# Spec: 阶段 9 — SwiftUI 原生外壳 + Rust 核心库（FFI）

状态：**待确认**（2026-09-17）
上游依据：用户 2026-09-17 决定 —— 「整个 app 用 SwiftUI 重写」+「把 Rust 编成库」
参考视觉：Spokenly（原生 SwiftUI，悬浮窗见用户截图 4–7）、Apple 系统设置
前置：阶段 8 的设计语言与 token 继续作为 SwiftUI 的视觉基准；阶段 8 的 **Tauri UI 外壳作废**
（后端逻辑保留）。

## 决策

**最终形态：一个原生 macOS app —— SwiftUI 做外观/外壳，Rust 编成静态库做核心，通过 C FFI 直连。**

```
┌─────────────────────────────────────────────┐
│  TalkWTF.app（Swift / SwiftUI）              │
│  窗口 · 侧栏 · 设置 · Dashboard · 资料库 ·    │
│  词典 UI · 悬浮窗 · 托盘 · 权限 · 全局热键     │
└───────────────┬─────────────────────────────┘
                │  C ABI（静态库 + cbindgen 头文件）
┌───────────────▼─────────────────────────────┐
│  talkwtf-core（Rust，无 Tauri）              │
│  ASR(transcribe.cpp/Qwen3) · 音频采集/VAD ·   │
│  LLM(BYOK) · 提示词 · 词典 · 历史 · 自动学词   │
│  设置读写 · 统计                             │
└─────────────────────────────────────────────┘
```

## 现状（写 spec 前核过的事实）

- crate 已是 `crate-type = ["staticlib", "cdylib", "rlib"]`（`src-tauri/Cargo.toml:15-20`）
  —— **编静态库不需要改 crate 类型**。
- 耦合度：
  - `AppHandle` 出现 **313 次**，但集中在命令/外壳层（`commands/`、`shortcut/`、`actions.rs`、
    `tray.rs`、`overlay.rs`、`lib.rs`）。
  - 核心模块依赖很少：`managers/audio.rs` 5、`managers/transcription.rs` 5、`managers/history.rs` 3、
    `managers/dictionary.rs` 3、`learning/mod.rs` 3、**`llm_client.rs` 0**。
  - `#[tauri::command]` **147 个**；`tauri::` 引用 263 次。
- 核心模块拿 `AppHandle` 主要为了三件事：读设置（`get_settings(app)`）、
  应用数据目录（`portable::app_data_dir(app)`）、发事件（history 更新）。
- 数据目录：`~/Library/Application Support/com.pais.handy/`（settings_store.json、dictionary.db、
  history.db、recordings/）。**新 app 沿用同一 bundle id 即可无缝复用数据。**
- 平台集成现状：全局热键（`shortcut/` + `handy-keys` crate）、托盘（`tray.rs`）、
  悬浮窗（`overlay.rs`，NSPanel + `NSGlassEffectView`）、粘贴/打字（`enigo`）、
  AX 学词（`learning/`）、权限（`tauri-plugin-macos-permissions`）。

## 目标

1. 原生 macOS app：外观 100% SwiftUI，观感与系统设置/Spokenly 一致（含真 Liquid Glass）。
2. Rust 核心零 Tauri 依赖，编成静态库，Swift 通过 C FFI 调用。
3. **保留**本地 ASR 运行时（transcribe.cpp + Qwen3-ASR）、BYOK LLM、词典、历史、自动学词。
4. 数据无缝迁移（同一 bundle id + 现有文件格式）。
5. 悬浮窗按 Spokenly 面板重做（用户截图 4–7）。

## 架构

### 三个 crate / 目标

| 目标 | 语言 | 职责 |
|---|---|---|
| `talkwtf-core`（新 crate，`src/core/`） | Rust | 无 Tauri 的核心：ASR、音频、LLM、提示词、词典、历史、学词、设置、统计 |
| `talkwtf-ffi`（新 crate，`src/ffi/`） | Rust | C ABI：命令分发 + 事件回调 + 内存管理；`cbindgen` 生成 `talkwtf.h` |
| `TalkWTF`（新 Xcode 工程，`macos/`） | Swift/SwiftUI | 全部 UI + 平台集成（窗口/热键/托盘/权限/悬浮窗） |

### 桥的设计（关键）

- **命令用 JSON 分发，避免手写 147 个函数**：
  ```c
  // talkwtf.h
  char *talkwtf_invoke(const char *command, const char *payload_json); // 返回 JSON 字符串（调用方 free）
  void  talkwtf_free_string(char *s);
  ```
  Rust 侧把现有 `#[tauri::command]` 逻辑改为普通函数 + 一个 `match command` 分发器
  （复用现有 `serde` 结构，几乎零改写）。
- **事件用回调**：
  ```c
  typedef void (*talkwtf_event_cb)(const char *event_json, void *userdata);
  void talkwtf_set_event_callback(talkwtf_event_cb cb, void *userdata);
  ```
  Rust 侧把 `app.emit(...)` 换成一个 `EventSink` trait；Tauri 适配层与 FFI 层各实现一次。
  事件：`overlay-state`、`stream-text`、`stream-phase`、`learned`、`history-updated`、
  `recording-error`、`theme-changed` 等（现有事件名不变）。
- **生命周期**：`talkwtf_init(config_json)` / `talkwtf_shutdown()`；配置含数据目录、语言、provider 等。
- **线程**：Rust 内部保留现有线程模型；回调从 Rust 线程触发，Swift 侧 `DispatchQueue.main.async` 派发到主线程。
- **错误**：`invoke` 返回 `{"ok":...}` 或 `{"error":"..."}`；Swift 侧解码。

### 平台集成放哪

| 能力 | 放哪 | 理由 |
|---|---|---|
| 全局热键 | **Swift**（Carbon `RegisterEventHotKey` / `KeyboardShortcuts`） | 原生、不占 Rust 主循环；但 push-to-talk/hold-or-toggle 逻辑要移植（现有 `transcription_coordinator.rs` 的状态机可参考/移植） |
| 悬浮窗 | **Swift**（NSPanel + SwiftUI + `.glassEffect()`） | 真原生玻璃（macOS 26 `glassEffect`），比 webview 更接近 Spokenly |
| 托盘 | **Swift**（`NSStatusItem`） | 原生 |
| 权限引导 | **Swift** | 原生 |
| 粘贴/打字 | **Rust**（`enigo`，已有且稳） | 通过 `invoke("paste", ...)` |
| 音频采集/VAD | **Rust**（现有） | 核心 |
| ASR/LLM/词典/历史/学词 | **Rust** | 核心 |

> 说明：热键若移植到 Swift，`transcription_coordinator` 的 hold/tap 状态机是纯逻辑，可 1:1 移植；
> 也可先保留 Rust 热键（`handy-keys`）经回调驱动 Swift，二期再迁。

## 分阶段

### P0 Spike（先跑通，风险最低）
- 建最小 `talkwtf-ffi`（导出 `talkwtf_version()` 与一个 `invoke("ping")`）+ cbindgen 头文件。
- 建最小 SwiftUI app，链接静态库，调用并显示结果。
- 验证：`cargo build --release --target aarch64-apple-darwin` → `.a` + `.h` → Xcode Run Script 链接 → Swift 调通。
- **不碰现有 app**。

### P1 抽出 `talkwtf-core`（Rust 内部重构，Tauri app 继续可用）
- 引入 `CoreContext`（设置读写、数据目录、`EventSink`）替代核心层的 `AppHandle`。
- 把 `managers/*`、`llm_client`、`learning/*`、`settings`、`catalog`、`audio_toolkit` 移入 core。
- Tauri 侧保留一个薄适配层（`AppHandle` → `CoreContext`），**保证现有 app 仍能编译运行**（回归基线）。
- 验证：`cargo test --lib` 全绿 + 现有 app 真机跑通。

### P2 FFI 完整化
- `talkwtf_invoke` 覆盖全部现有命令（设置、词典、历史、场景、翻译、Dashboard、模型…）。
- 事件回调覆盖全部事件。
- cbindgen 生成头文件；单测：JSON 分发与错误路径。

### P3 SwiftUI 外壳
- 主窗口（`NavigationSplitView`）：概览 / 资料库 / 设置；设置用 `Form` + 原生控件。
- 视觉沿用阶段 8 的 token（字号/间距/圆角），但用 SwiftUI 原生实现。
- Dashboard / 资料库 / 词典界面接 `invoke`。

### P4 悬浮窗（Spokenly 面板）
- NSPanel + SwiftUI + `glassEffect`；面板布局：状态点 + 工作流标签 + 计时 / 全宽波形 / 提示行。
- 状态：录音 / 处理中 / 失败+重试 / 学习提示+撤销。
- 通过事件回调驱动。

### P5 平台集成 + 收尾
- 热键（原生）、托盘、权限、开机启动、主题跟随、i18n（Swift String Catalog 或复用 JSON）。
- 迁移检查：复用 `com.pais.handy` 数据目录；老设置/词典/历史可读。
- 移除 Tauri 依赖与 `src/`（React）代码。

## 非目标

- 签名/公证/自动更新（个人使用）。
- 自建云/账号/遥测（硬约束不变）。
- 改 ASR 运行时（transcribe.cpp/Qwen3 原样保留）。
- Windows/Linux（本阶段只做 macOS）。
- 重写 Rust 的算法/业务逻辑（只做「去 Tauri 化 + 接 FFI」）。

## 验收标准

1. `TalkWTF.app` 为原生 SwiftUI 应用；设置页控件为真原生（开关/下拉/分段/按钮）。
2. 悬浮窗为原生 NSPanel + `glassEffect`，布局对标 Spokenly 面板；白底干净。
3. 听写（转录+润色）、翻译、词典、历史、自动学词、Dashboard 功能与现状一致。
4. 数据无缝：沿用 `com.pais.handy` 目录，老数据可读。
5. 无 Tauri/React 运行时依赖（`src/` 与 `src-tauri` 的 Tauri 层移除）。
6. `cargo test --lib` 全绿；Swift 侧可编译运行；真机冒烟通过。
7. 无自建云/账号/遥测；除用户配置的 provider 外不联网。

## 风险与对策

| 风险 | 对策 |
|---|---|
| 构建链复杂（静态库 + Xcode 链接 + 架构） | **P0 先跑通**；用 Run Script 构建 `.a` 与头文件；只做 arm64 |
| 异步/线程跨 FFI 回调 | 回调统一 JSON；Swift 侧一律 `DispatchQueue.main`；Rust 不回调进 Swift 后再调 Rust（避免重入） |
| 内存管理 | 所有返回字符串由 `talkwtf_free_string` 释放；Swift 用 `defer` 包一层 |
| 147 命令迁移量大 | JSON `invoke` 分发，复用现有函数体；设置类命令泛化 |
| 热键状态机移植 | 先保留 Rust 热键经回调，二期再迁 Swift |
| 数据格式漂移 | 保持 `settings_store.json`/`dictionary.db`/`history.db` 格式不变 |
| 阶段 8 的 Tauri UI 作废 | 保留其设计 token 与视觉决策，作为 SwiftUI 的实现基准 |

## 任务拆分（粗）

- [x] **P0** 最小 FFI + SwiftUI app 跑通（版本/ping + 事件回调）
- [x] **P1** 抽出 `talkwtf-core`（引擎层全部入 core；src-tauri 变薄适配层）
- [x] **P2** `invoke` 全命令 + 事件回调（手写 `talkwtf.h`）
- [x] **P3** SwiftUI 主窗口 / 设置 / 资料库 / Dashboard
- [x] **P4** 原生悬浮窗（NSPanel + glassEffect）
- [x] **P5** 热键 / 托盘 / 权限 / i18n / 数据迁移 / 移除 Tauri

### P5 完成记录（2026-09-17）

**原生能力补齐**
- 提示音：`SoundPlayer.swift`（`NSSound`，读 `resources/*.wav`，自定义主题读 AppData）
- 开机启动：`Autostart.swift`（`SMAppService.mainApp`）+ 清理旧 launch agent
- 托盘：`TrayController.swift`（`NSStatusItem`）
- 权限：`Permissions.swift` + `OnboardingView.swift`（麦克风 / 辅助功能，轮询授权状态）
- i18n：`Localization.swift` + `Languages.swift`，复用 `resources/locales/` 26 个语言包，
  复刻 Tauri 的语言码解析（`zh-Hans-CN`→`zh`、Hant→`zh-TW`）
- 按键模式：`DictationController.swift` 支持 toggle / push-to-talk / hold-or-toggle
- 设置：通用 / 个性化（provider·风格·场景·翻译）/ 模型 / 声音 / 高级 / 调试 / 关于
- 资料库：历史（搜索·复制·删除）+ 词典（词·规则·学词拒绝名单·导入导出）

**导入导出搬进 core**（Tauri 与 SwiftUI 共用）
- `core/core/src/dictionary_io.rs`、`core/core/src/polish_profile.rs`；
  src-tauri 改为薄委托，测试一并迁移

**新增 FFI 命令**
`is_accessibility_trusted` / `get_available_accelerators` / `list_input_devices` /
`list_output_devices` / `unload_model` / `export_dictionary` / `import_dictionary` /
`export_polish_profile` / `import_polish_profile`

**移除 Tauri 与 React**
- 删除 `src/`、`src-tauri/`、JS 工具链（package.json / vite / tsconfig / eslint /
  prettier / playwright / node_modules / dist / public / tests）、`.github/`、Nix
  （`flake.nix` / `flake.lock` / `nix/` / `.nix/`）、`.cargo/`、上游 Handy 文档与
  `sponsor-images/`
- 共享资产迁到仓库根：`resources/`（原 `src-tauri/resources`）、
  `resources/locales/`（原 `src/i18n/locales`）；Xcode 复制阶段合并为一条
- `scripts/check-translations.ts` → `scripts/check_translations.py`（不再依赖 bun）
- 删除 `ContentView.swift`（P0 spike）与 `MigrationProgress.swift`（迁移已完成）
- 重写 `README.md` / `BUILD.md`，更新 `AGENTS.md` 的技术栈与代码地图

**验证**
- core 275 / ffi 6 测试通过；两边 `cargo fmt --check` 绿
- `python3 scripts/check_translations.py` 25 个语言全部通过
- Xcode BUILD SUCCEEDED；真机运行：七个设置面板 + 资料库渲染正常、中文本地化生效
- 无头冒烟：`cargo run --example smoke` → 转录 + DeepSeek 润色成功

**未做**
- App 图标（原 Handy 图标含商标，已随 `src-tauri/icons` 删除；需要自备）
- 悬浮窗状态机（learned / translation_failed + retry / notice / translating）
- 历史 re-transcribe；麦克风选择真正下发到 audio manager
- 键盘诊断 / hold-threshold 调试面板

## 待确认

1. **热键**：先保留 Rust 的（`handy-keys` + coordinator，经回调驱动 Swift），还是一开始就移植到 Swift？
   （建议先保留，P5 再迁）
2. **Xcode 工程**：新建 `macos/TalkWTF.xcodeproj`，还是用 Swift Package（`Package.swift`）+ 一个可执行 target？
   （建议 Xcode 工程，方便资源/权限/打包）
3. **i18n**：复用现有 26 个 JSON 语言包（Rust 读，Swift 显示），还是改用 Swift String Catalog？
   （建议复用 JSON，零翻译成本）
4. **Dashboard/资料库** 是否与设置一起在 P3 做，还是拆到 P5？
5. 是否同意**先把 P0 跑通再继续**（我会先交付一个能显示 "Rust core connected: v0.9.6" 的 SwiftUI 窗口）？

## 已确认（2026-09-17）

1. 先跑 **P0 spike** 再继续。
2. 全局热键**先保留 Rust**（`handy-keys` + coordinator，经回调驱动 Swift），P5 再迁。
3. 用 **Xcode 工程**（`macos/TalkWTF.xcodeproj`）。

## P0 实现记录（2026-09-17，已完成）

**新增**

- `core/ffi/`（Rust crate `talkwtf-ffi`，`crate-type = ["staticlib","cdylib"]`）：
  - `talkwtf_version()`、`talkwtf_invoke(command, payload_json)`、`talkwtf_free_string()`、
    `talkwtf_set_event_callback(cb, userdata)`。
  - `invoke` 用 JSON 分发（P0 只有 `ping` / `emit_test_event`），返回 `{"ok":…}` / `{"error":…}`。
  - 事件回调用 `AtomicPtr` 存函数指针；`emit_event()` 供核心调用。
  - 4 个单测（含 C ABI 往返与空指针）。
  - 头文件 `core/ffi/include/talkwtf.h`（手写，注明与 lib.rs 同步）。
- `macos/TalkWTF.xcodeproj`（手写 pbxproj）：macOS App target，SwiftUI；
  - Run Script 构建阶段 `cd core/ffi && cargo build --release --target aarch64-apple-darwin`；
  - `HEADER_SEARCH_PATHS` → `core/ffi/include`；`LIBRARY_SEARCH_PATHS` → `core/ffi/target/…/release`；
    `OTHER_LDFLAGS = -ltalkwtf_ffi`；`SWIFT_OBJC_BRIDGING_HEADER` → `TalkWTF-Bridging-Header.h`；
  - `CODE_SIGN_IDENTITY = "-"`（本地 ad-hoc）、`ENABLE_USER_SCRIPT_SANDBOXING = NO`、
    `bundle id = com.pais.handy`（沿用数据目录）。
- `macos/TalkWTF/`：`TalkWTFApp.swift`（注册事件回调）、`ContentView.swift`（ping / 事件展示）。

**验证**

- `cargo test`（core/ffi）4 passed；`nm` 确认 4 个 C 符号导出。
- `xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build` → **BUILD SUCCEEDED**。
- 真机运行：窗口显示 `Rust core connected: 0.9.6`；`invoke("ping")` 返回 Rust 生成的 JSON；
  `emit_test_event` 后 **事件通道显示** `{"event":"test","message":"hello from Rust"}`
  —— Swift→Rust（命令）与 Rust→Swift（事件）**双向打通**。

**结论**：桥的方案（静态库 + JSON invoke + C 回调）可行，可以进入 P1。

## P1 进行中记录（2026-09-17）

### 已完成

- **新 crate `core/core`（`talkwtf-core`，无 Tauri）**，已迁入：
  - `settings.rs`（原 2644 行，42 个单测）——store 从 `tauri-plugin-store` 改为**直接读写
    `data_dir/settings_store.json`**（格式仍是 `{"settings": …}`，与旧文件兼容）；
    新增 `init(data_dir)` / `set_locale(locale)` / `set_resource_dir(dir)` / `current()` / `store()` /
    `data_dir()` / `resource_dir()` / `legacy_custom_words()`。
    去掉了 `From<LogLevel> for tauri_plugin_log::LogLevel`（改由外壳转换）。
  - `dictionary.rs`（973 行，18 个单测）——`new()` 不再要 `AppHandle`。
  - `history.rs`（1072 行，3 个单测）——`new()` 无 `AppHandle`；4 处 emit 改为
    `crate::events::emit("history-update-payload", …)`；WAV 读取改用 core 的 `wav`。
  - `llm_client.rs`（776 行，13 个单测）——零改动（原本只依赖 settings）。
  - `wav.rs`——从 `audio_toolkit/audio/utils.rs` 抽出的 WAV 读写（read/verify/save）。
  - `events.rs`——`EventSink` trait + 全局 `set_sink`/`emit`（`emit` 是泛型，签名贴近原 `app.emit`）。
  - `model/`（`mod.rs` + `download.rs` + `download/tests.rs`，3090 行）——`new()` 无 `AppHandle`；
    emit 走事件通道；资源路径改用 `settings::resource_dir()`。
  - `model_capabilities.rs`、`gguf_meta.rs`、`catalog/`（含 `catalog.json`）——纯逻辑，零改动。
  - `learning/`（`mod` / `watcher` / `diff` / `ax/*`）——`LearningState` 从 Tauri state 改为 core 全局；
    `watch_for_edit(pasted_text)` 不再收 `AppHandle`；`learned-correction` 与 `learned-overlay`
    经事件通道发出（shell 负责显示悬浮窗）。
  - `secure_input.rs`——只搬「实时检测」（`is_enabled_now`）；监控线程 / Carbon fallback / 托盘
    留在外壳。
  - `state.rs`——core 的共享单例（`dictionary_store`）。
  - `audio_toolkit/`（整棵树，含 cpal 采集、重采样、VAD、文本后处理）——**零 Tauri 依赖**，整搬。
  - `audio.rs`（1101 行）——`new(stream_router)` 无 `AppHandle`；VAD 模型路径改用 `settings::resource_dir()`；
    麦克风电平改走 `events::emit_mic_levels`（节流 + 可开关）；延迟关闭线程改用 core 的
    `state::audio_manager()`（Weak）。
  - `transcription.rs`（2551 行）——`new(model_manager)` 无 `AppHandle`；`StreamPhaseEvent`/`StreamTextEvent`
    改走事件通道；`apply_accelerator_settings()` 不再收 `AppHandle`；`dictionary_snapshot()` 用
    `state::dictionary_store()`；`redact_text`/Windows 检测抽到 `util.rs`。
  - `helpers/clamshell.rs`（纯检测部分）；`util.rs`。
  - `state.rs` 扩展：`audio_manager`（Weak）+ `dictionary_store`。
- **Tauri 侧接线**：`lib.rs` 安装 `TauriEventSink`（把 core 事件转发到 `app.emit`），
  并调用 `settings::init(app_data_dir)` / `set_locale(...)`。
- **`src-tauri` 变成薄适配层**：`settings.rs` / `managers/dictionary.rs` 只做
  `pub use talkwtf_core::…` + 保留原 `AppHandle` 签名包装，其余代码零改动。
- **启动接线**：`lib.rs` 的 setup 里调用 `talkwtf_core::settings::init(portable::app_data_dir(..))`
  与 `set_locale(tauri_plugin_os::locale())`。
- **验证**：`talkwtf-core` 60 passed；`handy` 306 passed（原 366 − 60 已迁出）；
  `talkwtf-ffi` 4 passed；三边 `cargo fmt --check` 通过；前端 lint/build/translations 全绿。
  真机重启 Tauri app：0 ERROR，日志 `talkwtf_core::settings` 成功读取现有 store（数据无损）。

### 未完成（下一步）

- **管线** `actions.rs` / `transcription_coordinator.rs`——Tauri 耦合最重（overlay / tray / paste /
  热键 / `AppHandle`），需要先在 core 定义 `Shell` trait（overlay 显示、托盘状态、粘贴、声音）
- 外壳模块：`shortcut/`（含 handy-keys 热键）、`tray`、`overlay`、`input`（enigo）、`clipboard`、
  `utils`、`portable`、`signal_handle`、`audio_feedback`、`commands/`
- 之后才是 P2（FFI 命令面）/ P3（SwiftUI 界面）/ P4（原生悬浮窗）/ P5（平台集成）

### 进度小结（截至本次）

| 模块 | 状态 |
|---|---|
| settings / dictionary / history / llm_client / wav / events / util | ✅ 已入 core |
| model / model_capabilities / gguf_meta / catalog | ✅ 已入 core |
| learning / secure_input（纯检测）/ state / audio_toolkit / helpers | ✅ 已入 core |
| **audio（采集）/ transcription（ASR 调度）** | ✅ 已入 core |
| pipeline / shortcut / tray / overlay / input / clipboard / utils / portable / commands | ⏳ 待迁 |

**core 已承接全部「引擎」层**（设置、数据、模型、音频采集、ASR、LLM、词典、学词）。
剩下的是「外壳」层（窗口/托盘/热键/粘贴/悬浮窗）——这部分在 Swift 版里本来就要用原生重写，
所以 P1 的核心目标（把引擎与外壳解耦）已基本达成。

## P2 进行中记录（2026-09-17）

- `engine.rs`：`init()` 无 Tauri 构造并注册全部 manager（模型/转写/音频/历史/词典）。
- `state.rs` 扩展为引擎注册表（model / transcription / history / dictionary / audio(Weak)）。
- `dashboard.rs` 从 `src-tauri/commands/` 搬进 core（`get_dashboard_stats()` 不再要 `AppHandle`）。
- **`core/ffi` 命令面**（JSON `talkwtf_invoke`）已实现：
  - `init`（接收 `dataDir` / `resourceDir` / `locale`，建数据目录并启动引擎）
  - 设置：`get_app_settings` / `get_default_settings` / **`update_settings`（泛型 patch 合并）** /
    `get_polish_styles` / `get_translation_languages` / `get_bindings`
  - 场景：`add_scene` / `update_scene` / `delete_scene` / `reset_scene` / `restore_built_in_scenes` /
    `set_active_scene` / `change_polish_style`
  - 翻译：`add_translation_target` / `remove_translation_target` / `set_active_translation_target`
  - 词典：`get_dictionary` / `get_dictionary_limits` / 词与规则 CRUD / 学词拒绝名单 3 个
  - 历史：`get_history_entries` / `toggle_history_entry_saved` / `delete_history_entry` /
    `get_audio_file_path`
  - 模型：`get_available_models` / `get_model_info` / `rescan_local_models` / `delete_model`
  - `get_dashboard_stats`
- **真机验证（SwiftUI）**：`TalkWTF.app` 调用 `init` 后读到真实数据——
  `theme=system`、`polish_style=structured`、`dictionary_words=6`、`history_entries=34`、
  `total_recordings=34`、`total_chars=1816`。**零 Tauri**。
- 静态库链接验证：Xcode 成功链接含 transcribe-cpp / cpal / ort 的完整 `libtalkwtf_ffi.a`。

## P3 进行中记录（2026-09-17）

`macos/TalkWTF/` 新增 SwiftUI 外壳（全部经 FFI 读 core）：
- `CoreClient.swift`——`Core.invoke` 封装 + `Dashboard`/`HistoryEntry`/`Dictionary` 解码
- `AppShell.swift`——`NavigationSplitView`：侧栏（概览 / 资料库 / 设置）+ 设置二级列表
  （通用 / 个性化 / 模型 / 关于）；启动时后台 `Core.initialize()`（引擎加载不阻塞 UI）
- `DashboardView.swift`——指标卡（总录音/口述时长/字数/节省时间/翻译次数/个性化程度）+ 服务状态
- `LibraryView.swift`——历史列表（搜索 + 相对时间 + 字数）与词典（词汇 / 纠正规则）
- `SettingsView.swift`——原生 `Form`：主题 / 润色风格 / 自动学词 / 输出开关、
  翻译目标语言（增删 + 设为当前）、模型列表（使用）、关于

**真机验证**：Dashboard 显示真实数据 34 录音 / 6m51s / 1816 字 / 节省 8m16s / 9 翻译 / 个性化 80%；
服务状态 Qwen3-ASR ✅ + DeepSeek ✅。**零 Tauri**。

## P5 进行中记录（2026-09-17）

- **管线入 core**：`pipeline.rs`——把 `actions.rs` 的 `build_system_prompt` / `BASE_PROMPT` /
  `build_user_content` / `strip_*` / `is_blank_transcription` / `post_process_transcription` /
  `maybe_convert_chinese_variant` / `resolve_effective_language` / `record_llm_usage` /
  `ProcessedTranscription` / `ProcessingMode` 搬进 core；src-tauri 改为 `pub use` + 薄包装，
  **提示词单一来源**（避免两个 shell 漂移）。Apple Intelligence 分支在 core 里改为「交给外壳」。
- **`dictation.rs`**：`start(mode)` / `stop(mode) -> String` / `cancel()`——录音→转写→（OpenCC）→
  润色或翻译，返回最终文本；外壳负责触发与粘贴。
- **FFI**：`start_dictation` / `stop_dictation` / `cancel_dictation`。
- **Swift**：`DictationController.swift`——Carbon `RegisterEventHotKey`（Option+Space，切换式）→
  调 core 听写；`Paster`（剪贴板 + CGEvent Cmd+V，粘贴后恢复剪贴板）；
  悬浮窗接**真实 mic-level**（core `emit_mic_levels` → FFI 事件 → `NotificationCenter`）。
- 验证：core 266 / ffi 6 / src-tauri 100；三边 fmt 绿；前端 lint/build 绿；Xcode BUILD SUCCEEDED；
  Swift app 启动无错误。

### 待办（P5 剩余）

- 托盘（`NSStatusItem`）、权限引导（麦克风/辅助功能）、开机启动
- i18n（复用现有 26 个 JSON 语言包）
- 数据迁移校验（沿用 `com.pais.handy` 目录，已验证可读）
- 移除 Tauri 依赖与 `src/`（React）代码
- 真机听写冒烟（需用户按 Option+Space 实测）

### 待办（P2 剩余）

- 异步命令的阻塞桥（`fetch_post_process_models` / `download_model` / `retry_history_entry_transcription`）
- `get_current_model` / `set_active_model`（需要转写管理器）与下载进度事件
- `diagnose_edit_learning`、`undo_last_dictionary_learning`（依赖学词状态）
- 词典/场景导入导出（`export_*` / `import_*` 的路径式命令）
- 事件名与载荷对齐（overlay / stream / learned 已由 core 发出，Swift 侧待接）

### 设计问题（需要定方案）

**事件类型与 specta 的耦合**：`HistoryUpdatePayload` / `StreamTextEvent` / `StreamPhaseEvent` /
`LearnedCorrection` 目前用 `#[derive(tauri_specta::Event)]`，而 `tauri-specta` 依赖 `tauri`
（`Event::emit` 需要 `Emitter`）。把类型搬进 core 会破坏「core 无 Tauri」。

**候选方案**：
1. core 只放**纯 serde** 的事件载荷，经 `EventSink` 以 JSON 发出（事件名保持
   `history-update-payload` 等）；Tauri 侧保留一份**specta 镜像类型**仅用于生成 TS 类型。
   代价：类型定义有两份，需保持同步。
2. **事件发射上移到外壳**：core 的方法返回「发生了什么」，由外壳负责 `app.emit`。
   代价：要改 `save_entry`/`toggle_saved_status` 等的返回与调用点，改动更大但架构更干净。
3. 给 core 加 `tauri-specta` 依赖（只为 derive）。**否决**：会把 tauri 拖进 core。

倾向 **方案 1**（改动最小、可立即推进），把方案 2 记为后续清理目标。
