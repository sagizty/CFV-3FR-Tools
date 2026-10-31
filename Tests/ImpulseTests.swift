// SPDX-License-Identifier: MIT
import Foundation
import CoreImage
@main enum ImpulseTests {
 static var checks=0
 static func check(_ value:Bool,_ label:String) {print(value ? "PASS" : "FAIL",label);precondition(value,label);checks += 1}
 static func main() throws {
  setbuf(stdout,nil)
  check(ImpulseCleaner.requiresSignature,"released cleanup requires learned signatures")
  let w=96,h=96,ctx=HotPixelEngine.context(),linear=HotPixelEngine.linear
  let kernel:[Float]=[0.05,0.10,0.05,0.20,1,0.20,0.05,0.10,0.05]
  var shape=[Float](repeating:0,count:81)
  for dy in -1...1 {for dx in -1...1 {shape[(dy+4)*9+dx+4]=kernel[(dy+1)*3+dx+1]}}
  let norm=sqrt(shape.reduce(0){$0+$1*$1});shape=shape.map{$0/norm}
  let signature=ImpulseSignature(channel:0,xPhase:0,yPhase:0,band:2,samples:shape)
  check(signature.valid,"shape validates")
  func make(_ amplitudes:[(PixelYX,Float)],star:Bool=false,line:Bool=false,background:Float=0.001)->CIImage {
   var a=[Float](repeating:background,count:w*h*4)
   for y in 0..<h {for x in 0..<w {
    let i=((h-1-y)*w+x)*4;a[i+3]=1
    if star {let r=Float((x-70)*(x-70)+(y-24)*(y-24));let v=Float(0.2)*exp(-r/8);a[i] += v;a[i+1] += v*0.8;a[i+2] += v*0.6}
    if line && x==72 && y>=55 && y<=82 {a[i]=0.15}
   }}
   for (p,amp) in amplitudes {for dy in -1...1 {for dx in -1...1 {
    let x=p.x+dx,y=p.y+dy;if x<0 || y<0 || x>=w || y>=h {continue}
    a[((h-1-y)*w+x)*4] += amp*kernel[(dy+1)*3+dx+1]
   }}}
   let data=a.withUnsafeBytes{Data($0)}
   return CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:linear)
  }
  let impulse=PixelYX(y:40,x:40)
  let input=make([(impulse,0.2)],star:true,line:true)
  let cleaned=try ImpulseCleaner.clean(input,signatures:[signature],context:ctx)
  let original=HotPixelEngine.floats(input,rect:input.extent,context:ctx),after=HotPixelEngine.floats(cleaned.image,rect:input.extent,context:ctx)
  check(after[(40*w+40)*4]<0.003,"unmapped multi-pixel impulse removed")
  check(abs(after[(24*w+70)*4]-original[(24*w+70)*4])<0.000001,"broad optical point preserved")
  check(abs(after[(65*w+72)*4]-original[(65*w+72)*4])<0.000001,"long thin line preserved")
  check(cleaned.changedPixels>0 && cleaned.changedPixels<100,"repair stays sparse")
  let absent=try ImpulseCleaner.clean(input,signatures:[],context:ctx)
  check(absent.changedPixels==0,"no unverified cleanup without calibration shapes")
  let weak=make([(impulse,0.006)])
  let weakClean=try ImpulseCleaner.clean(weak,signatures:[signature],context:ctx)
  check(HotPixelEngine.floats(weakClean.image,rect:weak.extent,context:ctx)[(40*w+40)*4]<0.003,"shape match permits amplitude changes across ISO")
  let midtone=make([(impulse,0.2)],background:0.1)
  let midtoneClean=try ImpulseCleaner.clean(midtone,signatures:[signature],context:ctx)
  let midtonePixels=HotPixelEngine.floats(midtoneClean.image,rect:midtone.extent,context:ctx)
  check(abs(midtonePixels[(40*w+40)*4]-0.1)<0.00001,"local detection repairs chromatic impulse on a normal midtone background")
  check(abs(midtonePixels[(10*w+10)*4]-0.1)<0.00001,"normal midtone away from impulse preserved")
  let edge=make([(PixelYX(y:0,x:0),0.2)])
  let edgeClean=try ImpulseCleaner.clean(edge,signatures:[signature],context:ctx)
  check(HotPixelEngine.floats(edgeClean.image,rect:edge.extent,context:ctx)[0]<0.003,"partial edge impulse repaired without out-of-bounds")
  let shifted=input.transformed(by:CGAffineTransform(translationX:100,y:200))
  let shiftedClean=try ImpulseCleaner.clean(shifted,signatures:[signature],context:ctx)
  check(HotPixelEngine.floats(shiftedClean.image,rect:shifted.extent,context:ctx)[(40*w+40)*4]<0.003,"nonzero image origin handled")
  // Provider buckets must preserve normalized coordinates at tile edges and the far corner.
  let markers:[PixelYX:SIMD4<Float>]=[PixelYX(y:0,x:0):SIMD4<Float>(0.2,0.3,0.4,1),PixelYX(y:255,x:256):SIMD4<Float>(0.7,0.2,0.1,1),PixelYX(y:256,x:255):SIMD4<Float>(0.1,0.6,0.4,1),PixelYX(y:599,x:639):SIMD4<Float>(0.3,0.2,0.9,1)]
  let provider=SparsePixelProvider(packed:markers,height:600)
  let tiled=CIImage(imageProvider:provider,size:640,600,format:.RGBAf,colorSpace:linear,options:[.providerTileSize:256])
  for (point,color) in markers {
   let v=HotPixelEngine.floats(tiled,rect:CGRect(x:point.x,y:point.y,width:1,height:1),context:ctx)
   check(abs(v[0]-color.x)<0.000001 && abs(v[1]-color.y)<0.000001 && abs(v[2]-color.z)<0.000001,"sparse provider tile boundary \(point)")
  }
  var malformed=signature;malformed.samples=[0]
  check(!malformed.valid,"malformed shape rejected")
  print("PASS \(checks) impulse cleanup checks")
 }
}
