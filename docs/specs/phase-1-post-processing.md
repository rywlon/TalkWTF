# Spec: 阶段一 — 解锁 + 重做润色 UI

状态：已实现，待人工冒烟（2026-09-17）
上游依据：`AGENTS.md` 的「阶段计划」第 1 项与「验收标准」

## 目标

让 AI 润色从「藏在 experimental 开关后面的半成品」变成一等功能：

- 入口显眼、不再自锁。
- 用户填上自己的 API key 就能润色（DeepSeek 等，BYOK 直连）。
- 用户能看清「当前用哪个 provider / 哪个模型 / 哪条提示词」，并能管理提示词。

## 现状（代码线索）

- 双层 gating（自锁）：`src/components/settings/advanced/AdvancedSettings.tsx:65` 用 `experimentalEnabled` 包住开关（`:67`）；
  `src/components/Sidebar.tsx:63` 的 `postprocessing` 段又要求 `post_process_enabled` 才显示入口。
- 后端链路已完整：`src-tauri/src/llm_client.rs`（OpenAI 兼容 `POST {base_url}/chat/completions`）、
  `src-tauri/src/settings.rs` 的 `post_process_*` 字段、`src-tauri/src/actions.rs:422` 的 `process_transcription_output`。
- Provider 表里没有 Ollama、没有 DeepSeek（只能走 `custom`）。
- `anthropic` 走的是 `/chat/completions` + 换 header，而 Anthropic 原生是 `/v1/messages` → 该选项实际不可用。
- 提示词 CRUD 已有（`post-processing/PostProcessingSettings.tsx:146`），缺恢复默认 / 复制 / 占位符说明。
- 硬编码的 provider 判断有两处：`shortcut/mod.rs:1051`（base url 只允许 `custom` 编辑）、
  `shortcut/mod.rs:1227`（非 `custom` 必须有 API key 才拉模型）。

## 范围

1. **拆 gating**：开关移出 experimental 分组；侧边栏「AI 润色」入口常显。
2. **Provider 表重做**：新增 `deepseek` 并置于首位；从默认列表移除 `anthropic`
   （已存在 store 里的条目保留不动，不主动删）。
3. **去掉硬编码**：拉模型是否要求 API key 改由 `requires_api_key` 字段决定，base url 编辑权改由
   `allow_base_url_edit` 决定，不再写死 `provider.id != "custom"`。
4. **设置页结构重做**：三段式——开关 + 快捷键 / Provider 配置 / 提示词管理；一屏看清当前选择与「待配置」状态。
5. **提示词管理增强**：恢复默认（仅内置模板）、复制、`${output}` 占位符说明与编辑预览。
6. **i18n 与文案**：en/zh 同步，文案统一为「AI 润色」。

### 涉及文件

前端
- `src/components/settings/advanced/AdvancedSettings.tsx`（移出开关）
- `src/components/Sidebar.tsx`（入口常显、标签文案）
- `src/components/settings/post-processing/PostProcessingSettings.tsx`（重写）
- `src/components/settings/post-processing/usePostProcessProviderState.ts`
- `src/components/settings/post-processing/`（`ProviderSelect.tsx` / `ModelSelect.tsx` / `ApiKeyField.tsx` / `BaseUrlField.tsx` / `types.ts` 按需复用）
- `src/components/settings/index.ts`
- `src/i18n/locales/{en,zh}/translation.json`

后端
- `src-tauri/src/settings.rs`（provider 默认表、`ensure_post_process_defaults`、默认 provider id）
- `src-tauri/src/shortcut/mod.rs`（命令语义修正 + 新命令）
- `src-tauri/src/llm_client.rs`（确认 DeepSeek reasoning 特判命中新 provider）

清理
- 删除 re-export shim：`src/components/settings/PostProcessingSettingsPrompts.tsx`、
  `src/components/settings/PostProcessingSettingsApi/index.tsx`

## 非目标

- app-aware 润色 / Scenes 管理（阶段三）
- 词典增强（阶段二）
- Apple 原生视觉重做、vibrancy、主题去粉（阶段四）——本阶段只做结构，新代码不引入粉色
- Anthropic 原生 `/v1/messages` 适配
- 「测试连接 / 试跑润色」按钮（本次决定不做，靠真实听写验证；见「已知限制」）
- 任何自建云后端、账号、遥测、代理
- 新增第三方依赖（UI 框架、HTTP 库等一律不引）
- 改动本地 ASR 运行时

## 关键设计决策

| 决策 | 取值 | 理由 |
|---|---|---|
| 侧边栏入口 | 常显 | 断掉自锁，可发现性优先 |
| 默认 provider（新装） | `deepseek` | 用户实际要用的就是 DeepSeek BYOK；`post_process_enabled` 默认 false，不会在用户没看到配置页前就触发 |
| Anthropic | 从默认列表移除，不实现 | 现有 transport 必错，不做误导性选项；旧配置条目保留 |
| 免 key provider | 新增字段 `requires_api_key: bool`（serde default = true） | 取代 `provider.id != "custom"` 硬编码，自解释且可扩展 |
| base url 编辑权 | 统一由 `allow_base_url_edit` 决定 | 去掉 `provider.id != "custom"` 硬编码 |
| Ollama | 不提供（2026-09-17 决定） | 用户不用本地模型；连带把已写进 store 的 `ollama` 条目做一次性清理（仅在未被配置过时删除） |

## 验收标准

1. `experimental_enabled = false` 时，设置里能找到并打开「AI 润色」；侧边栏入口可见。
2. 全新安装的 provider 列表含 `DeepSeek`（首位、默认选中），不含 `Anthropic`、不含 `Ollama`。
3. 已存在的 `settings_store.json` 升级后不丢已配的 key / model / prompt；`anthropic` 旧条目保留；
   未被配置过的 `ollama` 条目被清理，已配置过的保留。
4. provider 填错 key 或地址时点「刷新模型」，报错文案能区分「key 无效」与「服务连不上」。
5. 真实听写冒烟：DeepSeek BYOK 跑通一次 `transcribe_with_post_process`，产出润色后文本。
6. 提示词可新增 / 改名 / 编辑 / 删除 / 复制 / 恢复默认（仅内置模板）；最后一条不可删（保持现有约束）。
7. 设置页能一眼看出当前 provider、当前模型、当前提示词，以及是否处于「待配置」状态。
8. `bun run build`、`bun run lint`、`bun run check:translations`、`cd src-tauri && cargo check` 全过；
   `cd src-tauri && cargo test` 现有用例不回归。

## 命令

```
前端构建    bun run build
前端 lint   bun run lint
翻译检查    bun run check:translations
后端检查    cd src-tauri && cargo check
后端测试    cd src-tauri && cargo test
后端格式化  bun run format:backend
开发运行    bun run tauri dev
```

## 测试策略

- **后端（主要）**：`src-tauri/src/settings.rs` 已有 `#[cfg(test)]`。新增用例：
  - 默认 provider 表含 `deepseek`、不含 `anthropic` / `ollama`。
  - `ensure_post_process_defaults` 对已有 store 只补缺、不覆盖用户已配的 key / model / prompt。
  - `requires_api_key` 与 `allow_base_url_edit` 的默认值与迁移同步。
  - `ollama` 清理迁移：未配置则删、已配置则留。
- **前端**：本阶段不加 e2e（`tests/` 的 Playwright 保持现状）；以 `tsc` + `eslint` + 手点为准。
- **手动冒烟**：DeepSeek BYOK 一次真实听写。
- 判定标准：验收标准 1–8 全部满足，命令全绿，未通过不说「完成」。

## 任务拆分

- [x] **T1 拆 gating**
  - 验收：关掉 experimental 仍能看到并开启润色；侧边栏入口常显
  - 验证：`bun run build` + 手点
  - 文件：`AdvancedSettings.tsx`、`Sidebar.tsx`
  - 备注：开关建议落在「AI 润色」页顶部，或 General 分组；experimental 分组保持只含真正的实验项

- [x] **T2 Provider 表重做（后端）**
  - 验收：新装默认含 DeepSeek、不含 Anthropic / Ollama；老 store 不丢配置
  - 验证：`cargo test` + `cargo check`
  - 文件：`settings.rs`
  - 备注：顺序为 `deepseek` → `openai` → `zai` → `openrouter` → `groq` → `cerebras` →
    `[apple_intelligence]` → `bedrock_mantle` → `custom`；新增 `requires_api_key` 字段；
    `default_post_process_provider_id` 改为 `deepseek`；schema version 升到 3 并清理 `ollama`

- [x] **T3 去掉 provider 硬编码**
  - 验收：`requires_api_key` / `allow_base_url_edit` 真正驱动行为
  - 验证：`cargo check` + 手点
  - 文件：`shortcut/mod.rs`、`llm_client.rs`
  - 备注：改 `fetch_post_process_models` 的 key 校验与 `change_post_process_base_url_setting` 的判断；
    确认 `llm_client.rs` 对 `api.deepseek.com` 的 reasoning 特判能命中新 `deepseek` provider

- [x] **T4 设置页结构重做**
  - 验收：一屏看清开关 / 快捷键 / provider / 模型 / 提示词与「待配置」状态
  - 验证：`bun run build` + `bun run lint` + 手点
  - 文件：`PostProcessingSettings.tsx`、`usePostProcessProviderState.ts`、`settings/index.ts`，删两个 shim
  - 备注：复用现有 `ProviderSelect` / `ModelSelect` / `ApiKeyField` / `BaseUrlField`；不引入新依赖；
    不硬编码粉色，复用 `theme.css` 变量

- [x] **T5 提示词管理增强**
  - 验收：新增 / 改名 / 编辑 / 删除 / 复制 / 恢复默认可用；占位符说明与预览可见
  - 验证：`cargo check` + 手点
  - 文件：`shortcut/mod.rs`、`PostProcessingSettings.tsx`、`settings/index.ts`（`bindings.ts` 由 specta 生成）
  - 备注：新增 `reset_post_process_prompt(app, id) -> LLMPrompt`，仅内置 id 可重置，否则报错；
    复制走已有 `add_post_process_prompt`，纯前端拼「副本」名

- [~] **T6 i18n 收尾 + 全量验证 + 冒烟**
  - 验收：验收标准 7、8 满足
  - 验证：`bun run build` / `bun run lint` / `bun run check:translations` / `cargo check` / `cargo test` + 两次真实听写
  - 文件：`src/i18n/locales/{en,zh}/translation.json`
  - 备注：zh 用「AI 润色」，en 用「AI Polish」；清理不再使用的旧 key

## 已知限制（本阶段接受）

- 没有「测试连接 / 试跑润色」按钮：配置错误只能在真实听写时暴露。缓解手段是让 provider 页显示清晰的
  「待配置」状态、把错误文案做具体（区分服务未启动 / key 无效 / 网络不通）。若后续觉得痛，另开小阶段补。
- Anthropic 仍不可用（不在默认列表，但旧 store 里若已有条目仍会出现）。
- 只有 loopback 端点自动绕过代理；若把 `Custom` 指向局域网另一台机器，仍需自行设置 `NO_PROXY`。

## 边界

- **Always**：改完跑 `bun run build` + `bun run lint` + `cargo check`；新增后端逻辑补 Rust 测试；沿用现有组件与
  i18n 模式；保持 settings 向后兼容（只补缺、不覆盖用户数据）。
- **Ask first**：改动 `AppSettings` 字段语义、引入任何新依赖、改动 `settings_store.json` 的既有 key 结构。
- **Never**：提交密钥；新增云后端 / 账号 / 遥测；改动 `audio_toolkit/` 本地 ASR 运行时；为了让构建过而放宽 lint 或删测试。

## 实现记录

- `PostProcessProvider` 新增 `requires_api_key`（serde default `true`，老 store 视为需要 key）；
  `ensure_post_process_defaults` 改为同步三个 capability flag，且不碰 base_url / key / model / prompt。
- 新增命令 `reset_post_process_prompt(id) -> LLMPrompt`，只接受 `settings::built_in_post_process_prompts()`
  里的 id（当前为 `default_improve_transcriptions`），用于「恢复默认」。
- 「待配置」状态由 `usePostProcessProviderState` 计算 `missingConfig`（baseUrl / apiKey / model），
  前端映射成已有的字段标题后插入新 key `settings.postProcessing.status.incomplete`。
- 占位符预览：把 `${output}` 在草稿文本里高亮（无新增 key，用中性描边而不是品牌色）。
- 顺手修掉一个真实缺陷：`fetchPostProcessModels` 失败原本只 `console.error`，用户看不到原因；
  现在按 `toast.error("<provider>: <error>")` 抛出，服务连不上与 key 无效才能被区分。
- 又一个真实缺陷（冒烟时暴露）：`HTTP_PROXY` 环境变量会让 reqwest 把 `localhost:11434` 也丢给代理，
  本地端点因此收到 `502 Bad Gateway` 而不是「连接被拒绝」。`llm_client::create_client` 现在对
  loopback 端点（localhost / 127.x / ::1）使用 `no_proxy()`，云端 provider 仍走代理。
  （这条修复与 Ollama 无关地保留了：`Custom` 指向本地服务时同样需要。）
- Ollama 移除：`default_post_process_providers()` 不再含 `ollama`，默认 provider 改为 `deepseek`；
  `CURRENT_SETTINGS_SCHEMA_VERSION` 升到 3，新增一次性清理迁移——只在 `ollama` 未被配置过
  （无 key、无 model）时删除其 provider / key / model 条目，并把指向它的选中项改回默认。
- provider 展示顺序改由 `ensure_post_process_defaults` 每次加载同步为本 build 的顺序
  （老 store 里追加在末尾的 `deepseek` 因此归位；本 build 不再提供的 provider 保留并沉底）。
  之所以不放在 schema 迁移里：一次性迁移会被「先跑到 schema 3 的中间版本」漏掉，而顺序本身是幂等的展示状态。
- 子组件从 `settings/PostProcessingSettingsApi/` 迁到 `settings/post-processing/`，删除两个 re-export shim
  与 `settings/index.ts` 里对应的两个无用导出。
- 新增 i18n key 共 3 个（`status.incomplete`、`prompts.duplicate`、`prompts.restoreDefault`），
  已同步全部 25 个非英文 locale；另有若干 en/zh 文案值更新（侧边栏改「AI 润色」、baseUrl 说明去掉
  「仅自定义可编辑」）。
- `src/bindings.ts` 是 specta 生成物，本次手改以保持编译（新增 `requires_api_key` 与
  `resetPostProcessPrompt`），下次 debug 启动会重新生成，需确认无 diff。

## 验证结果（2026-09-17）

| 命令 | 结果 |
|---|---|
| `bun run build` | 通过 |
| `bun run lint` | 通过 |
| `bun run check:translations` | 通过（25/25） |
| `cargo check` | 通过（仅存量 warning） |
| `cargo test --lib` | 277 passed（新增 5 个用例） |
| 真实听写冒烟 | **未执行**，需人工在有麦克风的环境下完成 |
| store 迁移实测 | `~/Library/Application Support/com.pais.handy/settings_store.json` 已确认：schema 3、`ollama` 已清、`provider_id` 改为 `deepseek`、顺序归位 |

注：本机 `HTTP_PROXY/HTTPS_PROXY/ALL_PROXY` 指向 `127.0.0.1:12334`，会让 reqwest 把 localhost 请求也走代理，
导致 `managers::model::download` 的 13 个用例报 502。加 `NO_PROXY=127.0.0.1,localhost` 后全绿；
这是环境问题，与本次改动无关。

## 变更记录

- 2026-09-17 初稿；确认四项决策（入口常显 / 移除 Anthropic / 不做测试按钮 / spec 落盘 `docs/specs/`）。
- 2026-09-17 T1–T5 实现完成，自动化验证全绿；T6 待人工冒烟。
- 2026-09-17 冒烟中决定**砍掉 Ollama**（用户不使用本地模型）：默认 provider 改 `deepseek`，新增
  schema 3 清理迁移，`AGENTS.md` 同步去掉 Ollama 相关表述。
