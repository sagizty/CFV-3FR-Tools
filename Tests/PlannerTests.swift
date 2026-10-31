// SPDX-License-Identifier: MIT
import Foundation
import CoreImage
@main enum PlannerTests {
 static var checks=0
 static func check(_ yes:Bool,_ label:String) { precondition(yes,label);checks += 1 }
 static func rejects(_ label:String,_ f:() throws -> Void) { do { try f();fatalError(label) } catch { checks += 1 } }
 static func trySelect(_ maps:[HotPixelProfile],_ camera:SensorIdentity,_ iso:Int?,_ exposure:Double?) -> Bool {
  (try? HotPixelCatalog.select(maps,identity:camera,iso:iso,exposure:exposure)) != nil
 }
 static func main() throws {
  setbuf(stdout,nil)
  let json="""
  {"make":"Hasselblad","model":"Hasselblad CFV-50c/500","decoded_width":32,"decoded_height":32,"origin_x":0,"origin_y":0,"native_width":32,"native_height":32,"orientation":1,"decoder_version":"7"}
  """
  let camera=try JSONDecoder().decode(SensorIdentity.self,from:Data(json.utf8))
  var dark=[Float](repeating:0,count:400)
  for i in 0..<100 { dark[i*4+3]=1 }
  check(CalibrationPlanner.blackScore(dark) == 1,"black accepted")
  dark[0]=1
  check(CalibrationPlanner.blackScore(dark)>=0.98,"isolated bright point retained")
  for i in 0..<40 { dark[i*4]=0.5 }
  check(CalibrationPlanner.blackScore(dark)<0.98,"ordinary image excluded")
  check(CalibrationPlanner.blackScore([0,0,0,0]) == 0,"transparent rendering rejected")
  var frames:[PlannedDarkFrame]=[]
  for i in 0..<3 { frames.append(PlannedDarkFrame(url:URL(fileURLWithPath:"/100-\(i).3fr"),camera:camera,iso:100,exposure:0.008,darkFraction:1)) }
  for i in 0..<8 { frames.append(PlannedDarkFrame(url:URL(fileURLWithPath:"/800-\(i).3fr"),camera:camera,iso:800,exposure:0.008,darkFraction:1)) }
  frames.append(PlannedDarkFrame(url:URL(fileURLWithPath:"/long.3fr"),camera:camera,iso:800,exposure:1,darkFraction:1))
  let groups=CalibrationPlanner.group(frames)
  check(groups.count == 3,"ISO/exposure separated")
  check(groups[0].advice.contains("7"),"three existing frames need seven")
  check(groups.filter(\.ready).count == 1,"only eligible group selected")
  var a=HotPixelProfile(camera:camera,calibration:CalibrationMetrics(iso:100,exposure_seconds:0.008,frame_count:10,confirm_ratio:0.8,candidate_counts:Array(repeating:1,count:10)),hot_pixels_yx:[[10,10]])
  a.schema_version=2;a.hot_regions=[HotPixelRegion(y:10,x:10,radius:3)]
  try a.validate()
  var b=a;b.profile_id="long";b.calibration.exposure_seconds=1
  let selected=try HotPixelCatalog.select([a,b],identity:camera,iso:100,exposure:0.01)
  check(selected.points == a.points,"closest exposure does not drop fixed positions")
  check(trySelect([a,b],camera,800,0.01),"single calibrated ISO works on ISO800")
  check(trySelect([a],camera,nil,0.01),"missing ISO can use sensor map")
  check(trySelect([a,b],camera,100,nil),"missing exposure can use merged sensor map")
  var different=camera;different.orientation=6
  rejects("orientation mismatch") { _=try HotPixelCatalog.select([a],identity:different,iso:100,exposure:0.01) }
  let url=URL(fileURLWithPath:"/private/tmp/cfv-catalog-test.json")
  try HotPixelCatalog(same_back_confirmed:true,profiles:[a,b]).write(url)
  let loaded=try HotPixelCatalog.read(url)
  check(loaded.profiles.count == 2 && loaded.same_back_confirmed,"catalog persistence")
  let legacy=URL(fileURLWithPath:"/private/tmp/cfv-legacy-test.json")
  try a.write(legacy)
  let imported=try HotPixelCatalog.read(legacy)
  check(imported.profiles.count == 1 && !imported.same_back_confirmed,"legacy import requires binding")
  if let folder=CommandLine.arguments.dropFirst().first {
   let plan=try CalibrationPlanner.scan(URL(fileURLWithPath:folder)) { _,_ in }
   print("REAL SCAN",plan.scanned,"black",plan.blackCount,"rejected",plan.rejected.count)
   print(plan.rejected)
   for group in plan.groups { print(group.title,group.advice) }
   check(plan.blackCount > 0 && plan.blackCount <= plan.scanned,"genuine dark frames found")
   check(plan.groups.allSatisfy { group in group.frames.allSatisfy { $0.iso == group.iso && $0.exposure == group.exposure } },"each group has consistent capture settings")
  }
  print("PASS \(checks) planner/catalog checks")
 }
}
