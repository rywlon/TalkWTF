# 阶段 15 实现计划：悬浮窗自适应/悬停稳定 + 学词发送判定

**Goal:** 悬浮窗按内容自适应、悬停不变、始终居中；学词只在「回车 + 清空/跳转」时发生。

**Spec:** `docs/specs/phase-15-overlay-and-trigger.md`

## Global Constraints

- 不改词典/润色/翻译；不新增设置项；不引入第三方库。
- 构建通过；core 测试通过；沿用系统语义色/材质。
- 分支 `phase-15-overlay-trigger`（自 `phase-14-spokenly-ui`）。

---

### Task 1: 悬浮窗 ZStack + 实测宽度 + 居中

**Files:** `macos/TalkWTF/OverlayPanel.swift`

- [ ] 录音/流式态改为 `ZStack`：录音内容层（`opacity(hovering ? 0 : 1)`）+ 悬停按钮层
      （`opacity(hovering ? 1 : 0)`、`allowsHitTesting(hovering)`），按钮 `maxWidth: .infinity`。
- [ ] 内容改回 `.fixedSize(horizontal: true, vertical: false)`，宽度由 `ZStack` 决定（悬停无关）。
- [ ] `OverlayPanel.show`：`hosting.layoutSubtreeIfNeeded()` 后取 `fittingSize`，
      宽 clamp 到 `[240, 520]`，`setContentSize` 再 `reposition`（按新宽度居中）。
- [ ] 保留 `hosting.sizingOptions = []`。
- [ ] 删掉上一版基于 app 名的 `contentWidth(for:)` 公式（改回实测）。
- [ ] 构建；重启截图：录音态宽度、悬停态宽度一致；长 app 名不截断。

### Task 2: `WatchMachine` pending_send + observe

**Files:** `core/core/src/learning/watcher.rs`

- [ ] 新增常量 `SEND_CONFIRM_WINDOW = Duration::from_millis(1500)`。
- [ ] `WatchMachine` 增加 `pending_send: Option<Instant>` 与 `pending_text: Option<String>`。
- [ ] `Poll::Enter` → 不 Learn；设 `pending_send=now`、`pending_text=observed.last()`，返回 `Continue`。
- [ ] 新增 `Poll::Tick`（或在 Readable 分支内处理）：
      - 若 `pending_send` 已设：
        - 文本为空 → `(Learn, StopReason::Enter)`（reason 文案「the enter key was pressed and the field cleared」）。
        - 前台变化由 `Poll::AppChanged` 处理：若 pending 已设 → `(Learn, AppChanged)`，否则 `Ignore`。
        - 文本非空且与 `pending_text` 不同 → 清除 pending，`Continue`。
        - `now - pending_send > SEND_CONFIRM_WINDOW` → 清除 pending，`Continue`。
- [ ] `observe`：Enter 命中后不再立即返回 Learn；继续轮询，把后续 `Readable` 喂给 machine 触发确认。
      Enter 当轮仍做一次/两次补读（沿用阶段 14）以捕获最终文本。
- [ ] `Poll::AppChanged` 的 Learn/Ignore 取决于是否 pending。
- [ ] 单测：
      - Enter + 清空 → Learn；
      - Enter + 前台变化 → Learn；
      - Enter + 文本变多 → Continue 且 pending 清除；
      - Enter + 超时 → Continue；
      - 无 Enter 仅清空 → Ignore；
      - 两次 Enter → pending 重置。

### Task 3: 验证

- [ ] `cargo test core`、`cargo fmt`、`xcodebuild`。
- [ ] 真机：Chrome/微信 含空格词 + 输入法回车；悬浮窗宽度/悬停/居中；顶/底定位。
