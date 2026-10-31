// SPDX-License-Identifier: MIT
import Foundation
import CoreImage

struct ImpulseSignature:Codable,Hashable {
    var channel:Int;var xPhase:Int;var yPhase:Int;var band:Int;var samples:[Float]
    var valid:Bool {
        (0...2).contains(channel) && (0...1).contains(xPhase) && (0...1).contains(yPhase) && (0...2).contains(band) && samples.count==81 && samples.allSatisfy{$0.isFinite && $0>=0 && $0<=1.001} && abs(samples.reduce(0){$0+$1*$1}-1)<0.02
    }
    var key:Int {channel*4+xPhase*2+yPhase}
}
private struct ImpulsePatch {
    var channel:Int;var band:Int;var samples:[Float];var visible:[Bool];var amplitude:Float;var background:Float;var noise:Float;var chromatic:Float
}
private enum PatchBuilder {
    static func build(_ rgba:[Float],width:Int,low:Int,high:Int,point:PixelYX,allowCompact:Bool=false,compact:Bool=false)->ImpulsePatch? {
        func rgb(_ x:Int,_ y:Int,_ c:Int)->Float? {
            guard x>=0,x<width,y>=low,y<high else{return nil}
            let v=rgba[((y-low)*width+x)*4+c];return v.isFinite ? v : nil
        }
        let offsets=[(-6,-6),(-6,0),(-6,6),(0,-6),(0,6),(6,-6),(6,0),(6,6)]
        var bases:[Float]=[],noises:[Float]=[]
        for c in 0..<3 {
            let values=offsets.compactMap{rgb(point.x+$0.1,point.y+$0.0,c)}
            guard values.count>=3,let center=rgb(point.x,point.y,c) else{return nil}
            let base=HotPixelEngine.median(values);bases.append(base)
            noises.append(HotPixelEngine.median(values.map{abs($0-base)})*1.4826)
            if !center.isFinite{return nil}
        }
        let excess=(0..<3).map{(rgb(point.x,point.y,$0) ?? bases[$0])-bases[$0]}
        let channel=(0..<3).max{excess[$0]<excess[$1]}!,amplitude=excess[channel]
        guard amplitude>0.001 else{return nil}
        let cut=compact ? max(amplitude*0.18,noises[channel]*2.5) : max(amplitude*0.08,noises[channel]*1.5)
        var samples=[Float](repeating:0,count:81),visible=[Bool](repeating:false,count:81)
        for dy in -4...4 {for dx in -4...4 {
            let i=(dy+4)*9+dx+4
            if let v=rgb(point.x+dx,point.y+dy,channel) {
                visible[i]=true;let delta=v-bases[channel];if delta>cut {samples[i]=delta}
            }
        }}
        guard samples[40]>0 else{return nil}
        var connected=Set<Int>([40]),queue=[40],head=0
        while head<queue.count {
            let i=queue[head];head += 1;let x=i%9,y=i/9
            for dy in -1...1 {for dx in -1...1 {
                let xx=x+dx,yy=y+dy;if xx<0 || xx>=9 || yy<0 || yy>=9 {continue}
                let j=yy*9+xx;if samples[j]>0,connected.insert(j).inserted {queue.append(j)}
            }}
        }
        let inner=(-1...1).flatMap {dy in (-1...1).compactMap {dx -> Float? in
            guard dy != 0 || dx != 0,let v=rgb(point.x+dx,point.y+dy,channel) else{return nil}
            return max(0,v-bases[channel])
        }}
        let sharp = inner.count>=3 && HotPixelEngine.median(inner)<amplitude*0.55
        if connected.count>35 && allowCompact && !compact && (bases.max() ?? 0)<0.003 && sharp {
            // Dark-frame grain can connect an impulse to unrelated noise. Retry segmentation
            // at a higher noise support level; keep the same compactness and shape checks.
            return build(rgba,width:width,low:low,high:high,point:point,allowCompact:true,compact:true)
        }
        guard connected.count>=3,connected.count<=35 else{return nil}
        for i in samples.indices where !connected.contains(i) {samples[i]=0}
        let norm=sqrt(samples.reduce(0){$0+$1*$1});guard norm>0 else{return nil}
        samples=samples.map{$0/norm}
        return ImpulsePatch(channel:channel,band:amplitude<0.012 ? 0 : (amplitude<0.05 ? 1 : 2),samples:samples,visible:visible,amplitude:amplitude,background:bases.max() ?? 0,noise:noises[channel],chromatic:amplitude-(excess.min() ?? 0))
    }
}
final class ImpulseSignatureLearner {
    private var buckets:[Int:[ImpulseSignature]]=[:]
    var signatures:[ImpulseSignature] {buckets.keys.sorted().flatMap{buckets[$0]!}}
    func observe(_ rgba:[Float],width:Int,low:Int,high:Int,points:[PixelYX]) {
        for p in points {
            guard p.x>=6,p.x<width-6,p.y>=low+6,p.y<high-6,let patch=PatchBuilder.build(rgba,width:width,low:low,high:high,point:p) else{continue}
            let signature=ImpulseSignature(channel:patch.channel,xPhase:p.x&1,yPhase:p.y&1,band:patch.band,samples:patch.samples)
            let key=signature.key*3+signature.band
            let existing=buckets[key] ?? []
            if existing.count>=4 {continue}
            if existing.contains(where:{ zip($0.samples,signature.samples).reduce(Float(0)){$0+$1.0*$1.1}>0.997 }) {continue}
            buckets[key,default:[]].append(signature)
        }
    }
}
struct ImpulseCleanupResult {var image:CIImage;var candidates:Int;var matched:Int;var changedPixels:Int;var note:String}
enum ImpulseCleaner {
    // Per-image cleanup always requires signatures learned from genuine calibration frames.
    static let requiresSignature=true
    static func diagnostic(_ image:CIImage,point:PixelYX,signatures:[ImpulseSignature],context:CIContext)->String {
        let x0=max(0,point.x-12),y0=max(0,point.y-12),x1=min(Int(image.extent.width),point.x+13),y1=min(Int(image.extent.height),point.y+13)
        let rgba=HotPixelEngine.floats(image,rect:CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0),context:context)
        var best:Float=0,detail="all patches rejected"
        for dy in -2...2 {for dx in -2...2 {
            let q=PixelYX(y:point.y+dy,x:point.x+dx)
            guard let patch=PatchBuilder.build(rgba,width:x1-x0,low:0,high:y1-y0,point:PixelYX(y:q.y-y0,x:q.x-x0),allowCompact:true) else {continue}
            for shape in signatures where shape.channel==patch.channel && shape.xPhase==q.x&1 && shape.yPhase==q.y&1 {
                var dot:Float=0,sn:Float=0,pn:Float=0
                for i in 0..<81 where patch.visible[i] && abs(i%9-4)<=2 && abs(i/9-4)<=2 {
                    dot += patch.samples[i]*shape.samples[i];sn += shape.samples[i]*shape.samples[i];pn += patch.samples[i]*patch.samples[i]
                }
                let score=sn>0 && pn>0 ? dot/sqrt(sn*pn) : 0
                if score>best {best=score;detail="offset \(dy),\(dx), score \(score), amp \(patch.amplitude), background \(patch.background), noise \(patch.noise), chromatic \(patch.chromatic)"}
            }
        }}
        return detail
    }
    static func clean(_ image:CIImage,signatures:[ImpulseSignature],context:CIContext,rows:Range<Int>?=nil)throws->ImpulseCleanupResult {
        var current=image,candidates=0,matched=0,changed=0,note=""
        for _ in 0..<4 {
            let pass=try onePass(current,signatures:signatures,context:context,rows:rows)
            current=pass.image;candidates += pass.candidates;matched += pass.matched;changed += pass.changedPixels;note=pass.note
            if pass.changedPixels==0 {break}
            context.clearCaches()
        }
        return ImpulseCleanupResult(image:current,candidates:candidates,matched:matched,changedPixels:changed,note:note+"; up to 4 passes")
    }
    private static func onePass(_ image:CIImage,signatures:[ImpulseSignature],context:CIContext,rows:Range<Int>?=nil)throws->ImpulseCleanupResult {
        if requiresSignature && signatures.isEmpty {return ImpulseCleanupResult(image:image,candidates:0,matched:0,changedPixels:0,note:"no learned shapes; update calibration")}
        let grouped=Dictionary(grouping:signatures,by:{$0.key})
        let bounds=image.extent,w=Int(bounds.width),h=Int(bounds.height)
        var packed:[PixelYX:SIMD4<Float>]=[:],candidateCount=0,matchedCount=0
        let visitor:PixelTileVisitor={rgba,width,low,high,start,points in
            var mask=[UInt8](repeating:0,count:width*(high-low)),dirty:[Int]=[]
            let sampled=stride(from:0,to:rgba.count/4,by:97).map { i in max(rgba[i*4],max(rgba[i*4+1],rgba[i*4+2])) }.filter(\.isFinite)
            let referenceBase=HotPixelEngine.median(sampled)
            let referenceNoise=HotPixelEngine.median(sampled.map{abs($0-referenceBase)})*1.4826
            let referenceLimit=max(Float(0.002),referenceBase+8*referenceNoise)
            func mark(_ x:Int,_ y:Int) {
                guard x>=0,x<w,y>=0,y<h,y>=low,y<high else{return}
                let i=(y-low)*width+x
                if mask[i]==0 {mask[i]=1;dirty.append(i)}
            }
            candidateCount += points.count
            for p in points {
                var support:[Int]=[],anchor=p
                if requiresSignature {
                    var match:(PixelYX,ImpulsePatch,ImpulseSignature)?,bestScore:Float=0,bestRequired:Float=1
                    // Demosaic plateaus may move the local peak by one pixel. Match the shape at
                    // neighboring anchors using each anchor's real normalized coordinate phase.
                    let offsets=[(0,0),(-1,0),(1,0),(0,-1),(0,1),(-1,-1),(-1,1),(1,-1),(1,1)]
                    for (dy,dx) in offsets {
                        let q=PixelYX(y:p.y+dy,x:p.x+dx)
                        guard let patch=PatchBuilder.build(rgba,width:width,low:low,high:high,point:q,allowCompact:true),patch.amplitude>0.003 else{continue}
                        let scene = patch.background>0.01 || (patch.background>0.003 && patch.noise>patch.amplitude*0.30)
                        let required:Float = scene ? 0.97 : 0.80
                        if scene && patch.chromatic<max(0.005,patch.amplitude*0.60) {continue}
                        for shape in grouped[patch.channel*4+(q.x&1)*2+(q.y&1)] ?? [] {
                            var dot:Float=0,shapeNorm:Float=0,patchNorm:Float=0
                            for i in 0..<81 where patch.visible[i] && abs(i%9-4)<=2 && abs(i/9-4)<=2 {
                                dot += patch.samples[i]*shape.samples[i];shapeNorm += shape.samples[i]*shape.samples[i];patchNorm += patch.samples[i]*patch.samples[i]
                            }
                            let score=shapeNorm>0 && patchNorm>0 ? dot/sqrt(shapeNorm*patchNorm) : 0
                            if score>=required && score>bestScore {bestScore=score;bestRequired=required;match=(q,patch,shape)}
                        }
                        if match != nil && bestScore>=max(0.90,bestRequired) {break}
                    }
                    guard let (q,patch,best)=match,bestScore>=bestRequired else{continue}
                    anchor=q
                    let limit=(best.samples.max() ?? 1)*0.08
                    support=(0..<81).filter{abs($0%9-4)<=2 && abs($0/9-4)<=2 && (best.samples[$0]>limit || patch.samples[$0]>limit)}
                } else {support=(0..<81).filter{max(abs($0%9-4),abs($0/9-4))<=2}}
                matchedCount += 1
                for index in support {
                    let x=anchor.x+index%9-4,y=anchor.y+index/9-4
                    for dy in -1...1 {for dx in -1...1 {mark(x+dx,y+dy)}}
                }
            }
            func healthy(_ x:Int,_ y:Int)->SIMD3<Float>? {
                guard x>=0,x<w,y>=low,y<high else{return nil}
                let i=(y-low)*width+x;guard mask[i]==0 else{return nil}
                let j=i*4,v=SIMD3<Float>(rgba[j],rgba[j+1],rgba[j+2])
                guard v.x.isFinite && v.y.isFinite && v.z.isFinite,max(v.x,max(v.y,v.z))<=referenceLimit else{return nil}
                return v
            }
            for index in dirty {
                let x=index%width,y=low+index/width,key=PixelYX(y:y,x:x)
                if packed[key] != nil {continue}
                var best:SIMD3<Float>?,cost=Float.infinity
                for (dx,dy) in [(1,0),(0,1),(1,1),(1,-1)] {
                    var left:(SIMD3<Float>,Int)?,right:(SIMD3<Float>,Int)?
                    for distance in 1...14 {
                        if left==nil,let v=healthy(x-dx*distance,y-dy*distance){left=(v,distance)}
                        if right==nil,let v=healthy(x+dx*distance,y+dy*distance){right=(v,distance)}
                        if left != nil && right != nil{break}
                    }
                    if let left,let right {
                        let d=left.0-right.0,c=abs(d.x)+abs(d.y)+abs(d.z)
                        if c<cost {cost=c;let t=Float(left.1)/Float(left.1+right.1);best=left.0*(1-t)+right.0*t}
                    }
                }
                if best==nil {
                    var values=[[Float]](repeating:[],count:3)
                    for dy in stride(from:-8,through:8,by:2){for dx in stride(from:-8,through:8,by:2){
                        if max(abs(dx),abs(dy))>=4,let v=healthy(x+dx,y+dy){values[0].append(v.x);values[1].append(v.y);values[2].append(v.z)}
                    }}
                    if values[0].count>=4 {best=SIMD3<Float>(HotPixelEngine.median(values[0]),HotPixelEngine.median(values[1]),HotPixelEngine.median(values[2]))}
                }
                if let best {packed[key]=SIMD4<Float>(best.x,best.y,best.z,1)}
            }
            if packed.count>4_000_000 {throw PixelRepairError("彩点簇候选覆盖过多，已保留固定点修复并跳过此补充阶段。")}
        }
        _=try HotPixelEngine.detect(image,context:context,requireDark:false,visit:visitor,rows:rows,noiseMultiplier:8,localNoiseMultiplier:4){_ in}
        if packed.isEmpty {return ImpulseCleanupResult(image:image,candidates:candidateCount,matched:matchedCount,changedPixels:0,note:"no matched impulses")}
        let provider=SparsePixelProvider(packed:packed,height:h)
        let overlay=CIImage(imageProvider:provider,size:w,h,format:.RGBAf,colorSpace:HotPixelEngine.linear,options:[.providerTileSize:256])
            .transformed(by:CGAffineTransform(translationX:bounds.minX,y:bounds.minY))
        return ImpulseCleanupResult(image:overlay.composited(over:image).cropped(to:bounds),candidates:candidateCount,matched:matchedCount,changedPixels:packed.count,note:"learned impulse cleanup")
    }
}
