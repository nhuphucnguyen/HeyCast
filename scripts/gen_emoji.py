#!/usr/bin/env python3
"""Generate emoji.json for SwiftCast from Unicode character data.

Emits a JSON array of {"c": "<emoji>", "n": "<lowercase name>"} for
single-codepoint emoji across the common emoji blocks. Rerun to refresh.
"""

import json
import sys
import unicodedata

BLOCKS = [
    (0x2600, 0x27BF),   # Misc symbols + dingbats (☀ ✂ ✅ ...)
    (0x2B00, 0x2B5F),   # arrows/stars (⭐ ⭑)
    (0x1F10D, 0x1F10F),
    (0x1F16D, 0x1F171),
    (0x1F200, 0x1F2FF), # enclosed ideographs (🈯)
    (0x1F300, 0x1F5FF), # misc symbols and pictographs
    (0x1F600, 0x1F64F), # emoticons
    (0x1F680, 0x1F6FF), # transport and map
    (0x1F77F, 0x1F7FF), # geometric shapes extended (mostly emoji)
    (0x1F900, 0x1F9FF), # supplemental symbols
    (0x1FA00, 0x1FAFF), # symbols extended-A
    (0x1FBF0, 0x1FBF9), # digit keys
]

SKIP = set(range(0x1F3FB, 0x1F400))  # skin tone swatches
NO_VS16 = False

def clean_name(name: str) -> str:
    n = name.lower()
    for drop in (" sign", " symbol"):
        if n.endswith(drop):
            n = n[: -len(drop)]
    return n

out = []
for lo, hi in BLOCKS:
    for cp in range(lo, hi + 1):
        if cp in SKIP:
            continue
        ch = chr(cp)
        try:
            name = unicodedata.name(ch)
        except ValueError:
            continue
        cat = unicodedata.category(ch)
        if cat not in ("So", "Sk"):
            continue
        rendered = ch + "\uFE0F" if (0x2600 <= cp <= 0x27BF or 0x2B00 <= cp <= 0x2B5F) else ch
        # Verify the sequence renders as a distinct glyph we can keep; keep all.
        out.append({"c": rendered, "n": clean_name(name)})

out.sort(key=lambda e: e["n"])
with open(sys.argv[1] if len(sys.argv) > 1 else "emoji.json", "w") as f:
    json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
print(f"wrote {len(out)} emojis")
