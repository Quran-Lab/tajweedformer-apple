#!/usr/bin/env python3
"""Writes docs/api.md: the public surface of the TajweedFormer Swift package, from the sources.

Every `public` declaration under Sources/TajweedFormer is listed with its signature and its doc comment, grouped
by its top-level public type, in the order of NAMING.md section 8 (the five concepts first). The cases of a public
enum are listed with it. A test (PublicSurfaceTests.testTheAPIDocListsEveryPublicDeclaration) fails when a public
declaration is missing from the file, so run this after changing the public surface:

    python scripts/make_api_doc.py            writes docs/api.md
    python scripts/make_api_doc.py --check    exits 1 when docs/api.md is not what the sources give
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "TajweedFormer"
OUT = ROOT / "docs" / "api.md"

ORDER = ["TajweedClient", "TajweedClientOptions", "TajweedModel", "TajweedSession", "TajweedSessionOptions", "TajweedHeads",
         "TajweedBackend", "TajweedChunk", "TajweedDecoded", "TajweedToken", "TajweedWord", "TajweedFrame", "TajweedHead",
         "TajweedEvent", "TajweedTokens", "TajweedCalibration", "TajweedReference", "TajweedClip", "TajweedSharing",
         "TajweedAnalytics", "TajweedDiagnosis", "TajweedError", "Microphone"]

DECL = re.compile(r"^( *)((?:@\w+(?:\([^)]*\))? +)*)public +(.*)$")
TYPE = re.compile(r"^(?:final +|indirect +)*(struct|class|enum|actor|protocol) +(\w+)")
ANY_TYPE = re.compile(r"^ *(?:@\w+(?:\([^)]*\))? +)*(?:public +)?(?:final +|indirect +)*(?:struct|class|enum|actor|protocol|extension) +([\w.]+)")


def signature(lines, i):
    """The declaration that starts at line i, joined over its continuation lines, without its body."""
    text = lines[i].strip()
    depth = text.count("(") - text.count(")")
    j = i
    while depth > 0 and j + 1 < len(lines):
        j += 1
        nxt = lines[j].strip()
        text += " " + nxt
        depth += nxt.count("(") - nxt.count(")")
    cut = text.find(" {")
    if cut >= 0:
        text = text[:cut]
    return text.rstrip("{ ").strip()


def doc(lines, i):
    """The /// comment above line i, as one paragraph."""
    out = []
    j = i - 1
    # an attribute on its own line sits between the comment and the declaration
    while j >= 0 and lines[j].strip().startswith("@"):
        j -= 1
    while j >= 0 and lines[j].strip().startswith("///"):
        raw = lines[j].strip()[3:]
        # an indented line is a code example (the README has them): not part of the paragraph
        if raw.strip() and not raw.startswith("    "):
            out.append(raw.strip())
        j -= 1
    return " ".join(reversed(out)).strip()


def collect():
    """{top-level type: {"doc", "kind", "members": [(owner, signature, doc)]}} for every public declaration."""
    types = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        lines = path.read_text(encoding="utf-8").replace("\r\n", "\n").split("\n")
        top = None            # the top-level type (or extension) the current lines belong to
        owner = None          # the public type a nested declaration belongs to, "Outer" or "Outer.Inner"
        enum_indent = None    # the indentation of a public enum whose cases are being listed
        for i, line in enumerate(lines):
            m_any = ANY_TYPE.match(line)
            if m_any and not line.startswith(" "):
                top = m_any.group(1)
                owner = top
            if enum_indent is not None:
                stripped = line.strip()
                indent = len(line) - len(line.lstrip(" "))
                if stripped == "}" and indent <= enum_indent:
                    enum_indent = None
                elif stripped.startswith("case ") and indent == enum_indent + 4:
                    types[top.split(".")[0]]["members"].append((owner, stripped, doc(lines, i)))
            m = DECL.match(line)
            if not m:
                continue
            indent, rest = len(m.group(1)), m.group(3)
            sig = signature(lines, i)
            t = TYPE.match(rest)
            if indent == 0 and t:
                top = owner = t.group(2)
                types.setdefault(top, {"doc": doc(lines, i), "kind": t.group(1), "sig": sig, "members": []})
                if t.group(1) == "enum":
                    enum_indent = 0
                continue
            if top is None:
                continue
            root = top.split(".")[0]
            types.setdefault(root, {"doc": "", "kind": "extension", "sig": "", "members": []})
            if t:
                # a nested public type: its members follow under "Outer.Inner"
                owner = f"{root}.{t.group(2)}"
                types[root]["members"].append((owner, sig, doc(lines, i)))
                if t.group(1) == "enum":
                    enum_indent = indent
                continue
            if indent == 4:
                owner = root
            types[root]["members"].append((owner, sig, doc(lines, i)))
    return types


def render(types):
    names = [n for n in ORDER if n in types] + sorted(n for n in types if n not in ORDER)
    out = ["# TajweedFormer for iOS and macOS: the public API",
           "",
           "Generated from the sources by `scripts/make_api_doc.py`; a test fails when a public declaration is missing",
           "here. The names are those of the four TajweedFormer SDKs. Start with the README's quick start.",
           "",
           "| Type | What it is |",
           "|---|---|"]
    for n in names:
        first = re.split(r"(?<=\.)\s", types[n]["doc"], maxsplit=1)[0] if types[n]["doc"] else ""
        out.append(f"| [`{n}`](#{n.lower()}) | {first} |")
    for n in names:
        t = types[n]
        out += ["", f"## {n}", ""]
        if t["sig"]:
            out += ["```swift", t["sig"], "```", ""]
        if t["doc"]:
            out += [t["doc"], ""]
        # the type's own members first, then each nested public type with its members and cases
        owners = [n] + [o for o in dict.fromkeys(o for o, _, _ in t["members"]) if o != n]
        for o in owners:
            if o != n:
                out += ["", f"### {o}", ""]
            for owner, sig, d in t["members"]:
                if owner == o:
                    out.append(f"- `{sig}`" + (f": {d}" if d else ""))
    return "\n".join(out) + "\n"


def main():
    text = render(collect())
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text(encoding="utf-8").replace("\r\n", "\n") != text:
            print("docs/api.md is not what the sources give: run python scripts/make_api_doc.py")
            return 1
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(text.encode("utf-8"))
    print(f"wrote {OUT} ({len(text.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
