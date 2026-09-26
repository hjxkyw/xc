# xtpl's own material

Everything xtpl had to show what the language is and what its compiler does,
copied as it is from the xtpl repository (version 116). xtpl is deprecated and
now only serves to bootstrap xc; this is its knowledge, kept where xc's tests
can read it.

The files are byte for byte xtpl's -- line ends and encodings included -- and
are not edited here: to take a newer version, copy the folders again. Most of
the text in them is in Portuguese, as xtpl's was.

| | | read by |
|---|---|---|
| `tests/` | xtpl's test suite: each `.xtpl` with the `.tlpp` xtpl produced for it, a `.warn` where xtpl warns, and the few data files some tests read | `t/31-xtpl-corpus.raku` (every source); `t/25`, `t/26`, `t/30` (line-by-line comparisons with xtpl's output) |
| `examples/` | whole programs, each with its `.xtpl` and the `.tlpp` xtpl produced; some also have a `_mao.tlpp`, the same program written by hand, to compare against | `t/31-xtpl-corpus.raku` |
| `errors/` | what xtpl refuses: each `.xtpl` with the message xtpl gives in its `.err`; its `README.md` is xc's, on how `t/17` uses them | `t/17-xtpl-errors.raku` |
| `probes/` | `.tlpp` programs that ask Protheus a question and print the answer: most of what xtpl knows about AdvPL/TL++ beyond the documentation came from them. Run on an AppServer, not by the tests | -- |

## Comparing with xtpl's output

xc does not produce xtpl's text: it names its hidden locals differently, keeps
the source's layout, and leaves chains over arrays as runtime calls where
xtpl fuses them into loops. A comparison is of the statements, under a
normalisation each test states. Where xc differs on purpose -- mostly where
xtpl's output is wrong -- the test says why.

## What the probes found that matters to xc

- `probe_assign`: `:=` is an expression and yields the value assigned.
- `probe_ftuse`: an `FT_FUse` that fails is not inert -- it displaces the
  current file, and the next `FT_FUse()` closes another one. xc's `lines()`
  loops check `File()` before opening, as xtpl's do; a file that exists and
  still fails to open is not covered.
- `probe_hash*`: `THashMap`'s `Get(k, @x)` fills `x` only when the key is
  there, which is what `u_xtpl_hget` in `runtime/xtpl_runtime.tlpp` relies on.

Several probes use the names xtpl generated when they were written
(`__stk_`, `__blk_`): they record what was run, and are not updated.
