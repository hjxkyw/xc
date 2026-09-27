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
rakupp run-tests.raku          # all but the slow tests: about 20 seconds
rakupp run-tests.raku --all    # all of them, xtpl's whole corpus too: a few minutes
```

Each test file says `ok` or `FAIL` with its count, and the run ends with the
total; the exit code is 0 only when everything passed. A single test runs on
its own too:

```sh
rakupp t/08-tree.raku
```

## What is where

| | |
|---|---|
| `bin/xc` | the compiler |
| `lib/XC/` | the grammar, the tree, the checks, the emitter |
| `runtime/` | the functions the generated code calls, compiled into the RPO with it |
| `t/` | xc's tests |
| `xtpl/` | xtpl's own tests, examples, errors and probes, byte for byte, and xc's example `saldo` -- see `xtpl/README.md` |
