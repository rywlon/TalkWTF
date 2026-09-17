# 阶段 10：收尾（补缺 + UI 打磨）

> 前置：阶段 9 已完成（SwiftUI + FFI 架构落地，Tauri/React 已移除）。
> 本阶段只补「缺失/不能用」的东西并统一视觉，**不新增功能概念**。

## 目标

1. 修掉 SwiftUI 侧因**字段名与 FFI 响应不匹配**而失效的控件（审计已发现 7 处）。
2. 补齐阶段 9 遗留的原生能力：悬浮窗状态机、历史 re-transcribe、Dashboard 今日/近 7 天/token。
3. 补 App 图标。
4. 统一 UI：所有设置页用同一套 Form 风格；补上未暴露的设置项。

## 范围

### A. 修 bug（字段名不匹配）

| # | 位置 | 现状 | 正确 |
|---|---|---|---|
| A1 | `PersonalizationView` 润色风格 Picker | 读 `style["id"]` | 读 `value`（`get_polish_styles` 返回 `{value,label}`） |
| A2 | `PersonalizationView` 翻译目标 Picker | 读 `$0["code"]` | 读 `value`（`get_translation_languages` 同形） |
| A3 | `ModelsView` / `SettingsView` 加速器选项 | 读 `accelerators["available"]` | `get_available_accelerators` 返回 `{transcribe, ort, gpu_devices}` |
| A4 | 加速器设置键名 | `transcription_accelerator` | `transcribe_accelerator`（+ `transcribe_gpu_device`） |
| A5 | `ModelsView` 当前模型 | `get_current_model` 未加载时返回 `null` | 回退到 `settings.selected_model` |
| A6 | `ModelsView` 模型体积 | 读 `size_bytes` | 读 `size_mb` |
| A7 | `PersonalizationView` API Key | `SecureField` 占位符与值同时渲染；保存按钮复用标签文案 | 去掉占位符；按钮用独立文案 |

### B. 悬浮窗状态机

对标 Tauri 版 `src/overlay/RecordingOverlay.tsx` 的 8 个状态：

`recording` / `streaming` / `transcribing` / `processing` / `translating` /
`translation_failed`（重试）/ `notice`（如未配目标语言）/ `learned`（撤销）

- **core**：新增 `overlay-state` 事件（`{ state, label?, kind? }`），在 `dictation::stop` 的
  各阶段发出；翻译失败时把 `{transcription, label}` 存进槽位。
- **core**：新增 `retry_last_translation` 命令（FFI）。
- **Swift**：`OverlayPanel` 按状态渲染；`learned` / `translation_failed` / `notice` 8 秒自动隐藏；
  `learned` 用已有的 `learned-overlay` 事件（含 `notice` + `frame`）。

### C. 历史 re-transcribe

- **core**：`retry_history_entry_transcription(id)` —— 读该条录音 wav → 重新转写 →（按 workflow
  决定是否润色）→ `update_transcription(id, …)`。
- **Swift**：历史行加「重新转写」按钮。

### D. Dashboard 补全

现状只有 6 个统计卡 + 服务状态。补：

- 今日（录音数 / 字数 / 时长 / 翻译数）
- 近 7 天（柱状/列表）
- LLM token（今日 / 近 7 天：prompt / completion / requests）
- 平均速度（`avg_chars_per_min`）
- 个性化程度明细（`personalization.items`）

### E. App 图标

原 Handy 图标含商标已删。程序化生成一个简洁图标（macOS 圆角方块 + 波形），
输出 `AppIcon.icns` 并在 Xcode 工程里挂上。**风格待确认**。

### F. UI 统一

- 个性化页 / 模型页改成与其余页一致的 `Form(.grouped)` + `Section`。
- 补上未暴露的设置：粘贴延迟、可靠粘贴、typing tool、`translate_to_english`、
  `selected_language`、`word_correction_threshold`、实验性开关、更新检查开关、
  `lazy_stream_close`、录音缓冲、蛤壳模式麦克风、外部脚本路径。
- 空状态、间距、层级统一。

### G. 调试面板

- hold-threshold 滑块（已有设置项，缺 UI 交互）
- 键盘诊断（显示最近按下的键/修饰键，验证热键绑定）

## 非目标

- 不新增工作流/热键框架（阶段 5 已收缩）。
- 不做签名/公证/自动更新。
- 不改 ASR 运行时与数据格式。
- 不引入新依赖/UI 框架（图标生成用现有 Python/系统工具，不进 app 依赖）。

## 验收标准

1. 上述 A1–A7 全部可复现验证：控件有值、切换后写入 `settings_store.json`。
2. 悬浮窗 8 个状态在真机可见；翻译失败能重试成功；学习提示能撤销。
3. 历史某条能重新转写并更新该条内容。
4. Dashboard 显示今日/近 7 天/token/速度，全部本地统计。
5. App 在 Finder/Dock 显示自己的图标。
6. 设置页视觉一致；新增设置项可读写。
7. `cargo test`（core + ffi）全绿、`cargo fmt --check` 绿、`check_translations.py` 通过、
   Xcode BUILD SUCCEEDED、真机冒烟通过。

## 任务拆分

- [x] **T1** 修 A1–A7（字段名/键名对齐）— 已完成并真机验证：润色风格/翻译目标 Picker 有值、
      模型体积显示、当前模型回退 `selected_model`、加速器合并选项（Auto/GPU 设备/CPU）+ ORT 选项可读写
- [x] **T2** core：`overlay-state` 事件 + 失败槽位 + `retry_last_translation`（FFI）— 完成，
      含单测（translate 无目标 → `notice/no_target`）与 example 事件追踪
- [x] **T3** Swift：悬浮窗状态机 — 完成，真机实测 recording / processing / learned / translation_failed 四态渲染正常
- [x] **T4** core + Swift：历史 re-transcribe — 完成，真机端到端验证（读回录音 → 重转写 → 更新该条）
- [x] **T5** Swift：Dashboard 今日/近 7 天/token/速度/个性化/最近活动 — 完成
- [x] **T6** 图标生成 + 挂进 Xcode — 完成（`scripts/gen_icon.swift` 可重生成；`AppIcon.icns` 已进 bundle，各尺寸齐全）
- [x] **T7** UI 统一 + 补未暴露设置 — 完成
      - 个性化/模型页改成 `Form(.grouped)` + `Section`，与其余页一致
      - 新增：识别语言（`selected_language`，按模型能力过滤 + Auto 门控）、粘贴延迟（前/后）、
        可靠粘贴、翻译成英文、词纠正阈值、实验性开关、`lazy_stream_close`、录音缓冲、
        更新检查、键盘实现、粘贴方式补齐 3 个选项
      - 语言表从已删的前端搬进 `core/core/src/languages.rs`（104 条 + 4 个单测），
        匹配逻辑委托给 `model::canonical_language_code`（单一来源）
      - 修 `LabeledContent` + 占位符 `TextField` 同时渲染占位符与值的渲染 bug
- [x] **T8** 调试面板 — 完成
      - hold-threshold 改为下拉（仅在 hold-or-toggle 模式显示）
      - 键盘诊断 `KeyboardDiagnostic.swift`：10 秒 listen-only CGEventTap，只计数不记录键位；
        含 Secure Input 状态与判定；FFI 新增 `is_secure_input_enabled`；真机实测 3 次按键全部捕获
      - 悬浮窗 8 态预览按钮
- [x] **T9** 全量验证 + 文档更新 — 完成
      - core 280 / ffi 6 测试通过；两边 `cargo fmt --check` 绿
      - `check_translations.py` 25 个语言通过；Swift 侧 229 个 i18n 键全部存在
      - Xcode BUILD SUCCEEDED；真机运行无报错、热键注册正常
      - 无头冒烟：转录 + DeepSeek 润色成功
      - 文档：`AGENTS.md`（阶段 10 + 已知遗留）、`BUILD.md`（图标生成）、本 spec

## 待确认

1. **图标风格**：① 圆角方块 + 单色波形（最克制）② 渐变底 + 白色波形 ③ 你给素材我接入。
2. **优先级**：T1（修 bug）→ T2/T3（悬浮窗）→ T4/T5（历史/Dashboard）→ T6（图标）→ T7/T8（UI/调试）。
   是否按此顺序？
3. **未暴露设置项**：全补，还是只补常用的（粘贴延迟 / 可靠粘贴 / 实验性开关）？


## 追加：Secure Input 兜底（2026-09-17）

**问题**：任何进程打开安全输入（密码框、终端「安全键盘输入」、卡住的 `loginwindow`）后，
CGEventTap 收不到 KeyDown/KeyUp（`FlagsChanged` 仍会到达）。core 的 `handy-keys` 监听是
tap 实现，所以**按键类热键静默失效**，只有纯修饰键绑定还能用。

**实现**
- **core `secure_input.rs`**：1 秒轮询 + 3 秒「持续」阈值；持续后计算兜底计划并
  emit `secure-input-changed`。计划含每条绑定的 macOS 虚拟键码 + Carbon 修饰键掩码 +
  `degraded` 标记（左右侧修饰键会放宽成整组）；`fn` 与媒体键无法用 Carbon 表达，
  归入 `uncovered`。
- **FFI**：`get_secure_input_status` / `start_secure_input_monitor` /
  `set_cancel_shadow_active`（录音期间额外兜底取消键）。
- **Swift `SecureInputFallback.swift`**：`RegisterEventHotKey` 注册影子；
  **保留未变化的注册**（Carbon 只把 release 发给收到 press 的那个注册，替换会吞掉
  push-to-talk 的释放）；press/release 走与 tap 相同的 `DictationController.handle(bindingId:pressed:)`，
  上层无感。
- **调试面板**：实时显示安全输入状态、持有进程、以及**哪些绑定会自动兜底 / 哪些无法工作**。

**验证（真机）**：临时开启安全输入 → 日志
`SecureInput enabled (held by …)` → 3 秒后 `enabling Carbon shadows` → 关闭后
`releasing Carbon shadows`；`get_secure_input_status` 正确返回 `sustained` 与 `uncovered` 列表。

**结论（重要）**：当前用户的三个绑定（`option_right+fn+left/up/down`）**全部含 fn**，
Carbon 表达不了，因此兜底注册 0 个影子——**代码正确，是配置导致的**。
含 fn 的快捷键在安全输入期间任何 app 都无法恢复；调试面板会如实列出。

**测试**：core 新增 5 个单测（Carbon 掩码、侧键放宽 + degraded、纯修饰键免疫、
不可解析绑定、键码映射）。
