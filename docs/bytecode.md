# xtpl bytecode

`xc --bytecode file.xtpl` writes `file.xbc`: the same program, checked as
for TL++, as the instructions of a stack machine instead. An interpreter
runs it -- one written in xtpl, on an AppServer, is what the format is made
for: plain text, one instruction a line, nothing to decode but words,
numbers and a string at the end of a line. `interp/xbc.xtpl` is that
interpreter ([The interpreter](#the-interpreter)); `xc-vm`, built with xc,
is the machine as a program ([xc-vm](#xc-vm)).

```xtpl
User Function Soma(aNums)
  Local nTotal := 0
  Local nI := 0
  For nI := 1 To Len(aNums)
    nTotal += aNums[nI]
  Next
Return nTotal
```

```text
xbc 1
source soma.xtpl
statics 0

function U_SOMA user 1 3
  locals aNums nTotal nI
  line 2
  num 0
  setlocal 2
  line 3
  num 0
  setlocal 3
  line 4
  num 1
  setlocal 3
  line 4
  local 3
  local 1
  call 1 Len
  le
  jumpf 28
  line 5
  local 2
  local 1
  local 3
  index
  add
  setlocal 2
  local 3
  num 1
  add
  setlocal 3
  jump 10
  line 7
  local 2
  ret
end
```

`xc --bytecode file.xtpl out.xbc` names the output; `--outdir`,
`--includes` and `--check` work as for TL++, and a folder stands for the
`.xtpl` under it. A `.prw` makes a `.xbc` too.

## The file

A file is lines; a line ends at a LF, and a CR before it is not part of it.
Blanks at the start of a line are not part of it either, and an empty line
is nothing. The file is windows-1252, as the source was.

- `xbc 1` -- the format and its version, the first line.
- `source NAME` -- the source it was made from.
- `statics N` -- how many statics the module has, numbered from 1.
- `namespace NAME` -- the namespace of the module, when it has one: its
  functions but the static ones, and its classes, are named with it
  before them, `XDK.NS.U_SOMA`, as the AppServer names them.
- `using NAME` -- a namespace the module uses, one a line.
- `class NAME` ... `end` -- a class of the module, in upper case, after
  `statics` and before the functions. Inside it, `from NAME...` names the
  classes above it; `data NAME...` its data; `init FUNCTION` the function
  that gives them the values they start at, when one has one; `method NAME
  FUNCTION` each of its methods and the function that is its body, `static
  NAME FUNCTION` each static one. Only `class` and `end` must be there.
- `function NAME KIND PARAMS LOCALS` ... `end` -- a function: its name as
  it is called, in upper case; its kind; how many parameters it takes; how
  many locals its frame has, the parameters the first of them. Then its
  instructions, one a line, numbered from 1 -- what a jump names --, and
  `end`.
- `locals NAME...` -- right after `function`: the names of its locals, in
  order, for an interpreter to show; xc's own are `.t1`, `.t2`...
- `upvals NAME...` -- after `locals`, in a code block's function that
  shares variables: the names of its cells, in order.

The kinds:

| kind | what | its name |
|---|---|---|
| `user` | a `User Function`, or a `Function` whose name starts with `u_` | `U_` and its name: `U_SOMA` |
| `static` | a `Static Function` | its name: `SOMA` |
| `function` | any other `Function`: a regular function | its name |
| `main` | a `Main Function` | its name |
| `block` | the body of a code block or a lambda | its function's, `#` and a number: `U_SOMA#1` |
| `init` | the statics' values, run once when the module is loaded, first | `__INIT` |
| `method` | a `Method` of a class: Self is the object it runs on | its class's, `:` and its own: `CONTA:DEPOSITA` |
| `data` | the values a class's typed data start at, run on each new object, Self the object | its class's and `:__DATA`: `CONTA:__DATA` |

A `static` function is the module's own; `user`, `function` and `main` are
any module's to call; a `method` and a `data` are a class's, for a `class`
to name -- no `call` finds them. The blocks of a function come right after
it, in the order their numbers say.

```xtpl
Class Conta
  Data nSaldo as Numeric
  Method Deposita(nValor)
EndClass

Method Deposita(nValor) Class Conta
  ::nSaldo += nValor
Return Self
```

```text
class CONTA
  data NSALDO
  init CONTA:__DATA
  method DEPOSITA CONTA:DEPOSITA
end

function CONTA:__DATA data 0 0
  locals
  line 2
  self
  num 0
  setmember NSALDO
  nil
  ret
end

function CONTA:DEPOSITA method 1 1
  locals nValor
  line 7
  self
  dup
  member nSaldo
  local 1
  add
  setmember nSaldo
  line 8
  self
  ret
end
```

A word of an instruction is separated from the next by one blank or more.
A string is the last thing on its line, between double quotes: from the
first `"` to the last character of the line, a `"` -- so it may hold
quotes, and never a line end.

## The machine

Each call has a frame: its locals, the values on its stack, the privates it
created, the regions it protects, the areas it selected, the defers it
reached. An instruction takes its operands from the top of the stack and
pushes its result; below, `[a b]` is the stack before it, `b` on top, and
`-> [c]` what it leaves.

Values are AdvPL's. A cell -- what a code block shares with the function
that made it -- and a reference -- a variable passed with `@` -- are the
machine's own: no program sees one.

### Constants

| instruction | does |
|---|---|
| `nil` | `-> [Nil]` |
| `true`, `false` | `-> [.T.]`, `-> [.F.]` |
| `num TEXT` | `-> [n]`: the number AdvPL reads `TEXT` as -- `12`, `0.5`, `1250.75` |
| `str "TEXT"` | `-> [c]` |

### Variables

| instruction | does |
|---|---|
| `local N`, `setlocal N` | `-> [x]` the value of local N; `[x] ->` sets it |
| `box N` | local N becomes a cell holding the value it has -- at a function's start, before anything else, for a local a code block shares |
| `cell N`, `setcell N` | reads, sets the value in local N's cell |
| `upval N`, `setupval N` | in a code block's function: reads, sets the value in its cell N |
| `static N`, `setstatic N` | reads, sets the module's static N |
| `memvar NAME`, `setmemvar NAME` | reads, sets the variable NAME, in upper case: the innermost private of that name, else the public; with none, reading is an error ("variable does not exist") and setting creates a private in the frame, as AdvPL does |
| `private NAME` | creates a private NAME in this frame, Nil: it hides one of the same name until the frame ends; one the frame has already is given Nil |
| `public NAME` | creates a public NAME, Nil, unless there is one |
| `field ALIAS NAME`, `setfield ALIAS NAME` | `ALIAS->NAME`, both in upper case: `field SA1 A1_NOME`; the alias `FIELD` is the area selected |
| `fieldx NAME` | `[alias] -> [x]`: `(alias)->NAME` |
| `setfieldx NAME` | `[alias x] ->` |

`M->X` and `MEMVAR->X` are the memvar `X`. A static is set by `__INIT`
before anything runs: a file's `Static`s, then each function's, as they are
written; one declared in a function is that function's to read.

### References

`@x` passes a variable by reference: the call's argument is a reference to
it, made by `reflocal N`, `refcell N`, `refupval N`, `refstatic N` or
`refmemvar NAME` -- with no such memvar, `refmemvar` creates a private. The
parameter is given the variable's value, and when the call returns, the
parameter's last value is written back to the variable. For a function of
the AppServer, the interpreter passes a variable of its own by reference,
and writes it back the same way.

### The stack, arrays and objects

| instruction | does |
|---|---|
| `pop`, `dup` | `[x] ->`; `[x] -> [x x]` |
| `dup2` | `[a b] -> [a b a b]` |
| `array N` | `[x1 ... xN] -> [{x1, ..., xN}]` |
| `index` | `[a i] -> [a[i]]` -- of an array, or of a JsonObject by key |
| `setindex` | `[a i x] ->`: `a[i] := x` |
| `member NAME` | `[o] -> [o:NAME]` |
| `setmember NAME` | `[o x] ->`: `o:NAME := x` |
| `self` | `-> [Self]`: in a method, the object it runs on; in a code block's function, the Self of the frame that made the block |

### Operators

Each is AdvPL's own, on the values as they are:

| instruction | operator | | instruction | operator |
|---|---|---|---|---|
| `add` | `+` | | `eq` | `=` |
| `sub` | `-` | | `exact` | `==` |
| `mul` | `*` | | `ne` | `!=` `<>` `#` |
| `div` | `/` | | `lt` `gt` | `<` `>` |
| `mod` | `%` | | `le` `ge` | `<=` `>=` |
| `pow` | `**` `^` | | `contains` | `$` |
| `neg` | `-x` | | `not` | `!x` |

`isnil` is `[x] -> [x == Nil]`, for a value of any type.

### Jumps

`N` is an instruction of the same function.

| instruction | does |
|---|---|
| `jump N` | goes to N |
| `jumpf N`, `jumpt N` | `[l] ->`, and goes to N if `l` is `.F.`, `.T.` |
| `andjump N` | `[l]`: if `l` is `.F.`, goes to N and leaves it; else `->` and on |
| `orjump N` | `[l]`: if `l` is `.T.`, goes to N and leaves it; else `->` and on |

`.And.` and `.Or.` stop at the first side that decides, as AdvPL's do.

### Calls

| instruction | does |
|---|---|
| `call ARGC NAME` | `[x1 ... xARGC] -> [result]`: NAME as written; a function of the module by that name in upper case, else -- a NAME with no `.` -- its namespace's, then those of the namespaces it uses, in their order; else one any module has for others to call by that name, else the AppServer's -- a class is none |
| `callx ARGC` | `[name x1 ... xARGC] -> [result]`: `&name.(...)` -- the name looked for as `call` does, but in no namespace: as the AppServer's macro |
| `method ARGC NAME` | `[o x1 ... xARGC] -> [o:NAME(...)]` |
| `super ARGC NAME` | `[x1 ... xARGC] -> [result]`: `_Super:NAME(...)` -- the method NAME of the classes above the one the running method is of, on Self |
| `new ARGC CLASS NAME` | `[x1 ... xARGC] -> [o]`: `CLASS():NAME(...)` -- a new object of CLASS, its method NAME run on it with the arguments; the object is the value, whatever NAME returns. For a static NAME, no object: the value is what NAME returns. CLASS is found as `call` finds a function |
| `ret` | `[x] ->`: the frame ends, and the caller gets `x` |
| `block NAME K` | `[c1 ... cK] -> [b]`: a code block whose body is the function NAME, its cells `c1 ... cK` |
| `macro` | `[text] -> [&(text)]` |
| `setmacro` | `[text x] ->`: `&(text) := x` |
| `line N` | the line of the source the next instructions are on, for errors |

The arguments are pushed in order, an omitted one as `nil`. A function of
the module gets them as its first locals; a parameter given none is Nil,
an argument beyond them is dropped -- and `PCount()` is how many it was
given. A `Return` with no value returns Nil, and so does a function that
reaches its end.

A code block of the module -- `block` makes one -- is run by `Eval()` and
by anything given it, an AppServer function included: the interpreter
hands those one of the AppServer's own code blocks that runs it. Its cells
are what it shares with the function that made it: `refcell N` pushes local
N's, `refupval N` the block's own cell N, for one inside another.

### Classes

`new` makes an object of a module's class: the data of the classes above
it and its own, each once, Nil; then each class's `init` function runs on
it, the topmost class's first; then the method `new` names, which must be
there ("Cannot find method CLASS:NAME"). A static method is run with no
object -- Self is Nil -- and its value is what the caller gets. A class
`from` names is found from the module of the class that names it, as a
function is. Its frame is a method's, and when
it returns, the caller gets the object -- `Conta():Zera()` is an object even
when `Zera()` returns `.T.`, as on the AppServer. A CLASS no module has is
the AppServer's -- `THashMap`, `JsonObject` --: the interpreter makes the
object there, and the value is what NAME gives; with none, it is an error
("invalid class CLASS").

On an object of a module's class, `member` and `setmember` read and set its
data -- NAME in upper case; one it does not have is an error --, and
`method` runs the function its class names for NAME, else the one a class
above it names, in the order `from` says: a frame like a call's, Self the
object. With none, it is an error ("no method NAME of CLASS"). A class above
that is no module's is the AppServer's: `super ARGC NEW` of one leaves
Self, and its other methods are not there.

### Sequences and errors

| instruction | does |
|---|---|
| `seq N` | protects what follows, to the `endseq`: a `Break` there unwinds to here |
| `try N` | the same, and an error there is caught too |
| `endseq` | ends the innermost region of the frame |

A `Break(x)` -- a call of `Break`, in this frame or in any it called --
goes to the innermost region: the frames above go, this one's stack is cut
back to what it was at the region, the region and those inside it end, `x`
is pushed and it goes to N. An error goes to the program's `ErrorBlock()`
first, as AdvPL's do -- `ErrorBlock({|e| Break(e)})` makes it a break --;
one it does not break goes to the innermost `try`, with the error object. A
frame's regions end with it.

### Areas

| instruction | does |
|---|---|
| `area` | `[alias] ->`: selects the area the alias names -- a name, or a number --, the one selected before kept |
| `endarea` | selects again the area the innermost `area` of the frame kept |

`SA1->(...)` is `area`, its expression, and `endarea`. A region a break or
an error goes to forgets the areas kept inside it, and selects none.

### Defers

| instruction | does |
|---|---|
| `defer ID N` | the code at instruction N is to run when the function returns, once however many times this is reached |
| `rundefers` | runs the deferred code reached so far -- the highest ID first -- and forgets it |
| `enddefer` | ends a piece of deferred code: back to the `rundefers` running it |

The IDs are numbered in the order the `defer`s are written, so the last
written runs first, as for TL++. The deferred code comes after the
function's last `ret`.

## What becomes what

A `Local` is a local, numbered in the order the function declares them,
parameters first; xtpl's block locals and xc's own -- a limit, a subject,
an area, a value read twice -- get theirs after. A block local declared
with no value is given Nil each time its declaration runs, whatever its
type, as TL++'s is. Any other declared with a type and no value starts
where TL++ starts it -- in a `.prw`, at Nil: a `Numeric` at 0, a
`Character` at `""`, a `Logical` at `.F.`, a `Date` at 31 December 1899.
A `Static` is a static, a `Private` and a `Public` memvars, a name nothing
declares a `memvar`. A `#define` of the
file is its value, wherever its name is used; `CRLF`, which `totvs.ch`
defines, is `Chr(13) + Chr(10)`.

`If`, `Do Case`, `Do While`, `For` and xtpl's `for ... in` and `for N times`
are jumps. A `For`'s `To` and `Step` are evaluated each time round, as
AdvPL's are; a `Step` that is no number literal decides which way it
counts when it runs. `IIf()` and `If()` evaluate only the branch they take.
`Begin Sequence` is a `seq`, TL++'s `Try` a `try` -- its `Finally` after
the body, after the `Catch`, and on an `Exit`, a `Loop` or a `Return` out of
either --, `Begin Transaction` a call of `BeginTran()` before its body and
`EndTran()` after. An `Exit` or a `Loop` ends the regions it leaves.

A `Class` is a `class`, its `Method`s functions of kind `method`; an
`Interface` is nothing, being signatures. A `Data` with a type starts where
a typed `Local` does -- in a `.prw`, at Nil --, one without at Nil: its
`Default` or `Init` value is ignored, as the AppServer ignores it (tried on
24.3.1.9). The machine does not check a member's visibility. `Name():M(...)`
-- `Name` with no arguments -- is a `new`, whatever `Name` is, as for TL++;
`Self` is `self`, `::x` Self's `x`, `_Super:New(...)` a `super`. A `Static
Method` is a `static` of its class.

A `namespace` is the module's `namespace`, its `using`s its `using`s; a
name in a call is as it is written -- `xdk.ns.u_Soma()` is `call 0
xdk.ns.u_Soma` --, and the machine finds it, as the AppServer does (tried
on 24.3.1.9): a plain name first in the module, then in its namespace, then
in those it uses, then where no namespace is.

xtpl's own forms are what they are for TL++:

- a hash is the runtime's: `{"a" => 1}` is `u_xtpl_hnew({{"a", 1}})`,
  `h{k}` `u_xtpl_hget(h, k)`, `h{k} := v` `u_xtpl_hset(h, k, v)`, `has`
  `u_xtpl_hhas()`, `{ => }` `THashMap():New()`; a JSON object
  `u_xtpl_jnew()`, `{ : }` `JsonObject():New()`;
- `x in a` is `u_xtpl_in()`, `x in lo..hi` two comparisons, `%%` a `%` and
  a comparison with 0;
- `?:`, `?.` and `?=` test with `isnil`;
- `fallback` is TL++'s: `ErrorBlock({|e| Break(e)})`, a `seq` around the
  value, the alternative after it, and the error block put back -- as a
  statement's whole value, the statement inside the `seq`, the target
  given the value there, as TL++ writes it;
- a string with `${}` is a sum of strings and `cValToChar()`s;
- a lambda is a code block, and a function's name where a verb takes a
  block, `{|__it| name(__it)}`;
- a chain is a loop where TL++ makes one -- a statement's whole value, a
  block's `Local`, a `Private`, a `Public`, a `Return`, a statement of its
  own, what a `fallback` there guards: a chain from `rows()`, `lines()` or
  a range, or over an array where its stages fuse (`docs/language.md`,
  When a chain is a loop) --, the same loop, its stages inside it, each
  lambda's parameter the element: so a `tap` before a `take` sees only what
  the loop reads, as in TL++. Anywhere else a chain is its stages' calls,
  the value before each its first argument;
- `for x in lines(path)` reads the file as TL++'s does -- the line taken at
  the top of each round, the file closed after the loop and on a `Return`
  out of it;
- `defer` is `defer`; `using alias` the calls that select the area, its
  record and its order, and put them back on every way out; `with object`
  a local for the subject;
- `aTail(a) := x` is `a[Len(a)] := x`, a field a macro names
  `FieldGet(FieldPos(...))` in the area -- `FieldPut()` assigned;
- Decimals the `DEC_` functions, as for TL++.

The runtime -- `runtime/xtpl_runtime.tlpp`, compiled into the RPO -- has to
be there for these, as for TL++.

## Not yet

xc says so, and writes no `.xbc`:

- a web service's method (`WsMethod`);
- what is the preprocessor's: `raw`, a command -- TOTVS' `@ ... SAY`,
  `BeginSql`, one of the source's own --, a translation of the source's
  own, a directive inside a function, `#ifdef` and its kin, a `#define`
  with parameters;
- `@` before what is not a variable: `@aCampos[nX][8]`, `@::x`.

A `#define` from an include file is not seen: its name is a memvar.

## The interpreter

`interp/xbc.xtpl` is the machine written in xtpl, for an AppServer: xc
compiles it to TL++, the AppServer into the RPO, with the runtime. Then

```text
appserver -run=u_xbc -env=NAME [out=FILE] [run=NAME] module.xbc ...
```

loads the modules, runs each one's `__INIT` in the order given, then NAME --
`U_MAIN` when it is not given and there is one, else the first user
function of the last module. The runtime's bytecode may go first, as for
xc-vm, or not: a function no module has is the AppServer's, the runtime's in
the RPO among them. With `out=FILE`, what `ConOut()` is given and an error
nothing catches go to FILE instead, as xc-vm writes them -- `exit N`, `---
output`, its lines, `--- errors`, its lines.

It is the machine of this page, and the AppServer is the rest:

- a function no module has is the AppServer's: a well-known one -- some 150
  functions, methods, constructors and members of the AppServer's, and the
  runtime's own, its user functions and its classes' public methods and
  constructors, each with each number of arguments it takes, in the
  interpreter's own table (`XbcSyscalls()`; `cpp/tests/runtime-calls.cmake`
  writes the runtime's there, and checks them) -- is called by its number
  there, as compiled code; any other through a code
  block a macro makes once for that name, number of arguments and
  references -- `{|a, o, p1, p2, r| r := Upper(p1, @p2), a[2] := p2, r}`
  --; a method or a member of the AppServer's objects, and `Name():M()` of a
  class no module has, the same way;
- a code block of the program is one of the AppServer's that runs it there,
  with as many arguments as its function takes -- so `aEval()`, `aSort()`
  and the runtime's verbs run it;
- an object of a module's class is an `XbcObj`, a class of the interpreter's
  own, whose `ValType()` is `"O"`;
- `ErrorBlock()` is the program's, kept apart: the interpreter runs under
  its own, which gives an error to the program's first, then to the
  innermost `try`; its own errors it raises with `UserException()`;
- a Break is taken by a plain `Recover`, its value kept in a Static on its
  way -- the AppServer runs a `Recover Using` with every Local Nil but its
  variable, and keeps nothing it assigns --: the program's `Break()` is
  the interpreter's own, for that, and a Break in a block that a macro of
  the program's made, which the AppServer runs, arrives with no value;
- the program's privates and publics are the interpreter's: an AppServer
  function does not see them, and a macro other than a variable's name --
  the AppServer's -- does not either;
- `PCount()` is the frame's; a field is `FieldGet()` and `FieldPut()` in its
  area;
- a module is read whole, with `FOpen()` and `FRead()`: `FT_FReadLn()`
  gives a line longer than 1023 characters -- a long string's -- in pieces.
  The AppServer reads files under the environment's RootPath only, so the
  modules and FILE are named there, `\xbc\prog.xbc`; a path with a drive
  letter fails.

It is written in xtpl -- hashes for the names of the machine, chains, block
locals, `for ... in`, interpolation, postfix modifiers, `?:` and `?=`,
`defer` --, so it uses the runtime, which the AppServer has in the RPO.
xc-vm runs it too, after the runtime's bytecode: there are no macros there,
and its `XBC_CALL`, `XBC_METHOD`, `XBC_MEMBER`, `XBC_SETMEMBER` and
`XBC_NEW` call, read and write by name instead --
`FindFunction("XBC_CALL")` tells the interpreter where it is. ctest's
`interp` has xc-vm run the interpreter on each case of `cpp/tests/bytecode`
and on xtpl's self-test, the runtime interpreted too -- and the self-test
again without the runtime's bytecode, its calls of the runtime the table's
--, and what it writes has to be what xc-vm does running them itself; `interp-xc` the same for
xc's self-test, slowly -- labelled `slow` (`cpp/tests/interp.cmake`).
`rakupp run-protheus.raku --interp` does it on an AppServer.

A program that uses Decimals goes wrong in the interpreter on the
AppServer: a slot of its stack, or a variable of its own, that has held a
Decimal makes Decimals of the numbers put there after it, for good (the
AppServer's, [A slot that has held a Decimal](language.md#decimals)) -- a
counter, an index, an argument becomes one. It is left so: `--interp`
leaves out 05-decimal and xc's self-test, which have Decimals.

With `trace=FILE`, the interpreter writes there each instruction it runs
-- the frames' depth, the function, where in it, the instruction, the
stack's height and its top --, each call of the AppServer's with what it
was given and what it gave, and each Break a run took: the first 20,000
lines. It is how a difference on the AppServer is looked into:
`rakupp run-protheus.raku --interp --trace` keeps one for each case, in
`build/logs/interp/`.

It runs what it loads as the loop is fastest at it:

- each instruction has its line, and `line` goes; an error is on the line
  of the instruction the frame ran last -- the last `line` before it in
  the function, as xc-vm has it too;
- a few runs of instructions that programs have again and again are one:
  `local a, local b`; `local a, num n, index` and `local a, local b,
  index`, an array's element; `num n, index`; `local a, num n, add,
  setlocal a`, `x += n`; `num n, add`; `add, setlocal a`; a comparison and
  the `jumpf` after it -- never over an instruction something jumps to;
- a function's frame has one array for its locals and its stack, as big as
  the most its stack holds, worked out when it is loaded;
- the instructions are numbered by how often programs run them, and the
  loop asks for the most frequent first;
- a call finds what it calls the first time it runs, and keeps it: a
  function of a module, one of the AppServer's in the table, `PCount()`,
  `Eval()` of a block -- with no argument by reference -- are then made by
  the loop itself, a frame pushed or the table's block run, with no method
  between; a method of a module's class, and of the AppServer's objects,
  the same way;
- an object of a module's class keeps its data in an array, each at the
  place its class gives its name; `member` and `setmember` find the place
  once for the class they see.

With `trace=FILE`, it runs the instructions as they are in the file, one
by one, so that the trace shows them as written.

Its speed is measured with `interp/bench.xtpl`: parts that each do one
thing over and over -- a loop, calls of the program's functions and of the
AppServer's, an array's elements, a string, methods and data of the
program's class, code blocks, a hash, a chain --, each for a second at
least, printing the time of one of those things in microseconds. `rakupp
run-protheus.raku --bench` has the AppServer run it compiled, then the
interpreter run it as bytecode, and shows both and their ratio. On xc-vm,
`xc-vm --run=U_XBC xtpl_runtime.xbc xbc.xbc -- bench.xbc` against
`xc-vm --run=U_BENCH xtpl_runtime.xbc bench.xbc` does the same, and
`--profile=FILE` says where the interpreter's instructions go.

## xc-vm

`xc-vm [--run=NAME] [--profile=FILE] module.xbc ... [-- ARG ...]` loads
the modules, runs each one's `__INIT` in the order given, then NAME --
`U_MAIN` when it is not given and there is one, else the first user
function of the last module -- with the ARGs after `--`, strings, as its
arguments. What `ConOut()` is given goes to its output, a line for each
argument; an error nothing catches goes to its errors, with the function and
the line -- the last `line` before the instruction it ran last --, and the
exit code is 1. With `--profile=FILE`, FILE gets how many
instructions ran, in all, by function, by function and line, by instruction
and by instruction and the one before it, and how many times each of the
AppServer's functions was called -- the most first.

xtpl's runtime is a module like any other: `xc --bytecode
runtime/xtpl_runtime.tlpp` makes it, and it goes first, the program last --
`xc-vm xtpl_runtime.xbc prog.xbc`. ctest's `bytecode` runs the cases in
`cpp/tests/bytecode` so (`cpp/tests/bytecode.cmake` says how), and
`selftests` the runtime's own tests and xc's -- `xtpl/tests/54_selftest.xtpl`
and `protheus/xc_selftest.xtpl`, the programs the AppServer runs.

It is the machine this page describes, and of the AppServer only what the
runtime and the tests need: some of the strings', numbers', dates' and
arrays' functions, `Eval()`, `Break()`, `ErrorBlock()`, `PCount()`; the
`DEC_` functions, on exact decimals; `File()`, `MemoWrite()`, the `FT_`
functions -- a line longer than 1023 characters in pieces of 1023, and
`FT_FEof()` false with no file open, as the AppServer's -- and `FOpen()`,
`FRead()` and `FClose()`, for reading;
`THashMap` and `JsonObject`, with the methods the runtime calls -- a
`JsonObject`'s keys by `j["name"]` only, as the AppServer's. As the
AppServer's too, `x / 0` is 0 and `x % 0` an error.
`Random()` starts from the same seed each run, so a run repeats;
`Seconds()` counts from midnight UTC, for timing a run. A work
area is a name -- it can be selected and put back, and has no records --,
and a macro is a variable's name.
