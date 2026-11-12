# The stand-in of a one-file CoreML package

`onefile_stub.mlpackage` is written by `scripts/make_onefile_stub_fixture.py` from the stand-in the model side makes
for SDK tests. It has the interface of a one-file accelerator package, the kind that carries its keep table inside:
the functions `front_<context>` and `back_<context>`, each taking `keep_sel` (float16, shape [1, R]) in place of
`zf_keepf` / `zf_keepb`. It has no model: every output is 0, and its weights file holds only constants that are 0.

Changed by the script:

- Removed, because the SDK decides nothing by a package's metadata and this repository is public: the description
  text, the version string, and every user-defined entry that identifies the model the stand-in was made from (its
  id, version and contexts, and the names and SHA-256 of the files it was exported from).
- Added, so that the stand-in loads: an explicit `axes` input on each `reduce_max` of its program (every axis of
  the input, which is what the operation reduced over without one). CoreML on macOS 26 refuses to load a reduce
  without `axes`. The outputs are unchanged: all 0.

The functions' descriptions (names, inputs, outputs, shapes, types), every other operation of the program and the
weights file are byte for byte the stand-in's. `TajweedOneFilePackageTests` asserts that the fixture holds no weights and
none of the removed strings, and loads it.
