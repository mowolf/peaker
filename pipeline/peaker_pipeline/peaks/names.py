"""Readable display names.

OSM's ``name`` is in the local script ("मनास्लु", "珠穆朗玛峰 ཇོ་མོ་གླང་མ། सगरमाथा"). The peak DB's main
``name`` should be readable for most users, so it becomes the first Latin-script name available (English,
other languages, GeoNames/Wikidata names merged in), and as a last resort a transliteration. The original
local name is kept in ``names["local"]``.
"""

from __future__ import annotations

import re

from .model import Peak


def is_latin(text: str) -> bool:
    return all(ord(ch) < 0x250 or 0x1E00 <= ord(ch) <= 0x1EFF or 0x2000 <= ord(ch) <= 0x206F for ch in text)


# --- Devanagari (Nepali) → Latin -------------------------------------------------------------------------

_CONSONANTS = {
    "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "ng", "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "ny",
    "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n", "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
    "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m", "य": "y", "र": "r", "ल": "l", "व": "w", "श": "sh",
    "ष": "sh", "स": "s", "ह": "h", "ळ": "l",
}
_NUKTA = {"ड": "r", "ढ": "rh", "फ": "f", "ज": "z", "क": "q", "ख": "kh", "ग": "gh"}
_VOWELS = {"अ": "a", "आ": "a", "इ": "i", "ई": "i", "उ": "u", "ऊ": "u", "ऋ": "ri", "ए": "e", "ऐ": "ai", "ओ": "o",
           "औ": "au", "ऑ": "o"}
_MATRAS = {"ा": "a", "ि": "i", "ी": "i", "ु": "u", "ू": "u", "ृ": "ri", "े": "e", "ै": "ai", "ो": "o", "ौ": "au",
           "ॉ": "o"}
VIRAMA, NUKTA, ANUSVARA, CHANDRABINDU, VISARGA = "्", "़", "ं", "ँ", "ः"
_DIGITS = {chr(0x0966 + i): str(i) for i in range(10)}


def transliterate_devanagari(text: str) -> str:
    """Simplified Nepali romanisation: inherent 'a', final 'a' dropped unless the word ends in a cluster.

    मनास्लु → Manaslu, गौरीशंकर → Gaurishankar, लाङटाङ लिरुङ → Langtang Lirung, अन्नपूर्ण → Annapurna.
    Medial vowel deletion isn't modelled (Nepali is inconsistent: Sagarmatha but Pokhara), so सगरमाथा
    comes out as "Sagaramatha": readable, if not the usual spelling. It's only a last resort anyway.
    """
    words = []
    for word in re.split(r"\s+", text.strip()):
        out = []
        i, n = 0, len(word)
        while i < n:
            ch = word[i]
            if ch in _CONSONANTS:
                base = _CONSONANTS[ch]
                j = i + 1
                if j < n and word[j] == NUKTA:
                    base = _NUKTA.get(ch, base)
                    j += 1
                nxt = word[j] if j < n else ""
                if nxt == VIRAMA:
                    out.append(base)
                    j += 1
                elif nxt in _MATRAS:
                    out.append(base + _MATRAS[nxt])
                    j += 1
                elif ch == "ङ":
                    out.append(base)  # ng never carries the inherent vowel in Nepali names ("Langtang")
                else:
                    is_final = j >= n or not ("ऀ" <= word[j] <= "ॿ") or word[j] in (ANUSVARA, CHANDRABINDU)
                    after_cluster = i >= 1 and word[i - 1] == VIRAMA
                    # Nepali drops the final inherent vowel ("Langtang"), except after a cluster ("Annapurna").
                    if is_final and word[j:j + 1] not in (ANUSVARA, CHANDRABINDU) and not after_cluster and len(out) > 0:
                        out.append(base)
                    else:
                        out.append(base + "a")
                i = j
            elif ch in _VOWELS:
                out.append(_VOWELS[ch])
                i += 1
            elif ch == ANUSVARA:
                nxt = word[i + 1] if i + 1 < n else ""
                out.append("m" if nxt in ("प", "फ", "ब", "भ", "म") else "n")
                i += 1
            elif ch == CHANDRABINDU:
                out.append("n")
                i += 1
            elif ch == VISARGA:
                out.append("h")
                i += 1
            elif ch in _DIGITS:
                out.append(_DIGITS[ch])
                i += 1
            elif ch in ("।", "॥"):
                i += 1
            else:
                out.append(ch)
                i += 1
        w = "".join(out)
        if w:
            words.append(w[0].upper() + w[1:])
    return " ".join(words)


def transliterate(text: str) -> str:
    if any("ऀ" <= ch <= "ॿ" for ch in text):
        # Mixed names ("मकालु 马卡鲁峰"): keep the Devanagari part, which is usually the Nepali name.
        dev = " ".join(w for w in text.split() if any("ऀ" <= ch <= "ॿ" for ch in w))
        return transliterate_devanagari(dev)
    from anyascii import anyascii

    return re.sub(r"\s+", " ", anyascii(text)).strip(" ,.-")


def choose_display_name(p: Peak) -> tuple[str, str | None]:
    """(display name, original local name if it was replaced)."""
    local = p.name or ""
    if local and is_latin(local):
        return local, None
    candidates = [p.names.get("en"), p.names.get("int")]
    candidates += [p.names[k] for k in sorted(p.names) if k not in ("en", "int", "local")]
    candidates += p.alt_names
    for c in candidates:
        if c and is_latin(c):
            return c, local or None
    if local:
        return transliterate(local) or local, local
    return local, None
