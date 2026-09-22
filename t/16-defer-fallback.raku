use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# 'defer' e 'fallback' do xtpl. Os casos vem dos testes e exemplos do xtpl. As
# duas direcoes: a forma que sai, e o que tem de ser recusado -- em especial o
# 'fallback' fora dos quatro lugares onde o xtpl o aceita.

sub corpo(Str $linhas)
{
  my $src = "user function f()\n$linhas\nreturn\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(fonte => $src));
  $m ?? $m.made.funcoes[0].corpo !! Nil
}

sub cmd(Str $linha) { my $c = corpo("  $linha"); $c ?? $c[0] !! Nil }

sub casa(Str $linha)
{
  XC::Grammar.parse("user function f()\n  $linha\nreturn\n").defined
}

my ($ok, $total) = 0, 0;
sub confere(Str $o-que, &teste)
{
  $total++;
  my $v = try teste();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FALHA '), $o-que);
}

# ---- fallback ---------------------------------------------------------------------
confere 'no valor de uma atribuicao: Guarda com a expressao e a alternativa',
{
  my $g = cmd('cResposta := chamaServico(cUrl, cChave) fallback ""').valor;
  $g ~~ Guarda && $g.expr ~~ Chamada && $g.expr.nome eq 'chamaServico'
    && $g.alternativa ~~ Literal
};
confere 'protege a cadeia inteira: mais frouxo que |>',
{
  my $g = cmd('nSafe := aNums |> filter([x] x > 100) |> asum fallback 0').valor;
  $g ~~ Guarda && $g.expr ~~ Cadeia && $g.expr.etapas == 2
};
confere 'entre parenteses protege so um pedaco: (a fallback {}) |> ...',
{
  my $c = cmd('aList := (riskyCall(2) fallback {}) |> filter([x] x > 1)').valor;
  $c ~~ Cadeia && $c.fonte ~~ Guarda && $c.fonte.alternativa ~~ ArrayLit
};
confere 'entre parenteses, com ?: depois',
{
  my $e = cmd('aItens := (jDados["itens"] fallback nil) ?: {}').valor;
  $e ~~ Binaria && $e.op eq '?:' && $e.esq ~~ Guarda
};
confere 'no inicializador de uma declaracao',
{
  cmd('local nH := riskyCall(1) fallback 0').nomes[0].inicial ~~ Guarda
};
confere 'num return',
{
  my $r = cmd('return f() fallback 0');
  $r ~~ Retorno && $r.valor ~~ Guarda
};
confere 'alternativa negativa: nTmp := aNums[99] fallback -1',
{
  my $g = cmd('nTmp := aNums[99] fallback -1').valor;
  $g.expr ~~ Indice && $g.alternativa ~~ Binaria && $g.alternativa.op eq 'neg'
};
confere 'com modificador: a guarda fica dentro do comando',
{
  my $c = cmd('nS := riskyCall(1) fallback 0 if lX');
  $c ~~ Modificado && $c.cmd.valor ~~ Guarda
};
confere 'sem fallback nao ha Guarda',
{
  cmd('x := f()').valor ~~ Chamada
};
confere 'fallbackX e um nome',
{
  cmd('x := fallbackX').valor.nome eq 'fallbackX'
};
confere 'nomes lidos: os dois lados',
{
  my @n;
  percorre-expr(cmd('x := f(nA) fallback nB').valor, { @n.push(.nome) if $_ ~~ Nome });
  @n.join(' ') eq 'nA nB'
};

# ---- defer ------------------------------------------------------------------------
confere 'defer closeCursor(): Adiado com a chamada',
{
  my $d = cmd('defer closeCursor()');
  $d ~~ Adiado && $d.cmd ~~ ChamadaCmd && $d.cmd.chamada.nome eq 'closeCursor'
};
confere 'defer de metodo e de alias',
{
  cmd('defer oLog:Close()').cmd.chamada ~~ Metodo
    && cmd('defer ZAPUR->(DbCloseArea())').cmd.chamada ~~ EmAlias
};
confere 'defer de uma atribuicao',
{
  my $d = cmd('defer nTotal := nTotal + 1');
  $d.cmd ~~ Atribuicao && $d.cmd.alvo.nome eq 'nTotal'
};
confere 'defer de uma cadeia',
{
  my $d = cmd('defer aRows |> validate() |> flush()');
  $d.cmd ~~ ChamadaCmd && $d.cmd.chamada ~~ Cadeia
};
confere 'defer dentro de um bloco',
{
  my @c = corpo("  if nX > 0\n    local nA := 5\n    defer logIt(nA)\n  endif");
  @c[0].ramos[0].corpo[1] ~~ Adiado
};
confere 'um nome lido so pelo defer aparece no percurso',
{
  my @n;
  percorre(corpo("  defer reportTotal(nCount)"), -> $c
  {
    percorre-expr($_, { @n.push(.nome) if $_ ~~ Nome }) for exprs-de($c);
  });
  @n.join eq 'nCount'
};
confere 'deferred := 1 e uma atribuicao comum',
{
  cmd('deferred := 1') ~~ Atribuicao
};

# ---- o que tem de ser recusado -------------------------------------------------------
my @recusar =
  'f(a fallback 0)'                         => 'fallback num argumento',
  'x := a fallback b fallback c'            => 'dois fallback',
  'x := map(a, [y] g(y) fallback 0)'        => 'fallback dentro de um lambda',
  'f() fallback g()'                        => 'fallback num comando de chamada',
  'x := a fallback'                         => 'fallback sem alternativa',
  'defer'                                   => 'defer sem comando',
  'defer x'                                 => 'defer de um nome solto',
  'defer f() if c'                          => 'defer com modificador',
  'defer local x := 1'                      => 'defer de uma declaracao',
  'defer return 1'                          => 'defer de um return',
  ;

for @recusar -> $c
{
  confere "recusa: {$c.value} ({$c.key})", { !casa($c.key) };
}

say "\n  $ok de $total";
exit($ok == $total ?? 0 !! 1);
