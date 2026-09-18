# 阶段 14：UI 重做（Spokenly 风 + Apple 原生 + 液态玻璃）

> 起因：核心功能完成后，用户要求把 UI 做到接近本地 Spokenly 的观感。
> 本文档是设计，不是实现记录。参考：Spokenly 2.29.5（原生 SwiftUI）的
> 历史页 / 常规设置页 / 模式页 / 四张悬浮窗截图。

---

## 一、目标

把 TalkWTF 的观感对齐 Spokenly：**Apple 原生 + 液态玻璃**，大留白、层次靠材质与留白而非边框。

1. 主窗口：浮动玻璃侧栏 + 大标题内容区 + 分组卡片。
2. 悬浮窗：玻璃卡片 + 柔光边 + 虚线波形 + 目标 app 标识 + 悬停双按钮。
3. 引导页：同一套视觉。

## 二、范围

- `macos/TalkWTF/Theme.swift`（token 扩展）
- `AppShell.swift`（侧栏）
- `DashboardView.swift` / `LibraryView.swift` / `SettingsView.swift` / `PersonalizationView.swift` / `ModelsView.swift`（内容区）
- `OverlayPanel.swift`（悬浮窗）
- `OnboardingView.swift`
- 不新增 Swift 文件（除非必要，且需在 pbxproj 四处登记）。

## 三、非目标

- 不改信息架构（仍是 概览 / 资料库 / 设置 + 设置内分段）。
- 不改核心逻辑/FFI/引擎。
- 不引入第三方 UI 框架或字体。
- 不做签名/公证/自动更新。

---

## 四、设计 token（Theme.swift）

在现有 `Theme` 上扩展，所有视图只读 token，不写魔法数字。

**色彩**（全部系统语义色）
- 选中胶囊：`Color.primary.opacity(0.06)`（侧栏）；分段/胶囊选中用 `accentColor.opacity(0.14)` + accent 文本。
- 卡片面：`.background` 上的 `Color.primary.opacity(0.04)`；分组容器用 `.regularMaterial`。
- 文字：`label` / `secondaryLabel` / `tertiaryLabel`；分隔线 `separator`。
- 悬浮窗柔光：录音 `Color.red.opacity(0.35)`、处理/翻译 `accentColor.opacity(0.35)`（阴影 + 1px 描边）。

**材质**
- `Theme.Material.card = .regularMaterial`；`sidebar = .regularMaterial`。
- macOS 26：关键表面用 `.glassEffect(.regular, in: shape)`；旧系统回退 `.ultraThinMaterial`。
- 统一封装：`extension View { func glassSurface(cornerRadius:) -> some View }`，内部 `#available(macOS 26, *)` 分支。

**字体**（沿用并微调）
- `largeTitle` 28/semibold；`pageSubtitle` 13/regular/secondary；`sectionHeader` 13/semibold；
  `headline` 15/semibold；`body` 13；`callout` 13；`caption` 12；`metric` 28/semibold monospacedDigit。

**圆角 / 间距**
- `Radius.card 12`、`Radius.control 8`、`Radius.overlay 20`、搜索胶囊 `Capsule`。
- 间距 4/8 栅格；`Layout.contentMaxWidth 880`。

---

## 五、主窗口

### 5.1 侧栏（`AppShell`）
- 浮动圆角玻璃卡片（macOS 26 `.glassEffect`；旧系统 `.regularMaterial`），圆角 18，内缩 8–10pt。
- 顶部：app 图标 + 「TalkWTF」文字标（`Theme.Fonts.headline`）。
- 导航行：SF Symbol + 标题，高 34，圆角 8；选中 = `primary.opacity(0.06)` 胶囊；hover = `primary.opacity(0.03)`。
- 分组间发丝分隔；底部工具区（与现有 概览/资料库/设置 结构对应）。
- 保留现有 `NavigationSplitView` 行为与快捷键。

### 5.2 内容区
- 页面头：`largeTitle` 标题 + `pageSubtitle` 副标题（Spokenly 同款）。
- 分组卡片：圆角 12 容器 + 发丝分隔；行 = 图标(SF Symbol, secondary) + 标题 + 描述(caption/secondary) + 右侧控件。
- 设置页：顶部胶囊分段保留（通用/个性化/模型/声音/高级/调试/关于），换成带图标的胶囊样式；分段选中 = accent 淡色。
- 概览：指标卡片用同款卡片面 + `metric` 字阶；服务状态行。
- 资料库：历史/词典用圆角卡片列表；搜索框改**圆角胶囊**（`Capsule` + magnifier）。
- 移除硬编码的 `.quaternary.opacity(0.4)` 卡片面，统一走 token。

### 5.3 交互
- hover 高亮、键盘焦点、右键菜单保持原生；尊重「减少动态效果」（过渡短、可关）。

---

## 六、悬浮窗（`OverlayPanel`）

保留 8 状态机与事件契约，只重做渲染与几何。

- **外形**：玻璃卡片，圆角 `Radius.overlay`，柔光边（录音红晕 / 处理蓝晕），阴影柔和。
- **布局**（录音态）：
  - 左上：目标 app 图标（`NSRunningApplication.icon`，16–18pt）+ 名称；
  - 右上：「TalkWTF」文字标（secondary）；
  - 中部：**虚线波形**（点/短横；有电平时变为实心柱）；
  - 下方：提示「按 ⏎ 发送」（caption/secondary）。
- **悬停**：显示两个大按钮「✓ 完成并输入」（accent）/「✕ 丢弃」（红），其余淡出；沿用 `DictationController.finish()/discard()`。
- **处理/翻译态**：同一卡片，spinner + 文案（转录中/润色中/翻译为 X），蓝晕。
- **学到词/翻译失败**：沿用 `cardSize`，玻璃卡片 + 图标 + 按钮。
- **目标 app 标识**：录制开始时取 `NSWorkspace.shared.frontmostApplication`（bundle id + localizedName + icon）；取不到则不显示该行。
- **几何**：`recordingSize`/`workingSize`/`cardSize` 按新内边距微调；位置逻辑（与录音悬浮窗同位）不变。

---

## 七、引导页（`OnboardingView`）

- 同一套大标题 + 副标题 + 玻璃卡片；权限行 = 图标 + 标题 + 描述 + 状态/按钮。
- 步骤指示用 accent 胶囊；按钮用原生 prominence。

---

## 八、可访问性与回退

- 所有文本用语义色，保证 light/dark 可读；对比度达标。
- `#available(macOS 26, *)` 之外回退 material，功能不缺失。
- 尊重「减少动态效果」；动画时长 ≤ 0.2s。
- 图标均给 `accessibilityLabel`（现有已具备，新增控件补齐）。

## 九、测试与验收

- 构建：`xcodebuild ... Debug build` 成功，无新警告。
- 视觉：真机截图对比 Spokenly（侧栏/设置页/悬浮窗三处）。
- 功能回归：听写、翻译、学词、历史、词典、设置读写、悬浮窗各状态、引导页权限。
- 命令：
```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
python3 scripts/check_translations.py   # 若新增文案
```

## 十、任务拆分

1. `Theme.swift`：新 token + `glassSurface` 封装。
2. `AppShell` 侧栏：浮动玻璃卡片 + 导航行样式。
3. 内容区：页面头 + 分组卡片 + 搜索胶囊（Dashboard/Library/Settings/Personalization/Models）。
4. 悬浮窗：玻璃卡片 + 柔光边 + 虚线波形 + app 标识 + 悬停双按钮。
5. 引导页：统一视觉。
6. 真机截图验收 + 功能回归。

## 十一、风险

- **macOS 26 glassEffect 的可用性与性能**：悬浮窗频繁刷新，glass 可能有开销；必要时降级为 material。
- **侧栏浮动化与 `NavigationSplitView` 的兼容**：可能需要自定义侧栏容器；保持现有行为与快捷键。
- **目标 app 图标获取**：个别 app 无图标/名称；缺失时优雅省略。
- **不新增文件**：改动集中在已有文件，注意 `AppShell`/`SettingsView` 已有体量。
