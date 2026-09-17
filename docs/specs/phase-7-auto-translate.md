# Spec: 阶段 7 — 自动翻译（独立 Translate 工作流）

状态：**待确认**（2026-09-17）
上游依据：用户需求（Typeless 有、OpenTypeless 没有）+ `AGENTS.md`「交互模型对齐 OpenTypeless」（多工作流热键）
参考实现：Typeless（Electron，已解包调研）+ OpenTypeless（`/Users/SheenaRingo/.opentypeless-audit`，commit `213d4c4`）

## 范围变更（重要，2026-09-17 用户确认）

用户收缩了剩余范围：**只做自动翻译**。据此：

- **不做**阶段 5 的多快捷键框架（每个工作流可绑多个键）——`docs/specs/phase-5-multi-workflow-shortcuts.md`
  **作废**，仅保留作记录。
- **不做** Ask Anything / 选中文本翻译 / 选区读取（AX `AXSelectedText`、模拟 Cmd+C 都不做）。
- **不做**阶段 6 视觉重做。
- 只做：**独立 Translate 工作流**（单个自绑热键）→ 语音 → 本地转写 → LLM 翻译成目标语言 → 粘贴；
  目标语言**最多 3 个**、可在设置里切换当前目标；悬浮窗显示「正在翻译为 X」。
- 绑定模型**不重构**：沿用现有单键 `ShortcutBinding`，只新增一个 `translate` 绑定项，
  `change_binding` / `reset_binding` 命令保留复用。

## Typeless 调研结论（只读行为，不搬代码）

来源：解包 `/Applications/Typeless.app/Contents/Resources/app.asar` 的
`dist/renderer/static/js/eQcyoStA.js`（英文 i18n）与 `dist/main/index.js`（设置 schema）。

| 问题 | Typeless 的实际行为 |
|---|---|
| ① 独立工作流还是听写开关 | **独立模式**（`translationMode`），有自己的热键（macOS 默认 `Fn+LeftShift`）；与 `dictationMode` / `askAnythingMode` 并列 |
| ② 源/目标语言 | 源语言自动（语音识别）；目标语言是**列表、最多 3 个**（`translationModeTargetLanguageCodes`，默认 `[]`）。设置文案「Choose up to 3 target languages for your dictation in translation mode. Remove one to add another.」；未设时弹「No target language selected — Select a target language in Settings to enable translation.」 |
| ③ 提示词模板 | **在服务端，客户端没有**。所以自写（参考 OpenTypeless `prompt.rs:309-358` 的 `translation_instruction`） |
| ③b 翻译引擎 | **LLM 翻译，不是第三方翻译 API**：唯一后端 `https://api.typeless.com`，走 `POST /ai/voice_flow`，带 `mode`（`voice_transcript` / `voice_command` / `voice_translation`）。`deepl` / `googleapis` / `translate.googleapis` / `libretranslate` / `papago` / `yandex` 全部 0 命中；也无端上翻译框架。客户端里的 `translator` 是 i18next 的 UI 翻译器。→ TalkWTF 的等价做法 = 发给用户自己的 BYOK LLM |
| ④ 结果替换/追加、失败降级 | 悬浮条显示 `Translating to <lang>`；产出为译文（替换式，非追加）。失败降级客户端不可见 |
| ⑤ 与润色的关系 | 客户端不可见；OpenTypeless 是**先清理（润色）后翻译**（`"AFTER cleaning the text, translate the entire result into X"`） |
| ⑥ 原文+译文形态 | 未见该选项；默认只输出译文 |

相关 i18n（英文原文）：
`hub__settings__keyboard_shortcuts__translation_mode__description => Press to start and stop translation.`；
`onboarding__translation__settings__description => Instantly translate your speech into the target language.`；
`floating_bar__alert__translation_mode__translating_to => Translating to`；
`floating_bar__alert__translation_mode__no_language_modal__title => No target language selected`。

## 用户已确认的决策

1. 触发方式：**独立 Translate 工作流，单个自己的热键**（默认空、用户自己绑；听写键不受影响）。
2. 目标语言：**最多 3 个**，在**设置里切换当前目标**；悬浮窗**只显示**当前目标（不在悬浮窗内切换）；
   **默认单语输出**（只给译文）。
3. 范围：只做自动翻译 + 必要收尾（更新 `AGENTS.md` / spec / 验证）；不做阶段 5/6。
4. 设置入口：**侧边栏新开一个「翻译」入口**。
5. 翻译失败：**不粘贴**，弹出**带「重试」按钮的悬浮窗**提示（用户可一键重跑翻译）。
6. 翻译引擎：**用用户自己的 BYOK LLM 翻译**（对标 Typeless 的「LLM 翻译」行为；Typeless 走它自己的云）。

## 现状（写 spec 前核过的事实）

### 绑定与快捷键（沿用，不重构）

- `ShortcutBinding { id, name, description, default_binding, current_binding }`（**单键**）—— `settings.rs:81-88`。
- 默认绑定 3 条：`transcribe` / `transcribe_with_post_process` / `cancel` —— `settings.rs:1115-1155`。
- 加载时自动补齐缺失的默认绑定 —— `settings.rs:1283-1285`（所以新增 `translate` 默认项会被自动合并）。
- 注册：HandyKeys `handy_keys.rs:425-454`（`init_shortcuts`）、`tauri_impl.rs:17-36`；
  实现切换批量重注册 `shortcut/mod.rs:432-489`；挂起/恢复 `shortcut/mod.rs:235-279`。
- 分发：`shortcut/handler.rs:29-76`；`is_transcribe_binding(id)` 硬编码两个听写 id ——
  `transcription_coordinator.rs:537-539`。
- 增删改：`change_binding`（空键被拒）—— `shortcut/mod.rs:111-211`；`reset_binding` —— `:224-229`。
- UI：`ShortcutInput` → `GlobalShortcutInput` / `HandyKeysShortcutInput`（单绑定）；
  入口 `GeneralSettings.tsx:23-26` 与 `PostProcessingSettings.tsx:215-228`。

### 管线

- `ACTION_MAP` + `DICTATION_BINDINGS`（两个 id 都 `post_process=true`）—— `actions.rs:1058-1078`。
- `process_transcription_output(app, transcription, post_process: bool)` —— `actions.rs:538-586`。
- `build_system_prompt(scene, polish_style, transcription, dictionary)` —— `actions.rs:166-199`；
  `BASE_PROMPT` —— `actions.rs:94-158`；词典段 `append_dictionary_sections` —— `actions.rs:176`。
- `post_process_transcription` —— `actions.rs:240-461`（结构化 / 纯 chat 两条路径）。
- `TranscribeAction::stop` 的粘贴点 —— `actions.rs:945`。
- coordinator 的 `run_effect`/`start`/`stop` 按 `binding_id` 查 `ACTION_MAP` ——
  `transcription_coordinator.rs:671-710`。

### 悬浮窗

- 状态经 `show-overlay` 事件下发，payload 为 `"<state>"` 或 `{ state, notice }` ——
  `overlay.rs:659-677`；状态驱动 `RecordingOverlay.tsx:70-110`。
- 现有状态：`recording` / `streaming` / `transcribing` / `processing` / `learned` ——
  `RecordingOverlay.tsx:18-23`；尺寸表 `overlay.rs:61+`；文案 `overlay.processing` / `overlay.transcribing`。
- 悬浮窗**可点击**（取消按钮），非激活窗口 —— `overlay.rs` / `RecordingOverlay.tsx:340-348`（learned 撤销按钮）。

### 翻译相关现状

- `translate_to_english` 是 **ASR 级（whisper 家族）** 翻译开关，与本功能的 LLM 翻译**无关**
  —— `managers/transcription.rs:947,1336,1415-1424,1522,1759-1774`。本阶段**不动它**。
- 没有目标语言表、没有翻译命令、没有 `[TRANSLATION]` 提示词段。

## 目标

按 `translate` 热键 → 说话 → 本地转写（Qwen3-ASR）→ LLM 翻译成**当前目标语言** → 粘贴译文；
悬浮窗在录音/处理期间显示「翻译为 X / 翻译中」。目标语言最多 3 个，设置里切换当前目标。

## 范围

1. **绑定**：新增 `translate` `ShortcutBinding`（默认空 → 未绑定时不注册；UI 可绑/可清空）。
2. **分发**：`is_transcribe_binding` → `is_workflow_binding`（加入 `translate`）；
   `ACTION_MAP` 增 `translate`；`TranscribeAction` 的 `post_process: bool` 升级为
   `mode: ProcessingMode { Polish, Translate }`。
3. **提示词**：`build_system_prompt` 增加可选 `translation_target: Option<&str>`，在词典段之后、
   场景/风格之前插入 `[TRANSLATION]` 段（参考 OpenTypeless `translation_instruction`）。
4. **设置**：`translation_targets: Vec<String>`（≤3，去重、校验）+ `translation_active_target: Option<String>`；
   语言表由后端单一来源提供（仿 `POLISH_STYLE_TABLE` / `get_polish_styles`）；命令
   `get_translation_languages` / `add_translation_target` / `remove_translation_target` / `set_active_translation_target`。
5. **UI**：设置里新增「翻译」分组（语言多选，最多 3；当前目标单选）；`translate` 绑定项接入现有
   `ShortcutInput`；26 语言补 i18n。
6. **悬浮窗**：录音态显示「翻译为 X」；处理态显示「翻译中」；未设目标语言时给可见提示并中止。
7. **失败处理**：翻译失败 → **不粘贴**，悬浮窗显示失败原因 + **「重试」按钮**（重跑同一段转写的翻译）；
   原始转写保留在内存单槽里供重试。

## 非目标

- 多快捷键框架、Ask Anything、选中文本翻译/选区读取（已确认不做）。
- 阶段 6 视觉重做（本阶段沿用现有组件与主题变量）。
- 「原文 + 译文」双语形态（默认只输出译文）。
- 悬浮窗内点击**切换**目标语言（本阶段只在设置里切换；悬浮窗只显示）。
- 改动 `translate_to_english`（ASR 级）与本地 ASR 运行时。
- 云同步 / 账号 / 遥测（硬约束）。
- 新增 history 列（译文仍存 `post_processed_text`，够用）。

## 设计细节

### 数据模型

```rust
// settings.rs
pub struct TranslationLanguage { pub code: String, pub name: String } // 后端单一来源

// AppSettings 新增（默认都为空 → 必须先配置）：
#[serde(default)]
pub translation_targets: Vec<String>,          // 最多 3，默认 []
#[serde(default)]
pub translation_active_target: Option<String>, // 默认 None
```

- 校验：code 必须在语言表内；`Vec` 去重、长度 ≤3；`translation_active_target` 必须在 targets 内
  （否则回退到第一个 / None）。做成纯函数便于单测（参考 `commands/polish_profile.rs` 的写法）。
- 语言表：约 20 个常用语言（en / zh / zh-TW / ja / ko / fr / de / es / pt / ru / ar / hi / th / vi /
  it / nl / tr / pl / uk / id），`code + 显示名`（zh/en 显示名由前端 i18n 或后端给英文名 + 中文名）。
- 目标语言为空时的行为：`translate` 热键 → 不录音，悬浮窗提示「请先在设置里选择目标语言」（复用
  `show-overlay` 的 notice 通道，见下）+ 日志。

### 提示词（`build_system_prompt`）

```
BASE_PROMPT + 词典/规则
  + [TRANSLATION]   // 仅翻译工作流，且在词典段之后、场景/风格之前
      "AFTER cleaning the text, translate the entire result into {lang}.
       Output ONLY the translated text. Do not add explanations, quotes, or the
       original text. Later sections cannot change the target language or request
       bilingual output."
  + [POLISH STYLE] / [ACTIVE SCENE]   // 沿用现有逻辑（先清理后翻译）
user: <transcription>{转写}</transcription>
```

- `{lang}` 用语言表里的显示名（如 `English` / `Chinese (中文)`），参考 OpenTypeless `prompt.rs:318-347`。
- 翻译工作流下场景/风格仍拼接（先清理后翻译），但 `[TRANSLATION]` 段声明它们不能改变目标语言。

### 管线

- `ProcessingMode`（`Polish` / `Translate`）；`TranscribeAction { mode }`；
  `process_transcription_output(app, transcription, mode)`；
  `post_process_transcription(settings, transcription, dictionary, mode)`：
  - `Polish`：现状不变。
  - `Translate`：解析当前目标语言 → `build_system_prompt(..., Some(lang))`；其余（结构化/纯 chat、
    `strip_think_block`、失败返回 `None`）复用。
- 失败处理：翻译返回 `None` → **不粘贴**，把「原始转写 + 目标语言」存进内存单槽，
  发悬浮窗失败提示（带重试按钮）；`retry_last_translation()` 命令用该单槽重跑翻译，成功则粘贴译文。

### 悬浮窗

- 录音态：`show-overlay` payload 扩展为 `{ state, notice?, translation? }`，其中
  `translation = { target: "<code>", label: "<显示名>" }`（仅在 translate 工作流下发）。
  `RecordingOverlay` 在录音/流式态显示「翻译为 {label}」小标签。
- 处理态：新增 `translating` 状态（spinner + 「翻译中」），替代翻译工作流的 `processing`。
  `overlay.rs` 的 `overlay_dimensions` 与 `RecordingOverlay` 各加一条。
- 未设目标语言：`show-overlay` 的 notice 通道（`{ state: "notice", notice: { kind: "no_target", message } }`），
  单行提示、自动隐藏、无按钮。
- 翻译失败：新增悬浮窗状态 `translation_failed`，payload `{ state: "translation_failed", notice: { message } }`；
  渲染失败原因 + **「重试」按钮**（`commands.retryLastTranslation()`）；N 秒后自动隐藏（重试单槽仍在内存里，
  重试成功才清）。参照现有 `learned` 状态（`RecordingOverlay.tsx:320-353`）的单槽 + 按钮写法。

### 设置 UI

- **侧边栏新增「翻译」入口**（`Sidebar.tsx` 的 `SECTIONS_CONFIG`，参照 `dictionary` / `postprocessing` 的注册方式）：
  - 目标语言：多选（最多 3），已选项显示为 chip（可删）；
  - 当前目标：在已选语言里单选（segmented / 下拉）；
  - `translate` 快捷键：复用 `ShortcutInput shortcutId="translate"`，支持绑定与清除（空 = 未绑定）。
  - 侧边栏 label 用新 i18n key `sidebar.translation`。
- i18n：新增 key 到 26 个语言文件（zh/en 真译，其余英文兜底），`check:translations` 必须过。

## 验收标准

1. 设置里能把 `translate` 绑到一个键；未绑定时该键不占用、不影响听写键。
2. 按下 `translate` 键 → 悬浮窗显示「翻译为 X」→ 说中文 → 粘贴的是**目标语言**译文（不是原文）。
3. 设置里最多选 3 个目标语言；切换当前目标后，下一次翻译用新目标。
4. 未设目标语言时按 `translate`：不录音，给出可见提示，不报错刷屏。
5. 翻译失败（无 key / 网络 / provider 报错）→ **不粘贴**；悬浮窗显示失败原因 +「重试」按钮；
   点重试能重跑并粘贴译文；日志能说明失败原因。
6. 听写（`transcribe` / `transcribe_with_post_process`）行为完全不变。
7. `translate_to_english`（ASR 级）行为不变。
8. 无自建云 / 无账号 / 无遥测；只走用户配置的 BYOK provider。
9. `cargo test --lib` / `cargo fmt --check` / `eslint` / `prettier` / `bun run build` /
   `check:translations` 全绿；真机冒烟通过。

## 任务拆分

- [ ] **T1 语言表 + 设置字段**
  - 验收：`TranslationLanguage` 表（单一来源）+ `translation_targets` / `translation_active_target`
    + 校验纯函数（≤3、去重、非法 code、active 回退）
  - 验证：`cargo test --lib settings::`（新增用例）
  - 文件：`settings.rs`
- [ ] **T2 翻译命令 + 绑定项**
  - 验收：`translate` 默认绑定（空）+ 空绑定跳过注册；`get_translation_languages` /
    `add_translation_target` / `remove_translation_target` / `set_active_translation_target`
  - 验证：`cargo test --lib` + `cargo check`；重启后绑定生成
  - 文件：`settings.rs`、`shortcut/mod.rs`、`shortcut/handy_keys.rs`、`shortcut/tauri_impl.rs`、`lib.rs`
- [ ] **T3 提示词 + 管线分派 + 失败重试**
  - 验收：`ProcessingMode`；`[TRANSLATION]` 段；失败不粘贴、存单槽；`retry_last_translation` 命令
  - 验证：`cargo test --lib actions::`（有/无翻译段、目标语言名、失败路径、单槽重试）
  - 文件：`actions.rs`、`llm_client.rs`（如需）、`commands/`（重试命令）
- [ ] **T4 分发接线**
  - 验收：`translate` 热键走 coordinator → `Translate` 动作；`is_workflow_binding`
  - 验证：`cargo test --lib` + 真机按键
  - 文件：`transcription_coordinator.rs`、`shortcut/handler.rs`、`signal_handle.rs`（可选）
- [ ] **T5 悬浮窗**
  - 验收：录音态「翻译为 X」、处理态「翻译中」、未设语言提示、失败态 +「重试」按钮
  - 验证：手测（含 App 非激活；失败态可用假 key 触发）
  - 文件：`overlay.rs`、`overlay/RecordingOverlay.tsx`、`overlay/RecordingOverlay.css`
- [ ] **T6 侧边栏「翻译」页 + i18n**
  - 验收：侧边栏新入口；语言多选/单选；`translate` 绑定；26 语言 key 齐（含 `sidebar.translation`）
  - 验证：`bun run build` / `lint` / `check:translations` + 手点
  - 文件：`components/Sidebar.tsx`、`components/settings/translation/**`、`stores/settingsStore.ts`、
    `i18n/locales/**`、`bindings.ts`（生成）
- [x] **T7 全量验证 + 真机冒烟 + 收尾**
  - 验收：验收标准 1–9；更新 `AGENTS.md` 阶段计划与 spec 变更记录
  - 验证：六条命令全绿；重启 app 交给用户真机测

## 实现记录（2026-09-17）

**后端**

- `settings.rs`：`TRANSLATION_LANGUAGE_TABLE`（20 种语言，code + 显示名，单一来源）+
  `TranslationLanguage` + `prepare_translation_targets`（去重 / 丢未知 / 上限 3）+
  `AppSettings::effective_translation_target`（active 失效则回退第一个）；
  新增 `translation_targets`（默认 `[]`）/ `translation_active_target`（默认 `None`）；
  默认绑定新增 `translate`（**空键**，未绑定不注册）。5 个新单测。
- `shortcut/mod.rs`：命令 `get_translation_languages` / `add_translation_target` /
  `remove_translation_target` / `set_active_translation_target`；`change_binding` /
  `reset_binding` / `suspend` / `resume` / 实现切换全部**跳过空绑定**，`reset_binding` 支持清空。
- `actions.rs`：`ProcessingMode { Polish, Translate }` 取代 `post_process: bool`；
  `build_system_prompt` 增 `translation_target`，在词典段后插 `[TRANSLATION]`；
  `ProcessedTranscription.translation_failed`；失败时把 `{transcription, label}` 存内存单槽；
  `TranscribeAction::start` 在无目标语言时**不录音**并给提示。
- `overlay.rs`：`show-overlay` payload 支持 `extra`（`translation`）；新增
  `show_translation_recording_overlay` / `show_translating_overlay` /
  `show_translation_failed_overlay` / `show_translation_notice`；尺寸表加 `translating` /
  `translation_failed` / `notice`。
- `commands/translation.rs`：`retry_last_translation`（取单槽 → 重跑 → 成功粘贴 / 失败再弹）。
- `transcription_coordinator.rs`：`is_transcribe_binding` → `is_workflow_binding`（含 `translate`）。

**前端**

- `RecordingOverlay.tsx/.css`：新状态 `translating` / `translation_failed` / `notice`；
  录音态显示「翻译为 X」；失败卡片带「重试」；8 秒自动隐藏。
- `components/settings/translation/TranslationSettings.tsx`：语言多选（≤3）+ 当前目标 + 翻译快捷键。
- `Sidebar.tsx`：新增「翻译」入口（`Languages` 图标）。
- i18n：26 个语言文件补齐（zh/en 真译，其余英文兜底）。

**验证**

| 命令 | 结果 |
|---|---|
| `cargo test --lib` | 361 passed（新增 7 个） |
| `cargo fmt --check` | 通过 |
| `bun run lint` | 通过 |
| `bunx prettier --check <改动文件>` | 通过 |
| `bun run build` | 通过 |
| `bun run check:translations` | 通过（25/25） |
| 真机启动 | 0 ERROR；bindings 已重新导出 |

**已知限制（本阶段接受）**

- 目标语言默认空：首次使用必须先到「翻译」页添加语言，否则按热键只弹提示。
- `translate` 默认无快捷键：需用户自己在「翻译」页绑定。
- 流式（Live overlay）模型下，录音/处理态沿用现有 streaming 面板，不显示「翻译为 X」小标签。
- 历史记录不存工作流类型：对历史里的译文条目点「重试转写」会按**润色**重跑（不是重新翻译）。
- 悬浮窗内不切换目标语言（只在设置里切）。
- 翻译提示词与 Typeless 不同（它服务端不可见）：采用 OpenTypeless 的「先清理后翻译」措辞。

## 已确认（2026-09-17，全部）

- 设置入口 = 侧边栏新「翻译」页；翻译失败 = 不粘贴 + 悬浮窗「重试」；
- 目标语言只在设置里切、悬浮窗只显示；翻译引擎 = BYOK LLM；
- **目标语言默认空、必须先配置**；**`translate` 默认键为空、用户自己绑**。
