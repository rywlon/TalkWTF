# 阶段 18：自包含打包（子项目 0）

> 多平台计划的第一个子项目。后续：1 Intel/universal、2 内置 Qwen3-ASR、
> 3 公证、4 Windows。本阶段只做「能发出去的 Mac 包」。

## 背景

`dist/TalkWTF.app`（6.6MB）目前**无法分发**：Swift 主二进制**动态链接**
`libtalkwtf_ffi.dylib`（41MB），install name 是构建机绝对路径
`/Users/SheenaRingo/projects/TalkWTF/core/ffi/target/aarch64-apple-darwin/release/deps/libtalkwtf_ffi.dylib`，
而该 dylib **没有打进 `.app`**。拷到别的 Mac 上 dyld 会报
`Library not loaded`，启动即崩溃。

根因（已核实）：`core/ffi/Cargo.toml` 的
`crate-type = ["staticlib", "cdylib"]` 会同时在
`target/aarch64-apple-darwin/release/` 产出 `libtalkwtf_ffi.a` 与
`libtalkwtf_ffi.dylib`；Xcode 用 `OTHER_LDFLAGS = -ltalkwtf_ffi`，
链接器在两者同名并存时**优先选 `.dylib`**。文档
（`docs/specs/phase-12-next-steps.md`）里写的本意是链 `.a`，这是加 `cdylib`
后引入的回归。

## 目标

产出一个**自包含**、可在其他 Apple Silicon Mac 上启动的 `.app`，并提供
一条命令产出可分发的 zip。

## 范围

1. **静态链接**：`macos/TalkWTF.xcodeproj/project.pbxproj` 的 Debug/Release
   两处 `OTHER_LDFLAGS` 去掉 `-ltalkwtf_ffi`，改为显式链
   `$(SRCROOT)/../core/ffi/target/aarch64-apple-darwin/release/libtalkwtf_ffi.a`。
2. **strip**：Release 打开 `COPY_PHASE_STRIP = YES`（脚本里再兜底
   `strip -x`）。
3. **ad-hoc 签名**：Debug/Release 的 `CODE_SIGN_IDENTITY` 从 `"TalkWTF Dev"`
   改为 `"-"`，去掉对 keychain 自签证书的依赖，使任何人都能复现构建。
   `CODE_SIGN_STYLE = Manual`、`ENABLE_HARDENED_RUNTIME = NO` 保持不变。
4. **打包脚本** `scripts/package.sh`：
   - `xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Release build`
   - 断言 `otool -L` 输出不含 `/Users/` 且不含 `libtalkwtf_ffi.dylib`
   - `strip -x`（若 Xcode 未 strip）
   - `codesign --force --sign - TalkWTF.app`
   - `ditto -c -k --keepParent` 打 zip 到 `dist/TalkWTF-<version>-arm64.zip`
   - 复制 `INSTALL.txt` 进 `dist/`
5. **`INSTALL.txt`**：写清 Gatekeeper 绕过步骤（现代 macOS 已取消右键打开）：
   系统设置 → 隐私与安全性 → 「仍要打开」；或终端
   `xattr -dr com.apple.quarantine /Applications/TalkWTF.app`。

## 非目标

- Intel / universal binary（子项目 1）
- 内置 Qwen3-ASR 模型（子项目 2）
- 公证 / Developer ID（子项目 3，需 $99/年，已决定不做）
- Windows（子项目 4）
- 修改引擎行为、UI、功能

## 验收标准

1. `otool -L dist/TalkWTF.app/Contents/MacOS/TalkWTF` 只剩
   `/System/...`、`/usr/lib/...`，无绝对构建路径、无 `libtalkwtf_ffi.dylib`。
2. 把 `.app` 拷到 `/tmp`（模拟他处）能启动；最好在另一台 Apple Silicon Mac
   实测：菜单栏图标出现、能录音听写。
3. 清掉 `macos/build/` 后 `scripts/package.sh` 能重建并出 zip。
4. `dist/TalkWTF-<version>-arm64.zip` 解压后的 app 满足第 1、2 条。
5. `cargo test`（core + ffi）与既有构建仍通过。

## 任务拆分（高层）

1. 改 pbxproj：静态链接 + ad-hoc 签名 + Release strip。
2. 构建并验证 `otool -L`；若静态链接缺符号，补链接标志
   （`-lresolv` / `-lpthread` / `-lc++` 等）。
3. 写 `scripts/package.sh` + `INSTALL.txt`。
4. 端到端：clean → package → 拷到 `/tmp` 启动验证。
5. 更新 `BUILD.md` 与 `AGENTS.md`（分发/签名设定变化）。

## 风险

- 静态链接 Rust staticlib 可能缺系统库符号 → 实现时补 `OTHER_LDFLAGS`。
- 静态链接后主二进制变大（预计十几 MB），可接受。
- 无公证：对方首次打开必须手动绕过 Gatekeeper（已写进 `INSTALL.txt`）。
