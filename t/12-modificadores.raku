use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# Modificadores posfixados do xtpl: 'x := 1 if c', 'return n if c',
# 'f() while c', 'exec f() if c'. Os casos vem dos testes e exemplos do xtpl.
# As duas direcoes: a forma que sai, e o que tem de ser recusado.
#
# 'return(x) if c' esta aqui de proposito: foi o caso que o fuzz_paths.py do
# xtpl achou -- certo num caminho do xtpl e errado no outro, e nenhum teste
# fixo cobria.

sub cmd(Str $linha)
{
  my $src = "user function f()\n  $linha\nreturn\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(fonte => $src));
  $m ?? $m.made.funcoes[0].corpo[0] !! Nil
}

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

# ---- return ---------------------------------------------------------------------
confere 'return if lSkip: sem valor -- o if nao e o valor',
{
  my $c = cmd('return if lSkip');
  $c ~~ Modificado && $c.op eq 'if' && $c.cmd ~~ Retorno && !$c.cmd.valor.defined
    && $c.cond ~~ Nome && $c.cond.nome eq 'lSkip'
};
confere 'return nTotal if nTotal > 100',
{
  my $c = cmd('return nTotal if nTotal > 100');
  $c.cmd ~~ Retorno && $c.cmd.valor.nome eq 'nTotal' && $c.cond ~~ Binaria
};
confere 'return(nTotal) if nX > 100: colado no (, e ainda um return',
{
  my $c = cmd('return(nTotal) if nX > 100');
  $c ~~ Modificado && $c.cmd ~~ Retorno && $c.cmd.valor.nome eq 'nTotal'
};
confere 'return {} if !lOk: literal como valor',
{
  my $c = cmd('return {} if !lOk');
  $c.cmd.valor ~~ ArrayLit && $c.cond ~~ Binaria
};
confere 'return sem modificador continua sendo um Retorno',
{
  my $c = cmd('return nX');
  $c ~~ Retorno && $c.valor.nome eq 'nX'
};

# ---- os outros comandos simples ---------------------------------------------------
confere 'lDone := .T. if nTotal > 5: atribuicao',
{
  my $c = cmd('lDone := .T. if nTotal > 5');
  $c ~~ Modificado && $c.cmd ~~ Atribuicao && $c.cmd.alvo.nome eq 'lDone'
};
confere 'exec resetAll() if nTotal == 0: a expressao vira comando',
{
  my $c = cmd('exec resetAll() if nTotal == 0');
  $c ~~ Modificado && $c.op eq 'if' && $c.cmd ~~ ChamadaCmd
    && $c.cmd.chamada.nome eq 'resetAll'
};
confere 'conout("x") while nTotal < 0: op while',
{
  my $c = cmd('conout("x") while nTotal < 0');
  $c.op eq 'while' && $c.cmd ~~ ChamadaCmd
};
confere 'exit if nErros > 3, e loop if empty(...)',
{
  cmd('exit if nErros > 3').cmd ~~ Sai
    && cmd('loop if empty(oItem:cCodigo)').cmd ~~ Continua
};
confere 'metodo como comando: oObj:Salva() if lOk',
{
  my $c = cmd('oObj:Salva() if lOk');
  $c.cmd ~~ ChamadaCmd && $c.cmd.chamada ~~ Metodo
};
confere 'campo de area na condicao: nT := 1 if SA1->A1_SALDO == "abc"',
{
  my $c = cmd('nT := 1 if SA1->A1_SALDO == "abc"');
  $c.cond ~~ Binaria && $c.cond.esq ~~ CampoAlias
};
confere 'comentario no fim da linha',
{
  cmd('exit if nX == 0   // nao e palavra de bloco').cmd ~~ Sai
};

# ---- palavras que so comecam com if/while -------------------------------------------
confere 'iif(...) nao e modificador',
{
  my $c = cmd('x := iif(a, b, c)');
  $c ~~ Atribuicao && $c.valor ~~ Chamada && $c.valor.nome eq 'iif'
};
confere 'iif(...) seguido de um modificador de verdade',
{
  my $c = cmd('x := iif(a, b, c) if d');
  $c ~~ Modificado && $c.cmd.valor.nome eq 'iif' && $c.cond.nome eq 'd'
};
confere 'x := ifood: variavel que comeca com if',
{
  my $c = cmd('x := ifood');
  $c ~~ Atribuicao && $c.valor.nome eq 'ifood'
};
confere 'x := 1 if ifood: condicao que comeca com if',
{
  cmd('x := 1 if ifood').cond.nome eq 'ifood'
};

# ---- percorrer ---------------------------------------------------------------------
confere 'percorre visita o Modificado e o comando de dentro',
{
  my @vistos;
  percorre((cmd('x := nA if nB'),), { @vistos.push(.^name.subst('XC::AST::', '')) });
  @vistos.join(' ') eq 'Modificado Atribuicao'
};
confere 'exprs-de do Modificado e a condicao',
{
  my @n;
  percorre-expr($_, { @n.push(.nome) if $_ ~~ Nome }) for exprs-de(cmd('x := nA if nB > nC'));
  @n.join(' ') eq 'nB nC'
};

# ---- o que tem de ser recusado -------------------------------------------------------
my @recusar =
  'exec resetAll()'           => 'exec sem modificador',
  'local x := 1 if c'         => 'declaracao com modificador',
  'if x if y'                 => 'if de bloco com modificador',
  'x := 1 if'                 => 'modificador sem condicao',
  'return if'                 => 'return com modificador sem condicao',
  'x := 1 if a if b'          => 'dois modificadores',
  'x := 1 unless c'           => 'unless nao existe',
  ;

for @recusar -> $c
{
  confere "recusa: {$c.value} ({$c.key})", { !casa($c.key) };
}

say "\n  $ok de $total";
exit($ok == $total ?? 0 !! 1);
