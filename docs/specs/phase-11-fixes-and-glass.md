# 阶段 11：修功能缺口 + 液态玻璃

> 来源：用户 2026-09-17 反馈（`继续修改：_副本.md` + 3 张截图）。
> 前置：阶段 10 已完成（收尾 + UI token）。

## 目标

1. **修好四个功能性缺口**（前三个是回归 bug，根因已定位）。
2. **悬浮窗重做**：液态玻璃 + 中心震荡波形 + 悬停双按键（去掉取消键）。
3. **设置页控件修正**：历史上限、词汇修正阈值、快捷键自定义。
4. **整体 UI**：Apple 原生风格 + 液态玻璃。

## 根因（已核实）

| # | 现象 | 根因 |
|---|---|---|
| 1 | 概览数据不涨 | `core/core/src/dictation.rs::stop` **从不写历史**（不存 WAV、不调 `save_entry`） |
| 2 | 资料库不更新、听不了录音 | 同上（没有新条目）；且 Swift 侧没有播放 UI |
| 3 | 自动学词完全失效 | core 的 `learning::watch_for_edit` 存在，但 Swift 粘贴后**从不调用** |
| 4 | 录音时重新转录会打架 | 没有「忙」保护，`retry_history_entry_transcription` 可与录音并行 |
| 6 | 快捷键不能自己绑 | 只有 `get_bindings`，**没有 `set_binding`**；Swift 只读展示 |

另外两个设置项是**实现错误**（不只是样式）：

- `word_correction_threshold` 是 **0.0–1.0 的 f64**（默认 0.18），我实现成了整数 ms 输入框 →
  截图里显示「0 ms」，实际写坏了这个设置。旧版是 0–1 滑块。
- `hold_threshold_ms` 旧版是 **100–1000 / step 50 滑块**（默认 300），我实现成了固定值下拉。

## 范围

### A. 修功能缺口

**A1 录音 + 历史（修 #1 #2）**
- `dictation::stop` 保存 WAV 到 `recordings_dir/handy-<ts>.wav`（`wav::save_wav_file` + `verify_wav_file`），
  然后 `history.save_entry(file_name, transcription, true, post_processed_text, prompt,
  duration_ms, char_count, workflow)`。
- 发出 `history-update-payload`，概览与资料库自动刷新。
- 保存失败只记日志，不影响粘贴。

**A2 自动学词（修 #3）**
- 新增 FFI `watch_for_edit`（传粘贴的文本），Swift 在 `Paster.paste` 成功后调用。
- 需要 core 的 `learning::watch_for_edit` 可经 FFI 调用。

**A3 忙保护（修 #4）**
- core 维护「听写进行中」状态（start → busy，stop/cancel → idle）。
- 忙时 `retry_history_entry_transcription` 等耗时命令直接返回错误
  `"a dictation is in progress"`。
- Swift 捕获后弹提示：「当前正在转录，请完成当前转录，再去做其他的事情。」

**A4 快捷键自定义（修 #6）**
- 新增 FFI `set_binding(bindingId, hotkey)` / `reset_binding(bindingId)`。
- Swift 新增录制控件：点击 → 「请按键…」→ 捕获组合键 → 保存 → 重启热键监听。

### B. 设置页控件修正

- `history_limit`：改成与其它行对齐的 `Stepper`（0–1000）。
- `word_correction_threshold`：0.0–1.0 滑块（显示百分比）。
- `hold_threshold_ms`：100–1000 / step 50 滑块。

### C. 悬浮窗（Spokenly 式）

- **液态玻璃**：`.glassEffect(.regular, in:)`，去掉多余填充/边框/阴影（"玻璃即表面"）。
- **波形从中心震荡**：以垂直中线为轴上下对称生长，而不是从底部/前端。
- **去掉常驻取消键**；**鼠标悬停**时：面板变暗 → 显示两个按键
  - ✕ 结束录音（停止并丢弃）
  - ✓ 完成录音（停止并粘贴）
- 悬停状态需要 `NSTrackingArea`。

### D. 整体 UI

- 加载 `frontend-design` / `frontend-ui-engineering` skills 的准则：
  - 全部走系统控件与系统语义色，无自造花哨控件
  - 间距/字号一律取自 `Theme.swift`
  - 交互状态齐全（hover / disabled / 空状态 / 错误状态）
  - 键盘可达、无障碍标签完整
- 窗口与侧栏用系统材质；内容卡片视情况用玻璃（克制，避免"到处玻璃"）。

## 非目标

- 不引入新依赖/UI 框架。
- 不改 ASR / LLM / 词典算法。
- 不做签名/公证/自动更新。

## 验收标准

1. 说一句话 → 概览今日数字 +1、资料库出现新条目、录音可播放。
2. 说错一个词并改掉 → 词典自动多出该词（可撤销）。
3. 录音过程中点「重新转录」→ 弹提示，不执行。
4. 设置里能把听写/翻译/取消快捷键重新绑定，立即生效（不用重启）。
5. 悬浮窗：玻璃通透、波形从中心震荡、悬停出现两个按键、取消键消失。
6. 历史上限/词汇修正阈值/按住阈值都是合适的控件且与其它行对齐。
7. `cargo test` / `cargo fmt --check` / `check_translations.py` / Xcode BUILD 全绿；真机冒烟。

## 任务拆分

- [x] **T1** core：`stop` 存 WAV + 历史 — 完成。单测
      `a_completed_run_is_saved_to_history` 断言录音落盘 + 历史字段（时长/字数/workflow）
- [x] **T2** FFI + Swift：粘贴后 `watch_for_edit` — 完成。**还发现第二个 bug**：
      `init_learning_state()` 从来没人调用，学词状态根本不存在。真机 TextEdit 端到端验证：
      `outcome: learned`、`36/36 readable`、候选 `起 → 器`、词典 6→7；撤销也验证通过
      （词被删 + 误听文本进拒绝名单）
- [x] **T3** core + Swift：忙保护 + 提示 — 完成。真机验证录音中 `retry_history_entry_transcription`
      / `unload_model` / `retry_last_translation` 全部返回 `busy:`，空闲后放行
- [x] **T4** FFI + Swift：快捷键录制 — 完成。`set_binding` / `reset_binding` / `build_binding`；
      Swift 录制控件（录制时暂停热键监听，避免自己的绑定被触发）；真机录制 `cmd+shift+k` 成功
- [x] **T5** 设置控件修正 — 完成。历史上限改 `Stepper`、词汇修正阈值改 0–1 滑块（显示百分比）、
      按住阈值改 100–1000 滑块。**顺带修了一个我引入的 bug**：阈值原本被整数输入框写成了 `0.0`，
      已还原为默认 `0.18`
- [x] **T6** 悬浮窗重做 — 完成。波形镜像到中心（最响的桶在中间、向两侧衰减）、
      去掉常驻取消键、悬停变暗 + 双按键（✕ 丢弃 / ✓ 完成并输入）
- [x] **T7** 资料库录音播放 — 完成。`RecordingPlayer` + 每行播放/停止按钮
- [x] **T8** 设置导航改成顶部胶囊分段 — 完成（用户选定方案）
- [x] **T9** 全量验证 — core 288 / ffi 6 通过、fmt 绿、25 语言包通过、
      Swift 246 个 i18n 键全部存在、Xcode BUILD SUCCEEDED

## 决策记录

1. 设置二级菜单：**改成顶部胶囊分段**（用户 2026-09-17 选定）。
2. 悬浮窗两个按键：**✕ 丢弃 / ✓ 完成并输入**（用户确认）。

## 真机验证清单

| 项 | 结果 |
|---|---|
| 历史保存 | 单测覆盖（录音落盘 + 字段正确） |
| 自动学词 | TextEdit 端到端：学到 + 撤销 + 拒绝名单 |
| 忙保护 | 录音中三条命令全部拒绝 |
| 快捷键录制 | 录制 `cmd+shift+k` 并写回设置 |
| 悬浮窗 | 正常态无取消键、悬停态双按键（截图确认） |
| 录音播放 | 点击变「停止播放」、无错误 |
| 设置导航 | 顶部胶囊分段（截图确认） |

## 待确认

1. **设置二级菜单「太长」**：截图里是二级列表（通用…关于）+ 很长的内容区。你想要的是
   ① 把二级菜单合并进主导航（设置项直接在左侧栏展开）
   ② 二级菜单改成顶部胶囊分段
   ③ 缩短内容（把调试/关于拆到别处）
2. **悬浮窗两个按键的语义**：✕ = 结束并**丢弃**、✓ = 结束并**粘贴**，对吗？
