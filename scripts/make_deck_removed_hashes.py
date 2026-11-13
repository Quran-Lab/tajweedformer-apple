#!/usr/bin/env python3
"""Writes Tests/TajweedFormerTests/Fixtures/deck_removed/2026-11-12.1.json: for each of the eight languages, the
length in UTF-8 bytes and the SHA-256 of the sentence that copy deck 2026-11-12.1 added to `sheet.who` and to
`what.detail`, and that the deck bundled from SDK 3.1.2 (2026-11-13.1) does not have.

The sentence itself is written nowhere: a test (SharingDeckTests) slides a window of that length over the UTF-8
bytes of every text the sharing sheet is built from and fails when a window has that hash.

    python scripts/make_deck_removed_hashes.py <contract checkout>
        reads <contract>/sharing_copy/archive/2026-11-12.1/<lang>.json and <contract>/sharing_copy/<lang>.json
        and writes the data file
    python scripts/make_deck_removed_hashes.py --check <folder of deck files>
        the test's own check, over the decks in a folder: prints per language whether a string of the deck holds
        the sentence, and exits 1 when one does (the archived decks must; the bundled decks must not)

The fragment of a string: what the archived string has between the longest beginning and the longest ending it
shares with the new string, without the white space around it.
"""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Tests" / "TajweedFormerTests" / "Fixtures" / "deck_removed" / "2026-11-12.1.json"
LANGS = ["ar", "bn", "en", "fr", "id", "ms", "tr", "ur"]
KEYS = ["sheet.who", "what.detail"]


def strings(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))["strings"]


def fragment(earlier, now):
    head = 0
    while head < len(earlier) and head < len(now) and earlier[head] == now[head]:
        head += 1
    tail = 0
    while tail < len(earlier) - head and tail < len(now) - head and earlier[-1 - tail] == now[-1 - tail]:
        tail += 1
    return earlier[head:len(earlier) - tail].strip()


def texts(deck):
    """Every text of a deck's strings: a plain string, and each form of a plural line."""
    out = []
    for value in deck.values():
        if isinstance(value, str):
            out.append(value)
        elif isinstance(value, dict):
            out.extend(v for v in value.values() if isinstance(v, str))
    return out


def has_window(text, size, digest):
    data = text.encode("utf-8")
    return any(hashlib.sha256(data[i:i + size]).hexdigest() == digest for i in range(0, len(data) - size + 1))


def make(checkout):
    source = Path(checkout) / "sharing_copy"
    languages = {}
    for lang in LANGS:
        earlier = strings(source.joinpath("archive", "2026-11-12.1", f"{lang}.json"))
        now = strings(source.joinpath(f"{lang}.json"))
        differing = sorted(k for k in earlier if earlier[k] != now.get(k))
        assert differing == KEYS and set(earlier) == set(now), (lang, differing)
        entry = {}
        seen = []
        for key in KEYS:
            gone = fragment(earlier[key], now[key]).encode("utf-8")
            assert len(gone) > 10 and gone.decode("utf-8") in earlier[key] and gone.decode("utf-8") not in now[key], (lang, key)
            entry[key] = {"bytes": len(gone), "sha256": hashlib.sha256(gone).hexdigest()}
            seen.append(gone)
        languages[lang] = entry
        print(f"{lang}: {entry['sheet.who']['bytes']} and {entry['what.detail']['bytes']} bytes; "
              f"the same fragment in both: {'yes' if seen[0] == seen[1] else 'no'}")
    data = {
        "format": "quranlab.sdk-deck-removed/1",
        "about": "For each language: the length in UTF-8 bytes and the SHA-256 of the sentence that copy deck 2026-11-12.1 "
                 "added to sheet.who and to what.detail and that deck 2026-11-13.1 does not have "
                 "(scripts/make_deck_removed_hashes.py). No text the sharing sheet is built from may hold a window of "
                 "that length with that hash.",
        "deck": "2026-11-12.1",
        "languages": languages,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, indent=1, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {OUT}")


def check(folder):
    data = json.loads(OUT.read_text(encoding="utf-8"))
    found = 0
    for lang in LANGS:
        deck = strings(Path(folder) / f"{lang}.json")
        hits = []
        for key in KEYS:
            want = data["languages"][lang][key]
            if any(has_window(t, want["bytes"], want["sha256"]) for t in texts(deck)):
                hits.append(key)
        found += bool(hits)
        print(f"{lang}: " + ("HAS the sentence (the fragment of " + ", ".join(hits) + ")" if hits else "clean"))
    print(f"{found} of {len(LANGS)} languages have it")
    return 1 if found else 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        sys.exit(check(sys.argv[2]))
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    make(sys.argv[1])
