# The C++ xc's tests

Data, not code: each test is a source, or a command line, and what xc does
with it. CMake runs them:

```
cmake --build cpp/build -j$(nproc)
ctest --test-dir cpp/build
```

| test | what | the data |
|---|---|---|
| `outputs` | each of xtpl's sources compiles to the `.tlpp` beside it | `xtpl/tests/`, `xtpl/examples/` |
| `cases` | each case: the TL++ xc writes, and what it says | `cases/` |
| `driver` | each command line: the exit code, what is printed, the files written | `driver/` |
| `doc` | each example of the language reference comes out as it shows | `docs/language.md` |

## cases/

`NAME.xtpl` and beside it `NAME.tlpp`, the TL++ (none when xc writes none;
for `NAME.prw`, an AdvPL source, `NAME.out.prw`, the AdvPL xc writes),
`NAME.err`, what xc says of it -- warnings, errors, the line it could not
parse -- (none when it says nothing), and `NAME.args` when it is compiled with
options: `--dict FILE`, `--dict-strict`, `--includes=DIRS`, the paths from its
folder. A case that names include files has a folder of its own, with them.

The sources are the Raku xc's tests': every program a test in `t/` compiled,
one folder for each test file (`32-check/`, `43-advpl-forms/`, ...), each
source once. xtpl's own are in `outputs`. The dictionary's are compiled with
`33-dictionary/sx3.csv`, as the test compiles them, and again strict. What is
expected is what xc made of them when they were taken (October 2026) -- the
same as the Raku xc, checked then.

Cases added since the Raku xc was frozen have folders named for what they
test: `temps/`, the Locals that hold a value read twice; `fallback/`, a
guard as a statement's whole value, and one that stays an expression;
`calls/`, verbs written as calls; `distinct/`, a `distinct` in a loop;
`prologue/`, the values a prologue keeps, and the one it cannot;
`indent/`, the lines xc writes before a `return` at the first column;
`typed-start/`, the warning for a `?:` or a `?=` on a `Local` declared
with a type and no value that TL++ starts at something else than Nil;
`refused/`, what the AppServer was seen to refuse since (`as Block`, a
variable named `as`, a number as a `Decimal`'s value); `survey/`, forms
of the survey of AdvPL and TL++ on GitHub that xc refused wrongly;
`advpl/`, an AdvPL source that stays AdvPL, and the same source as TL++;
`json/`, the JSON literals TL++ takes as written, and those xc makes with
`u_xtpl_jnew` or `JsonObject():New()`.

A test in `t/` says what it looks for; a case holds the whole of what came
out, so a change to the output shows in every case it touches. After a change
that is meant, write them again and read the diff:

```
cpp/build/xc-cases --update cpp/tests/cases
git diff cpp/tests/cases
```

## driver/

`NAME.cmd`, the arguments of one run of `xc`, one to a line, and
`NAME.expect`, what the run did. Each runs in a fresh copy of `src/` and
`extra/`, the files the arguments name. After a change that is meant:

```
cmake -DXC=cpp/build/xc -DCASES=cpp/tests/driver -DWORK=cpp/build/driver -DUPDATE=1 -P cpp/tests/driver.cmake
```

## docs/language.md

`xc-doc` (`src/doc.cpp`) reads the reference as `t/45-language-doc.raku`
does: each ```` ```xtpl ```` example is compiled, and the ```` ```tlpp ````
right after it is what has to come out, the ```` ```text ```` after those
what xc has to say; each row of a `| xtpl | TL++ |` table is assigned in a
function and has to come out as the TL++ beside it. A change to the output
that an example shows is a change to the document.

## Line ends

The files are kept byte for byte (`.gitattributes`: no conversion of line
ends, no complaint about blanks at the end of a line). The cases whose
sources end their lines with CRLF are in `cases/crlf/`, one folder for each
test file, and travel as binary in a patch: `git am` would strip their CRs
from a patch's text. A new case with CRLF goes there too.
