# Spec: 阶段 6 — Apple 原生视觉重做 + Dashboard

状态：**待确认**（2026-09-17）
上游依据：`AGENTS.md`「UI 风格（Apple 原生风格）」+「阶段计划」第 6 项 + 用户新提 Dashboard 需求
参考：Typeless（Electron，已解包调研）的首页/资料库/设置信息架构

> 本阶段拆成 **6a 视觉外壳** 与 **6b Dashboard** 两步实现，先 6a 后 6b。

## 目标

1. **看起来像 macOS 原生 app**：系统字体、系统语义色、系统 accent、vibrancy（毛玻璃/液态玻璃观感）、
   克制的圆角与分隔线；**去掉粉色**。
2. **改名换标**：显示名 Handy → **TalkWTF**，logo 换成自绘声波标记（占位，后续可换）。
3. **信息架构重做**（对标 Typeless）：一级导航 **Dashboard / 资料库 / 设置**；
   设置内二级侧栏；历史 + 词典合并进资料库；AI 润色 + 翻译归入「个性化」。
4. **去掉致谢**（Acknowledgments / 捐赠 / Handy 源码链接）。
5. **Dashboard**：活动、口述时长、字数、速度、节省时间、个性化程度、服务状态、
   LLM token 用量（今日 / 近 7 天）。

## 现状（写 spec 前核过的事实）

### 主题与视觉

- 主题变量 `src/styles/theme.css`：粉色硬编码在 `:9`（`--light-color-logo-primary: #faa2ca`）、
  `:14`（`--dark-color-logo-primary: #f28cbb`）、`:26`（`--color-background-ui: #da5893`）。
- 组件大量使用 `bg-background` / `text-text` / `border-mid-gray/*` / `bg-logo-primary` /
  `text-logo-primary` / `border-logo-primary`（Tailwind 映射见 `tailwind.config` / `App.css`）。
- light/dark 由 `prefers-color-scheme` + `:root[data-theme]` 驱动（`theme.css:40-77`），
  切换逻辑 `src/lib/utils/theme.ts`、`ThemeSelector.tsx`，设置项 `theme`。
- 字体：当前未见统一的系统字体栈声明（需新增）。
- 窗口 `macOSPrivateApi: true`（`tauri.conf.json`）；`window-vibrancy` **未**依赖。
  Tauri 2 自带窗口 `effects`（`WindowEffectsConfig`），**无需新依赖**。
- 主窗口在代码里创建：`lib.rs:987-993`（`title("Handy")`、680×570、`visible(false)`）。

### 品牌 / 致谢

- `HandyTextLogo`（`src/components/icons/HandyTextLogo.tsx`）用于 `Sidebar.tsx:13,120`、
  `onboarding/Onboarding.tsx:165`、`onboarding/AccessibilityOnboarding.tsx:327`。
- `HandyHand`（`icons/HandyHand.tsx`）用作侧边栏 general 图标（`Sidebar.tsx:48`）。
- 致谢 / 捐赠 / 源码在 `settings/about/AboutSettings.tsx:32-38,56-95`
  （`handy.computer/donate`、`github.com/cjpais/Handy`、`settings.about.acknowledgments.*`）。
- `llm_client.rs:146-152` 硬编码 `github.com/cjpais/Handy` 的 REFERER / UA / `X-Title`。
- 应用图标 `src-tauri/icons/*`（含 `icon.icns` / `icon.ico` / 各尺寸 png / Windows Square*Logo）；
  托盘图标 `src-tauri/resources/tray_*.png`（8 个）。
- `tauri.conf.json`：`productName: "Handy"`、`identifier: "com.pais.handy"`。
- 文案里的 "Handy" 散落多处 i18n（如 `settings.about.version.description`）。

### 导航

- 一级侧栏 9 项：`general / history / models / advanced / postprocessing / dictionary / translation /
  debug / about`（`Sidebar.tsx:31-92`），`SECTIONS_CONFIG` 驱动渲染，`App.tsx` 用 `currentSection`
  （默认 `"general"`）选择组件（`renderSettingsContent`）。
- i18n `sidebar.*` 9 个 key。
- 资料库候选：`HistorySettings`（`components/settings/history/`）、
  `DictionarySettings`（`components/settings/dictionary/DictionarySettings.tsx`）。

### Dashboard 数据源

- history SQLite：`managers/history.rs`，表 `transcription_history`
  （`id, file_name, timestamp, saved, title, transcription_text, post_processed_text,
  post_process_prompt, post_process_requested`；迁移在 `:22-34`）。
  **没有**时长、字数、工作流（听写/翻译）字段。
- `save_entry`（`:219`）签名：`(file_name, transcription, post_process_requested,
  post_processed_text, post_process_prompt)`。
- 录音时长在管线里是已知的（`samples.len()` / 采样率，`actions.rs`），但未落库。
- LLM 用量：`llm_client.rs` 的 `ChatCompletionResponse`（`:124-136`）**只取 `choices[0].message.content`**，
  **没有捕获 `usage`**。`post_process_transcription`（`actions.rs`）拿到文本后直接返回。
- 服务状态可从 settings 直接读：`selected_model`、`active_post_process_provider()`、
  `post_process_models`、`post_process_api_keys`、`paste_method`。
- 词典规模：`DictionaryStore`（`managers/dictionary.rs`）有 words / rules。

## 6a 范围：视觉外壳

### 6a-1 主题：去粉色，改系统语义色（保留现有类名）

**策略：只改 `theme.css` 的取值与新增 token，不改组件类名**，把「去粉色」做成全局一次生效。

| token | 现在 | 改为 |
|---|---|---|
| `--color-logo-primary`（强调色） | 粉 `#faa2ca` / `#f28cbb` | **系统 accent**（见下） |
| `--color-background-ui` | 粉 `#da5893` | accent |
| `--color-logo-stroke` | 粉调 | `--color-label` |
| `--color-text` | `#0f0f0f` / `#fbfbfb` | `--color-label`（label 语义色） |
| `--color-background` | `#fbfbfb` / `#2c2b29` | 半透明材质（配 vibrancy） |

新增语义 token（Apple HIG 命名）：

```
--color-label / --color-secondary-label / --color-tertiary-label
--color-separator / --color-fill / --color-accent
```

- light/dark 各一套；`data-theme` 覆盖逻辑不变。
- **系统 accent**：新增 Rust 命令 `get_system_accent_color() -> String`（读
  `NSColor.controlAccentColor`，转 hex；非 macOS 返回空）。前端启动时写入
  `--color-accent` / `--color-logo-primary`；取不到则回退 macOS 系统蓝 `#007aff` / `#0a84ff`。
  这样强调色真正跟随系统（用户换 accent 颜色，app 跟着变）。
- 字体：`font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC",
  "Helvetica Neue", sans-serif;`（中文自动走苹方）。
- 排版/间距统一 4/8pt 栅格（组件级微调，不强制重写全部）。

### 6a-2 Vibrancy / 液态玻璃

- 主窗口用 Tauri 2 内置 `effects`：`WindowEffectsConfig { effects: [HudWindow], state:
  FollowsWindowActiveState, radius: Some(12.0) }`（在 `lib.rs:987` 的 builder 上加 `.effects(...)`）。
  macOS 生效；Windows/Linux 忽略（Tauri 会 no-op）。
- `html/body` 与 app 外壳背景改透明/半透明材质（`color-mix` 叠加），让毛玻璃透出来；
  内容卡片用不透明或低透明度材质，保证可读性。
- 悬浮窗（`recording_overlay`）已是透明窗口，**不要**给它加 effects（避免双重材质）。
- 「液态玻璃」在 WebView 内无法做真正的 Liquid Glass 折射；本阶段用
  vibrancy + 半透明材质 + 细腻阴影达到同观感，**不引入新依赖**。

### 6a-3 图标与品牌

- 新增 `src/components/icons/TalkWtfLogo.tsx`（自绘声波标记，`currentColor`，可当 app icon），
  替换 `HandyTextLogo` 的 3 处使用；`HandyHand` 从侧边栏移除（Dashboard 用 lucide `LayoutDashboard`）。
- 生成应用图标集：由一份 `icon.svg` 用 macOS 自带 `qlmanage` 光栅化 → `sips` 出各尺寸 →
  `iconutil` 出 `icon.icns`；`icon.ico` 用同一 PNG 生成（或保留占位，mac 专用影响小）。
  覆盖 `src-tauri/icons/`（含 Windows Square*Logo）。
- 托盘图标：由同一标记生成单色模板版 `tray_*.png`（idle / recording / transcribing × 明暗）。
- `lib.rs` 窗口 `title("Handy")` → `"TalkWTF"`；`tauri.conf.json` `productName` → `"TalkWTF"`。
- **`identifier` 保持 `com.pais.handy`**（数据目录不变）。将来迁移另立步骤。
- i18n 文案里的 "Handy" → "TalkWTF"（zh/en 真译；其余按现有兜底策略）。

### 6a-4 导航重构

一级（`Sidebar.tsx` 重写）：

| 一级 | 内容 |
|---|---|
| **Dashboard** | 新首页（6b） |
| **资料库**（Library） | 历史 + 词典（segmented / tabs） |
| **设置**（Settings） | 二级侧栏 |

设置二级 pane：

| pane | 来源 |
|---|---|
| 通用 | 语言、主题、开机启动、托盘、快捷键（听写/取消）、叠加层样式 |
| 个性化 | **AI 润色**（服务商/风格/场景）+ **翻译**（目标语言/快捷键） |
| 模型 | `ModelsSettings` + 加速器 |
| 声音 | 麦克风、通道、输出设备、音频反馈、静音 |
| 高级 | `AdvancedSettings`（粘贴方式、VAD、填充词等） |
| 关于 | 版本、数据目录、日志目录、What's New |
| 调试 | 仅 `debug_mode` 时显示 |

- 实现：`App.tsx` 的 `currentSection` 改成 `dashboard | library | settings` +
  `settingsPane` 状态；新增 `SettingsShell`（二级列表 + 内容区），沿用 `Sidebar` 视觉。
- 现有组件基本原样搬进对应 pane（`PostProcessingSettings` + `TranslationSettings` → 个性化；
  `GeneralSettings` 拆出声音相关到「声音」pane）。

### 6a-5 去致谢

- `AboutSettings.tsx` 删掉捐赠 / Handy 源码 / Acknowledgments 三个分组（`:32-38,56-95`）。
- 删除 i18n `settings.about.{supportDevelopment,sourceCode,acknowledgments}.*`（en + 全部 locale，
  保持 `check:translations` 绿）。
- `llm_client.rs:146-152` 的 Handy 头改为 TalkWTF（REFERER/UA/X-Title）。
- `SecureInputWarning.tsx:10` 的 `handy.computer` 帮助链接：移除链接，保留警告文案。

## 6b 范围：Dashboard

### 6b-1 数据模型

**history 迁移**（`managers/history.rs` 的 `MIGRATIONS`，追加）：

```sql
ALTER TABLE transcription_history ADD COLUMN duration_ms INTEGER NOT NULL DEFAULT 0;
ALTER TABLE transcription_history ADD COLUMN char_count  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE transcription_history ADD COLUMN workflow    TEXT    NOT NULL DEFAULT 'dictation';
```

- `workflow`：`dictation` | `translate`（由 `ProcessingMode` 决定）。
- `save_entry` 增参（时长、字数、workflow）；`HistoryEntry` 增字段（向后兼容默认值）。
- 字数口径：`char_count` = 去掉首尾空白的字符数（中文友好）；另存 `word_count` 不必要。

**LLM 用量新表**：

```sql
CREATE TABLE IF NOT EXISTS llm_usage (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp INTEGER NOT NULL,
  provider_id TEXT NOT NULL,
  model TEXT NOT NULL,
  workflow TEXT NOT NULL,
  prompt_tokens INTEGER NOT NULL DEFAULT 0,
  completion_tokens INTEGER NOT NULL DEFAULT 0,
  total_tokens INTEGER NOT NULL DEFAULT 0
);
```

- `llm_client.rs`：`ChatCompletionResponse` 增 `usage: Option<Usage>`；
  `send_chat_completion_with_schema` 返回 `(String, Option<Usage>)`；
  `post_process_transcription` 成功后调 `HistoryManager::record_llm_usage(...)`。
  无 usage 的 provider 记 0。

### 6b-2 统计命令

`get_dashboard_stats() -> DashboardStats`（新增 `commands/dashboard.rs`，纯聚合 + 可单测的纯函数）：

```
DashboardStats {
  total_recordings: u64
  total_dictation_ms: u64
  total_chars: u64
  avg_chars_per_min: f64          // = total_chars / (total_dictation_ms/60000)
  time_saved_ms: u64              // 估算，见口径
  translation_count: u64          // workflow='translate' 总数
  today: { recordings, translations, dictation_ms, chars }
  recent: Vec<RecentActivity>     // 最近 10 条：{id, timestamp, workflow, chars, preview}
  services: {
    asr_model: String             // 选中模型的显示名
    asr_ready: bool               // 模型文件存在/已加载
    llm_provider: Option<String>  // provider label
    llm_model: Option<String>
    polish_ready: bool            // provider + key + model 齐
    paste_enabled: bool           // paste_method != None
  }
  personalization: { score: u8, items: Vec<{id, done}> }  // 0-100
  tokens_today: TokenUsage        // {prompt, completion, total, requests}
  tokens_week: TokenUsage
  weekly: Vec<{date, recordings}> // 近 7 天，画迷你柱状图
}
```

**统计口径（写死并单测）**

- 总口述时间 = Σ `duration_ms`；平均速度 = `total_chars / 口述分钟`。
- 节省时间 = `max(0, total_chars / TYPING_CPS - total_dictation_ms)`，
  `TYPING_CPS = 2.0` 字符/秒（≈120 字/分，保守估计；常量 + 注释说明是估算）。
- 个性化程度（加权求和，上限 100）：
  词典词数>0 → +20；自定义场景>0 → +15；翻译目标语言>0 → +15；`learn_from_edits` 开 → +15；
  风格非默认或激活了场景 → +10；LLM 服务商配置完整 → +15；填充词移除开 → +5；
  自定义填充词非空 → +5。
- 「今日 / 近 7 天」按本地时区（`chrono::Local`）切天。
- token 今日/近 7 天按 `llm_usage.timestamp` 聚合。

### 6b-3 Dashboard UI

单页（`components/dashboard/Dashboard.tsx`），自上而下：

1. **问候 + 今日概览**：今日录音数 / 今日字数 / 今日翻译数 / 今日口述时长。
2. **指标卡**：总录音数、总口述时间、口述字数、平均速度、节省时间、翻译次数。
3. **近 7 天活动**：内联 SVG 迷你柱状图（不引图表库）。
4. **LLM token**：今日 / 近 7 天（prompt / completion / total / 请求数）。
5. **服务状态**：语音识别（模型名 + 就绪）、LLM（provider + model）、AI 润色（已配置/未配置）、
   语音输入（就绪/未就绪）、自动粘贴（开/关）。
6. **个性化程度**：环形/条形进度 + 明细清单（哪几项已完成）。
7. **最近活动**：最近 10 条（听写/翻译图标、时间、预览、字数）。

- 视觉：复用语义 token 与卡片组件；`lucide-react` 图标；纯 Tailwind + 内联 SVG，**不引图表库**。
- 空状态：无数据时给友好占位（不显示 NaN）。
- i18n：新增 key 到 26 个语言文件。

## 非目标

- **identifier 改名与数据迁移**（本阶段保留 `com.pais.handy`；将来另立步骤）。
- 真正的 macOS 26 Liquid Glass 折射（WebView 做不到；用 vibrancy + 材质近似）。
- Windows/Linux 的 vibrancy（macOS 优先，其他平台纯色回退）。
- 图表库 / 交互式图表 / 导出报表。
- 云同步统计、遥测（硬约束：统计全在本地）。
- Dashboard 的实时刷新（进入页面时拉取即可；可选加「刷新」按钮）。
- 改本地 ASR 运行时。
- 重写全部组件的排版/间距（本阶段以主题与外壳为主，组件微调随行）。

## 验收标准

**6a**

1. 全 app **无粉色**：切 light/dark、切系统 accent，强调色都跟随系统。
2. 主窗口有毛玻璃材质（macOS）；关闭 vibrancy 不可用时仍可读。
3. 侧边栏显示 TalkWTF 声波 logo；app 图标 / 托盘图标是 TalkWTF（不再是 Handy 手）。
4. 一级导航为 Dashboard / 资料库 / 设置；设置内二级侧栏可用；调试页仅 debug 时出现。
5. 资料库能切历史 / 词典；个性化里有 AI 润色 + 翻译。
6. 关于页**没有**致谢 / 捐赠 / Handy 源码链接；界面文案不再出现 "Handy"。
7. 跟随系统 light/dark，且可手动覆盖；字体为系统字体（中文苹方）。

**6b**

8. Dashboard 显示验收：总录音数、总口述时间、口述字数、平均速度、节省时间、翻译次数、
   今日概览、近 7 天、最近活动、服务状态、个性化程度。
9. token 用量：今日 / 近 7 天的 prompt/completion/total 正确；无 usage 的 provider 显示 0 不报错。
10. 老 history 库升级：加列不丢数据；新听写/翻译正确写入时长/字数/workflow。
11. 无数据时全部指标为 0 / 友好占位，不出现 NaN。
12. 统计**全部本地**，不发任何网络请求（除用户自己触发的 LLM 调用）。

**通用**

13. `cargo test --lib` / `cargo fmt --check` / `eslint` / `prettier` / `bun run build` /
    `check:translations` 全绿；真机冒烟通过。

## 任务拆分

### 6a

- [x] **A1 主题去粉 + 系统语义色 + 系统 accent**
  - 验收：`theme.css` 无粉色；`get_system_accent_color` 命令；字体栈
  - 验证：`cargo test --lib` + 手测 light/dark/accent
  - 文件：`src/styles/theme.css`、`App.css`、`shortcut/mod.rs`（或新命令）、`lib.rs`、`bindings.ts`
- [x] **A2 Vibrancy**
  - 验收：主窗口毛玻璃；透明背景不破坏可读性
  - 验证：真机（macOS）+ 其他平台编译
  - 文件：`src-tauri/src/lib.rs`、`src/styles/*`
- [x] **A3 图标 + 品牌文案**
  - 验收：`TalkWtfLogo`、app 图标集、托盘图标、`title`/`productName`、i18n 去 Handy
  - 验证：真机看 Dock/托盘/侧边栏；`check:translations`
  - 文件：`components/icons/*`、`src-tauri/icons/*`、`src-tauri/resources/tray_*`、
    `tauri.conf.json`、`lib.rs`、`i18n/locales/**`
- [x] **A4 导航重构（一级 3 项 + 设置二级侧栏 + 资料库合并）**
  - 验收：验收标准 4–5
  - 验证：手点 + `bun run build`
  - 文件：`components/Sidebar.tsx`、新 `SettingsShell`、`App.tsx`、`components/settings/index.ts`、
    `components/library/*`、`i18n/locales/**`
- [x] **A5 去致谢 + Handy 引用清理**
  - 验收：验收标准 6
  - 验证：手点 + `check:translations`
  - 文件：`AboutSettings.tsx`、`llm_client.rs`、`SecureInputWarning.tsx`、`i18n/locales/**`

### 6b

- [x] **B1 history 迁移 + save_entry 扩展**
  - 验收：`duration_ms` / `char_count` / `workflow` 落库；老库兼容
  - 验证：`cargo test --lib managers::history::`（迁移 + 写入 + 读回）
  - 文件：`managers/history.rs`、`actions.rs`（传时长/字数/workflow）
- [x] **B2 LLM usage 捕获 + 落库**
  - 验收：`llm_usage` 表；`usage` 从响应解析；无 usage 记 0
  - 验证：`cargo test --lib`（响应解析纯函数）+ 真机看 Dashboard
  - 文件：`llm_client.rs`、`managers/history.rs`、`actions.rs`
- [x] **B3 统计命令**
  - 验收：`get_dashboard_stats` 全部字段；口径单测
  - 验证：`cargo test --lib commands::dashboard::`
  - 文件：新 `commands/dashboard.rs`、`lib.rs`、`bindings.ts`
- [x] **B4 Dashboard UI + i18n**
  - 验收：验收标准 8–12
  - 验证：`bun run build` / `lint` / `check:translations` + 手测
  - 文件：`components/dashboard/*`、`i18n/locales/**`

## 已确认决策（2026-09-17）

1. 导航：**两级**（一级 Dashboard/资料库/设置；设置内二级侧栏）。
2. 分组：**个性化 = AI 润色 + 翻译**；通用/模型/声音/高级/关于 分开。
3. 「文字输入/写入」= 语音输入(ASR) 已就绪 / 自动粘贴输出 已开启。
4. 个性化程度 = **配置完成度加权分**（见口径）。
5. 改名：**本阶段只改显示名/图标，identifier 保留 `com.pais.handy`**；数据迁移将来另做。
6. 图标：先生成**简单声波**占位，之后可换。
7. 技术选型：vibrancy 用 **Tauri 2 内置 `effects`**（不加 `window-vibrancy`）；
   图表用**内联 SVG**（不加图表库）；系统 accent 用 **Rust 读 `NSColor.controlAccentColor`**。

## 已确认（补充，2026-09-17）

- 「节省时间」口径：`TYPING_CPS = 2.0` 字符/秒（≈120 字/分），常量写在代码里并标注是估算。
- 资料库：顶部 **segmented tabs**（历史 / 词典）。
- Dashboard：进入页面**自动拉取** + **手动刷新按钮**。

## 实现记录（2026-09-17）

**6a 视觉外壳**

- 主题（`src/styles/theme.css` 重写）：去掉粉色，改用 Apple 语义色；token 名保留（`--color-logo-primary`
  = 系统 accent），新增 `--color-secondary-label / tertiary-label / separator / fill / accent`。
  `App.css` 增加系统字体栈（`-apple-system` / `SF Pro` / `PingFang SC`）与新 token 的 Tailwind 映射。
- 系统 accent：新命令 `get_system_accent_color()`（`NSColor.controlAccentColor` → hex），
  前端 `syncAccentFromSystem()` 写入 `--color-accent/--color-logo-primary/--color-background-ui`。
- Vibrancy：`lib.rs` 主窗口加 `.transparent(true).effects(UnderWindowBackground)`（macOS；
  用 Tauri 2 内置 effects，未加依赖）；`:root[data-platform="macos"]` 把背景换成半透明材质。
- 品牌：新增 `TalkWtfLogo`（声波 + 字标）；生成 `src-tauri/icons/*`（`qlmanage`→`sips`→`iconutil`）
  与 `resources/tray_*.png`（单色声波）；`productName` → TalkWTF、窗口标题 → TalkWTF；
  删除 `HandyTextLogo` / `HandyHand`。
- 导航：`Sidebar` 重写为 3 个一级项（概览 / 资料库 / 设置）；新增 `SettingsNav`（设置二级侧栏）；
  新增 `Library`（历史 / 词典 tabs）与 `PersonalizationSettings`（AI 润色 / 翻译 tabs）；
  `GeneralSettings` 拆分出 `AudioSettings`；`AboutSettings` 去掉致谢/捐赠/源码。
- 去 Handy 引用：`AboutSettings` 致谢组删除；`llm_client.rs` 请求头改 TalkWTF；
  `SecureInputWarning` 去掉 handy.computer 链接；26 语言文案里 "Handy" → "TalkWTF"；
  **更新检查强制关闭**（`update_checks_forced_disabled() == true`，个人使用无更新通道）。

**6b Dashboard**

- history 迁移：加 `duration_ms` / `char_count` / `workflow` 三列 + `llm_usage` 表；
  `save_entry` 增参；`HistoryEntry` 增字段。启动时幂等回填旧数据（字数从文本、时长从 WAV）。
- token 捕获：`llm_client` 的 `ChatCompletionResponse` 解析 `usage`，
  `send_chat_completion_with_schema` 返回 `LlmCompletion { content, usage }`；
  `actions.rs` 成功后 `record_llm_usage`。
- 统计命令 `commands/dashboard.rs::get_dashboard_stats`：总录音/总时长/字数/平均速度/节省时间/
  翻译次数、今日、近 7 天、最近 10 条活动、服务状态（ASR/LLM/润色/语音输入/文字写入）、
  个性化程度（8 项加权，满分 100）、token 今日/近 7 天。口径为纯函数 + 5 个单测。
- UI `components/dashboard/Dashboard.tsx`：指标卡、内联 SVG 柱状图、token、服务状态、
  个性化进度 + 清单、最近活动；进入自动拉取 + 刷新按钮；空数据友好占位。

**踩坑记录**

- rusqlite_migration 用 `user_version` 计数追踪迁移：**在数组中间插入迁移会让部分库
  的 `user_version` 越过该槽位而不执行它**，删掉后又触发 `DatabaseTooFarAhead` 崩溃。
  处理：把回填迁移固定为第 9 个（补回数组长度），同时用 Rust 里幂等回填兜底；
  并注明「迁移只能追加在末尾」。
- 旧历史记录的时长/字数靠回填补齐（WAV 已被保留策略删除的条目时长仍为 0）。

**验证**：`cargo test --lib` 366 passed；`cargo fmt --check` / `eslint` / `prettier` /
`bun run build` / `check:translations` 全绿；真机截图确认新视觉、导航与 Dashboard 数据。
