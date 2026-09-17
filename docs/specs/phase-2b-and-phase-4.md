# 阶段 2b（润色配置导入导出）+ 阶段 4（app-aware 润色）spec

> 依据 AGENTS.md 的阶段计划。
>
> **决定（2026-09-17）**：只做 **2b**；**阶段 4 否决**——用户看过 spec 后判断无用（app-aware 有价值的部分
> 恰恰是窗口标题/浏览器 URL 那类上下文，而隐私硬约束下我们不发这些，剩下的粗粒度分类收益很低）。
> 下面阶段 4 的内容保留作记录，不再实施。

## 现状（写 spec 前核过的事实）

- 场景：`settings.rs:93-104` `Scene { id, name, description, prompt, created_at, updated_at }`，
  存在 `AppSettings.scenes`（`settings.rs:465`）；内置 7 个以 `builtin_` 前缀标记（`settings.rs:809-864`）；
  上限见 `settings.rs:884-887`（名称 80 / 描述 240 / 提示词 4000 / 最多 100 条）。
- 风格：全局固定表 `POLISH_STYLE_TABLE`（`settings.rs:895-900`，minimal/clean/structured/professional），
  `polish_style` 字段 `settings.rs:472`，渲染 `polish_style_prompt()` `settings.rs:966`。
- 命令（`shortcut/mod.rs`，注册于 `lib.rs:690-698`）：`add_scene` / `update_scene` / `delete_scene` /
  `reset_scene` / `restore_built_in_scenes` / `set_active_scene` / `change_polish_style` / `get_polish_styles`。
  **没有**导入导出，也没有排序命令。
- 提示词组装：`actions.rs:166-199` `build_system_prompt`，顺序 = `BASE_PROMPT`(`actions.rs:94-158`)
  → 词典/规则（`append_dictionary_sections`）→ 场景（`${output}` 替换 + `ACTIVE SCENE`）
  或风格（`POLISH STYLE`）。`BASE_PROMPT` 是从 OpenTypeless `prompt.rs` 移植时**去掉了** app-aware 段。
- 可复用的导入导出样板：词典 `commands/dictionary.rs`（格式常量 :18-19、`DictionaryImportReport` :36-40、
  文件结构 :44-57、解析校验 :139-155、合并去重 :90-137、命令 `export_dictionary` :244 / `import_dictionary` :268）；
  前端 `DictionarySettings.tsx:564-599`（`plugin-dialog` 的 `save`/`open` + toast + busy 态）。
- 前台 app 检测（3.5 已有，直接复用，零新依赖）：`learning/ax/mod.rs:151-155` `frontmost_bundle_id()`
  （`NSWorkspace.frontmostApplication`），`is_blocked_app()` :157，`BLOCKED_BUNDLE_IDS` :41。
- 移植源：`/Users/SheenaRingo/.opentypeless-audit`（commit `213d4c4`）——
  `app_detector/types.rs:96-105` `ContextSignals`；`app_detector/registry.rs:118-198` `classify_with_mapping`
  （优先级：用户映射 → 浏览器 host 精确/后缀 → bundle id → 进程别名 → 窗口标题标记 → 兜底）；
  `ContextFamily` 10 类（`types.rs:7-18`）；`llm/context_policy.rs:5-127` `ContextPolicy::for_family` +
  `render_family_rules` :138-176；`llm/prompt.rs:143-243` `build_context_system_prompt`；
  **只发** `ContextProfileSummary`（`types.rs:84-93`：`profile_id/family/app_label/icon_key/override_id/
  browser_access_status/browser_target`），窗口标题/URL/进程 id 明确不序列化（有测试守着）。

---

## 阶段 2b：润色配置导入导出

**目标**：把「风格 + 场景」导出成一个 JSON 备份，能换机/分享后导入，导入是合并（不覆盖现有）。

**范围**
1. 后端新命令（照抄词典那套路径式接口，文件 IO 在 Rust、原生对话框在 JS）：
   `export_polish_profile(path)` / `import_polish_profile(path)`。
2. 文件格式：`{ "format": "talkwtf_polish_profile", "version": 1, "polishStyle": "clean",
   "activeSceneId": "...", "scenes": [{ id, name, description, prompt }] }`；
   只导出**自定义**场景（`builtin_` 前缀的不写进文件，避免把内置复制成自定义）。
3. 导入合并规则：按名称（大小写/空白不敏感）去重跳过；字段超限或空的记为 invalid 跳过；
   导入的场景**重新分配 id**（不覆盖本地 id）；`activeSceneId` 只在本地没有激活场景时才采用。
   返回 `{ accepted, skipped_duplicates, skipped_invalid }`，前端 toast 报告（复用 `importReport` 的文案结构）。
4. 前端：`StyleAndScenesPane.tsx` 顶部加「导入 / 导出」两个按钮（沿用词典页的 `save`/`open` + busy + toast 写法）。
5. i18n：新增 key 到 26 个语言文件（zh/en 真译，其余先英文兜底），`check:translations` 必须通过。

**非目标**
- 不做云同步/分享链接；不导入导出词典（词典已有自己的导入导出）；不改 `Scene` 存储结构；不做场景排序。

**验收标准**
- 导出 → 导入 round-trip：自定义场景、当前风格、激活场景都能恢复；内置场景不会被复制成自定义。
- 重复/非法条目跳过并计数，不报致命错。
- `cargo test --lib` / `cargo fmt --check` / `eslint` / `prettier` / `bun run build` / `check:translations` 全绿。

**实现记录（2026-09-17，已完成）**
- 新模块 `src-tauri/src/commands/polish_profile.rs`：`POLISH_PROFILE_FORMAT`/`_VERSION`、`PolishProfileFile`/
  `PolishProfileScene`/`PolishProfileImportReport`、`export_polish_profile`/`import_polish_profile`、
  `merge_polish_profile`（纯函数，5 个单测）+ `fresh_scene_id`（沿用 `add_scene` 的 id 方案）。
- `settings.rs` 新增 `is_built_in_scene()` 与 `pub fn default_polish_style()`；命令注册在 `lib.rs`。
- 采纳规则：风格只在本地还是默认值时采纳，激活场景只在本地为空时采纳（按**名称**映射到新 id）——
  空机器上恢复备份是全量恢复，已有配置的机器不会被悄悄改掉选择。
- 前端 `StyleAndScenesPane.tsx` 加导入/导出按钮（`plugin-dialog` + toast + 报告），26 语言补 4 个 key。
- 验证：`cargo test --lib` 354 passed；`cargo fmt --check` / `eslint` / `prettier` / `bun run build` /
  `check:translations` 全绿。

**任务拆分**
- T1 后端：格式常量 + `PolishProfileFile` 解析校验 + 合并逻辑（含单测：round-trip、去重、超限、缺字段、版本不符）。
- T2 后端：两个命令 + 注册 + 绑定生成。
- T3 前端：两个按钮 + 报告 toast + i18n（26 语言）。

---

## 阶段 4：app-aware 润色

**目标**：按前台应用类别调整润色的语气/格式（聊天口语化、邮件补标点分段、编辑器不动术语），
**只把粗粒度分类**发进提示词。

**范围**
1. 新模块 `src-tauri/src/app_context/`：
   - 检测：复用 `learning/ax::frontmost_bundle_id()`（本地、无网络、零新依赖）。
   - 分类：内置 `bundle id → family` 映射表，family 取 OpenTypeless 的 10 类
     （email / work_chat / personal_chat / document / project_management / developer_collaboration /
     prompt_or_code / support / social / general），覆盖常用：微信、QQ、飞书、Slack、Discord、Mail、
     Outlook、VS Code、Cursor、Terminal/iTerm、Notion、Obsidian、Safari/Chrome 等；未命中 → general。
   - 隐私：**只采集 bundle id**，不读窗口标题、不读 URL、不读进程 id；发进提示词的只有
     `{ family, app_label }`（`app_label` 用白名单里的显示名，不用 bundle id 原文）。
2. 策略表 `app_context/policy.rs`：移植 `context_policy.rs` 的 `ContextPolicy::for_family`，裁剪到自用范围，
   渲染成一小段规则文本（`render_family_rules` 等价物）。
3. 提示词接线：`build_system_prompt` 在词典之后、场景/风格**之前**插入 `[APP CONTEXT]` 段
   （场景 > 风格 > app 分类的优先级，保证用户显式选择能压过自动分类）。
4. 设置：`app_aware_enabled: bool`（默认 true；设置页可关）+ 一个诊断区显示「当前前台 app → 分类」
   （纯本地展示，便于核对映射是否命中）。
5. UI：设置页「润色」分组加开关 + 诊断（沿用 `diagnoseEditLearning` 那种按钮+文本框的写法）。
6. i18n：新增 key 到 26 个语言文件。

**非目标**
- 不做窗口标题 / 浏览器 URL / 进程名采集（隐私硬约束）。
- 不做每 app 自定义 matcher 的 UI（先内置映射表；用户要覆盖就用场景/风格手动选）。
- 不做云同步、不做遥测、不改本地 ASR 运行时。
- 不做「按 app 自动切换场景」（可作为阶段 4.5，等 4 跑稳再说）。

**验收标准**
- 在聊天 / 邮件 / 终端 三类里各听写一次：日志能查到分类结果；提示词里出现对应 family 规则；
  **不含**窗口标题、URL、bundle id 原文。
- 关闭开关后，提示词里不再有该段；场景/风格仍然优先生效。
- 未知 app 落到 general，不报错。
- `cargo test --lib` / `cargo fmt --check` / `eslint` / `prettier` / `bun run build` / `check:translations` 全绿。

**任务拆分**
- T1 `app_context` 检测 + 分类 + 内置映射表（单测：微信→personal_chat、Mail→email、Terminal→prompt_or_code、
  未知→general、发出去的 payload 不含敏感字段）。
- T2 policy 表 + 规则文本渲染（单测：每类都有非空规则、渲染稳定）。
- T3 `build_system_prompt` 接线 + `app_aware_enabled` 开关（单测：开关关闭时无该段；场景优先于分类）。
- T4 设置页开关 + 诊断区 + i18n。
- T5（可选，后续）每 app 覆盖场景/风格。
