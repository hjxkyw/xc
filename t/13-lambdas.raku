use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# O lambda do xtpl: '[nomes] corpo', de um a seis nomes, um corpo so. Os casos
# vem dos testes e exemplos do xtpl. As duas direcoes: a forma que sai, e o que
# tem de ser recusado.

sub expr(Str $src)
{
  my $m = XC::Grammar.parse($src, rule => 'expr', actions => XC::Actions.new(fonte => $src));
  $m ?? $m.made !! Nil
}

sub corpo(Str $linhas)
{
  my $src = "user function f()\n$linhas\nreturn\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(fonte => $src));
  $m ?? $m.made.funcoes[0].corpo !! Nil
}

sub lambdas(Expr $e)
{
  my @l;
  percorre-expr($e, { @l.push($_) if $_ ~~ Lambda });
  @l
}

sub nomes(Expr $e)
{
  my @n;
  percorre-expr($e, { @n.push(.nome) if $_ ~~ Nome });
  @n.join(' ')
}

my ($ok, $total) = 0, 0;
sub confere(Str $o-que, &teste)
{
  $total++;
  my $v = try teste();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FALHA '), $o-que);
}

# ---- a forma --------------------------------------------------------------------
confere 'map(aOrders, [o] o:nValue): o lambda e o segundo argumento',
{
  my $e = expr('map(aOrders, [o] o:nValue)');
  my $l = $e.args[1];
  $e ~~ Chamada && $e.args == 2 && $l ~~ Lambda
    && $l.params.join eq 'o' && $l.corpo == 1 && $l.corpo[0] ~~ Membro
};
confere 'reduce(aNums, [acc, x] acc + x, 0): a semente fica fora do corpo',
{
  my $e = expr('reduce(aNums, [acc, x] acc + x, 0)');
  $e.args == 3 && $e.args[1] ~~ Lambda && $e.args[1].params.join(',') eq 'acc,x'
    && $e.args[1].corpo[0] ~~ Binaria && $e.args[2] ~~ Literal
};
confere 'tap([cLinha] nLidas += 1): atribuicao como corpo',
{
  my $l = expr('tap([cLinha] nLidas += 1)').args[0];
  $l.corpo[0] ~~ AtribExpr && $l.corpo[0].op eq '+='
};
confere 'um lambda e um Bloco de tipo Block',
{
  my $l = expr('[o] o');
  $l ~~ Bloco && $l.tipo eq 'Block'
};
confere 'seis nomes',
{
  expr('[a, b, c, d, e, f] a + f').params == 6
};
confere 'corpo com array literal',
{
  expr('map(a, [oCampo] {alltrim(oCampo:X3_CAMPO), 1})').args[1].corpo[0] ~~ ArrayLit
};
confere 'virgula dentro de uma string nao termina o corpo',
{
  my $e = expr('map(a, [c] c + ", " + d)');
  $e.args == 2 && $e.args[1].corpo[0] ~~ Binaria
};

# ---- aninhados ------------------------------------------------------------------
confere 'lambda dentro de lambda',
{
  my @l = lambdas(expr('map(a, [x] filter(x, [y] y > 0))'));
  @l.map({ .params.join }).join(' ') eq 'x y'
};
confere 'verbo chamado direto dentro do lambda (o que o doc recomenda)',
{
  my $l = expr('map(aL, [a] asum(map(a, val)) / 3)').args[1];
  $l.corpo[0] ~~ Binaria && $l.corpo[0].esq ~~ Chamada
};
confere 'nomes lidos no corpo: o parametro e os de fora',
{
  nomes(expr('filter(aP, [o] o:nValor > nLimite)')) eq 'aP o nLimite'
};

# ---- o '[' como indice, e como lambda -------------------------------------------
confere 'a[i] continua sendo indice',
{
  expr('a[i]') ~~ Indice
};
confere 'f(a[1], [o] o): indice num argumento, lambda no outro',
{
  my $e = expr('f(a[1], [o] o)');
  $e.args[0] ~~ Indice && $e.args[1] ~~ Lambda
};
confere 'o lambda guardado numa variavel',
{
  my $c = corpo("  bVal := [o] o:nValor")[0];
  $c ~~ Atribuicao && $c.valor ~~ Lambda
};
confere "cabeca numa linha, corpo na outra, com ';'",
{
  my $c = corpo("  aZ := zip(aA, aB, [cA, cB] ;\n       cA + cB)")[0];
  my $l = $c.valor.args[2];
  $l ~~ Lambda && $l.params.join(',') eq 'cA,cB' && $l.corpo[0] ~~ Binaria
};

# ---- o que tem de ser recusado -------------------------------------------------------
my @recusar =
  'map(a, [] x)'                   => 'sem nome',
  'map(a, [a, b, c, d, e, f, g] a)' => 'sete nomes',
  'map(a, [x y] x)'                => 'nomes sem virgula',
  'map(a, [x])'                    => 'sem corpo',
  'map(a, [1] x)'                  => 'parametro que nao e nome',
  'map(a, [o.x] o)'                => 'parametro pontuado',
  'map(a, [o] local x)'            => 'declaracao como corpo',
  ;

for @recusar -> $c
{
  confere "recusa: {$c.value} ({$c.key})", { !expr($c.key).defined };
}

say "\n  $ok de $total";
exit($ok == $total ?? 0 !! 1);
