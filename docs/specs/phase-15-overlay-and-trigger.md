# 阶段 15：悬浮窗自适应/悬停稳定 + 学词发送判定（防输入法回车）

> 起因：阶段 14 真机验收反馈。本文档是设计，不是实现记录。

---

## 一、目标

1. **悬浮窗**：宽度按内容自适应；**鼠标悬停时宽度与位置都不变**；**始终水平居中**于所在屏幕。
2. **学词**：保留「按回车才学」，但**区分「发送回车」与「输入法/编辑回车」**，不再学到半截词。

## 二、问题与证据

### 2.1 悬浮窗

- 上一版用 `.fixedSize(horizontal: true)` 让玻璃卡片贴内容，于是**悬停时内容换成两个按钮、卡片跟着变窄**（用户：「移上去就缩短」）。
- 之后改成固定宽度公式，又**不够自适应**（用户：「现在又不能自适应了」）。
- 宽度变化导致**视觉不居中**：面板原点按旧宽度算，宽度一变就偏左/偏右。
- 学词记录显示学到半截词：id=33 `CISA XO → Cic a`、id=32 `C三XO → Cic a`（用户还没打完）。

### 2.2 学词

- 用户输入 `Cica Exo` 这类**含空格的词**时，中文输入法常需要**按回车提交候选**（`Cica` + 回车 → 空格 → `Exo` + 回车）。这些回车**不是发送**。
- 我们的 Enter 监听把这些回车当成发送 → 结算 → 学到半截。
- 结论：Enter 是好信号，但**必须再确认「这是发送」**。

---

## 三、设计

### 3.1 悬浮窗：自适应 + 悬停稳定 + 居中

**布局：录音态用 `ZStack` 叠两层，宽度由「非悬停层」决定。**

```swift
case .recording, .streaming:
    ZStack {
        HStack { appBadge; Spacer(minLength: 8); waveform; Spacer(minLength: 8); wordmark }
            .opacity(hovering ? 0 : 1)
        HStack { finishButton; discardButton }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
    }
```

- `ZStack` 的尺寸 = 两个子层里较大者 = 录音内容（通常更宽）→ **宽度与悬停无关**。
- 悬停时两个按钮用 `maxWidth: .infinity` 撑满同一宽度，不再变窄。
- 卡片用 `.fixedSize(horizontal: true, vertical: false)` 贴合 `ZStack` 宽度 → **真正自适应内容**（长 app 名自动变宽）。

**尺寸与居中**

- `OverlayPanel.show` 每次都用 `NSHostingView.fittingSize` 量当前内容（此时宽度恒定，量出来稳定），
  `setContentSize` 后 `reposition` → 按新宽度重新居中。
- `hosting.sizingOptions = []`，禁止 SwiftUI 自行改窗口尺寸。
- 位置：`x = screen.visibleFrame.midX - width/2`（居中）；`y` 由「顶部/底部」设置决定。
- 各状态的宽度都改为**按内容量**（不再用固定 `workingSize/cardSize` 宽度），仅保留最小/最大 clamp：
  `minWidth = 240`、`maxWidth = 520`。

**其它状态**（transcribing/processing/translating/learned/translationFailed/notice）同样按内容量宽，
高度沿用现有 `size.height`；学词仍是录音胶囊尺寸。

### 3.2 学词：Enter 只是「候选发送」，需再确认

在 `WatchMachine` 增加「待确认发送」状态：

- `Poll::Enter` → **不立即 Learn**，记 `pending_send = Some(Instant)`，并记下当前字段文本。
- 之后每轮：
  - **字段清空** → 确认发送 → `Learn`（原因 `Enter + field cleared`）。
  - **前台 app 变化** → 确认发送（网页提交跳页）→ `Learn`。
  - **字段文本变化且非空**（用户在输入法提交后继续打字）→ **取消** `pending_send`，继续观察。
  - **超时**（`SEND_CONFIRM_WINDOW = 1.5s` 内既未清空也未跳转）→ 取消 `pending_send`，继续观察（不学）。
- 新一轮 `Poll::Enter` 覆盖 `pending_send`（重新计时）。
- 观察窗口 45s 到期仍不学。

即：**只有「回车 + 字段被清空/应用跳转」才算发送**。这样：
- 聊天类（回车发送→清空）：学。
- 网页表单（回车提交→跳转）：学。
- 输入法回车（提交候选→文本变多）：不学。
- 多行框回车换行（文本变多）：不学。

**设置联动（可选）**：若 `auto_submit_key` 为 `enter`，语义一致；若为 `off`，
说明用户用别的方式发送，此时 Enter 仅作候选，仍需清空/跳转确认（同上）。

**诊断**：`learning_attempts` 的 `reason` 里带上确认方式（`enter+cleared` / `enter+app-changed`），
便于回溯。

### 3.3 边界

- 若发送后字段**既不清空也不跳转**（少数 app 保留文本）：本设计**不学**（宁可少学）。用户可手动加词。
- 若用户回车后立刻切走焦点（失焦而非清空）：属「app 变化」或「字段不可读」，按未确认处理，不学。

---

## 四、数据流

```
Enter 命中 → pending_send（记文本、计时）
  ├─ 1.5s 内字段清空      → Learn（observed）
  ├─ 1.5s 内前台 app 变化  → Learn（observed）
  ├─ 字段文本变化且非空     → 取消 pending，继续观察
  └─ 超时                  → 取消 pending，继续观察
```

## 五、测试与验收

**单元测试（`WatchMachine`）**
- Enter 后字段清空 → Learn。
- Enter 后前台变化 → Learn。
- Enter 后文本变多 → Continue（不学），且 pending 清除。
- Enter 后 1.5s 无变化 → Continue（不学）。
- 无 Enter、仅清空 → 仍不学（沿用阶段 14 的收紧）。
- 连续两次 Enter → pending 重新计时。

**真机**
1. Chrome/Gmail、微信：听写 → 改词（含空格，输入法回车提交）→ 真回车发送 → 学到**完整词**、弹窗。
2. 输入法提交候选的回车**不**触发学习。
3. 悬浮窗：长 app 名自动变宽；鼠标悬停宽度、位置不变；始终居中。
4. 顶部/底部定位仍生效。

## 六、任务拆分

1. 悬浮窗：`ZStack` 录音/悬停层 + 按内容量宽 + 居中重算 + `sizingOptions`。
2. `WatchMachine`：`pending_send` 状态机 + 取消/确认逻辑 + 单测。
3. `observe`：Enter 不再直接 Learn；驱动 pending 确认；诊断原因。
4. 真机验收。

## 七、非目标

- 不改词典/润色/翻译逻辑；不新增设置项（复用 `overlay_position`）。
- 不引入第三方库。
