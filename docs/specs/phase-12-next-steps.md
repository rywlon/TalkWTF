# 阶段 12：悬浮窗工作流提示 + 自动学词 + UI 优化

> 交接文档。上一阶段（9 P3–P5 / 10 / 11）已提交在 `f214abb`。
> 本文档面向**新会话**，包含：项目现状、环境坑、待办事项（含已核实的证据与线索）。

---

## 一、项目现状

个人自用的 macOS 语音听写 app。**原生 SwiftUI 外壳 + Rust 引擎，零 Tauri/React。**

```
macos/TalkWTF.xcodeproj     SwiftUI app（24 个 .swift）
        │  C FFI（JSON invoke + 事件回调）
core/ffi                    talkwtf-ffi：staticlib + 手写 talkwtf.h
core/core                   talkwtf-core：全部引擎逻辑（288 测试）
resources/                  随包资源（locales 26 语言 / models / 提示音）
scripts/                    Python（翻译检查、图标生成、目录生成）
docs/specs/                 各阶段 spec 与实现记录
```

**数据目录**：`~/Library/Application Support/com.pais.handy/`
（`settings_store.json` / `history.db` / `dictionary.db` / `recordings/`）

**已实现**：听写（转录+润色）、自动翻译、润色风格+场景、词典+纠正规则、自动学词、
历史（播放/重转录/删除）、Dashboard、悬浮窗、托盘、权限引导、26 语言、快捷键自定义、
Secure Input 检测 + Carbon 兜底。

---

## 二、环境与命令（重要，踩过的坑）

```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"

# 构建 app
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
# 产物：macos/build/Debug/TalkWTF.app
# 注意：没有 scheme，必须用 -target；新增 .swift 要手工在 pbxproj 四处登记
#      （PBXBuildFile / PBXFileReference / group children / Sources）

# 测试（必须绕过本机代理，否则 localhost 被拦）
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml
cargo test --manifest-path core/ffi/Cargo.toml
cargo fmt --manifest-path core/core/Cargo.toml --check
cargo fmt --manifest-path core/ffi/Cargo.toml --check
python3 scripts/check_translations.py     # 26 个语言包 key 一致性

# 看 Rust 日志：必须直接跑二进制（FFI 里装了 stderr logger）
macos/build/Debug/TalkWTF.app/Contents/MacOS/TalkWTF

# 无头端到端
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo run --manifest-path core/core/Cargo.toml --example smoke
cargo run --manifest-path core/core/Cargo.toml --example dictation -- 3
```

**其他坑**：

- **改 Rust 命令/事件后必须重启 app**，Swift 侧按名字调 `Core.invoke`，没有生成绑定。
- **`resourceDir` 传的是仓库根目录，不是 `resources/`**。core 内部按
  `<resource_dir>/resources/...` 解析；传 `.../resources` 会变成 `resources/resources/...`
  （这个坑踩过两次）。
- **release 静态库要单独重建**：harness 链接的是
  `core/ffi/target/aarch64-apple-darwin/release/libtalkwtf_ffi.a`，
  只跑 `cargo build`（debug）不会更新它：
  `cargo build --release --target aarch64-apple-darwin --manifest-path core/ffi/Cargo.toml`
- **AX 测试**：命令行工具继承 Terminal 的辅助功能授权。读焦点元素时**目标 app 必须是前台**，
  否则读到的永远是 Terminal。要测 AX 相关功能，让 harness 自己
  `NSRunningApplication.activate()` 把目标 app 拉到前台。
- **测试隔离**：`settings::init` / `state::set_*` 都是进程级 `OnceLock`，测试共享一个进程。
  写依赖它们的测试要先判断「这个 dir 是不是我的」，否则别的测试删掉临时目录后你会拿到 I/O 错误。
- 已知 flaky：`clipboard::tests::external_script_does_not_wait_for_inherited_stdio`（与本项目无关）。
- 存量 warning：`managers/transcription.rs` 的 `model_takes_initial_prompt`（别动）。

---

## 三、待办

### P1-A　悬浮窗没有「正在做什么」的提示（用户反馈 #1）

**现象**：录音/处理时看不出当前是普通听写、润色还是翻译。

**已核实的代码事实**：

- core **已经**把工作流信息发出来了：`core/core/src/dictation.rs` 的
  `emit_overlay_state(state, label, kind)` 在 `start()` 里对翻译模式带了 label，
  在 `stop()` 里发 `transcribing` → `processing`（听写）/ `translating`（翻译）。
- **Swift 侧把 label 丢了**：`macos/TalkWTF/OverlayPanel.swift` 的 `content` 里，
  `case .recording, .streaming:` 分支**只画状态点 + 波形，完全没有渲染 label**。
  翻译模式录音时应该显示「翻译为 X」。
- 处理态文案对得上（`overlay.transcribing` / `overlay.processing`），
  但 `processing` 显示的是「处理中…」，无法区分转录/润色/翻译。

**旧版（已删除的 React 版）是怎么做的**（`git show HEAD~1:src/overlay/RecordingOverlay.tsx`）：

- 录音行是「状态点 | **波形 或 翻译标签** | 计时 + 取消」——
  翻译模式下用「翻译为 X」**替换**波形（两者同时显示会重叠），
  普通听写显示波形。**并且有一个录音计时器**（`fmtTime(elapsed)`），当前 Swift 版没有。
- 工作行是「spinner | 文案 | 取消」，文案 =
  翻译 ? `overlay.translate.working`（翻译中…）
  : 润色 ? `overlay.processing`（处理中…）
  : `overlay.transcribing`（正在转录…）。

**建议改法**：

1. `OverlayState.recording/streaming` 增加 `label: String?`（翻译目标）；
   core 已经在发，`OverlayController.decode` 里把 label 透传过去即可。
2. 渲染：label 有值时显示「翻译为 X」并隐藏波形（照旧版避免重叠）。
3. 加录音计时（旧版有，能明确「正在录音」）。
4. 处理态文案按 mode 区分：转录中 / 润色中 / 翻译中。
   若需要新 key，参考 `resources/locales/en/translation.json` 的 `overlay.*`；
   加 key 必须同步 26 个语言包，否则 `scripts/check_translations.py` 会失败。

**验证方式**：用户按自己的热键实测（三个绑定：`option_right+fn+left` 听写 /
`+up` 备用 / `+down` 翻译）。合成 CGEvent 触发不了 handy-keys 的 tap，别在这上面浪费时间。

---

### P1-B　自动学词「跟老版本不一样 / 坏了」（用户反馈 #2）

**已核实的结论：算法本身没有改，是设置值被写坏导致行为不同。**

**证据链**：

1. `core/core/src/learning/diff.rs` 与首次实现（commit `8568117`）**逐字节一致**，
   `watcher.rs` 的观察窗口/结算逻辑也一致。所以「学词算法」没有回归。
2. **根因**：上一阶段我把 `word_correction_threshold` 做成了整数输入框，
   把它的值写成了 `0.0`（正确默认是 `0.18`）。这个阈值是
   `apply_custom_words` 的 Levenshtein 归一化上限——
   **0.0 等于只接受完全匹配**，于是「学到的词」永远不会去纠正下一次的近似听错。
   用户看到的就是「学了但没用」→ 判定为坏掉。
   - 该值**已还原为 0.18**，UI 也改成了 0–1 滑块（阶段 11）。
   - 但**需要用户重新实测确认**。
3. 走不走模糊纠正在 `core/core/src/transcription.rs:1507` 附近判断：
   `custom_words_already_prompted = model_is_whisper`——
   用户用 Qwen3-ASR（非 Whisper），所以**会**走模糊纠正，阈值才会生效。

**另一个真实的设计缺陷（CJK 粒度）**：

- `diff.rs::expand_to_token_bounds` 对 CJK 把**每个汉字都当边界**，
  所以中文纠错只会学到**单个字**。实测：把「浏览**起**搜索」改成「浏览**器**搜索」，
  学到的是 `起 → 器`，而不是「浏览器」。
- 单个汉字的字典词几乎没有纠正价值（阈值再合理也难命中）。
- 用户真实场景是**中英混说里的英文/术语**（词典里现存 `Cica Exo` / `Hydra facial` /
  `Yuki` / `tripod` 都是拉丁词），这类走 ASCII 分支会扩到空白边界，学整个词，是正常的。
- **建议**：中文场景把学习粒度从「单字」放宽到「词/短语」——
  例如以标点或长度窗口（2–6 字）为界，或复用 `MIN_CJK_SPAN_CHARS`
  并让 CJK 也向两侧扩到标点/句读。需要先明确期望粒度，属于**行为变更**，
  建议先跟用户确认。

**建议的验证方式**（阶段 11 用过、有效）：

- 用 TextEdit + harness：`watch_for_edit("我用了浏览起搜索")` → 改文本 →
  等 ~5 秒（`SETTLE`）→ 看 `get_dictionary` 是否多词；
  `diagnose_edit_learning` 会给出 `outcome` / `polls (readable)` / `candidate`。
  **注意 TextEdit 必须真前台**（见「环境与命令」的 AX 说明）。
- 撤销路径：`undo_last_dictionary_learning` → 词被删 + 误听文本进拒绝名单
  （`list_learning_rejections`）。
- 端到端「学到 → 下次听写生效」目前只能靠用户真机口述验证。

**顺带建议**：把 `word_correction_threshold` 的滑块下限从 `0.0` 提到 `0.01`，
避免用户把功能拖成「关闭」而不自知。

---

### P1-C　悬浮窗液态玻璃（用户反馈 #8，部分完成）

阶段 11 已做：中心震荡波形、去常驻取消键、悬停双按键（✕ 丢弃 / ✓ 完成并输入）。
用户仍反馈「这个语音也要用上液态玻璃的效果，现在可能还是有点奇怪」。

- 当前实现：`OverlayView.body` 用 `.glassEffect(.regular, in: .rect(cornerRadius:))`
  （macOS 26+），旧系统回退 `.ultraThinMaterial`。
- 需要用户提供「哪里奇怪」的具体描述或截图；可能的方向：玻璃层次/亮度、
  尺寸与内边距、状态点与波形的视觉权重、hover 变暗的幅度。

---

### P2　其他 UI 优化（用户说部分自己做）

用户原话：「还有一些其他的 UI 优化呀之类的，这些东西不打算交给你做了」——
**这部分先不要动**，等用户明确要做什么再做。

已知可改进点（仅供参考，勿擅自开工）：

- 设置页各 pane 的分组标题与页面标题重复（如「通用」下面又是一个「通用」分组）。
- Dashboard 的「今日」与「累计」在数据相同时看起来冗余。
- 悬浮窗没有录音计时（见 P1-A）。

---

## 四、代码地图（改动时先看这里）

| 关注点 | 文件 |
|---|---|
| 悬浮窗状态机 + 渲染 | `macos/TalkWTF/OverlayPanel.swift` |
| 听写编排（触发→录音→转录→润色→保存历史） | `core/core/src/dictation.rs` |
| 悬浮窗状态事件来源 | `dictation.rs::emit_overlay_state`（事件名 `overlay-state`） |
| 自动学词 | `core/core/src/learning/{watcher,diff,ax/*}.rs` |
| 自定义词模糊纠正 + 阈值 | `core/core/src/audio_toolkit/text.rs::apply_custom_words` |
| 转录后处理调用点 | `core/core/src/transcription.rs:1144 / 1507` |
| 设置读写 | `core/core/src/settings.rs` |
| FFI 命令分发 | `core/ffi/src/lib.rs`（新增命令后同步 `include/talkwtf.h` 如需） |
| 设计 token | `macos/TalkWTF/Theme.swift`（**别在视图里写魔法数字**） |
| Swift 事件路由 | `macos/TalkWTF/TalkWTFApp.swift` + `OverlayController.start()` |

**事件名一览**（core → shell）：`overlay-state`、`learned-correction`、
`learned-overlay`、`history-update-payload`、`dictionary-changed`、`hotkey`、
`mic-level`、`model-download-progress`、`secure-input-changed`、`settings-changed`。

---

## 五、开工前必读

1. `AGENTS.md` —— 硬约束（无自建云/账号/遥测；BYOK 允许）、UI 风格、阶段计划、已知遗留。
2. `docs/specs/phase-11-fixes-and-glass.md` —— 上一阶段的完整记录与验证清单。
3. `docs/specs/phase-8-native-ui-system.md` —— UI 设计系统（`Theme.swift` 的出处）。
4. `docs/specs/phase-9-swiftui-native-shell.md` —— 架构与迁移记录。

**工作流约定**（AGENTS.md）：先 spec 再代码；小步可验证；完成前必须跑构建/测试，
未通过不许说「完成」；不要提交除非用户明确要求。

---

## 六、建议的开工顺序

1. **先跟用户确认 P1-B 的中文学词粒度期望**（是「学单个字」还是「学词/短语」）——
   这是行为变更，猜错会白做。
2. **P1-A 悬浮窗提示**（改动小、用户感知强、core 已备好数据，只差渲染）。
3. **P1-B 阈值验证**（已还原 0.18，请用户实测；顺手把滑块下限提到 0.01）。
4. **P1-C 玻璃细节**（需要用户给具体描述）。
5. P2 等用户指派。
