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
  同理允许 OpenAI / Anthropic / OpenRouter / Groq 等；若想指向本地或自建的 OpenAI 兼容服务，
  用 `Custom` provider 自己填地址即可（不预置、不推荐、不保证）。
- **本地优先**：本地 ASR 默认可用且不联网。润色默认不联网——只有用户在设置里显式选好 provider
  并填好 key 之后才会发出请求。
- 除用户显式配置的 provider 外，App 自身不联网。
- 个人使用：不做签名、公证、自动更新。
- 保留 MIT 许可声明；改名为自己的名字、换 logo（商标不在 MIT 内）。
- 隐私优先：不记录、不上报用户数据。

## 策略（重要，别搞错方向）

- 不要"合并两个代码库"。以 Handy 为唯一底座，从 OpenTypeless 移植逻辑/UX。
- 理由：Handy 的本地 ASR 运行时是难复制、必须保留的部分；OpenTypeless 的润色+词典是相对简单、可移植的部分。
- 绝对不要反过来把 Handy 的本地模型塞进 OpenTypeless。
- 两边技术栈几乎相同，UI 代码可大量直接搬运。
- **目标是功能对齐 OpenTypeless（除云/账号），结构保持 Handy**。凡是 OpenTypeless 有的能力，
  默认都要有；差异只在实现底座（本地 ASR 用 Handy 的 transcribe.cpp + Qwen3-ASR）和「无自建云」这条硬约束。
- **交互模型对齐 OpenTypeless**：听写是「转录 + 润色」一个动作，没有"纯转写模式"；
  不同用途用不同工作流热键（听写 / Ask / 翻译），每个工作流可绑多个快捷键。
- 润色不是让用户手写 prompt，而是「润色风格 + 场景」；prompt 文本属于高级用法。

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

> 总原则：结构照 Handy，功能照 OpenTypeless（去掉云/账号）。下面是功能对齐的推进顺序。

1. 解锁 + 重做润色 UI：拆掉 experimental gating，做好用的 provider/prompt 界面，接通 BYOK（DeepSeek 等）— 已完成
1.5 取消纯转写模式：所有听写热键默认走后处理（`transcribe` 也润色），移除 `post_process_enabled` 开关 — 已完成
2. 润色风格 + 场景：内置/自定义场景、导入导出、激活状态；用户选风格而不是手写 prompt
   — 2a（风格 + 场景 + 提示词组装）已完成；2b（导入导出）未开始
3. 词典增强：增删改、导入导出、纠正规则（本地 SQLite）— 已完成
3.5 自动学词：听写后读取刚输入的输入框，把你改掉的错词学进词典（先加 + 撤销，对标 Typeless）
   — 已完成（待真机冒烟）
4. ~~app-aware 润色~~ **已否决**（2026-09-17）：有价值的部分是窗口标题/浏览器 URL 那类上下文，
   隐私约束下不发，剩下粗粒度分类收益太低。spec 保留在 docs/specs/phase-2b-and-phase-4.md 作记录。
2b. 润色风格 + 场景的导入导出（阶段 2 剩下的部分）— 已完成（2026-09-17）
5. ~~多工作流热键：Ask Anything、翻译选中文本；每个工作流可绑多个快捷键~~ **已收缩**（2026-09-17）：
   不做多快捷键框架、不做 Ask Anything、不做选中文本翻译。spec 作废记录在
   `docs/specs/phase-5-multi-workflow-shortcuts.md`。
7. 自动翻译：独立 Translate 工作流（单个自绑热键）→ 语音 → 本地转写 → BYOK LLM 翻译成目标语言 →
   粘贴；目标语言最多 3 个、设置里切换当前目标；悬浮窗显示「翻译为 X」；失败不粘贴 + 悬浮窗重试
   — 已实现（2026-09-17，待真机冒烟）。spec：`docs/specs/phase-7-auto-translate.md`。
6. 视觉重做：改成 Apple 原生风格（见「UI 风格」一节），去掉粉色，统一 UI，light/dark —
   **已完成**（2026-09-17）：去粉 + 系统语义色 + 系统 accent、Tauri 内置 vibrancy、
   TalkWTF 图标/产品名、两级导航（概览 / 资料库 / 设置）、去致谢、强制关闭更新检查。
   spec：`docs/specs/phase-6-native-visual-redesign.md`。
6b. Dashboard：活动/时长/字数/速度/节省时间/个性化程度/服务状态/LLM token（今日 + 近 7 天）
   — **已完成**（2026-09-17，同 spec 的 6b 部分；history 加 duration_ms/char_count/workflow 列 +
   llm_usage 表；旧数据启动时幂等回填）。

## 验收标准（Definition of Done）

- 无自建云后端、无账号、无遥测
- AI 润色支持 BYOK（DeepSeek 等云端 provider）
- 本地 ASR 可用（Qwen3-ASR 0.6B，中文）
- 听写 = 转录 + 润色，没有纯转写模式；润色失败自动降级为原始转写，且用户能知道失败原因
- 润色：UI 显眼、可接 DeepSeek 等 BYOK provider、有场景/风格与提示词管理
- 词典：可增删改、导入导出、纠正规则
- 自动翻译：独立 Translate 工作流（单个自绑热键）→ 语音 → 本地转写 → BYOK LLM → 粘贴译文；
  目标语言最多 3 个、设置里切换；未配语言给提示；失败不粘贴 + 悬浮窗重试
  （原「多工作流热键 / Ask / 翻译选中文本」已按 2026-09-17 决定收缩，见阶段计划）
- UI：Apple 原生风格、无粉色、跟随系统 light/dark、可读；导航为 概览 / 资料库 / 设置
- Dashboard：活动/时长/字数/速度/节省时间/个性化程度/服务状态/LLM token（今日 + 近 7 天），
  全部本地统计、无遥测
- 构建通过、测试通过

## 环境

- Mac，16GB 内存
- 主要语言：中文（含中英混说）

## 不要做

- 不要加任何云端/账号/订阅/遥测
- 不要改动 Handy 的本地 ASR 运行时（除非必要且已说明理由）
- 不要引入新的重型依赖或新 UI 框架
- 不要为了"能跑"而跳过验证
