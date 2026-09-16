# AGENTS.md

## 这个项目是什么

**TalkWTF** —— 个人自用的桌面语音听写 app。以 Handy 为底座，移植 OpenTypeless 的「AI 润色 + 词典」UX，并重做 UI。

不分发、不上架，不需要签名/公证/自动更新基建。

## 技术栈

- 前端：Tauri 2 + React + TypeScript + Tailwind 4 + Zustand
- 后端：Rust（本地 ASR、LLM 调用、系统集成）
- 包管理：bun（沿用 Handy 的 bun.lock）

## 两个仓库

- 底座（保留）：https://github.com/cjpais/Handy （MIT）
- 功能来源（只搬逻辑/UX，不搬云）：https://github.com/tover0314-w/opentypeless （MIT）

## 硬约束（不可违反）

- **禁止的是"我们自己的云"**：不实现任何自建云后端、账号/登录、订阅/配额、遥测/analytics、
  数据中转代理（即 OpenTypeless 的 `/api/proxy/*`、`/api/backup`、账号体系那一套）。
- **允许 BYOK（Bring Your Own Key）**：用户在设置里填自己的 API key，直连 provider。
  例如 AI 润色接 **DeepSeek API 是允许的**——用户自己的 key、直连 DeepSeek，不经过我们。
  同理允许 OpenAI / Anthropic / OpenRouter / Groq 等，也允许本地 Ollama。
- **本地优先**：默认走本地（Ollama 做润色、本地 ASR），云端 provider 由用户自行选择。
- 除用户显式配置的 provider 外，App 自身不联网。
- 个人使用：不做签名、公证、自动更新。
- 保留 MIT 许可声明；改名为自己的名字、换 logo（商标不在 MIT 内）。
- 隐私优先：不记录、不上报用户数据。

## 策略（重要，别搞错方向）

- 不要"合并两个代码库"。以 Handy 为唯一底座，从 OpenTypeless 移植逻辑/UX。
- 理由：Handy 的本地 ASR 运行时是难复制、必须保留的部分；OpenTypeless 的润色+词典是相对简单、可移植的部分。
- 绝对不要反过来把 Handy 的本地模型塞进 OpenTypeless。
- 两边技术栈几乎相同，UI 代码可大量直接搬运。

## 已知代码线索

### Handy（底座，保留）

- 本地 ASR 运行时：src-tauri/src/audio_toolkit/
- 模型目录/校验：src-tauri/src/catalog/
- 润色后端（已存在）：src-tauri/src/llm_client.rs；settings 的 post_process_* 字段
- 词典后端（已存在）：settings 的 custom_words；src-tauri/src/audio_toolkit/text.rs 的 apply_custom_words
- 润色 UI：src/components/settings/post-processing/、src/components/settings/PostProcessingToggle.tsx
- 词典 UI：src/components/settings/CustomWords.tsx
- 隐藏开关（要拆掉）：src/components/settings/advanced/AdvancedSettings.tsx:65 的
  `{experimentalEnabled && (...)}` 把润色藏在了 experimental 开关后面
- 粉色主题色：src/styles/theme.css:9 (#faa2ca)、:14 (#f28cbb)
- 主题：src/lib/utils/theme.ts、src/components/settings/ThemeSelector.tsx
- 设置存储：src-tauri/src/settings.rs（settings_store.json）

### OpenTypeless（只搬这些，别搬云）

- app-aware 润色：src-tauri/src/llm/context_policy.rs、src-tauri/src/llm/prompt.rs、src-tauri/src/app_detector/
- 场景/提示词管理：src/components/Settings 里的 Scenes 相关
- 词典：src-tauri/src/storage/mod.rs（SQLite 的 dictionary + correction_rules 表）、
  src-tauri/src/dictionary_io.rs、src/components/Settings 里的 DictionaryPane
- 禁止搬（全是云/账号）：src-tauri/src/llm/cloud.rs、src-tauri/src/stt/cloud.rs、
  src/lib/api.ts、authStore、AccountPage、UpgradePage

## 工作流

- 先 spec 再代码：每个阶段先产出 目标 / 范围 / 非目标 / 验收标准 / 任务拆分，确认后再实现。
- 小步改动，可验证；每个阶段结束要能跑起来。
- 完成前必须验证（跑构建/测试），未通过不许说"完成"。

## UI 风格（Apple 原生风格）

目标：看起来像 macOS 原生 app，遵循 Apple Human Interface Guidelines (HIG)。

- **字体**：系统字体栈（`-apple-system` / SF Pro）；中文用苹方（PingFang SC）。不引入第三方字体。
- **颜色**：用系统语义色（label / secondaryLabel / tertiaryLabel / separator / systemBlue 等），
  强调色用系统 accent。**不要硬编码品牌色**（尤其去掉粉色 #faa2ca / #f28cbb）。
- **主题**：跟随系统 light/dark，并允许手动覆盖（system / light / dark）。
- **材质与层次**：窗口用 vibrancy / 毛玻璃（Handy 已开 `macOSPrivateApi`，可用 `window-vibrancy` 这个 Rust crate）；
  圆角、阴影、分隔线保持系统级克制。
- **控件**：优先原生观感——sidebar、toolbar、segmented control、switch、list、inspector。
  不要自造花哨控件。
- **排版/间距**：统一 4/8pt 栅格，层级清晰，留白充足。
- **布局**：macOS 上用 sidebar + 内容区（NavigationSplitView 式），设置页分组式。
- **交互**：键盘快捷键、右键菜单、拖放等原生行为。
- **动效**：细腻、克制、短时长；尊重「减少动态效果」偏好。

实现：Tailwind + 系统字体 + CSS 变量即可，不引入新 UI 框架。
现有主题变量在 `src/styles/theme.css`，组件在 `src/components/`。

## 阶段计划

1. 解锁 + 重做润色 UI：拆掉 experimental gating，做好用的 provider/prompt 界面，接本地 Ollama
2. 词典增强：增删改、导入导出、纠正规则、per-app 映射
3. app-aware 润色：按前台 app 调语气/格式
4. 视觉重做：改成 Apple 原生风格（见「UI 风格」一节），去掉粉色，统一 UI，light/dark

## 验收标准（Definition of Done）

- 无自建云后端、无账号、无遥测
- AI 润色支持 BYOK（DeepSeek 等云端 provider）与本地 Ollama
- 本地 ASR 可用（Qwen3-ASR 0.6B，中文）
- 润色：UI 显眼、可接 Ollama、有提示词/场景管理
- 词典：可增删改、导入导出、纠正规则
- UI：Apple 原生风格、无粉色、跟随系统 light/dark、可读
- 构建通过、测试通过

## 环境

- Mac，16GB 内存
- 主要语言：中文（含中英混说）

## 不要做

- 不要加任何云端/账号/订阅/遥测
- 不要改动 Handy 的本地 ASR 运行时（除非必要且已说明理由）
- 不要引入新的重型依赖或新 UI 框架
- 不要为了"能跑"而跳过验证
