use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# Os operadores do xtpl: 'h{"k"}' e 'has', 'in', 'lo..hi', '%%', '?:', '?.',
# '?=', e as marcas '<const>'/'<contained>'. As duas direcoes: a forma e a
# precedencia que saem, e o que tem de ser recusado.

sub expr(Str $src)
{
  my $m = XC::Grammar.parse($src, rule => 'expr', actions => XC::Actions.new(fonte => $src));
  $m ?? $m.made !! Nil
}

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

# ---- hash -----------------------------------------------------------------------
confere 'hCfg{"taxa"}: IndiceHash, base e chave',
{
  my $e = expr('hCfg{"taxa"}');
  $e ~~ IndiceHash && $e.base.nome eq 'hCfg' && $e.chave ~~ Literal
};
confere 'chave que e expressao: hDescricao{oItem:cProduto}',
{
  my $e = expr('hDescricao{oItem:cProduto}');
  $e.chave ~~ Membro && nomes($e) eq 'hDescricao oItem'
};
confere 'como alvo: hCfg{"limite"} := 2000',
{
  my $c = cmd('hCfg{"limite"} := 2000');
  $c ~~ Atribuicao && $c.alvo ~~ IndiceHash
};
confere 'dentro de uma conta: nBase * hCfg{"taxa"}',
{
  my $e = expr('nBase * hCfg{"taxa"}');
  $e ~~ Binaria && $e.op eq '*' && $e.dir ~~ IndiceHash
};
confere 'has, e com .and.: (h has "a") .and. (h has "b")',
{
  my $e = expr('hCfg has "a" .and. hCfg has "b"');
  $e.op eq '.and.' && $e.esq.op eq 'has' && $e.dir.op eq 'has'
};

# ---- in e lo..hi -------------------------------------------------------------------
confere 'cCod in aCodigos',
{
  my $e = expr('cCod in aCodigos');
  $e ~~ Binaria && $e.op eq 'in' && $e.dir.nome eq 'aCodigos'
};
confere 'a colecao para no .and.: (cCod in aC) .and. lOk',
{
  my $e = expr('cCod in aC .and. lOk');
  $e.op eq '.and.' && $e.esq.op eq 'in'
};
confere 'e na virgula: f(cCod in aCodes, nValor) tem dois argumentos',
{
  my $e = expr('f(cCod in aCodes, nValor)');
  $e.args == 2 && $e.args[0].op eq 'in'
};
confere 'o literal fica inteiro: n in {1, 2, 3}',
{
  expr('n in {1, 2, 3}').dir ~~ ArrayLit
};
confere 'nValor in 1..100: o intervalo a direita',
{
  my $e = expr('nValor in 1..100');
  $e.op eq 'in' && $e.dir ~~ Intervalo && $e.dir.de.texto eq '1' && $e.dir.ate.texto eq '100'
};
confere '1..999 |> asum: intervalo como fonte',
{
  my $e = expr('1..999 |> asum');
  $e ~~ Cadeia && $e.fonte ~~ Intervalo
};
confere 'pontas com conta: n in a + 1..b - 1',
{
  my $i = expr('n in a + 1..b - 1').dir;
  $i ~~ Intervalo && $i.de ~~ Binaria && $i.ate ~~ Binaria
};
confere 'index e inList sao nomes, nao o operador in',
{
  expr('index') ~~ Nome && expr('f(inList)').args[0].nome eq 'inList'
};

# ---- %% ----------------------------------------------------------------------------
confere '(nX * 2) %% 2',
{
  my $e = expr('(nX * 2) %% 2');
  $e.op eq '%%' && $e.esq.op eq '*'
};
confere 'a %% 3 .or. a %% 5: mais forte que .or.',
{
  my $e = expr('a %% 3 .or. a %% 5');
  $e.op eq '.or.' && $e.esq.op eq '%%' && $e.dir.op eq '%%'
};
confere 'o % do AdvPL continua sendo %',
{
  expr('5 % 2').op eq '%'
};

# ---- ?: e ?. -------------------------------------------------------------------------
confere 'a ?: b ?: c encadeia pela direita',
{
  my $e = expr('a ?: b ?: c');
  $e.op eq '?:' && $e.esq.nome eq 'a' && $e.dir.op eq '?:'
};
confere '?: e mais frouxo que .or.',
{
  my $e = expr('a .or. b ?: c');
  $e.op eq '?:' && $e.esq.op eq '.or.'
};
confere '?: e mais forte que |>',
{
  my $e = expr('f() ?: {} |> tap([x] x)');
  $e ~~ Cadeia && $e.fonte.op eq '?:'
};
confere 'oP?.oC?.cNome: dois elos seguros',
{
  my $e = expr('oP?.oC?.cNome');
  $e ~~ MembroSeguro && $e.nome eq 'cNome' && $e.base ~~ MembroSeguro
    && $e.base.base.nome eq 'oP'
};
confere 'um MembroSeguro ainda e um Membro',
{
  expr('o?.x') ~~ Membro
};
confere 'oUser?.cCity ?: "x"',
{
  my $e = expr('oUser?.cCity ?: "x"');
  $e.op eq '?:' && $e.esq ~~ MembroSeguro
};

# ---- ?= -----------------------------------------------------------------------------
confere 'cCache ?= "vazio": Atribuicao com op ?=',
{
  my $c = cmd('cCache ?= "vazio"');
  $c ~~ Atribuicao && $c.op eq '?=' && $c.alvo.nome eq 'cCache'
};
confere '?= com modificador',
{
  my $c = cmd('nX ?= 3 if lReset');
  $c ~~ Modificado && $c.cmd.op eq '?='
};

# ---- marcas ---------------------------------------------------------------------------
confere 'local v1 <const, contained> := 0, v2 := 1',
{
  my $d = cmd('local v1 <const, contained> := 0, v2 := 1');
  $d.nomes[0].marcas.join(',') eq 'const,contained' && !$d.nomes[1].marcas
};
confere 'local v5<const>:=3, sem espaco nenhum',
{
  cmd('local v5<const>:=3').nomes[0].marcas.join eq 'const'
};
confere 'local aW <contained>, sem valor',
{
  my $d = cmd('local aW <contained>').nomes[0];
  $d.marcas.join eq 'contained' && !$d.inicial.defined
};
confere 'marca com tipo: local n <const> := 1 as N',
{
  my $d = cmd('local n <const> := 1 as N').nomes[0];
  $d.marcas.join eq 'const' && $d.declarado eq 'Numeric'
};

# ---- o que tem de ser recusado -------------------------------------------------------
my @recusar =
  'x := hCfg {"taxa"}'        => 'espaco entre o nome e o {',
  'x := h{"a"}{"b"}'          => 'hash de hash',
  'x := 1..10'                => 'intervalo solto',
  'x := f(1..10)'             => 'intervalo como argumento',
  'x := (f() ?= 1)'           => '?= numa expressao',
  'local x ?= 1'              => '?= numa declaracao',
  'local x <const>'           => 'const sem valor',
  'local x <const> as N'      => 'const sem valor, com tipo',
  'local x <frozen> := 1'     => 'marca que nao existe',
  'local x <> := 1'           => 'marca vazia',
  'x := o?.M()'               => '?. com chamada',
  'x := a ?:'                 => '?: sem lado direito',
  'x := a in'                 => 'in sem colecao',
  'x := n %%'                 => '%% sem lado direito',
  ;

for @recusar -> $c
{
  confere "recusa: {$c.value} ({$c.key})", { !casa($c.key) };
}

say "\n  $ok de $total";
exit($ok == $total ?? 0 !! 1);
