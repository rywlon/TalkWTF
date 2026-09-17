# 构建

只支持 macOS（arm64）。不需要签名/公证。

## 前置

- Xcode（含命令行工具）
- Rust stable：`rustup`（本机路径 `/opt/homebrew/opt/rustup/bin`）

## 构建 app

```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
```

产物：`macos/build/Debug/TalkWTF.app`

工程里有两个 Run Script 阶段，Xcode 会自动跑：

1. **Build Rust core** —— 在 `core/ffi` 跑
   `cargo build --release --target aarch64-apple-darwin`，产出 `libtalkwtf_ffi.a`。
2. **Copy core resources** —— 把 `resources/` 拷进 `TalkWTF.app/Contents/Resources/resources/`
   （含 `locales/`、`models/silero_vad_v4.onnx`、提示音 wav、托盘 png、`default_settings.json`）。

## 运行

```bash
open macos/build/Debug/TalkWTF.app
```

首次启动会引导授权**麦克风**（录音）和**辅助功能**（粘贴 + 读输入框学词）。

Rust 日志走 stderr；直接跑二进制才能看到：

```bash
macos/build/Debug/TalkWTF.app/Contents/MacOS/TalkWTF
```

## 测试

```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"

# 核心（含网络相关用例时需要绕过本机代理）
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml

cargo test --manifest-path core/ffi/Cargo.toml

# 格式
cargo fmt --manifest-path core/core/Cargo.toml --check
cargo fmt --manifest-path core/ffi/Cargo.toml --check

# 26 个语言包的 key 一致性
python3 scripts/check_translations.py
```

无头端到端冒烟（不启动 app）：

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo run --manifest-path core/core/Cargo.toml --example smoke
```

`core/core/examples/dictation.rs` 会真录 4 秒音再走完整管线。

## App 图标

`macos/TalkWTF/AppIcon.icns` 由 `scripts/gen_icon.swift` 生成（圆角方块 + 单色波形）：

```bash
swift scripts/gen_icon.swift docs/assets/app-icon.png
mkdir -p /tmp/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s docs/assets/app-icon.png --out /tmp/AppIcon.iconset/icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) docs/assets/app-icon.png --out /tmp/AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns /tmp/AppIcon.iconset -o macos/TalkWTF/AppIcon.icns
```

## 加 Swift 文件

`macos/TalkWTF.xcodeproj/project.pbxproj` 是手写的。新增 `.swift` 需要在四处登记：
`PBXBuildFile`、`PBXFileReference`、group 的 `children`、`Sources` build phase。

## 加 Rust 命令

1. 在 `core/ffi/src/lib.rs` 的 `run()` 里加分支。
2. 同步 `core/ffi/include/talkwtf.h`（手写，按需）。
3. 重启 app（不是热重载）——Swift 侧通过 `Core.invoke` 按名字调用，没有生成的绑定。
