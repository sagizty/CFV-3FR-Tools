// SPDX-License-Identifier: MIT
import Foundation
import CoreImage
import CoreGraphics

@main struct LUTTests {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1
        }
        func rejected(_ text: String) -> Bool {
            do { _ = try CubeLUT.parse(text); return false } catch { return true }
        }
        func table(_ size: Int = 2, header: String = "", transform: (Float, Float, Float) -> SIMD3<Float>) -> String {
            var text = "# fixture\nTITLE \"Test\"\nLUT_3D_SIZE \(size)\n" + header
            for b in 0..<size { for g in 0..<size { for r in 0..<size {
                let n = Float(size - 1), v = transform(Float(r)/n, Float(g)/n, Float(b)/n)
                text += "\(v.x) \(v.y) \(v.z) # sample\n"
            }}}
            return text
        }
        let identityText = table { SIMD3($0, $1, $2) }
        let identity = try CubeLUT.parse("\u{feff}" + identityText)
        check(identity.dimension == 2 && identity.rgba.count == 8*4*4, "dimension/float32 RGBA")
        check(identity.domainMin == .zero && identity.domainMax == SIMD3(repeating: 1), "default domain")
        check(rejected(identityText.replacingOccurrences(of: "LUT_3D_SIZE 2", with: "LUT_3D_SIZE 129")), "size limit")
        check(rejected("LUT_1D_SIZE 2\n0 0 0\n1 1 1"), "reject unsupported 1D")
        check(rejected(identityText + "1 1 1\n"), "reject extra rows")
        check(rejected("LUT_3D_SIZE 2\n0 0 0"), "reject truncation")
        check(rejected(identityText.replacingOccurrences(of: "0.0 0.0 0.0", with: "nan 0 0")), "reject NaN")
        check(rejected(identityText.replacingOccurrences(of: "0.0 0.0 0.0", with: "inf 0 0")), "reject infinity")
        check(rejected("LUT_3D_SIZE 2\nLUT_3D_SIZE 2\n"), "reject duplicate headers")
        check(rejected(identityText + "DOMAIN_MIN 0 0 0"), "reject late headers")
        check(rejected(table(header: "DOMAIN_MIN 1 0 0\nDOMAIN_MAX 0 1 1\n") { SIMD3($0,$1,$2) }), "reject reversed domain")
        check(rejected(table(header: "DOMAIN_MIN 0 0 0\nLUT_3D_INPUT_RANGE 0 1\n") { SIMD3($0,$1,$2) }), "reject conflicting domain")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        check(try LUTLibrary.load(from: root).isEmpty, "empty public library")
        try identityText.write(to: root.appendingPathComponent("identity.cube"), atomically: true, encoding: .utf8)
        func writeCatalog(file: String = "identity.cube", space: String = "sRGB", duplicate: Bool = false) throws {
            let row = ["id":"test", "group":"Test", "name":"Identity", "file":file, "inputSpace":space]
            try JSONSerialization.data(withJSONObject: duplicate ? [row,row] : [row]).write(to: root.appendingPathComponent("catalog.json"))
        }
        func badCatalog() -> Bool { do { _ = try LUTLibrary.load(from: root); return false } catch { return true } }
        try writeCatalog(); check(try LUTLibrary.load(from: root).count == 1, "catalog loaded")
        try writeCatalog(space: "rec709Gamma24"); check(try LUTLibrary.load(from: root).first?.inputSpace == "rec709Gamma24", "Rec.709 Gamma 2.4 catalog accepted")
        try writeCatalog(duplicate: true); check(badCatalog(), "duplicate IDs rejected")
        try writeCatalog(file: "../outside.cube"); check(badCatalog(), "path escape rejected")
        try writeCatalog(space: "LogMystery"); check(badCatalog(), "unknown color encoding rejected")
        try writeCatalog(file: "missing.cube"); check(badCatalog(), "missing preset rejected")

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let contexts = [linear, CGColorSpace(name: CGColorSpace.displayP3)!].map {
            CIContext(options: [.workingColorSpace: $0, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        }
        let samples: [Float] = [0.2,0.5,0.8,1, 0.9,0.25,0.1,1, 0,0,0,1, 1,1,1,1]
        let input = CIImage(bitmapData: samples.withUnsafeBytes { Data($0) }, bytesPerRow: 4*4*4,
                            size: CGSize(width: 4,height: 1), format: .RGBAf, colorSpace: srgb)
        func pixels(_ image: CIImage, _ context: CIContext, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> [Float] {
            var values = [Float](repeating: -999, count: 16)
            context.render(image, toBitmap: &values, rowBytes: 4*4*4, bounds: CGRect(x:0,y:0,width:4,height:1), format: .RGBAf, colorSpace: space)
            return values
        }
        func close(_ a: [Float], _ b: [Float], _ tolerance: Float = 0.004) -> Bool {
            zip(a,b).allSatisfy { abs($0-$1) < tolerance }
        }
        let bypass = try ColorLUTEngine.apply(input, preset: nil)
        check(bypass === input, "nil LUT must be exact graph bypass")
        let swapped = try CubeLUT.parse(table { SIMD3($2,$1,$0) })
        let square = try CubeLUT.parse(table(17) { SIMD3($0*$0,$1*$1,$2*$2) })
        for context in contexts {
            check(close(pixels(try ColorLUTEngine.apply(input,cube:identity,inputSpace:"sRGB"),context), samples), "identity/color management")
            var expected = samples
            for i in stride(from:0,to:16,by:4) { expected[i] = samples[i+2]; expected[i+2] = samples[i] }
            check(close(pixels(try ColorLUTEngine.apply(input,cube:swapped,inputSpace:"sRGB"),context),expected), "RGB cube order")
            expected = samples
            for i in 0..<16 where i%4 != 3 { expected[i] = samples[i]*samples[i] }
            check(close(pixels(try ColorLUTEngine.apply(input,cube:square,inputSpace:"sRGB"),context),expected), "gamma-encoded grading, not linear RAW lookup")
        }
        let gamma24 = try LUTColorSpace.make("rec709Gamma24")
        let gammaInput = CIImage(bitmapData: samples.withUnsafeBytes { Data($0) }, bytesPerRow: 4*4*4,
                                 size: CGSize(width:4,height:1), format:.RGBAf, colorSpace:gamma24)
        var gammaLinear = samples
        for i in 0..<16 where i%4 != 3 { gammaLinear[i] = pow(samples[i],2.4) }
        for context in contexts {
            check(close(pixels(gammaInput,context,space:linear),gammaLinear,0.002), "Rec.709 primaries and true 2.4 transfer verified numerically")
            check(close(pixels(try ColorLUTEngine.apply(gammaInput,cube:identity,inputSpace:"rec709Gamma24"),context,space:gamma24),samples), "Rec.709 gamma identity round trip")
            var expected = samples
            for i in 0..<16 where i%4 != 3 { expected[i] *= samples[i] }
            check(close(pixels(try ColorLUTEngine.apply(gammaInput,cube:square,inputSpace:"rec709Gamma24"),context,space:gamma24),expected), "Rec.709 cube uses gamma-encoded coordinates")
        }
        let ranged = try CubeLUT.parse(table(header:"DOMAIN_MIN 0.25 0.25 0.25\nDOMAIN_MAX 0.75 0.75 0.75\n") { SIMD3($0,$1,$2) })
        var normalized = samples
        for i in 0..<16 where i%4 != 3 { normalized[i] = max(0,min(1,(samples[i]-0.25)/0.5)) }
        check(close(pixels(try ColorLUTEngine.apply(input,cube:ranged,inputSpace:"sRGB"),contexts[0]), normalized), "domain normalization and edge clamping")
        let tagged = input.settingProperties(["test":"metadata"]).transformed(by: CGAffineTransform(translationX: 5,y: 7))
        let graded = try ColorLUTEngine.apply(tagged,cube:identity,inputSpace:"sRGB")
        check(graded.extent == tagged.extent && graded.properties["test"] as? String == "metadata", "extent/origin and metadata retained")

        if CommandLine.arguments.count > 1 {
            let presets = try LUTLibrary.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
            let expectedCount = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init)
            check(!presets.isEmpty && (expectedCount == nil || presets.count == expectedCount), "expected unique preset count")
            if expectedCount == 36 {
                let kodak = presets.filter { $0.group == "Kodak 克罗姆系列" }
                check(Set(kodak.map(\.name)) == ["Kodok 克罗姆 1930s", "Kodok 克罗姆 64 调整"], "only requested Kodak looks retained")
                check(presets.filter { $0.inputSpace == "rec709Gamma24" }.count == 34, "34 Fuji looks use declared Rec.709 Gamma 2.4")
            }
            for preset in presets {
                let cube = try LUTCache.load(preset)
                print("Validating:",preset.label,preset.inputSpace,cube.dimension)
                check((2...128).contains(cube.dimension), "actual supplied CUBE parses")
                let lutSpace = try LUTColorSpace.make(preset.inputSpace)
                let testInput = CIImage(bitmapData: samples.withUnsafeBytes { Data($0) }, bytesPerRow: 4*4*4,
                                        size: CGSize(width:4,height:1), format:.RGBAf, colorSpace:lutSpace)
                let output = pixels(try ColorLUTEngine.apply(testInput,preset:preset),contexts[0],space:lutSpace)
                check(output.allSatisfy(\.isFinite) && !close(output,samples,0.01), "actual LUT renders and changes colors")
                // Compare GPU interpolation against an independent CPU trilinear lookup.
                let values = cube.rgba.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                var reference = samples
                for i in stride(from:0,to:16,by:4) {
                    let c = (0..<3).map { Double(samples[i+$0]) * Double(cube.dimension-1) }
                    let lo = c.map { Int(floor($0)) }, hi = lo.map { min($0+1,cube.dimension-1) }
                    let f = (0..<3).map { c[$0]-Double(lo[$0]) }
                    for channel in 0..<3 {
                        var sum = 0.0
                        for b in 0...1 { for g in 0...1 { for r in 0...1 {
                            let x = r == 0 ? lo[0] : hi[0], y = g == 0 ? lo[1] : hi[1], z = b == 0 ? lo[2] : hi[2]
                            let weight = (r == 0 ? 1-f[0] : f[0]) * (g == 0 ? 1-f[1] : f[1]) * (b == 0 ? 1-f[2] : f[2])
                            sum += Double(values[4*(x+cube.dimension*y+cube.dimension*cube.dimension*z)+channel]) * weight
                        }}}
                        reference[i+channel] = Float(sum)
                    }
                }
                check(close(output,reference,0.006), "actual CUBE matches independent CPU reference")
            }
        }
        print("PASS LUT: \(count) checks")
    }
}
