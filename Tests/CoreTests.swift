// SPDX-License-Identifier: MIT
import Foundation
import CoreImage
@main enum CoreTests {
 static var checks=0
 static func check(_ condition: @autoclosure () -> Bool, _ message:String) {
  checks += 1
  if !condition() { fatalError("FAIL: \(message)") }
 }
 static func rejects(_ block:() throws -> Void,_ message:String) {
  do { try block(); fatalError("FAIL expected rejection: \(message)") } catch { checks += 1 }
 }
 static func main() throws {
  let json = """
  {"make":"Hasselblad","model":"Hasselblad CFV-50c/500","decoded_width":32,"decoded_height":32,"origin_x":0,"origin_y":0,"native_width":32,"native_height":32,"orientation":1,"decoder_version":"7"}
  """
  let identity=try JSONDecoder().decode(SensorIdentity.self,from:Data(json.utf8))
  var p=HotPixelProfile(camera:identity,calibration:CalibrationMetrics(frame_count:10,confirm_ratio:0.8,candidate_counts:Array(repeating:2,count:10)),hot_pixels_yx:[[5,9],[5,9],[8,12]])
  try p.validate(); check(p.points.count == 2,"dedup")
  p.schema_version=2;p.hot_regions=p.points.map { HotPixelRegion(y:$0.y,x:$0.x,radius:2) };try p.validate()
  check(p.points[0] == PixelYX(y:5,x:9),"yx order")
  rejects({ try p.matches(identity,manuallyBound:false) },"serial binding")
  try p.matches(identity,manuallyBound:true)
  var mismatch=identity; mismatch.orientation=6
  rejects({ try p.matches(mismatch,manuallyBound:true) },"orientation mismatch")
  mismatch=identity; mismatch.decoder_version="8"
  rejects({ try p.matches(mismatch,manuallyBound:true) },"decoder mismatch")
  mismatch=identity; mismatch.decoded_width=33
  rejects({ try p.matches(mismatch,manuallyBound:true) },"size mismatch")
  var invalid=p; invalid.hot_pixels_yx=[[32,0]]
  rejects({ try invalid.validate() },"bounds")
  invalid=p; invalid.hot_pixels_yx=[[1]]
  rejects({ try invalid.validate() },"tuple shape")
  invalid=p; invalid.coordinate_system="visible_raw_yx"
  rejects({ try invalid.validate() },"CFA mapping rejected")
  invalid=p; invalid.schema_version=3
  rejects({ try invalid.validate() },"future schema")
  let tmp=URL(fileURLWithPath:"/private/tmp/cfv-test-map.json")
  try p.write(tmp); try p.write(tmp)
  let loaded = try HotPixelProfile.read(tmp)
  check(loaded.points == p.points,"JSON roundtrip")
  check(FileManager.default.fileExists(atPath:tmp.appendingPathExtension("previous").path),"atomic update backup")
  let ctx=HotPixelEngine.context(), w=32, h=32
  func image(_ hot:[PixelYX]) -> CIImage {
   var rgb=[Float](repeating:0,count:w*h*4)
   for i in 0..<w*h { rgb[i*4]=0.001; rgb[i*4+1]=0.001; rgb[i*4+2]=0.001; rgb[i*4+3]=1 }
   for q in hot { rgb[((h-1-q.y)*w+q.x)*4]=0.7 }
   let data=rgb.withUnsafeBytes { Data($0) }
   return CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:HotPixelEngine.linear)
  }
  let fixed=[PixelYX(y:0,x:0),PixelYX(y:15,x:16),PixelYX(y:31,x:31)]
  var frames:[Set<PixelYX>]=[]
  for n in 0..<10 {
   let input=image(fixed+[PixelYX(y:4+n,x:4)])
   frames.append(try HotPixelEngine.detect(input,context:ctx) { _ in })
  }
  let confirmed=HotPixelEngine.confirm(frames,ratio:0.8)
  check(Set(confirmed) == Set(fixed),"100% fixed-point recall; zero confirmed false positives incl edges")
  let source=image(fixed), output=HotPixelEngine.repair(source,points:fixed,context:ctx)
  check(output.repaired == 3 && output.skipped == 0,"edge repair")
  let before=HotPixelEngine.floats(source,rect:source.extent,context:ctx)
  let after=HotPixelEngine.floats(output.image,rect:source.extent,context:ctx)
  var outside=0, changed=0
  for y in 0..<h { for x in 0..<w {
   let affected=fixed.contains { max(abs(x-$0.x),abs(y-$0.y)) <= 2 }
   for c in 0..<4 where abs(before[(y*w+x)*4+c]-after[(y*w+x)*4+c]) > 0.000001 {
    if !affected { outside += 1 }; changed += 1
   }
  } }
  check(outside == 0 && changed > 0,"only local mapped disks changed")
  let empty=HotPixelEngine.repair(source,points:[],context:ctx)
  check(HotPixelEngine.floats(empty.image,rect:source.extent,context:ctx) == before,"empty mapping no change")
  let order1=HotPixelEngine.repair(source,points:fixed,context:ctx)
  let order2=HotPixelEngine.repair(source,points:fixed.reversed(),context:ctx)
  check(HotPixelEngine.floats(order1.image,rect:source.extent,context:ctx) == HotPixelEngine.floats(order2.image,rect:source.extent,context:ctx),"order independent")
  var dense:[PixelYX]=[]
  for y in 5...26 { for x in 5...26 { dense.append(PixelYX(y:y,x:x)) } }
  check(HotPixelEngine.repair(source,points:dense,context:ctx).skipped > 0,"dense cluster safely skips unavailable neighbors")
  rejects({ _ = try HotPixelEngine.calibrate([],ratio:0.8) { _,_ in } },"insufficient calibration frames")
  print("PASS \(checks) checks (RGB compatibility route; CFA not accessed)")
 }
}
