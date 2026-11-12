#!/usr/bin/env python3
"""Makes the test fixture Tests/TajweedFormerTests/Fixtures/keepsel_stub/onefile_stub.mlpackage from the stand-in
package the model side makes for SDK CI.

  python scripts/make_onefile_stub_fixture.py STUB.mlpackage.zip

The stand-in is a CoreML package of a few kilobytes with the interface of a one-file accelerator package (the kind
that carries its keep table inside and takes `keep_sel` in place of `zf_keepf` / `zf_keepb`): the functions
`front_<context>` and `back_<context>` with their inputs and outputs (names, shapes, float16) and no model: every
output is 0. TajweedOneFilePackageTests compiles it on the machine that runs the tests.

What this script changes, and why: the stand-in also carries the metadata of the package it was made from. The SDK
never decides anything by a package's metadata, and this repository is exported publicly, so everything that
identifies a model is taken out before the fixture is written:

  - the description text, replaced by one sentence that says what the fixture is;
  - `versionString`, removed;
  - every user-defined entry except `stub`, `keeps` and `precision` (removed: the model's id and version, its
    contexts, and the names and SHA-256 of the files it was exported from); the `stub` entry is reworded.

One change to the program, so that the stand-in loads: each of its `reduce_max` operations gets an explicit `axes`
input, every axis of its input. The stand-in was made without one (a reduction over all axes by default), and
CoreML on macOS 26 refuses to load such a program ("Parameter binding for axes does not exist"). The numbers do not
change: every output is still 0.

Kept byte for byte: the specification version, every function's description (names, inputs, outputs, their shapes,
types and descriptions), the default function name, every other operation of the program, the weights file and
Manifest.json. `author` stays.

After writing, the script checks the fixture and fails if a check does not hold:
  - no file holds one of the strings in FORBIDDEN;
  - the weights file holds no weights: fewer than 256 of its bytes are not 0 (the headers of constants that are 0);
  - the whole fixture is under 70 kB.

Python 3.8 or later, standard library only (the model description is rewritten with a small protobuf reader, so
neither coremltools nor protobuf is needed).
"""
import hashlib
import io
import os
import shutil
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Tests", "TajweedFormerTests", "Fixtures", "keepsel_stub", "onefile_stub.mlpackage")
MODEL = "Data/com.apple.CoreML/model.mlmodel"
WEIGHTS = "Data/com.apple.CoreML/weights/weight.bin"
MANIFEST = "Manifest.json"

DESCRIPTION = ("STUB for SDK tests (no model, every output 0): the interface of a one-file TajweedFormer CoreML "
               "package, which carries its keep table inside and takes keep_sel")
STUB_ENTRY = "true: the interface of a one-file package, no weights, every output 0; the model's own metadata removed"
KEPT_ENTRIES = ("stub", "keeps", "precision")
# what must not be in a public fixture: a model version, a training step, the provenance of an export
FORBIDDEN = (b"4.1", b"v4_s1", b"checkpoint", b"source_onnx", b"model_id", b"model_version")


def varint(b, i):
    """The varint at b[i:], and the index after it."""
    v, s = 0, 0
    while True:
        x = b[i]
        i += 1
        v |= (x & 0x7F) << s
        s += 7
        if not x & 0x80:
            return v, i


def enc(v):
    out = bytearray()
    while True:
        x = v & 0x7F
        v >>= 7
        out.append(x | (0x80 if v else 0))
        if not v:
            return bytes(out)


def fields(b):
    """A protobuf message as [(field number, wire type, value)]; a value is an int (varint) or the raw bytes."""
    i, out = 0, []
    while i < len(b):
        k, i = varint(b, i)
        f, w = k >> 3, k & 7
        if w == 0:
            v, i = varint(b, i)
        elif w == 2:
            n, i = varint(b, i)
            v = b[i:i + n]
            i += n
        elif w == 1:
            v = b[i:i + 8]
            i += 8
        elif w == 5:
            v = b[i:i + 4]
            i += 4
        else:
            raise ValueError(f"wire type {w}")
        out.append((f, w, v))
    return out


def message(fs):
    out = bytearray()
    for f, w, v in fs:
        out += enc(f << 3 | w)
        if w == 0:
            out += enc(v)
        elif w == 2:
            out += enc(len(v)) + v
        else:
            out += v
    return bytes(out)


def text(f, s):
    return (f, 2, s.encode("utf-8"))


def scrub_metadata(md):
    """Metadata: shortDescription 1, versionString 2, author 3, license 4, userDefined 100 (entries: key 1, value 2)."""
    out, removed = [text(1, DESCRIPTION)], []
    for f, w, v in fields(md):
        if f == 1:
            continue
        if f == 2:
            removed.append("versionString")
            continue
        if f == 100:
            kv = {g: x.decode("utf-8") for g, _, x in fields(v)}
            key = kv.get(1, "")
            if key not in KEPT_ENTRIES:
                removed.append(key)
                continue
            if key == "stub":
                v = message([text(1, "stub"), text(2, STUB_ENTRY)])
        out.append((f, w, v))
    return message(out), removed


INT32, STRING = 23, 2  # MIL DataType


def tensor_type(data_type, size=None):
    """ValueType { tensorType 1: { dataType 1, rank 2, dimensions 3: { constant 1: { size 1 } } } }; a scalar
    without `size`."""
    t = [(1, 0, data_type)]
    if size is not None:
        t += [(2, 0, 1), (3, 2, message([(1, 2, message([(1, 0, size)]))]))]
    return message([(1, 2, message(t))])


def const_axes(name, rank):
    """The operation `const` that holds the int32 tensor [0, .., rank - 1], as coremltools writes a constant:
    Operation { type 1, outputs 3: { name 1, type 2 }, attributes 5: map of `name` and `val` to a Value { type 2,
    immediateValue 3: { tensor 1: { ints 2 | strings 4: { values 1 } } } } }."""
    ints = message([(1, 2, b"".join(enc(i) for i in range(rank)))])
    val = message([(2, 2, tensor_type(INT32, rank)), (3, 2, message([(1, 2, message([(2, 2, ints)]))]))])
    strings = message([(1, 2, name.encode("utf-8"))])
    name_value = message([(2, 2, tensor_type(STRING)), (3, 2, message([(1, 2, message([(4, 2, strings)]))]))])
    return message([
        text(1, "const"),
        (3, 2, message([text(1, name), (2, 2, tensor_type(INT32, rank))])),
        (5, 2, message([text(1, "name"), (2, 2, name_value)])),
        (5, 2, message([text(1, "val"), (2, 2, val)])),
    ])


def add_axes(program):
    """Program { functions 2: map of name to Function { inputs 1: { name 1, type 2 }, block_specializations 3: map
    of opset to Block { operations 3 } } }. Every `reduce_max` whose input `x` is a function input gets the input
    `axes`, bound to a new constant in front of it. Returns the program and how many operations were changed."""
    changed = 0
    out_program = []
    for f, w, v in fields(program):
        if f != 2:
            out_program.append((f, w, v))
            continue
        entry = fields(v)
        fn_fields = []
        ranks = {}
        for g, w2, x in fields(next(val for k, _, val in entry if k == 2)):
            if g == 1:  # an input: its name and the rank of its tensor type
                d = {a: b for a, _, b in fields(x)}
                tensor = {a: b for a, _, b in fields(next(b for a, _, b in fields(d[2]) if a == 1))}
                ranks[d[1].decode("utf-8")] = tensor.get(2, 0)
            if g == 3:  # a block specialization
                spec = fields(x)
                block = []
                for h, w3, y in fields(next(val for k, _, val in spec if k == 2)):
                    op = fields(y) if h == 3 else []
                    if h == 3 and op[0][2] == b"reduce_max":
                        args = {}
                        for a, _, b in op:
                            if a == 2:
                                kv = {p: q for p, _, q in fields(b)}
                                args[kv[1].decode("utf-8")] = kv[2]
                        assert "axes" not in args, "a reduce_max of the stand-in already has axes"
                        bound = {p: q for p, _, q in fields(next(q for p, _, q in fields(args["x"]) if p == 1))}
                        rank = ranks[bound[1].decode("utf-8")]
                        assert rank > 0, bound
                        out_name = {p: q for p, _, q in fields(next(b for a, _, b in op if a == 3))}[1].decode("utf-8")
                        const_name = out_name + "_axes_0"
                        block.append((3, 2, const_axes(const_name, rank)))
                        binding = message([(1, 2, message([text(1, const_name)]))])
                        op.insert(1, (2, 2, message([text(1, "axes"), (2, 2, binding)])))
                        y = message(op)
                        changed += 1
                    block.append((h, w3, y))
                x = message([(k, w4, message(block) if k == 2 else val) for k, w4, val in spec])
            fn_fields.append((g, w2, x))
        out_program.append((f, w, message([(k, w5, message(fn_fields) if k == 2 else val) for k, w5, val in entry])))
    return message(out_program), changed


def scrub_model(model):
    """Model: specificationVersion 1, description 2, then the program (502). ModelDescription: functions 20, the
    default function's name 21, metadata 100."""
    top, removed = [], []
    for f, w, v in fields(model):
        if f == 502:
            v, changed = add_axes(v)
            assert changed > 0, "the stand-in has no reduce_max: check whether it still needs this change"
            print(f"program: axes added to {changed} reduce_max operations")
        if f == 2:
            d = []
            for g, w2, x in fields(v):
                if g == 100:
                    x, removed = scrub_metadata(x)
                d.append((g, w2, x))
            v = message(d)
        top.append((f, w, v))
    return message(top), removed


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    z = zipfile.ZipFile(io.BytesIO(open(sys.argv[1], "rb").read()))
    roots = {n.split("/")[0] for n in z.namelist()}
    assert len(roots) == 1 and next(iter(roots)).endswith(".mlpackage"), roots
    root = next(iter(roots)) + "/"
    names = sorted(n[len(root):] for n in z.namelist() if not n.endswith("/"))
    assert names == sorted([MODEL, WEIGHTS, MANIFEST]), names
    model, removed = scrub_model(z.read(root + MODEL))
    files = {MODEL: model, WEIGHTS: z.read(root + WEIGHTS), MANIFEST: z.read(root + MANIFEST)}
    # the checks, before anything is written
    for name, data in files.items():
        for s in FORBIDDEN:
            assert s not in data, f"{name} holds {s!r}"
    not_zero = sum(1 for x in files[WEIGHTS] if x)
    assert not_zero < 256, f"the weights file has {not_zero} bytes that are not 0"
    total = sum(len(d) for d in files.values())
    assert total < 70_000, total
    out = os.path.normpath(OUT)
    shutil.rmtree(out, ignore_errors=True)
    for name, data in files.items():
        path = os.path.join(out, *name.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        print(f"{name}: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
    print(f"removed from the metadata: {', '.join(sorted(removed))}")
    print(f"weights file: {not_zero} bytes that are not 0; fixture: {total} bytes -> {out}")


if __name__ == "__main__":
    main()
