# 使用细节 / Advanced usage

[返回首页 / Back to README](../README.md)

## 文件与监视 / Files and monitoring

普通转换只扫描所选文件夹本层；黑场标定会递归扫描子文件夹。自动监视约每 5 秒检查一次，文件大小和修改时间稳定后才加入转换队列。已有同名 HEIC 会跳过，切换 LUT、画质或修复设置后应先移走旧输出。

Photo conversion scans the chosen folder only; dark-frame calibration searches subfolders. Monitoring checks about every five seconds and waits for file size and modification time to stabilize. Existing same-name HEIC files are skipped; move them before reconverting with another look, quality, or repair setting.

“转换成功并核验后，将原始 3FR 移入废纸篓”默认关闭。开启时，App 检查新 HEIC 的格式、尺寸、位深和色彩空间后才移动原片；这不能替代人工检查画质。可支持的元数据会尽量复制，包括原片已有的 GPS 信息。

Moving originals to Trash is off by default. When enabled, the app validates the new HEIC's format, dimensions, depth, and color space before moving the RAW. These checks do not replace visual review. Supported metadata, including GPS when present, is copied.

## 黑场与模板 / Dark frames and calibration

- 使用同一台实体后背，在正常工作温度下完全遮光拍摄，不要以暗夜实拍替代黑场。
- 每组按 ISO / 曝光分组，至少 8 张、最多使用 12 张，建议拍 10 张；同组曝光保持一致。
- 已标定位置可跨 ISO 共享。优先参考同 ISO，其次按曝光档数距离选择最接近的 ISO；缺少照片 ISO 时使用最低已知 ISO，必要时使用通用参考。
- 自动保存前会检查策略。成功组更新，失败或素材不足的组保留旧模板；整次失败时保留原有保存结果。
- 系统解码器变化后如果模板兼容性检查失败，应重新标定。

Use intentionally captured, fully covered dark frames from the same physical back at normal operating temperature. Each ISO/exposure group requires 8 frames, uses up to 12, and should keep exposure consistent. About 10 frames is a practical starting point.

Confirmed locations are shared across compatible ISO profiles. The same ISO is preferred, otherwise the nearest ISO by exposure-stop distance. Missing photo ISO falls back to the lowest known ISO or an available generic reference. Successful groups update automatically; failed or insufficient groups retain previous entries. A wholly failed run preserves the saved strategy. Recalibrate if an OS decoder change makes the catalog incompatible.

“高级选项”默认折叠。同位置重复确认比例默认 80%，修改后用于下次标定。真实星点或微小彩灯可能与彩点簇形状相似，此时可关闭补充彩点簇清理，保留固定位置修复。

Advanced Options is collapsed by default. The repeat-confirmation ratio defaults to 80%; changes apply to the next calibration. Tiny stars or colored lights may resemble impulses. Disable supplemental cluster cleanup when needed while retaining fixed-location repair.

模板位置 / Catalog location:

```text
~/Library/Application Support/org.cfvheic.converter/HotPixelTemplates.json
```

上一份备份 / Previous backup: `HotPixelTemplates.json.previous`。

## LUT 与处理顺序 / LUTs and processing order

**RAW 显影 → 可选坏点修复 → 可选 LUT → 10-bit HEIC**。

App 记住 LUT 选择；转换或监视期间锁定选择。默认“不加 LUT”直接跳过调色步骤。LUT 无法加载或渲染时会报错，不会静默输出未套用风格的照片。修复渲染回退时仍会应用所选 LUT。

The app remembers the LUT choice and locks it during conversion or monitoring. No LUT bypasses grading. A LUT loading or rendering failure reports an error instead of silently dropping the look. Repair render fallback still applies the selected LUT.

富士 34 款按文件声明的 Rec.709 Gamma 2.4 处理；两个 Kodak 风格未声明输入色彩空间，明确按 sRGB 配置。预设是第三方复现，不保证与相机机内模拟、ICC 或 Adobe XMP 完全一致。当前由维护者配置 3D CUBE，App 没有导入按钮。

Fuji's 34 looks use the files' declared Rec.709 Gamma 2.4 encoding. The two Kodak looks do not declare an input encoding and are explicitly configured as sRGB. These are third-party recreations, without a guaranteed match to in-camera rendering, ICC, or Adobe XMP. The maintainer configures 3D CUBE resources; the app has no importer.

## 适用边界 / Limits

修复在 Apple 去马赛克后的浮点 RGB 图像上进行，不写传感器数据或后背固件。检测存在启发式判断，可能漏检或影响微小真实细节，不保证零噪声、与 Phocus 完全相同的显影或全部元数据完整保留。HEIC 不具备 RAW 的重新显影能力。

Repair operates on Apple's post-demosaic floating-point RGB image. It does not modify sensor data or camera firmware. Detection is heuristic and can miss defects or affect tiny real features. Noise-free output, exact Phocus rendering, and complete metadata preservation are not guaranteed. HEIC does not retain RAW editing latitude.

本地构建使用临时签名，未经公证，macOS 可能显示安全提示。Intel、其他后背及所有 macOS 版本未经过全面测试。开发和测试细节见 [开发文档](DEVELOPMENT.md)。

Builds are ad-hoc signed and not notarized, so macOS may show a security prompt. Intel Macs, other backs, and every macOS version have not been comprehensively tested. See [development documentation](DEVELOPMENT.md) for build and test details.
