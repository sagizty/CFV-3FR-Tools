// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum CalibrationStage {case idle,scanning,building,saved,failed}

@MainActor final class HotPixelModel:ObservableObject {
    private let preferences:UserDefaults
    private let storeURL:URL
    @Published var cleanupImpulses:Bool {didSet {preferences.set(cleanupImpulses,forKey:"hotClusterCleanup")}}
    @Published var enabled=false {didSet {preferences.set(enabled,forKey:"hotPixelEnabled")}}
    @Published var ratio:Double {didSet {preferences.set(ratio,forKey:"hotConfirmRatio")}}
    @Published var catalog=HotPixelCatalog(profiles:[])
    @Published var folder:URL?
    @Published var busy=false
    @Published var progress=0.0
    @Published var stage=CalibrationStage.idle
    @Published var message="选择黑场文件夹后，App 会自动分析、建立并保存标定策略。"
    @Published var issues:[String]=[]
    @Published var showSheet=false
    var profiles:[HotPixelProfile] {catalog.profiles}
    var usableProfiles:[HotPixelProfile] {profiles.filter {$0.enabled && $0.schema_version==2 && $0.coordinate_revision=="ci_bottom_left_normalized_v2"}}
    var options:PixelRepairOptions {PixelRepairOptions(enabled:enabled,manuallyBound:catalog.same_back_confirmed,profiles:profiles,cleanupImpulses:cleanupImpulses)}
    var isoSummary:String {
        let values=Array(Set(usableProfiles.compactMap {$0.calibration.iso})).sorted()
        return values.isEmpty ? "通用参考模板" : "ISO "+values.map(String.init).joined(separator:" / ")
    }
    var statusTitle:String {
        switch stage {
        case .idle:return usableProfiles.isEmpty ? "尚未建立标定策略" : "标定策略已就绪"
        case .scanning:return "正在识别黑场"
        case .building:return "正在建立标定策略"
        case .saved:return "标定策略已自动保存"
        case .failed:return "本次标定未完成"
        }
    }
    static var store:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("org.cfvheic.converter",isDirectory:true).appendingPathComponent("HotPixelTemplates.json")
    }
    init(storeURL:URL?=nil,preferences:UserDefaults = .standard) {
        self.preferences=preferences;self.storeURL=storeURL ?? Self.store
        cleanupImpulses=preferences.object(forKey:"hotClusterCleanup") as? Bool ?? true
        let savedRatio=preferences.object(forKey:"hotConfirmRatio") as? Double ?? 0.8
        ratio=savedRatio.isFinite && (0.5...1).contains(savedRatio) ? savedRatio : 0.8
        let legacy=self.storeURL.deletingLastPathComponent().appendingPathComponent("HotPixelMap.json")
        let existing=FileManager.default.fileExists(atPath:self.storeURL.path) ? self.storeURL : legacy
        do {
            if FileManager.default.fileExists(atPath:existing.path) {
                var loaded=try HotPixelCatalog.read(existing)
                if !loaded.same_back_confirmed && loaded.profiles.contains(where:{$0.schema_version==2}) {
                    loaded.same_back_confirmed=true
                    try loaded.write(self.storeURL)
                }
                catalog=loaded
                message=usableProfiles.isEmpty ? "选择黑场文件夹，自动更新标定策略。" : "已自动载入保存的标定策略，转换时自动匹配 ISO。"
            }
            enabled=catalog.same_back_confirmed && !usableProfiles.isEmpty && preferences.bool(forKey:"hotPixelEnabled")
        } catch {stage = .failed;message="标定策略读取或保存失败：\(error.localizedDescription)"}
    }
    func chooseFolder() {
        guard !busy else{return}
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true
        panel.allowsMultipleSelection=false;panel.prompt="选择标定文件夹"
        if panel.runModal() == .OK,let url=panel.url {scan(url)}
    }
    func scan(_ url:URL) {
        guard !busy else{return}
        folder=url;issues=[];busy=true;progress=0;stage = .scanning
        message="正在查找文件夹及子文件夹中的黑场 3FR…"
        let previous=catalog,ratio=ratio,destination=storeURL
        Task.detached(priority:.userInitiated) { [weak self] in
            do {
                let plan=try CalibrationPlanner.scan(url) {value,text in
                    Task { @MainActor [weak self] in
                        guard let self,self.busy,self.stage == .scanning else{return}
                        self.progress=max(self.progress,value*0.18);self.message=text
                    }
                }
                await MainActor.run { [weak self] in self?.stage = .building;self?.progress=0.18 }
                let result=try AutomaticCalibration.buildAndSave(plan,previous:previous,ratio:ratio,destination:destination) {value,text in
                    Task { @MainActor [weak self] in
                        guard let self,self.busy,self.stage == .building else{return}
                        self.progress=max(self.progress,0.18+value*0.81);self.message=text
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else{return}
                    self.catalog=result.catalog;self.issues=result.issues
                    self.progress=1;self.stage = .saved;self.busy=false
                    self.message="找到 \(plan.blackCount) 张黑场，已自动保存 \(result.generated.count) 组模板。"+(self.enabled ? "后续转换会自动应用。" : "转换时勾选“应用标定模板”即可使用。")
                }
            } catch {
                await MainActor.run { [weak self] in self?.busy=false;self?.stage = .failed;self?.message=error.localizedDescription }
            }
        }
    }
    func drop(_ providers:[NSItemProvider])->Bool {
        guard !busy,providers.count==1,let provider=providers.first else{return false}
        provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { [weak self] item,_ in
            let url:URL?
            if let value=item as? URL {url=value}
            else if let data=item as? Data {url=URL(dataRepresentation:data,relativeTo:nil)}
            else {url=nil}
            if let url {Task { @MainActor [weak self] in self?.scan(url)}}
        }
        return true
    }
}

struct HotPixelControls:View {
    @ObservedObject var model:HotPixelModel
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Toggle("转换 3FR 时应用标定模板",isOn:$model.enabled)
                    .disabled(model.usableProfiles.isEmpty || !model.catalog.same_back_confirmed || model.busy)
                Spacer()
                Button("设置标定模板…") {model.showSheet=true}
                    .popover(isPresented:$model.showSheet,arrowEdge:.bottom) {HotPixelSheet(model:model)}
            }
            if model.busy {
                ProgressView(value:model.progress)
                Text(model.statusTitle+" · "+model.message).font(.caption).foregroundStyle(.secondary)
            } else if !model.usableProfiles.isEmpty {
                Text("\(model.isoSummary) · 自动匹配 · 策略已保存").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("选择一次黑场文件夹，自动建立标定策略。").font(.caption).foregroundStyle(.secondary)
            }
            if model.stage == .failed {Text(model.message).font(.caption).foregroundStyle(.orange)}
        }.padding(12).background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:10))
    }
}

struct HotPixelSheet:View {
    @ObservedObject var model:HotPixelModel
    private func step(_ number:String,_ title:String,_ detail:String)->some View {
        HStack(alignment:.top,spacing:12) {
            Text(number).font(.caption.bold()).foregroundStyle(.secondary)
                .frame(width:24,height:24).background(.quaternary,in:Circle())
            VStack(alignment:.leading,spacing:3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                VStack(alignment:.leading,spacing:6) {
                    Text("设置标定模板").font(.title2.bold())
                    Text("选择这台后背拍摄的黑场文件夹，其余交给 App 自动完成。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("选择标定文件夹") {model.chooseFolder()}
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
                if let folder=model.folder {
                    Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                VStack(alignment:.leading,spacing:14) {
                    step("1","自动识别黑场","扫描文件夹及子文件夹，筛选接近全黑的 3FR，跳过普通照片和不可读文件。")
                    step("2","自动分析 ISO","按 ISO 和曝光分组，每组自动选取 8–12 张黑场，分别建立处理模板。")
                    step("3","自动保存策略","完成检测即保存，更新对应分组并保留其他已有模板，无需手动确认。")
                }
                VStack(alignment:.leading,spacing:8) {
                    Label(model.statusTitle,systemImage:model.busy ? "hourglass" : (model.stage == .failed ? "exclamationmark.circle" : (model.usableProfiles.isEmpty ? "circle.dashed" : "checkmark.circle")))
                        .font(.callout.weight(.medium))
                    if model.busy {ProgressView(value:model.progress)}
                    Text(model.message).font(.caption).foregroundStyle(model.stage == .failed ? Color.orange : Color.secondary)
                        .fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                    if !model.usableProfiles.isEmpty {Text(model.isoSummary).font(.caption.weight(.medium))}
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:10))
                Text("转换优先参考相同 ISO，其次选最接近的 ISO；照片未记录 ISO 时参考最低 ISO。各组共享已标定的固定坏点和形状，一组模板也可跨 ISO 使用。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                DisclosureGroup("拍摄说明") {
                    Text("盖紧镜头盖并可靠遮光，机背保持正常工作温度。每个 ISO 建议拍 10 张黑场 3FR，同组曝光时间一致。可把多个 ISO 放进同一文件夹；只拍一个 ISO 也能使用。默认素材来自同一后背，无需白场。")
                        .font(.caption).foregroundStyle(.secondary).padding(.top,6)
                }
                DisclosureGroup("高级选项") {
                    VStack(alignment:.leading,spacing:12) {
                        HStack {
                            Text("重复检测比例").font(.caption)
                            Slider(value:$model.ratio,in:0.5...1,step:0.05)
                            Text("\(Int((model.ratio*100).rounded()))%").font(.caption.monospacedDigit()).frame(width:36)
                        }
                        Toggle("补充清理逐张出现的小型彩点簇",isOn:$model.cleanupImpulses).font(.caption)
                        Text("星空或微小彩灯可能与彩点形状相似，此时可关闭补充清理，保留固定点修复。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top,6).disabled(model.busy)
                }
                if !model.issues.isEmpty {
                    DisclosureGroup("处理详情（\(model.issues.count)）") {
                        Text(model.issues.joined(separator:"\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Text("也可直接拖入文件夹。点击面板外可收起，标定会在后台继续。")
                    .font(.caption).foregroundStyle(.tertiary)
            }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
        }.frame(width:560,height:650)
            .onDrop(of:[UTType.fileURL],isTargeted:nil) {model.drop($0)}
    }
}
