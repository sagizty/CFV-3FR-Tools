// SPDX-License-Identifier: MIT
import Foundation
import CoreImage
import ImageIO

struct CaptureGroupKey: Hashable {
    let identityData: Data
    let iso: Int?
    let exposure: Double?
    init(identity: SensorIdentity, iso: Int?, exposure: Double?) {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        identityData=(try? encoder.encode(identity)) ?? Data()
        self.iso=iso; self.exposure=exposure
    }
}
struct PlannedDarkFrame {
    let url: URL
    let camera: SensorIdentity
    let iso: Int?
    let exposure: Double?
    let darkFraction: Double
}
struct CalibrationGroup: Identifiable {
    let id=UUID()
    let frames: [PlannedDarkFrame]
    var iso: Int? { frames.first?.iso }
    var exposure: Double? { frames.first?.exposure }
    var ready: Bool { frames.count >= 8 }
    var selectedFrames: [URL] { Array(frames.prefix(12)).map(\.url) }
    var title: String {
        let label=iso.map { "ISO \($0)" } ?? "ISO 未记录"
        let time=Self.exposureLabel(exposure)
        return "\(label) · \(time) · \(frames.count) 张"
    }
    var advice: String {
        let exposureNote=exposure == nil ? " 文件未记录曝光时间，请确认组内拍摄曝光相同。" : ""
        if frames.count < 8 { return "再拍 \(10-frames.count) 张同 ISO / 曝光黑场，可补足推荐的 10 张。" + exposureNote }
        return (frames.count > 12 ? "已足够；自动使用文件名顺序前 12 张。" : "可以标定；将使用全部 \(frames.count) 张。") + exposureNote
    }
    static func exposureLabel(_ value: Double?) -> String {
        guard let value, value > 0 else { return "曝光未记录" }
        if value < 1 { return "1/\(Int((1/value).rounded()))s" }
        return String(format:"%.2gs",value)
    }
}
struct CalibrationPlan {
    var groups: [CalibrationGroup]
    var scanned: Int
    var rejected: [String]
    var blackCount: Int { groups.reduce(0) { $0+$1.frames.count } }
}
enum CalibrationPlanner {
    static func capture(_ raw: CIRAWFilter) -> (iso:Int?, exposure:Double?) {
        let p=raw.properties as? [String:Any] ?? [:]
        let e=p[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        let iso=(e[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue
        let exposure=(e[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        return (iso.flatMap { $0 > 0 ? $0 : nil },exposure.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
    }
    static func blackScore(_ pixels: [Float]) -> Double {
        guard pixels.count >= 4 else { return 0 }
        var dark=0, valid=0
        for i in stride(from:0,to:pixels.count-3,by:4) {
            let v=max(pixels[i],max(pixels[i+1],pixels[i+2]))
            guard v.isFinite, pixels[i+3] > 0.99 else { continue }
            valid += 1
            if v < 0.025 { dark += 1 }
        }
        return valid > 0 && Double(valid)/Double(pixels.count/4) >= 0.98 ? Double(dark)/Double(valid) : 0
    }
    static func group(_ frames:[PlannedDarkFrame]) -> [CalibrationGroup] {
        Dictionary(grouping:frames) { CaptureGroupKey(identity:$0.camera,iso:$0.iso,exposure:$0.exposure) }
            .values.map { CalibrationGroup(frames:$0.sorted { $0.url.path < $1.url.path }) }
            .sorted {
                if $0.iso != $1.iso { return ($0.iso ?? Int.max) < ($1.iso ?? Int.max) }
                if $0.exposure != $1.exposure { return ($0.exposure ?? 0) < ($1.exposure ?? 0) }
                return $0.frames[0].url.path < $1.frames[0].url.path
            }
    }
    static func scan(_ folder:URL, progress:(Double,String)->Void) throws -> CalibrationPlan {
        var isDirectory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:folder.path,isDirectory:&isDirectory),isDirectory.boolValue else {
            throw PixelRepairError("请选择标定文件夹。")
        }
        var failures:[String]=[]
        guard let enumerator=FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles,.skipsPackageDescendants],errorHandler:{ url,error in
            failures.append("\(url.lastPathComponent)：\(error.localizedDescription)"); return true
        }) else { throw PixelRepairError("无法读取标定文件夹。") }
        var urls:[URL]=[]
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() != "3fr" { continue }
            let values=try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            if values?.isRegularFile == true && values?.isSymbolicLink != true { urls.append(url) }
            if urls.count > 10000 { throw PixelRepairError("文件夹超过 10000 张 3FR，请选择更小的标定文件夹。") }
        }
        urls.sort { $0.path < $1.path }
        guard !urls.isEmpty else { throw PixelRepairError("文件夹及子文件夹中没有 3FR 文件。") }
        var frames:[PlannedDarkFrame]=[]
        let ctx=HotPixelEngine.context()
        for (index,url) in urls.enumerated() {
            autoreleasepool {
                do {
                    guard let raw=CIRAWFilter(imageURL:url) else { throw PixelRepairError("RAW 无法解码") }
                    raw.isDraftModeEnabled=false
                    guard let image=raw.outputImage else { throw PixelRepairError("RAW 无法解码") }
                    let identity=try SensorIdentity(raw:raw,image:image), capture=capture(raw)
                    // Full RAW output is sampled at small size; embedded JPEG previews are not used.
                    let scale=min(128/image.extent.width,128/image.extent.height)
                    let small=image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
                        .applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:scale,kCIInputAspectRatioKey:1])
                    let sampleBounds=CGRect(x:2,y:2,width:floor(image.extent.width*scale)-4,height:floor(image.extent.height*scale)-4)
                    guard sampleBounds.width >= 4,sampleBounds.height >= 4 else { throw PixelRepairError("无法取得可靠黑场采样范围") }
                    let score=blackScore(HotPixelEngine.floats(small,rect:sampleBounds,context:ctx))
                    if score >= 0.98 {
                        frames.append(PlannedDarkFrame(url:url,camera:identity,iso:capture.iso,exposure:capture.exposure,darkFraction:score))
                    } else { failures.append("\(url.lastPathComponent)：不像黑场（暗部占比 \(Int(score*100))%），已排除") }
                } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
                ctx.clearCaches()
            }
            progress(Double(index+1)/Double(urls.count),"扫描 \(index+1)/\(urls.count)：\(url.lastPathComponent)")
        }
        return CalibrationPlan(groups:group(frames),scanned:urls.count,rejected:failures)
    }
}
struct HotPixelCatalog: Codable {
    var catalog_version=1
    var same_back_confirmed=false
    var profiles:[HotPixelProfile]
    mutating func validate() throws {
        guard catalog_version == 1, profiles.count <= 64, Set(profiles.map(\.profile_id)).count == profiles.count else { throw PixelRepairError("模板集版本或数量无效。") }
        for i in profiles.indices { try profiles[i].validate() }
    }
    static func read(_ url:URL) throws -> Self {
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 25_000_000 else { throw PixelRepairError("模板集过大。") }
        let data=try Data(contentsOf:url)
        if var catalog=try? JSONDecoder().decode(Self.self,from:data) { try catalog.validate(); return catalog }
        let profile=try HotPixelProfile.read(url)
        return Self(profiles:[profile])
    }
    func write(_ url:URL) throws {
        var checked=self; try checked.validate()
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let data=try encoder.encode(checked)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:url.path) {
            try Data(contentsOf:url).write(to:url.appendingPathExtension("previous"),options:.atomic)
        }
        try data.write(to:url,options:.atomic)
    }
    // A fixed-location sensor map belongs to the back, not to an ISO value.
    // ISO/exposure only choose the preferred center when merging near-identical entries.
    static func select(_ profiles:[HotPixelProfile], identity:SensorIdentity, iso:Int?, exposure:Double?) throws -> HotPixelProfile {
        let valid=profiles.filter { $0.enabled && $0.schema_version == 2 && $0.coordinate_revision == "ci_bottom_left_normalized_v2" }
        guard !valid.isEmpty else { throw PixelRepairError("没有可用的新版模板；旧版坐标需重新标定。") }
        let sources=valid.filter { $0.camera == identity }.sorted { a,b in
            let ai=a.calibration.iso,bi=b.calibration.iso
            // Known capture ISO: exact, then nearest in exposure stops. Missing ISO:
            // the lowest recorded ISO anchors the shared sensor map deterministically.
            if let iso,iso>0 {
                if (ai != nil) != (bi != nil) { return ai != nil }
                if let ai,let bi {
                let da=abs(log2(Double(ai)/Double(iso))),db=abs(log2(Double(bi)/Double(iso)))
                if da != db { return da < db }
                if ai != bi { return ai < bi }
                }
            } else if ai != bi {
                return (ai ?? Int.max) < (bi ?? Int.max)
            }
            if let exposure,exposure>0 {
                let da=a.calibration.exposure_seconds.map { abs(log2($0/exposure)) } ?? .infinity
                let db=b.calibration.exposure_seconds.map { abs(log2($0/exposure)) } ?? .infinity
                if da != db { return da < db }
            }
            return a.created_at == b.created_at ? a.profile_id < b.profile_id : a.created_at > b.created_at
        }
        guard var result=sources.first else { throw PixelRepairError("模板与照片的后背、尺寸、方向或解码版本不匹配。") }
        var regions:[HotPixelRegion]=[],centers:[PixelYX:Int]=[:]
        for source in sources {
            for region in source.repairRegions.sorted(by:{$0.point < $1.point}) {
                var near:[Int]=[]
                for dy in -1...1 { for dx in -1...1 {
                    if let index=centers[PixelYX(y:region.y+dy,x:region.x+dx)] { near.append(index) }
                } }
                if let index=near.min(by:{
                    let da=abs(regions[$0].x-region.x)+abs(regions[$0].y-region.y)
                    let db=abs(regions[$1].x-region.x)+abs(regions[$1].y-region.y)
                    return da == db ? $0 < $1 : da < db
                }) {
                    let shift=max(abs(regions[index].x-region.x),abs(regions[index].y-region.y))
                    regions[index].radius=min(6,max(regions[index].radius,region.radius+shift))
                } else {
                    centers[region.point]=regions.count;regions.append(region)
                }
            }
        }
        guard regions.count <= 5000 else { throw PixelRepairError("合并后的固定点超过 5000 个，请检查模板或停用异常模板。") }
        regions.sort { $0.point < $1.point }
        result.profile_id="sensor-"+String(result.profile_id.prefix(112))
        result.hot_regions=regions;result.hot_pixels_yx=regions.map { [$0.y,$0.x] }
        result.common_iso_sources=nil
        var unique=Set<ImpulseSignature>()
        result.impulse_signatures=sources.flatMap { $0.impulse_signatures ?? [] }.filter { unique.insert($0).inserted }.prefix(384).map { $0 }
        result.template_iso_sources=Array(Set(sources.compactMap { $0.calibration.iso })).sorted()
        result.calibration.iso=nil
        result.calibration.notes="Camera-wide union of calibrated fixed locations. Valid across ISO; each photo must pass local positive anomaly verification. Not a calibration taken at the target ISO."
        try result.validate();return result
    }
}

struct AutomaticCalibrationResult {
    var catalog:HotPixelCatalog
    var generated:[HotPixelProfile]
    var issues:[String]
}
enum AutomaticCalibration {
    typealias Builder=([URL],Double,(Double,String)->Void)throws->HotPixelProfile
    // Save only after at least one valid group succeeds. Failed/incomplete groups retain
    // their previous templates; the catalog writer validates and atomically replaces it.
    static func buildAndSave(_ plan:CalibrationPlan,previous:HotPixelCatalog,ratio:Double,
                             destination:URL,
                             build:Builder={try HotPixelEngine.calibrate($0,ratio:$1,progress:$2)},
                             progress:@escaping (Double,String)->Void)throws->AutomaticCalibrationResult {
        guard ratio.isFinite,(0.5...1).contains(ratio) else {throw PixelRepairError("重复检测比例无效。")}
        let groups=plan.groups.filter(\.ready)
        guard !groups.isEmpty else {throw PixelRepairError("没有足够的黑场可建立模板。每组至少需要 8 张同 ISO、同曝光黑场，建议拍摄 10 张。现有策略已保留。")}
        guard groups.count<=64 else {throw PixelRepairError("标定分组超过 64 组，请选择较小的文件夹。现有策略已保留。")}
        var completed:[HotPixelProfile]=[],issues=plan.rejected
        for group in plan.groups where !group.ready {issues.append("\(group.title)：不足 8 张，保留已有模板。")}
        for (index,group) in groups.enumerated() {
            do {
                var profile=try build(group.selectedFrames,ratio) {fraction,text in
                    progress((Double(index)+fraction)/Double(groups.count),"\(group.iso.map {"ISO \($0)"} ?? "通用参考") · \(text)")
                }
                try profile.validate()
                guard profile.schema_version==2,profile.enabled,
                      profile.camera==group.frames[0].camera,profile.calibration.iso==group.iso,
                      profile.calibration.exposure_seconds==group.exposure,profile.calibration.frame_count==group.selectedFrames.count else {throw PixelRepairError("生成结果与黑场分组不一致。")}
                completed.append(profile)
            } catch {issues.append("\(group.title)：\(error.localizedDescription)")}
        }
        guard !completed.isEmpty else {throw PixelRepairError("未能生成有效模板，现有策略已保留。\n"+issues.joined(separator:"\n"))}
        var updated=previous
        for profile in completed {
            updated.profiles.removeAll {$0.camera==profile.camera && $0.calibration.iso==profile.calibration.iso && $0.calibration.exposure_seconds==profile.calibration.exposure_seconds}
            updated.profiles.append(profile)
        }
        // The app assumes one back by default; compatibility is still checked per photo.
        updated.same_back_confirmed=true
        try updated.validate()
        // Check the actual merged strategies before replacing a working catalog.
        for profile in completed {
            _=try HotPixelCatalog.select(updated.profiles,identity:profile.camera,
                                         iso:profile.calibration.iso,exposure:profile.calibration.exposure_seconds)
        }
        progress(1,"正在自动保存标定策略…")
        try updated.write(destination)
        return AutomaticCalibrationResult(catalog:updated,generated:completed,issues:issues)
    }
}
