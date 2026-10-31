# CFV HEIC 1.9.0

The app and GitHub release now include the same **36 LUT looks**: 34 Fuji-style recreations plus Kodak Chrome 1930s and Kodak Chrome 64 Adjusted. The other five Kodak variants were removed. The dropdown groups looks by collection; No LUT remains the default.

Fuji looks use their declared Rec.709 Gamma 2.4 encoding. The order remains RAW development → optional dark-frame pixel repair → selected LUT → 10-bit HEIC (P3 or sRGB). Move existing HEIC outputs before reconverting with a different look.

Includes bilingual usage, third-party provenance and checksums. No private photos or camera calibration templates are distributed. Application source: MIT; resource metadata: docs/THIRD_PARTY_NOTICES.md.

Apple Silicon / arm64, macOS 12.0 deployment target. Ad-hoc signed, not notarized; not all macOS releases and backs have been tested. Interface: Simplified Chinese.

App 和 GitHub 统一内置 **36 个风格**：富士复现 34 款，以及 Kodak 克罗姆 1930s、64 调整。其余 5 个 Kodak 版本已删除，下拉菜单按系列分组，默认仍是“不加 LUT”。

富士系列按文件声明的 Rec.709 Gamma 2.4 处理。流程保持为 RAW 显影 → 可选坏点修复 → 所选 LUT → 10-bit HEIC，支持 P3 / sRGB。换风格后请先移走旧 HEIC 再转换。

提供中英文说明、第三方来源记录及校验文件，不包含私人照片或后背标定模板。代码 MIT，素材信息见 docs/THIRD_PARTY_NOTICES.md。当前为 Apple Silicon 本地签名构建，未经公证。
