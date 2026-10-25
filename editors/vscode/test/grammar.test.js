// The grammar, run by the engine VS Code runs it with (vscode-textmate and
// its Oniguruma): each piece of xtpl below has to come out with the scope
// given; then every .xtpl of the repository is read through, and no line may
// end inside a string or a block it did not open -- a rule that runs away
// shows there.
//
//   npm install && npm test        (in editors/vscode)

'use strict';

const fs = require('fs');
const path = require('path');
const vsctm = require('vscode-textmate');
const oniguruma = require('vscode-oniguruma');

const here = __dirname;
const repo = path.resolve(here, '..', '..', '..');

async function registry()
{
  const wasm = fs.readFileSync(require.resolve('vscode-oniguruma/release/onig.wasm')).buffer;
  await oniguruma.loadWASM(wasm);
  return new vsctm.Registry({
    onigLib: Promise.resolve({
      createOnigScanner: (patterns) => new oniguruma.OnigScanner(patterns),
      createOnigString: (s) => new oniguruma.OnigString(s),
    }),
    loadGrammar: async (scopeName) =>
    {
      if (scopeName !== 'source.xtpl')
      {
        return null;
      }
      const file = path.join(here, '..', 'syntaxes', 'xtpl.tmLanguage.json');
      return vsctm.parseRawGrammar(fs.readFileSync(file, 'utf8'), file);
    },
  });
}

// The tokens of some lines: [text, scopes] for each, the scopes joined.
function tokens(grammar, text)
{
  let stack = vsctm.INITIAL;
  const out = [];
  for (const line of text.split('\n'))
  {
    const r = grammar.tokenizeLine(line, stack);
    for (const t of r.tokens)
    {
      out.push([line.substring(t.startIndex, t.endIndex), t.scopes.join(' ')]);
    }
    stack = r.ruleStack;
  }
  return out;
}

let ok = 0;
let total = 0;
function check(what, test)
{
  total++;
  let v = false;
  try
  {
    v = test();
  }
  catch (e)
  {
    console.log('    ' + e.message);
  }
  if (v)
  {
    ok++;
  }
  console.log((v ? '  ok    ' : '  FAIL  ') + what);
}

// Whether, in the tokens of $text, the piece $piece has a scope containing
// $scope -- the first token that is exactly the piece.
function scoped(grammar, text, piece, scope)
{
  const t = tokens(grammar, text).find(([s]) => s === piece);
  if (!t)
  {
    throw new Error(`no token '${piece}' in: ${text}`);
  }
  if (!t[1].includes(scope))
  {
    throw new Error(`'${piece}' is ${t[1]}`);
  }
  return true;
}

function files(dir)
{
  let found = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true }))
  {
    if (e.name === 'node_modules' || e.name.startsWith('.'))
    {
      continue;
    }
    const p = path.join(dir, e.name);
    if (e.isDirectory())
    {
      found = found.concat(files(p));
    }
    else if (e.name.toLowerCase().endsWith('.xtpl'))
    {
      found.push(p);
    }
  }
  return found;
}

(async () =>
{
  const grammar = await (await registry()).loadGrammar('source.xtpl');

  const cases = [
    ['User Function Soma(nA, nB)', 'User ', 'storage.modifier'],
    ['User Function Soma(nA, nB)', 'Function', 'storage.type.function'],
    ['User Function Soma(nA, nB)', 'Soma', 'entity.name.function'],
    ['static function ajuda()', 'ajuda', 'entity.name.function'],
    ['  Local nTotal := 0 as Numeric', 'Local', 'storage.modifier'],
    ['  Local nTotal := 0 as Numeric', 'Numeric', 'storage.type'],
    ['  Local nTotal := 0 as Numeric', ':=', 'keyword.operator.assignment'],
    ['  local nMax := 10 <const>', '<const>', 'storage.modifier.attribute'],
    ['  If lOk .And. nX > 1', 'If', 'keyword.control'],
    ['  If lOk .And. nX > 1', '.And.', 'keyword.operator.logical'],
    ['  EndIf', 'EndIf', 'keyword.control'],
    ['  for oItem, nPos in aItems', 'in', 'keyword.control'],
    ['  for oItem, nPos in aItems', 'nPos', 'variable.other'],
    ['  for 3 times', 'times', 'keyword.control'],
    ['  if lOk exec nOk++ else nErr++', 'exec', 'keyword.control'],
    ['  Return nTotal', 'Return', 'keyword.control'],
    ['  defer conout("bye")', 'defer', 'keyword.control'],
    ['  using alias SA1 order 1 do', 'alias', 'keyword.control'],
    ['  using alias SA1 order 1 do', 'SA1', 'variable.other.alias'],
    ['  end using', 'end using', 'keyword.control'],
    ['  with object oDlg', 'object', 'keyword.control'],
    ['  aTop := aOrders |> filter([o] o:nValue > 0) |> take(3)', '|>', 'keyword.operator.pipe'],
    ['  aTop := aOrders |> filter([o] o:nValue > 0) |> take(3)', 'filter', 'support.function'],
    ['  aTop := aOrders |> filter([o] o:nValue > 0) |> take(3)', 'o', 'variable.parameter'],
    ['  aTop := aOrders |> filter([o] o:nValue > 0) |> take(3)', 'nValue', 'variable.other.member'],
    ['  n := aX |> distinct |> asum', 'distinct', 'support.function'],
    ['  x := rows("SA1") |> count', 'rows', 'support.function.source'],
    ['  x := aX[1]', '1', 'constant.numeric'],
    ['  nBig := 12\'345\'678', '12\'345\'678', 'constant.numeric'],
    ['  nHalf := .5', '.5', 'constant.numeric'],
    ['  lOk := .T.', '.T.', 'constant.language.boolean'],
    ['  x := Nil', 'Nil', 'constant.language.nil'],
    ['  c := "total = ${nTotal} items"', 'nTotal', 'meta.interpolation'],
    ['  c := "total = ${nTotal} items"', '${', 'punctuation.section.interpolation.begin'],
    ['  c := \'rate ${hCfg{"t"}} end\'', ' end', 'string.quoted.single'],
    ['  c := "R$ 10"', 'R$ 10', 'string.quoted.double'],
    ['  cQ := "SELECT X', 'SELECT X', 'string.quoted.double'],
    ['  b := {|x, y| x + y}', 'y', 'variable.parameter'],
    ['  b := {|| Time()}', 'Time', 'entity.name.function.call'],
    ['  cName ?= "empty"', '?=', 'keyword.operator.assignment.nil'],
    ['  c := cName ?: "anonymous"', '?:', 'keyword.operator.elvis'],
    ['  c := oUser?.cName', '?.', 'punctuation.accessor.safe'],
    ['  l := nX in 1..100', '..', 'keyword.operator.range'],
    ['  l := nX in 1..100', '100', 'constant.numeric'],
    ['  c := oUser?.oAddress?.cCity', 'cCity', 'variable.other.member'],
    ['  l := hCfg has "rate"', 'has', 'keyword.operator.word'],
    ['  l := nN %% 3', '%%', 'keyword.operator.divisible'],
    ['  x := callService(cUrl) fallback ""', 'fallback', 'keyword.operator.word'],
    ['  h := {"rate" => 1.5}', '=>', 'punctuation.separator.key-value'],
    ['  c := SA1->A1_NOME', 'SA1', 'variable.other.alias'],
    ['  c := SA1->A1_NOME', 'A1_NOME', 'variable.other.field'],
    ['  ::cName := x', 'cName', 'variable.other.member'],
    ['  oDlg:Activate()', 'Activate', 'entity.name.function.member'],
    ['  x := 1  // a comment', ' a comment', 'comment.line.double-slash'],
    ['  x := 1  && a comment', ' a comment', 'comment.line.double-ampersand'],
    ['* a comment line', ' a comment line', 'comment.line.asterisk'],
    ['/* one */ x := 1', ' one ', 'comment.block'],
    ['#include "totvs.ch"', '"totvs.ch"', 'string.quoted.other.include'],
    ['#xcommand REPORTE <x> => u_Rep(<x>)', '<x>', 'variable.other.marker'],
    ['Class Pessoa From Base', 'Pessoa', 'entity.name.type.class'],
    ['Class Pessoa From Base', 'Base', 'entity.other.inherited-class'],
    ['Method New() Class Pessoa', 'New', 'entity.name.function'],
    ['  Data cNome', 'cNome', 'variable.other.member'],
    ['@Get("/clientes")', 'Get', 'storage.type.annotation'],
    ['external alias SA1, SB1', 'external', 'storage.modifier.external'],
    ['  conout(1); conout(2)', 'conout', 'entity.name.function.call'],
  ];
  for (const [text, piece, scope] of cases)
  {
    check(`${text.trim()}: '${piece}' is ${scope}`, () => scoped(grammar, text, piece, scope));
  }

  // A lambda only where a value starts: after a value '[' is an index.
  check("aX[i] is no lambda", () => !tokens(grammar, '  x := aX[i] + 1').some(([, s]) => s.includes('variable.parameter')));

  // A multi-line block comment, and a code block over two lines, close.
  check('a block comment over lines closes', () =>
  {
    const t = tokens(grammar, '/* one\n two */ x := 1');
    return t.find(([s]) => s === 'x')[1] === 'source.xtpl variable.other.xtpl';
  });

  // Every .xtpl of the repository: each line, as the grammar reads it, ends
  // where it started -- outside any string, comment or bracket -- unless it
  // is a line the source itself carries on (';', an open bracket, a block
  // comment). The test is lighter: no file leaves anything open at its end.
  const all = files(repo);
  let read = 0;
  const open = [];
  for (const f of all)
  {
    const text = fs.readFileSync(f, 'latin1');
    let stack = vsctm.INITIAL;
    for (const line of text.split(/\r?\n/))
    {
      stack = grammar.tokenizeLine(line, stack).ruleStack;
    }
    read++;
    if (stack.depth > 1)
    {
      open.push(path.relative(repo, f));
    }
  }
  check(`the repository's .xtpl files were read (${read})`, () => read >= 100);
  check('none of them is left inside anything at its end', () => open.length === 0);
  for (const f of open.slice(0, 10))
  {
    console.log('    open at the end: ' + f);
  }

  console.log(`\n  ${ok} of ${total}`);
  process.exit(ok === total ? 0 : 1);
})();
