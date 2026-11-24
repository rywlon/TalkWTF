# TalkWTF (Web Edition)

A browser-based web port of **TalkWTF** built with React, TypeScript, Vite, and Tailwind CSS — preserving TalkWTF's Apple HIG interface, Voice to Agent workflow, AI polishing styles & scenes, voice translation, personal dictionary, and floating Liquid Glass recording overlay.

## Core Features

- **Dashboard (概览)**: Voice dictation & translation entry card, customizable keyboard shortcuts (`Alt+Space` / `Alt+Shift+Space`), today's statistics, recent activity, and service status.
- **Voice to Agent**: Pair local Agent conversations (Codex, Claude Code, OpenCode, Cursor, or custom adapters) via expiring connection prompts, assign per-agent shortcuts, and deliver voice instructions with recoverable failure handling.
- **Library (资料库)**:
  - **History**: Search, sort, inspect polished vs. raw transcript, copy, re-polish, and delete entries.
  - **Dictionary**: Manage custom vocabulary words, toggleable correction rules (`pattern → replacement`), JSON import/export, and auto-learn exclusion list.
- **Floating Liquid Glass Overlay**: Top/bottom-anchored frosted glass pill with 18-bar centered audio waveform, hover-to-reveal Finish/Discard controls, and all 8 state views (recording, streaming, transcribing, processing, translating, learned with Undo, translation failed with Retry, and notices).
- **Settings (设置)**: General (bilingual Chinese/English, system/light/dark theme, recognition language, shortcuts), Personalization (BYOK provider config, polish styles, 7 built-in + custom scenes, up to 3 translation targets), ASR Models catalog, Browser Audio device selection & sound chimes, Advanced options, Debug overlay preview & keyboard diagnostics, and About.

## Development

```sh
npm install
npm run dev
```

The development server runs on `http://0.0.0.0:3000`.

## Notes on Web Migration

- Native macOS Accessibility auto-paste, global OS-level hotkeys outside the browser tab, and local GGUF/ONNX native inference are replaced with Web Speech API + Web Audio API recording, in-app keyboard shortcuts, local deterministic polishing/dictionary rules, and `localStorage` persistence.
- See `.env.example` for optional external provider environment variables.
