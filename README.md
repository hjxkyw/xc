# xc

A compiler from xtpl to TL++, in C++20. The language -- what xc takes,
what it makes of it, what it refuses -- is described in
[docs/language.md](docs/language.md). It also compiles a program to the
bytecode of a stack machine, for an interpreter to run:
[docs/bytecode.md](docs/bytecode.md).

xc was written in Raku first (see [History](#history)); Raku still runs
the script around it, `run-protheus.raku`.

## Building

C++20, nothing beyond the standard library; GCC, Clang and MSVC.

```sh
cmake -S cpp -B cpp/build -DCMAKE_BUILD_TYPE=Release
cmake --build cpp/build -j$(nproc)
```

On Windows, from `cmd.exe`, with Visual Studio 2026 (CMake 4.2 or later on
the PATH):

```bat
cmake -S cpp -B cpp\build -G "Visual Studio 18 2026"
cmake --build cpp\build --config Release --parallel
```

The programs are then in `cpp\build\Release\`: `xc.exe` where this README
says `cpp/build/xc`.

## Compiling

```sh
cpp/build/xc file.xtpl               # writes file.tlpp
cpp/build/xc file.xtpl out.tlpp
cpp/build/xc a.xtpl b.xtpl src/      # each next to itself; a folder is every .xtpl under it
cpp/build/xc --check src/            # checks, and writes nothing
cpp/build/xc --includes="lib/include;../shared" file.xtpl    # where its include files are
cpp/build/xc --dict sx3.csv file.xtpl                   # checks the fields against an exported SX3
cpp/build/xc --dict sx3.csv --dict-strict file.xtpl     # and what it finds stops the compile
cpp/build/xc --version               # the commit it was built from, and its date
cpp/build/xc --outdir=out a.prw      # an AdvPL source stays AdvPL: out/a.prw
cpp/build/xc a.prw b.prw             # writes b.prw -- never over its source
cpp/build/xc --bytecode file.xtpl    # writes file.xbc, bytecode, instead of the TL++
cpp/build/xc --bytecode runtime/xtpl_runtime.tlpp rt.xbc   # xtpl's runtime, as bytecode
cpp/build/xc-vm rt.xbc file.xbc      # runs it, the runtime first
```

xtpl is TL++, and so is what xc makes of it: a `.tlpp`. A `.prw` (or
`.prx`) is AdvPL, and stays AdvPL: xc writes a `.prw`, without
`tlpp-core.th`, and holds it to AdvPL's rules, not TL++'s -- AdvPL takes
`As String`, drops the arguments a function does not take, and checks no
types (see `docs/language.md`, The output).

The exit code is 0 when every file went through, 1 when one did not, and 2
when the command line itself is wrong. `--version` says the commit xc was
built from -- `xc version 3d7df6e, 2026-10-15`, with `-dirty` after the hash
when the files differed from it -- as `run-protheus.raku` shows it too. A
source is windows-1252 (cp1252), as Protheus' sources are, and so is what xc
writes; a file in UTF-8 is refused.

A source may bring commands and translations of its own -- `#xcommand`,
`#xtranslate`, in the file or in an include file. xc reads them from the
file and from every include file it finds as plain text, beside the source
or in `--includes`, and takes their uses as the preprocessor will: a command
whole, as written; one that stands for a function's header, with its body
read like any other; a translation as a value. TOTVS' own include files are
compressed, and xc knows their commands from a list of its own.

The generated code calls xtpl's runtime, `runtime/xtpl_runtime.tlpp`, which
has to be compiled into the RPO alongside it.

`--bytecode` writes the program as instructions for a stack machine
instead, one to a line, in a `.xbc` -- what an interpreter written in xtpl
is to run on an AppServer, calling the AppServer's functions by name.
`docs/bytecode.md` says what each instruction does, and what is not
compiled so yet. `xc-vm` runs `.xbc`s: the machine as a program, with a
few of the AppServer's functions, which the tests run their bytecode with --
xtpl's runtime compiled to bytecode first, and the self-tests too.
`interp/xbc.xtpl` is the interpreter for an AppServer, written in xtpl
(`appserver -run=u_xbc -env=NAME module.xbc ...`); xc-vm runs it too, and
`rakupp run-protheus.raku --interp` runs it on an AppServer.

## Running the tests

```sh
ctest --test-dir cpp/build
```

On Windows, `ctest --test-dir cpp\build -C Release`. The tests are data, in
`cpp/tests/` (its README says how each is kept):

| test | what |
|---|---|
| `outputs` | each of xtpl's sources compiles to the `.tlpp` beside it |
| `cases` | sources, each with the TL++ and the messages xc gives for it |
| `driver` | command lines: the exit code, what is printed, the files written |
| `doc` | the examples of `docs/language.md` come out as it shows them |
| `style` | every separator line of xc's own files ends at column 80 |
| `bytecode` | sources, each with its bytecode, the messages, and what `xc-vm` does running it |
| `selftests` | xtpl's self-tests and xc's, as bytecode, pass on `xc-vm` |
| `interp`, `interp-xc` | the interpreter written in xtpl, run by `xc-vm`, does what `xc-vm` does: the bytecode cases, the self-tests (`interp-xc`: xc's, slowly) |

After a change to the output that is meant, the expected files are written
again, and the diff is the review:

```sh
cpp/build/xc-cases --update cpp/tests/cases
cpp/build/xc-outputs --update xtpl/tests xtpl/examples
```

## Running in Protheus

`run-protheus.raku` compiles two self-tests with xc -- xtpl's
`xtpl/tests/54_selftest.xtpl` and xc's own `protheus/xc_selftest.xtpl` --
has an AppServer compile them with the runtime, runs each, and reads their
totals. xc is the one CMake built (`cpp/build/xc`, or
`cpp\build\Release\xc.exe`); `--xc=PATH` names another:

```sh
rakupp run-protheus.raku --env=NAME --includes=PATH [--appserver=PATH] [--authorization=FILE]
rakupp run-protheus.raku ... --compile-only     # or --run-only
rakupp run-protheus.raku ... --corpus           # all of xtpl's corpus, compiled by Protheus in one run
rakupp run-protheus.raku ... --interp           # the bytecode's interpreter, on the bytecode cases and xtpl's self-test
rakupp run-protheus.raku ... --bench            # the interpreter's speed: interp/bench.xtpl compiled and interpreted
rakupp run-protheus.raku ... --verbose          # everything the AppServer says, as it comes
rakupp run-protheus.raku ... --rebuild          # the self-tests compiled again, up to date or not
```

Only what matters is shown -- a source that did not compile and why, the
results line, each failed check and the totals; all the AppServer said goes
into a log beside what it compiled (`compile.log`, `run-u_selftest.log`,
...). With `--corpus`, xc compiles every program of xtpl's corpus into
`build/corpus/` and the AppServer compiles that folder: nothing runs, the
point is that Protheus takes all of xc's output. With `--interp`, the
AppServer compiles the interpreter (`interp/xbc.xtpl`) and runs it on the
bytecode cases and on xtpl's self-test, made bytecode in `build/interp-xbc/`:
each has to do what xc-vm does. The AppServer reads files under the
environment's RootPath only, so the bytecode goes to `xbc/` there, and the
files the cases read to its StartPath; both come from the environment's
section of the `appserver.ini`, or `--rootpath=PATH` (`XC_ROOTPATH`) names
the RootPath. A case that needs what only xc-vm does (`NAME.vmonly`: its
own tables, Decimals) is left out, and so is xc's self-test, which has
Decimals; `--trace` keeps what the interpreter did in each run, in
`build/logs/interp/NAME.trace`, and `--nojit` has the interpreter make no
code blocks of runs of instructions with the macro compiler. With
`--bench`, the AppServer runs `interp/bench.xtpl` compiled, then the
interpreter on it as bytecode, with and without those blocks, and the
times of each of its parts are shown side by side.

It calls `appserver -compile -files=... -includes=... -env=... [-authorization=...]`
and reads its `Compilation Results .: Total sources(3) Success(3) Errors(0)`
line, then `appserver -run=u_selftest -env=...` and `-run=u_xc_selftest`. The
settings can come from `XC_APPSERVER`, `XC_ENV`, `XC_INCLUDES`,
`XC_AUTHORIZATION`, `XC_COMPILER` (`--xc`) and `XC_ROOTPATH` instead, so
that once set a run is just `rakupp run-protheus.raku`. The AppServer defaults to
`appserver.exe` on Windows and `appsrvlinux` elsewhere, found on the PATH;
given as a path, it is started from its own folder, where its
`appserver.ini` is. xc's output goes to `build/protheus/`. A compile that
prints no results line shows the last lines the AppServer said, and its
exit code. The exit code is 0 only when both self-tests ran and every check
passed.

The self-tests are pure computation -- no table, no file, no screen -- so
they run on any environment. They need AppServer 19.3.1 or later: aPick
and aRoll draw with `Random()`.

## Editing in VS Code

`editors/vscode/` is an extension for `.xtpl` files: highlighting, xc's
checks as diagnostics on open and on save, and a command that compiles the
file. See [its README](editors/vscode/README.md) for installing it -- a
package, or the folder linked into VS Code's extensions.

## Installing rakupp

For `run-protheus.raku`:

```sh
curl -sfL -O https://github.com/ash/rakupp/releases/download/v5.3.0/rakupp-linux-x86_64.tar.gz
curl -sfL -O https://github.com/ash/rakupp/releases/download/v5.3.0/rakupp-linux-x86_64.tar.gz.sha256
sha256sum -c rakupp-linux-x86_64.tar.gz.sha256
tar xzf rakupp-linux-x86_64.tar.gz
export PATH=$PWD/rakupp/bin:$PATH
```

It runs under rakupp 5.3.0, and under Rakudo as well.

## What is where

| | |
|---|---|
| `cpp/` | xc: `src/` the compiler, `xc-vm` and the programs that test them, `tests/` the tests, as data |
| `docs/` | the language reference, `language.md` -- `xc-doc` (ctest's `doc`) compiles its examples --, and the bytecode's, `bytecode.md` |
| `editors/vscode/` | the extension for VS Code: highlighting and xc's checks |
| `runtime/` | the functions the generated code calls, compiled into the RPO with it |
| `protheus/` | xc's self-test for an AppServer, in xtpl -- `run-protheus.raku` compiles and runs it |
| `xtpl/` | xtpl's own tests, examples, errors and probes, byte for byte, each with the `.tlpp` xc makes of it, and xc's example `saldo` -- see `xtpl/README.md` |
| `run-protheus.raku` | xc's output compiled and run by an AppServer |

## History

xc was written in Raku first: a grammar, the tree its actions make, the
checks and the emitter, with their tests. That xc was frozen on 14 October
2026, and it is kept, archived, at
[hjxkyw/xc-raku](https://github.com/hjxkyw/xc-raku); this repository took
the C++ xc, with its history, in October 2026.

The C++ xc began as a port of it, and its comments still say so where that
helps: "the Raku grammar" is `lib/XC/Grammar.rakumod` there, whose rules
`src/parser.cpp` and `src/statements.cpp` quote; "Raku's `.lines`" is what
that method does; `lib/XC/Check.rakumod` and `lib/XC/Emit.rakumod` say why
the rules and rewrites the two share are what they are. The programs of its
tests, in `t/`, are the cases in `cpp/tests/cases/` named for them.
