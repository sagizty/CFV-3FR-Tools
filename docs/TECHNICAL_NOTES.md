# Technical notes / 技术说明

## Source map

| File | Responsibility |
|---|---|
| `Sources/App.swift` | Folder queue, monitoring, LUT selection, main UI |
| `Sources/Conversion.swift` | RAW development, repair → LUT → HEIC pipeline, output validation |
| `Sources/ColorLUT.swift` | Bundled catalog, validated CUBE parsing, explicit LUT color-space processing |
| `Sources/HotPixelCore.swift` | Profile validation, normalized image coordinates, calibration, sparse fixed-location repair |
| `Sources/ImpulseCleanup.swift` | Learned impulse signatures and optional per-image cluster cleanup |
| `Sources/CalibrationPlanner.swift` | Dark-frame scanning, capture groups, reference ordering, automatic catalog persistence |
| `Sources/HotPixelUI.swift` | One-action calibration panel, progress, local settings |
| `Resources/Info.plist` | Bundle identity, version, minimum deployment target |
| `Tests/` | Synthetic regressions and optional user-supplied-data checks |

## Rendering and coordinates

`CIRAWFilter` supplies the full decoded image. The optional repair stage operates in floating-point extended-linear-sRGB after Apple's demosaic, then returns to the existing color-managed HEIC encoder. It is not a writable CFA pipeline. Profile coordinates are normalized to the decoded image's bottom-left origin and are not interchangeable with sensor or rawpy coordinates.

Compatibility checks include camera identity, decoded/native dimensions, image origin, orientation, and decoder version. Older incompatible coordinate revisions are rejected. ISO prioritizes reference centers when sharing confirmed positions and shapes across compatible profiles; it does not establish that a new calibration was physically photographed at the target ISO.

When supplemental cleanup fails or exceeds its safeguards, the converter logs the fallback and retains fixed-location repair where possible. A mismatched catalog is skipped with a log message so conversion can continue. Inspect the conversion log when diagnosing unchanged defects.

The application does not guarantee exact Phocus rendering or full metadata round-tripping. Existing exports are not overwritten by the folder queue. The encoder validates new output format, depth, dimensions, and color space before the optional move-to-Trash step.

## Calibration persistence

Each ready group uses 8–12 dark files and the current repeat-confirmation ratio (default 0.8). Successful groups replace matching camera/ISO/exposure entries. Incomplete or failed groups keep their previous entries. Before writing, the combined strategies must be valid and applicable. The writer backs up the prior catalog and uses atomic replacement.

Missing photo ISO prefers the lowest known calibration ISO. If photo ISO is known, closest means minimum absolute log2 exposure-stop distance; lower ISO breaks a tie. A generic unknown-ISO template is used when no known-ISO reference is available. All data remains local.

## Public distribution

The public bundle identifier and storage namespace are `org.cfvheic.converter`. No camera-specific private calibration preset is loaded or distributed. There is no dependency download step, Xcode project, signing certificate, or developer account in the repository. `build.sh` compiles the seven source files against the selected macOS SDK and uses an ad-hoc signature. Formal distribution signing and notarization are separate maintainer tasks.

`Resources/logo.png` is the supplied transparent camera-back artwork, retained unchanged. `zsh scripts/make-icon.sh` places it on a white rounded background and regenerates `Resources/icon.png` and `Resources/AppIcon.icns` in standard macOS icon sizes. No image-generation service or external dependency is needed.

## 验证与维护要点

修复发生在 Apple 去马赛克后的浮点 RGB 图像中，坐标以解码图像左下角为基准，不能套用传感器 CFA 坐标。模板匹配会检查尺寸、方向和解码器等信息；系统解码器变化后，如模板不匹配，应重新标定。ISO 用于选择合并时的优先参考，不代表在目标 ISO 下重新拍过标定图。

自动保存前会验证策略。单组失败保留该组旧模板；全部失败不替换为无效结果。当前应用把模板视为来自同一实体后背，使用者仍需保证素材来源一致。

维护时请优先保持关闭修复时的原转换结果，避免为了修复亮点而无验证地替换 RAW 显影或色彩管理流程。真实图像测试由测试者自行提供素材，公开仓库不附带私人照片、标定表或逐图实验记录。

## LUT resources and color handling

The repository and app include the same 36 third-party looks in `Resources/LUTs/`: 34 Fuji recreations and the two retained Kodak Chrome looks (1930s and 64 Adjusted). The supplied source metadata and hashes are recorded in `Resources/LUTs/PROVENANCE.json`; see [third-party notices](THIRD_PARTY_NOTICES.md). A normal build bundles this directory. To prepare a future collection, a maintainer can pass another resources directory as the second `build.sh` argument, replacing the default collection. It contains `catalog.json` and the referenced CUBE files:

```json
[
  {
    "id": "my-look-v1",
    "group": "My collection",
    "name": "My look",
    "file": "My collection/my-look.cube",
    "inputSpace": "sRGB"
  }
]
```

The app reads this fixed bundled catalog, never scans Downloads or imports files through the UI. Names and groups are displayed in the dropdown. Missing or invalid catalog entries produce a visible warning. Only the currently used parsed table is cached; full-size photographs are not copied to an intermediate 8-bit image.

The parser accepts one independent 3D CUBE with side length 2–128, optional TITLE/comments/BOM, DOMAIN_MIN/MAX or LUT_3D_INPUT_RANGE, and red-fastest RGB rows. It validates row counts, finite numbers, and domain consistency. Unsupported 1D/shaper combinations are rejected rather than interpreted incorrectly. ICC/XMP parsing and arbitrary Log encodings are not implemented.

`inputSpace` must be `sRGB`, `linearSRGB`, `displayP3`, or `rec709Gamma24`. Matching explicitly converts working RGB to the declared LUT coordinates, applies domain normalization and the table, then returns to the context's working space. Values outside the LUT domain clamp to its edges; this is a creative SDR grade and does not promise to preserve all HDR or out-of-gamut information. The output remains 10-bit P3 or sRGB as selected, but a sRGB LUT does not create wide-gamut color information.

The two retained Kodak CUBE files do not declare an input encoding. Their catalog entries therefore use **sRGB as an explicit assumption**, not a verified claim from the vendor. Visual matching to an Adobe XMP or ICC rendition is not promised. Future packs should be configured using their vendor's stated input/output encoding; unsupported transfer functions require implementation work.

The lookup and code-value order follow Apple's [CIColorCube reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html#//apple_ref/doc/filter/ci/CIColorCube). The explicit working-space conversions are verified using identity, channel-swap, nonlinear gamma fixtures, and independent CPU interpolation of the supplied 64³ and 32³ tables. Repair render fallback reapplies the same LUT to the unrepaired RAW; a LUT failure must never silently drop the selected look.

### Fuji collection encoding

All 34 Fuji CUBE headers name `Rec709gamma2.4.icc`. The two software editions are byte-identical before sanitizing their exporting-computer path comments. They are one collection, not 68 distinct looks. The app uses Rec.709 primaries, D65 white, and a pure 2.4 gamma calibrated RGB space, then matches back to the HEIC working space. It does not treat these tables as sRGB or substitute the system ITU-R 709 transfer curve.

The creator of the exporting tool explains the importance of matching the LUT profile in [Export LUT color management](https://johnrellis.com/lightroom/exportlut.htm#video-color-management). The implementation uses Apple's [calibrated RGB color-space initializer](https://developer.apple.com/documentation/coregraphics/cgcolorspace/init(calibratedrgbwhitepoint:blackpoint:gamma:matrix:)). Synthetic tests independently verify the linear values `pow(codeValue, 2.4)` and nonlinear lookup results in both linear-sRGB and Display-P3 contexts.
