# Changelog / 更新记录

## 1.9.0 — 2026-11-01

- Bundle the same 36 looks in the app and GitHub release: 34 Fuji recreations plus Kodak Chrome 1930s and 64 Adjusted.
- Remove the other five Kodak variants. Preserve the two retained preset identifiers.
- Group the look dropdown by collection.
- Match the Fuji collection's declared Rec.709 Gamma 2.4 encoding explicitly.
- Retain repair → LUT → 10-bit HEIC order and existing preset identifiers.

新增富士风格复现 34 款；Kodak 只保留 1930s 和 64 调整，删除其余 5 款，共 36 个风格。App 与 GitHub 统一，菜单按系列分组，富士系列按声明的 Rec.709 Gamma 2.4 处理，保留原有修复流程。

## 1.8.0 — 2026-11-01

- Optional bundled 3D CUBE looks applied after pixel repair and before HEIC export.
- Remembered No LUT / preset dropdown, locked during batch conversion and monitoring.
- Explicit LUT input encoding, validated tables, and LUT-preserving repair fallback.
- Personal LUT assets stay outside the MIT source and public release binaries.

新增 LUT 下拉选项：坏点修复后统一套用，默认关闭；记住选择，转换或监视时锁定。公开包不附带第三方预设。

## 1.7.0 — 2026-10-31

Initial public source release.

- Native SwiftUI/AppKit batch `.3FR` to 10-bit HEIC conversion.
- Display P3/sRGB, adjustable quality, folder drag-and-drop and monitoring.
- Optional automatic multi-ISO dark-frame calibration and sparse RGB pixel-cluster repair.
- Single-action calibration setup with automatic persistence and fallback selection.
- Public package starts without camera-specific templates, uses the supplied camera-back logo, and keeps settings separate from the private development build.
- English and Simplified Chinese usage guides and MIT licensing.

首次公开源码版本，包含原生批量转换、广色域输出、文件夹监视、自动多 ISO 黑场标定、局部彩点簇修复和单按钮标定交互。公开包不附带特定后背模板，采用用户提供的后背图案及独立设置目录，并提供中英文说明和 MIT 许可证。
