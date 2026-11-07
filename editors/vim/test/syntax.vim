" The syntax file, held to what editors/vscode's grammar is held to: each
" piece of xtpl below has to come out in the group given -- or, after a '!',
" not in it; then every .xtpl of the repository is read through, from its
" start, and none may end inside a block comment or a directive -- a rule
" that runs away shows there.
"
"   vim -Nu NONE -i NONE -n -es --cmd "let g:out = 'vim.out'" -S editors/vim/test/syntax.vim
"
" What it finds goes to g:out (the terminal when it is not given); Vim exits
" 1 when something is wrong. ctest runs it as 'vim', when there is a vim.

let s:here = expand('<sfile>:p:h')
let s:root = fnamemodify(s:here, ':h:h:h')
execute 'set runtimepath^=' . fnameescape(fnamemodify(s:here, ':h'))
filetype plugin on
syntax on

let s:said = []
let s:ok = 0
let s:total = 0

function! s:Groups(lnum, col) abort
  return map(synstack(a:lnum, a:col), 'synIDattr(v:val, "name")')
endfunction

" In the lines of text -- "\n" between them --, the first piece found, at
" offset in it: in group (or not, '!group').
function! s:Check(text, piece, group, ...) abort
  let l:offset = a:0 ? a:1 : 0
  let l:lines = split(a:text, "\n", 1)
  silent %delete _
  call setline(1, l:lines)
  setlocal syntax=xtpl
  let s:total += 1
  let l:where = []
  for l:n in range(len(l:lines))
    let l:at = stridx(l:lines[l:n], a:piece)
    if l:at >= 0
      let l:where = [l:n + 1, l:at + 1 + l:offset]
      break
    endif
  endfor
  let l:what = substitute(a:text, "\n", ' | ', 'g') . ": '" . a:piece . "' is " . a:group
  if empty(l:where)
    call add(s:said, '  FAIL  ' . l:what . ' -- no such piece')
    return
  endif
  let l:groups = s:Groups(l:where[0], l:where[1])
  let l:want = substitute(a:group, '^!', '', '')
  let l:has = index(l:groups, l:want) >= 0
  if a:group =~# '^!' ? !l:has : l:has
    let s:ok += 1
    call add(s:said, '  ok    ' . l:what)
  else
    call add(s:said, '  FAIL  ' . l:what . ' -- it is ' . string(l:groups))
  endif
endfunction

enew!
setlocal buftype=nofile
let s:cases = [
      \ ['User Function Soma(nA, nB)', 'User', 'xtplStorage'],
      \ ['User Function Soma(nA, nB)', 'Function', 'xtplDefine'],
      \ ['User Function Soma(nA, nB)', 'Soma', 'xtplFuncName'],
      \ ['static function ajuda()', 'ajuda', 'xtplFuncName'],
      \ ['static function ajuda()', 'static', 'xtplStorage'],
      \ ['  Local nTotal := 0 as Numeric', 'Local', 'xtplStorage'],
      \ ['  Local nTotal := 0 as Numeric', 'Numeric', 'xtplType'],
      \ ['  Local nTotal := 0 as Numeric', 'as', 'xtplAs'],
      \ ['  Local nTotal := 0 as Numeric', ':=', 'xtplOperator'],
      \ ['  local nMax := 10 <const>', '<const>', 'xtplAttribute'],
      \ ['  Local aN as Array<n>', 'Array', 'xtplType'],
      \ ['  Local aN as Array<n>', 'n>', 'xtplTypeLetter'],
      \ ['  Local hC as Hash<c, Array<n>>', 'Array', 'xtplType'],
      \ ['  Local hC as Hash<c, Array<n>>', 'c,', 'xtplTypeLetter'],
      \ ['  Local hC as Hash<c, Array<n>>', 'n>', 'xtplTypeLetter'],
      \ ['  Local aN := { <n> }', 'n>', 'xtplTypeLetter'],
      \ ['  Local aK := {1} as Array<fixed n>', 'fixed', 'xtplFixed'],
      \ ['  Local aK := {1} as Array<fixed n>', 'n>', 'xtplTypeLetter'],
      \ ['  Local aK := {1} as Array<fixed n>', '1', 'xtplNumber'],
      \ ['  Local bW as Bag<c>', 'Bag', 'xtplType'],
      \ ['  Local oOrder as Order', ' Order', 'xtplType', 1],
      \ ['  Local oObj as Object', 'Object', 'xtplType'],
      \ ['Static Function Mk(oCust as Customer) as Order', 'Customer', 'xtplType'],
      \ ['Static Function Mk(oCust as Customer) as Order', 'Order', 'xtplType'],
      \ ['  Data aItems as Array<fixed n>', 'aItems', 'xtplMemberName'],
      \ ['  Data aItems as Array<fixed n>', 'Array', 'xtplType'],
      \ ['  Data aItems as Array<fixed n>', 'fixed', 'xtplFixed'],
      \ ['  Public Data sSeen as Set<c>', 'c>', 'xtplTypeLetter'],
      \ ['  Public Data sSeen as Set<c>', 'Public', 'xtplStorage'],
      \ ['Method Add(aMore as Array<n>) as Hash<c, n> Class Order', 'Add', 'xtplFuncName'],
      \ ['Method Add(aMore as Array<n>) as Hash<c, n> Class Order', 'Hash', 'xtplType'],
      \ ['Method Add(aMore as Array<n>) as Hash<c, n> Class Order', ' n>', 'xtplTypeLetter', 1],
      \ ['Method Add(aMore as Array<n>) as Hash<c, n> Class Order', 'Order', 'xtplClassName'],
      \ ['  Local sK := setof(aA) as Set<fixed c>', 'Set', 'xtplType'],
      \ ['  Local sK := setof(aA) as Set<fixed c>', 'setof', 'xtplVerb'],
      \ ['  sAll := sA (|) sB (&) sC', '(|)', 'xtplOperator'],
      \ ['  sAll := sA (|) sB (&) sC', '(&)', 'xtplOperator'],
      \ ['  oJobs := heapof(aJobs, [j] j:nPrio)', 'heapof', 'xtplVerb'],
      \ ['  oJobs := heapof(aJobs, [j] j:nPrio)', '[j]', 'xtplParam', 1],
      \ ['  l := cX (elem) sA .And. sA (<=) sB', '(elem)', 'xtplOperator'],
      \ ['  l := cX (elem) sA .And. sA (<=) sB', '(<=)', 'xtplOperator'],
      \ ['  l := cX (elem) sA .And. sA (<=) sB', '.And.', 'xtplOperator'],
      \ ['  Local hK := {"a" => 1} as Hash<fixed c, n>', 'fixed', 'xtplFixed'],
      \ ['  Local hH := { <c> => <Array<d>> }', 'd>', 'xtplTypeLetter'],
      \ ['  Local hH := { <c> => <Array<d>> }', 'c>', 'xtplTypeLetter'],
      \ ['  Local hH := { <c> => <Array<d>> }', '=>', 'xtplOperator'],
      \ ['  Local aX := {1, nA}', 'nA', '!xtplTypeLetter'],
      \ ['  If lOk .And. nX > 1', 'If', 'xtplConditional'],
      \ ['  EndIf', 'EndIf', 'xtplConditional'],
      \ ['  Do Case', 'Case', 'xtplConditional'],
      \ ['  for oItem, nPos in aItems', 'for', 'xtplRepeat'],
      \ ['  for oItem, nPos in aItems', 'in', 'xtplOperator'],
      \ ['  for 3 times', 'times', 'xtplRepeat'],
      \ ['  for 3 times', '3', 'xtplNumber'],
      \ ['  if lOk exec nOk++ else nErr++', 'exec', 'xtplStatement'],
      \ ['  if lOk exec nOk++ else nErr++', '++', 'xtplOperator'],
      \ ['  Return nTotal', 'Return', 'xtplStatement'],
      \ ['  Begin Sequence', 'Sequence', 'xtplException'],
      \ ['  Recover Using oErr', 'Using', 'xtplStatement'],
      \ ['  defer conout("bye")', 'defer', 'xtplStatement'],
      \ ['  defer conout("bye")', '"bye"', 'xtplString'],
      \ ['  using alias SA1 order 1 do', 'alias', 'xtplStatement'],
      \ ['  using alias SA1 order 1 do', 'SA1', 'xtplAliasName'],
      \ ['  using alias SA1 order 1 do', 'order', 'xtplOrder'],
      \ ['  using alias SA1 order 1 do', 'do', 'xtplStatement'],
      \ ['  end using', 'end', 'xtplStatement'],
      \ ['  end using', 'using', 'xtplStatement'],
      \ ['  with object oDlg', 'object', 'xtplStatement'],
      \ ['  aTop := aOrders |> filter([o] o:nValue > 0) |> take(3)', '|>', 'xtplPipe'],
      \ ['  aTop := aOrders |> filter([o] o:nValue > 0) |> take(3)', 'filter', 'xtplStage'],
      \ ['  aTop := aOrders |> filter([o] o:nValue > 0) |> take(3)', 'take', 'xtplStage'],
      \ ['  aTop := aOrders |> filter([o] o:nValue > 0) |> take(3)', '[o]', 'xtplParam', 1],
      \ ['  aTop := aOrders |> filter([o] o:nValue > 0) |> take(3)', '0', 'xtplNumber'],
      \ ['  n := aX |> distinct |> asum', 'distinct', 'xtplStage'],
      \ ['  n := aX |> distinct |> asum', 'asum', 'xtplStage'],
      \ ['  aOrders then validate() THEN save()', 'then', 'xtplPipe'],
      \ ['  aOrders then validate() THEN save()', 'THEN', 'xtplPipe'],
      \ ['  aOrders then validate() THEN save()', 'validate', 'xtplStage'],
      \ ['  cThen := cName', 'cThen', '!xtplPipe'],
      \ ['  x := rows("SA1") |> count', 'rows', 'xtplVerb'],
      \ ['  x := rows("SA1") |> count', 'count', 'xtplStage'],
      \ ['  x := aX[1]', '1', 'xtplNumber'],
      \ ['  x := aX[i] + 1', 'i]', '!xtplParam'],
      \ ["  nBig := 12'345'678", "12'345'678", 'xtplNumber'],
      \ ["  nBig := 12'345'678", "678", 'xtplNumber'],
      \ ["  nBig := 12'345'678", "345", '!xtplString'],
      \ ['  nHalf := .5', '.5', 'xtplNumber'],
      \ ['  lOk := .T.', '.T.', 'xtplBoolean'],
      \ ['  x := Nil', 'Nil', 'xtplNil'],
      \ ['  x := Self:cName', 'Self', 'xtplSelf'],
      \ ['  c := "total = ${nTotal} items"', 'nTotal', 'xtplInterp'],
      \ ['  c := "total = ${nTotal} items"', '${', 'xtplInterpDelim'],
      \ ['  c := "total = ${nTotal} items"', ' items', 'xtplString', 1],
      \ ['  c := "total = ${nTotal} items"', ' items', '!xtplInterp', 1],
      \ ['  c := "n = ${aX |> count()} ok"', 'count', 'xtplStage'],
      \ ["  c := 'rate ${hCfg{\"t\"}} end'", ' end', 'xtplString', 1],
      \ ["  c := 'rate ${hCfg{\"t\"}} end'", ' end', '!xtplInterp', 1],
      \ ['  c := "R$ 10"', 'R$ 10', 'xtplString'],
      \ ["  c := \"it's\" + x", 'x', '!xtplString'],
      \ ["  cQ := \"SELECT X\n  x := 1", 'SELECT X', 'xtplString'],
      \ ["  cQ := \"SELECT X\n  x := 1", 'x', '!xtplString'],
      \ ["  c := 'abc\nLocal nX", 'Local', 'xtplStorage'],
      \ ['  b := {|x, y| x + y}', 'y', 'xtplParam'],
      \ ['  b := {|x, y| x + y}', '|x', 'xtplBlockParams'],
      \ ['  b := {|x| x |> count()}', 'count', 'xtplStage'],
      \ ['  b := {|| Time()}', '||', 'xtplBlockParams'],
      \ ['  cName ?= "empty"', '?=', 'xtplOperator'],
      \ ['  c := cName ?: "anonymous"', '?:', 'xtplOperator'],
      \ ['  c := oUser?.cName', '?.', 'xtplOperator'],
      \ ['  l := nX in 1..100', '..', 'xtplOperator'],
      \ ['  l := nX in 1..100', '100', 'xtplNumber'],
      \ ['  l := nX in 1..100', '1.', 'xtplNumber'],
      \ ['  l := hCfg has "rate"', 'has', 'xtplOperator'],
      \ ['  l := nN %% 3', '%%', 'xtplOperator'],
      \ ['  x := callService(cUrl) fallback ""', 'fallback', 'xtplOperator'],
      \ ['  h := {"rate" => 1.5}', '=>', 'xtplOperator'],
      \ ['  h := {"rate" => 1.5}', '1.5', 'xtplNumber'],
      \ ['  c := SA1->A1_NOME', 'SA1', 'xtplAliasName'],
      \ ['  c := SA1->A1_NOME', '->', 'xtplOperator'],
      \ ['  ::cName := x', '::', 'xtplSelf'],
      \ ['  x := 1  // a comment', ' a comment', 'xtplComment', 1],
      \ ['  x := 1  && a comment', ' a comment', 'xtplComment', 1],
      \ ['* a comment line', ' a comment line', 'xtplComment', 1],
      \ ['  // TODO: this', 'TODO', 'xtplTodo'],
      \ ['/* one */ x := 1', ' one ', 'xtplCommentBlock', 1],
      \ ['/* one */ x := 1', 'x', '!xtplCommentBlock'],
      \ ["/* one\n two */ x := 1", 'x', '!xtplCommentBlock'],
      \ ["/* one\n two */ x := 1", 'two', 'xtplCommentBlock'],
      \ ["// an AppServer's, and xc-vm's\nUser Function Soma()", 'Function', 'xtplDefine'],
      \ ["// an AppServer's, and xc-vm's\nUser Function Soma()", 'Soma', '!xtplString'],
      \ ['#include "totvs.ch"', '"totvs.ch"', 'xtplIncludeFile'],
      \ ['#include "totvs.ch"', '#include', 'xtplInclude'],
      \ ['#xcommand REPORTE <x> => u_Rep(<x>)', '<x>', 'xtplMarker'],
      \ ['#xcommand REPORTE <x> => u_Rep(<x>)', '#xcommand', 'xtplPreProc'],
      \ ['#xtranslate Dobro(<x>) => (<x> * 2)', '#xtranslate', 'xtplPreProc'],
      \ ['#ifdef TOP', '#ifdef', 'xtplPreProc'],
      \ ["#define BIG 1 + ;\n  2\nLocal nX", '2', 'xtplDirective'],
      \ ["#define BIG 1 + ;\n  2\nLocal nX", 'Local', 'xtplStorage'],
      \ ["#define BIG 1 + ;\n  2\nLocal nX", 'Local', '!xtplDirective'],
      \ ['Class Pessoa From Base', 'Class', 'xtplStructure'],
      \ ['Class Pessoa From Base', 'Pessoa', 'xtplClassName'],
      \ ['Class Pessoa From Base', 'Base', 'xtplClassName'],
      \ ['Method New() Class Pessoa', 'New', 'xtplFuncName'],
      \ ['Method New() Class Pessoa', 'Pessoa', 'xtplClassName'],
      \ ['EndClass', 'EndClass', 'xtplStructure'],
      \ ['type Item', 'type', 'xtplStructure'],
      \ ['type Item', 'Item', 'xtplClassName'],
      \ ['  If Type("cX") == "U"', 'Type', '!xtplStructure'],
      \ ['endtype', 'endtype', 'xtplStructure'],
      \ ['end type', 'end type', 'xtplStructure'],
      \ ['  n := aIt.nQtd + 1', 'nQtd', 'xtplField'],
      \ ['  n := aIt.Total()', 'Total', 'xtplFieldCall'],
      \ ['  Return .nQtd * .nPreco', 'nPreco', 'xtplField'],
      \ ['  l := lA.And.lB', 'And', '!xtplField'],
      \ ['  x := 1.5', '5', '!xtplField'],
      \ ['End Class', 'End Class', 'xtplStructure'],
      \ ['  Data cNome', 'cNome', 'xtplMemberName'],
      \ ['namespace xdk.ns', 'xdk.ns', 'xtplNamespaceName'],
      \ ['using namespace xdk.ns', 'namespace', 'xtplNamespace'],
      \ ['@Get("/clientes")', '@Get', 'xtplAnnotation'],
      \ ['external alias SA1, SB1', 'external', 'xtplStorage'],
      \ ['external alias SA1, SB1', 'alias', 'xtplStorage'],
      \ ]
for s:c in s:cases
  call call('s:Check', s:c)
endfor

" Every .xtpl of the repository, from its start: a line put after its last
" one is in nothing it left open.
let s:files = filter(globpath(s:root, '**/*.xtpl', 0, 1), 'v:val !~# "[\\/]\\%(node_modules\\|build\\)[\\/]"')
let s:open = []
for s:f in s:files
  execute 'silent edit! ' . fnameescape(s:f)
  setlocal syntax=xtpl
  syntax sync fromstart
  call append('$', 'x')
  let s:groups = s:Groups(line('$'), 1)
  if !empty(s:groups)
    call add(s:open, fnamemodify(s:f, ':.'))
  endif
endfor
let s:total += 2
if len(s:files) >= 100
  let s:ok += 1
  call add(s:said, "  ok    the repository's .xtpl files were read (" . len(s:files) . ')')
else
  call add(s:said, "  FAIL  the repository's .xtpl files were read (" . len(s:files) . ')')
endif
if empty(s:open)
  let s:ok += 1
  call add(s:said, '  ok    none of them is left inside anything at its end')
else
  call add(s:said, '  FAIL  none of them is left inside anything at its end')
  call extend(s:said, map(s:open[: 9], '"    open at the end: " . v:val'))
endif

call add(s:said, '')
call add(s:said, '  ' . s:ok . ' of ' . s:total)
call writefile(s:said, get(g:, 'out', '/dev/stdout'))
if s:ok == s:total
  qall!
endif
cquit!
