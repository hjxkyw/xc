use lib 'lib';
use XC::Grammar;

# Os fontes que o xtpl recusa, copiados em t/erros/ (ver t/erros/LEIA.md).
# Cada arquivo esta num grupo:
#
#   sintaxe    a gramatica recusa -- e o fonte com a correcao casa, o que
#              mostra que a recusa foi pelo erro certo
#   analise    a gramatica aceita; recusar e de uma passada que nao existe ainda
#   decidido   o xc aceita de proposito, contra o xtpl
#   pendente   usa uma construcao que o xc ainda nao le -- aparece, nao conta

# arquivo => a correcao, como pares 'de' => 'para' trocados em todo o texto
my %sintaxe =
  const_no_init         => ('local nL <const>' => 'local nL <const> := 1',),
  decl_trailing_comma   => ('local nA := 1,' => 'local nA := 1',),
  defined_or_expression => ('?= {}' => '?: {}',),
  feed_in_block         => ('[x] x |> triple' => '[x] triple(x)',),
  feed_no_head          => (':= |> distinct' => ':= aNums |> distinct',),
  generated_name        => ('fo_0_0' => 'nFo',),
  interp_unclosed       => ('{"t"}' => "\{'t'\}",),
  prologue              => ("  conout(n)\n  local m := 2\n" => "  local m := 2\n  conout(n)\n",),
  reserved_word         => ('local if' => 'local nIf', 'return if' => 'return nIf'),
  stale_fold            => ('[+]a' => 'asum(a)',),
  stale_keyword         => ("  given n do\n  end given\n" => "  do case\n  case n == 1\n  endcase\n",),
  unbalanced_line       => ('minhaFuncao(nX,' => 'minhaFuncao(nX, ;',),
  unknown_attribute     => ('<bogus>' => '<const>',),
  ;

my @analise = <
  arity_too_many call_form const_assign const_by_ref contained_captured
  contained_deferred distinct_adjacent_no_key fallback_over_source
  out_of_scope redeclared scalar_chain scalar_declared source_stranded
  undeclared_read undeclared_write
>;

# 'function' solto: o TL++ aceita com nome 'u_' (e talvez outros prefixos),
# entao o xc nao recusa -- o xtpl recusa todos.
my @decidido = <bare_function>;

my %pendente =
  external_assign => "'external'",
  using_unclosed  => "'using alias'",
  ;

my ($ok, $total) = 0, 0;
sub confere(Str $o-que, &teste)
{
  $total++;
  my $v = try teste();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FALHA '), $o-que);
}

sub casa(Str $src) { XC::Grammar.parse($src).defined }
sub fonte(Str $nome) { slurp("t/erros/$nome.xtpl") }

# ---- sintaxe: recusado, e a correcao casa ---------------------------------------
for %sintaxe.keys.sort -> $nome
{
  my $src = fonte($nome);
  confere "sintaxe  $nome: recusado", { !casa($src) };

  my $certo = $src;
  my $trocou = True;
  for %sintaxe{$nome}.list -> $p
  {
    $trocou = False unless $certo.contains($p.key);
    $certo = $certo.subst($p.key, $p.value, :g);
  }
  confere "sintaxe  $nome: corrigido, casa", { $trocou && casa($certo) };
}

# ---- analise: a gramatica aceita ------------------------------------------------
for @analise -> $nome
{
  confere "analise  $nome: a gramatica aceita", { casa(fonte($nome)) };
}

# ---- decidido ---------------------------------------------------------------------
for @decidido -> $nome
{
  confere "decidido $nome: aceito de proposito", { casa(fonte($nome)) };
}

# ---- pendente -----------------------------------------------------------------------
for %pendente.keys.sort -> $nome
{
  say "  pula   pendente $nome: usa %pendente{$nome}, que o xc ainda nao le";
}

# ---- o que o xtpl decide caso a caso --------------------------------------------
# Cada linha foi rodada no proprio xtpl ('--check'), e o veredito dele e o que
# se espera aqui. Varios nao sao obvios: o 'else' nao abre prologo, o
# 'begin sequence' nao e escopo, e a forma de nome gerado so e recusada no
# nivel da funcao, o unico que sai com o nome como foi escrito.
my @xtpl =
  # prologo
  True,  'local no comeco do corpo de um while', "  while n > 0\n    local nY := 1\n    n := n - nY\n  enddo",
  True,  'local no comeco do corpo de um for',   "  for local i := 1 to 3\n    local nY := i\n    conout(nY)\n  next",
  True,  'private no prologo',                   "  private nP := 0\n  conout(nP)",
  False, 'local depois de um comando',           "  conout(1)\n  local nL := 0",
  False, 'private depois de um comando',         "  conout(1)\n  private nP := 0",
  False, 'local no corpo do else',               "  if n > 0\n    conout(1)\n  else\n    local nY := 1\n  endif",
  False, 'local no corpo do else, if vazio',     "  if n > 0\n  else\n    local nY := 1\n  endif",
  False, 'local no corpo do elseif',             "  if n > 0\n    conout(1)\n  elseif n < 0\n    local nY := 1\n  endif",
  False, 'local no corpo de um case',            "  do case\n  case n > 0\n    local nY := 1\n  endcase",
  False, 'local dentro de begin sequence',       "  begin sequence\n    local nY := 1\n  end sequence",
  # palavras reservadas
  False, 'reservada como local: if',             "  local if := 1",
  False, 'reservada como local: len',            "  local len := 1",
  False, 'reservada em maiusculas: LEN',         "  local LEN := 1",
  False, 'reservada num cabecalho: if local',    "  if local len := 1, len > 0\n  endif",
  False, 'reservada num for local',              "  for local len := 1 to 2\n  next",
  True,  'reservada como parametro de lambda',   "  local b := map(a, [len] len + 1)",
  # formas de nome gerado
  False, 'gerado como local: FO_0_0',            "  local FO_0_0 := 1",
  False, "gerado como private: fo_0_0",          "  private fo_0_0 := 1",
  False, "gerado como local: __x",               "  local __x := 1",
  True,  'gerado num local de bloco',            "  if n > 0\n    local fo_0_0 := 1\n  endif",
  True,  'gerado num cabecalho: if local',       "  if local fo_0_0 := 1, fo_0_0 > 0\n  endif",
  True,  'gerado num for local',                 "  for local fo_0_0 := 1 to 2\n  next",
  True,  'gerado como parametro de lambda',      "  local b := map(a, [fo_0_0] fo_0_0 + 1)",
  True,  'quase: fo_0',                          "  local fo_0 := 1",
  True,  'quase: s_x_1',                         "  local s_x_1 := 1",
  ;

for @xtpl -> $aceita, $o-que, $corpo
{
  my $src = "user function f(n, a)\n$corpo\nreturn n\n";
  confere "xtpl {$aceita ?? 'aceita' !! 'recusa'}: $o-que", { casa($src) == $aceita };
}

# Parametros tem regra propria: palavra reservada recusada, forma gerada aceita.
confere 'xtpl recusa: reservada como parametro',   { !casa("user function f(if)\nreturn 1\n") };
confere 'xtpl aceita: gerado como parametro',      {  casa("user function f(fo_0_0)\nreturn 1\n") };

# ---- todo arquivo esta num grupo ---------------------------------------------------
my @todos = dir('t/erros').grep(*.extension eq 'xtpl').map(*.basename.subst('.xtpl', '')).sort;
my @conhecidos = (|%sintaxe.keys, |@analise, |@decidido, |%pendente.keys);
my @soltos = @todos.grep({ $_ !(elem) @conhecidos });
confere "todo arquivo de t/erros/ esta num grupo" ~ (@soltos ?? " -- sem grupo: {@soltos.join(', ')}" !! ''),
{
  !@soltos
};

say "\n  $ok de $total";
exit($ok == $total ?? 0 !! 1);
