# Spec: 阶段 1.5 — 取消纯转写模式（所有听写默认润色）

状态：已实现，自动化验证全绿；T5 待人工冒烟（2026-09-17）
上游依据：`AGENTS.md`「策略」的交互模型（听写 = 转录 + 润色，没有纯转写模式）与「阶段计划」第 1.5 项
参考实现：OpenTypeless 只有一个「听写」热键，按下即转录 + 润色；Ask / 翻译是另外的工作流热键

## 目标

听写不再分「纯转写」和「带润色」两种模式：**任何已绑定的听写热键都产出润色后的文本**。
用户不必先找到某个开关、也不必记住哪个热键才会润色。

## 现状（代码线索）

- 两个热键绑同一件事，但行为不同：`ACTION_MAP` 里 `transcribe` → `post_process: false`、
  `transcribe_with_post_process` → `post_process: true`（`src-tauri/src/actions.rs:929`）。
- `post_process_enabled` 开关只用来 gate 第二个热键的注册，共 5 处：
  `shortcut/mod.rs:258`、`shortcut/mod.rs:450`、`shortcut/tauri_impl.rs:27`、
  `shortcut/handy_keys.rs:437`、`secure_input.rs:483`。
- 这个开关的 UI 在「AI 润色」页顶部（阶段一从 experimental 移过来的）。
- 用户按主热键（`transcribe`）时完全没有 LLM 参与，且没有任何提示——这是「提示词没生效」的实际原因。
- 润色失败时 `process_transcription_output` 静默保留原始文本（`actions.rs:442`），只在日志里 `error!`。

## 范围

1. **`transcribe` 也走润色**：`ACTION_MAP` 里 `post_process: true`。
2. **保留两个绑定**，都走同一工作流。理由：OpenTypeless 明确支持「一个工作流多个快捷键」，
   删掉绑定会牵动 `transcription_coordinator`、`signal_handle`(SIGUSR1)、CLI、4 处注册逻辑，
   收益只是少一行 UI。第二个绑定改名为「听写备用快捷键」，语义诚实。
3. **移除 `post_process_enabled`**：字段、命令、UI 开关、store 映射、i18n 一并删除。
   它原本唯一的作用是 gate 注册；润色恒开之后它没有意义，留着就是死开关。
4. **文案对齐**：`transcribe` 的 i18n 名称/描述改为「听写（转录 + 润色）」；
   `transcribe_with_post_process` 改为「听写备用快捷键」。
5. **失败降级保持不变**：LLM 报错 → 用原始转写，日志留 `error!`。

## 非目标

- **润色失败的界面可见反馈**：见「已知限制」，本阶段只保留日志 + 自动降级。
- 场景 / 润色风格（阶段 2）
- 词典（阶段 3）
- app-aware（阶段 4）
- Ask / 翻译工作流（阶段 5）
- 视觉重做（阶段 6）

## 验收标准

1. 按 `transcribe`（用户当前是 `option_right+fn+left`）→ 产出润色后文本，日志出现 `Starting LLM post-processing`。
2. 按 `transcribe_with_post_process` → 同样产出润色后文本。
3. 设置里不再有「润色开关」；两个热键都始终注册。
4. 老 store 里的 `post_process_enabled` 与绑定条目不导致加载失败（serde 忽略未知字段）。
5. 提示词里没有 `${output}` 时，行为与阶段一一致（属提示词用法问题，不是本阶段的 bug）。
6. `bun run build` / `lint` / `check:translations` / `cargo fmt --check` / `cargo check` / `cargo test` 全绿。

## 命令

```
前端构建    bun run build
前端 lint   bun run lint
翻译检查    bun run check:translations
后端检查    cd src-tauri && cargo check
后端测试    cd src-tauri && NO_PROXY=127.0.0.1,localhost cargo test --lib
后端格式化  bun run format:backend
开发运行    PATH="/opt/homebrew/opt/rustup/bin:$PATH" bun run tauri dev
```

## 测试策略

- 后端：`settings.rs` 加一个用例断言默认设置里没有 `post_process_enabled`（字段已删）且
  两个听写绑定都存在；`actions.rs` 加用例断言 `ACTION_MAP` 里两个听写 binding 都 `post_process: true`。
- 前端：`tsc` + `eslint`（不加 e2e）。
- 手动冒烟：按两个热键各说一句，确认都润色。

## 任务拆分

- [x] **T1 所有听写热键走润色**
  - 验收：`ACTION_MAP` 两个听写 binding 都是 `post_process: true`
  - 验证：`cargo test --lib actions::`
  - 文件：`actions.rs`

- [x] **T2 移除 `post_process_enabled` 的注册 gating**
  - 验收：两个热键无论开关如何都注册
  - 验证：`cargo check` + 手点
  - 文件：`shortcut/mod.rs`、`shortcut/tauri_impl.rs`、`shortcut/handy_keys.rs`、`secure_input.rs`

- [x] **T3 删除 `post_process_enabled` 字段与命令**
  - 验收：字段、`default_post_process_enabled`、`change_post_process_enabled_setting`、lib.rs 注册全部消失
  - 验证：`cargo check` + `cargo test`
  - 文件：`settings.rs`、`shortcut/mod.rs`、`lib.rs`

- [x] **T4 前端清理**
  - 验收：设置页没有润色开关；`PostProcessingToggle` 与 store 映射删除；`bindings.ts` 同步
  - 验证：`bun run build` + `bun run lint`
  - 文件：`post-processing/PostProcessingSettings.tsx`、`settings/index.ts`、`stores/settingsStore.ts`、`bindings.ts`

- [x] **T5 i18n + 全量验证**
  - 验收：验收标准 6 满足
  - 验证：四条命令 + 手动冒烟
  - 文件：`src/i18n/locales/**`

## 已知限制（本阶段接受）

- **润色失败没有界面反馈**：现在润色是唯一路径，所以失败时用户只看到原始文本，要知道原因得翻日志
  （`~/Library/Logs/com.pais.handy/handy.log` 里的 `error` 行）。候选方案（下一阶段挑一个）：
  1. 悬浮窗加一个 error 行（对齐 OpenTypeless 的状态胶囊）——需要动 overlay 的状态与隐藏时序；
  2. 设置页加「测试连接 / 试跑」按钮——配置类问题在源头暴露；
  3. 历史记录条目上标注「润色失败」。
- **LLM 不可用时每次听写都要等一次失败**：没有纯转写模式后，网络不通 / key 失效会让每次听写都
  先发一次注定失败的请求。若实测难受，再考虑加「连续失败后短暂跳过润色」的熔断。
- 两个听写绑定做同一件事，UI 上会有两行；这是「一个工作流多快捷键」的雏形，阶段 5 会把它变成正式能力。

## 验证结果（2026-09-17）

| 命令 | 结果 |
|---|---|
| `bun run build` | 通过 |
| `bun run lint` | 通过 |
| `bun run check:translations` | 通过（25/25） |
| `cargo fmt --check` / `cargo check` | 通过 |
| `cargo test --lib` | 280 passed（新增 3 个用例） |
| 真实听写冒烟 | **未执行**，需人工按两个热键各说一句 |

实现要点：

- `ACTION_MAP` 改为由 `DICTATION_BINDINGS: [(&str, bool); 2]` 表驱动，两个条目都是 `true`；
  测试 `every_dictation_binding_post_processes` 锁死「没有纯转写模式」这条产品规则。
- `post_process_enabled` 字段、`default_post_process_enabled`、`change_post_process_enabled_setting`、
  lib.rs 注册、前端 store 映射、`PostProcessingToggle` 组件、`settings/index.ts` 导出、i18n 键全部删除。
- 老 store 里的 `post_process_enabled` 由 serde 忽略（测试 `retired_post_process_enabled_key_is_ignored`）；
  下一次 settings 写入时该键自然消失（当前实测 store 里还留着，属正常）。
- 两个热键都保留，UI 上分别叫「听写快捷键」「听写备用快捷键」。
- 设置页第一组标题从「启用与快捷键」改为「快捷键」，因为不再有开关。
- 顺手发现 `bindings.ts` 已由运行中的 `tauri dev` 自动重新生成（我之前的 `requires_api_key` /
  `resetPostProcessPrompt` 手改与生成结果一致），所以这次删命令后前端类型是同步的，只需改 store 映射。

## 变更记录

- 2026-09-17 初稿。决策：保留两个绑定（不删 `transcribe_with_post_process`）、失败反馈延后。
- 2026-09-17 T1–T5 实现完成，自动化验证全绿；冒烟待人工。
