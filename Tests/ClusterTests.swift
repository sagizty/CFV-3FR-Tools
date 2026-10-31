// SPDX-License-Identifier: MIT
import Foundation
import CoreImage
@main enum ClusterTests {
 static var checks=0
 static func check(_ yes:Bool,_ label:String) { print(yes ? "PASS" : "FAIL",label);precondition(yes,label);checks += 1 }
 static func rejects(_ f:() throws -> Void) { do { try f();fatalError("expected rejection") } catch { checks += 1 } }
 static func main() throws {
  setbuf(stdout,nil)
  let markerBounds=CGRect(x:0,y:0,width:32,height:32)
  let marker=CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:markerBounds)
  let marked=CIImage(color:CIColor(red:0.8,green:0,blue:0)).cropped(to:CGRect(x:7,y:4,width:1,height:1)).composited(over:marker)
  let markerContext=HotPixelEngine.context()
  let markerPixels=HotPixelEngine.floats(marked,rect:markerBounds,context:markerContext)
  check(markerPixels[(4*32+7)*4] > 0.2 && markerPixels[(27*32+7)*4] < 0.01,"CI-space coordinates independently match normalized bitmap rows")
  let markerDetected=try HotPixelEngine.detect(marked,context:markerContext) { _ in }
  check(markerDetected.contains(PixelYX(y:4,x:7)),"detector reports actual asymmetric CI coordinate")
  let markerFixed=HotPixelEngine.repair(marked,regions:[HotPixelRegion(y:4,x:7,radius:2)],context:markerContext)
  check(HotPixelEngine.floats(markerFixed.image,rect:markerBounds,context:markerContext)[(4*32+7)*4]<0.01,"repair changes actual CI coordinate, not mirrored row")
  let center=PixelYX(y:32,x:32)
  let jitter=(0..<12).map { i -> Set<PixelYX> in [PixelYX(y:32+(i%3)-1,x:32+((i/3)%3)-1)] }
  let confirmed=HotPixelEngine.confirmClusters(jitter,ratio:0.8)
  check(confirmed.count == 1 && abs(confirmed[0].x-32)<=1 && abs(confirmed[0].y-32)<=1,"subpixel peak jitter confirmed as one cluster")
  let insufficient=(0..<10).map { i -> Set<PixelYX> in i < 7 ? [center,PixelYX(y:32,x:33)] : [] }
  check(HotPixelEngine.confirmClusters(insufficient,ratio:0.8).isEmpty,"multiple neighboring peaks cannot double-vote a frame")
  let w=64,h=64,ctx=HotPixelEngine.context()
  func make(_ damaged:Bool,_ black:Bool=false)->CIImage {
   var pixels=[Float](repeating:0,count:w*h*4)
   for y in 0..<h { for x in 0..<w {
    let i=((h-1-y)*w+x)*4
    let a:[Float] = black ? [0.001,0.001,0.001] : (x<32 ? [0.16,0.09,0.04] : [0.035,0.08,0.055])
    for c in 0..<3 { pixels[i+c]=a[c] };pixels[i+3]=1
    if damaged && abs(y-32)<=3 && abs(x-32)<=3 {
     let r=max(abs(y-32),abs(x-32))
     if r<=2 && !(x==32 && y==32) { pixels[i]=black ? 0.01 : 0.8;pixels[i+2]=black ? 0.012 : 0.6 }
     else if r==3 { pixels[i+1]=black ? 0.003 : 0.3;pixels[i+2]=black ? 0.004 : 0.35 }
    }
    // A real colored object outside the registered area must not be removed.
    if x==8 && y==8 { pixels[i]=0.9 }
   } }
   let data=pixels.withUnsafeBytes { Data($0) }
   return CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:HotPixelEngine.linear)
  }
  var weakPixels=[Float](repeating:0.001,count:w*h*4)
  for i in 0..<w*h { weakPixels[i*4+3]=1 }
  weakPixels[((h-1-32)*w+32)*4] += 0.0018
  let weakData=weakPixels.withUnsafeBytes { Data($0) }
  let weak=CIImage(bitmapData:weakData,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:HotPixelEngine.linear)
  let weakFixed=HotPixelEngine.repair(weak,regions:[HotPixelRegion(y:32,x:32,radius:3)],context:ctx)
  check(HotPixelEngine.floats(weakFixed.image,rect:weak.extent,context:ctx)[(32*w+32)*4]<0.0011,"weak isolated color point below old activation floor repaired")
  let damaged=make(true),clean=make(false)
  let unchanged=HotPixelEngine.repair(clean,regions:[HotPixelRegion(y:32,x:32,radius:4)],context:ctx)
  check(HotPixelEngine.floats(unchanged.image,rect:clean.extent,context:ctx) == HotPixelEngine.floats(clean,rect:clean.extent,context:ctx),"inactive registered point does not change healthy texture")
  let learned=HotPixelEngine.learnRegions(make(true,true),points:[center],context:ctx)
  check(learned.count == 1 && learned[0].radius>=4,"hollow magenta core and cyan halo included with guard border")
  let result=HotPixelEngine.repair(damaged,regions:learned,context:ctx)
  let a=HotPixelEngine.floats(damaged,rect:damaged.extent,context:ctx),b=HotPixelEngine.floats(result.image,rect:damaged.extent,context:ctx),truth=HotPixelEngine.floats(clean,rect:clean.extent,context:ctx)
  var outsideDiff:Float=0,insideError:Float=0
  for y in 0..<h { for x in 0..<w { for c in 0..<3 {
   let i=(y*w+x)*4+c
   if max(abs(x-32),abs(y-32))<=learned[0].radius { insideError=max(insideError,abs(b[i]-truth[i])) }
   else { outsideDiff=max(outsideDiff,abs(b[i]-a[i])) }
  } } }
  check(outsideDiff<0.000001,"outside cluster footprint unchanged including real red object")
  check(insideError<0.00001,"colored halo removed and straight texture boundary preserved")
  let json="""
  {"make":"Hasselblad","model":"Hasselblad CFV-50c/500","decoded_width":64,"decoded_height":64,"origin_x":0,"origin_y":0,"native_width":64,"native_height":64,"orientation":1,"decoder_version":"7"}
  """
  let camera=try JSONDecoder().decode(SensorIdentity.self,from:Data(json.utf8))
  var p=HotPixelProfile(camera:camera,calibration:CalibrationMetrics(iso:100,frame_count:12,confirm_ratio:0.8,candidate_counts:Array(repeating:2,count:12)),hot_pixels_yx:[[32,32],[10,10]])
  p.schema_version=2;p.hot_regions=[HotPixelRegion(y:32,x:32,radius:4),HotPixelRegion(y:10,x:10,radius:3)]
  try p.validate()
  var q=p;q.profile_id="ISO800";q.calibration.iso=800;q.hot_pixels_yx=[[32,33],[50,50]];q.hot_regions=[HotPixelRegion(y:32,x:33,radius:4),HotPixelRegion(y:50,x:50,radius:3)]
  let common=try HotPixelCatalog.select([p,q],identity:camera,iso:200,exposure:nil)
  check(common.points == [PixelYX(y:10,x:10),center,PixelYX(y:50,x:50)] && common.template_iso_sources == [100,800],"ISO200 receives calibrated fixed-location union including ISO-specific points")
  check(common.calibration.iso == nil,"cross-ISO map does not pretend ISO200 was calibrated")
  check(common.repairRegions.first(where:{$0.point == center})?.radius == 5,"cross-ISO center drift included in footprint")
  let exact=try HotPixelCatalog.select([p,q],identity:camera,iso:100,exposure:nil)
  check(exact.repairRegions.contains(where:{$0.point == center}) && exact.template_iso_sources == [100,800],"same ISO anchors duplicate centers but does not discard other fixed points")
  let single=try HotPixelCatalog.select([p],identity:camera,iso:200,exposure:nil)
  check(single.points == p.points && single.template_iso_sources == [100],"one ISO template applies to another ISO")
  let missing=try HotPixelCatalog.select([p],identity:camera,iso:nil,exposure:nil)
  check(missing.points == p.points,"missing photo ISO does not block camera identity map")
  var foreign=q;foreign.camera.serial="different-back"
  let localOnly=try HotPixelCatalog.select([p,foreign],identity:camera,iso:200,exposure:nil)
  check(localOnly.points == p.points,"foreign back points never enter merged map")
  var obsolete=p;obsolete.schema_version=1;obsolete.hot_regions=nil;obsolete.coordinate_revision=nil
  try obsolete.validate()
  rejects { _=try HotPixelCatalog.select([obsolete],identity:camera,iso:100,exposure:nil) }
  rejects { try obsolete.matches(camera,manuallyBound:true) }
  var malformed=p;malformed.hot_regions![0].radius=99
  rejects { try malformed.validate() }
  malformed=p;malformed.hot_regions=nil
  rejects { try malformed.validate() }
  print("PASS \(checks) cluster/halo/jitter/cross-ISO checks")
 }
}
