# 阶段 16：自动学词 v3（整框去抖 + 输入框采集）

> 起因：阶段 15 真机验收后，从用户真实 `learning_attempts` 记录定位到根因。
> 本文档是设计，不是实现记录。

---

## 一、目标

让「听写后改词 → 自动学进词典」在真实场景（Chrome / 微信 / 原生输入框）**稳定触发**，
并且**学到完整词**、**不污染词典**。

1. **采集读对框**：读到用户实际编辑的输入框，而不是整个终端/网页。
2. **触发改成就绪去抖**：停手编辑 1.5s 即结算，不再要求「回车 + 清空/跳转」。
3. **不学半截词**：只学「停手后的稳定整框」与 baseline 之间的局部改动。
4. **只听错**：沿用严格门槛（LLM + 本地相似度），改意思不学；误学用撤销兜底。

## 二、问题与证据

### 2.1 真机数据

用户本机 `~/Library/Application Support/com.talkwtf.app/dictionary.db` 的 `learning_attempts`：
**56 次尝试，仅 5 次学到**。`skipped` 的原因分布：

| reason | 含义 | 根因 |
| --- | --- | --- |
| `visible text collection`（几乎全部 strategy） | 读到了整窗可见文本 | 见 2.2 |
| `timeout` | 45s 内未结算 | 长句无 Enter / 字段不清空 |
| `the frontmost app changed` | 切 app 即放弃 | 无 pending Enter 时 AppChanged=Ignore |
| `superseded by a newer dictation` | 被下一次听写取代 | 观察窗口 45s 太长 |
| `secure input became active` | 安全输入 | Terminal 等 |
| `the enter key was pressed` 却仍 skipped | final 是无关文本 | 读到整窗 |

已学到的 5 条里，`C三XO → Cic a`、`CISA XO → Cic a`（id 32/33）是**半截词**。
词典里还有 `新做`、`想头疗了` 等疑似污染项。

### 2.2 头号 bug：采集「取最长」

`core/core/src/learning/ax/mod.rs::read_focused_field` 把四种读法（原生 `AXValue`、
web 文本标记、祖先、子元素、可见文本收集）都跑一遍，然后
`.max_by_key(|c| c.text.chars().count())`。在 Terminal / 浏览器 / 编辑器里，
「整窗可见文本」永远比输入框长 → 选中整窗 → `is_related(pasted, final)` 失败 → 不学。

### 2.3 Typeless 的做法（拆解 `/Applications/Typeless.app`）

- drizzle schema：`history.ax_text`（粘贴前整框）、`refined_text`（插入的）、
  `edited_text`（改后）、`edited_text_status`/`edited_text_attempts`（重试状态机）。
- 主进程日志串：`[User Edit] 🔄 Edit detected, resetting timeout timer` →
  `🟢 Content edited (small-scale), triggering report`；Enter 记 `lastPressEnterTime`。
- 结论：**采集整框、按「停止编辑」去抖结算、Enter 为主信号**，不要求输入框清空。
  （它把结果传云，那条不抄。）

### 2.4 现状与目标的差异

| 维度 | 现状 | v3 |
| --- | --- | --- |
| 读取 | 取最长 → 常读整窗 | 取「含粘贴文本的最短候选」= 输入框 |
| diff | 粘贴小段 vs 整框，靠对齐 | 整框 baseline vs final，同源 |
| 触发 | 必须 Enter + 清空/跳转 | 停手 1.5s 去抖 |
| 半截 | `decide()` 兜底保留半截 | 删兜底；只学稳定整框的局部改动 |
| 判定 | LLM 看整框 | LLM 只看候选附近的有界上下文 |

## 三、范围

- `core/core/src/learning/ax/mod.rs`：候选选择 + 来源锁定。
- `core/core/src/learning/watcher.rs`：baseline 采集 + 去抖状态机 + 结算。
- `core/core/src/learning/diff.rs`：去掉半截兜底；新增有界上下文辅助。
- `core/core/src/learning/llm.rs`：判定改用有界上下文（接口不变或微调）。
- `macos/TalkWTF/DictationController.swift` / `OverlayPanel.swift`：仅在必要时同步调用签名。
- 不改本地 ASR；不新增重型依赖；无自建云/账号/遥测。

## 四、非目标

- 不抄 Typeless 的云同步/账号/订阅。
- 不做 Windows/Linux。
- 不做「app-aware 润色」（阶段 4 已否决）。
- 不自动清理历史污染词（用户手动删，可另开小任务）。
- 不支持读不到独立输入框的 TTY（如 Terminal 的命令行本身）：整框滚动会令 diff 非局部，自然不学。

---

## 五、设计

### 5.1 分层

```
capture  粘贴后锁定输入框，取 baseline 整框
trigger  编辑一变即重置 1.5s 去抖；静默即结算
judge    整框 diff(baseline,final) → 只听错（本地门槛 + LLM 复核）
learn    写词典 + learning_attempts + 弹窗/撤销
```

### 5.2 采集层（`learning/ax`）

**候选收集**：按优先级收集所有成功读取（保持现有五条路径），但**不再直接取最长**。

**候选选择**（新纯函数，可单测）：

```rust
/// 从所有成功读取里选「用户正在编辑的输入框」。
/// pasted 为粘贴文本，用作锚点。
fn select_candidate(candidates: Vec<FocusedText>, pasted: Option<&str>) -> Option<FocusedText>
```

规则：

1. `pasted` 非空时：
   - **含** `pasted`（归一化后包含）的候选中，取**字符数最短**者（= 输入框，而非整窗）；
     并列时按优先级顺序取第一个。
   - 没有含的，取与 `pasted` 最相关者（`diff::is_related` 为真且 `unchanged_span` 最高）。
   - 都不相关 → 返回 `None`（宁可不学，也不读错框）。
2. `pasted` 为空（诊断路径）：取优先级最高的非空候选。

**接口变更**：

```rust
pub fn read_focused_field(pasted: Option<&str>, timeout_ms: u32) -> Option<FocusedField>;
```

- `FocusedField { text, identity, strategy }` 不变；`strategy` 记录选中的来源（仅诊断）。
- 观察期间因为始终用同一个 `pasted` 做锚点，同一个输入框每轮都会胜出，baseline 与 final 自然同源；
  不新增「首选来源」参数。
- `read_focused_text`（诊断用）保留。

**归一化包含**：新增 `diff::contains_normalized(haystack, needle)`（仅 alnum、小写后子串匹配）。

### 5.3 触发层（`learning/watcher`）

**常量**：

```rust
const POLL_INTERVAL: Duration = Duration::from_millis(200);
const BASELINE_TIMEOUT: Duration = Duration::from_millis(2000);
const EDIT_DEBOUNCE: Duration = Duration::from_millis(1500);
const FOCUS_LOST_POLLS: u32 = 10;          // 2s
const WATCH_WINDOW: Duration = Duration::from_secs(45);
const NO_EDIT_WINDOW: Duration = Duration::from_secs(15);
const MAX_LEARNED_WORDS: usize = 5;
```

**baseline 采集**：

- `watch_for_edit(pasted)` 后，轮询 `read_focused_field(Some(pasted), READ_TIMEOUT_MS)`，
  直到读到的文本**含 `pasted`**（归一化）或 `BASELINE_TIMEOUT` 到期。
- 成功：记 `baseline`（整框文本）+ `strategy` + `identity` + `bundle_id`。
- 失败：记 attempt（`outcome=skipped`, `reason="the input box could not be read"`），结束。

**去抖状态机**（重写 `WatchMachine`）：

状态：`baseline: String`、`last_text: String`、`edited: bool`、`last_edit: Option<Instant>`。

| 事件 | 行为 |
| --- | --- |
| `Readable(text)`，`text != last_text` | `last_text = text`；若 `text != baseline` → `edited = true`、`last_edit = now` |
| `Readable(text)`，`text == last_text` | 若 `edited && now - last_edit >= EDIT_DEBOUNCE` → **Learn** |
| `Unreadable` 连续 `FOCUS_LOST_POLLS` 且曾可读 | `edited` → Learn，否则 Ignore |
| `AppChanged` | `edited` → Learn，否则 Ignore |
| `SecureInput` / `Superseded` / `SettingOff` | Ignore（不学） |
| 无编辑且超过 `NO_EDIT_WINDOW` | Ignore（timeout） |
| 超过 `WATCH_WINDOW` | `edited` → Learn，否则 Ignore |

结算触发共有五类：编辑静默 1.5s、失焦约 2s、切 app、无编辑超时、观察窗口到期。
发送后输入框清空的情形，会在约 2s 失焦后结算学到（不再有回车立即结算）。

**结算**：`final = last_text`（停手后的稳定整框）。`final == baseline` → 不学。

**删除** `decide()` 与 `choose_final()`：新设计直接取稳定后的 `last_text` 作为 final，
不再从多个历史状态里挑候选（半截词正来自那套兜底）。`observed` 仅保留用于诊断记录。

### 5.4 判定层（`learning/diff` + `learning/llm`）

- **整框 diff**：`diff::detect_edits(baseline, final)` 得到局部、token 对齐的候选。
  同源整框，对齐可靠。
- **有界上下文**（新纯函数）：

```rust
/// baseline/final 的公共前后缀之间的差异区，向两侧各扩 radius 字符。
/// 上下文被限制在改动附近 ±radius 字符内；字段短于该范围时原样返回整段。
pub fn bounded_context(baseline: &str, final: &str, radius: usize) -> (String, String);
```

- **本地门槛**：`is_likely_mishearing` 过滤（只听错）。
- **LLM 复核**：
  - 配了 provider：把 `bounded_context` 的结果交给现有 `llm::judge(pasted_ctx, final_ctx)`
    （提示词与「只听错」约束不变），LLM 结果优先；失败 → 本地门槛结果。
  - 未配 provider：直接用本地门槛结果。
- 保持「改意思不学」（提示词反例不变）。

### 5.5 学词 / 事件 / 撤销

不变：`learn()` 只写词典词（不建替换规则）→ `learned-correction` + `learned-overlay` →
悬浮窗弹窗 + 撤销（`undo_last_dictionary_learning` 删词 + 记拒绝名单）。
去抖后弹窗约在停手 1.5s 后出现。

### 5.6 隐私

- 输入框文本只在本地读取；只有配了 provider 时才把**改动附近的有界上下文**直连发给该 provider。
  该上下文被限制在改动周围 ±`radius` 字符内；字段短于该范围时整段发出（并非「绝不外发整框」）。
- 密码框/被禁 app/Secure Input 永不读取。
- `learning_attempts` 只存本地，沿用现有 200 条裁剪。

---

## 六、数据流

```
热键 → 听写 → 粘贴 → watch_for_edit(pasted)
  ↓ 采集 baseline：轮询直到读到「含 pasted 的输入框」（≤2s）
  ↓ 轮询 200ms：文本一变 → 重置 1.5s 去抖
  ↓ 停手 1.5s / 切 app / 失焦 / 观察窗口到期
final = 稳定整框
  ↓ final == baseline ? 不学
  ↓ diff::detect_edits(baseline, final) → 局部候选
  ↓ 本地只听错门槛 + LLM 有界上下文复核
  ↓ learn(store, cands) → 加词典词
  ↓ emit learned-correction + learned-overlay
  ↓ Swift: OverlayController.show(.learned) + 撤销
```

---

## 七、错误处理

- baseline 读不到（≤2s）：静默不学，记 attempt。
- AX 不可读 / Secure Input / 被禁 app：静默不学，不报错。
- 切 app / 失焦：有编辑则结算学习，否则不学。
- LLM 任何失败：回退本地门槛；本地无候选则不学。
- 写词典失败：跳过该条。
- 被更新的听写取代：不学（去抖后观察窗口短，取代已罕见）。

---

## 八、测试与验收

**单元测试（core）**

- `ax::select_candidate`：
  - 候选同时含「输入框」与「整窗」，取最短（输入框）；
  - 无候选含 pasted 时取最相关；都不相关返回 `None`；
  - `pasted=None` 取优先级最高。
- `diff::bounded_context`：公共前后缀定位差异区、radius 扩展、短文本原样返回。
- `diff::contains_normalized`：大小写/标点差异下的包含判定。
- `watcher::WatchMachine`：
  - 编辑后静默 1.5s → Learn；
  - 编辑后持续变化 → 不结算；
  - 无编辑超时 → 不学；
  - 切 app / 失焦有编辑 → Learn，无编辑 → Ignore；
  - SecureInput / Superseded / SettingOff → Ignore。
- `watcher`：删除 `decide()`/`choose_final()` 及其半截兜底测试；`attempt_outcome` 等纯函数测试保留。
- `llm`：有界上下文判定（沿用现有 judge 测试 + 新上下文测试）。

**手动验收（用户真机）**

1. Chrome / 微信 / TextEdit：听写 → 改词 → **停手 1.5s** → 弹窗 + 词典加词。
2. 输入法提交候选的中途停顿**不**学半截词。
3. 改意思（早→晚）不学。
4. 弹窗「撤销」→ 词消失、误听进拒绝名单。
5. 调试页能看到每次尝试的 baseline/final/来源/原因。

**命令**

```bash
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  cargo test --manifest-path core/core/Cargo.toml
cargo fmt --manifest-path core/core/Cargo.toml --check
xcodebuild -project macos/TalkWTF.xcodeproj -target TalkWTF -configuration Debug build
python3 scripts/check_translations.py
```

---

## 九、任务拆分

1. `diff`：`contains_normalized` + `bounded_context` + 去掉半截兜底 + 单测。
2. `ax`：`select_candidate` + `read_focused_field(pasted, timeout)` 签名 + 单测。
3. `watcher`：baseline 采集 + 去抖状态机重写 + 结算 + 单测。
4. `llm`：判定改用有界上下文 + 单测。
5. 全量测试 + 构建 + 真机验收。

---

## 十、风险与取舍

- **去抖会多学**：停手即学，误学靠悬浮窗撤销兜底；门槛保持「只听错」。
- **中途停顿仍可能学半截**：1.5s 内继续输入会重置；极端情况下仍可能，撤销兜底。
- **整框 diff 对大字段**：终端滚动/动态网页产生非局部改动 → 自然不学（宁可少学）。
- **LLM 只带上下文**：可能丢失整句语义，但「只听错」是局部判断，足够；且更省 token、更少外发。
- **切 app/失焦也结算**：可能学到未发送的编辑；撤销兜底（沿用阶段 12b 取舍）。
- **锚定失效**：若「含 pasted 的候选」读不到（粘贴失败或输入框不可读），回退「最相关」；
  都不相关则不学（宁可不学，也不读错框）。
