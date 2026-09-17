# TalkWTF

个人自用的 macOS 语音听写 app。按住快捷键说话，松开后**转录 + AI 润色**，结果直接输入到当前输入框。

- **本地 ASR**：转录在你自己的 Mac 上完成（transcribe.cpp + Qwen3-ASR），音频不出本机。
- **BYOK 润色**：AI 润色走你自己填的 API key，直连服务商（DeepSeek / OpenAI / Anthropic / OpenRouter / Groq / 自填 OpenAI 兼容地址）。
- **无自建云**：没有账号、没有订阅、没有遥测。除你显式配置的 provider 外，App 不联网。

不分发、不上架，个人使用。

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

MIT（继承自 [Handy](https://github.com/cjpais/Handy)）。功能设计参考 [OpenTypeless](https://github.com/tover0314-w/opentypeless)（MIT），只移植逻辑与 UX，不含其云端/账号部分。
