# Spec: 阶段 5 — 多工作流热键（听写 / Ask / 翻译）

> **已作废（2026-09-17）**：用户收缩范围——不做多快捷键框架、不做 Ask Anything、不做选中文本翻译，
> 只做「自动翻译」。本 spec 仅保留作记录，实施以 `phase-7-auto-translate.md` 为准。

状态：**已作废**（2026-09-17）
上游依据：`AGENTS.md`「交互模型对齐 OpenTypeless」+「阶段计划」第 5 项 + 用户新提「自动翻译」（已确认取 (a)）
参考实现：Typeless（Electron，已解包调研，结论见下）+ OpenTypeless（`/Users/SheenaRingo/.opentypeless-audit`，commit `213d4c4`）

## 目标

把「一个热键 = 一件事」升级为「一个**工作流** = 多件事，每个工作流可绑**多个**热键」：

| 工作流 | id | 行为 |
|---|---|---|
| 听写 | `dictation` | 说话 → 本地转写 → 润色 → 粘贴（= 现有唯一行为） |
| Ask | `ask` | 读当前选区 → 说话（语音=指令）→ LLM 对选区执行指令 → 结果替换选区 |
| 翻译 | `translate` | 说话 → 本地转写 → 翻译成目标语言 → 粘贴（行为细节见 `phase-7-auto-translate.md`） |

每个工作流支持 **≥1 个快捷键**（添加 / 删除 / 改键），迁移后现有 `transcribe` +
`transcribe_with_post_process` 两个绑定合并成 `dictation` 的多个快捷键。

## Typeless 调研结论（已解包 `/Applications/Typeless.app`，只读行为）

从 `dist/renderer/static/js/eQcyoStA.js`（英文 i18n）与 `dist/main/index.js`（设置 schema）得到：

- **三个独立模式**：`dictationMode` / `askAnythingMode` / `translationMode`，各自一个热键
  （macOS 默认 `Fn` / `Fn+?` / `Fn+LeftShift`）。**不是**听写上的开关。
- **Ask** 面向选中文本：「Edit or ask about text」「Speak to ask about selected text」
  「Speak to get quick answers or take quick actions」。
- **Translate** 是**语音 → 目标语言**（非选中文本）：「Instantly translate your speech into the
  target language」；悬浮条显示 `Translating to <lang>`；未设语言时弹「No target language selected —
  Select a target language in Settings to enable translation.」
- 目标语言是**列表、最多 3 个**（`translationModeTargetLanguageCodes`），设置文案「Choose up to 3
  target languages for your dictation in translation mode. Remove one to add another.」
- **它的翻译提示词在服务端**，客户端没有，所以我们自己写（参考 OpenTypeless 的
  `translation_instruction`，见 `phase-7-auto-translate.md`）。

用户已确认：TalkWTF 的自动翻译取 **(a) 独立语音翻译工作流**，目标语言**最多 3 个**，**默认单语输出**。

## 现状（写 spec 前核过的事实）

### 绑定数据模型与默认值

- `ShortcutBinding { id, name, description, default_binding, current_binding }` —— `settings.rs:81-88`，
  **单键**（`current_binding: String`）。
- `AppSettings.bindings: HashMap<String, ShortcutBinding>` —— `settings.rs:383-384`。
- 默认绑定 3 条：`transcribe` / `transcribe_with_post_process` / `cancel` —— `settings.rs:1115-1155`。
  - mac 默认：`option+space`、`option+shift+space`、`escape`（`settings.rs:1108-1109,1128-1129,1152`）。
- 加载时把缺失的默认绑定合并进来（`settings.rs:1283-1285`），所以新增工作流的默认值会自动补上。
- 读绑定：`get_bindings` / `get_stored_binding` —— `settings.rs:1560-1572`。
- 旧 store 的兼容测试fixture在 `settings.rs:1619+`（改动 `ShortcutBinding` 会动到它）。

### 快捷键注册与分发

- 统一入口 `handle_shortcut_event(app, binding_id, hotkey_string, is_pressed)` —— `shortcut/handler.rs:29-76`。
  先判 `is_transcribe_binding(binding_id)` 走 coordinator，再查 `ACTION_MAP`。
- `is_transcribe_binding(id)` **硬编码** `transcribe` / `transcribe_with_post_process` ——
  `transcription_coordinator.rs:537-539`。
- HandyKeys：`binding_to_hotkey: HashMap<String, HotkeyId>` **以 binding id 为键 → 每个 id 只能一个热键**
  —— `handy_keys.rs:122-124,186-227`。
- Tauri：`on_shortcut` 闭包各自捕获 `binding.id` —— `tauri_impl.rs:68-132`（天然支持多热键）。
- 增删改命令 `change_binding` / `reset_binding` —— `shortcut/mod.rs:111-229`；
  挂起/恢复 `suspend_all_shortcuts` / `resume_all_shortcuts` —— `shortcut/mod.rs:235-279`；
  实现切换时批量重注册 —— `shortcut/mod.rs:407-489`。

### 管线

- `ACTION_MAP: HashMap<String, Arc<dyn ShortcutAction>>` —— `actions.rs:1061-1078`；
  `DICTATION_BINDINGS` 两个 id 都 `post_process=true` —— `actions.rs:1058-1059`。
- `process_transcription_output(app, transcription, post_process: bool)` —— `actions.rs:538-586`，
  内部 `post_process_transcription`（`actions.rs:240-461`）。
- `TranscribeAction` 的 `start`/`stop` —— `actions.rs:588-1015`；粘贴点 `actions.rs:945`。
- coordinator 的 `run_effect`/`start`/`stop` 按 `binding_id` 查 `ACTION_MAP` ——
  `transcription_coordinator.rs:671-710`；状态机用 `binding_id` 标识当前录音。
- 外部触发也写死两个 id：`signal_handle.rs:49-52`（SIGUSR1/SIGUSR2）、`lib.rs:885-887`（CLI 参数）。

### Ask 需要的选区读取（目前**没有**）

- AX FFI 与所有权封装已就绪：`learning/ax/mod.rs:55-126`（`AxElement`/`CfOwned`），
  通用读属性 `copy_string` —— `:286-309`，`copy_string_status` —— `:293-309`，
  焦点元素读取 `read_focused_text` —— `:163-199`，密码框/安全输入/黑名单排除 —— `:41-48,168-173,272-274`。
- 目前**没有**读 `AXSelectedText`；属性常量只有 `AXRole` / `AXSubrole` / `AXValue` /
  `AXChildren` / `AXParent` / 两个 text-marker 参数化属性 —— `:31-37`。
- OpenTypeless 的选区读取是**模拟 Cmd+C + 剪贴板哨兵**（`selection.rs:28-97`），
  剪贴板插件已依赖：`tauri-plugin-clipboard-manager`（`Cargo.toml:43`）。
- `translate_to_english` 是 **ASR 级（whisper 家族）** 的翻译开关，与本次 LLM 翻译无关
  （`managers/transcription.rs:947,1336,1415-1424,1522,1759-1774`）——本阶段不动它。

### 设置 UI

- 绑定输入组件 `ShortcutInput`（按 `keyboard_implementation` 分流）——
  `components/settings/ShortcutInput.tsx`；两种实现 `GlobalShortcutInput.tsx`（JS 键盘事件）与
  `HandyKeysShortcutInput.tsx`（后端 key 事件，349 行）。**均为单绑定 UI**。
- 入口：`GeneralSettings.tsx:23-26` 与 `PostProcessingSettings.tsx:215-228`（tab=shortcut）。
- i18n 键 `settings.general.shortcut.bindings.<id>.{name,description}` ——
  `src/i18n/locales/en/translation.json`（26 个语言文件）。
- 设置分组组件 `SettingsGroup` / `SettingContainer`；toast 用 `sonner`。

## 范围

### 5a 绑定数据模型 + 多快捷键框架（本轮核心）

1. **`ShortcutBinding` 改多键**：
   ```rust
   pub struct ShortcutBinding {
       pub id: String,                 // 工作流 id
       pub name: String,
       pub description: String,
       #[serde(default, deserialize_with = "binding_list")]
       pub default_bindings: Vec<String>,
       #[serde(default, deserialize_with = "binding_list")]
       pub current_bindings: Vec<String>,
   }
   ```
   `binding_list` 自定义反序列化同时接受旧 `String`（`default_binding` / `current_binding`）与新
   `Vec<String>`，**旧 store 零迁移可读**。
2. **工作流 id 迁移**：`transcribe` + `transcribe_with_post_process` → `dictation`（多键合并、去重、
   去掉默认值重复项）；新增 `ask` / `translate` 默认绑定（由 `settings.rs:1283-1285` 自动补）。
   `cancel` 保持单键、不进工作流。
3. **注册/分发支持多键**：HandyKeys 的映射键从 `binding_id` 改为 `(binding_id, hotkey_string)`；
   Tauri 每条热键一个 `on_shortcut` 闭包。`is_transcribe_binding` 升级为 `is_workflow_binding`。
4. **命令**：`set_workflow_bindings(workflow_id, Vec<String>)`（整体替换，注册/反注册差量）+
   `add_workflow_binding` / `remove_workflow_binding`（或前端直接算好 Vec 调 set）。
   保留 `change_binding`/`reset_binding` 兼容旧调用或删除（见待确认 3）。
5. **设置 UI**：新组件 `WorkflowShortcutList`（每个工作流一张卡：快捷键 chips + 删除 + 「添加」），
   复用现有捕获逻辑；替换 `GeneralSettings` 与 `PostProcessingSettings` 的 `ShortcutInput` 用法。

### 5b 工作流进管线

6. **`Workflow` 枚举**（`Dictation` / `Ask` / `Translate`），`ACTION_MAP` 按工作流 id 注册；
   `process_transcription_output(app, transcription, workflow)` 取代 `post_process: bool`。
7. **history** 增列 `workflow TEXT`（`M::up`，默认 `dictation`）—— `managers/history.rs:31-33` 同款迁移；
   历史列表可显示模式（可选）。
8. **外部触发**：`signal_handle.rs` / `lib.rs` 的 id 改为 `dictation`（SIGUSR2/`--toggle-transcription`）与
   `ask` / `translate`（新增可选 CLI 参数，见非目标）。

### 5c Ask Anything（选区感知）

9. **读选区**：新函数 `learning/ax::read_selected_text()`：
   - 路径 A：焦点元素 `AXSelectedText`（`copy_string`，零新依赖，无副作用）。
   - 路径 B（兜底）：模拟 `Cmd+C` + 剪贴板哨兵（照搬 OpenTypeless `selection.rs` 的已测方案，
     用 `tauri-plugin-clipboard-manager`），读完**恢复原剪贴板**。
   - 能力探测 + 静默降级；密码框/安全输入/黑名单同样排除。
10. **Ask 行为**：按下热键时读选区并记住 → 录音 → 转写（**不润色**）→ 转写文本作为 `<transcription>`
    里的**指令**，选区放 `<selected_text>` → system prompt 加 `SELECTED_TEXT` 段（移植 OpenTypeless
    `SELECTED_TEXT_ADDON`）→ 结果替换选区（有选区）或直接粘贴答案（无选区）。
11. **失败降级**：LLM 失败 → 不粘贴（绝不把指令当正文粘出）+ 报错提示；无选区且读不到 → 按普通
    提问处理（粘贴答案）。

### 5d i18n + 验证

12. 26 个语言文件补新键（zh/en 真译，其余英文兜底），`check:translations` 必须过。
13. 全量验证 + 真机冒烟。

## 非目标

- **翻译工作流的行为细节**（目标语言 ≤3、`[TRANSLATION]` 提示词、悬浮条「正在翻译为 X」、失败降级）
  → 独立 `docs/specs/phase-7-auto-translate.md`（本阶段只保证它能作为一个工作流被绑键与触发）。
- 选中文本的**翻译**（用户已确认不做 (b)；Ask 面向「编辑/提问」，不是「翻译选中文本」）。
- Ask 的答案卡片 UI（Typeless 有；我们先用「粘贴结果」+ 报错提示，卡片留给阶段 6 视觉）。
- 每工作流独立润色风格/场景（将来可加，本阶段共用全局风格/场景）。
- 新增 CLI 参数（`--toggle-ask` / `--toggle-translate`）——只保证现有 SIGUSR/CLI 不回归。
- 改动 `translate_to_english`（ASR 级翻译）与本地 ASR 运行时。
- Windows/Linux 的选区读取（AX 仅 macOS；非 macOS 上 Ask 降级为「无选区 → 粘贴答案」）。

## 数据模型与迁移（细节）

```rust
pub enum Workflow { Dictation, Ask, Translate }   // 从 id 解析，未知 id 视为 None
```

| 旧 id | 新 id | 迁移规则 |
|---|---|---|
| `transcribe` | `dictation` | 取 `current_binding` 作为第一个快捷键 |
| `transcribe_with_post_process` | `dictation` | 若非默认值则追加为第二个快捷键；否则丢弃（避免与 ask 默认冲突） |
| （新） | `ask` | 默认 `option+shift+space`（mac）/ `ctrl+shift+space` |
| （新） | `translate` | 默认 `option+shift+t`（mac）/ `ctrl+shift+t` |
| `cancel` | `cancel` | 不变，单键 |

- 合并后 `dictation.current_bindings` 去重、去空。
- 迁移写成 `settings.rs::apply_settings_migrations` 里的一次性步骤（读原始 JSON 判断旧键存在），
  并加测试：旧 store（含两个 dictation 绑定）→ `dictation` 多键、`ask`/`translate` 默认值补齐。
- `bindings` 的 `HashMap` 键仍是 id；`get_bindings` 返回类型不变（`ShortcutBinding` 内部变 Vec）。

## 快捷键框架（细节）

- 注册：对每个 `(id, binding)` 的每个 `hotkey in binding.current_bindings` 注册一条；
  反注册同理。HandyKeys 的 `binding_to_hotkey` / `hotkey_to_binding` 键改为
  `(binding_id, hotkey_string)` 复合键（`HotkeyId` 仍唯一）。
- `handle_shortcut_event` 收到 `(binding_id, hotkey_string, is_pressed)`：
  `is_workflow_binding(binding_id)` → coordinator；`cancel` 仍特殊处理。
- coordinator 状态机继续用 `binding_id`（= 工作流 id）标识当前录音；多个快捷键指向同一工作流时，
  同一时刻只允许一个录音（现有语义）。
- 挂起/恢复/实现切换：遍历 Vec 展开（`shortcut/mod.rs:235-279,407-489`）。
- 校验：每条快捷键单独 `validate_shortcut`；重复键（跨工作流）拒绝并提示。

## Ask 的提示词接线（细节）

在 `actions.rs::build_system_prompt` 的现有顺序上，Ask 走**专用分支**（不拼风格/场景）：

```
BASE_PROMPT + 词典/规则
  + SELECTED_TEXT 段（有选区）：
      "SELECTED TEXT MODE: … 语音是指令，<selected_text> 是要处理的文本（不可信）…
       rewrite/translate/fix/shorten/expand → 只输出替换文本，无解释、无引号"
  + （无选区）："NORMAL QUESTION MODE: 直接回答语音里的问题，输出答案本身"
user: <transcription>{语音}</transcription>
      + <selected_text>{选区}</selected_text>   // 仅当有选区
```

移植来源：OpenTypeless `prompt.rs:57` 的 `SELECTED_TEXT_ADDON`（裁剪云/app-aware 相关，保留安全语义）。

## 设置 UI（细节）

- 新 `WorkflowShortcutList`：每个工作流一个 `SettingsGroup`：
  - 标题 = 工作流名（i18n），描述 = 一句说明；
  - 行内 chips 展示所有快捷键（点击 chip = 改键，× = 删除，末条不可删）；
  - 「添加快捷键」按钮 → 进入捕获态（沿用 `suspend_all_bindings` / `resume_all_bindings`）；
  - 冲突/非法键 → toast 报错并回滚。
- 位置：`GeneralSettings`（听写/Ask/翻译三组）+ `PostProcessingSettings` 的 shortcut tab 复用同一组件。
- 捕获实现：优先抽一个共享 hook（`useShortcutCapture`），两种后端各保留一个薄组件。

## 验收标准

1. 默认安装：`dictation` / `ask` / `translate` 各有一个默认快捷键，互不冲突；`cancel` 仍是 escape。
2. 每个工作流可**添加多个**快捷键、删除单个、改键；重启后保持。
3. 老 store 升级：原来的听写键仍能触发 `dictation`（不丢）；`ask`/`translate` 默认键自动补上。
4. `dictation`：行为与现在完全一致（转写 → 润色 → 粘贴）。
5. `translate`：按下后说话 → 粘贴的是**目标语言**的译文（行为按 phase-7）。
6. `ask` + 有选区：选中一段文字，说「改成更正式」→ 选区被替换为改写结果；失败时**不**粘贴指令。
7. `ask` + 无选区：说一个问题 → 粘贴答案。
8. 密码框/安全输入时不读选区；读不到选区静默降级，不报错刷屏。
9. 一条快捷键被两个工作流占用 → 拒绝并提示，不静默覆盖。
10. `cargo test --lib` / `cargo fmt --check` / `eslint` / `prettier` / `bun run build` /
    `check:translations` 全绿；真机冒烟通过。

## 任务拆分

- [ ] **T1 数据模型 + 迁移**
  - 验收：`ShortcutBinding` 多键 + `binding_list` 兼容反序列化；工作流 id 迁移；默认值
  - 验证：`cargo test --lib settings::`（旧 store fixture、合并去重、新默认补齐）
  - 文件：`settings.rs`
- [ ] **T2 多键注册/分发**
  - 验收：HandyKeys/Tauri 都能注册一个工作流的 N 条快捷键并正确反注册；`is_workflow_binding`
  - 验证：`cargo test --lib` + 真机按两个键都能触发
  - 文件：`shortcut/handy_keys.rs`、`shortcut/tauri_impl.rs`、`shortcut/mod.rs`、`shortcut/handler.rs`、
    `transcription_coordinator.rs`、`signal_handle.rs`、`lib.rs`
- [ ] **T3 绑定命令 + 设置 UI**
  - 验收：`set_workflow_bindings` 等命令；`WorkflowShortcutList` 可增删改；冲突提示
  - 验证：`bun run build` + `lint` + 手点
  - 文件：`shortcut/mod.rs`、`components/settings/**`、`stores/settingsStore.ts`、`bindings.ts`（生成）
- [ ] **T4 Workflow 进管线 + history**
  - 验收：`Workflow` 枚举；`process_transcription_output` 按工作流分派；history 增 `workflow` 列
  - 验证：`cargo test --lib actions::`（三工作流分派）+ `managers::history::`
  - 文件：`actions.rs`、`managers/history.rs`、`lib.rs`
- [ ] **T5 选区读取 + Ask**
  - 验收：`read_selected_text()`（AX 主 + 剪贴板兜底）；Ask 提示词与粘贴替换；失败降级
  - 验证：`cargo test --lib`（纯逻辑：哨兵判定、prompt 组装）+ 真机（微信/浏览器各一次）
  - 文件：`learning/ax/mod.rs`（或新 `selection.rs`）、`actions.rs`、`llm_client.rs`（如需）
- [ ] **T6 i18n + 全量验证 + 真机冒烟**

## 待确认

1. **拆分方式**：本阶段做「框架 + 听写 + Ask」，**翻译工作流的行为细节留 phase-7**（本阶段只让
   `translate` 能被绑键、能触发，并接到 phase-7 的翻译函数）。可以吗？
   - 备选：phase 5 就把翻译做完整（目标语言单值），phase 7 只做「≤3 语言 + 悬浮条 + 提示词打磨」。
2. **Ask 的形态**：有选区 → 替换选区；无选区 → 粘贴答案；失败 → 不粘贴 + 报错。符合预期吗？
3. **旧命令 `change_binding` / `reset_binding`**：是保留（内部转发到新的 Vec 接口，减少前端改动）
   还是删除、前端全部改走 `set_workflow_bindings`？（建议保留 + 转发）
4. **默认快捷键**：`dictation=option+space`、`ask=option+shift+space`、`translate=option+shift+t`
   （mac）可以吗？翻译的默认键 Typeless 用 `Fn+LeftShift`，但 Handy 的 HandyKeys 后端才支持 Fn。
5. **Ask 无选区**时，答案是**粘贴**还是只在悬浮窗显示？粘贴更简单；悬浮卡片属阶段 6。
6. **Ask 是否也支持「选中文本 + 说『翻译成英文』」**？按用户已确认的 (a) 不单独做，但 Ask 的
   SELECTED_TEXT 段天然允许这种指令（等于顺带支持）。接受吗？
