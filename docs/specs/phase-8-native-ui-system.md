# Spec: 阶段 8 — 原生 macOS UI 体系（架构学 Typeless，视觉学 Spokenly）

状态：**待确认**（2026-09-17）
上游依据：`AGENTS.md`「UI 风格（Apple 原生风格）」+ 用户 2026-09-17 反馈
参考：
- **架构**：Typeless（概览 / 资料库 / 设置；已实现，本阶段只微调）
- **视觉**：**Spokenly**（原生 SwiftUI app，已在本机运行并截图研究）
- **技术**：macOS 27 + `NSGlassEffectView`（真 Liquid Glass，已接入）

## 用户反馈（本阶段要解决的）

1. **悬浮窗**：白色背景下灰扑扑的胶囊很脏；看起来像"网页卡片"而不是原生控件。
   > 「这个卡片应该要一个原生窗口才行，不要卡片了」
2. **整体太"小气"**：窗口小、留白少、字号小、卡片小，不够大方。
3. **控件要像苹果**：设置里的开关/按钮/分段控件等要有 macOS 原生观感。
4. **架构学 Typeless，视觉学 Spokenly。**

## Spokenly 实测观察（截图研究，本机 1060×698 窗口）

| 维度 | Spokenly 的做法 |
|---|---|
| 窗口 | **大**：约 1060×698；内容区宽松，两侧留白充足 |
| 侧栏 | ~200px，SF Symbols 图标 + 14px 标签；选中项 = **accent 淡色圆角块**；顶部 logo + 名称；底部分隔 + 次要操作 |
| 标题 | 大标题 ~28px semibold + 13px 灰色副标题，左对齐 |
| 分段/筛选 | **胶囊分段控件**：容器浅灰圆角，选中项白底 + 阴影 + accent 文字，带 SF Symbol |
| 搜索框 | 原生搜索框：圆角 10、放大镜、浅灰填充、无重边框 |
| 排序 | 原生 **pop-up button**：圆角、右侧 `chevron.up.chevron.down` |
| 列表 | 大圆角容器，行 = 标题（semibold）+ 正文 + 灰色元数据（`听写 · 1小时前 · 3秒钟`），整宽细分隔线 |
| 留白 | 区块间距 20–28px，行内边距 12–16px |
| 字体 | 系统字体，层级清晰（28 / 17 / 15 / 13 / 11） |
| 颜色 | 系统蓝 accent、系统灰、hairline 分隔，几乎无阴影 |

## 现状（写 spec 前核过的事实）

- 主窗口 **680×570**，`min_inner_size` 同值：`src-tauri/src/lib.rs`（`inner_size(680.0, 570.0)`）。
- 侧栏 `w-44`（176px）：`src/components/Sidebar.tsx`；二级导航 `w-40`：`SettingsNav.tsx`。
- 内容区 `max-w-3xl`（768px）+ `p-4`：各设置页与 `App.tsx`。
- 基础字号 `15px` / 行高 24px：`src/App.css`（`:root`）。
- 控件现状：
  - `ToggleSwitch` 44×24（`w-11 h-6`），自绘，非 HIG 尺寸（macOS 常规 51×31）。
  - `Button` 圆角 `rounded-lg`、蓝底/灰底（`ui/Button.tsx`）。
  - `Select` 用 `react-select` 定制（`ui/Select.tsx`），非原生 pop-up 观感。
  - `SettingsGroup` = 卡片 + `divide-y` 行；`SettingContainer` 行内边距偏小。
- 悬浮窗：`NSPanel` + `NSGlassEffectView`（radius 跟随状态），但卡片有 **58% 不透明填充 + 边框 + 投影**
  （`src/overlay/RecordingOverlay.css` 的 `--s-surface` 与 `.scard`），在浅色背景上呈现"灰卡"。
- Dashboard 卡片 `rounded-xl p-4`、字号偏小：`components/dashboard/Dashboard.tsx`。

## 目标

1. **悬浮窗**：去掉"网页卡片"观感，做成**原生 glass HUD**——玻璃即表面，无实色填充，
   在任何背景（白/彩/深）上都干净、通透、有层次；尺寸更从容、排版更清晰。
2. **整体大方**：窗口变大、留白变多、字号层级更清晰、卡片更舒展。
3. **控件原生**：开关 / 按钮 / 分段控件 / 下拉 / 输入框 / 搜索框 全部对齐 HIG 观感与尺寸。
4. **架构保持** Typeless 式（概览 / 资料库 / 设置），只做视觉与间距升级。

## 范围

### 8a 设计系统（token 化，改一处全局生效）

新增/替换 `src/styles/theme.css` + `App.css` 的排版与尺寸 token：

| 类别 | token | 值（pt） |
|---|---|---|
| 字号 | `--fs-large-title` | 26（semibold） |
| | `--fs-title` | 20（semibold） |
| | `--fs-headline` | 15（semibold） |
| | `--fs-body` | 14 |
| | `--fs-callout` | 13 |
| | `--fs-caption` | 11 |
| 行高 | `--lh-body` | 1.45 |
| 圆角 | `--radius-card` | 12 |
| | `--radius-control` | 8 |
| | `--radius-field` | 8 |
| 间距 | 4/8 栅格；区块间距 24；行内边距 12×14 | |
| 控件尺寸 | switch 51×31；按钮高 28；输入框高 30；分段高 28 | |

- 通过 Tailwind 的 `@theme` 暴露为 `text-body` / `rounded-card` 等工具类。
- 现有 `text-sm`/`rounded-lg` 等用法逐步迁移，不强制一次改完。

### 8b 窗口与外壳

- 主窗口 **1000×700**，`min_inner_size` **880×600**（`lib.rs`）。
- 侧栏 `w-56`（224px）；二级导航 `w-48`（192px）；侧栏项高度 30、字号 14、图标 18。
- 内容区：去掉 `max-w-3xl` 的硬限制，改为 `max-w-[880px]` + `px-7 py-6`；
  标题区独立（大标题 + 副标题），列表区独立滚动。
- `Sidebar`：选中项用 accent 淡色圆角块（已有雏形，统一 radius 8 / 高度 30 / 图标 18）。
- 去掉窗口内不必要的硬边框，改用 hairline `--color-separator`。

### 8c 原生控件（观感对齐 HIG）

| 控件 | 目标 |
|---|---|
| `ToggleSwitch` | 51×31；关闭=系统灰填充；开启=accent 填充；白色圆钮 + 细阴影；键盘焦点环 |
| `Button` | primary=accent 实心、radius 8、高 28、14px medium；secondary=浅灰填充 + hairline 边；destructive=红字；hover 提亮 6% |
| **SegmentedControl（新）** | 胶囊容器（浅灰）+ 选中白底 pill + 阴影 + accent 文字；用于 资料库（历史/词典）与 个性化（润色/翻译） |
| `Select` | 改成原生 pop-up 观感：圆角 8、hairline 边、右侧 `chevron.up.chevron.down`，点开用原生风格菜单 |
| `Input` / `Textarea` | radius 8、内嵌阴影、hairline 边、focus 用 accent 环 |
| **SearchField（新）** | 圆角 10、浅灰填充、放大镜图标、无重边框（资料库历史页用） |
| `SettingsGroup` / `SettingContainer` | 卡片 radius 12、行内边距 12×14、行高 44+、分隔线 hairline、标题 13 灰 |

### 8d 悬浮窗（native glass HUD）——本阶段重点

**问题**：卡片有 58% 实色填充 + 边框 + 投影 → 在浅色背景上是"灰卡"，不是原生控件。

**方案**：**玻璃即表面**。

- **macOS**：`.scard` 背景 **完全透明**（`background: transparent`），去掉边框；
  表面完全交给 `NSGlassEffectView`；只保留极轻的镜面高光（`.scard` 的内阴影改为
  仅顶部 0.5px 白色高光，去掉外投影）。文字用系统语义色（label / secondaryLabel）。
- **非 macOS**：保留实色/半透明表面（无玻璃时透明会看不见）。
  → 用 `:root[data-platform="macos"]` 覆盖，默认仍是实色。
- **尺寸更从容**：录音 220×44、处理中 240×44、流式 420×140、提示卡 440×80；
  玻璃圆角 = 高度/2（胶囊）/ 16（卡片）。
- **排版**：标签 13px medium，计时/元数据 12px 次要色；图标 18。
- **状态内容**：
  - 录音：波形 + 计时 + 取消（保持）
  - 翻译：波形 + 「翻译为 X」+ 取消
  - 处理中：spinner + 「转写中 / 润色中 / 翻译中」
  - 失败/提示：一行文字 + 按钮（重试），无实色卡片
- **动效**：淡入淡出 + 尺寸变化（窗口 resize），不做缩放（避免露出玻璃）。

### 8e 资料库 / 历史行

- 顶部 **SearchField** + **排序 pop-up**（最新在前 / 最早在前）。
- 历史行：主行（润色后文本，semibold）+ 次行（原始转写，灰色）+ 元数据
  （`听写/翻译 · 相对时间 · 时长`），整宽 hairline 分隔，行高 ~64。
- 词典页：行 + 内联操作按钮对齐新控件。

### 8f Dashboard 排版升级

- 指标卡：`radius 12`、padding 16–20、数值 28 semibold、标签 13 灰、图标 16。
- 区块标题 13 灰大写（已有），区块间距 28。
- 柱状图放大（高度 72）、服务状态行高 40、个性化清单行高 28。

## 非目标

- **不引入新 UI 框架 / 组件库**（继续 Tailwind + 现有组件）。
- **不嵌入真正的 AppKit 控件**（webview 限制）：用 CSS 精确对齐 HIG 观感，而非真控件。
- **不用 SF Symbols 字体**（不可再分发）：继续用 `lucide-react` 近似；必要处自绘 SVG。
- 不改后端 / ASR / 翻译 / 词典逻辑（纯 UI）。
- 不做 Windows/Linux 的玻璃（保持实色回退）。
- 不做窗口尺寸的响应式断点系统（个人自用，固定大窗口）。

## 验收标准

1. 悬浮窗在**白色**、彩色、深色背景上都干净通透；**看不出"卡片"边界**（只有玻璃与内容）。
2. 主窗口默认 1000×700；内容区留白明显变宽；大标题 + 副标题层级清晰。
3. 开关/按钮/分段/下拉/输入框观感与尺寸对齐 HIG（开关 51×31、按钮高 28 等）。
4. 资料库有搜索框与排序控件；历史行显示原文 + 润色 + 元数据。
5. Dashboard 卡片与字号明显更舒展，无 11px 以下正文。
6. 深浅色、系统 accent 全部正确；无粉色残留。
7. `cargo test --lib` / `cargo fmt --check` / `eslint` / `prettier` / `bun run build` /
   `check:translations` 全绿；真机冒烟通过。

## 任务拆分

- [x] **U1 设计系统 token**（字号/行高/圆角/间距/控件尺寸 + Tailwind 映射）
- [x] **U2 窗口与外壳**（窗口尺寸、侧栏宽度、内容区留白、大标题）
- [x] **U3 原生控件**（Switch / Button / SegmentedControl / Dropdown / Select / SearchField /
      SettingsGroup 行）
- [x] **U4 悬浮窗重做**（玻璃即表面、尺寸、排版、各状态、圆角矩形）
- [x] **U5 资料库**（搜索 / 排序 / 历史行两行 + 元数据）
- [x] **U6 Dashboard 排版升级**
- [x] **U7 i18n + 全量验证 + 真机冒烟**（真机冒烟待用户确认）

## 第二轮修正（用户 2026-09-17 反馈：下拉框半透明、按钮太大、没对齐）

- **弹出层不透明 token**：新增 `--color-popover`（light `#f5f5f7` / dark `#2a2a2c`）。
  `Dropdown` 与 `Select` 的菜单从 `bg-background`（macOS 上是半透明材质，导致"能看见后面内容"）
  改为 `bg-popover`，加 `rounded-[10px]` + 阴影。
- **原生弹出按钮**：`Dropdown` 触发器 `min-w-[200px]` + 重边框 → `h-7 min-w-[150px]`
  + hairline 边 + 浅填充 + **双箭头 `chevron.up.chevron.down`**（不再旋转单箭头）；
  `Select` 控件 `minHeight 40 → 28`、圆角 8、去重边框、`DropdownIndicator` 换成双箭头。
- **快捷键 chip**：`GlobalShortcutInput` / `HandyKeysShortcutInput` 的按键框改成
  `h-7 rounded-control border-separator bg-fill` 的原生弹出按钮观感。
- **悬浮窗圆角矩形**：胶囊（radius 26 = 高度/2）→ **圆角矩形 radius 14**
  （`overlay.rs::overlay_glass_radius` 与 CSS 同步）。
- **U5 资料库**：
  - 新增 `ui/SearchField.tsx`（原生搜索框：圆角 10、浅填充、放大镜）。
  - 历史页顶部：SearchField + 排序 `Dropdown`（最新/最早）+ 打开文件夹。
  - 历史行改成 Spokenly 式三行：润色文本（`text-body`）→ 原始转写（`text-callout` 次要色）→
    元数据（`听写/翻译 · 相对时间 · 时长`，`text-caption`）；操作图标移到右上；音频播放器在下。
  - 新增 `formatRelativeTime`（`Intl.RelativeTimeFormat`）与 `formatDurationShort`。
  - 空结果状态 `settings.history.noMatches`；搜索为**已加载条目**的前端过滤（本地库很小，
    `history_limit` 默认 5）。

## 实现记录（2026-09-17，U1–U4 + U6）

- **U1**：`App.css` 新增 `@theme` 设计 token（`--text-caption/callout/body/headline/title/large-title`、
  `--radius-control/card`）；根字号 `15px → 16px`，让 Tailwind 的 rem 间距落到标准 4/8 栅格。
- **U2**：主窗口 **1000×700 / 最小 880×600**（`lib.rs`）；侧栏 `w-44 → w-56`、二级导航 `w-40 → w-48`；
  内容区 `max-w-3xl → max-w-[880px]`、`p-4 → px-7 py-6`；侧栏项高度 34 / 图标 18 / `text-body`。
- **U3**：`ToggleSwitch` 改 51×31（27pt 圆钮 + 阴影）；`Button` 高 28 / `rounded-control`；
  新增 `ui/SegmentedControl.tsx` 并用于资料库与个性化；`SettingsGroup` 圆角 12 + `text-callout` 标题；
  `SettingContainer` 行内边距 12、`text-body` 标题 + `text-callout` 描述。
- **U4**：`overlay.rs` 尺寸 **260×52 / 280×52 / 440×150 / 460×84**，玻璃圆角跟随（胶囊 26 / 卡片 16）；
  `RecordingOverlay.css` 在 macOS 下 `.scard` **背景透明、无边框、无投影**，只留 0.5px 顶部高光
  （玻璃即表面）；取消按钮改用 label 派生色，在玻璃上清晰可见；`--ov-base-h: 52px`。
  悬浮窗 webview 也设置 `data-platform`。
- **U6**：Dashboard 大标题 `text-large-title`、区块标题 `text-callout`、卡片 `rounded-card p-5`、数值 28px。

**验证**：`cargo test --lib` 366 passed；`cargo fmt --check` / `eslint` / `prettier` /
`bun run build` / `check:translations` 全绿；真机截图确认窗口变大、悬浮窗单层玻璃。

**待办**：U5（资料库搜索 / 排序 / 历史行两行 + 元数据）、Select/Input 的原生观感、真机冒烟。

## 已确认（2026-09-17）

1. 窗口 **1000×700**，最小 **880×600**。
2. 悬浮窗：**录音 260×52 / 处理 280×52**（流式与提示卡按比例放大：**440×150 / 460×84**）。
3. 悬浮窗：**玻璃即表面**（macOS 卡片背景完全透明、去边框投影；非 macOS 回退实色）。
4. 基础字号：**正文 14 / 次要 13 / 说明 11**。
5. 实现顺序：**U1→U2→U3**（外壳与控件，肉眼可验收）→ **U4**（悬浮窗）→ **U5/U6**（内容页）。
