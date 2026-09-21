use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# A arvore dos comandos. As duas direcoes, como em 07: a forma que tem de sair,
# e o que tem de ser recusado. Varios casos daqui eram aceitos com a forma
# errada quando a quebra de linha era so espaco -- um 'return' sem valor
# levava a linha de baixo, e o 'user' da funcao seguinte.

sub arvore(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(fonte => $src));
  $m ?? $m.made !! Nil
}

# Um corpo solto, dentro de uma funcao que nao faz mais nada.
sub corpo(Str $linhas)
{
  my $p = arvore("user function f()\n" ~ $linhas ~ "\n");
  $p ?? $p.funcoes[0].corpo !! Nil
}

sub tipos(@c) { @c.map(*.^name.subst('XC::AST::', '')).join(' ') }

my ($ok, $total) = 0, 0;
sub confere(Str $o-que, &teste)
{
  $total++;
  my $v = try teste();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FALHA '), $o-que);
}

# ---- o arquivo de referencia --------------------------------------------------
my $p = arvore(slurp('exemplos/saldo.tlpp'));

confere 'saldo.tlpp: namespace, using, include',
{
  $p.namespace eq 'exemplo.saldo' && $p.usings eqv ['tlpp.regex']
    && $p.diretivas eqv ['#include "totvs.ch"']
};
confere 'saldo.tlpp: uma user function, na linha 19',
{
  $p.funcoes == 1 && $p.funcoes[0].tipo eq 'user'
    && $p.funcoes[0].nome eq 'saldo' && $p.funcoes[0].linha == 19
};
confere 'saldo.tlpp: a anotacao fica na funcao, nao solta',
{
  $p.funcoes[0].anotacoes.map(*.nome).List eqv ('Get',) && !$p.anotacoes
};
confere 'saldo.tlpp: parametros tipados, abreviacao expandida',
{
  $p.funcoes[0].params.map({ .nome ~ ':' ~ .declarado }).join(' ')
    eq 'cCliente:Character nLimite:Numeric'
};
confere 'saldo.tlpp: os comandos do corpo, em ordem',
{
  tipos($p.funcoes[0].corpo) eq
    'Declaracao Declaracao Declaracao Declaracao Declaracao Se Atribuicao '
    ~ 'Para Caso Sequencia Retorno'
};
confere 'saldo.tlpp: percorre desce em tudo, em ordem de leitura',
{
  my @vistos;
  percorre($p.funcoes[0].corpo, { @vistos.push($_) });
  tipos(@vistos.grep({ $_ !~~ Declaracao })) eq
    'Se Retorno Atribuicao Para Se Continua Atribuicao Se Sai Caso '
    ~ 'ChamadaCmd ChamadaCmd ChamadaCmd Sequencia Atribuicao Atribuicao Retorno'
};
confere 'saldo.tlpp: o ultimo return esta na linha 62 e devolve nTotal',
{
  my $r = $p.funcoes[0].corpo[*-1];
  $r ~~ Retorno && $r.linha == 62 && $r.valor ~~ Nome && $r.valor.nome eq 'nTotal'
};

# ---- a forma de cada comando ---------------------------------------------------
confere 'if / elseif / elseif / else: tres ramos e um senao',
{
  my @c = corpo("  if a\n    x()\n  elseif b\n    y()\n  elseif c\n    z()\n  else\n    w()\n  endif");
  @c == 1 && @c[0].ramos == 3 && @c[0].senao == 1
    && @c[0].ramos.map({ .cond.nome }).join eq 'abc'
};
confere 'if sem else: senao vazio, e o comando seguinte fica fora',
{
  my @c = corpo("  if a\n    x()\n  endif\n  y()");
  tipos(@c) eq 'Se ChamadaCmd' && !@c[0].senao && @c[0].ramos[0].corpo == 1
};
confere 'do case: os cases como ramos, otherwise como senao',
{
  my @c = corpo("  do case\n  case a\n    x()\n  case b\n  otherwise\n    y()\n    z()\n  endcase");
  @c[0] ~~ Caso && @c[0].ramos == 2 && !@c[0].ramos[1].corpo && @c[0].senao == 2
};
confere 'for com step: var, de, ate e passo',
{
  my $f = corpo("  for i := 10 to 1 step -1\n    x()\n  next i")[0];
  $f ~~ Para && $f.var eq 'i' && $f.de.texto eq '10' && $f.passo.defined
    && $f.corpo == 1
};
confere 'for sem step: passo indefinido',
{
  !corpo("  for i := 1 to n\n  next")[0].passo.defined
};
confere 'while com exit e loop dentro de um if',
{
  my $w = corpo("  while a\n    if b\n      exit\n    endif\n    loop\n  enddo")[0];
  $w ~~ Enquanto && tipos($w.corpo) eq 'Se Continua'
    && tipos($w.corpo[0].ramos[0].corpo) eq 'Sai'
};
confere 'begin sequence ... recover using oErr',
{
  my $s = corpo("  begin sequence\n    x()\n  recover using oErr\n    y()\n  end sequence")[0];
  $s ~~ Sequencia && $s.tem-recover && $s.erro eq 'oErr' && $s.recupera == 1
};
confere 'begin sequence sem recover',
{
  my $s = corpo("  begin sequence\n    x()\n  end")[0];
  !$s.tem-recover && !$s.erro.defined && !$s.recupera
};
confere 'atribuicao: op, e alvo com trailer vira a cadeia',
{
  my @c = corpo("  n += 1\n  oObj:nX := 2\n  a[i] := 3");
  @c[0].op eq '+=' && @c[0].alvo ~~ Nome
    && @c[1].alvo ~~ Membro && @c[1].alvo.base.nome eq 'oObj'
    && @c[2].alvo ~~ Indice && @c[2].alvo.indices[0].nome eq 'i'
};
confere 'chamada como comando: de funcao e de metodo',
{
  my @c = corpo("  conout(\"a\", 1)\n  oDlg:Activate()");
  @c[0].chamada ~~ Chamada && @c[0].chamada.args == 2
    && @c[1].chamada ~~ Metodo && @c[1].chamada.nome eq 'Activate'
};
confere 'anotacao sem funcao depois fica no programa',
{
  my $q = arvore("@Deprecated\n#define X 1\n");
  $q.anotacoes.map(*.nome).List eqv ('Deprecated',) && !$q.funcoes
};

# ---- onde a linha acaba ----------------------------------------------------------
confere 'return sem valor nao leva a linha de baixo',
{
  my @c = corpo("  return\n  conout(1)");
  tipos(@c) eq 'Retorno ChamadaCmd' && !@c[0].valor.defined
};
confere 'return sem valor dentro de um if',
{
  my @c = corpo("  if x\n    return\n  endif\n  return 1");
  tipos(@c) eq 'Se Retorno' && !@c[0].ramos[0].corpo[0].valor.defined
};
confere "return no fim nao leva o 'user' da funcao seguinte",
{
  my $q = arvore("user function f()\n  return\n\nuser function g()\n  return\n");
  $q.funcoes.map({ .tipo ~ ' ' ~ .nome }).join(', ') eq 'user f, user g'
};
confere 'duas static function seguidas',
{
  arvore("static function f()\n  return 1\nstatic function g()\n  return 2\n")
    .funcoes.map(*.tipo).join(' ') eq 'static static'
};
confere "next sem nome nao leva a linha de baixo",
{
  tipos(corpo("  for i := 1 to 3\n  next\n  do case\n  case a\n  endcase")) eq 'Para Caso'
};
confere "';' no fim continua o comando",
{
  my @c = corpo("  n := soma(1, ;\n           2)\n  return n");
  tipos(@c) eq 'Atribuicao Retorno' && @c[0].valor.args == 2
};
confere 'comentarios e linhas em branco nao viram comando',
{
  tipos(corpo("  // so isto\n\n  n := 1 // no fim\n  /* dois\n  */\n  return n"))
    eq 'Atribuicao Retorno'
};
confere 'fim de linha CRLF',
{
  tipos(corpo("  n := 1\r\n  return n\r")) eq 'Atribuicao Retorno'
};

# ---- o que tem de ser recusado -------------------------------------------------------
my @recusar =
  "  n := 1  m := 2"                   => 'dois comandos numa linha',
  "  if x n := 1 endif"                => 'if inteiro numa linha',
  "  n := 1\n  -1"                     => 'expressao continuando sem ;',
  "  if x\n    y()"                    => 'if sem endif',
  "  for i := 1 to 3\n    y()"         => 'for sem next',
  "  local nX as Numeric := 1"         => 'tipo antes do inicializador, no corpo',
  ;

for @recusar -> $c
{
  confere "recusa: {$c.value}", { !corpo($c.key).defined };
}

say "\n  $ok de $total";
exit($ok == $total ?? 0 !! 1);
