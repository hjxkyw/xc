# xc

A compiler from xtpl to TL++, written in Raku.

## Installing rakupp

```sh
curl -sfL -O https://github.com/ash/rakupp/releases/download/v4.0.1/rakupp-linux-x86_64.tar.gz
tar xzf rakupp-linux-x86_64.tar.gz
export PATH=$PWD/rakupp/bin:$PATH
```

## Compiling

```sh
rakupp bin/xc file.xtpl              # writes file.tlpp
rakupp bin/xc file.xtpl out.tlpp
rakupp bin/xc a.xtpl b.xtpl src/     # each next to itself; a folder is every .xtpl under it
rakupp bin/xc --check src/           # checks, and writes nothing
rakupp bin/xc --dict sx3.csv file.xtpl                  # checks the fields against an exported SX3
rakupp bin/xc --dict sx3.csv --dict-strict file.xtpl    # and what it finds stops the compile
```

The exit code is 0 when every file went through, 1 when one did not, and 2
when the command line itself is wrong.

The generated code calls xtpl's runtime, `runtime/xtpl_runtime.tlpp`, which
has to be compiled into the RPO alongside it.

## Running the tests

From the top of the repository:

```sh
rakupp run-tests.raku          # every test, xtpl's whole corpus too
rakupp run-tests.raku --jobs=1 # one file at a time -- by default, as many at once as there are cores
rakupp run-tests.raku --all    # and any marked slow ('# slow:' near its top) -- none are now
raku run-tests.raku            # the same under Rakudo, which must pass too
```

Each test file says `ok` or `FAIL` with its count and the time it took, and
the run ends with the total, its time, and the three slowest files. The exit
code is 0 only when everything passed, and 2 for an option it does not know
-- `-all` with one dash, say -- before any test runs. xtpl's corpus is checked
in three parts, `t/31-xtpl-corpus-1` to `-3`, so that they run at once; what
they check is in `t/lib/XtplCorpus.rakumod`. A single test runs on its own
too:

```sh
rakupp t/08-tree.raku
```

## Running in Protheus

`run-protheus.raku` compiles two self-tests with xc -- xtpl's
`xtpl/tests/54_selftest.xtpl` and xc's own `protheus/xc_selftest.xtpl` --
has an AppServer compile them with the runtime, runs each, and reads their
totals:

```sh
rakupp run-protheus.raku --env=NAME --includes=PATH [--appserver=PATH] [--authorization=FILE]
rakupp run-protheus.raku ... --compile-only     # or --run-only
```

It calls `appserver -compile -files=... -includes=... -env=... [-authorization=...]`
and reads its `Compilation Results .: Total sources(3) Success(3) Errors(0)`
line, then `appserver -run=u_selftest -env=...` and `-run=u_xc_selftest`. The
settings can come from `XC_APPSERVER`, `XC_ENV`, `XC_INCLUDES` and
`XC_AUTHORIZATION` instead, so that once set a run is just
`rakupp run-protheus.raku`. The AppServer defaults to `appserver.exe` on
Windows and `appsrvlinux` elsewhere, found on the PATH; given as a path, it is
started from its own folder, where its `appserver.ini` is. xc's output goes
to `build/protheus/`. The exit code is 0 only when both self-tests ran and
every check passed.

The self-tests are pure computation -- no table, no file, no screen -- so
they run on any environment. They need AppServer 19.3.1 or later: aPick
and aRoll draw with `Random()`.

## What is where

| | |
|---|---|
| `bin/xc` | the compiler |
| `lib/XC/` | the grammar, the tree, the checks, the emitter |
| `runtime/` | the functions the generated code calls, compiled into the RPO with it |
| `t/` | xc's tests, in Raku; `t/lib/` what several of them share |
| `protheus/` | xc's self-test for an AppServer, in xtpl -- `run-protheus.raku` compiles and runs it |
| `xtpl/` | xtpl's own tests, examples, errors and probes, byte for byte, and xc's example `saldo` -- see `xtpl/README.md` |
