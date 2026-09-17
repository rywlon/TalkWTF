# Spec: 阶段 3 — 词典 + 纠错规则（SQLite 版）

状态：T1–T6 已实现，待人工冒烟（2026-09-17）
上游依据：`AGENTS.md`「阶段计划」第 3 项（增删改、导入导出、纠正规则、本地存储）
参考实现：OpenTypeless 的 `DictionaryStore` / `dictionary_io.rs` / `DictionaryPane`（核对 commit `213d4c4`）

## 已确认的决策（2026-09-17）

1. **纠错规则 = 确定性替换 + 提示词注入**（不只做提示词引导）
2. **词典放侧边栏独立入口**，不留在「高级 → 转录」
3. **导入导出只做 JSON**
4. **阈值滑块从 debug 移到词典页**
5. **存储用 SQLite**（用户明确要求，不用 settings JSON）
6. 顺手补**行级 salvage**：坏行丢弃、好行保留（`scenes` 现在有「一行坏掉丢全部」的隐患）

## 目标

让「ASR 听错的词」能被修好，而且用户能自己修：

- 词表既影响 ASR，也进润色提示词（后者是今天缺的一环）
- 纠错规则（`open type place` → `OpenTypeless`）能**确定性**生效，不依赖模型
- 词表与规则可增删改、可开关、可导入导出，且**行级可靠**（不因一行损坏丢全部）

## 现状

**我们的**
- `custom_words: Vec<String>`（`settings.rs:440`）+ `apply_custom_words`（`audio_toolkit/text.rs:151`）：
  Levenshtein + Soundex + 1–3 词 n-gram，阈值 `word_correction_threshold`（默认 0.18），**只对 ASCII 生效**。
- 两个消费点，都在 `TranscriptionManager` 内部读 `settings.custom_words`：
  whisper 的 `initial_prompt`（`transcription.rs:1310`）与模糊纠错（`transcription.rs:1769`
  的 `post_process_transcription_text`，由 `finalize_stream` 1139 / `transcribe` 1496 调用）。
- **润色提示词看不到词典**（`actions.rs:163` 的 `build_system_prompt`）。
- UI 只能增/删（`CustomWords.tsx`），无编辑/搜索/导入导出；阈值滑块在 `debug/`。
- `update_custom_words`（`shortcut/mod.rs:824`）零校验、不去重、不发 `settings-changed`。

**底座可复用的**
- `HistoryManager`（`managers/history.rs`）是现成范本：`AppHandle` + `db_path`、
  **每次调用新开 `Connection`**、`MIGRATIONS: &[M]` + `Migrations::new(...).to_latest(&mut conn)`、
  `anyhow::Result`、迁移版本存在 SQLite 的 `user_version`。
- `TranscriptionManager` 已经持有 `app_handle`，并已有 **懒查 Tauri state** 的写法
  （`transcription.rs:329` 的 `try_state::<Arc<AudioRecordingManager>>()`）。
- 依赖齐备：`rusqlite 0.37 (bundled)`、`rusqlite_migration 2.3`、`regex`。
- `portable::app_data_dir()` 给出数据目录（`history.db`、`recordings/` 都在那儿）。

**OpenTypeless 的（含坑）**
- 表 `dictionary(id, word, pronunciation)`、`correction_rules(id, pattern, replacement, enabled, created_at)`；
  无唯一约束，去重在 Rust 用 NFKC + 小写规范化。
- 上限：word 100 字、pattern/replacement 120 字、导入 1 MiB / 10000 行、提示词里规则截断 100 条，
  而**词条不设上限**（他们的提示词体积风险）。
- `pronunciation` 是**死字段**：存/显/导出都有，没有任何行为读它。
- `correction_rules.created_at` 也是写了不读。
- 纠错规则**只做提示词引导**，没有确定性替换。
- 不该抄：云备份、场景包词表、Pro 门控、没被引用的 `001_init.sql`。

## 存储设计（SQLite）

**独立文件 `dictionary.db`**（`app_data_dir/dictionary.db`），**不并入 `history.db`**。
理由：各自的迁移链独立演进；`HistoryManager` 不必为一个不相关领域扩表；文件名与内容一致。
`DictionaryStore` 照抄 `HistoryManager` 的形状（`AppHandle` + `db_path` + 每调用一个连接 + `anyhow::Result`）。

```sql
-- migration 1
CREATE TABLE dictionary (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    word TEXT NOT NULL
);
CREATE TABLE correction_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pattern TEXT NOT NULL,
    replacement TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

- **不抄** `pronunciation` 与 `created_at`（两者都是死字段）。排序用 `id ASC`。
- 唯一性不做 SQL 约束（NFKC 规范化 SQLite 表达不了），改在 Rust 用
  `NFKC + trim + lowercase` 规范化后比对，重复时返回可读错误。
- `meta` 表用于一次性标记：`legacy_custom_words_imported`。
- 上限：word 100 字；pattern/replacement 各 120 字；规则提示词截断 100 条；词条提示词截断 200 条。

### 老数据迁移

`DictionaryStore::new()` 在迁移后执行 `import_legacy_custom_words()`：

1. 读 `meta['legacy_custom_words_imported']`，已存在则直接返回
2. 否则读 settings 原始 JSON 里的 `custom_words`（数组），逐条插入（规范化去重）
3. 写入 `meta['legacy_custom_words_imported'] = '1'`

用标记而不是「表为空就导入」，避免「用户清空词表后重启又冒出来」。
完成后 `AppSettings.custom_words` **字段删除**（老 store 里残留的键由 serde 忽略，
首次写盘自然消失；`apply_custom_words` 的签名不变，只是数据来源换成 DB）。

## 数据怎么进到转写路径（plumbing）

采用**懒查 Tauri state**（`B′`），不改进程内缓存的模式（后端没有 `settings-changed` 监听，不发明新机制）：

- `lib.rs` 的 `initialize_core_logic` 里 `app.manage(Arc<DictionaryStore>)`；
  **headless 分支也要建**（否则 CLI `--transcribe-file` 会丢掉词表纠错）。
- `transcribe()` / `finalize_stream()` 内部：
  `self.app_handle.try_state::<Arc<DictionaryStore>>()` → 取快照；取不到就用空快照。
- `post_process_transcription_text` 增加一个 `dictionary: &DictionarySnapshot` 参数
  （`{ words: Vec<String>, rules: Vec<CorrectionRule> }`），替换现在直接读 `settings.custom_words` 的写法。
  调用点：1139、1496 + 5 个测试。
- `process_transcription_output`（`actions.rs:525`，有 `AppHandle`）也取一次快照，
  传给 `post_process_transcription` → `build_system_prompt`。

**不改** `transcribe()` / `finalize_stream()` 的公开签名（3+1 个外部调用点不用动）。
每次听写多两次 SQLite 读（本地、微秒级），可接受。

## 纠错规则的行为

**确定性替换**（新增 `apply_correction_rules`，在 `apply_custom_words` **之前**执行）：

- 只处理 `enabled = 1` 的规则，按 `id ASC`
- 字面匹配（`regex::escape`，绝不让用户输入变成正则）、大小写不敏感
- ASCII 模式用词边界（`\b`）；含 CJK 的模式退化为直接子串替换
- 替换结果不再被后续规则重复处理（逐条作用于同一份文本，不做链式回写）

**提示词注入**（`build_system_prompt` 增加两段，照抄 OpenTypeless 原文）：

```
IMPORTANT: The following are the user's custom terms. Always use these exact spellings:
- "OpenTypeless"

USER CORRECTION RULES: When the transcript likely contains the left phrase, output the right
phrase. Use context; do not apply blindly if it would change the intended meaning.
- "open type place" -> "OpenTypeless"
```

词条 ≤200 条、规则 ≤100 条（截断，不报错）。

## 后端命令

| 命令 | 说明 |
|---|---|
| `get_dictionary()` | 返回 `{ words: [{id, word}], rules: [{id, pattern, replacement, enabled}] }` |
| `add_dictionary_word(word)` / `update_dictionary_word(id, word)` / `delete_dictionary_word(id)` | 词表 CRUD |
| `add_correction_rule(pattern, replacement)` / `update_correction_rule(id, pattern, replacement)` / `delete_correction_rule(id)` / `set_correction_rule_enabled(id, enabled)` | 规则 CRUD |
| `export_dictionary()` / `import_dictionary()` | Rust 侧用 `tauri-plugin-dialog` 的 save/open + `std::fs`（不需要给前端加 fs 权限） |

`update_custom_words` 命令**删除**（被上面的 CRUD 取代）。
`change_word_correction_threshold_setting` 保留（阈值仍在 settings，是调参不是词典数据）。

导入导出 JSON 格式：

```json
{
  "format": "talkwtf_dictionary",
  "version": 1,
  "words": ["OpenTypeless", "Tauri"],
  "correctionRules": [
    { "pattern": "open type place", "replacement": "OpenTypeless", "enabled": true }
  ]
}
```

- 导入**合并**（不替换），规范化去重，返回 `{ accepted, skippedDuplicates, skippedInvalid }`
- 解析宽容：`words` 接受字符串或 `{ "word": ... }` 对象；`correctionRules` 也接受 `correction_rules`
- `format` 存在时必须匹配，`version` 必须为 1；非法输入给可读错误且不写坏 DB
- 整个导入在一个事务里，失败回滚

## UI

侧边栏新增「词典」入口（放在「AI 润色」下面），页内：

```
[搜索框]                      [导入] [导出]
[ 词汇 | 纠错规则 ]  ← 分段控制
─────────────────────────────────
词汇：
  [输入框] [添加]
  word1                              [编辑] [删除]
  ...
  模糊匹配严格程度  [滑块] 0.18
纠错规则：
  [错误写法] [正确写法] [添加]
  ☑ open type place → OpenTypeless   [编辑] [删除]
  ...
```

- 内联编辑（点「编辑」该行变成输入框 + 保存/取消）
- 规则行有启用开关；停用后灰显
- 删除需二次确认（比 OpenTypeless 的「直接删」保守一点）
- 搜索在本地过滤两个分段
- `CustomWords` 从「高级 → 转录」移除，组件删除
- 阈值滑块从 `debug/` 移到词汇分段下方（`debug/WordCorrectionThreshold.tsx` 删除）

## 非目标

- CSV / TXT 导入导出（JSON 够用）
- `pronunciation` 字段（死字段）
- 正则纠错规则（字面 + 整词就够）
- per-app 词表映射（阶段 4）
- 场景导入导出（阶段 2b，届时复用这里的导入导出骨架）
- 云备份、场景包词表、Pro 门控

## 验收标准

1. 把 `OpenTypeless` 加进词汇 → 说 "open type place" → 输出 `OpenTypeless`（模糊或提示词任一命中）。
2. 加规则 `open type place` → `OpenTypeless` → **立刻**生效，关掉 thinking 也生效。
3. 规则可停用；停用后不替换、也不出现在提示词里。
4. 词表与规则都出现在润色提示词里（Rust 测试断言原文）。
5. 词汇与规则都能增/改/删；重复被拒并给出提示；超长被拒。
6. 导入导出 JSON 往返一致；非法 JSON 给可读错误且不写坏 DB；重复跳过并统计。
7. **老数据迁移**：升级后原 `custom_words` 里的词出现在词典 DB 里，且不会重复导入（重启不再冒出来）。
8. 一行数据损坏不会丢掉整个词表/规则表（行级 salvage 生效）。
9. 中文词条不会被模糊匹配破坏（沿用现有 CJK 跳过行为）。
10. 构建/测试/lint/translations 全绿。

## 测试策略

- 后端为主：`DictionaryStore` 的 CRUD/去重/上限/事务回滚；`apply_correction_rules` 的字面/整词/大小写/CJK/停用；
  `build_system_prompt` 的词典与规则段；导入导出的往返与非法输入；legacy 导入的一次性（跑两次只导一次）。
- 前端：`tsc` + `eslint`。
- 手动冒烟：加词、加规则、开关规则、导入导出各一次 + 一次真实听写。

## 任务拆分

- [x] **T1 `DictionaryStore` + 迁移 + legacy 导入**
  - 验收：`dictionary.db` 建表；CRUD + 规范化去重 + 上限校验；`meta` 一次性标记生效；
    `custom_words` 字段从 `AppSettings` 删除
  - 验证：`cargo test --lib dictionary` + `cargo check`
  - 文件：新 `managers/dictionary.rs`、`managers/mod.rs`、`lib.rs`、`settings.rs`

- [x] **T2 确定性纠错 + 提示词注入**
  - 验收：`apply_correction_rules` 接入 `post_process_transcription_text`（在 `apply_custom_words` 之前）；
    词典与规则进 `build_system_prompt`（≤200 / ≤100）；快照 plumbing（`try_state` + headless）
  - 验证：`cargo test --lib`（新增两组用例）
  - 文件：`audio_toolkit/text.rs`、`managers/transcription.rs`、`actions.rs`

- [x] **T3 词典命令 + 导入导出**
  - 验收：CRUD/toggle 命令齐备；`export_dictionary` / `import_dictionary` 走原生对话框 + 事务；
    `update_custom_words` 删除
  - 验证：`cargo test --lib` + `cargo check`
  - 文件：`shortcut/mod.rs`（或新 `commands/dictionary.rs`）、新 `dictionary_io.rs`、`lib.rs`

- [x] **T4 词典设置页**
  - 验收：侧边栏入口；两个分段 + 搜索 + 增删改 + 启用开关 + 阈值滑块 + 导入导出；
    `CustomWords` 与 debug 阈值滑块移除
  - 验证：`bun run build` + `bun run lint` + 手点
  - 文件：新 `components/settings/dictionary/*`、`Sidebar.tsx`、`settings/index.ts`、
    `advanced/AdvancedSettings.tsx`、`debug/DebugSettings.tsx`

- [x] **T5 行级 salvage（settings 侧）**
  - 验收：`scenes` / 其他数组字段里一行损坏时，只丢那一行
  - 验证：`cargo test --lib settings::`（新增用例）
  - 文件：`settings.rs`

- [x] **T6 i18n + 全量验证 + 冒烟**
  - 验收：验收标准 10 满足
  - 验证：四条命令 + 手动冒烟
  - 文件：`src/i18n/locales/**`

## 已知限制（本阶段接受）

- 模糊匹配仍只对 ASCII 生效（Handy 原有行为，改它要动 ASR 后的文本变换，风险高）；中文靠提示词与规则。
- 确定性替换是**字面**匹配：规则写 `not` → `note` 会误伤 "I am not sure"（ASCII 走词边界能挡一部分）。
  缓解：规则可停用 + UI 写明「字面匹配」。
- 导入只有**合并**，没有替换/覆盖模式。
- 词典与历史是两个 DB 文件，不共享事务（无跨域事务需求）。

## 验证结果（2026-09-17）

| 命令 | 结果 |
|---|---|
| `bun run build` / `bun run lint` / `bun run check:translations` | 通过 |
| `bun run prettier --check` | 通过 |
| `cargo fmt --check` / `cargo check` | 通过（仅剩 1 条存量 warning） |
| `cargo test --lib` | 315 passed（阶段 3 新增 15 个用例） |
| 真机 `dictionary.db` | 已生成：3 张表、`user_version=1`、`meta.legacy_custom_words_imported=1` |
| 日志 | 0 条 ERROR / panic |
| 真实听写冒烟 | **未执行** |

实现记录：

- 独立 `dictionary.db` + `DictionaryStore`（照 `HistoryManager`：`db_path` + 每调用一个新连接 + `anyhow::Result` +
  `Migrations::new(...).to_latest()`）。
- legacy 导入用 `meta` 标记而不是「表为空」，避免清空后重启又冒出来；有测试跑两次只导一次。
- 管线用懒查 state（`try_state::<Arc<DictionaryStore>>()`），`transcribe()` / `finalize_stream()` 签名未动；
  headless 分支也建 store。
- `apply_correction_rules` 放在 `managers/dictionary.rs`（规则与其语义同处），没有动 `audio_toolkit/`；
  `regex::escape` + `regex::NoExpand` 保证用户输入不会变成正则、`$` 不会被当捕获引用。
- 提示词段照抄 OpenTypeless 原文，词条 ≤200、规则 ≤100。
- 导入导出走「前端原生对话框取路径 + Rust 读写文件」，因此**不需要给 webview 加 fs 写权限**。
- 顺手删掉了 `update_custom_words` 命令、`CustomWords.tsx`、debug 里的阈值滑块（已移到词典页）。
- 测试时发现并修掉一个自己引入的 bug：`DictionaryFile` 的字段名是 snake_case，而导出的 JSON 用 camelCase
  `correctionRules`，导致导入时规则被静默忽略（现已 `rename` + alias）。

## 变更记录

- 2026-09-17 初稿（JSON 方案）。
- 2026-09-17 改为 SQLite 方案：独立 `dictionary.db` + `DictionaryStore`（照 `HistoryManager` 形状）；
  懒查 state 的 plumbing（不改 `transcribe`/`finalize_stream` 签名）；`custom_words` 一次性导入后删字段；
  `meta` 表做一次性标记；新增 T5 行级 salvage。
