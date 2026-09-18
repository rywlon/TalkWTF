# 阶段 12b：自动学词重做（发送后触发 + LLM 判定 + 弹窗修正）

> 起因：用户反馈（阶段 12 交接文档 P1-B）。本文档是设计，不是实现记录。
> 目标：让自动学词「只在发送后学」「会学词而不是单字」「弹窗即时且位置正确」。

---

## 一、目标

1. **只在发送后学**：用户在输入框里改完并发送（回车）之后才学习；不再因为停顿 5 秒、
   45 秒超时或切换 app 而提前/意外学习。
2. **学词而不是单字**：中英混说与中文场景学到的应是词/术语（如「浏览器」「Cica Exo」），
   不是单个汉字。
3. **弹窗即时、位置正确**：学到后立刻弹出，且与录音悬浮窗同一位置（替代录音悬浮窗），
   不再需要点开 app 才出现。

## 二、范围

- `core/core/src/learning/{watcher,diff}.rs` 的触发与结算逻辑
- 新增 LLM 判定（复用现有 BYOK provider）
- `macos/TalkWTF/OverlayPanel.swift` 的 learned 弹窗定位
- `macos/TalkWTF/SettingsView.swift` 阈值滑块下限

## 三、非目标

- 不改本地 ASR 运行时。
- 不新增设置页；学词复用「个性化」里已选的润色 provider 与 key。
- 不实现自建云/账号/遥测；LLM 仅在用户已配置 provider + key 时直连。
- 不处理 P1-A（录音/处理态 label）与 P1-C（液态玻璃细节），另开 spec。

---

## 四、现状（已核实的代码事实）

- 观察循环：`core/core/src/learning/watcher.rs::observe()`。粘贴后轮询 45s
  （`POLL_INTERVAL` 200ms、`WATCH_WINDOW` 45s），最多记 40 个不同字段值。
- **当前会提前学**：字段静默 `SETTLE`=5s 就结算（watcher.rs:250-271），
  45s 超时也会 `decide()` 学习（watcher.rs:274-276）。
- **当前「切 app 才弹」的原因**：`observe()` 只在字段清空、静默 5s、或
  `frontmost_bundle_id` 变化时才结算。用户发送后若焦点/可读性变化但字段未清空，
  就不会结算，直到切 app 触发 `frontmost` 变化。
- 学到后：`apply()` → `learn()` 只把词写进词典 `words`（识别提示，不建替换规则），
  发 `learned-correction` + `learned-overlay` 事件（watcher.rs:352-391）。
- 弹窗定位：`OverlayController.handle` 收到 `learned-overlay` 时用 core 给的
  AX `frame` 贴输入框（OverlayPanel.swift:112-122）；录音悬浮窗则用默认位置
  （指针所在屏幕顶部居中，OverlayPanel.swift:226-234）。
- CJK 粒度：`diff.rs::is_token_boundary` 把每个汉字都当边界，
  `expand_to_token_bounds` 因此只扩到单字；`MIN_CJK_SPAN_CHARS`=1。
- 阈值：`word_correction_threshold` 默认 0.18（settings.rs:617），
  UI 滑块下限 0.0（SettingsView.swift:246）。
- LLM 管线：`core/core/src/pipeline.rs:230` 起用 `settings.active_post_process_provider()`
  + `post_process_api_keys` + `post_process_models`，经
  `llm_client::send_chat_completion_with_schema` 发结构化输出请求。

---

## 五、设计

### 5.1 触发时机：只在发送后结算

`observe()` 的结算条件改为**仅以下三种**（任一命中即结算并学习）：

1. **字段清空**：`focused.text.trim().is_empty()`（聊天类发送后清空）。
2. **焦点丢失**：字段此前可读、之后连续 `FOCUS_LOST_POLLS`（10 次 = 2s）
   读不到焦点文本（网页提交跳页、点走焦点）。
3. **前台 app 变化**：`frontmost_bundle_id` 与粘贴时不同（等价于焦点丢失）。

**不再结算**（改为只记诊断、不学）：

- 字段静默 `SETTLE`：删除该分支（watcher.rs:250-271）。
- 45s 超时：`report.outcome = "timeout"`，返回空候选。
- 被更新的听写取代 / 设置被关 / 安全输入激活：返回空候选，不学。

结算时用现有 `decide(&observed, pasted, &mut report)` 从捕获到的状态里挑最终文本；
`final == pasted` 则不学。

> 取舍（已与用户确认）：点走焦点但没发送也会结算学习。可用弹窗的「撤销」退回，
> 并在撤销后把误听文本写入拒绝名单（现有 `undo_last_learning` 行为）。

> 已知局限：少数 app 发送后既不清空、也不失焦、前台也不变，则不会学习。可接受。

### 5.2 LLM 判定 + 本地回退

结算拿到 `(pasted, final)` 后：

```
match llm::detect_corrections(pasted, final) {
    Some(candidates) => candidates,          // 信任 LLM：空就是「不学」，不再跑本地
    None             => diff::detect_edits(pasted, final)  // LLM 不可用/失败 → 本地
                          .filter(diff::is_likely_mishearing) // 只听错才学
                          .filter(...)                        // 复用 usable_candidates
}
```

- **可用条件**：`learn_from_edits` 开、active provider 有 key、有 model。
  任一不满足 → 返回 `None`（回退本地）。
- **请求**：复用 `llm_client::send_chat_completion_with_schema`；provider 支持结构化输出时
  走 JSON schema，否则走普通 chat completion 再解析 JSON。system 提示词要求
  「只抽取**识别听错**（同音/近音误听）的词/术语；明确排除用户改主意、改措辞、
  改意思的情况；忽略改写、标点、语序、空格；没有听错就返回空数组」，
  并给出反例：把「今天早上」改成「今天晚上」是改意思，**不是**听错，不得学习。
  输出 `[{"pattern": "...", "replacement": "..."}]`。
- **校验**：pattern/replacement 非空、互不相同、长度在 `MAX_SPAN_CHARS` 内；
  丢弃含换行的项。校验后最多取 `MAX_CANDIDATES`（5）条。
- **回退**：无 key/model、provider 是 shell 侧专属（如 Apple Intelligence，core 不可达）、
  网络错、非 2xx、JSON 解析失败 → 一律返回 `None`，回退本地。
- **超时**：沿用 `llm_client` 现有超时；学词是后台线程，不阻塞 UI。
- 学到后仍走现有 `learn()`、`learned-correction`、`learned-overlay`、撤销路径。
- **隐私**：仅当用户已配置 provider + key 时，才把 `pasted` 与 `final` 两段文本
  直连发给该 provider；否则纯本地。不新增任何我方服务器。

新增文件：`core/core/src/learning/llm.rs`（仅 macOS 编译，或在 watcher 内私有模块）。
其接口只依赖 `settings` + `llm_client`，纯函数可单测（用可注入的「发送器」便于测试）。

### 5.3 本地回退：只听错才学

没有 provider/key（或 LLM 失败）时回退本地，但**加相似度门槛**，宁可少学、不学错。
在 `diff.rs` 内新增 `pub fn is_likely_mishearing(pattern, replacement) -> bool`：

- **ASCII↔ASCII**：对 `build_match_key` 归一化（仅 alnum、小写）后算归一化
  Levenshtein 距离，`≤ LEARN_SIMILARITY_THRESHOLD`（0.6）才算听错。
  - `c3xo→cicaexo` = 0.571 → 学（听错）；`ship→hold` = 1.0 → 不学（改意思）。
- **CJK↔CJK**：要求共同字（多重集交集）占比 ≥ `LEARN_CJK_OVERLAP`（0.5）。
  - `浏览起→浏览器` = 2/3 → 学；`要喝牛奶→想喝咖啡` = 1/4 → 不学（改意思）。
- **跨语言（CJK↔ASCII，任一方向）**：视为听错（识别把英文听成中文或反之），学习。
  - `嗨桌飞手→Hydra Facial` → 学。
- 其它（空、完全相同的归一化）→ 不学。

同时：`MIN_CJK_SPAN_CHARS` 由 1 改为 2（单个汉字不再学，交给 LLM 路径）。
不做「扩到标点边界」——无标点的中文句子里会把整个短句当词学（已知回归，已否决）。

- 已知局限：本地无分词，CJK↔CJK 多字仍可能学到短短语；LLM 路径下此分支不生效。

### 5.4 弹窗位置与时机

- `OverlayPanel.swift` 的 `learned-overlay` 分支**不再传 `near:`**，
  用与录音悬浮窗相同的默认定位（`reposition(panel, near: nil)`：
  指针所在屏幕顶部居中）。core 仍可继续发 `frame` 供诊断，但 shell 不用它定位。
- 时机：清空/失焦结算后立即 `show`；LLM 的 1–3s 直接等待结果，不额外加状态。
- 尺寸/圆角沿用 `Theme.Overlay.cardSize` / `cardRadius`（不缩小成 pill），
  视觉上「替代」录音悬浮窗。

### 5.5 阈值滑块

- `SettingsView.swift:246` 滑块下限 `0.0...1.0` → `0.01...1.0`，
  避免用户拖成「只接受完全匹配」而误以为功能坏了。
- 默认 0.18 已在阶段 11 还原；本次不改默认值，请用户真机验证。

---

## 六、数据流

```
热键 → dictation → 粘贴文本 → watch_for_edit(pasted)
  ↓ 轮询 45s（200ms）
字段清空 / 焦点丢失 2s / 前台变化
  ↓ decide(observed, pasted) → final
final == pasted ? 不学
  ↓
llm::detect_corrections(pasted, final)
  ├─ Some(cands) → cands
  └─ None        → diff::detect_edits(pasted, final)
                     .filter(diff::is_likely_mishearing)   // 只听错才学
  ↓ learn(store, cands) → 加词典词
  ↓ emit learned-correction + learned-overlay{notice, frame}
  ↓ Swift: OverlayController.show(.learned, near: nil)  // 与录音悬浮窗同位
```

---

## 七、错误处理

- AX 不可读、Secure Input、被禁 app：静默不学，不报错（沿用现状）。
- LLM 任何失败：回退本地；本地也无候选则不学。
- 写词典失败：跳过该条（沿用现状）。
- 撤销：`undo_last_dictionary_learning` 删词 + 记拒绝名单（沿用现状）。

---

## 八、测试与验收

**单元测试（core）**

- watcher：字段清空结算；焦点连续 2s 不可读结算；静默 5s **不**结算；
  45s 超时 **不**学；`final == pasted` 不学。
- llm：解析合法 JSON；空数组 → 学 0 条且不触发本地；非法 JSON / 无 key → `None`（回退）。
- diff 听错门槛：`c3xo→cicaexo`（0.571）学；`ship→hold`（1.0）不学；
  `浏览起→浏览器` 学；`要喝牛奶→想喝咖啡` 不学；`嗨桌飞手→Hydra Facial`（跨语言）学；
  单个汉字（`早→晚`）不再作为候选。

**手动验收（用户真机）**

1. 聊天输入框：听写 → 改词 → 回车发送 → 立刻弹窗，位置与录音悬浮窗一致。
2. 弹窗「撤销」→ 词消失、误听进拒绝名单。
3. 改了词但停住不发（焦点仍在）→ **不**弹窗、不学习。
4. **改意思不学**：把「今天早上我要喝牛奶」改成「今天晚上我要喝牛奶」→ 不学习。
5. 配好 DeepSeek key 时走 LLM；清空 key 后走本地，均能学到词。
6. 阈值 0.18 下，学到的词能纠正下一次近似听错。

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

1. watcher 触发/结算重构 + 单测（不涉及 LLM，可独立验证）。
2. `diff.rs` 听错门槛 `is_likely_mishearing` + `MIN_CJK_SPAN_CHARS`=2 + 单测。
3. `learning/llm.rs` + 提示词 + 校验 + 单测；接入 watcher 的 LLM→本地回退。
4. `OverlayPanel.swift` learned 定位改为默认位置。
5. `SettingsView.swift` 阈值滑块下限 0.01。
6. 更新 `diagnose_edit_learning` 的 outcome / 来源（llm / local）文案。
7. 跑全部测试 + 构建；交用户真机验收。

---

## 十、风险与取舍

- **焦点丢失含「点走未发送」**：会多学，但有撤销兜底。已确认接受。
- **LLM 增加一次网络请求**：仅在发送后触发，且需用户显式配 key；不配则纯本地。
- **本地门槛会漏学**：无 key 时，本地判不出的真听错（如部分跨语言/多字）会被跳过；
  这是「宁可少学、不学错」的取舍，LLM 路径是主路径。
- **发送后不清空/不失焦的 app**：不学习；无法可靠覆盖，接受。
