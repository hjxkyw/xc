use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# A arvore das expressoes. Nada fica como texto: um nome lido dentro de
# 'o:x(n)[i]', de um code block ou de uma macro e um no -- que e o que uma
# analise de variaveis precisa para nao chamar de sem uso o que e lido la.

sub expr(Str $src)
{
  my $m = XC::Grammar.parse($src, rule => 'expr', actions => XC::Actions.new(fonte => $src));
  $m ?? $m.made !! Nil
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

# ---- trailers -------------------------------------------------------------------
confere "o:x(1)[2]: Indice de um Metodo de um Nome",
{
  my $e = expr('o:x(1)[2]');
  $e ~~ Indice && $e.base ~~ Metodo && $e.base.nome eq 'x'
    && $e.base.base ~~ Nome && $e.base.args == 1 && $e.indices == 1
};
confere "o:x:y(1):z: a cadeia inteira, na ordem",
{
  my $e = expr('o:x:y(1):z');
  $e ~~ Membro && $e.nome eq 'z' && $e.base ~~ Metodo && $e.base.nome eq 'y'
    && $e.base.base ~~ Membro && $e.base.base.nome eq 'x'
};
confere "a[1, 2] e a[1][2] sao coisas diferentes",
{
  my $x = expr('a[1, 2]');
  my $y = expr('a[1][2]');
  $x.indices == 2 && $x.base ~~ Nome && $y.indices == 1 && $y.base ~~ Indice
};
confere "o:End() e um metodo, nao o fim de nada",
{
  my $e = expr('o:End()');
  $e ~~ Metodo && $e.nome eq 'End' && !$e.args
};
confere "(a):x: o primario entre parenteses e a base",
{
  my $e = expr('(a):x');
  $e ~~ Membro && $e.base ~~ Nome && $e.base.nome eq 'a'
};

# ---- areas ----------------------------------------------------------------------
confere "SA1->A1_NOME: a area e um nome, nao uma variavel",
{
  my $e = expr('SA1->A1_NOME');
  $e ~~ CampoAlias && $e.alias eq 'SA1' && !$e.base.defined && $e.campo eq 'A1_NOME'
    && nomes($e) eq ''
};
confere "(cAlias)->A1_NOME: a area vem de uma variavel, que e lida",
{
  my $e = expr('(cAlias)->A1_NOME');
  $e ~~ CampoAlias && $e.base ~~ Nome && nomes($e) eq 'cAlias'
};
confere "SA1->( DbSeek(cChave) )",
{
  my $e = expr('SA1->( DbSeek(cChave) )');
  $e ~~ EmAlias && $e.alias eq 'SA1' && $e.expr ~~ Chamada && nomes($e) eq 'cChave'
};
confere "(cAlias)->( DbGoTop() )",
{
  my $e = expr('(cAlias)->( DbGoTop() )');
  $e ~~ EmAlias && $e.base ~~ Nome && $e.expr ~~ Chamada
};

# ---- argumentos -----------------------------------------------------------------
confere "f( , 1, , ): quatro posicoes, as vazias como Omitido",
{
  my @a = expr('f( , 1, , )').args;
  @a == 4 && @a[0] ~~ Omitido && @a[1] ~~ Literal && @a[2] ~~ Omitido && @a[3] ~~ Omitido
};
confere "f() nao tem argumento, f(1) tem um",
{
  expr('f()').args == 0 && expr('f(1)').args == 1
};
confere "f(@aX, 1): passagem por referencia",
{
  my $a = expr('f(@aX, 1)').args[0];
  $a ~~ Ref && $a.alvo.nome eq 'aX'
};
confere "If(c, a, cA := u): atribuicao como argumento",
{
  my $a = expr('If(c, a, cA := u)').args[2];
  $a ~~ AtribExpr && $a.alvo.nome eq 'cA' && $a.valor.nome eq 'u'
};

# ---- blocos, macros, literais -----------------------------------------------------
confere '{ |a, b| a + b, c }: parametros e duas expressoes',
{
  my $e = expr('{ |a, b| a + b, c }');
  $e ~~ Bloco && $e.params.join(',') eq 'a,b' && $e.corpo == 2 && $e.tipo eq 'Block'
};
confere '{ || x := 1, y }: atribuicao dentro do bloco',
{
  my $e = expr('{ || x := 1, y }');
  !$e.params && $e.corpo[0] ~~ AtribExpr && nomes($e) eq 'x y'
};
confere "&cVar le cVar, &(cA + cB) le os dois",
{
  my $x = expr('&cVar');
  my $y = expr('&(cA + cB)');
  $x ~~ Macro && nomes($x) eq 'cVar' && $y ~~ Macro && nomes($y) eq 'cA cB'
};
confere '{1, n, 3}: array com os itens, e tipo Array',
{
  my $e = expr('{1, n, 3}');
  $e ~~ ArrayLit && $e.itens == 3 && $e.tipo eq 'Array' && nomes($e) eq 'n'
};
confere '{ "a": nX } e { 1 => nY }: pares, com os valores lidos',
{
  my $j = expr('{ "a": nX }');
  my $h = expr('{ 1 => nY }');
  $j ~~ JsonLit && $j.pares == 1 && nomes($j) eq 'nX'
    && $h ~~ HashLit && nomes($h) eq 'nY'
};
confere '{ "a": nX } e JSON, nao um array com o membro nX de "a"',
{
  my $e = expr('{ "a": nX, "b": 2 }');
  $e ~~ JsonLit && $e.tipo eq 'JSON' && $e.pares[0].chave ~~ Literal
};
confere '{ : }, { => } e {}: vazios de cada tipo',
{
  expr('{ : }') ~~ JsonLit && expr('{ => }') ~~ HashLit && expr('{}') ~~ ArrayLit
};

# ---- o arquivo de referencia --------------------------------------------------------
# Todo nome lido ou escrito em saldo.xtpl, pelas expressoes dos comandos. Antes
# 'nX' so aparecia dentro de 'aTitulos[nX]:nSaldo', que era texto.
confere 'saldo.xtpl: todo nome aparece na arvore, nX inclusive',
{
  my $src = slurp('exemplos/saldo.xtpl');
  my $p = XC::Grammar.parse($src, actions => XC::Actions.new(fonte => $src)).made;
  my %vistos;
  percorre($p.funcoes[0].corpo, -> $c
  {
    percorre-expr($_, { %vistos{.nome} = True if $_ ~~ Nome }) for exprs-de($c);
  });
  %vistos.keys.sort.join(' ') eq 'aTitulos cCliente jResposta nLimite nTotal nX'
};

# ---- o que tem de ser recusado -------------------------------------------------------
my @recusar =
  'a[]'       => 'indice vazio',
  'o:'        => 'membro sem nome',
  'a->'       => 'campo sem nome',
  '&'         => 'macro sem nada',
  'f(1 2)'    => 'argumentos sem virgula',
  'o:x('      => 'parenteses sem fechar',
  '{|a b| a}' => 'parametros de bloco sem virgula',
  '"a":x'     => 'membro de uma string',
  '1[2]'      => 'indice de um numero',
  ;

for @recusar -> $c
{
  confere "recusa: {$c.value} ({$c.key})", { !expr($c.key).defined };
}

say "\n  $ok de $total";
exit($ok == $total ?? 0 !! 1);
