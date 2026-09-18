# 阶段 14 实现计划：UI 重做（Spokenly 风 + Apple 原生 + 液态玻璃）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把主窗口、悬浮窗、引导页的观感对齐 Spokenly（Apple 原生 + 液态玻璃），不改信息架构与引擎。

**Architecture:** 先扩 `Theme.swift` 的 token 与 `glassSurface` 封装，再逐页应用：侧栏（浮动玻璃卡片 + 导航行）、内容区（大标题 + 分组卡片 + 圆角搜索）、悬浮窗（玻璃卡片 + 柔光边 + 虚线波形 + 目标 app 标识 + 悬停双按钮）、引导页。全部改动在已有 `.swift` 文件内。

**Tech Stack:** SwiftUI / AppKit（macOS 26 的 `glassEffect`，旧系统回退 material）。

**Spec:** `docs/specs/phase-14-spokenly-ui.md`

## Global Constraints

- Apple 原生风格（AGENTS.md）：系统语义色，**不硬编码品牌色**；系统字体；原生控件优先；不引入第三方 UI 框架/字体。
- 不改信息架构、核心逻辑、FFI、引擎。
- 只改已有 `.swift`；若确需新增文件，必须在 pbxproj 四处登记并在报告里说明。
- 构建必须通过：`xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build`。
- 分支 `phase-14-spokenly-ui` 上允许提交；每个任务构建通过再收。
- 视觉任务以「构建通过 + 真机截图」验收；不做无谓注释。

---

### Task 1: Theme token + glass 封装

**Files:**
- Modify: `macos/TalkWTF/Theme.swift`

**Interfaces:**
- Produces:
  - `Theme.Fonts.pageSubtitle`、`Theme.Fonts.sectionHeader`
  - `Theme.Colors.selection`、`Theme.Colors.selectionAccent`、`Theme.Colors.cardFill`、`Theme.Colors.glowRecording`、`Theme.Colors.glowWorking`
  - `Theme.Radius.overlay`
  - `View.glassSurface(cornerRadius: CGFloat, glow: Color? = nil) -> some View`
  - `View.sidebarRow(isSelected: Bool) -> some View`

- [ ] **Step 1: 扩展 Theme**

在 `Theme.swift` 的 `Fonts` 加：

```swift
        /// Page subtitle under the large title.
        static let pageSubtitle = Font.system(size: 13)
        /// Small bold group header inside a page.
        static let sectionHeader = Font.system(size: 13, weight: .semibold)
```

在 `Radius` 加：

```swift
        static let overlay: CGFloat = 20
```

新增 `Colors`：

```swift
    /// Semantic surfaces. Never hard-code brand colors (AGENTS.md).
    enum Colors {
        static let selection = Color.primary.opacity(0.06)
        static let selectionHover = Color.primary.opacity(0.03)
        static let selectionAccent = Color.accentColor.opacity(0.14)
        static let cardFill = Color.primary.opacity(0.04)
        static let glowRecording = Color.red.opacity(0.35)
        static let glowWorking = Color.accentColor.opacity(0.35)
    }
```

- [ ] **Step 2: 加 glass 封装**

在 `extension View` 里加：

```swift
    /// A rounded surface that uses Liquid Glass on macOS 26 and falls back to a
    /// material elsewhere. `glow` adds a soft outer shadow for the overlay.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat, glow: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .shadow(color: glow ?? .clear, radius: 12, y: 2)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: glow ?? .black.opacity(0.12), radius: 12, y: 2)
        }
    }

    /// Sidebar navigation row: an inset rounded pill that highlights on hover and
    /// selection, matching the reference app.
    func sidebarRow(isSelected: Bool) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isSelected ? Theme.Colors.selection : Color.clear)
            )
            .contentShape(Rectangle())
    }
```

- [ ] **Step 3: 构建**

```bash
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
```
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 4: 提交**

```bash
git add macos/TalkWTF/Theme.swift
git commit -m "feat(ui): Theme token + glassSurface/sidebarRow 封装（阶段 14 任务 1）"
```

---

### Task 2: 侧栏（浮动玻璃卡片 + 导航行）

**Files:**
- Modify: `macos/TalkWTF/AppShell.swift`

**Interfaces:**
- Consumes: `Theme.Colors.*`、`View.sidebarRow`、`View.glassSurface`（Task 1）。
- Produces: 侧栏渲染；`AppSection` / `SettingsPane` 不变。

- [ ] **Step 1: 侧栏头部与导航行样式**

把 `NavigationSplitView` 的侧栏 `List` 改为自绘行，保持 `selection` 绑定：

```swift
                NavigationSplitView {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform").foregroundStyle(.tint)
                            Text("TalkWTF").font(Theme.Fonts.headline)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 14)
                        .padding(.bottom, 10)

                        ForEach(AppSection.allCases) { item in
                            Button {
                                section = item
                            } label: {
                                Label(item.title, systemImage: item.symbol)
                                    .font(Theme.Fonts.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .sidebarRow(isSelected: section == item)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .navigationSplitViewColumnWidth(
                        min: Theme.Layout.sidebarMinWidth,
                        ideal: Theme.Layout.sidebarWidth,
                        max: Theme.Layout.sidebarMaxWidth
                    )
                } detail: { ... 保持原样 ... }
```

- [ ] **Step 2: 让侧栏背景走材质/玻璃**

在侧栏 `VStack` 上加：

```swift
                    .glassSurface(cornerRadius: 0)
```

并在 `NavigationSplitView` 上保留系统行为。若真机截图显示侧栏未浮动（macOS 26 系统风格），
则改为在 `VStack` 外层包一层圆角玻璃卡片（内缩 8pt）：

```swift
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.clear)
                    )
```
（以截图为准，二选一；在报告里写明选了哪种与截图结果。）

- [ ] **Step 3: 构建 + 截图**

```bash
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
```
构建成功后重启 app，截侧栏图（供审查）。

- [ ] **Step 4: 提交**

```bash
git add macos/TalkWTF/AppShell.swift
git commit -m "feat(ui): 侧栏玻璃卡片 + 导航行样式（阶段 14 任务 2）"
```

---

### Task 3: 内容区（页面头 + 分组卡片 + 搜索胶囊）

**Files:**
- Modify: `macos/TalkWTF/DashboardView.swift`
- Modify: `macos/TalkWTF/LibraryView.swift`
- Modify: `macos/TalkWTF/SettingsView.swift`
- Modify: `macos/TalkWTF/PersonalizationView.swift`
- Modify: `macos/TalkWTF/ModelsView.swift`

**Interfaces:**
- Consumes: `Theme.Fonts.pageSubtitle/sectionHeader`、`Theme.Colors.cardFill`（Task 1）。

- [ ] **Step 1: 加共享页面头**

在 `Theme.swift` 的 `extension View` 加（本任务用）：

```swift
    /// Large page title + secondary subtitle, matching the reference app.
    func pageHeader(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Fonts.largeTitle)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Fonts.pageSubtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
```

- [ ] **Step 2: 各页应用页面头 + 分组卡片**

- `DashboardView`：标题「概览」+ 副标题；指标卡改用 `Theme.Colors.cardFill` 圆角 12 面；区块头用 `sectionHeader`。
- `LibraryView`：标题「资料库」+ 副标题；搜索框改胶囊：
```swift
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("library.searchPlaceholder"), text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.Colors.cardFill, in: Capsule())
```
- `SettingsView` / `PersonalizationView` / `ModelsView`：分组标题用 `sectionHeader`；卡片面统一 `Theme.Colors.cardFill`（替换现有 `.quaternary.opacity(0.4)` 与 `cardSurface()` 的实现，使其读 token）。

把 `Theme.swift` 的 `cardSurface()` 改为：

```swift
    func cardSurface() -> some View {
        self
            .padding(Theme.Spacing.row + 4)
            .background(
                Theme.Colors.cardFill,
                in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            )
    }
```

- [ ] **Step 3: 设置分段换带图标胶囊**

`AppShell` 里设置页的 `Picker(.segmented)` 改为带图标的胶囊（`SettingsPane.symbol`）：

```swift
                            Picker("", selection: $pane) {
                                ForEach(SettingsPane.allCases) { item in
                                    Label(item.title, systemImage: item.symbol).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
```

- [ ] **Step 4: 构建 + 截图**

```bash
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
```
构建成功后重启 app，截概览/资料库/设置图。

- [ ] **Step 5: 提交**

```bash
git add macos/TalkWTF/DashboardView.swift macos/TalkWTF/LibraryView.swift macos/TalkWTF/SettingsView.swift macos/TalkWTF/PersonalizationView.swift macos/TalkWTF/ModelsView.swift macos/TalkWTF/Theme.swift macos/TalkWTF/AppShell.swift
git commit -m "feat(ui): 内容区页面头/分组卡片/搜索胶囊（阶段 14 任务 3）"
```

---

### Task 4: 悬浮窗（玻璃卡片 + 柔光边 + 虚线波形 + app 标识 + 悬停双按钮）

**Files:**
- Modify: `macos/TalkWTF/OverlayPanel.swift`
- Modify: `macos/TalkWTF/Theme.swift`（`Overlay` 几何微调）

**Interfaces:**
- Consumes: `Theme.Colors.glow*`、`Theme.Radius.overlay`、`glassSurface`。
- Produces: 新的 `OverlayView` 渲染；状态机与事件契约不变。

- [ ] **Step 1: 目标 app 标识**

在 `OverlayModel` 加：

```swift
    @Published var targetAppName: String?
    @Published var targetAppIcon: NSImage?
```

在 `OverlayController.show` 开头（仅 recording 态）取前台 app：

```swift
        if case .recording = state {
            let app = NSWorkspace.shared.frontmostApplication
            model.targetAppName = app?.localizedName
            model.targetAppIcon = app?.icon
        }
```

- [ ] **Step 2: 重写 `OverlayView.content`**

录音/流式态改为（其余态沿用，但套 glass + glow）：

```swift
            case .recording, .streaming:
                if hovering {
                    finishButton
                    discardButton
                } else {
                    appBadge
                    Spacer(minLength: 8)
                    waveform
                    Spacer(minLength: 8)
                    Text("TalkWTF")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(.secondary)
                }
```

`appBadge`：

```swift
    private var appBadge: some View {
        HStack(spacing: 6) {
            if let icon = model.targetAppIcon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            if let name = model.targetAppName {
                Text(name).font(Theme.Fonts.callout).lineLimit(1)
            }
        }
    }
```

`waveform` 改为虚线风格：无电平时画一排 3×2 的圆角短横（`Color.secondary.opacity(0.5)`），
有电平时用现有柱高（`.tint`）。

- [ ] **Step 3: glass + glow**

`OverlayView.body` 用：

```swift
        content.glassSurface(
            cornerRadius: model.state.cornerRadius,
            glow: glowColor
        )
```
`glowColor`：录音/流式 = `Theme.Colors.glowRecording`；处理/翻译 = `Theme.Colors.glowWorking`；其余 = nil。

- [ ] **Step 4: 提示文案**

录音态在卡片下方加一行「按 ⏎ 发送」（caption/secondary）。i18n key
`overlay.recordingHint`（en 写好，其余 25 个语言包补同 key，可英文兜底）。

- [ ] **Step 5: 构建 + 翻译检查 + 截图**

```bash
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
python3 scripts/check_translations.py
```
重启 app，按住热键录音截图（含悬停双按钮）。

- [ ] **Step 6: 提交**

```bash
git add macos/TalkWTF/OverlayPanel.swift macos/TalkWTF/Theme.swift resources/locales
git commit -m "feat(ui): 悬浮窗玻璃卡片 + 柔光边 + 虚线波形 + app 标识（阶段 14 任务 4）"
```

---

### Task 5: 引导页

**Files:**
- Modify: `macos/TalkWTF/OnboardingView.swift`

- [ ] **Step 1: 统一视觉**

- 用 `pageHeader` 大标题 + 副标题。
- 权限行改为圆角卡片：图标（SF Symbol）+ 标题 + 描述 + 右侧状态/按钮。
- 步骤指示用 accent 胶囊；卡片用 `cardSurface()`。

- [ ] **Step 2: 构建 + 截图**

```bash
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
```
重启 app，触发引导页截图。

- [ ] **Step 3: 提交**

```bash
git add macos/TalkWTF/OnboardingView.swift
git commit -m "feat(ui): 引导页统一视觉（阶段 14 任务 5）"
```

---

### Task 6: 全量验证 + 真机截图

- [ ] **Step 1: 构建 + 测试 + 翻译**

```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml
cargo fmt --manifest-path core/core/Cargo.toml --check
python3 scripts/check_translations.py
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
```

- [ ] **Step 2: 真机功能回归**

听写、翻译、学词、历史播放/重转录、词典 CRUD、设置读写、悬浮窗各状态、引导页权限。

- [ ] **Step 3: 截图对比**

对 侧栏 / 设置页 / 悬浮窗 各截一张，与 Spokenly 对比；不达标处记录并修。

---

## Self-Review

- **Spec 覆盖**：token→T1；侧栏→T2；内容→T3；悬浮窗→T4；引导→T5；验收→T6。
- **占位符**：无 TBD；T2 Step 2 的「二选一」是刻意的真机判定，报告须写明选择与截图。
- **类型一致**：`glassSurface` / `sidebarRow` / `pageHeader` / `Theme.Colors.*` 在定义与调用处一致。
- **风险**：macOS 26 `glassEffect` 与 `NavigationSplitView` 侧栏的兼容由 T2 的真机截图判定。
