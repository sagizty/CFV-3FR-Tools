# 开发与测试 / Development and testing

[返回首页 / Back to README](../README.md)

## 构建 / Build

需要 Apple Silicon Mac、较新的 Xcode 或 Xcode Command Line Tools，包含 macOS SDK 和 Swift 编译器。无需下载第三方依赖。脚本使用系统选中的 SDK，当前目标为 arm64 / macOS 12.0；未提供或验证 Intel 构建。

Use an Apple Silicon Mac with a recent Xcode or Xcode Command Line Tools installation, including the macOS SDK and Swift compiler. No third-party packages are downloaded. The build targets arm64 / macOS 12.0; Intel builds are not supplied or tested.

在仓库根目录运行 / Run from the repository root:

```sh
zsh build.sh
```

输出 / Output: `dist/CFV-HEIC-<version>-macOS-arm64.zip`。

标准构建自动包含 `Resources/LUTs/` 中的 36 个预设及第三方说明。脚本使用临时签名，未经公证；正式签名和公证需由维护者另行安排。部署目标不表示所有 macOS 版本都经过实机验证，RAW 解码也依赖系统支持。

The default build bundles the same 36 presets in `Resources/LUTs/` and the third-party notice. It uses an ad-hoc signature and is not notarized. Distribution signing and notarization are separate maintainer tasks. A deployment target does not establish testing on every macOS release; RAW decoding also depends on the OS.

维护者准备后续预设包时可指定输出及资源目录 / To prepare a future collection:

```sh
zsh build.sh ./dist /path/to/lut-resources
```

第二个参数替换默认资源目录。资源清单和色彩空间要求见 [技术说明](TECHNICAL_NOTES.md)。App 没有用户导入 LUT 的界面。

The second argument replaces the default resource directory. See [technical notes](TECHNICAL_NOTES.md) for the catalog and encoding requirements. There is no in-app LUT importer.

## 测试 / Tests

在正常登录的 macOS 图形会话中运行 / Run in a logged-in macOS graphics session:

```sh
# Synthetic repair/calibration checks and all 36 bundled LUTs; no photos needed.
zsh Tests/run-tests.sh

# Optional end-to-end calibration using your own dark-frame folder.
zsh Tests/run-tests.sh "/path/to/dark-frames"

# Optional real-RAW comparison with the original, unrepaired converter.
zsh Tests/regression.sh "/path/to/photo.3FR"

# Optional full-resolution repair → LUT → HEIC integration.
zsh Tests/lut-integration.sh "/path/to/photo.3FR" ./Resources/LUTs

# Optional integration with a catalog from the same physical back.
zsh Tests/lut-integration.sh "/path/to/photo.3FR" ./Resources/LUTs "/path/to/calibration.json"
```

真实 RAW 比较脚本另需 Python 3。真实图像测试依赖 macOS RAW 解码与图形服务；受限或无图形会话的环境可能无法提供。测试输出使用临时目录，不修改输入原片。标定测试需要至少一个合格黑场组；传入的标定表必须来自同一台实体后背。仓库不包含私人测试数据。

The RAW comparison helper also requires Python 3. Real-image checks depend on macOS RAW decoding and graphics services, which may be unavailable in restricted or headless environments. Outputs use temporary storage and input originals are not modified. Calibration tests need an eligible dark-frame group; any supplied catalog must belong to the same physical back. No private test dataset is included.

## 图标与贡献 / Artwork and contributions

```sh
zsh scripts/make-icon.sh
```

此命令从保留的 `Resources/logo.png` 生成带白色圆角底的 PNG / ICNS。使用 `zsh` 运行脚本，网页上传后即使未保留可执行权限也能使用。

This regenerates PNG / ICNS icons from `Resources/logo.png`, with a white rounded background. Explicit `zsh` commands work even when browser uploads do not retain executable permissions.

[贡献说明 / Contributing](CONTRIBUTING.md) · [技术说明 / Technical notes](TECHNICAL_NOTES.md) · [第三方资源 / Third-party resources](THIRD_PARTY_NOTICES.md)
