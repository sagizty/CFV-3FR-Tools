// SPDX-License-Identifier: MIT
import Foundation
import CoreImage
import ImageIO

struct PixelYX: Hashable, Comparable {
    let y: Int
    let x: Int
    static func < (a: Self, b: Self) -> Bool { a.y == b.y ? a.x < b.x : a.y < b.y }
}
struct PixelRepairError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct SensorIdentity: Codable, Equatable {
    var make: String
    var model: String
    var serial: String?
    var decoded_width: Int
    var decoded_height: Int
    var origin_x: Int
    var origin_y: Int
    var native_width: Int
    var native_height: Int
    var orientation: UInt32
    var decoder_version: String

    init(raw: CIRAWFilter, image: CIImage) throws {
        let p = raw.properties as? [String: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        make = tiff[kCGImagePropertyTIFFMake as String] as? String ?? ""
        model = tiff[kCGImagePropertyTIFFModel as String] as? String ?? ""
        serial = exif["BodySerialNumber"] as? String
        if serial?.isEmpty == true { serial = nil }
        guard make.lowercased().contains("hasselblad"), model.lowercased().contains("cfv-50c"),
              !model.lowercased().contains("cfv ii") else {
            throw PixelRepairError("无法确认是初代 CFV-50c：\(make) \(model)。")
        }
        let b = image.extent
        guard !b.isInfinite, !b.isEmpty, b == b.integral, b.width < 30000, b.height < 30000 else {
            throw PixelRepairError("不支持的解码尺寸或坐标范围。")
        }
        decoded_width = Int(b.width); decoded_height = Int(b.height)
        origin_x = Int(b.minX); origin_y = Int(b.minY)
        native_width = Int(raw.nativeSize.width); native_height = Int(raw.nativeSize.height)
        orientation = raw.orientation.rawValue
        decoder_version = raw.decoderVersion.rawValue
    }
}
struct CalibrationMetrics: Codable {
    var type = "dark_frame_hot_pixels_decoded_rgb"
    var iso: Int? = nil
    var exposure_seconds: Double? = nil
    var frame_count: Int
    var confirm_ratio: Double
    var candidate_counts: [Int]
    var threshold_method = "linear_rgb_local_median_mad_bright_only_v1"
    var notes = "Route B: Apple demosaiced output; not sensor CFA coordinates. No dead pixel detection."
}
struct HotPixelRegion: Codable {
    var y:Int
    var x:Int
    var radius:Int
    var point:PixelYX { PixelYX(y:y,x:x) }
}
struct HotPixelProfile: Codable {
    var schema_version = 1
    var profile_id = UUID().uuidString
    var coordinate_system = "coreimage_decoded_bottom_left_yx"
    var camera: SensorIdentity
    var created_at = ISO8601DateFormatter().string(from: Date())
    var calibration: CalibrationMetrics
    var hot_pixels_yx: [[Int]]
    var coordinate_revision: String? = "ci_bottom_left_normalized_v2"
    var hot_regions: [HotPixelRegion]? = nil
    var common_iso_sources: [Int]? = nil
    var template_iso_sources: [Int]? = nil
    var impulse_signatures: [ImpulseSignature]? = nil
    var repairRegions:[HotPixelRegion] { hot_regions ?? points.map { HotPixelRegion(y:$0.y,x:$0.x,radius:4) } }
    var enabled = true
    var points: [PixelYX] { hot_pixels_yx.map { PixelYX(y: $0[0], x: $0[1]) } }
    var suspicious: Bool { hot_pixels_yx.count > 2000 }

    mutating func validate() throws {
        guard (1...2).contains(schema_version), coordinate_system == "coreimage_decoded_bottom_left_yx" else {
            throw PixelRepairError("映射版本或坐标系不兼容。此 App 只接受本版 RGB 兼容映射，不能直接套用 RAW/CFA 坐标。")
        }
        guard camera.decoded_width > 0, camera.decoded_width < 30000,
              camera.decoded_height > 0, camera.decoded_height < 30000,
              camera.native_width > 0, camera.native_height > 0,
              (1...8).contains(camera.orientation), !camera.decoder_version.isEmpty,
              camera.make.lowercased().contains("hasselblad"), camera.model.lowercased().contains("cfv-50c"),
              !profile_id.isEmpty, profile_id.count < 128,
              ISO8601DateFormatter().date(from: created_at) != nil,
              calibration.type == "dark_frame_hot_pixels_decoded_rgb",
              (8...12).contains(calibration.frame_count), calibration.confirm_ratio.isFinite,
              (0.5...1).contains(calibration.confirm_ratio),
              calibration.candidate_counts.count == calibration.frame_count,
              calibration.candidate_counts.allSatisfy({ (0...250000).contains($0) }),
              hot_pixels_yx.count <= 5000 else { throw PixelRepairError("映射字段、机型、标定记录或亮点数量无效。") }
        if let iso=calibration.iso, iso <= 0 { throw PixelRepairError("模板 ISO 无效。") }
        if let exposure=calibration.exposure_seconds, !exposure.isFinite || exposure <= 0 { throw PixelRepairError("模板曝光时间无效。") }
        for p in hot_pixels_yx {
            guard p.count == 2, p[0] >= 0, p[1] >= 0,
                  p[0] < camera.decoded_height, p[1] < camera.decoded_width else {
                throw PixelRepairError("映射中包含无效或越界的 [y,x] 坐标。")
            }
        }
        hot_pixels_yx = Set(points).sorted().map { [$0.y, $0.x] }
        if let regions=hot_regions {
            guard schema_version == 2,coordinate_revision == "ci_bottom_left_normalized_v2",regions.count == hot_pixels_yx.count,
                  Set(regions.map(\.point)) == Set(points),regions.allSatisfy({ (1...6).contains($0.radius) }) else {
                throw PixelRepairError("彩点簇修复范围无效或与中心坐标不一致。")
            }
        } else if schema_version == 2 { throw PixelRepairError("新版模板缺少彩点簇范围，请重新标定。") }
        if let signatures=impulse_signatures {
            guard signatures.count <= 384,signatures.allSatisfy({$0.valid}) else { throw PixelRepairError("彩点簇形状模板无效。") }
        }
        if let sources=template_iso_sources, sources.contains(where:{$0 <= 0}) || sources.count > 64 { throw PixelRepairError("模板来源 ISO 无效。") }
        if let sources=common_iso_sources, sources.count < 2 || sources.contains(where:{$0 <= 0}) { throw PixelRepairError("跨 ISO 来源无效。") }
    }
    func matches(_ identity: SensorIdentity, manuallyBound: Bool) throws {
        guard schema_version == 2,coordinate_revision == "ci_bottom_left_normalized_v2" else { throw PixelRepairError("旧版标定存在行方向错误，已停用；请重新扫描黑场生成模板。") }
        guard enabled else { throw PixelRepairError("映射已停用。") }
        guard camera == identity else { throw PixelRepairError("机型、序列号、尺寸、方向或 RAW 解码版本不匹配。") }
        guard camera.serial != nil || manuallyBound else {
            throw PixelRepairError("无法读取后背序列号，请先确认来源文件夹与标定使用同一台后背。")
        }
    }
    static func read(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 5_000_000 else { throw PixelRepairError("映射文件过大。") }
        var p = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try p.validate(); return p
    }
    func write(_ url: URL) throws {
        var p = self; try p.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(p)
        if FileManager.default.fileExists(atPath: url.path) {
            let old = try Data(contentsOf: url)
            try old.write(to: url.appendingPathExtension("previous"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
}
struct PixelRepairOptions {
    var enabled = false
    var profile: HotPixelProfile?
    var manuallyBound = false
    var profiles: [HotPixelProfile] = []
    var cleanupImpulses = true
}
struct PixelRepairOutcome {
    var image: CIImage
    var repaired: Int
    var skipped: Int
}

// Immutable sparse overlay: Core Image requests only the tiles needed for encoding or preview.
final class SparsePixelProvider: NSObject {
    struct Item { let point:PixelYX;let color:SIMD4<Float> }
    let buckets:[PixelYX:[Item]]
    let imageHeight:Int
    convenience init(values:[PixelYX:[Float]],height:Int) {
        self.init(packed:values.mapValues { SIMD4<Float>($0[0],$0[1],$0[2],1) },height:height)
    }
    init(packed:[PixelYX:SIMD4<Float>],height:Int) {
        imageHeight=height
        var grouped:[PixelYX:[Item]]=[:]
        for (p,color) in packed {
            let py=height-1-p.y
            grouped[PixelYX(y:py/256,x:p.x/256),default:[]].append(Item(point:PixelYX(y:py,x:p.x),color:color))
        }
        buckets=grouped
    }
    override func provideImageData(_ data:UnsafeMutableRawPointer,bytesPerRow rowbytes:Int,
                                   origin originx:Int,_ originy:Int,size width:Int,_ height:Int,userInfo info:Any?) {
        data.initializeMemory(as:UInt8.self,repeating:0,count:rowbytes*height)
        guard width>0,height>0 else {return}
        for by in originy/256...(originy+height-1)/256 { for bx in originx/256...(originx+width-1)/256 {
            for item in buckets[PixelYX(y:by,x:bx)] ?? [] {
                let p=item.point
                guard p.x>=originx,p.x<originx+width,p.y>=originy,p.y<originy+height else {continue}
                let pixel=data.advanced(by:(p.y-originy)*rowbytes+(p.x-originx)*16).assumingMemoryBound(to:Float.self)
                pixel[0]=item.color.x;pixel[1]=item.color.y;pixel[2]=item.color.z;pixel[3]=1
            }
        } }
    }
}

typealias PixelTileVisitor=([Float],Int,Int,Int,Int,[PixelYX]) throws -> Void

enum HotPixelEngine {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static func context() -> CIContext { CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: true]) }
    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let a = values.sorted(); let n = a.count
        return n % 2 == 0 ? (a[n/2-1] + a[n/2]) / 2 : a[n/2]
    }
    static func floats(_ image: CIImage, rect: CGRect, context: CIContext) -> [Float] {
        let width = Int(rect.width), height = Int(rect.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: rect, format: .RGBAf, colorSpace: linear)
        }
        // CIContext bitmap rows are top-down. Expose only normalized bottom-left rows to all algorithms.
        var normalized=[Float](repeating:0,count:pixels.count)
        let stride=width*4
        for y in 0..<height {
            normalized.replaceSubrange(y*stride..<(y+1)*stride,with:pixels[(height-1-y)*stride..<(height-y)*stride])
        }
        return normalized
    }
    // Detect only positive local outliers, after the existing Apple demosaic. Never label these as CFA pixels.
    static func detect(_ image: CIImage, context: CIContext, requireDark:Bool=true, visit:PixelTileVisitor?=nil, rows:Range<Int>?=nil, noiseMultiplier:Float=12, localNoiseMultiplier:Float?=nil, progress: (Double) -> Void) throws -> Set<PixelYX> {
        let b = image.extent.integral, w = Int(b.width), h = Int(b.height)
        guard w >= 8, h >= 8 else { throw PixelRepairError("图像尺寸太小。") }
        var found = Set<PixelYX>()
        let tileHeight = 256, halo = 20
        let neighbors = [(-6,-6),(-6,0),(-6,6),(0,-6),(0,6),(6,-6),(6,0),(6,6)]
        for start in stride(from: 0, to: h, by: tileHeight) {
            if let rows,start>=rows.upperBound || min(start+tileHeight,h)<=rows.lowerBound {continue}
            try autoreleasepool {
                let low = max(0,start-halo), high = min(h,start+tileHeight+halo)
                let rect = CGRect(x: b.minX, y: b.minY + CGFloat(low), width: b.width, height: CGFloat(high-low))
                let rgba = floats(image, rect: rect, context: context)
                var peaks = [Float](repeating: 0, count: w * (high-low))
                for i in peaks.indices {
                    let v = max(rgba[i*4], max(rgba[i*4+1], rgba[i*4+2]))
                    peaks[i] = v.isFinite ? v : 0
                }
                let sampled = stride(from: 0, to: peaks.count, by: max(1,peaks.count/20000)).map { peaks[$0] }
                let base = median(sampled)
                let sigma = median(sampled.map { abs($0-base) }) * 1.4826
                if requireDark && !(base < 0.08 && Double(sampled.filter({ $0 > 0.2 }).count) / Double(max(1,sampled.count)) < 0.1) {
                    throw PixelRepairError("照片过亮，疑似不是完全遮光的黑场。请检查漏光或素材用途。")
                }
                let blackBand = base<0.008 && Double(sampled.filter {$0>0.04}.count)/Double(max(1,sampled.count))<0.02
                let gate:Float = requireDark || blackBand ? base + max(noiseMultiplier*sigma, 0.0015) : 0.0015
                var localPoints:[PixelYX]=[]
                for y in start..<min(start+tileHeight,h) {
                    let row = y-low
                    for x in 0..<w {
                        let v = peaks[row*w+x]
                        if v <= gate { continue }
                        var maximum = true
                        for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                            guard y+dy >= 0, y+dy < h, x+dx >= 0, x+dx < w else { continue }
                            let n = peaks[(row+dy)*w+x+dx]
                            if n > v || (n == v && (dy < 0 || (dy == 0 && dx < 0))) { maximum = false }
                        } }
                        if !maximum {continue}
                        let local = neighbors.compactMap { offset -> Float? in
                            let ny=y+offset.0, nx=x+offset.1
                            guard ny >= 0, ny < h, nx >= 0, nx < w else { return nil }
                            return peaks[(ny-low)*w+nx]
                        }
                        if local.count < 3 { continue }
                        let m = median(local)
                        let noise = median(local.map { abs($0-m) }) * 1.4826
                        if v <= m + max((localNoiseMultiplier ?? noiseMultiplier)*noise,0.0015) { continue }
                        if maximum { let p=PixelYX(y:y,x:x);found.insert(p);localPoints.append(p) }
                    }
                }
                try visit?(rgba,w,low,high,start,localPoints)
            }
            guard found.count <= 250000 else { throw PixelRepairError("候选亮点超过二十五万，疑似漏光或噪声；已终止标定。") }
            progress(Double(min(start+tileHeight,h))/Double(h))
        }
        return found
    }
    static func confirm(_ frames: [Set<PixelYX>], ratio: Double) -> [PixelYX] {
        var votes: [PixelYX:Int] = [:]
        for frame in frames { for p in frame { votes[p,default:0] += 1 } }
        let required = Int(ceil(Double(frames.count)*ratio))
        return votes.filter { $0.value >= required }.map(\.key).sorted()
    }
    static func calibrate(_ urls: [URL], ratio: Double, progress: (Double,String) -> Void) throws -> HotPixelProfile {
        guard (8...12).contains(urls.count), Set(urls.map { $0.standardizedFileURL }).count == urls.count else {
            throw PixelRepairError("请选择 8–12 个不同的黑场 3FR 文件，推荐 10 张。")
        }
        guard (0.5...1).contains(ratio), ratio.isFinite else { throw PixelRepairError("重复比例无效。") }
        // Preflight every file before scanning the first full-size frame.
        var identity: SensorIdentity?
        var captureISO: Int?
        var captureExposure: Double?
        var first = true
        for url in urls {
            guard url.pathExtension.lowercased() == "3fr", let raw = CIRAWFilter(imageURL:url) else { throw PixelRepairError("无法解码：\(url.lastPathComponent)") }
            raw.isDraftModeEnabled = false
            guard let image = raw.outputImage else { throw PixelRepairError("无法解码：\(url.lastPathComponent)") }
            let info = try SensorIdentity(raw:raw,image:image)
            let properties = raw.properties as? [String: Any] ?? [:]
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue
            let exposure = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
            if !first && (captureISO != iso || captureExposure != exposure) {
                throw PixelRepairError("请使用同一组 ISO 和曝光时间的黑场，不能混合不同曝光组。")
            }
            captureISO = iso; captureExposure = exposure; first = false
            if let identity, identity != info { throw PixelRepairError("黑场的机型、尺寸、方向或序列号不一致：\(url.lastPathComponent)") }
            identity = info
        }
        var detections: [Set<PixelYX>] = []
        let signatureLearner=ImpulseSignatureLearner()
        for (index,url) in urls.enumerated() {
            try autoreleasepool {
                guard let raw = CIRAWFilter(imageURL:url) else { throw PixelRepairError("无法解码：\(url.lastPathComponent)") }
                raw.isDraftModeEnabled = false
                guard let image = raw.outputImage else { throw PixelRepairError("无法解码：\(url.lastPathComponent)") }
                let ctx = context()
                do {
                    let visitor:PixelTileVisitor? = index < 3 ? { rgba,w,low,high,start,points in
                        signatureLearner.observe(rgba,width:w,low:low,high:high,points:points)
                    } : nil
                    let candidates = try detect(image, context:ctx,visit:visitor) { fraction in
                        progress((Double(index)+fraction)/Double(urls.count),"\(index+1)/\(urls.count) · \(url.lastPathComponent)")
                    }
                    detections.append(candidates)
                    progress(Double(index+1)/Double(urls.count),"第 \(index+1) 张：\(candidates.count) 个候选")
                } catch { throw PixelRepairError("\(url.lastPathComponent)：\(error.localizedDescription)") }
                ctx.clearCaches()
            }
        }
        let confirmed = confirmClusters(detections,ratio:ratio)
        guard confirmed.count <= 5000 else { throw PixelRepairError("重复亮点超过 5000 个，请检查黑场曝光、漏光及噪声。") }
        var profile = HotPixelProfile(camera:identity!,calibration:CalibrationMetrics(iso:captureISO,exposure_seconds:captureExposure,frame_count:urls.count,confirm_ratio:ratio,candidate_counts:detections.map(\.count)),hot_pixels_yx:confirmed.map { [$0.y,$0.x] })
        guard let firstRaw=CIRAWFilter(imageURL:urls[0]) else { throw PixelRepairError("无法读取修复范围参考黑场。") }
        firstRaw.isDraftModeEnabled=false
        guard let reference=firstRaw.outputImage else { throw PixelRepairError("无法读取修复范围参考黑场。") }
        profile.schema_version=2
        profile.impulse_signatures=signatureLearner.signatures
        profile.hot_regions=learnRegions(reference,points:confirmed,context:context())
        profile.calibration.threshold_method="linear_rgb_cluster_jitter_mad_v2"
        profile.calibration.notes="Post-demosaic clusters; +/-1 pixel repeat matching; learned radius 3...6 and healthy directional interpolation."
        try profile.validate(); return profile
    }
    // Merge per-frame peak jitter before voting, so one defect cannot vote several times in a frame.
    static func confirmClusters(_ frames:[Set<PixelYX>], ratio:Double) -> [PixelYX] {
        guard !frames.isEmpty, frames.count <= 16 else { return [] }
        let required=Int(ceil(Double(frames.count)*ratio-1e-9))
        var exact:[PixelYX:UInt16]=[:]
        for (index,frame) in frames.enumerated() { for p in frame { exact[p,default:0] |= UInt16(1)<<index } }
        let seedVotes=max(1,Int(ceil(Double(required)/9)))
        var bins:[PixelYX:UInt16]=[:]
        for (p,mask) in exact { bins[PixelYX(y:p.y/4,x:p.x/4),default:0] |= mask }
        var anchors=Set<PixelYX>()
        for (p,mask) in exact where mask.nonzeroBitCount >= seedVotes {
            var possible:UInt16=0
            for dy in -1...1 { for dx in -1...1 { possible |= bins[PixelYX(y:p.y/4+dy,x:p.x/4+dx)] ?? 0 } }
            if possible.nonzeroBitCount < required { continue }
            for dy in -1...1 { for dx in -1...1 { anchors.insert(PixelYX(y:p.y+dy,x:p.x+dx)) } }
        }
        var supported:[(PixelYX,Int,Int)]=[]
        for p in anchors {
            var mask:UInt16=0
            for dy in -1...1 { for dx in -1...1 { mask |= exact[PixelYX(y:p.y+dy,x:p.x+dx)] ?? 0 } }
            if mask.nonzeroBitCount >= required { supported.append((p,mask.nonzeroBitCount,(exact[p] ?? 0).nonzeroBitCount)) }
        }
        supported.sort { a,b in a.1 != b.1 ? a.1 > b.1 : (a.2 != b.2 ? a.2 > b.2 : a.0 < b.0) }
        var taken=Set<PixelYX>(), result:[PixelYX]=[]
        for (p,_,_) in supported {
            if taken.contains(p) { continue }
            var matched:[PixelYX]=[]
            for frame in frames {
                let neighbors=(-1...1).flatMap { dy in (-1...1).map { PixelYX(y:p.y+dy,x:p.x+$0) } }
                if let closest=neighbors.filter({frame.contains($0)}).min(by:{
                    let da=abs($0.x-p.x)+abs($0.y-p.y),db=abs($1.x-p.x)+abs($1.y-p.y)
                    return da == db ? $0 < $1 : da < db
                }) { matched.append(closest) }
            }
            let ys=matched.map(\.y).sorted(),xs=matched.map(\.x).sorted()
            let center=PixelYX(y:ys[ys.count/2],x:xs[xs.count/2]);result.append(center)
            for dy in -2...2 { for dx in -2...2 { taken.insert(PixelYX(y:center.y+dy,x:center.x+dx)) } }
        }
        return Array(Set(result)).sorted()
    }
    static func learnRegions(_ image:CIImage, points:[PixelYX], context:CIContext) -> [HotPixelRegion] {
        let b=image.extent,w=Int(b.width),h=Int(b.height)
        return points.map { p in
            let x0=max(0,p.x-9),y0=max(0,p.y-9),x1=min(w,p.x+10),y1=min(h,p.y+10),rw=x1-x0
            let data=floats(image,rect:CGRect(x:b.minX+CGFloat(x0),y:b.minY+CGFloat(y0),width:CGFloat(rw),height:CGFloat(y1-y0)),context:context)
            var background=[[Float]](repeating:[],count:3)
            for y in y0..<y1 { for x in x0..<x1 where max(abs(x-p.x),abs(y-p.y)) >= 7 {
                let i=((y-y0)*rw+x-x0)*4
                for c in 0..<3 where data[i+c].isFinite { background[c].append(data[i+c]) }
            } }
            let base=background.map(median)
            let noise=(0..<3).map { c in median(background[c].map { abs($0-base[c]) })*1.4826 }.max() ?? 0
            let threshold=max(5*noise,0.0003)
            var bright=Set<PixelYX>()
            for y in y0..<y1 { for x in x0..<x1 where max(abs(x-p.x),abs(y-p.y)) <= 5 {
                let i=((y-y0)*rw+x-x0)*4
                if (0..<3).contains(where:{ data[i+$0].isFinite && data[i+$0]-base[$0] > threshold }) { bright.insert(PixelYX(y:y,x:x)) }
            } }
            var visited=Set(bright.filter { max(abs($0.x-p.x),abs($0.y-p.y)) <= 2 }),queue=Array(bright.filter { max(abs($0.x-p.x),abs($0.y-p.y)) <= 2 })
            var index=0,radius=3
            while index<queue.count {
                let q=queue[index];index += 1
                radius=max(radius,max(abs(q.x-p.x),abs(q.y-p.y))+1)
                for dy in -1...1 { for dx in -1...1 {
                    let next=PixelYX(y:q.y+dy,x:q.x+dx)
                    if bright.contains(next),visited.insert(next).inserted { queue.append(next) }
                } }
            }
            return HotPixelRegion(y:p.y,x:p.x,radius:min(6,radius))
        }
    }
    static func repair(_ image:CIImage, points:[PixelYX], context:CIContext) -> PixelRepairOutcome {
        repair(image,regions:Set(points).sorted().map { HotPixelRegion(y:$0.y,x:$0.x,radius:2) },context:context)
    }
    static func repair(_ image:CIImage, regions:[HotPixelRegion], context:CIContext) -> PixelRepairOutcome {
        let b=image.extent.integral,w=Int(b.width),h=Int(b.height)
        let regions=regions.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        var excluded=Set<PixelYX>()
        for region in regions {
            let r=max(1,min(6,region.radius)),p=region.point
            for dy in -r...r { for dx in -r...r {
                let q=PixelYX(y:p.y+dy,x:p.x+dx)
                if q.x >= 0,q.y >= 0,q.x<w,q.y<h { excluded.insert(q) }
            } }
        }
        var values:[PixelYX:[Float]]=[:], repaired=0,skipped=0
        for region in regions {
            let p=region.point,r=max(1,min(6,region.radius))
            guard p.x>=0,p.y>=0,p.x<w,p.y<h else { skipped += 1;continue }
            let reach=r+12,x0=max(0,p.x-reach),y0=max(0,p.y-reach),x1=min(w,p.x+reach+1),y1=min(h,p.y+reach+1)
            let rw=x1-x0,src=floats(image,rect:CGRect(x:b.minX+CGFloat(x0),y:b.minY+CGFloat(y0),width:CGFloat(rw),height:CGFloat(y1-y0)),context:context)
            func healthy(_ q:PixelYX) -> [Float]? {
                guard q.x>=x0,q.y>=y0,q.x<x1,q.y<y1,!excluded.contains(q) else { return nil }
                let i=((q.y-y0)*rw+q.x-x0)*4,a=Array(src[i..<i+3])
                return a.allSatisfy { $0.isFinite } ? a : nil
            }
            var fallback=[[Float]](repeating:[],count:3)
            for y in y0..<y1 { for x in x0..<x1 {
                if let a=healthy(PixelYX(y:y,x:x)) { for c in 0..<3 { fallback[c].append(a[c]) } }
            } }
            var changed=false,active=false
            var proposed:[PixelYX:[Float]]=[:]
            for y in max(0,p.y-r)...min(h-1,p.y+r) { for x in max(0,p.x-r)...min(w-1,p.x+r) {
                let q=PixelYX(y:y,x:x)
                if values[q] != nil { changed=true;continue }
                var best:[Float]?,bestCost=Float.infinity
                var minimumEvidence=Float.infinity,testedDirections=0
                let sourceIndex=((q.y-y0)*rw+q.x-x0)*4
                for (dx,dy) in [(1,0),(0,1),(1,1),(1,-1),(2,1),(2,-1),(1,2),(1,-2)] {
                    var left:([Float],Int)?,right:([Float],Int)?
                    for distance in 1...24 {
                        if left == nil,let a=healthy(PixelYX(y:y-dy*distance,x:x-dx*distance)) { left=(a,distance) }
                        if right == nil,let a=healthy(PixelYX(y:y+dy*distance,x:x+dx*distance)) { right=(a,distance) }
                        if left != nil && right != nil { break }
                    }
                    if let left,let right {
                        let cost=(0..<3).reduce(Float(0)) { $0 + abs(left.0[$1]-right.0[$1]) }
                        let t=Float(left.1)/Float(left.1+right.1)
                        let estimate=(0..<3).map { left.0[$0]*(1-t)+right.0[$0]*t }
                        let delta=(0..<3).map { src[sourceIndex+$0]-estimate[$0] }
                        let hi=delta.max() ?? 0,lo=delta.min() ?? 0,level=max(0,estimate.max() ?? 0)
                        let threshold=max(Float(0.0015),level*0.02)
                        let colorEvidence=min(hi/threshold,(hi-lo)/threshold)
                        let whiteEvidence=min(hi/threshold,lo/max(Float(0.008),level*0.08))
                        minimumEvidence=min(minimumEvidence,max(colorEvidence,whiteEvidence));testedDirections += 1
                        if cost<bestCost { bestCost=cost;best=estimate }
                    }
                }
                if best == nil,fallback[0].count>=8 { best=fallback.map(median) }
                if let best {
                    proposed[q]=best
                    if max(abs(q.x-p.x),abs(q.y-p.y)) <= 2 {
                        if testedDirections >= 2 {
                            if minimumEvidence>1 { active=true }
                        } else if fallback[0].count>=8 {
                            let base=fallback.map(median)
                            let noise=(0..<3).map { c in median(fallback[c].map { abs($0-base[c]) })*1.4826 }.max() ?? 0
                            let delta=(0..<3).map { src[sourceIndex+$0]-base[$0] }
                            let hi=delta.max() ?? 0,lo=delta.min() ?? 0,level=max(0,base.max() ?? 0)
                            let threshold=max(Float(0.003),max(noise*6,level*0.04))
                            if hi>threshold && (hi-lo>threshold || lo>max(Float(0.01),level*0.1)) { active=true }
                        }
                    }
                }
            } }
            if active { for (q,value) in proposed where values[q] == nil { values[q]=value };changed=true }
            if changed { repaired += 1 } else { skipped += 1 }
        }
        guard !values.isEmpty else { return PixelRepairOutcome(image:image,repaired:repaired,skipped:skipped) }
        let provider=SparsePixelProvider(values:values,height:h)
        let overlay=CIImage(imageProvider:provider,size:w,h,format:.RGBAf,colorSpace:linear,options:[.providerTileSize:256])
            .transformed(by:CGAffineTransform(translationX:b.minX,y:b.minY))
        return PixelRepairOutcome(image:overlay.composited(over:image).cropped(to:b),repaired:repaired,skipped:skipped)
    }
}
