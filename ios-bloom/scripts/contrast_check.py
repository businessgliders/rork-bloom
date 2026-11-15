#!/usr/bin/env python3
"""Bloom colour contrast check (WCAG 2.1).

Reads the colour tokens from Shared/Theme.swift, then prints the contrast
ratio of every text / button pairing the app uses, in light and dark mode.
Run: python3 ios-bloom/scripts/contrast_check.py
Exit code 1 when any pairing is under its minimum.
"""
import re
import sys
from pathlib import Path

THEME = Path(__file__).resolve().parent.parent / "Shared" / "Theme.swift"


def load_tokens():
    tokens = {}
    pattern = re.compile(r"static let (\w+) = Color\(light: 0x([0-9A-Fa-f]{6}), dark: 0x([0-9A-Fa-f]{6})\)")
    for name, light, dark in pattern.findall(THEME.read_text()):
        tokens[name] = {"light": light, "dark": dark}
    return tokens


def luminance(hex_):
    def channel(c):
        c = c / 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (int(hex_[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def ratio(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


WHITE = {"light": "FFFFFF", "dark": "FFFFFF"}

# (foreground, background, minimum, where it appears)
PAIRS = [
    ("text", "canvas", 4.5, "body text"),
    ("text", "surface", 4.5, "card text"),
    ("textSecondary", "canvas", 4.5, "secondary text"),
    ("textSecondary", "surface", 4.5, "secondary text on cards"),
    ("textSecondary", "surfaceMuted", 4.5, "secondary text on muted"),
    ("blushDeep", "surface", 4.5, "rose links / times"),
    ("blushDeep", "canvas", 4.5, "rose links on canvas"),
    ("blushDeep", "blushSoft", 4.5, "soft rose buttons"),
    ("sageDeep", "surface", 4.5, "Food OK text"),
    ("sageDeep", "sageSoft", 4.5, "Food OK on its tint"),
    ("coralDeep", "surface", 4.5, "No food text"),
    ("coralDeep", "coralSoft", 4.5, "No food on its tint"),
    ("peachDeep", "surface", 4.5, "peach text"),
    ("peachDeep", "peachSoft", 4.5, "peach on its tint"),
    ("toastAccent", "text", 4.5, "Undo on the dark toast"),
    ("canvas", "text", 4.5, "toast message"),
    ("WHITE", "roseButton", 4.5, "primary button"),
    ("WHITE", "peachButton", 4.5, "peach filled button"),
    ("WHITE", "sageButton", 4.5, "sage filled button"),
    ("WHITE", "coralButton", 4.5, "coral filled button"),
]


def main():
    tokens = load_tokens()
    tokens["WHITE"] = WHITE
    failed = False
    for fg, bg, minimum, where in PAIRS:
        if fg not in tokens or bg not in tokens:
            print(f"MISSING  {fg} on {bg}")
            failed = True
            continue
        for mode in ("light", "dark"):
            value = ratio(tokens[fg][mode], tokens[bg][mode])
            ok = value >= minimum
            failed |= not ok
            flag = "ok  " if ok else "FAIL"
            print(f"{flag} {mode:5} {value:5.2f}  {fg} on {bg}  ({where})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
