// SPDX-License-Identifier: MIT
import Foundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct ConversionResult {
    let source: URL
    let destination: URL
    let sourceBytes: Int64
    let outputBytes: Int64
    let width: Int
    let height: Int
    let trashedOriginal: Bool
    let trashWarning: String?
    let pixelRepairLog: String
    let lutLog: String
}

enum ConversionError: LocalizedError {
    case decodeFailed
    case invalidDimensions
    case missingColorSpace
    case outputInvalid

    var errorDescription: String? {
        switch self {
        case .decodeFailed: return "macOS 无法解码此 3FR 的完整 RAW 图像。"
        case .invalidDimensions: return "RAW 图像尺寸无效。"
        case .missingColorSpace: return "无法创建输出色彩空间。"
        case .outputInvalid: return "写入的 HEIC 文件未通过尺寸与格式核验。"
        }
    }
}

enum Converter {
    static func convert(_ source: URL, to outputFolder: URL, quality: Double, useP3: Bool, trashOriginal: Bool, pixelRepair: PixelRepairOptions = PixelRepairOptions(), lut: LUTPreset? = nil) throws -> ConversionResult {
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: source.path)
        let inputBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        try manager.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        guard let raw = CIRAWFilter(imageURL: source) else { throw ConversionError.decodeFailed }
        raw.isDraftModeEnabled = false
        guard let decoded = raw.outputImage else { throw ConversionError.decodeFailed }
        var metadata = decoded.properties
        if let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
           let sourceProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] {
            for key in [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary,
                        kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
                if let value = sourceProperties[key as String] { metadata[key as String] = value }
            }
        }
        var image = decoded.settingProperties(metadata)
        var pixelRepairLog = "Pixel repair: disabled"
        if pixelRepair.enabled {
            do {
                let identity = try SensorIdentity(raw: raw, image: decoded)
                let capture = CalibrationPlanner.capture(raw)
                let library = pixelRepair.profiles.isEmpty ? pixelRepair.profile.map { [$0] } ?? [] : pixelRepair.profiles
                var profile = try HotPixelCatalog.select(library, identity: identity, iso: capture.iso, exposure: capture.exposure)
                try profile.validate()
                try profile.matches(identity, manuallyBound: pixelRepair.manuallyBound)
                let repaired = HotPixelEngine.repair(decoded, regions: profile.repairRegions, context: HotPixelEngine.context())
                var processed=repaired.image
                var clusterLog="cluster cleanup: off"
                if pixelRepair.cleanupImpulses {
                    do {
                        let clean=try ImpulseCleaner.clean(processed,signatures:profile.impulse_signatures ?? [],context:HotPixelEngine.context())
                        processed=clean.image
                        clusterLog="cluster match events: \(clean.matched)/\(clean.candidates), pixel write events: \(clean.changedPixels), \(clean.note)"
                    } catch { clusterLog="cluster cleanup skipped: \(error.localizedDescription)" }
                }
                image = processed.settingProperties(metadata)
                pixelRepairLog = "Pixel repair: enabled | profile: \(profile.profile_id) | ISO: \(capture.iso ?? 0) | template ISO sources: \(profile.template_iso_sources ?? []) | pixels: \(repaired.repaired) | skipped: \(repaired.skipped) | post-demosaic RGB | \(clusterLog)"
            } catch {
                pixelRepairLog = "Pixel repair: warning | skipped | \(error.localizedDescription)"
            }
        }
        // Repair always sees the ungraded RAW rendering. A nil LUT is an exact bypass.
        image = try ColorLUTEngine.apply(image, preset: lut)
        let lutLog = lut.map { "LUT: \($0.label) | \($0.inputSpace) | after pixel repair" } ?? "LUT: disabled"
        let bounds = image.extent.integral
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else {
            throw ConversionError.invalidDimensions
        }
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        let colorSpaceName: CFString = useP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        guard let colorSpace = CGColorSpace(name: colorSpaceName) else { throw ConversionError.missingColorSpace }

        let destination = outputFolder.appendingPathComponent(source.deletingPathExtension().lastPathComponent).appendingPathExtension("heic")
        let temporary = outputFolder.appendingPathComponent(".\(UUID().uuidString).heic")
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false
        ])
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
        ]
        defer { try? manager.removeItem(at: temporary) }
        do {
            try context.writeHEIF10Representation(of: image, to: temporary, colorSpace: colorSpace, options: options)
        } catch {
            guard pixelRepairLog.hasPrefix("Pixel repair: enabled") else { throw error }
            try? manager.removeItem(at: temporary)
            pixelRepairLog = "Pixel repair: warning | render failed, converted without repair | \(error.localizedDescription)"
            // The repair fallback must retain the chosen grade. LUT failures propagate;
            // never report success or trash the RAW after silently dropping the LUT.
            let fallback = try ColorLUTEngine.apply(decoded.settingProperties(metadata), preset: lut)
            try context.writeHEIF10Representation(of: fallback, to: temporary, colorSpace: colorSpace, options: options)
        }

        guard let check = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              let type = CGImageSourceGetType(check),
              UTType(type as String)?.conforms(to: .heic) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int) == width,
              (properties[kCGImagePropertyPixelHeight] as? Int) == height,
              (properties[kCGImagePropertyDepth] as? Int ?? 0) >= 10,
              let profile = properties[kCGImagePropertyProfileName] as? String,
              profile.localizedCaseInsensitiveContains(useP3 ? "P3" : "sRGB") else {
            throw ConversionError.outputInvalid
        }
        let outputBytes = ((try manager.attributesOfItem(atPath: temporary.path))[.size] as? NSNumber)?.int64Value ?? 0
        guard outputBytes > 0 else { throw ConversionError.outputInvalid }

        if manager.fileExists(atPath: destination.path) { throw CocoaError(.fileWriteFileExists) }
        try manager.moveItem(at: temporary, to: destination)
        if let created = attributes[.creationDate] as? Date {
            try? manager.setAttributes([.creationDate: created], ofItemAtPath: destination.path)
        }
        if let modified = attributes[.modificationDate] as? Date {
            try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
        }
        var trashedOriginal = false
        var trashWarning: String?
        if trashOriginal {
            do {
                try manager.trashItem(at: source, resultingItemURL: nil)
                trashedOriginal = true
            } catch {
                trashWarning = "HEIC 已保存，但原始 3FR 未能移入废纸篓：\(error.localizedDescription)"
            }
        }
        return ConversionResult(source: source, destination: destination, sourceBytes: inputBytes,
                                outputBytes: outputBytes, width: width, height: height,
                                trashedOriginal: trashedOriginal, trashWarning: trashWarning, pixelRepairLog: pixelRepairLog, lutLog: lutLog)
    }
}

