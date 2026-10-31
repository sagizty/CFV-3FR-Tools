// SPDX-License-Identifier: MIT
import Foundation
import CoreImage
import ImageIO
import CryptoKit

@main struct LUTConversionTests {
    static func main() throws {
        setbuf(stdout,nil)
        guard CommandLine.arguments.count >= 3 else { fatalError("Pass a real 3FR and a private LUT resource directory; optionally a calibration catalog") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let before = SHA256.hash(data: try Data(contentsOf: source))
        let presets = try LUTLibrary.load(from: URL(fileURLWithPath: CommandLine.arguments[2]))
        let requested = CommandLine.arguments.dropFirst(4).first
        let chosen = requested.flatMap { id in presets.first { $0.id == id } }
            ?? (requested == nil ? presets.first(where: { $0.name.contains("1930") }) ?? presets.first : nil)
        guard let preset = chosen else { fatalError("Requested LUT not found") }
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("cfv-lut-integration-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        let ungraded = try Converter.convert(source,to:stage.appendingPathComponent("none"),quality:0.92,useP3:true,trashOriginal:false)
        print("PASS: no LUT export",ungraded.width,ungraded.height,ungraded.outputBytes)
        precondition(ungraded.lutLog == "LUT: disabled")
        var repair = PixelRepairOptions()
        if CommandLine.arguments.count > 3 {
            repair.enabled = true
            // This opt-in fixture is explicitly supplied as belonging to the same physical back,
            // matching the app's automatic same-back setup/migration behavior.
            repair.manuallyBound = true
            repair.profiles = try HotPixelCatalog.read(URL(fileURLWithPath:CommandLine.arguments[3])).profiles
        }
        let graded = try Converter.convert(source,to:stage.appendingPathComponent("graded"),quality:0.92,useP3:true,trashOriginal:false,pixelRepair:repair,lut:preset)
        precondition(graded.lutLog.contains(preset.name) && graded.width == ungraded.width && graded.height == ungraded.height)
        print("Repair result:", graded.pixelRepairLog)
        if repair.enabled && !graded.pixelRepairLog.hasPrefix("Pixel repair: enabled") {
            throw PixelRepairError("Integration repair did not run: " + graded.pixelRepairLog)
        }
        print("PASS: repair → LUT → 10-bit P3 HEIC",graded.pixelRepairLog,graded.lutLog)
        let srgb = try Converter.convert(source,to:stage.appendingPathComponent("srgb"),quality:0.92,useP3:false,trashOriginal:false,lut:preset)
        precondition(srgb.width == graded.width && srgb.height == graded.height)
        print("PASS: LUT → 10-bit sRGB HEIC",srgb.outputBytes)
        let context = HotPixelEngine.context()
        let region = CGRect(x:0,y:0,width:16,height:16)
        func pixels(_ url: URL) -> [Float] { HotPixelEngine.floats(CIImage(contentsOf:url)!,rect:region,context:context) }
        let originalPixels = pixels(ungraded.destination), gradedPixels = pixels(graded.destination)
        precondition(zip(originalPixels,gradedPixels).contains {abs($0-$1)>0.001},"LUT did not affect encoded HEIC")
        let p3Pixels = pixels(graded.destination), srgbPixels = pixels(srgb.destination)
        precondition(zip(p3Pixels,srgbPixels).allSatisfy {abs($0-$1)<0.015},"sRGB LUT changed grade with output profile")
        print("PASS: HEIC pixels show grade, consistent across P3/sRGB outputs")
        let missing = LUTPreset(id:"missing",group:"test",name:"missing",file:stage.appendingPathComponent("missing.cube"),inputSpace:"sRGB")
        let failInput = stage.appendingPathComponent("failure.3FR")
        try FileManager.default.copyItem(at: source, to: failInput)
        do {
            _ = try Converter.convert(failInput,to:stage.appendingPathComponent("failed"),quality:0.92,useP3:true,trashOriginal:true,lut:missing)
            fatalError("Missing LUT silently accepted")
        } catch { print("PASS: invalid LUT fails before saving/trashing") }
        precondition(FileManager.default.fileExists(atPath:source.path) && FileManager.default.fileExists(atPath:failInput.path))
        precondition(!FileManager.default.fileExists(atPath:stage.appendingPathComponent("failed").appendingPathComponent("failure.heic").path))
        let after = SHA256.hash(data:try Data(contentsOf:source))
        precondition(after == before,"RAW mutated")
        print("PASS: original RAW hash unchanged")
    }
}
