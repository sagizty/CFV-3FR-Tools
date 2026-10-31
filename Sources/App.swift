// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

private struct FileStamp: Equatable {
    let size: Int64
    let modified: Date
}

private func droppedFileURL(_ item: NSSecureCoding?) -> URL? {
    if let url = item as? URL { return url }
    if let data = item as? Data {
        return URL(dataRepresentation: data, relativeTo: nil)
    }
    if let text = item as? String { return URL(string: text) }
    return nil
}

@MainActor
final class AppModel: ObservableObject {
    let repair = HotPixelModel()
    let lutPresets: [LUTPreset]
    let lutLibraryWarning: String?
    @Published var selectedLUTID = "" {
        didSet { UserDefaults.standard.set(selectedLUTID, forKey: "selectedLUTID") }
    }
    var selectedLUT: LUTPreset? { lutPresets.first { $0.id == selectedLUTID } }
    var lutGroups: [String] {
        var seen = Set<String>()
        return lutPresets.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }
    @Published var folder: URL?
    @Published var quality = 0.92
    @Published var useP3 = true
    @Published var trashOriginal = false
    @Published var watching = false
    @Published var isDropTargeted = false
    @Published var busy = false
    @Published var converted = 0
    @Published var skipped = 0
    @Published var failures = 0
    @Published var sourceBytes: Int64 = 0
    @Published var outputBytes: Int64 = 0
    @Published var status = "请选择包含 3FR 的文件夹。"
    @Published var log: [String] = []

    private var timer: Timer?
    private var previous: [URL: FileStamp] = [:]
    private var queued = Set<URL>()
    private var queue: [URL] = []
    private var failedStamps: [URL: FileStamp] = [:]

    init() {
        do {
            lutPresets = try LUTLibrary.bundled()
            lutLibraryWarning = nil
        } catch {
            lutPresets = []
            lutLibraryWarning = error.localizedDescription
        }
        let saved = UserDefaults.standard.string(forKey: "selectedLUTID") ?? ""
        if lutPresets.contains(where: { $0.id == saved }) { selectedLUTID = saved }
        if let path = UserDefaults.standard.string(forKey: "selectedFolder"),
           FileManager.default.fileExists(atPath: path) {
            folder = URL(fileURLWithPath: path, isDirectory: true)
            status = "已选择文件夹。点击“转换现有文件”开始。"
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            setFolder(url)
        }
    }

    func acceptDroppedFolder(_ providers: [NSItemProvider]) -> Bool {
        guard providers.count == 1,
              let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            status = "请一次拖入一个文件夹。"
            return false
        }
        status = "正在读取拖入的文件夹…"
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
            let url = droppedFileURL(item)
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let url, url.isFileURL else {
                    self.status = message ?? "无法读取拖入的文件夹。"
                    return
                }
                self.setFolder(url)
            }
        }
        return true
    }

    private func setFolder(_ url: URL) {
        let normalized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            status = "请拖入文件夹，而不是单个文件。"
            return
        }
        stopWatching()
        folder = normalized
        UserDefaults.standard.set(normalized.path, forKey: "selectedFolder")
        previous.removeAll()
        queued.removeAll()
        queue.removeAll()
        failedStamps.removeAll()
        status = "已选择 \(normalized.lastPathComponent)。点击“转换现有文件”开始。"
    }

    func convertExisting() { scan(requireStable: false) }

    func toggleWatching() {
        if watching {
            stopWatching()
            status = "文件夹监视已停止。"
        } else {
            guard folder != nil else { return }
            watching = true
            previous.removeAll()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.scan(requireStable: true) }
            }
            scan(requireStable: true)
            status = "正在监视文件夹；新文件大小稳定后会自动转换。"
        }
    }

    private func stopWatching() {
        watching = false
        timer?.invalidate()
        timer = nil
    }

    private func scan(requireStable: Bool) {
        guard let folder else { return }
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            status = "无法读取文件夹，请重新选择。"
            return
        }
        var current: [URL: FileStamp] = [:]
        let files = contents.filter { $0.pathExtension.lowercased() == "3fr" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, let modified = values.contentModificationDate else { continue }
            let stamp = FileStamp(size: Int64(size), modified: modified)
            current[url] = stamp
            if requireStable && previous[url] != stamp { continue }
            if requireStable && failedStamps[url] == stamp { continue }
            if queued.contains(url) { continue }
            let output = folder.appendingPathComponent("HEIC", isDirectory: true)
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("heic")
            if manager.fileExists(atPath: output.path) {
                if !requireStable { skipped += 1 }
                continue
            }
            queued.insert(url)
            queue.append(url)
        }
        previous = current
        if !queue.isEmpty { processNext() }
        else if !requireStable { status = "扫描完成：发现 \(files.count) 张 3FR，没有待转换文件。" }
    }

    private func processNext() {
        guard !busy, !queue.isEmpty, let folder else { return }
        busy = true
        let source = queue.removeFirst()
        let output = folder.appendingPathComponent("HEIC", isDirectory: true)
        let quality = self.quality
        let useP3 = self.useP3
        let trashOriginal = self.trashOriginal
        let pixelRepair = repair.options
        let lut = selectedLUT
        status = "正在转换 \(source.lastPathComponent)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try Converter.convert(source, to: output, quality: quality, useP3: useP3, trashOriginal: trashOriginal, pixelRepair: pixelRepair, lut: lut) }
            await self?.finish(source: source, result: result)
        }
    }

    private func finish(source: URL, result: Result<ConversionResult, Error>) {
        busy = false
        queued.remove(source)
        switch result {
        case .success(let item):
            converted += 1
            log.insert(item.pixelRepairLog, at: 0)
            log.insert(item.lutLog, at: 0)
            sourceBytes += item.sourceBytes
            outputBytes += item.outputBytes
            status = "已转换 \(item.source.lastPathComponent) → \(item.destination.lastPathComponent)"
            log.insert("✓ \(item.source.lastPathComponent)  \(item.width)×\(item.height)  \(format(item.sourceBytes)) → \(format(item.outputBytes))", at: 0)
            if item.trashedOriginal { log.insert("↪ 原始 3FR 已移入废纸篓", at: 0) }
            if let warning = item.trashWarning { log.insert("! \(warning)", at: 0) }
        case .failure(let error):
            failures += 1
            if let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
               let size = values.fileSize, let modified = values.contentModificationDate {
                failedStamps[source] = FileStamp(size: Int64(size), modified: modified)
            }
            status = "转换失败：\(source.lastPathComponent)"
            log.insert("✕ \(source.lastPathComponent)：\(error.localizedDescription)", at: 0)
        }
        if log.count > 100 { log.removeLast() }
        processNext()
    }

    func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CFV 3FR → HEIC").font(.title.bold())
                    Text("初代 Hasselblad CFV-50c · 原尺寸 · 10-bit HEIC")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 52, height: 52)
            }
            HStack {
                VStack(alignment: .leading) {
                    Text("来源文件夹").font(.headline)
                    Text(model.folder?.path ?? "尚未选择")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    Text("可从 Finder 将文件夹拖入此窗口")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("选择文件夹…") { model.chooseFolder() }
            }
            .padding(12)
            .background(model.isDropTargeted ? Color.accentColor.opacity(0.14) : Color(nsColor: .quaternaryLabelColor).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(model.isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2))

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Display P3 广色域", isOn: $model.useP3)
                    .help("关闭后使用 sRGB，以获得更广的兼容性。")
                HStack {
                    Text("画质")
                    Slider(value: $model.quality, in: 0.80...1.00, step: 0.01)
                    Text("\(Int(model.quality * 100))%")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text("默认 92%：优先保留细节与颜色，同时减小文件。HEIC 是有损的，不能保留 RAW 的重新显影能力。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("转换成功并核验后，将原始 3FR 移入废纸篓", isOn: $model.trashOriginal)
                    .help("默认关闭。只有新 HEIC 已保存并通过格式、10-bit、尺寸和色彩空间检查后才移动原始文件。")
            }
            .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            HotPixelControls(model: model.repair)

            VStack(alignment: .leading, spacing: 6) {
                Picker("LUT 风格", selection: $model.selectedLUTID) {
                    Text("不加 LUT").tag("")
                    ForEach(model.lutGroups, id: \.self) { group in
                        Section(header: Text(group)) {
                            ForEach(model.lutPresets.filter { $0.group == group }) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                    }
                }
                .disabled(model.busy || model.watching)
                Text("先修复坏点，再统一套用所选 LUT。已存在的 HEIC 会跳过；更换风格后请先移走旧输出。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.busy || model.watching {
                    Text("转换或自动监视期间，LUT 选择已锁定。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let warning = model.lutLibraryWarning {
                    Text(warning).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("转换现有文件") { model.convertExisting() }
                    .buttonStyle(.borderedProminent).disabled(model.folder == nil)
                Button(model.watching ? "停止自动监视" : "自动监视新文件") { model.toggleWatching() }
                    .disabled(model.folder == nil)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(model.status).font(.callout)
                Text("成功 \(model.converted) · 跳过 \(model.skipped) · 失败 \(model.failures)")
                    .foregroundStyle(.secondary)
                if model.converted > 0 {
                    Text("已处理：\(model.format(model.sourceBytes)) → \(model.format(model.outputBytes))")
                        .foregroundStyle(.secondary)
                }
                Text("输出位置：来源文件夹 / HEIC；原始 3FR \(model.trashOriginal ? "核验后移入废纸篓" : "保留不动")。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("转换记录").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, item in
                        Text(item).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minHeight: 130)
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 840)
        .onDrop(of: [UTType.fileURL], isTargeted: $model.isDropTargeted) { providers in
            model.acceptDroppedFolder(providers)
        }
    }
}

@main
struct CFVHEICApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
