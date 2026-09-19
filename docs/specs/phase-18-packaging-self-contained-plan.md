# 阶段 18 实施计划：自包含打包（子项目 0）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `xcodebuild` 产出不依赖构建目录、可在其他 Apple Silicon Mac 上启动的
`TalkWTF.app`，并给出一条命令产出可分发 zip。

**Architecture:** 把 Swift 外壳与 Rust 引擎的链接方式从「动态链 `.dylib`」改成
「显式静态链 `.a`」，补齐 Rust 静态库所需的系统框架，改用 ad-hoc 签名，strip 后
`codesign`，最后 `ditto` 打 zip。不改引擎、不改 UI。

**Tech Stack:** Xcode（手写 pbxproj）、Rust staticlib、clang 链接、`codesign`、`ditto`。

## Global Constraints

- 平台：macOS 14+、**arm64 only**（Intel/universal 是子项目 1，本阶段不做）。
- **不做公证 / 不买 Developer ID**（子项目 3 已否决）。签名用 ad-hoc（`-`）。
- 无自建云、无账号、无遥测；不修改引擎行为。
- `dist/` 已被 `.gitignore` 忽略，zip 产物不进 git。
- 版本号来源：`macos/TalkWTF/Info.plist` 的 `CFBundleShortVersionString`（当前 `0.9.6`）。
- Rust 工具链路径：`export PATH="/opt/homebrew/opt/rustup/bin:$PATH"`。
- 构建命令必须用 `-target`（工程没有 scheme）。
- pbxproj 缩进是 **Tab**，改动时保持原样。

---

### Task 1: 静态链接 + ad-hoc 签名 + Release strip

**Files:**
- Modify: `macos/TalkWTF.xcodeproj/project.pbxproj`（target 的两个 XCBuildConfiguration：
  `1A000000000000000000000F /* Debug */` 与 `1A0000000000000000000010 /* Release */`）

**Interfaces:**
- Consumes: `core/ffi/target/aarch64-apple-darwin/release/libtalkwtf_ffi.a`
  （由已有的 "Build Rust core" Run Script 阶段产出；已用探针链接验证可静态链）
- Produces: 自包含的 `macos/build/Release/TalkWTF.app`，其 `otool -L` 只剩
  `/System/...`、`/usr/lib/...`；后续 Task 2 的打包脚本依赖它。

**背景（已核实）：** `core/ffi/Cargo.toml` 的 `crate-type = ["staticlib", "cdylib"]`
会同时在 `release/` 产出 `.a` 与 `.dylib`，`-ltalkwtf_ffi` 时 `ld` 优先选 `.dylib`。
改成显式链 `.a` 后，需补这些系统框架（探针实测通过）：
`Accelerate AppKit ApplicationServices AudioToolbox AudioUnit Carbon CloudKit
CoreAudio CoreData CoreFoundation CoreGraphics CoreImage CoreText CoreVideo Metal
QuartzCore Security SystemConfiguration` + `-lc++`。

- [ ] **Step 1: 记录基线（确认当前是坏的）**

Run:
```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Release build
otool -L macos/build/Release/TalkWTF.app/Contents/MacOS/TalkWTF | grep -E '/Users/|libtalkwtf_ffi'
```
Expected: 输出里出现
`/Users/SheenaRingo/projects/TalkWTF/core/ffi/target/.../libtalkwtf_ffi.dylib`
（证明当前动态链接、不可分发）。

- [ ] **Step 2: 替换 Debug 配置块**

在 `project.pbxproj` 里，把 `1A000000000000000000000F /* Debug */ = {` 到它对应的
`name = Debug;` 之前的整个 `buildSettings` 替换为（Tab 缩进）：

```
		1A000000000000000000000F /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ARCHS = arm64;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_HARDENED_RUNTIME = NO;
				GENERATE_INFOPLIST_FILE = NO;
				HEADER_SEARCH_PATHS = (
					"$(SRCROOT)/../core/ffi/include",
				);
				INFOPLIST_FILE = TalkWTF/Info.plist;
				LIBRARY_SEARCH_PATHS = (
					"$(SRCROOT)/../core/ffi/target/aarch64-apple-darwin/release",
				);
				MARKETING_VERSION = 0.9.6;
				OTHER_LDFLAGS = (
					"$(SRCROOT)/../core/ffi/target/aarch64-apple-darwin/release/libtalkwtf_ffi.a",
					"-framework",
					"Accelerate",
					"-framework",
					"AppKit",
					"-framework",
					"ApplicationServices",
					"-framework",
					"AudioToolbox",
					"-framework",
					"AudioUnit",
					"-framework",
					"Carbon",
					"-framework",
					"CloudKit",
					"-framework",
					"CoreAudio",
					"-framework",
					"CoreData",
					"-framework",
					"CoreFoundation",
					"-framework",
					"CoreGraphics",
					"-framework",
					"CoreImage",
					"-framework",
					"CoreText",
					"-framework",
					"CoreVideo",
					"-framework",
					"Metal",
					"-framework",
					"QuartzCore",
					"-framework",
					"Security",
					"-framework",
					"SystemConfiguration",
					"-lc++",
				);
				PRODUCT_BUNDLE_IDENTIFIER = com.talkwtf.app;
				PRODUCT_NAME = TalkWTF;
				SWIFT_OBJC_BRIDGING_HEADER = "TalkWTF/TalkWTF-Bridging-Header.h";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
```

- [ ] **Step 3: 替换 Release 配置块（多一行 `COPY_PHASE_STRIP`）**

把 `1A0000000000000000000010 /* Release */ = {` 到它的 `name = Release;` 之前替换为：

```
		1A0000000000000000000010 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ARCHS = arm64;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				COMBINE_HIDPI_IMAGES = YES;
				COPY_PHASE_STRIP = YES;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_HARDENED_RUNTIME = NO;
				GENERATE_INFOPLIST_FILE = NO;
				HEADER_SEARCH_PATHS = (
					"$(SRCROOT)/../core/ffi/include",
				);
				INFOPLIST_FILE = TalkWTF/Info.plist;
				LIBRARY_SEARCH_PATHS = (
					"$(SRCROOT)/../core/ffi/target/aarch64-apple-darwin/release",
				);
				MARKETING_VERSION = 0.9.6;
				OTHER_LDFLAGS = (
					"$(SRCROOT)/../core/ffi/target/aarch64-apple-darwin/release/libtalkwtf_ffi.a",
					"-framework",
					"Accelerate",
					"-framework",
					"AppKit",
					"-framework",
					"ApplicationServices",
					"-framework",
					"AudioToolbox",
					"-framework",
					"AudioUnit",
					"-framework",
					"Carbon",
					"-framework",
					"CloudKit",
					"-framework",
					"CoreAudio",
					"-framework",
					"CoreData",
					"-framework",
					"CoreFoundation",
					"-framework",
					"CoreGraphics",
					"-framework",
					"CoreImage",
					"-framework",
					"CoreText",
					"-framework",
					"CoreVideo",
					"-framework",
					"Metal",
					"-framework",
					"QuartzCore",
					"-framework",
					"Security",
					"-framework",
					"SystemConfiguration",
					"-lc++",
				);
				PRODUCT_BUNDLE_IDENTIFIER = com.talkwtf.app;
				PRODUCT_NAME = TalkWTF;
				SWIFT_OBJC_BRIDGING_HEADER = "TalkWTF/TalkWTF-Bridging-Header.h";
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
```

- [ ] **Step 4: 构建**

Run:
```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Release build
```
Expected: `** BUILD SUCCEEDED **`。
若报 `Undefined symbols` / `framework not found`，把缺失的符号名贴出来，按需在
`OTHER_LDFLAGS` 里补对应 `-framework`（探针已确认上面这组够用）。

- [ ] **Step 5: 验证自包含**

Run:
```bash
otool -L macos/build/Release/TalkWTF.app/Contents/MacOS/TalkWTF | grep -E '/Users/|libtalkwtf_ffi'
```
Expected: **无输出**（grep 退出码 1）。再确认文件大小：
```bash
ls -la macos/build/Release/TalkWTF.app/Contents/MacOS/TalkWTF
```
Expected: 约 40–50MB（静态链后比原来的 3MB 大，正常）。

- [ ] **Step 6: 验证能启动**

Run:
```bash
open macos/build/Release/TalkWTF.app
sleep 3
pgrep -x TalkWTF && echo RUNNING || echo NOT-RUNNING
```
Expected: `RUNNING`（菜单栏出现图标）。随后退出：
```bash
pkill -x TalkWTF || true
```

- [ ] **Step 7: 提交**

```bash
git add macos/TalkWTF.xcodeproj/project.pbxproj
git commit -m "build(macos): 静态链接 Rust 核心 + ad-hoc 签名，app 自包含"
```

---

### Task 2: 打包脚本 + 安装说明

**Files:**
- Create: `scripts/package.sh`
- Create: `INSTALL.txt`

**Interfaces:**
- Consumes: Task 1 产出的 `macos/build/Release/TalkWTF.app`。
- Produces: `dist/TalkWTF-<version>-arm64.zip` 与 `dist/INSTALL.txt`。
  后续 Task 3 的端到端验证依赖这个 zip。

- [ ] **Step 1: 写 `scripts/package.sh`**

```bash
#!/bin/bash
# 打出自包含、可分发的 TalkWTF.app（arm64，未公证）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PATH="/opt/homebrew/opt/rustup/bin:$PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' macos/TalkWTF/Info.plist)"
APP="macos/build/Release/TalkWTF.app"
BIN="$APP/Contents/MacOS/TalkWTF"
DIST="$ROOT/dist"
ZIP="$DIST/TalkWTF-${VERSION}-arm64.zip"

echo "==> 构建 Release"
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Release build

echo "==> 断言自包含"
if otool -L "$BIN" | grep -E '/Users/|libtalkwtf_ffi\.dylib'; then
  echo "ERROR: app 仍依赖构建目录里的库，不可分发" >&2
  exit 1
fi

echo "==> strip"
strip -x "$BIN" || true

echo "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP"

echo "==> 打 zip"
mkdir -p "$DIST"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
cp "$ROOT/INSTALL.txt" "$DIST/INSTALL.txt"

echo "==> 完成：$ZIP"
ls -la "$ZIP"
```

- [ ] **Step 2: 加可执行权限**

Run:
```bash
chmod +x scripts/package.sh
```

- [ ] **Step 3: 写 `INSTALL.txt`**

```
TalkWTF — macOS 安装说明

系统要求：macOS 14 或更新，Apple Silicon（M 系列）芯片。

本 app 未经过 Apple 公证（个人项目，不交 Apple 开发者年费）。macOS 默认会
阻止打开。首次打开请二选一：

方法 A（图形界面，推荐）
  1. 把 TalkWTF.app 拖进「应用程序」文件夹
  2. 双击它，弹出「无法打开」提示后点「完成」
  3. 打开「系统设置」→「隐私与安全性」
  4. 向下滚到「安全性」区域，点「仍要打开 TalkWTF」
  5. 再次双击 TalkWTF.app，点「打开」

方法 B（终端，一行命令）
  把 TalkWTF.app 放进 /Applications 后运行：
    xattr -dr com.apple.quarantine /Applications/TalkWTF.app

首次启动会请求：
  - 麦克风权限（录音）
  - 辅助功能权限（粘贴、自动学词）

注意：语音识别模型会在首次使用时从 Hugging Face 下载（数百 MB），需要联网。
```

- [ ] **Step 4: 从干净状态跑脚本（验证可重建）**

Run:
```bash
rm -rf macos/build
scripts/package.sh
```
Expected: 末尾打印 `==> 完成：/Users/SheenaRingo/projects/TalkWTF/dist/TalkWTF-0.9.6-arm64.zip`
且 `ls -la` 显示 zip 存在。

- [ ] **Step 5: 验证 zip 内容**

Run:
```bash
rm -rf /tmp/talkwtf-verify && mkdir -p /tmp/talkwtf-verify
ditto -x -k dist/TalkWTF-0.9.6-arm64.zip /tmp/talkwtf-verify
otool -L /tmp/talkwtf-verify/TalkWTF.app/Contents/MacOS/TalkWTF | grep -E '/Users/|libtalkwtf_ffi' && echo BAD || echo SELF-CONTAINED
codesign -dv /tmp/talkwtf-verify/TalkWTF.app 2>&1 | grep -E 'Signature|Identifier|Authority'
```
Expected: `SELF-CONTAINED`；`codesign` 输出含 `Signature=adhoc`，无 `Authority`。

- [ ] **Step 6: 提交**

```bash
git add scripts/package.sh INSTALL.txt
git commit -m "build(macos): 新增 package.sh 与 INSTALL.txt（自包含 zip + 未公证说明）"
```

---

### Task 3: 端到端验证 + 文档更新

**Files:**
- Modify: `BUILD.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: Task 2 的 `dist/TalkWTF-0.9.6-arm64.zip`。
- Produces: 更新后的构建/打包文档；无代码接口。

- [ ] **Step 1: 模拟「他处」启动**

Run:
```bash
rm -rf /tmp/talkwtf-run && mkdir -p /tmp/talkwtf-run
ditto -x -k dist/TalkWTF-0.9.6-arm64.zip /tmp/talkwtf-run
xattr -dr com.apple.quarantine /tmp/talkwtf-run/TalkWTF.app || true
open /tmp/talkwtf-run/TalkWTF.app
sleep 3
pgrep -x TalkWTF && echo RUNNING || echo NOT-RUNNING
pkill -x TalkWTF || true
```
Expected: `RUNNING`。

- [ ] **Step 2: 人工验收（在另一台 Apple Silicon Mac 上）**

把 `dist/TalkWTF-0.9.6-arm64.zip` 拷到另一台 Apple Silicon Mac，按 `INSTALL.txt`
打开，确认菜单栏图标出现、能录音听写。
**此步无法在本机自动化，由用户执行。** 若无法实测，在交付说明里标注「未在第二台机器验证」。

- [ ] **Step 3: 回归测试（确认链接改动没影响引擎）**

Run:
```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml
cargo test --manifest-path core/ffi/Cargo.toml
```
Expected: 全部通过。

- [ ] **Step 4: 更新 `BUILD.md`**

在「## 运行」之后新增一节：

```markdown
## 打包分发

```bash
scripts/package.sh
```

产物：`dist/TalkWTF-<version>-arm64.zip`（含 `INSTALL.txt`）。

脚本流程：Release 构建 → 断言 `otool -L` 无构建目录依赖 → `strip -x`
→ ad-hoc 签名 → `ditto` 打 zip。

app 只支持 Apple Silicon（arm64）、macOS 14+。**未公证**，对方首次打开需按
`INSTALL.txt` 绕过 Gatekeeper。
```

- [ ] **Step 5: 更新 `AGENTS.md`**

1. 顶部「不分发、不上架，不需要签名/公证/自动更新基建。」改为：
   `以个人自用为主，可打 zip 小范围分发给朋友；不做公证（不交 Apple 年费），签名用 ad-hoc，靠 INSTALL.txt 绕过 Gatekeeper；不做自动更新。`
2. 「## 硬约束」里 `- **个人使用：不做签名、公证、自动更新。**` 改为：
   `- **个人使用/小范围分发**：不做公证（不交 Apple 开发者年费）、不做自动更新；签名用 ad-hoc。`
3. 「## 阶段计划」末尾追加：
   `18. 自包含打包（子项目 0）— 已完成：静态链接 + ad-hoc 签名 + strip + scripts/package.sh + INSTALL.txt。`
   并加一行多平台计划：`多平台：0 打包已完成；1 Intel/universal、2 内置 Qwen3-ASR、3 公证（否决）、4 Windows（待定）。`

- [ ] **Step 6: 提交**

```bash
git add BUILD.md AGENTS.md
git commit -m "docs: 阶段 18 打包流程 + 分发/签名设定更新"
```

---

## Self-Review

- **Spec 覆盖**：范围 1 静态链接 → Task 1；范围 2 strip → Task 1 Step 3 + Task 2 脚本；
  范围 3 ad-hoc → Task 1 Step 2/3；范围 4 package.sh → Task 2；范围 5 INSTALL.txt → Task 2；
  验收 1/2/3/4 → Task 1 Step 5/6 + Task 2 Step 5 + Task 3 Step 1；验收 5 → Task 3 Step 3。
  无缺口。
- **占位符**：无 TBD/TODO；所有代码块完整。
- **类型/命名一致**：`libtalkwtf_ffi.a` 路径、`dist/TalkWTF-<version>-arm64.zip`、
  `scripts/package.sh`、`INSTALL.txt` 在各任务间一致。
