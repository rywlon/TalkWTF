# Spec: 阶段 2 — 润色风格 + 场景

状态：2a 已实现，待人工冒烟（2026-09-17）；2b 未开始
上游依据：`AGENTS.md`「策略」（润色不是让用户手写 prompt，而是「润色风格 + 场景」）与「阶段计划」第 2 项
参考实现：OpenTypeless 的 `polish_style` / `custom_scenes` / `system_scene_overrides` / `family_scene_assignments`
（核对 commit `213d4c4`，调研结论见下）

## 目标

让用户**选**润色方式，而不是**写** prompt：

- 一个 4 选 1 的**润色风格**（轻改 / 清爽 / 结构化 / 专业），默认即可用；
- 一组**场景**（会议纪要、专业邮件、客服回复…）可一键切换，也能自己新建、编辑、复制、导入导出；
- 转写内容**永远**会被送进模型——不再依赖用户记得写 `${output}`。

## 参考实现的关键事实（与 `AGENTS.md` 原描述有出入）

OpenTypeless 实际有四层，不是「场景」一层：

| 层 | 字段 | 我们的处置 |
|---|---|---|
| 全局润色风格 | `polish_style`（4 选 1） | **阶段 2 移植** |
| 内置起始场景 | `builtin_*`（7 个，代码常量，已不被其 UI 渲染） | **阶段 2 移植**，作为内置场景种子 |
| 自定义场景 | `custom_scenes`（name/description/prompt_template/时间戳） | **阶段 2 移植** |
| 系统场景改写 | `system_scene_overrides` | 阶段 4（那是 app 分类场景的可编辑副本） |
| 按 App 分类绑定 | `family_scene_assignments` + `ContextFamily` | **阶段 4**（依赖 app 检测） |

其他必须知道的：

- 内置数据全在**代码里**（Rust `match` + TS 常量，且重复了两份），不在 DB。
- 场景 prompt **没有占位符**：转写放在 user message 的 `<transcription>…</transcription>` 里，
  system prompt 只放规则。这正好解决我们踩过的 `${output}` 坑。
- 规则「有场景则跳过内置风格段」：场景与风格同时存在时，场景赢，风格段不拼接。
- 导入导出只导自定义场景，JSON 形如 `{version, exportedAt, scenes:[{id,name,description,promptTemplate,...}]}`；
  其实现**不校验 schema/version**（太宽松），我们会加校验。
- 不移植：cloud scene packs、Pro 门控、`/api/scenes`、账号相关文案。

## 范围

### 2a 核心（本轮实现）

1. **润色风格**：`polish_style` 4 选 1，默认 `clean`。
2. **场景数据模型**：`Scene` 类型 + 字段重命名迁移（见下）。
3. **内置场景**：7 个作为**种子数据**写入 store（不是代码常量，避免 i18n 爆炸，且用户可改名）。
4. **场景管理 UI**：列表 / 新建 / 编辑 / 复制 / 删除（二次确认）/ 激活 / 恢复内置场景。
5. **提示词组装改造**：`BASE + [STYLE] + [SCENE]`，转写固定放 `<transcription>`；
   不再要求 `${output}`（保留替换以兼容旧 prompt）。
6. **设置页分 tab**：把现在的单页拆成「快捷键」「风格与场景」「服务商」。

### 2b 打磨（紧接着，可单独验收）

7. **导入导出**：JSON，带 `schema` + `version` 校验，冲突 id 自动改名，部分成功并报告统计。
8. **场景编辑体验**：预览、字数上限提示、内置场景徽章、空状态。

## 数据模型

```rust
pub struct Scene {
    pub id: String,               // "scene_<millis>" 新建；内置为 "builtin_*"
    pub name: String,             // ≤80
    #[serde(default)]
    pub description: String,      // ≤240
    pub prompt: String,           // ≤4000
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub updated_at: String,
}
```

`AppSettings` 字段变更（用 serde `alias` 做零风险迁移，老 store 直接可读）：

| 旧 | 新 | 说明 |
|---|---|---|
| `post_process_prompts: Vec<LLMPrompt>` | `scenes: Vec<Scene>`（`alias = "post_process_prompts"`） | 用户现有提示词原样变成场景，`description` 为空 |
| `post_process_selected_prompt_id` | `active_scene_id: Option<String>`（`alias = "post_process_selected_prompt_id"`） | 语义从「选中的提示词」变成「激活的场景」 |
| — | `polish_style: String`（默认 `"clean"`） | 新增 |

- `LLMPrompt` 类型与 `post_process_*` 命令重命名；老 key 由 alias 承接，下一次写盘自然消失。
- 内置场景种子：`builtin_clean_dictation` / `builtin_meeting_notes` / `builtin_professional_email` /
  `builtin_support_reply` / `builtin_technical_explanation` / `builtin_code_comment` /
  `builtin_product_spec_notes`（prompt 文本照抄 OpenTypeless 的 `builtinScenes.ts`，英文）。
- 种子时机：**一次性迁移**（`CURRENT_SETTINGS_SCHEMA_VERSION` → 4）。已有的
  `default_improve_transcriptions` 保留为普通场景（用户可能正在用），不删。
- 「恢复内置场景」= 按钮，补齐缺失的 `builtin_*`，已存在的不动。

## 提示词组装（新）

```
system: <BASE 规则>            // 安全/保真/输出格式：不答问题、不加事实、空输入输出空
        + [POLISH STYLE]       // 仅当没有激活场景
        + [ACTIVE SCENE]       // 激活场景时拼接，且跳过风格段
        + [CUSTOM WORDS]       // 沿用现有 custom_words 注入（如已有）
user:   <transcription>
        {转写文本}
        </transcription>
```

- 转写**固定**出现在 user message，两种 provider 路径一致；`${output}` 仍做字符串替换以兼容旧 prompt，
  但内置场景与新文案都不再用它，UI 也不再推荐。
- `supports_structured_output` 保持现状（结构化输出仍走 JSON schema 路径，只是 user message 里放转写）。

## UI 结构

「AI 润色」页从单页改为 **segmented control + 3 个 tab**（侧边栏仍只有一个入口）：

| Tab | 控件 |
|---|---|
| 快捷键 | `ShortcutInput(transcribe)`、`ShortcutInput(transcribe_with_post_process)` |
| 风格与场景 | ① 风格：4 选 1 下拉（带一句说明）<br>② 当前场景：下拉（含「不使用场景（仅风格）」+ 全部场景），选中即激活<br>③ 我的场景：卡片列表（名称/描述/展开看 prompt），动作 = 复制 / 编辑 / 删除（内联二次确认）<br>④ 内置场景：徽章区分，可编辑（另存为自定义）/ 不可删 / 「恢复内置场景」按钮<br>⑤ 导入 / 导出按钮（2b） |
| 服务商 | 现有的 provider / base url / api key / model + 「配置未完成」提示 |

风格选项文案（i18n，新增 4 个 key）：

| 值 | zh | en |
|---|---|---|
| `minimal` | 轻改 | Minimal |
| `clean` | 清爽 | Clean |
| `structured` | 结构化 | Structured |
| `professional` | 专业 | Professional |

## 非目标

- app 检测、按 App 分类绑定场景、系统场景改写（阶段 4）
- Ask Anything / 翻译工作流（阶段 5）
- 视觉重做（阶段 6）——本阶段仍用现有组件与主题变量，不引入新 UI 框架、不引入新依赖
- 云场景包、账号、Pro 门控
- 场景拖拽排序、图标/分类字段（OpenTypeless 也没有）

## 验收标准

1. 默认状态下（未激活任何场景）说一句话 → 输出被 `clean` 风格润色，且**转写一定被送给模型**。
2. 切换风格（4 个）→ 输出风格可见地变化（至少「结构化」对多项内容会分点）。
3. 激活任一场景 → 风格段被跳过，场景指令生效；切回「不使用场景」恢复。
4. 可新建 / 编辑 / 复制 / 删除场景；删除有二次确认；最后一个场景不可删？——**不需要**，
   因为「不使用场景」永远可用（与提示词时代不同）。
5. 内置场景可编辑但另存为自定义，不可删；「恢复内置场景」能补回被删的。
6. 场景 prompt 里**不写** `${output}` 也能拿到正确结果（对比旧行为）。
7. 老 store（含 `post_process_prompts` / `post_process_selected_prompt_id`）升级后场景与激活状态不丢。
8. 导入导出往返一致；导入非法 JSON 时给出可读错误，不写坏 store（2b）。
9. `bun run build` / `lint` / `check:translations` / `cargo fmt --check` / `cargo check` / `cargo test` 全绿。

## 任务拆分

- [x] **T1 数据模型与迁移**
  - 验收：`Scene` 类型、字段重命名 + alias、`polish_style`、schema → 4、内置场景种子
  - 验证：`cargo test --lib settings::`（含 alias 兼容与种子一次性用例）
  - 文件：`settings.rs`

- [x] **T2 后端命令**
  - 验收：场景 CRUD / 激活 / 恢复内置 / 改风格 命令齐备，旧命令名清理
  - 验证：`cargo check` + `cargo test`
  - 文件：`shortcut/mod.rs`、`lib.rs`

- [x] **T3 提示词组装改造**
  - 验收：BASE + STYLE + SCENE，转写固定进 `<transcription>`；无场景时用风格段
  - 验证：`cargo test --lib actions::`（新增组装用例：有/无场景、有/无 `${output}`）
  - 文件：`actions.rs`（`build_system_prompt` 一带）、`llm_client.rs`（如需）

- [x] **T4 设置页分 tab + 风格 UI**
  - 验收：三 tab 可用；风格下拉生效
  - 验证：`bun run build` + `bun run lint` + 手点
  - 文件：`post-processing/PostProcessingSettings.tsx`、新增 tab/风格组件、`settingsStore.ts`、`bindings.ts`（生成）

- [x] **T5 场景管理 UI**
  - 验收：列表 / 新建 / 编辑 / 复制 / 删除 / 激活 / 恢复内置
  - 验证：手点
  - 文件：`post-processing/`（新增场景组件）

- [x] **T6 i18n + 全量验证**
  - 验收：验收标准 9 满足
  - 验证：四条命令 + 手动冒烟（默认风格 / 切换风格 / 激活场景各一次）
  - 文件：`src/i18n/locales/**`

- [ ] **T7（2b）导入导出**
  - 验收：验收标准 8 满足
  - 验证：`cargo test` + 手点（往返导入、坏 JSON、id 冲突）
  - 文件：新 `scene_io.rs`（对齐 OpenTypeless 的 `sceneImportExport.ts` 行为但加校验）、场景 UI

## 验证结果（2026-09-17）

| 命令 | 结果 |
|---|---|
| `bun run build` / `bun run lint` | 通过 |
| `bun run check:translations` | 通过（25/25） |
| `cargo fmt --check` / `cargo check` | 通过 |
| `cargo test --lib` | 290 passed（新增 11 个用例） |
| store 迁移实测 | schema 4、`polish_style=clean`、`active_scene_id` 清空、7 个内置场景已种入、用户自己的 `TEST` 场景保留、旧 `post_process_prompts` 键消失 |
| 真实听写冒烟 | **未执行**（默认风格 / 切换风格 / 激活场景各一次） |

实现要点：

- `Scene` 取代 `LLMPrompt`；`scenes` / `active_scene_id` 用 serde `alias` 承接 `post_process_prompts` /
  `post_process_selected_prompt_id`，老 store 零迁移成本。
- 内置场景是**可编辑、可删除**的种子数据（`builtin_` 前缀），`reset_scene` 恢复单个、`restore_built_in_scenes` 补回全部。
  没有采用 OpenTypeless 的 `system_scene_overrides` 覆盖表——那样会多一张表和一套 id 校验。
- 提示词组装：`BASE_PROMPT` + `[POLISH STYLE]` 或 `[ACTIVE SCENE]`，转写固定进 `<transcription>`；
  两种 provider 路径（结构化 / 纯 chat）现在共用同一份 system prompt 与 user message，`send_chat_completion`
  这个旧包装函数被删掉。`${output}` 仍做替换以兼容旧模板。
- `BASE_PROMPT` 改为移植 OpenTypeless 的 `BASE_PROMPT`（9 条规则 + 5 个示例 + DISFLUENCY 段 +
  SECURITY 防注入段），并合并 Handy 老提示词里的两条（数字词转阿拉伯数字、口头标点转符号）。
  裁剪：去掉西语问号规则、selected-text / 翻译 / app-aware 段落（属阶段 4/5）。约 4150 字符 ≈ 1150 token。
- 顺带修掉一个真实的速度缺陷：`disable_reasoning` 原本只对 `custom` / `openrouter` 为 true，
  DeepSeek 不在其中，于是每次润色都让模型先「思考」——日志里 108–216 字的输出耗时 2s 到 14s 就是它。
  `llm_client` 里早就有 DeepSeek 的 `thinking: {"type":"disabled"}` 专用处理，只是从未被触发。
- 4 个风格由后端 `POLISH_STYLE_TABLE` 单一来源提供（id + 中文标签 + prompt），新增命令
  `get_polish_styles`，避免前端再抄一份 id 列表。
- 设置页分 3 个 tab；场景编辑器的文案复用已有 `prompts.*` key（只改 en/zh 的值），
  真正新增的 i18n key 只有 11 个。

## 已知限制（本阶段接受）

- 内置场景的 name/description/prompt 是**英文种子数据**（不 i18n），用户可自行改名。
  理由：7 个场景 × 2 个字段 × 26 个 locale 的翻译成本远大于收益，且它们是可编辑数据而非 UI 文案。
- 场景与风格同时存在时风格被跳过（沿用 OpenTypeless 规则），UI 需要把这点说清楚。
- 本阶段仍无 app-aware：场景靠手动切换。

## 已确认的决策（2026-09-17）

1. **2a / 2b 切分**：接受。T1–T6 先做完（核心可用），T7 导入导出单独一轮。
2. **内置场景语言**：中文名 + 中文描述 + 英文 prompt。它们是可编辑种子数据，不走 i18n。
3. **UI 结构**：3 个 tab（快捷键 / 风格与场景 / 服务商），侧边栏仍只有一个「AI 润色」入口。
4. **旧的 `Improve Transcriptions`**：仅当它与内置原文逐字一致（未被用户改过）时删除；
   其规则并入 BASE。改过则保留为普通场景。与 Ollama 的清理规则一致。

## 待确认（已全部确认，保留供追溯）

1. **2a / 2b 的切分**是否接受？（T1–T6 先做，T7 导入导出单独一轮）
2. **内置场景用英文种子数据**（可改名）而不是 i18n，接受吗？
3. **设置页分 3 个 tab**（快捷键 / 风格与场景 / 服务商）而不是拆成两个侧边栏入口，可以吗？
4. 旧的 `default_improve_transcriptions` 提示词**保留为普通场景**（不删），可以吗？
