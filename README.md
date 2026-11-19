# TalkWTF — Words That Flow

**Words That Flow，让表达自然流畅。**

基于 [Handy](https://github.com/cjpais/Handy) 二次开发的开源 macOS 语音听写 app。按住快捷键说话，松开后**转录 + AI 润色**，结果直接输入到当前输入框。

- **本地 ASR**：转录在你自己的 Mac 上完成（transcribe.cpp + Qwen3-ASR），音频不出本机。
- **BYOK 润色**：AI 润色走你自己填的 API key，直连服务商（DeepSeek / OpenAI / Anthropic / OpenRouter / Groq / 自填 OpenAI 兼容地址）。
- **无自建云**：没有自建账号、订阅或遥测服务。模型下载需要联网；启用 AI 润色或翻译时，文本会发送至你配置的服务商。

目前以个人日常使用为主，公开源码供学习与改进；尚未作为面向大众的稳定产品维护。支持 Apple Silicon Mac、macOS 14+，不提供 Windows 版本。

## 从 Handy 到 TalkWTF

项目保留 Handy 的本地语音识别基础，扩展 AI 润色、多语言翻译、场景配置、个性化词典与自动纠错学习，整合历史检索、录音管理及本地使用统计，覆盖从语音输入到文本处理与个性化积累的完整流程。界面重构为原生 SwiftUI，核心逻辑保留在 Rust 中。

开发采用 AI 辅助：将需求拆为阶段目标、功能边界和验收标准，再根据实际使用反馈推进热键、悬浮窗、失败回退与安装打包。需求取舍、使用反馈和迭代记录见 `docs/specs/`。

功能选择以日常使用收益和隐私成本为依据。例如，项目放弃了需要窗口标题、浏览器地址等上下文才能发挥价值的应用感知润色，优先完善场景配置、词典纠错与自动学词。

本地开发提交从 2026 年 9 月保留至今；本次公开发布未重写原始提交日期。TalkWTF 与 Typeless 无隶属关系。

## 隐私边界

- 语音识别在本机执行；下载所需模型时会访问模型托管服务。
- 云端润色/翻译会向所选服务商发送转录文本，以及该请求所需的词典、场景等提示内容；由服务商的政策决定其处理方式。
- 自动学词需要辅助功能权限，会在听写后观察目标输入框的修改；历史记录与录音有本地留存设置。请按自己的需求配置。
- 本项目尚未经过独立安全审计，不将“本地优先”等同于“所有功能完全离线”。

## 快速开始

1. 按 [BUILD.md](BUILD.md) 安装 Xcode、Rust 并从源码构建。
2. 启动后授予麦克风权限；回填文本和自动学词需要辅助功能权限。
3. 在模型设置中下载本地识别模型；如需 AI 润色/翻译，再配置自己的服务商与 API key。
4. 设置快捷键后即可听写。应用未做 Apple 公证，目前建议有开发经验的用户自行构建。

## 架构

```
macos/TalkWTF.xcodeproj     原生 SwiftUI app（窗口 / 设置 / 悬浮窗 / 托盘 / 热键 / 粘贴）
        │  C FFI（JSON invoke + 事件回调）
        ▼
core/ffi                     talkwtf-ffi：staticlib + talkwtf.h
        │
        ▼
core/core                    talkwtf-core：全部引擎逻辑，零 Tauri 依赖
                             （设置 / 词典 / 历史 / 模型 / 音频 / ASR / LLM / 润色 / 翻译 / 学词 / Dashboard）
resources/                   随 app 打包的资源（模型元数据、VAD 模型、提示音、26 个语言包）
scripts/                     维护脚本（翻译一致性检查、模型目录生成/镜像）
docs/specs/                  各阶段 spec 与实现记录
```

- 没有 Tauri，没有 React，没有 webview。SwiftUI 直接调 Rust。
- 设置、词典、历史的数据格式沿用旧版（`~/Library/Application Support/com.pais.handy/`），老数据可直接读。

## 构建

见 [BUILD.md](BUILD.md)。

## 功能

- 听写（转录 + 润色，一个动作；润色失败自动降级为原始转录）
- 自动翻译：独立 Translate 工作流，目标语言最多 3 个
- 润色风格 + 场景（内置 / 自定义 / 导入导出）
- 词典：词汇 + 纠正规则，导入导出
- 自动学词：听写后读取刚输入的输入框，把你改掉的错词学进词典（可撤销，拒绝名单可管理）
- 历史：搜索、复制、删除、录音留存策略
- Dashboard：活动 / 时长 / 字数 / 速度 / 节省时间 / 个性化程度 / 服务状态 / LLM token
- 原生悬浮窗（Liquid Glass）、托盘、三种按键模式、26 个语言

## 许可

MIT（继承自 [Handy](https://github.com/cjpais/Handy)）。部分逻辑与 UX 移植自 [OpenTypeless](https://github.com/tover0314-w/opentypeless)（MIT），不含其云端/账号部分。相关许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。语音模型及第三方依赖分别遵循各自许可。
