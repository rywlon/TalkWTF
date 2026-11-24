#!/usr/bin/env python3
"""Check that every locale has the same key set as the reference language.

Ported from the old `scripts/check-translations.ts` so the repo needs no Node
toolchain. Run from anywhere: `python3 scripts/check_translations.py`.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

LOCALES_DIR = Path(__file__).resolve().parent.parent / "resources" / "locales"
REFERENCE_LANG = "en"

RESET = "\x1b[0m"
RED = "\x1b[31m"
GREEN = "\x1b[32m"
YELLOW = "\x1b[33m"
BLUE = "\x1b[34m"


def colorize(text: str, color: str) -> str:
    return f"{color}{text}{RESET}"


def key_paths(obj: object, prefix: tuple[str, ...] = ()) -> list[tuple[str, ...]]:
    """Every leaf key path in `obj` (dicts recurse, everything else is a leaf)."""
    paths: list[tuple[str, ...]] = []
    if not isinstance(obj, dict):
        return paths
    for key, value in obj.items():
        current = prefix + (key,)
        if isinstance(value, dict):
            paths.extend(key_paths(value, current))
        else:
            paths.append(current)
    return paths


def has_key_path(obj: object, path: tuple[str, ...]) -> bool:
    current = obj
    for key in path:
        if not isinstance(current, dict) or key not in current:
            return False
        current = current[key]
    return True


def load(lang: str) -> dict | None:
    path = LOCALES_DIR / lang / "translation.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:  # noqa: BLE001 - report and continue
        print(colorize(f"✗ Error loading {lang}/translation.json:", RED))
        print(f"  {error}")
        return None


def main() -> int:
    print(colorize("\n🌍 Translation Consistency Check\n", BLUE))

    if not LOCALES_DIR.is_dir():
        print(colorize(f"✗ Locales directory not found: {LOCALES_DIR}", RED))
        return 1

    languages = sorted(
        entry.name
        for entry in LOCALES_DIR.iterdir()
        if entry.is_dir() and entry.name != REFERENCE_LANG
    )

    print(f"Loading reference language: {REFERENCE_LANG}")
    reference = load(REFERENCE_LANG)
    if reference is None:
        print(colorize(f"\n✗ Failed to load reference file ({REFERENCE_LANG})", RED))
        return 1

    reference_paths = key_paths(reference)
    print(f"Reference has {len(reference_paths)} keys\n")

    has_errors = False
    results: dict[str, tuple[list[tuple[str, ...]], list[tuple[str, ...]]]] = {}

    for lang in languages:
        data = load(lang)
        if data is None:
            has_errors = True
            results[lang] = ([], [])
            continue

        missing = [path for path in reference_paths if not has_key_path(data, path)]
        extra = [path for path in key_paths(data) if not has_key_path(reference, path)]
        results[lang] = (missing, extra)
        if missing or extra:
            has_errors = True

    print(colorize("Results:", BLUE))
    print("─" * 60)

    for lang in languages:
        missing, extra = results[lang]
        if not missing and not extra:
            print(colorize(f"✓ {lang.upper()}: All keys present", GREEN))
            continue

        print(colorize(f"✗ {lang.upper()}: Issues found", RED))
        if missing:
            print(colorize(f"  Missing {len(missing)} keys:", YELLOW))
            for path in missing[:10]:
                print(f"    - {'.'.join(path)}")
            if len(missing) > 10:
                print(colorize(f"    ... and {len(missing) - 10} more", YELLOW))
        if extra:
            print(colorize(f"  Extra {len(extra)} keys (not in reference):", YELLOW))
            for path in extra[:10]:
                print(f"    - {'.'.join(path)}")
            if len(extra) > 10:
                print(colorize(f"    ... and {len(extra) - 10} more", YELLOW))
        print()

    print("─" * 60)

    valid = sum(1 for missing, extra in results.values() if not missing and not extra)
    total = len(languages)

    if has_errors:
        print(colorize(f"\n✗ Validation failed: {valid}/{total} languages passed", RED))
        return 1
    print(colorize(f"\n✓ All {total} languages have complete translations!", GREEN))
    return 0


if __name__ == "__main__":
    sys.exit(main())
