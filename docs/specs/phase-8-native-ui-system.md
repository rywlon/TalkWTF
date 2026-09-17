# Spec: 原生 macOS UI 体系（架构学 Typeless，视觉学 Spokenly）

状态：**已完成**（2026-09-17 改写为 SwiftUI 版并落地 S1–S7）
上游依据：`AGENTS.md`「UI 风格（Apple 原生风格）」
参考：
- **架构**：Typeless（概览 / 资料库 / 设置）
- **视觉**：Spokenly（原生 SwiftUI app，已在本机运行并截图研究）
- **技术**：SwiftUI + macOS 26 `glassEffect`（真 Liquid Glass）

> **历史说明**：本 spec 最初写于 Tauri/React 时代，当时的 token 是 CSS 变量 + Tailwind。
> 那些代码已随 `src/` 删除（阶段 9 P5）。**设计决策不变，落地方式改为 SwiftUI**。
> 本文档现在是 UI 的单一事实来源：SwiftUI 里的 `Theme.swift` 与之对应。

## 用户反馈（要解决的）

1. **悬浮窗**：白色背景下灰扑扑的胶囊很脏；像"网页卡片"而不是原生控件。
2. **整体太"小气"**：窗口小、留白少、字号小、卡片小。
3. **控件要像苹果**：开关/按钮/分段/下拉要有 macOS 原生观感。
4. **架构学 Typeless，视觉学 Spokenly。**

## Spokenly 实测观察（本机 1060×698 窗口）

| 维度 | 做法 |
|---|---|
| 窗口 | **大**：约 1060×698；内容区宽松，两侧留白充足 |
| 侧栏 | ~200px，SF Symbols + 14px 标签；选中项 = accent 淡色圆角块；顶部 logo，底部次要操作 |
| 标题 | 大标题 ~28px semibold + 13px 灰色副标题，左对齐 |
| 分段/筛选 | 胶囊分段：容器浅灰圆角，选中项白底 + 阴影 + accent 文字 |
| 搜索框 | 原生搜索框：圆角 10、放大镜、浅灰填充、无重边框 |
| 排序 | 原生 pop-up button：圆角、右侧 `chevron.up.chevron.down` |
| 列表 | 大圆角容器，行 = 标题（semibold）+ 正文 + 灰色元数据，整宽细分隔线 |
| 留白 | 区块间距 20–28px，行内边距 12–16px |
| 字体 | 系统字体，层级清晰（28 / 17 / 15 / 13 / 11） |
| 颜色 | 系统 accent、系统灰、hairline 分隔，几乎无阴影 |

## 设计 token（唯一事实来源）

SwiftUI 实现在 `macos/TalkWTF/Theme.swift`。所有视图从这里取值，不再散落魔法数字。

### 字号

| token | 值 | 用途 |
|---|---|---|
| `Font.largeTitle` | 26 semibold | 页面标题 |
| `Font.title` | 20 semibold | 区块标题 |
| `Font.headline` | 15 semibold | 行标题 |
| `Font.body` | 14 | 正文 |
| `Font.callout` | 13 | 次要文字、控件标签 |
| `Font.caption` | 11 | 元数据、说明 |

### 间距 / 圆角 / 尺寸

| 类别 | token | 值（pt） |
|---|---|---|
| 栅格 | `Spacing.unit` | 4（所有间距取 4 的倍数） |
| 区块间距 | `Spacing.section` | 24 |
| 行内边距 | `Spacing.row` | 12×14 |
| 内容区 | `Layout.contentMaxWidth` | 880 |
| | `Layout.contentPadding` | 28 / 24 |
| 窗口 | `Layout.windowSize` | 1000×700 |
| | `Layout.windowMinSize` | 880×600 |
| 侧栏 | `Layout.sidebarWidth` | 224（设置二级 192） |
| | `Layout.sidebarRowHeight` | 30 |
| 圆角 | `Radius.card` | 12 |
| | `Radius.control` | 8 |
| | `Radius.field` | 8 |
| 控件 | `Control.buttonHeight` | 28 |
| | `Control.fieldHeight` | 30 |
| | `Control.segmentedHeight` | 28 |

### 悬浮窗

| 状态 | 尺寸 | 圆角 |
|---|---|---|
| 录音 / 流式 | 260×52 | 14（圆角矩形） |
| 处理中（转写/润色/翻译） | 280×52 | 14 |
| 学词 / 提示 | 460×84 | 16 |

- **玻璃即表面**：macOS 26 用 `.glassEffect(.regular, in:)`；旧系统回退 `.ultraThinMaterial`。
  不加实色填充、不加边框、不加投影。
- 排版：标签 13 medium，元数据 12 次要色，图标 18。
- 动效：淡入淡出 + 尺寸变化，不做缩放（避免露出玻璃边缘）。

## 目标

1. **悬浮窗**：原生 glass HUD——玻璃即表面，在白/彩/深背景上都干净通透。
2. **整体大方**：窗口变大、留白变多、字号层级清晰、卡片舒展。
3. **控件原生**：用系统控件（`Form` / `Picker` / `Toggle` / `NavigationSplitView`），不自绘。
4. **架构保持** Typeless 式（概览 / 资料库 / 设置），只做视觉与间距升级。

## 范围

### 8a 设计系统（`Theme.swift`）

把上表 token 化。所有视图引用 token，替换现有魔法数字
（当前散落着 `padding(28)` / `maxWidth: 780/880/900` / `cornerRadius: 10` 等不一致的值）。

### 8b 窗口与外壳

- 主窗口默认 **1000×700**、最小 **880×600**（`TalkWTFApp` 的 `.defaultSize` + 视图 `frame(minWidth:minHeight:)`）。
- 侧栏 **224**；设置二级列表 **192**；侧栏项高度 30、字号 14、图标 18。
- 内容区统一 `maxWidth: 880` + `padding: 28/24`，标题区独立，列表区独立滚动。

### 8c 控件（用系统控件，不自绘）

| 控件 | 做法 |
|---|---|
| 开关 | 原生 `Toggle`（`.switch`），macOS 自带 51×31 观感 |
| 下拉 | 原生 `Picker(.menu)`，自带双箭头 |
| 分段 | 原生 `Picker(.segmented)`（资料库 历史/词典） |
| 搜索框 | 原生 `TextField` + 放大镜（`.roundedBorder` 或自绘圆角 10 + 浅填充） |
| 排序 | 原生 `Picker(.menu)` |
| 按钮 | `.bordered` / `.borderedProminent` / `.link`，不设固定高度 |
| 行 | `Form(.grouped)` + `Section`，行内边距交给系统 |

### 8d 悬浮窗（重点）

见上表。**玻璃即表面**，尺寸按状态固定，内容居中。

### 8e 资料库 / 历史行

- 顶部 **搜索框** + **排序 pop-up**（最新在前 / 最早在前）。
- 历史行三行：润色文本（body）→ 原始转写（callout 次要色，仅当与润色不同）→
  元数据（`听写/翻译 · 相对时间 · 时长`，caption）。
- 操作（复制 / 重新转写 / 删除）放行尾。
- 词典页行 + 内联操作对齐新控件。

### 8f Dashboard 排版

- 指标卡：圆角 12、padding 16–20、数值 26–28 semibold、标签 13 次要色。
- 区块间距 24–28；柱状图高度 88；服务状态行高 40；个性化清单行高 28。

## 非目标

- 不引入新 UI 框架 / 第三方组件库。
- 不自绘控件（用系统控件，观感交给 macOS）。
- 不改后端 / ASR / 翻译 / 词典逻辑（纯 UI）。
- 不做窗口响应式断点（个人自用，固定大窗口）。

## 验收标准

1. 悬浮窗在白色 / 彩色 / 深色背景上都干净通透，看不出"卡片"边界。
2. 主窗口默认 1000×700、最小 880×600；内容区留白一致（所有页面 `maxWidth: 880`）。
3. 控件全部是系统控件，尺寸符合 HIG（开关 51×31、按钮高 28 等）。
4. 资料库有搜索框与排序控件；历史行显示润色 + 原文 + 元数据。
5. Dashboard 卡片与字号舒展，无 11px 以下正文。
6. 深浅色、系统 accent 全部正确；无粉色残留。
7. Xcode BUILD SUCCEEDED；`cargo test` / `cargo fmt --check` / `check_translations.py` 全绿；真机冒烟通过。

## 任务拆分

- [x] **U1 设计系统 token** —— 曾以 CSS/Tailwind 实现（已随 `src/` 删除）
- [x] **U2 窗口与外壳** —— 同上
- [x] **U3 原生控件** —— 同上
- [x] **U4 悬浮窗重做** —— SwiftUI 版已实现玻璃 + 圆角矩形 + 8 状态
- [x] **U5 资料库** —— 曾以 React 实现（已删）
- [x] **U6 Dashboard 排版升级** —— 同上
- [x] **U7 i18n + 全量验证** —— 同上

### SwiftUI 落地（本轮）

- [x] **S1** `Theme.swift`：`Theme.Fonts` / `Spacing` / `Layout` / `Radius` / `Control` / `Overlay`
      + `pageLayout()` / `cardSurface()` 两个修饰器
- [x] **S2** 窗口与外壳：`.defaultSize` 1000×700 + 视图 `frame(minWidth: 880, minHeight: 600)`；
      侧栏 224（200–260）、设置二级 192；三个页面统一走 `pageLayout()`（`maxWidth: 880`、padding 28/24）
- [x] **S3** 悬浮窗尺寸对齐：录音 260×52、处理 280×52、卡片 460×84；
      圆角按状态（胶囊态 14 / 卡片态 16）；玻璃形状跟随状态
- [x] **S4** 资料库：搜索框（放大镜 + 浅灰圆角）+ 排序 pop-up（最新/最早）+ 打开录音文件夹；
      历史行三行（润色 body / 原文 callout 次要色，仅在与润色不同时显示 / 元数据 caption 含时长）；
      操作改行尾图标（复制 / 重新转写 / 删除）；顺手修了资料库缺少 `ScrollView` 导致内容被裁切
- [x] **S5** Dashboard：卡片 `cardSurface()`（圆角 12 + padding 16）、数值 `Theme.Fonts.metric`
      （26 semibold 等宽）、标签 13、区块间距 24、柱状图更窄
- [x] **S6** 设置页：全部用系统 `Form(.grouped)` + `Section` + 原生 `Picker`/`Toggle`/`TextField`，
      行距与字号交给 HIG；去掉了散落的 780/900 宽度
- [x] **S7** 真机逐页截图核对 + 深浅色 — 完成（概览 / 资料库 / 设置七页；light + dark 均正确，无硬编码色）

## 已确认

1. 窗口 **1000×700**，最小 **880×600**。
2. 悬浮窗：**录音 260×52 / 处理 280×52**（学词/提示 **460×84**）。
3. 悬浮窗：**玻璃即表面**（macOS 卡片背景完全透明、去边框投影；旧系统回退材质）。
4. 基础字号：**正文 14 / 次要 13 / 说明 11**。
5. 实现顺序：**S1→S2**（外壳）→ **S3**（悬浮窗）→ **S4/S5/S6**（内容页）→ **S7**。
