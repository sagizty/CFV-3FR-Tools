// SPDX-License-Identifier: MIT
import Foundation
import CoreImage
import CoreGraphics

enum LUTError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let detail): return "LUT 无法使用：\(detail)" }
    }
}

struct LUTPreset: Identifiable {
    let id: String
    let group: String
    let name: String
    let file: URL
    let inputSpace: String
    var label: String { "\(group) / \(name)" }
}

enum LUTColorSpace {
    static let supported = ["sRGB", "linearSRGB", "displayP3", "rec709Gamma24"]
    // Rec.709 primaries / D65, with a pure 2.4 display gamma. The system ITU-R 709
    // space uses a different transfer function and is not a substitute for this LUT encoding.
    private static let rec709Gamma24: CGColorSpace? = {
        let white: [CGFloat] = [0.95047, 1, 1.08883]
        let gamma: [CGFloat] = [2.4, 2.4, 2.4]
        let matrix: [CGFloat] = [
            0.4124564, 0.2126729, 0.0193339,
            0.3575761, 0.7151522, 0.1191920,
            0.1804375, 0.0721750, 0.9503041
        ]
        return CGColorSpace(calibratedRGBWhitePoint: white, blackPoint: nil,
                            gamma: gamma, matrix: matrix)
    }()
    static func make(_ encoding: String) throws -> CGColorSpace {
        let space: CGColorSpace?
        switch encoding {
        case "sRGB": space = CGColorSpace(name: CGColorSpace.sRGB)
        case "linearSRGB": space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        case "displayP3": space = CGColorSpace(name: CGColorSpace.displayP3)
        case "rec709Gamma24": space = rec709Gamma24
        default: throw LUTError.invalid("未定义的输入色彩空间。")
        }
        guard let space else { throw LUTError.invalid("无法创建 LUT 色彩空间。") }
        return space
    }
}

enum LUTLibrary {
    private struct Entry: Decodable {
        let id: String
        let group: String
        let name: String
        let file: String
        let inputSpace: String
    }
    static func load(from directory: URL?) throws -> [LUTPreset] {
        guard let directory else { return [] }
        let catalog = directory.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: catalog.path) else { return [] }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: catalog))
        var ids = Set<String>()
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return try entries.map { entry in
            let file = directory.appendingPathComponent(entry.file).resolvingSymlinksInPath().standardizedFileURL
            guard !entry.id.isEmpty, ids.insert(entry.id).inserted,
                  !entry.name.isEmpty, !entry.group.isEmpty,
                  file.path.hasPrefix(root), file.pathExtension.lowercased() == "cube",
                  LUTColorSpace.supported.contains(entry.inputSpace),
                  FileManager.default.isReadableFile(atPath: file.path) else {
                throw LUTError.invalid("预设目录无效或文件缺失（\(entry.name)）。")
            }
            return LUTPreset(id: entry.id, group: entry.group, name: entry.name,
                             file: file, inputSpace: entry.inputSpace)
        }
    }
    static func bundled() throws -> [LUTPreset] {
        try load(from: Bundle.main.resourceURL?.appendingPathComponent("LUTs", isDirectory: true))
    }
}

struct CubeLUT {
    let dimension: Int
    let rgba: Data
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>

    // Adobe .cube order: red varies fastest, then green, then blue.
    // Keep code values as supplied. ColorLUTEngine explicitly enters/exits the LUT color space.
    static func parse(_ text: String) throws -> CubeLUT {
        var dimension: Int?
        var lower = SIMD3<Float>(repeating: 0)
        var upper = SIMD3<Float>(repeating: 1)
        var values = [Float]()
        var seen = Set<String>()
        var dataStarted = false
        func triple(_ words: [Substring]) throws -> SIMD3<Float> {
            guard words.count == 3, let r = Float(words[0]), let g = Float(words[1]),
                  let b = Float(words[2]), r.isFinite, g.isFinite, b.isFinite else {
                throw LUTError.invalid("包含无效的 RGB 数值。")
            }
            return SIMD3(r, g, b)
        }
        for rawLine in text.replacingOccurrences(of: "\u{feff}", with: "").split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let words = line.split(whereSeparator: \.isWhitespace)
            guard let first = words.first else { continue }
            let key = String(first)
            if ["TITLE", "LUT_3D_SIZE", "DOMAIN_MIN", "DOMAIN_MAX", "LUT_3D_INPUT_RANGE"].contains(key) {
                guard !dataStarted, seen.insert(key).inserted else {
                    throw LUTError.invalid("头部重复或出现在数据之后。")
                }
                switch key {
                case "TITLE": break
                case "LUT_3D_SIZE":
                    guard words.count == 2, let n = Int(words[1]), (2...128).contains(n) else {
                        throw LUTError.invalid("3D 表格边长必须为 2–128。")
                    }
                    dimension = n
                    values.reserveCapacity(n * n * n * 4)
                case "DOMAIN_MIN": lower = try triple(Array(words.dropFirst()))
                case "DOMAIN_MAX": upper = try triple(Array(words.dropFirst()))
                default:
                    guard words.count == 3, let a = Float(words[1]), let b = Float(words[2]),
                          a.isFinite, b.isFinite else { throw LUTError.invalid("输入范围无效。") }
                    lower = SIMD3(repeating: a); upper = SIMD3(repeating: b)
                }
            } else {
                guard let n = dimension, Float(first) != nil else {
                    throw LUTError.invalid("仅支持独立 3D CUBE；遇到不支持的头部 \(key.prefix(40))。")
                }
                dataStarted = true
                let rgb = try triple(words)
                guard values.count < n * n * n * 4 else { throw LUTError.invalid("表格数据过多。") }
                values.append(contentsOf: [rgb.x, rgb.y, rgb.z, 1])
            }
        }
        guard let n = dimension, values.count == n * n * n * 4 else {
            throw LUTError.invalid("表格数据不足。")
        }
        guard !(seen.contains("LUT_3D_INPUT_RANGE") &&
                (seen.contains("DOMAIN_MIN") || seen.contains("DOMAIN_MAX"))),
              (0..<3).allSatisfy({ upper[$0] > lower[$0] && (upper[$0] - lower[$0]).isFinite }) else {
            throw LUTError.invalid("输入范围冲突或无效。")
        }
        return CubeLUT(dimension: n, rgba: values.withUnsafeBytes { Data($0) },
                       domainMin: lower, domainMax: upper)
    }
}

enum LUTCache {
    private static let lock = NSLock()
    private static var cached: (URL, CubeLUT)?
    static func load(_ preset: LUTPreset) throws -> CubeLUT {
        lock.lock(); defer { lock.unlock() }
        if let value = cached, value.0 == preset.file { return value.1 }
        let cube = try CubeLUT.parse(String(contentsOf: preset.file, encoding: .utf8))
        cached = (preset.file, cube)
        return cube
    }
}

enum ColorLUTEngine {
    static func apply(_ image: CIImage, preset: LUTPreset?) throws -> CIImage {
        guard let preset else { return image }
        return try apply(image, cube: LUTCache.load(preset), inputSpace: preset.inputSpace)
    }
    static func apply(_ image: CIImage, cube: CubeLUT, inputSpace: String) throws -> CIImage {
        let space = try LUTColorSpace.make(inputSpace)
        guard var encoded = image.matchedFromWorkingSpace(to: space),
              let filter = CIFilter(name: "CIColorCube") else {
            throw LUTError.invalid("无法创建色彩处理器。")
        }
        // Index the explicitly declared LUT encoding, never assume linear RAW RGB.
        // Explicit matching also makes the grade independent of the chosen HEIC output profile.
        let scale = SIMD3<Float>(repeating: 1) / (cube.domainMax - cube.domainMin)
        let offset = -cube.domainMin * scale
        encoded = encoded.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(scale.x), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(scale.y), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale.z), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: CGFloat(offset.x), y: CGFloat(offset.y), z: CGFloat(offset.z), w: 0)
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
        filter.setValue(encoded, forKey: kCIInputImageKey)
        filter.setValue(cube.dimension, forKey: "inputCubeDimension")
        filter.setValue(cube.rgba, forKey: "inputCubeData")
        if filter.inputKeys.contains("inputExtrapolate") { filter.setValue(false, forKey: "inputExtrapolate") }
        guard let result = filter.outputImage?.matchedToWorkingSpace(from: space) else {
            throw LUTError.invalid("滤镜没有输出。")
        }
        return result.cropped(to: image.extent).settingProperties(image.properties)
    }
}
