// SPDX-License-Identifier: MIT
import Foundation
import CoreImage

@main enum AutomaticCalibrationTests {
    static var checks=0
    static func check(_ yes:Bool,_ label:String) {precondition(yes,label);checks += 1;print("PASS",label)}
    static func rejects(_ label:String,_ action:()throws->Void) {do {try action();fatalError(label)} catch {checks += 1;print("PASS",label)}}
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("cfv-auto-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:dir)}
        let json="""
        {"make":"Hasselblad","model":"Hasselblad CFV-50c/500","decoded_width":32,"decoded_height":32,"origin_x":0,"origin_y":0,"native_width":32,"native_height":32,"orientation":1,"decoder_version":"7"}
        """
        let camera=try JSONDecoder().decode(SensorIdentity.self,from:Data(json.utf8))
        func profile(_ iso:Int?,_ count:Int=10,_ ratio:Double=0.8,_ name:String="old")->HotPixelProfile {
            var p=HotPixelProfile(camera:camera,calibration:CalibrationMetrics(iso:iso,exposure_seconds:0.008,frame_count:count,confirm_ratio:ratio,candidate_counts:Array(repeating:1,count:count)),hot_pixels_yx:[[10,10]])
            p.schema_version=2;p.hot_regions=[HotPixelRegion(y:10,x:10,radius:3)];p.profile_id="\(name)-\(iso ?? 0)"
            return p
        }
        func frames(_ iso:Int?,_ count:Int)->[PlannedDarkFrame] {
            (0..<count).map {PlannedDarkFrame(url:dir.appendingPathComponent("ISO\(iso ?? 0)/\($0).3fr"),camera:camera,iso:iso,exposure:0.008,darkFraction:1)}
        }
        let path=dir.appendingPathComponent("catalog.json")
        let previous=HotPixelCatalog(profiles:[profile(100),profile(400)])
        try previous.write(path);let original=try Data(contentsOf:path)
        let plan=CalibrationPlan(groups:CalibrationPlanner.group(frames(100,13)+frames(800,8)+frames(1600,3)),scanned:24,rejected:["ordinary frame excluded"])
        var calls:[Int]=[],receivedRatios:[Double]=[]
        let build:AutomaticCalibration.Builder={files,ratio,progress in
            let iso=Int(files[0].deletingLastPathComponent().lastPathComponent.dropFirst(3))!
            calls.append(files.count);receivedRatios.append(ratio);progress(0.5,"test progress")
            return profile(iso,files.count,ratio,"new")
        }
        let result=try AutomaticCalibration.buildAndSave(plan,previous:previous,ratio:0.85,destination:path,build:build) {_,_ in}
        let saved=try HotPixelCatalog.read(path)
        check(calls == [12,8],"all eligible ISO groups run automatically with at most 12 frames")
        check(receivedRatios == [0.85,0.85],"advanced ratio captured for all groups")
        check(saved.same_back_confirmed && saved.profiles.count==3,"completed strategy saved and same-back assumption recorded")
        check(saved.profiles.contains {$0.profile_id=="old-400"} && !saved.profiles.contains {$0.profile_id=="old-100"},"update matching group and retain other existing ISO templates")
        check(try Data(contentsOf:path.appendingPathExtension("previous")) == original,"one automatic save backs up the previous strategy")
        check(result.issues.count==2,"rejected files and insufficient groups recorded without manual steps")
        let partialPlan=CalibrationPlan(groups:CalibrationPlanner.group(frames(100,10)+frames(800,10)),scanned:20,rejected:[])
        let oldWith800=HotPixelCatalog(profiles:[profile(100),profile(800)])
        let partial=try AutomaticCalibration.buildAndSave(partialPlan,previous:oldWith800,ratio:0.8,destination:path,build:{files,ratio,progress in
            if files[0].path.contains("ISO800") {throw PixelRepairError("test decoder error")}
            return profile(100,files.count,ratio,"recovered")
        }) {_,_ in}
        check(partial.generated.count==1 && partial.catalog.profiles.contains {$0.profile_id=="old-800"},"one failed group preserves its prior template while successful groups save")
        let stable=try Data(contentsOf:path),backup=try Data(contentsOf:path.appendingPathExtension("previous"))
        rejects("all failed groups do not save or replace active strategy") {
            _=try AutomaticCalibration.buildAndSave(partialPlan,previous:partial.catalog,ratio:0.8,destination:path,build:{_,_,_ in throw PixelRepairError("test failure")}) {_,_ in}
        }
        check(try Data(contentsOf:path)==stable && Data(contentsOf:path.appendingPathExtension("previous"))==backup,"failed run leaves both strategy and backup unchanged")
        rejects("insufficient black frames leave strategy untouched") {
            _=try AutomaticCalibration.buildAndSave(CalibrationPlan(groups:CalibrationPlanner.group(frames(100,2)),scanned:2,rejected:[]),previous:partial.catalog,ratio:0.8,destination:path,build:build) {_,_ in}
        }
        rejects("inconsistent generated metadata cannot be saved") {
            _=try AutomaticCalibration.buildAndSave(partialPlan,previous:partial.catalog,ratio:0.8,destination:path,build:{_,_,_ in profile(1600)}) {_,_ in}
        }
        let blocked=dir.appendingPathComponent("blocked");try Data([0]).write(to:blocked)
        rejects("disk write failure is reported rather than success") {
            _=try AutomaticCalibration.buildAndSave(partialPlan,previous:partial.catalog,ratio:0.8,destination:blocked.appendingPathComponent("catalog.json"),build:build) {_,_ in}
        }
        var large=camera;large.decoded_width=1000;large.decoded_height=1000;large.native_width=1000;large.native_height=1000
        let denseFrames=[100,800].flatMap {(iso:Int) in (0..<8).map {i in PlannedDarkFrame(url:dir.appendingPathComponent("denseISO\(iso)/\(i).3fr"),camera:large,iso:iso,exposure:0.008,darkFraction:1)}}
        let densePlan=CalibrationPlan(groups:CalibrationPlanner.group(denseFrames),scanned:16,rejected:[])
        let beforeDense=try Data(contentsOf:path)
        rejects("unusable merged strategies are rejected before automatic save") {
            _=try AutomaticCalibration.buildAndSave(densePlan,previous:partial.catalog,ratio:0.8,destination:path,build:{files,ratio,_ in
                let iso=files[0].path.contains("denseISO100") ? 100 : 800,start=iso==100 ? 0 : 3000
                let points=(start..<(start+3000)).map {[$0/300*3+4,$0%300*3+4]}
                var p=HotPixelProfile(camera:large,calibration:CalibrationMetrics(iso:iso,exposure_seconds:0.008,frame_count:8,confirm_ratio:ratio,candidate_counts:Array(repeating:3000,count:8)),hot_pixels_yx:points)
                p.schema_version=2;p.hot_regions=points.map {HotPixelRegion(y:$0[0],x:$0[1],radius:1)}
                return p
            }) {_,_ in}
        }
        check(try Data(contentsOf:path)==beforeDense,"merged-strategy failure preserves saved catalog")
        let genericPlan=CalibrationPlan(groups:CalibrationPlanner.group(frames(nil,8)),scanned:8,rejected:[])
        let generic=try AutomaticCalibration.buildAndSave(genericPlan,previous:HotPixelCatalog(profiles:[]),ratio:0.8,destination:dir.appendingPathComponent("generic.json"),build:{files,ratio,_ in profile(nil,files.count,ratio,"generic")}) {_,_ in}
        check(generic.generated.count==1 && generic.generated[0].calibration.iso==nil,"black frames without ISO can build a generic reference")
        let a=profile(100,10,0.8,"low"),b=profile(800,10,0.8,"high"),c=profile(400,10,0.8,"middle")
        let missing=try HotPixelCatalog.select([b,a],identity:camera,iso:nil,exposure:0.008)
        let exact=try HotPixelCatalog.select([a,b],identity:camera,iso:800,exposure:nil)
        let nearest=try HotPixelCatalog.select([b,a,c],identity:camera,iso:500,exposure:nil)
        check(missing.profile_id=="sensor-low-100","missing photo ISO defaults to lowest recorded ISO")
        check(exact.profile_id=="sensor-high-800","matching ISO is the preferred reference")
        check(nearest.profile_id=="sensor-middle-400","unmatched ISO chooses nearest exposure-stop reference")
        let unknown=profile(nil,10,0.8,"unknown")
        check(try HotPixelCatalog.select([unknown,a],identity:camera,iso:800,exposure:nil).profile_id=="sensor-low-100","generic reference does not override an available known ISO")
        let suite="cfv-auto-tests-"+UUID().uuidString,preferences=UserDefaults(suiteName:suite)!
        defer {preferences.removePersistentDomain(forName:suite)}
        preferences.set(true,forKey:"hotPixelEnabled")
        let modelPath=dir.appendingPathComponent("model.json")
        try previous.write(modelPath)
        let model=HotPixelModel(storeURL:modelPath,preferences:preferences)
        check(model.enabled && model.catalog.same_back_confirmed,"existing unbound strategy migrates without a confirmation step")
        check(model.ratio==0.8,"repeat ratio uses the system default")
        model.ratio=0.9
        check(preferences.double(forKey:"hotConfirmRatio")==0.9,"advanced repeat ratio persists without a save action")
        if let folder=CommandLine.arguments.dropFirst().first {
            // Exercise the actual async model in isolation; no writes to the user's app store.
            let realPath=dir.appendingPathComponent("real.json")
            let live=HotPixelModel(storeURL:realPath,preferences:preferences);live.ratio=0.8
            live.scan(URL(fileURLWithPath:folder))
            let chosen=live.folder
            live.scan(dir) // A second request during calibration must not start another run.
            check(live.folder==chosen,"duplicate starts are ignored while automatic calibration is busy")
            for _ in 0..<6000 {if !live.busy {break};try await Task.sleep(nanoseconds:100_000_000)}
            try await Task.sleep(nanoseconds:100_000_000)
            check(!live.busy && live.stage == .saved && live.progress==1,"real folder selection completes scanning, calibration and saving with no intervening user actions")
            let actual=try HotPixelCatalog.read(realPath)
            check(actual.same_back_confirmed && !actual.profiles.isEmpty && Set(actual.profiles.map(\.profile_id))==Set(live.catalog.profiles.map(\.profile_id)),"real multi-ISO strategy is durable on disk")
            check(live.message.contains("自动保存"),"late progress callbacks cannot overwrite saved status")
            live.enabled=true;let durable=try Data(contentsOf:realPath)
            live.scan(dir.appendingPathComponent("missing-folder"))
            for _ in 0..<100 {if !live.busy {break};try await Task.sleep(nanoseconds:50_000_000)}
            let afterFailure=try Data(contentsOf:realPath)
            check(live.stage == .failed && live.enabled && afterFailure==durable,"failed rescan preserves saved strategy and apply preference")
            print("REAL AUTO WORKFLOW",actual.profiles.map {"ISO\($0.calibration.iso ?? 0):\($0.points.count)"}.joined(separator:", "))
        }
        print("PASS \(checks) automatic workflow checks")
    }
}
