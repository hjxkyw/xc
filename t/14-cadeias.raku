use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# O '|>' do xtpl: o valor da esquerda vira o primeiro argumento da etapa da
# direita. As duas direcoes: a forma que sai, e o que tem de ser recusado --
# em especial a cadeia dentro de um lambda ou code block, que o xtpl recusa e
# que, se so parasse o corpo, mudaria o programa calado.

sub cmd(Str $linhas)
{
  my $src = "user function f()\n$linhas\nreturn\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(fonte => $src));
  $m ?? $m.made.funcoes[0].corpo[0] !! Nil
}

sub casa(Str $linhas)
{
  XC::Grammar.parse("user function f()\n$linhas\nreturn\n").defined
}

sub expr(Str $src)
{
  my $m = XC::Grammar.parse($src, rule => 'expr', actions => XC::Actions.new(fonte => $src));
  $m ?? $m.made !! Nil
}

sub etapas(Cadeia $c) { $c.etapas.map({ .nome ~ '/' ~ .args.elems }).join(' ') }

my ($ok, $total) = 0, 0;
sub confere(Str $o-que, &teste)
{
  $total++;
  my $v = try teste();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FALHA '), $o-que);
}

# ---- a forma --------------------------------------------------------------------
confere 'filter |> map: a fonte, e as etapas sem o primeiro argumento',
{
  my $c = cmd('  aC := aPedidos |> filter([o] o:nValor > 1000) |> map([o] o:cCodigo)').valor;
  $c ~~ Cadeia && $c.fonte ~~ Nome && $c.fonte.nome eq 'aPedidos'
    && etapas($c) eq 'filter/1 map/1' && $c.etapas[0].args[0] ~~ Lambda
};
confere 'etapa como nome solto: |> distinct |> asum',
{
  etapas(expr('aNums |> distinct |> asum')) eq 'distinct/0 asum/0'
};
confere 'sem |> nao ha Cadeia',
{
  expr('aNums') ~~ Nome && expr('f(x)') ~~ Chamada
};
confere 'etapa com argumentos proprios: |> meuAuxiliar(3)',
{
  my $c = expr('aPedidos |> meuAuxiliar(3) |> ordenaLinhas');
  etapas($c) eq 'meuAuxiliar/1 ordenaLinhas/0' && $c.etapas[0].args[0] ~~ Literal
};
confere 'etapa qualificada: |> pkg.util.f(1)',
{
  expr('a |> pkg.util.f(1)').etapas[0].nome eq 'pkg.util.f'
};

# ---- onde a cadeia fica ---------------------------------------------------------
confere 'dentro de um argumento: len(aNums |> distinct)',
{
  my $e = cmd('  nTotal := len(aNums |> distinct)').valor;
  $e ~~ Chamada && $e.nome eq 'len' && $e.args[0] ~~ Cadeia
};
confere 'num argumento, sem arrastar os outros: f(a |> g, b)',
{
  my $e = expr('f(a |> g, b)');
  $e.args == 2 && $e.args[0] ~~ Cadeia && $e.args[1] ~~ Nome
};
confere 'aninhada no argumento de uma etapa: a |> take(len(b |> distinct))',
{
  my $c = expr('a |> take(len(b |> distinct))');
  $c ~~ Cadeia && $c.etapas[0].args[0].args[0] ~~ Cadeia
};
confere 'como comando, pelos efeitos: aPedidos |> valida() |> grava()',
{
  my $c = cmd('  aPedidos |> valida() |> grava()');
  $c ~~ ChamadaCmd && $c.chamada ~~ Cadeia && etapas($c.chamada) eq 'valida/0 grava/0'
};
confere 'comando que comeca com chamada: f(x) |> g()',
{
  my $c = cmd('  f(x) |> g()');
  $c ~~ ChamadaCmd && $c.chamada ~~ Cadeia && $c.chamada.fonte ~~ Chamada
};
confere 'return de uma cadeia',
{
  my $c = cmd('  return aNums |> asum');
  $c ~~ Retorno && $c.valor ~~ Cadeia
};
confere 'com modificador: nB := aNums |> asum if lFlag',
{
  my $c = cmd('  nB := aNums |> asum if lFlag');
  $c ~~ Modificado && $c.cmd.valor ~~ Cadeia && $c.cond.nome eq 'lFlag'
};
confere "em varias linhas, com ';'",
{
  my $c = cmd("  aX := aP ;\n    |> filter([o] o:lOk) ;\n    |> map([o] o:cCod)").valor;
  $c ~~ Cadeia && etapas($c) eq 'filter/1 map/1'
};

# ---- precedencia ----------------------------------------------------------------
confere 'o |> e o mais frouxo: a + b |> f tem a soma como fonte',
{
  my $c = expr('a + b |> f');
  $c ~~ Cadeia && $c.fonte ~~ Binaria && $c.fonte.op eq '+'
};
confere 'mais frouxo que .or.: lA .or. lB |> f',
{
  my $c = expr('lA .or. lB |> f');
  $c ~~ Cadeia && $c.fonte ~~ Binaria
};
confere 'literal como fonte: {1, 2, 3} |> asum',
{
  expr('{1, 2, 3} |> asum').fonte ~~ ArrayLit
};

# ---- percorrer ---------------------------------------------------------------------
confere 'nomes lidos: a fonte e o corpo dos lambdas; nome de etapa nao e leitura',
{
  my @n;
  percorre-expr(expr('aP |> filter([o] o:nV > nLim) |> asum'), { @n.push(.nome) if $_ ~~ Nome });
  @n.join(' ') eq 'aP o nLim'
};

# ---- o que tem de ser recusado -------------------------------------------------------
my @recusar =
  '  aOut := map(aNums, [x] x |> triplica)'    => 'cadeia no corpo de um lambda',
  '  aOut := map(aNums, {|x| x |> triplica})'  => 'cadeia num code block',
  '  aOut := map(aNums, [x] f(x |> g))'        => 'cadeia aninhada dentro de um lambda',
  '  x := a |>'                                => 'sem etapa',
  '  |> f'                                     => 'sem fonte',
  '  x := a |> 1'                              => 'literal como etapa',
  '  x := a |> (f)'                            => 'etapa entre parenteses',
  '  x := a |> o:m()'                          => 'metodo como etapa',
  ;

for @recusar -> $c
{
  confere "recusa: {$c.value}", { !casa($c.key) };
}

say "\n  $ok de $total";
exit($ok == $total ?? 0 !! 1);
