# xtpl's own material

Everything xtpl had to show what the language is and what its compiler does,
copied as it is from the xtpl repository (version 116). xtpl is deprecated and
now only serves to bootstrap xc; this is its knowledge, kept at the top of
xc's repository, apart from xc's own tests in `t/`, which read it.

The sources, the warnings, the errors and the programs written by hand are
byte for byte xtpl's -- line ends and encodings included -- and are not edited
here: to take a newer version, copy the folders again. The `.tlpp` beside each
`.xtpl` is not: it is xc's output, not the one xtpl produced, which is gone
(October 2026). `ctest --test-dir cpp/build` checks that the C++ xc still
writes each of them byte for byte, and `cpp/build/xc-outputs --update
xtpl/tests xtpl/examples` writes them again after a change to the output that
is meant. One folder is not xtpl's at all:
`examples/saldo/` is xc's own small source, written for xc's parser tests
(`t/02`, `t/03`, `t/08`, `t/09`). Most of the text in them is in Portuguese,
as xtpl's was.

| | | read by |
|---|---|---|
| `tests/` | xtpl's test suite: each `.xtpl` with the `.tlpp` xc writes for it, a `.warn` where xtpl warns, and the few data files some tests read | `t/31-xtpl-corpus.raku` (every source); `xc-outputs` (the `.tlpp` files) |
| `examples/` | whole programs, each with its `.xtpl` and the `.tlpp` xc writes for it; some also have a `_mao.tlpp`, the same program written by hand, to compare against | `t/31-xtpl-corpus.raku`; `xc-outputs` |
| `errors/` | what xtpl refuses: each `.xtpl` with the message xtpl gives in its `.err`; its `README.md` is xc's, on how `t/17` uses them | `t/17-xtpl-errors.raku` |
| `probes/` | `.tlpp` programs that ask Protheus a question and print the answer: most of what xtpl knows about AdvPL/TL++ beyond the documentation came from them. Run on an AppServer, not by the tests | -- |

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
