# xtpl, as xc reads it

xtpl is TL++ with extensions: block locals, lambdas, chains with `|>`,
hashes, `defer`, `using alias`, string interpolation and a few operators.
xc compiles it to plain TL++ for Protheus. This is the reference for the
language as xc reads it today: what it takes, what it makes of it, and what
it refuses.

Every example here was compiled by xc, and the output shown is what it
wrote; `t/45-language-doc.raku` compiles them again with the other tests.
When an example has no include lines, the two xc adds are left out of its
output.

- [The output](#the-output)
- [Lines, comments and names](#lines-comments-and-names)
- [Literals](#literals)
- [A file](#a-file)
- [Declarations](#declarations)
- [Statements](#statements)
- [Expressions](#expressions)
- [Chains](#chains)
- [A source's own commands](#a-sources-own-commands)
- [The checks](#the-checks)
- [The runtime](#the-runtime)
- [Names xc keeps](#names-xc-keeps)

## The output

**Source plus edits.** xc copies the source through and rewrites only what
is xtpl's: everything that is already TL++ comes out as it went in, byte for
byte -- layout, comments, blank lines, the case of every word. A file that is
plain TL++ comes out unchanged, but for two includes: `totvs.ch` at the top
when the file does not include it, and `tlpp-core.th` after the last `.ch`
include when it does not include that.

**Encoding and line ends.** A source is read as UTF-8, or as windows-1252
when it is not valid UTF-8, and the output is written in the same encoding,
with the same line ends and the same byte order mark, if any.

**Comments of a rewritten statement.** A statement xc rewrites loses its
trailing comment to the rewrite and gets it back, two spaces after the new
code: on the header line when the rewrite opens a block, on the last line
otherwise.

**Locals xc adds.** Some rewrites need variables of their own -- a loop's
counter, a hash's subject, the area a `using alias` found. xc declares them
after the function's prologue, each with a comment saying what it is:

```tlpp
  Local fi_0_0  // the position in the array walked
  Local fv_0_0  // the element walked
  Local fo_0_0  // the result of the chain
```

Their names have shapes a function may not declare as its own (see
[Names xc keeps](#names-xc-keeps)).

**The runtime.** Some rewrites call functions of xtpl's runtime,
`runtime/xtpl_runtime.tlpp` -- `u_xtpl_map`, `u_xtpl_hget`, ... -- which
has to be compiled into the RPO with the generated code
([The runtime](#the-runtime)).

**Messages.** xc names the file and the line:

```text
consts.xtpl:3: 'nMax' is <const> (declared on line 2) and cannot be assigned.
decl.xtpl:5: warning: 'cX' is assigned but never read
lambda.xtpl:2: cannot parse this line: Local aOut := map(aNums, [x] x |> triple)
```

An error stops that file -- nothing is written for it; a warning does not.
`cannot parse this line` is the grammar's refusal, at the first line the
parse could not get past.

## Lines, comments and names

**One statement per line.** A line break ends a statement. A line that ends
in `;` carries on to the next, and a comment may follow that `;`. A `;` with
more code after it on the same line ends a statement and starts another.

```xtpl
User Function Soma(nA, nB)
  Local nTotal := nA + ;   // the first
                  nB
  conout(1); conout(2)
Return nTotal
```

**Comments** are `// ...` to the end of the line and `/* ... */`, which may
span lines. AdvPL's `&&` and `*` comments are not read.

**Case.** Keywords and names are read without regard to case: `IF`, `If` and
`if` are the same word, and so are `nTotal` and `NTOTAL`. The output keeps
the case written.

**Names** are a letter or `_`, then letters, digits and `_`. Some cannot be
declared: see [Names xc keeps](#names-xc-keeps).

## Literals

| Literal | Examples |
|---|---|
| number | `42`, `3.14`, `.5`, `12'345'678`, `1'234.567'8` |
| string | `"text"`, `'text'`, `"total = ${nTotal}"` |
| logical | `.T.`, `.F.` |
| nil | `Nil` |
| array | `{}`, `{1, 2, 3}`, `{ "P", , 1 }` -- an empty element is Nil |
| hash | `{"rate" => 1.5}`, `{ => }` |
| JSON object | `{"name": cName}`, `{ : }` |
| code block | `{\|\| Time()}`, `{\|x\| x * 2}` |
| lambda | `[x] x * 2`, `[acc, x] acc + x` |

**Numbers.** Digits may be grouped with an apostrophe, between two digits
only, as C++14 does; the output drops it. A number may start with its point,
as Clipper writes it.

```xtpl
  Local nBig := 12'345'678
  Local nDec := 1'234.567'8
  Local nHalf := .5
```

```tlpp
  Local nBig := 12345678
  Local nDec := 1234.5678
  Local nHalf := .5
```

**Strings** take either quote and have no escapes. A string not closed by
the end of its line ends there, as TL++ takes it (`cQ := "SELECT X`), and
the checks warn. `${expression}` inside a string, of either quote, is
[interpolation](#interpolation). A `$` not followed by `{` is text:
`"R$ 10"`.

Hashes, JSON objects and lambdas are [expressions](#expressions) xc
rewrites; arrays and code blocks are TL++'s own.

## A file

A file holds, in any order:

- preprocessor directives -- `#include`, `#define`, `#ifdef`, `#command`,
  `#xtranslate`, ... -- each passed through whole, with its continuation
  lines;
- `namespace minha.empresa` and `using namespace ...`;
- `external` declarations;
- file statics: `Static aCache := {}`;
- functions, classes, interfaces, method implementations, web services;
- annotations, before the function or method they annotate;
- TOTVS' commands ([TOTVS' commands](#totvs-commands)), and those the
  source declares itself ([A source's own commands](#a-sources-own-commands)).

### external

```xtpl
#include "totvs.ch"
external CRLF, dDataBase
external alias SB1

User Function Ext()
  conout(DToC(dDataBase) + CRLF + SB1->B1_DESC)
Return nil
```

```tlpp
#include "totvs.ch"
#include "tlpp-core.th"

User Function Ext()
  conout(DToC(dDataBase) + CRLF + SB1->B1_DESC)
Return nil
```

A promise, not a declaration: `external` names variables that exist but no
declaration in the file shows, and `external alias` names work areas the
caller opens. It writes nothing. It goes at file level, with at least one
name. An external cannot be assigned. A name nothing declares is only a
warning anyway ([The checks](#the-checks)); `external` says it is meant.

### Functions

```xtpl
User Function Saldo(cCod as Character, nQtd)
Static Function Calcula(nBase) as Numeric
Main Function Principal()
Function u_Bare(nX)
```

`User`, `Static` and `Main`, or none: xc takes a bare `Function`, which TL++
allows when the name starts with `u_`. Parameters may be typed, `as
Numeric`, and take the attributes of a local, `<const>` and `<contained>`.
The return type goes after the parentheses. A `User Function` needs no
parentheses when it takes nothing.

A function ends where the next function, class or method starts. `Return` is a
statement like any other, and a function's last line should be one: Protheus
warns about a function that ends without it (W0019), and so does xc.
`EndFunction`, `EndFunc` and `EndMethod` are no keywords of TL++'s: the
AppServer takes such a word as a name on its own, a line that does nothing
(W0001), and xc reads it so, with a warning.

### Classes and interfaces

TL++'s own, and passed through as written:

```xtpl
#include "totvs.ch"
#include "tlpp-core.th"

Interface IConta
  Public Method Saldo() as Numeric
EndInterface

Class Conta From LongNameClass Implements IConta
  Public Data nSaldo as Numeric default 0
  Public Method New() Constructor
  Public Method Saldo() as Numeric
  Public Operator Add(oOutra)
EndClass

Method New() Class Conta
Return Self

Method Saldo() Class Conta as Numeric
Return ::nSaldo

Operator Add(oOutra) Class Conta
  ::nSaldo += oOutra:nSaldo
Return Self
```

- `Class Name [From|Inherit Super, ...] [Implements Iface, ...]` ...
  `EndClass` (or `End Class`); a superclass may carry its namespace.
- `Data name [as Type] [default|init value]`, several to a line, with a
  visibility (`Public`, `Protected`, `Private`, `Exported`, `Hidden`) or
  none.
- `Method name(...)` and `Operator name(...)`, with a visibility or
  `Static`, `Constructor` and `as Type` in either order.
- An implementation, at file level: `Method name(...) Class Name`, with
  `as Type` before or after `Class Name`, and its body.
- Inside a method, `::x` is `Self:x` -- a value, a call, a target.
- `Interface Name` ... `EndInterface`: method signatures only.

### Annotations

A line starting with `@` and a name, with arguments or not, before what it
annotates: `@Get("/api/v1/saldo")` before a function or a method. A line
that starts with `@` and goes on as an assignment, `@oJSON := x`, is an
assignment.

### Web services

AdvPL's web services come from include files xc cannot read (`restful.ch`,
`apwebsrv.ch`). xc takes the declaration -- `WSRESTFUL Name` ...
`END WSRESTFUL`, and `WSSERVICE`, `WSSTRUCT`, `WSCLIENT` the same way --
whole, and each method's implementation as a function: its header as
written, through its continuation lines, ending in `WSSERVICE Name`,
`WSRESTFUL Name` or `WSREST Name`, and its body read like any other, `::`
and `Self` included.

```xtpl
#include "totvs.ch"
#include "restful.ch"

WSRESTFUL Clientes DESCRIPTION "Clientes"
  WSDATA cCod AS STRING
  WSMETHOD GET DESCRIPTION "Lista" WSSYNTAX "/clientes"
END WSRESTFUL

WSMETHOD GET WSRECEIVE cCod WSSERVICE Clientes
  Local lRet := .T.
  ::SetContentType("application/json")
  ::SetResponse('[]')
Return lRet
```

## Declarations

```xtpl
User Function Decl(cName as Character, nQty)
  Local nTotal as Numeric := 0
  Local aBuf <contained, const> := {}
  Local aDados[10], aTela[2][3]
  Local cX := "a", cY as Character
  Private lOk := .T.
  nTotal := nQty * 2 + Len(aBuf) + Len(aDados) + Len(aTela) + Len(cX + cY)
Return nTotal
```

```tlpp
User Function Decl(cName as Character, nQty)
  Local nTotal := 0 as Numeric
  Local aBuf := {}  // [contained, const]
  Local aDados[10], aTela[2][3]
  Local cX := "a", cY as Character
  Private lOk := .T.
  nTotal := nQty * 2 + Len(aBuf) + Len(aDados) + Len(aTela) + Len(cX + cY)
Return nTotal
```

`Local`, `Static`, `Private` and `Public`, one or more declarators to a
line, separated by commas. A trailing comma is refused: a declaration that
goes on to the next line ends in `;`.

**Types.** The type comes before the value or after it. TL++ only takes it
after, so xc moves it there. Only one of the two places: `Local nX as
Numeric := 1 as Numeric` is refused. The types are TL++'s, by their whole
names -- `as N` is "Invalid Type N" to Protheus, and an error to xc:
`Numeric`, `Character`, `Logical`, `Date`, `Array`, `Object`, `CodeBlock`,
`JSON`, `Variant`, `Integer`, `Decimal`, `Double`, and `Variadic` -- a
parameter that takes every argument there is, read as `parm:vCount` and
`parm:vArgs[i]`. `Char` is refused, as Protheus refuses it ("Use Character
Type instead of Char Type"). xc does not yet check that a value agrees with
the type declared.

**Attributes**, between the name and the value, outside TL++: `<const>` --
the variable is never assigned again nor passed by reference with `@`, so it
needs a value to start with -- and `<contained>` -- it does not leave its
block: no code block or lambda names it, and no `defer` reads it.
The output keeps them as a comment.

**Dimensions** after the name make an array of that size, its elements Nil:
`Local aDados[10]`, `Private aTela[0][0]`.

**Default**, from `totvs.ch`: `Default nQtd := 1, cTipo := "A"` gives each
its value when it is Nil. It is a statement, and passes through.

### The prologue

A function's locals and statics come first, before its first statement:
Protheus refuses a `Local` after a statement, and so does xc.

```xtpl
User Function Prol()
  Local nA := 1
  conout(nA)
  Local nB := 2
Return nB
```

```text
prol.xtpl:4: 'local' cannot be declared here: every local comes before the first statement of its function or its block -- 'Local nB := 2'
```

Any statement that is not a declaration closes the prologue -- a `Default`
too, which is an `If` once the preprocessor is done with it. `Private` and
`Public` are statements in TL++: they create the variable when they run, and
may come anywhere a statement may. They close the prologue too, so a `Local`
after one is an error. A `Static` may come anywhere, and is the file's.

### Block locals

A block has a prologue of its own: the first body of an `If`, a `While`, a
`For`, a `for ... in`, a `for ... times`, a `using alias` and a `with
object`. A `Local` there is a **block local**: its name lives from its
declaration to the end of the block, and after that it is out of scope.

```xtpl
User Function BlockLoc(aItems)
  Local nSum := 0
  If Len(aItems) > 0
    Local nFirst := aItems[1]
    nSum += nFirst
  EndIf
  While nSum < 10
    Local nStep := 2
    nSum += nStep
  EndDo
Return nSum
```

```tlpp
User Function BlockLoc(aItems)
  Local nSum := 0
  Local s_0_0  // a slot: the block locals 'nFirst', 'nStep'
  If Len(aItems) > 0
    s_0_0 := aItems[1]  // nFirst
    nSum += s_0_0
  EndIf
  While nSum < 10
    s_0_0 := 2  // nStep
    nSum += s_0_0
  EndDo
Return nSum
```

TL++ has no block locals, so each becomes a `Local` of the function, after
its prologue, and its declaration an assignment -- to Nil when it had no
value, so that it starts as a new variable each time. Block locals that are
never alive at the same time share one `Local`, a **slot**, and the comments
say which is which.

A block local keeps a `Local` of its own, with its own name when that is
free, when it can be reached after its block: when a code block or a lambda
names it, when it is passed by reference with `@`, when a `defer` reads it,
or when raw text names it.

```xtpl
User Function Pinned(aItems)
  Local aBlocks := {}
  If Len(aItems) > 0
    Local nFirst := aItems[1]
    aAdd(aBlocks, {|| nFirst})
  EndIf
Return aBlocks
```

```tlpp
User Function Pinned(aItems)
  Local aBlocks := {}
  Local nFirst  // a block local
  If Len(aItems) > 0
    nFirst := aItems[1]
    aAdd(aBlocks, {|| nFirst})
  EndIf
Return aBlocks
```

The bodies of `ElseIf`, `Else`, `Case`, `Otherwise`, `Begin Sequence`,
`Recover`, `Try`, `Catch`, `Finally` and `Begin Transaction` belong to the
block they are part of and open no prologue: no declarations there. Two
block locals of the same name in one block are an error.

### Declaring in a block's header

`If`, `While` and `Do Case` may declare a block local in their header, and
`For` may make its counter one:

```xtpl
User Function Headers(aItems, cCode)
  Local nPos := 0
  If local nAt := aScan(aItems, cCode), nAt > 0
    nPos := nAt
  EndIf
  While local cLine := NextLine(), !Empty(cLine)
    conout(cLine)
  EndDo
  For local nX := 1 To Len(aItems)
    conout(aItems[nX])
  Next
  Do Case With local cKind := Upper(cCode)
  Case cKind == "A"
    nPos := 1
  Otherwise
    nPos := 2
  EndCase
Return nPos
```

```tlpp
User Function Headers(aItems, cCode)
  Local nPos := 0
  Local s_0_0  // a slot: the block locals 'nAt', 'cLine', 'nX', 'cKind'
  s_0_0 := aScan(aItems, cCode)
  If s_0_0 > 0
    nPos := s_0_0
  EndIf
  While .T.
    s_0_0 := NextLine()
    If !(!Empty(s_0_0))
      Exit
    EndIf
    conout(s_0_0)
  EndDo
  For s_0_0 := 1 To Len(aItems)
    conout(aItems[s_0_0])
  Next
  s_0_0 := Upper(cCode)
  Do Case
  Case s_0_0 == "A"
    nPos := 1
  Otherwise
    nPos := 2
  EndCase
Return nPos
```

The header's declaration needs a value. In `If` and `While` it comes after
`local`, then a comma and the condition. `ElseIf` does not declare. Without
`local`, `Do Case With x := e` assigns a variable declared before and tests
it in each `Case`.

## Statements

### Assignment

`:=`, `=`, `+=`, `-=`, `*=`, `/=`, to a variable, an element, a member, a
field, `::x`, `aTail(a)`, a macro (`&cVar := x`, `&(cVar) := x`) or an
`@`-name (`@oJSON := x`). An assignment is a value: `nA := nB := 5`,
`If lOk := aRet[1]`. As a statement `=` assigns; in an expression it
compares.

`n++`, `++n`, `a[i]--`: TL++'s increments, as statements and in
expressions -- on a variable, an element, a field, never a literal.

### Assign if Nil: `?=`

```xtpl
  cCache ?= "empty"
```

```tlpp
  If cCache == Nil
    cCache := "empty"
  EndIf
```

Only as a statement of its own. Inside an expression, `?:` is the one
([`?:`](#elvis-and-safe-access)); in a declaration it could never fail its
test, and is refused.

### Blocks

TL++'s, with the closers Clipper takes, and xtpl's:

| Statement | Closed by |
|---|---|
| `If` ... `ElseIf` ... `Else` | `EndIf`, `End If`, `End` |
| `While`, `Do While` | `EndDo`, `End Do`, `End` |
| `For i := a To b [Step s]` | `Next`, `Next i`, `Next (i)` |
| `Do Case` ... `Case` ... `Otherwise` | `EndCase`, `End Case`, `End` |
| `for x in ...`, `for n times` | `Next` -- nothing else |
| `Begin Sequence` ... `Recover [Using e]` | `End Sequence`, `End` |
| `Try` ... `Catch [e]` ... `Finally` | `EndTry` -- not `End Try`, which Protheus refuses |
| `Begin Transaction` | `End Transaction` |
| `using alias` | `End Using` |
| `with object` | `End With` |
| `raw` | `End Raw` |

`If( c, a, b )` alone on its line is AdvPL's `If()` function, `IIf`'s twin,
not a block. `Exit` and `Loop` leave and repeat the loop; `Break [value]`
goes to the `Recover` of a `Begin Sequence`; `Return()` returns nothing, as
`Return` does.

`Default` alone on its line, where `Otherwise` should be, is no label: the
AppServer takes it as a name on its own (W0001) and the lines after it
belong to the case before. xc reads it the same way, with a warning.

### for ... in

```xtpl
User Function ForIn(aItems)
  Local nTotal := 0
  for oItem in aItems
    nTotal += oItem:nValue
  next
  for oItem, nPos in aItems
    conout(cValToChar(nPos))
  next
  for nI in 1..5
    nTotal += nI
  next
  for 3 times
    conout("line")
  next
Return nTotal
```

```tlpp
User Function ForIn(aItems)
  Local nTotal := 0
  Local s_0_0  // a slot: the block locals 'oItem', 'nI'
  Local fs_0_0  // the source of a 'for ... in'
  Local fi_0_0  // the counter of a 'for ... in'
  Local nPos  // a block local
  Local fs_0_1  // the source of a 'for ... in'
  Local fi_0_1  // the counter of a 'for ... in'
  Local fi_0_2  // the counter of a 'for ... times'
  fs_0_0 := aItems
  For fi_0_0 := 1 To Len(fs_0_0)
    s_0_0 := fs_0_0[fi_0_0]
    nTotal += s_0_0:nValue
  next
  fs_0_1 := aItems
  For nPos := 1 To Len(fs_0_1)
    s_0_0 := fs_0_1[nPos]
    conout(cValToChar(nPos))
  next
  For fi_0_1 := 1 To 5
    s_0_0 := fi_0_1
    nTotal += s_0_0
  next
  For fi_0_2 := 1 To 3
    conout("line")
  next
Return nTotal
```

`for x in source` walks an array; `for x, i in source` gives the position
too. Both names are new block locals of the loop, declared by the header --
so there is no `local` in it, and `for local x in a` is refused. The source
is any expression, a chain included, and is read once. `for x in lo..hi`
counts. `for x in lines(cFile)` reads a file line by line, and closes it on
every way out of the loop ([Sources](#sources)). `for x in rows(...)` is
refused: a loop body can move the table's position, and `Loop` would skip
the advance -- walk an area with a chain, or write the `While` yourself.

`for n times` runs its body n times; n is any expression.

### Postfix modifiers

A simple statement may end in `if condition` or `while condition`:

```xtpl
User Function Mods(nTotal)
  Local lDone := .F.
  lDone := .T. if nTotal > 5
  conout("x") while nTotal-- > 0
  exec Reset() if nTotal == 0
  return(nTotal) if nTotal > 100
Return iif(lDone, 1, 0)
```

```tlpp
User Function Mods(nTotal)
  Local lDone := .F.
  If nTotal > 5
    lDone := .T.
  EndIf
  While nTotal-- > 0
    conout("x")
  EndDo
  If nTotal == 0
    Reset()
  EndIf
  If nTotal > 100
    return(nTotal)
  EndIf
Return iif(lDone, 1, 0)
```

The simple statements are assignments, calls, `?=`, increments, chains run
for their effect, `Return`, `Exit`, `Loop`, `Break` and `Default`. Block
statements and declarations take no modifier. The condition runs to the end
of the line. `return if lSkip` returns nothing when `lSkip` -- the `if` is a
modifier, not the value. `exec expression` marks an expression as a
statement, and only exists with a modifier.

### defer

```xtpl
User Function Defers(cFile)
  Local nH := FOpen(cFile)
  defer FClose(nH)
  defer conout("saindo")
  using alias SA1 do
    return -1 if SA1->(Eof())
  end using
Return 1
```

```tlpp
User Function Defers(cFile)
  Local nH := FOpen(cFile)
  Local far_0_0  // the area selected before a 'using alias'
  Local frc_0_0  // the record the area was on before a 'using alias'
  far_0_0 := Alias()
  DbSelectArea("SA1")
  frc_0_0 := SA1->(RecNo())
    If SA1->(Eof())
      conout("saindo")
      FClose(nH)
      SA1->(DbGoto(frc_0_0))
      If !Empty(far_0_0)
        DbSelectArea(far_0_0)
      EndIf
      return -1
    EndIf
  SA1->(DbGoto(frc_0_0))
  If !Empty(far_0_0)
    DbSelectArea(far_0_0)
  EndIf
conout("saindo")
FClose(nH)
Return 1
```

A statement -- a call, an assignment or a chain -- to run on the way out of
the function, the last written first. xc writes it before every `Return`
that comes after it in the text, the function's last one included, and
ahead of the areas a `using alias` puts back: they may still want them.

A `defer` goes by its place in the text, not by whether its line ran: one
inside an `If` runs at the returns after the `If` even when the `If` was
not taken. It takes no modifier -- in `defer f() if c` there would be no
telling whose `if` it is.

### using alias

```xtpl
User Function Using(cCod)
  Local nTotal := 0
  using alias SA1 order 1 do
    SA1->(DbSeek(xFilial("SA1") + cCod))
    nTotal := SA1->A1_SALDO
    return nTotal if nTotal > 100
  end using
Return nTotal
```

```tlpp
User Function Using(cCod)
  Local nTotal := 0
  Local far_0_0  // the area selected before a 'using alias'
  Local frc_0_0  // the record the area was on before a 'using alias'
  Local fol_0_0  // the index order before a 'using alias'
  far_0_0 := Alias()
  DbSelectArea("SA1")
  frc_0_0 := SA1->(RecNo())
  fol_0_0 := SA1->(IndexOrd())
  SA1->(DbSetOrder(1))
    SA1->(DbSeek(xFilial("SA1") + cCod))
    nTotal := SA1->A1_SALDO
    If nTotal > 100
      SA1->(DbSetOrder(fol_0_0))
      SA1->(DbGoto(frc_0_0))
      If !Empty(far_0_0)
        DbSelectArea(far_0_0)
      EndIf
      return nTotal
    EndIf
  SA1->(DbSetOrder(fol_0_0))
  SA1->(DbGoto(frc_0_0))
  If !Empty(far_0_0)
    DbSelectArea(far_0_0)
  EndIf
Return nTotal
```

Selects the area, sets the index order if one is given, and puts back the
area, the record and the order it found at every way out of the block -- a
`Return`, and an `Exit` or `Loop` that leaves it, included. The name is the
alias, or a variable of the function holding one. Only `End Using` closes
it.

### with object

```xtpl
User Function WithObj(oModel, cCod)
  Local cName := ""
  with object oModel:GetModel("SA1DETAIL")
    :SetValue("A1_COD", cCod)
    cName := :GetValue("A1_NOME")
  end with
Return cName
```

```tlpp
User Function WithObj(oModel, cCod)
  Local cName := ""
  Local fbs_0_0  // the subject of a 'with object'
  fbs_0_0 := oModel:GetModel("SA1DETAIL")
    fbs_0_0:SetValue("A1_COD", cCod)
    cName := fbs_0_0:GetValue("A1_NOME")
Return cName
```

The subject is evaluated once. Inside the block, a `:` where AdvPL could not
have one -- at the start of a statement or of an operand -- means the
subject; a `:` after a name, `)` or `]` is a member, as always. Blocks nest,
and the innermost subject wins. Only `End With` closes it, and a `:x`
outside one is refused. `with` without `object` is not xtpl.

### raw

```xtpl
User Function Raw(nTotal, cName)
  raw @ 10, 5 SAY "Total ${nTotal}" GET nTotal PICTURE "@E 999,999.99"
  raw
    @ 12, 5 SAY "Name" GET cName PICTURE "@!"
  end raw
Return nil
```

```tlpp
User Function Raw(nTotal, cName)
  @ 10, 5 SAY ("Total " + cValToChar(nTotal)) GET nTotal PICTURE "@E 999,999.99"
    @ 12, 5 SAY "Name" GET cName PICTURE "@!"
Return nil
```

Text for a `#command` xc does not know: not TL++ until the preprocessor
runs, so xc does not parse it. `raw` and a space start a raw line, which
carries on over `;` continuations; `raw` alone on its line starts a block,
which only `End Raw` closes. The `raw` goes; the text stays, with its strings
interpolated and the block locals in it renamed. `raw(1)` is a call and
`raw := 2` an assignment. Inside functions only: at file level, directives
pass through whole already.

### TOTVS' commands

TOTVS' include files are compressed, and xc cannot read their `#command`s.
A statement that starts with one of their words is taken whole, through its
continuation lines, and goes out as it came:

- `DEFINE`, `ACTIVATE`, `REDEFINE`, `SET`, `MENU`, `PUBLISH`, `REPLACE`,
  each followed by a word;
- `ADD OPTION`, `PREPARE ENVIRONMENT`, `RESET ENVIRONMENT`, `APPEND BLANK`,
  `COUNT TO`, `MENUITEM`, `ENDMENU`, `TCQUERY`, `PARAMTYPE`, `THROW`;
- mail: `CONNECT SMTP`, `DISCONNECT SMTP`, `SEND MAIL`, `GET MAIL ERROR`;
- the RF terminal's: `VTPAUSE`, `VTREAD`, `VTCLEAR`, `VTSAVE`, `VTRESTORE`;
- `@ row, col ...`: an `@` followed by a space or a digit;
- `BeginSql` ... `EndSql` and `BeginContent` ... `EndContent`, to their
  closing line.

`Begin Transaction` ... `End Transaction` is a block whose body xc reads.
A word not on the list is a line xc cannot parse -- so a typo in one of
xtpl's keywords is not taken for a command. A directive inside a function,
`#IFDEF TOP` ... `#ENDIF`, passes through as it came.

## Expressions

### Precedence

From the loosest to the tightest:

| Level | Operators |
|---|---|
| guard | `e fallback alt` |
| chain | `x \|> f()` |
| elvis | `a ?: b` |
| or | `.Or.` |
| and | `.And.` |
| not | `!`, `.Not.` |
| comparison | `==` `!=` `<>` `#` `=` `>=` `<=` `>` `<` `$` `in` `has` |
| range | `lo..hi` |
| sum | `+` `-` |
| product | `*` `/` `%` `%%` |
| power | `**` `^` |
| sign | `-x`, `+x`, `++x`, `--x` |
| postfix | `a[i]` `o:m` `o:m()` `o::m` `h{k}` `o?.m` `A->F` `A->(e)` `x++` |

Comparisons do not nest by precedence among themselves: `a < b == c` reads
left to right. TL++'s own operators come out as written, so the AppServer's
reading of them stands; xc's reading matters where it rewrites.

### in, has, %% and ranges

| xtpl | TL++ |
|---|---|
| `cCode in aCodes` | `u_xtpl_in(cCode, aCodes)` |
| `nValue in 1..100` | `(nValue >= 1 .And. nValue <= 100)` |
| `hCfg has "rate"` | `u_xtpl_hhas(hCfg, "rate")` |
| `nN %% 3` | `((nN % 3) == 0)` |

`in` asks whether a value is in an array -- AdvPL's `$` only searches a
string -- or, with a range on its right, whether it lies between the two
ends, both included. `has` asks whether a hash has a key. `%%` asks whether
the left is divisible by the right; AdvPL's `%` is left alone. A range `lo..hi`
only exists in three places: the right of an `in`, the head of a
[chain](#sources), and the source of a `for ... in`.

### Elvis and safe access

| xtpl | TL++ |
|---|---|
| `cName ?: "anonymous"` | `u_xtpl_elvis(cName, {\|\| "anonymous"})` |
| `cached() ?: computed() ?: "last"` | `u_xtpl_elvis(cached(), {\|\| u_xtpl_elvis(computed(), {\|\| "last"})})` |
| `oUser?.cName` | `If(oUser != Nil, oUser:cName, Nil)` |
| `oUser?.Describe(1)` | `If(oUser != Nil, oUser:Describe(1), Nil)` |

`a ?: b` is `a`, unless it is Nil; `b` is only evaluated when it is needed.
It chains to the right. `o?.m` is Nil when `o` is, instead of an error, for
a member and for a method call; in a run of them, `oUser?.oAddress?.cCity`,
each base is evaluated once.

### Hashes

```xtpl
User Function Hashes(cKey)
  Local hCfg := {"rate" => 1.5, "name" => "x"}
  Local hNone := { => }
  Local nRate := hCfg{"rate"}
  hCfg{"rate"} := 2
  hCfg{cKey} += 1
  conout(hCfg{"name"})
Return {nRate, hNone}
```

```tlpp
User Function Hashes(cKey)
  Local hCfg := u_xtpl_hnew({{"rate", 1.5}, {"name", "x"}})
  Local hNone := THashMap():New()
  Local nRate := u_xtpl_hget(hCfg, "rate")
  hCfg:Set("rate", 2)
  hCfg:Set(cKey, u_xtpl_hget(hCfg, cKey) + (1))
  conout(u_xtpl_hget(hCfg, "name"))
Return {nRate, hNone}
```

A hash is a `THashMap`. `{k => v, ...}` makes one, and `{ => }` an empty
one -- `{}` is the empty array. Braces right after a value -- a name, `)`,
`]` or `}`, with no space between -- read a key: `hCfg{"k"}`,
`GetHash(){"k"}`, `aHashes[1]{"k"}`, `h{"a"}{"b"}`. A key not there reads as
Nil. Assigned, `h{k} := v` is a `Set`, and `+=` and the like read and write
back. Inside an expression, a write is `u_xtpl_hset(h, k, v)`, which gives
back the value, as `:=` does.

### JSON objects

| xtpl | TL++ |
|---|---|
| `{"name": cName, "qty": 3}` | `u_xtpl_jnew({{"name", cName}, {"qty", 3}})` |
| `{ : }` | `JsonObject():New()` |

TL++ has no JSON literal -- `{ : }` is a syntax error to the AppServer --
so xc makes the object with the runtime's `u_xtpl_jnew`.

### Interpolation

| xtpl | TL++ |
|---|---|
| `"total = ${nTotal} items"` | `("total = " + cValToChar(nTotal) + " items")` |
| `'rate ${hCfg{"t"}} end'` | `('rate ' + cValToChar(u_xtpl_hget(hCfg, "t")) + ' end')` |

`${expression}` in a string of either quote, wherever the string is, a
`Local`'s value included. The expression is ordinary code, and must be a
whole one: `${}` and `${n +}` are refused. A string inside it cannot use the
quote of the string around it -- that quote would end the outer string --
so `"x ${cA + "y"} z"` is refused, and `"x ${cA + 'y'} z"` is the way.

### Lambdas and code blocks

| xtpl | TL++ |
|---|---|
| `[o] o:nValue` | `{\|o\| o:nValue}` |
| `[acc, x] acc + x` | `{\|acc, x\| acc + x}` |

A lambda is `[` one to six names `]` and a body: one expression, or an
assignment, which stops at the comma or the parenthesis of what holds it --
`reduce([acc, x] acc + x, 0)` has the lambda and the seed as two arguments.
`[` opens a lambda only where a value starts; after a value it is an index.
A lambda's parameters may be reserved words. Code blocks, `{|x| ...}` and
`{|| ...}`, are TL++'s and pass through; inside one, an assignment is a
value. Neither a lambda nor a code block may hold a `|>` or a `fallback`:
the body runs later, and lifting a stage out of it would run the stage
first.

### fallback

| xtpl | TL++ |
|---|---|
| `callService(cUrl) fallback ""` | `u_xtpl_safe_pipe({\|\| callService(cUrl)}, {\|\| ""})` |
| `(risky(2) fallback 0) + 1` | `u_xtpl_safe_pipe({\|\| risky(2)}, {\|\| 0}) + 1` |

Guards an expression: if it raises an error, the alternative is the value,
and it is only evaluated then. `fallback` goes at the end of the value of an
assignment, a declaration or a `Return`, and in parentheses, which is how to
guard just a piece. It guards a whole chain, and a chain it guards does not
[fuse](#when-a-chain-is-a-loop).

### TL++'s own

These pass through as written, and xc reads them so its checks see the
names inside:

- `::x`, `::M(...)`: `Self:x`; `oObj::cX` is `oObj:cX`.
- `SA1->A1_NOME` reads a field of an area; `(cAlias)->A1_COD` of the area a
  variable names; `SA1->(DbGoTop())` and `SA2->( dbSetOrder(3), dbGoTop() )`
  run in the area; `(cAlias)->&(cField)` and `SX3->&("X3_CAMPO")` name the
  field when they run.
- `&cVar`, `&(cExpr)`, `&cFunc.(1, 2)`: the macro operator.
- `@x`, `@::x`, `@aCampos[nX][8]`: by reference, in an argument.
- `totvs.framework.Thing():New()`: a call through a namespace.
- `If(c, a, b)` and `IIf(c, a, b)`.
- `f( , 1, , )`: arguments left out.

## Chains

### |>

```xtpl
  cUp := cName |> alltrim |> upper
  nN := len(aNums |> distinct)
  aCodes := sortedCodes(aOrders |> sortby([o] o:cCode), 10)
  aOrders |> validate() |> save()
```

```tlpp
  cUp := upper(alltrim(cName))
  nN := len(u_xtpl_distinct(aNums))
  aCodes := sortedCodes(u_xtpl_sortby(aOrders, {|o| o:cCode}), 10)
  save(validate(aOrders))
```

The value on the left becomes the first argument of the stage on the right.
A stage is a call or a bare name: `|> asum` is `asum(x)`. `|>` is the
loosest operator but `fallback`: its left side runs back to the comma, the
parenthesis or the start of the expression that holds it -- so
`aR := nA > 1 |> sortRows` feeds `nA > 1`, and xc warns. A chain may be the
value of anything, or a statement of its own, run for its effect.

### The verbs

A call to one of these names -- a call, not a method -- is the runtime's
`u_xtpl_<name>`, wherever it is, in a chain or not. Over an array:

| Verb | Gives |
|---|---|
| `map(a, [x] e)` | each element through the block |
| `filter(a, [x] c)`, `reject(a, [x] c)` | the elements that pass, that fail |
| `tap(a, [x] e)` | `a`, after running the block on each element |
| `take(a, n)`, `drop(a, n)` | the first n, all but the first n |
| `takewhile(a, [x] c)`, `dropwhile(a, [x] c)` | the leading run that passes; the rest after it |
| `expand(a, [x] arr)` | every element of the arrays the block gives, in order |
| `distinct(a)` | without repeats |
| `distinctadjacent(a[, [x] key])` | without runs of the same value, or key |
| `sort(a[, {\|x, y\| ...}])`, `sortby(a, [x] key[, lDesc])` | sorted -- a copy |
| `reverse(a)`, `flatten(a)` | reversed; nested arrays flattened all the way down |
| `enumerate(a)` | `{i, x}` pairs |
| `chunks(a, n)`, `chunkby(a, [x] key)` | groups of n; runs of the same key |
| `pairwise(a)` | each element with the one before it |
| `zip(a, b[, ...][, block])` | rows of the arrays' elements, up to six arguments, to the shortest; with a block, what it makes of each row |
| `scan(a, [acc, x] e, seed)` | the running value after each element |
| `reduce(a, [acc, x] e, seed)`, `fold(a, [acc, x] e)` | one value; `fold` starts from the first element |
| `asum(a)`, `aprod(a)`, `amax(a)`, `amin(a)` | the sum, product, largest, smallest |
| `count(a[, [x] c])`, `first(a, [x] c)` | how many pass; the first that does, or Nil |
| `anyof(a, [x] c)`, `allof(...)`, `noneof(...)` | whether any, all, none pass -- stopping at the answer |
| `maxby(a, [x] key)`, `minby(a, [x] key)` | the element with the largest, smallest key |
| `apick(a[, n])`, `aroll(a[, n])` | n elements drawn at random: without, with repeats |

Over hashes and text:

| Verb | Gives |
|---|---|
| `keys(h)`, `values(h)`, `pairs(h)` | the keys, the values, `{k, v}` rows |
| `split(c, cSep)`, `join(a[, cSep])` | the pieces of a text; a text from pieces |
| `starts(c, x)`, `ends(c, x)`, `contains(c, x)` | whether the text starts with, ends with, holds x |

And `setmaxroll(n)`, the most elements `aroll` gives (1000 to start with;
it returns the old value), and `queue([n])`, a queue: `:Push(x)`, `:Pop()`,
`:Peek()`, `:Count()`, `:IsEmpty()`.

AdvPL's own one-argument functions need nothing: `cName |> alltrim |>
upper`.

### A function's name as a block

Where a verb takes a block, a bare name that is not a variable of the
function is the function of that name: `map(alltrim)` is `map([it]
alltrim(it))`. A name that is a variable is a block held in it.

```xtpl
  aUp := aNames |> map(upper)
  aUp2 := aNames |> map(bUp)
```

The verbs that take a block: `map`, `filter`, `reject`, `tap`, `takewhile`,
`dropwhile`, `expand`, `maxby`, `minby`, `sortby`, `chunkby`,
`distinctadjacent`, `first`, `count`, `anyof`, `allof`, `noneof`.

### When a chain is a loop

A chain that is the whole value of a statement -- `x := chain`, a `Local`'s
value, `Return chain`, or a statement of its own -- becomes one loop, with
no array built between its stages, when at least two of its stages fuse, or
one that carries a block (a lambda written in the stage, or a function's
name):

```xtpl
User Function Fused(aOrders)
  Local aCodes := aOrders |> filter([o] o:nValue > 1000) |> map([o] o:cCode)
Return aCodes
```

```tlpp
User Function Fused(aOrders)
  Local aCodes
  Local fi_0_0  // the position in the array walked
  Local fv_0_0  // the element walked
  Local fo_0_0  // the result of the chain
  fo_0_0 := {}
  For fi_0_0 := 1 To Len(aOrders)
    fv_0_0 := aOrders[fi_0_0]
    If fv_0_0:nValue > 1000
      fv_0_0 := fv_0_0:cCode
      AAdd(fo_0_0, fv_0_0)
    EndIf
  Next
  aCodes := fo_0_0
Return aCodes
```

- The stages that fuse: `filter`, `reject`, `map`, `tap`, `take`,
  `takewhile`, `drop`, `dropwhile`, `expand`, `distinctadjacent`, `scan`,
  `pairwise`.
- The terminals that end a fused run: `asum`, `count`, `anyof`, `allof`,
  `noneof`, `first`, `aprod`, `amax`, `amin`, `join`, `reduce`, `fold`,
  `maxby`, `minby`, `chunkby`.
- A stage that takes a block fuses with the block written in it -- a
  lambda of one parameter, or a function's name; a block held in a variable
  does not. `scan`, `reduce` and `fold` fuse with a lambda of two parameters
  that does not assign them; `take`, `drop`, `asum` and the others that take
  no block, with their plain arguments.
- `take`, `takewhile`, `anyof`, `allof`, `noneof` and `first` leave the loop
  as soon as they know.
- A chain run for its effect fuses only when all of its stages do, and none
  is a terminal.
- Any other stage stops the fusing: it and every stage after it apply, as
  calls, to what the loop collected. xc warns about it, in xtpl's words.

```xtpl
User Function NoFuse(aOrders)
  Local aTop := aOrders |> filter([o] o:nValue > 0) |> sortby([o] o:nValue) |> take(3)
Return aTop
```

```tlpp
User Function NoFuse(aOrders)
  Local aTop
  Local fi_0_0  // the position in the array walked
  Local fv_0_0  // the element walked
  Local fo_0_0  // the result of the chain
  fo_0_0 := {}
  For fi_0_0 := 1 To Len(aOrders)
    fv_0_0 := aOrders[fi_0_0]
    If fv_0_0:nValue > 0
      AAdd(fo_0_0, fv_0_0)
    EndIf
  Next
  aTop := u_xtpl_take(u_xtpl_sortby(fo_0_0, {|o| o:nValue}), 3)
Return aTop
```

```text
nofuse.xtpl:2: warning: this chain does not fuse -- 'sortby' stops it, because it needs the whole collection, so it and every stage after it builds an array
```

Anywhere else -- inside an expression, an argument, a condition -- a chain
is one call per stage, which is what it means; fusing only saves the work.
A `Local` whose value is a chain becomes a declaration without a value, and
the assignment moves after the prologue, in order with the others.

### Sources

`rows("SA1")`, `lines(cFile)` and `lo..hi` are not functions: a chain from
one is a loop over the area, the file or the numbers, with the stages inside
it, and nothing is built in between.

```xtpl
User Function Saldo()
  Local nTotal := rows("SA1") |> filter([r] r:A1_MSBLQL != "1") |> map([r] r:A1_SALDO) |> asum
Return nTotal
```

```tlpp
User Function Saldo()
  Local nTotal
  Local far_0_0  // the area selected before the walk
  Local frc_0_0  // the record the area was on before the walk
  Local fv_0_0  // the element walked
  Local fo_0_0  // the result of the chain
  far_0_0 := Alias()
  DbSelectArea("SA1")
  frc_0_0 := SA1->(RecNo())
  SA1->(DbGoTop())
  fo_0_0 := 0
  While !SA1->(Eof())
    If SA1->A1_MSBLQL != "1"
      fv_0_0 := SA1->A1_SALDO
      fo_0_0 := fo_0_0 + fv_0_0
    EndIf
    SA1->(DbSkip())
  EndDo
  SA1->(DbGoto(frc_0_0))
  If !Empty(far_0_0)
    DbSelectArea(far_0_0)
  EndIf
  nTotal := fo_0_0
Return nTotal
```

- `rows(alias[, key])` walks a work area from the top, or from
  `DbSeek(key)`, to its end, and puts back the area and the record it found.
  The element is the current record: `r:A1_SALDO` is `SA1->A1_SALDO`, and
  the record's name can only name fields until a `map` makes it a value.
  Nothing can be collected from a record, so a chain from `rows()` maps
  before it collects; `count`, `anyof`, `allof` and `noneof` need no map.
  To read one group, seek it and stop at its end:

  ```xtpl
    using alias SC6 order 1 do
      aSeek := rows("SC6", xFilial("SC6") + cNum) ;
               |> takewhile([r] r:C6_NUM == cNum) ;
               |> map([r] r:C6_PRODUTO)
    end using
  ```

- `lines(path)` reads a text file line by line (`FT_FUse`, `FT_FReadLn`),
  when `File()` finds it, and closes it at the end.
- `lo..hi` counts from `lo` to `hi`.

A chain from a source runs as a loop before its statement, so it is only the
whole value of `x := ...`, of a `Local`, `Private` or `Public`, of `Return`,
or a statement of its own -- a postfix modifier around it is fine, the loop
goes inside the `If`. A source alone may also be the source of a
`for ... in`. Anywhere else is an error; so is a source that does not start
a chain, and a `fallback` around a chain from one.

## A source's own commands

A source may declare commands and translations of its own, in the file or in
an include file -- a library's `#xcommand`, `#xtranslate`, `#command`,
`#translate`:

```xtpl
#include "totvs.ch"
#include "tlpp-core.th"
#xcommand REPORTE <x> [TITULO <t>] [LARGURA <n>] => u_Rep(<x>, <t>, <n>)
#xtranslate @Agora => Time()

User Function Cmds(cX)
  REPORTE cX LARGURA 80 TITULO "Vendas"
Return @Agora
```

xc reads them, from the file and from every include file it finds as plain
text -- beside the source, or in the folders of `--includes` -- and the ones
those include. It finds their uses as the preprocessor will, and leaves the
work to it: what is written goes out as written. A use is

- a command, a whole statement: taken whole;
- a command that stands for a function's header (`Function ...`,
  `Method ... Class ...`): a function, its header as written and its body
  read like any other -- nginformatica's `Feature f TestSuite X`;
- a translation, inside an expression or after a value: a value.

Patterns have words, `<x>` markers -- regular, list `<x,...>`, restricted
`<x: A, B>`, wild `<*x*>` -- and optional clauses `[ ... ]`, which may come
in any order. Under `#command` and `#translate` a word may be cut to its
first four letters; `#xcommand` and `#xtranslate` want it whole. A pattern
matches the whole statement, or it is not the command. TOTVS' include files
are compressed: xc skips them, and knows their commands from a list of its
own ([TOTVS' commands](#totvs-commands)).

## The checks

Between the parse and the output, xc checks what xtpl refuses although it
parses, in xtpl's words.

**Errors** -- the file is not written:

| | |
|---|---|
| a name used after its block | `'nIn' is out of scope here (block local declared on line 3).` |
| a block local declared twice in its block | `'nTmp' is already declared in this block.` |
| a `<const>` assigned, or passed by reference | `'nMax' is <const> (declared on line 2) and cannot be assigned.` |
| a `<contained>` named in a code block, a lambda, a `defer` | `'aWork' is <contained> (declared on line 2) and cannot leave its block.` |
| an `external` assigned | `'cEmpAnt' is external (line 1) and cannot be assigned.` |
| a `Local` after a `Private` or `Public` | `'local' after 'private' (line 3): a private or a public is a statement, and every local comes before the first statement.` |
| a type by its letter, or `Char` | `'as N': TL++ has no type 'N' -- write 'as Numeric'.` |
| a user function of the file called without `u_` | `'calc' is a user function (line 9), so it is called as 'u_calc' -- the compiler puts the prefix on the declaration.` |
| a static function of the file called with `u_` | `'u_ajuda' -- ajuda is a static function in this file, so it is called by its plain name, without the 'u_'.` |
| more arguments than a function of the file takes | `calcTotal() takes 2 parameters (line 4), but is given 3.` |
| a single value at the head of a chain | `nX is a single value -- it was declared as 5, and a chain walks a collection. Write {nX} for a one-element array, or 'lo..hi' for a range.` |
| a source anywhere but the head of a chain | `'lines()' is a source, and only reads at the head of a chain. Assign it, or feed it into stages with '\|>'.` |
| a chain from a source in the wrong place | `a chain from lines() runs as a loop, before its statement, so it is only the whole value of 'x := ...', ...` |
| `for ... in rows()` | `'for ... in' over rows() is not supported: ...` |
| a `fallback` around a chain from a source | `'fallback' cannot guard a walk over rows(). ...` |
| `distinctAdjacent` over `rows()` without a key | `distinctAdjacent over rows() needs a key -- ...` |

The grammar refuses the rest, with `cannot parse this line`: a reserved word
declared, a name of xc's shape declared, a trailing comma in a declaration,
`?=` in an expression, `|>` or `fallback` inside a lambda or a code block, a
`|>` with nothing on its left, `${` never closed, a lambda with no
parameters, `with` without `object`.

**Warnings** -- the file is written:

| | |
|---|---|
| a name nothing declares | `'cFilAnt' is not declared` |
| a name nothing declares, assigned | `'nCount' is not declared, so this creates a PRIVATE` |
| a variable never read, or never used | `'cX' is assigned but never read`, `'cY' is declared but never used` |
| a field of an area nothing in the function opened | `nothing in this function opened SA1. Wrap the use in 'using alias SA1 do', or declare 'external alias SA1' if the caller opens it.` |
| a value on one path and none on another | `the function can reach its end without a return, but returns a value on line 3` |
| a function ending without `Return` | `the function ends without a 'return': Protheus warns about it (W0019), and will refuse it` |
| a string the line ends | `this string is not closed: TL++ ends it at the end of the line -- "SELECT X` |
| `EndFunction` and the like; `Default` in a `Do Case` | `'EndFunction' is no TL++ keyword: ...` |
| a stage that stops the fusing | `this chain does not fuse -- 'sortby' stops it, ...` |
| a `fallback` around a chain that would fuse | `'fallback' turns off fusion for this chain -- ...` |
| a comparison on the left of `\|>` | `the whole left side of '\|>' is the first argument, so 'nA > 1' is what gets fed in. ...` |

A name nothing declares is a warning, not an error: plain TL++ uses the
system's variables -- `cFilAnt`, `dDataBase`, `CRLF` -- without declaring
them. A name counts as declared when it is a parameter, a `Local`, a
`Static` of the function or of the file, a `Private` or `Public` anywhere in
the function, a block local in its block, a parameter of a lambda or a code
block, an `external`, or a `#define` of the file.

**The dictionary.** With `--dict sx3.csv`, an exported SX3, a literal
`ALIAS->FIELD` -- and `r:FIELD` in a chain over `rows("ALIAS")` -- is
checked against it: an alias or a field it does not have ("Did you mean
A1_NOME?"), a literal of the wrong type assigned to a field or compared with
it, a string too long for the field it is assigned to. Warnings; with
`--dict-strict`, errors.

## The runtime

`runtime/xtpl_runtime.tlpp` holds the functions the output calls. It has to
be compiled into the RPO with the generated code, and kept up to date with
xc: a new xc may call a function an old runtime does not have.

They are `User Function`s, so the names the output calls carry the `u_`:

- the verbs: `u_xtpl_map`, `u_xtpl_filter`, ... -- one for each name in
  [The verbs](#the-verbs), and `u_xtpl_queue` with its class, `XtplQueue`;
- `u_xtpl_in`, for `in`;
- `u_xtpl_elvis`, for `?:`;
- `u_xtpl_hget`, `u_xtpl_hset`, `u_xtpl_hhas`, `u_xtpl_hnew`, for hashes;
- `u_xtpl_jnew`, for JSON objects;
- `u_xtpl_safe_pipe`, for `fallback`.

The verbs leave their arguments alone: `sort` and `sortby` sort a copy.
`apick` and `aroll` draw with `Random()`, which needs AppServer 19.3.1 or
later.

## Names xc keeps

**Reserved words** cannot be declared -- as a `Local`, `Private`, `Public`,
`Static`, parameter, header local or loop variable; a lambda's parameter is
free:

```text
function static return if else elseif endif for next while enddo do
local private public with without orwith given when otherwise end len
```

`len` is the one native function the AppServer refuses as a name.
`with`, `without`, `orwith`, `given` and `when` were xtpl's. `user`, `array`,
`conout`, `eval`, `aadd`, `substr` and `userexception` are names to the
AppServer, and so to xc. A statement cannot start with a word that starts
one -- `return (.t.)` is a `Return`, not a call to `return` -- but after `:`
or `->` a member may be called anything: `oDlg:End()`.

**The verbs' names** are the runtime's: a call to `first(...)`, `count(...)`,
`join(...)`, `split(...)`, `keys(...)`, `sort(...)`, ... is
`u_xtpl_first(...)` and so on, wherever it is. A static function of your own
by one of those names is not reached by its plain name; give it another. A
method of that name is yours: `oObj:Count()`. A class of your own called
`XtplQueue` would clash with the runtime's.

**Generated names.** xc's own locals have shapes a function may not declare
as a `Local` or a `Private` of its own: a leading `__`,
`<kind>_<depth>_<index>` -- `fo_0_0`, `fv_1_2`, `fi_0_0` -- and the slots,
`s_0_0`, `b_0_x`.
