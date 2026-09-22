use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# Declaracoes de bloco no cabecalho -- o 'local' reaproveitado do TL++, na
# posicao que o xtpl acrescenta: 'for local i', 'if local x := f(), cond',
# 'while local ..., cond', 'do case with local x := f()'. E as duas direcoes:
# o que sai, e o que a mesma posicao NAO deve aceitar.
#
# Declaracao no CORPO de um bloco ('if cond' com um 'local' dentro) ja e um
# comando como qualquer outro; o que e novo aqui e a declaracao no cabecalho.

sub corpo(Str $linhas)
{
  my $src = "user function f()\n" ~ $linhas ~ "\n";
  my $p = XC::Grammar.parse($src, actions => XC::Actions.new(fonte => $src));
  $p ?? $p.made.funcoes[0].corpo !! Nil
}

sub casa(Str $linhas)
{
  XC::Grammar.parse("user function f()\n" ~ $linhas ~ "\nreturn").defined
}

my ($ok, $total) = 0, 0;
sub confere(Str $o-que, &teste)
{
  $total++;
  my $v = try teste();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FALHA '), $o-que);
}

# ---- for local ------------------------------------------------------------------
confere 'for local i: var-local marcado, e a variavel e i',
{
  my $f = corpo("  for local i := 1 to 3\n  next")[0];
  $f ~~ Para && $f.var eq 'i' && $f.var-local
};
confere 'for i sem local: var-local falso',
{
  !corpo("  for i := 1 to 3\n  next")[0].var-local
};
confere 'for local i com step e corpo',
{
  my $f = corpo("  for local i := 1 to 10 step 2\n    x()\n  next i")[0];
  $f.var-local && $f.passo.defined && $f.corpo == 1
};
confere 'for localVar: uma variavel que so comeca com "local"',
{
  my $f = corpo("  for localVar := 1 to 3\n  next")[0];
  $f ~~ Para && $f.var eq 'localVar' && !$f.var-local
};

# ---- if local ..., cond ----------------------------------------------------------
confere 'if local x := f(), cond: declarador no cabecalho e a condicao',
{
  my $s = corpo("  if local x := f(), x > 0\n    y()\n  endif")[0];
  $s ~~ Se && $s.hdrdecl.defined && $s.hdrdecl.nome eq 'x'
    && $s.hdrdecl.inicial ~~ Chamada
    && $s.ramos[0].cond ~~ Binaria && $s.ramos[0].corpo == 1
};
confere 'if sem local: hdrdecl indefinido',
{
  !corpo("  if x > 0\n  endif")[0].hdrdecl.defined
};
confere 'if local: o inicializador e a condicao entram em exprs-de',
{
  my $s = corpo("  if local x := leExpr(nA), x > nB\n  endif")[0];
  my @nomes;
  percorre-expr($_, { @nomes.push(.nome) if $_ ~~ Nome }) for exprs-de($s);
  # 'leExpr' e nome de chamada (Str), nao leitura; 'x' aparece na cond. O 'x'
  # escrito pelo declarador nao e expressao -- vem de hdrdecl.nome.
  @nomes.sort.join(' ') eq 'nA nB x'
};
confere 'if local com tipo no declarador',
{
  my $s = corpo("  if local nX := f() as Numeric, nX > 0\n  endif")[0];
  $s.hdrdecl.declarado eq 'Numeric'
};

# ---- while local ..., cond -------------------------------------------------------
confere 'while local x := f(), cond',
{
  my $w = corpo("  while local x := prox(), x != Nil\n    usa(x)\n  enddo")[0];
  $w ~~ Enquanto && $w.hdrdecl.defined && $w.hdrdecl.nome eq 'x'
    && $w.cond ~~ Binaria && $w.corpo == 1
};
confere 'while sem local: hdrdecl indefinido',
{
  !corpo("  while x < 10\n  enddo")[0].hdrdecl.defined
};

# ---- do case with ----------------------------------------------------------------
confere 'do case with local nS := f(): sujeito e um declarador',
{
  my $c = corpo("  do case with local nS := calc(n)\n  case nS == 1\n    a()\n  endcase")[0];
  $c ~~ Caso && $c.sujdecl.defined && $c.sujdecl.nome eq 'nS'
    && !$c.sujatrib.defined && $c.ramos == 1
};
confere 'do case with nOutro := f(): sujeito e uma atribuicao',
{
  my $c = corpo("  do case with nOutro := calc(n)\n  case nOutro > 3\n  endcase")[0];
  $c.sujatrib.defined && $c.sujatrib.alvo.nome eq 'nOutro'
    && !$c.sujdecl.defined
};
confere 'do case sem with: nenhum sujeito',
{
  my $c = corpo("  do case\n  case x == 1\n  otherwise\n    y()\n  endcase")[0];
  !$c.sujdecl.defined && !$c.sujatrib.defined && $c.senao == 1
};
confere 'do case with: o sujeito entra em exprs-de',
{
  my $c = corpo("  do case with local nS := soma(nA, nB)\n  case nS == 0\n  endcase")[0];
  my @nomes;
  percorre-expr($_, { @nomes.push(.nome) if $_ ~~ Nome }) for exprs-de($c);
  @nomes.sort.join(' ') eq 'nA nB nS'   # 'soma' e nome de chamada, nao leitura
};

# ---- o que tem de ser recusado -------------------------------------------------------
my @recusar =
  "  if local x := f()\n  endif"          => 'if local sem a condicao',
  "  if local x, y > 0\n  endif"          => 'if local sem inicializador',
  "  while local x := f()\n  enddo"       => 'while local sem a condicao',
  "  for local := 1 to 3\n  next"         => 'for local sem o nome',
  "  do case with\n  case x\n  endcase"   => 'do case with sem sujeito',
  ;

for @recusar -> $c
{
  confere "recusa: {$c.value}", { !casa($c.key) };
}

say "\n  $ok de $total";
exit($ok == $total ?? 0 !! 1);
