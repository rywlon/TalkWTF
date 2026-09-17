# 翻译

TalkWTF 有 26 个语言包，加语言只需要动两处：JSON 语言包 + Swift 语言表。

## 步骤概览

1. 复制英文语言包到新语言目录
2. 翻译**值**（不是键）
3. 在 `macos/TalkWTF/Languages.swift` 登记
4. 跑 `python3 scripts/check_translations.py`

## File Structure

Translation files are located in:

```
resources/locales/
├── en/
│   └── translation.json    # English (source)
├── vi/
│   └── translation.json    # Vietnamese
├── fr/
│   └── translation.json    # French
└── [your-language]/
    └── translation.json    # Your contribution!
```

## Adding a New Language

### Step 1: Create the Language Folder

Create a new folder using the [ISO 639-1 language code](https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes):

```bash
mkdir resources/locales/[language-code]
```

Examples:

- `de` for German
- `es` for Spanish
- `ja` for Japanese
- `zh` for Chinese
- `ko` for Korean
- `pt` for Portuguese

### Step 2: Copy the English File

```bash
cp resources/locales/en/translation.json resources/locales/[language-code]/translation.json
```

### Step 3: Translate the Values

Open the file and translate only the **values** (right side), not the keys (left side):

```json
{
  "sidebar": {
    "general": "General",      // ← Translate this value
    "advanced": "Advanced",    // ← Translate this value
    ...
  }
}
```

**Important:**

- Keep all keys exactly the same
- Preserve any `{{variables}}` in the text (e.g., `{{error}}`, `{{model}}`)
- Keep the JSON structure and formatting intact

### Step 4: Register Your Language

在 `macos/TalkWTF/Languages.swift` 的 `Languages.all` 里加一行（`priority` 越小越靠前）：

```swift
Language(code: "de", name: "German", nativeName: "Deutsch", rtl: false),
```

`name` 是英文名，`nativeName` 是语言自己的写法（设置里的下拉就显示这个）。RTL 语言（阿拉伯语、希伯来语）把 `rtl` 设为 `true`。

### Step 5: Test Your Translation

1. 构建并运行：见 [BUILD.md](BUILD.md)
2. 设置 → 通用 → 应用语言
3. 选你的语言，检查显示是否正常

### Step 6: 提交

```bash
python3 scripts/check_translations.py   # 必须先通过
```
3. Open a pull request with:
   - Language name in the title (e.g., "Add German translation")
   - Any notes about the translation

## Improving Existing Translations

Found a typo or better translation?

1. Edit the relevant `translation.json` file
2. Submit a PR with a brief description of the change

## Translation Guidelines

### Do:

- Use natural, native-sounding language
- Keep translations concise (UI space is limited)
- Match the tone of the English text (friendly, clear)
- Preserve technical terms when appropriate (e.g., "API", "GPU")

### Don't:

- Translate brand names (Handy, transcribe.cpp, ggml, OpenAI)
- Change or remove `{{variables}}`
- Modify JSON keys
- Add extra spaces or formatting

### Handling Variables

Some strings contain variables like `{{error}}` or `{{model}}`. Keep these exactly as-is:

```json
// English
"downloadModel": "Failed to download model: {{error}}"

// French (correct)
"downloadModel": "Échec du téléchargement du modèle : {{error}}"

// French (incorrect - don't translate the variable!)
"downloadModel": "Échec du téléchargement du modèle : {{erreur}}"
```

### Handling Plurals

Some languages have complex plural rules. For now, use a general form that works for all cases. We may add proper plural support in the future.

## Questions?

- Open an issue on GitHub
- Join the discussion in existing translation PRs

## Currently Supported Languages

| Language   | Code | Status            |
| ---------- | ---- | ----------------- |
| English    | `en` | Complete (source) |
| Catalan    | `ca` | Complete          |
| Chinese    | `zh` | Complete          |
| French     | `fr` | Complete          |
| German     | `de` | Complete          |
| Japanese   | `ja` | Complete          |
| Spanish    | `es` | Complete          |
| Vietnamese | `vi` | Complete          |

## Requested Languages

We'd love help with:

- Korean (`ko`)
- Portuguese (`pt`)
- And more!

---

Thank you for making Handy accessible to more people around the world!
