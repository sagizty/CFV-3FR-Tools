# Contributing / 参与贡献

Please keep changes focused and run `zsh Tests/run-tests.sh` on macOS. For rendering changes, also run `zsh Tests/regression.sh "/path/to/photo.3FR"` and explain any intended output differences.

A useful issue includes the app version, macOS version, Mac architecture, exact back model, whether repair is enabled, and steps to reproduce. Before sharing photos, logs, or templates, check their metadata and file paths. Only share files you are comfortable making public; the project does not require publishing your RAW originals or sensor map.

Contributions to code and original artwork are submitted under the project's MIT license. Keep model-specific behavior explicit; do not silently replace the RAW decoder or claim compatibility with untested backs. The UI is currently Chinese; localization contributions are welcome.

请保持修改范围清晰，并在 macOS 上运行 `zsh Tests/run-tests.sh`。涉及显影或输出时，再运行 `zsh Tests/regression.sh "/path/to/photo.3FR"`，说明预期的输出差异。

反馈问题时，请附应用版本、macOS 版本、Mac 架构、后背确切型号、是否启用修复及复现步骤。分享照片、日志或模板前，请检查元数据和文件路径。仅分享你愿意公开的文件，不要求上传 RAW 原片或个人后背标定表。

提交的代码及原创素材采用项目的 MIT 许可证。请明确机型适用范围，不要静默替换 RAW 解码器，也不要宣称兼容未经验证的后背。欢迎补充界面本地化。
