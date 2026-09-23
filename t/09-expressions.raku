use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# The tree of the expressions. Nothing stays as text: a name read inside
# 'o:x(n)[i]', a code block or a macro is a node -- which is what a variable
# analysis needs so as not to call unused what is read there.

sub expr(Str $src)
{
  my $m = XC::Grammar.parse($src, rule => 'expr', actions => XC::Actions.new(source => $src));
  $m ?? $m.made !! Nil
}

sub names(Expr $e)
{
  my @n;
  walk-expr($e, { @n.push(.name) if $_ ~~ Name });
  @n.join(' ')
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- trailers -------------------------------------------------------------------
check "o:x(1)[2]: an Index of a MethodCall on a Name",
{
  my $e = expr('o:x(1)[2]');
  $e ~~ Index && $e.base ~~ MethodCall && $e.base.name eq 'x'
    && $e.base.base ~~ Name && $e.base.args == 1 && $e.indices == 1
};
check "o:x:y(1):z: the whole chain, in order",
{
  my $e = expr('o:x:y(1):z');
  $e ~~ Member && $e.name eq 'z' && $e.base ~~ MethodCall && $e.base.name eq 'y'
    && $e.base.base ~~ Member && $e.base.base.name eq 'x'
};
check "a[1, 2] and a[1][2] are different things",
{
  my $x = expr('a[1, 2]');
  my $y = expr('a[1][2]');
  $x.indices == 2 && $x.base ~~ Name && $y.indices == 1 && $y.base ~~ Index
};
check "o:End() is a method, not the end of anything",
{
  my $e = expr('o:End()');
  $e ~~ MethodCall && $e.name eq 'End' && !$e.args
};
check "(a):x: the parenthesized primary is the base",
{
  my $e = expr('(a):x');
  $e ~~ Member && $e.base ~~ Name && $e.base.name eq 'a'
};

# ---- work areas -------------------------------------------------------------------
check "SA1->A1_NOME: the area is a name, not a variable",
{
  my $e = expr('SA1->A1_NOME');
  $e ~~ AliasField && $e.alias eq 'SA1' && !$e.base.defined && $e.field eq 'A1_NOME'
    && names($e) eq ''
};
check "(cAlias)->A1_NOME: the area comes from a variable, which is read",
{
  my $e = expr('(cAlias)->A1_NOME');
  $e ~~ AliasField && $e.base ~~ Name && names($e) eq 'cAlias'
};
check "SA1->( DbSeek(cChave) )",
{
  my $e = expr('SA1->( DbSeek(cChave) )');
  $e ~~ InAlias && $e.alias eq 'SA1' && $e.expr ~~ Call && names($e) eq 'cChave'
};
check "(cAlias)->( DbGoTop() )",
{
  my $e = expr('(cAlias)->( DbGoTop() )');
  $e ~~ InAlias && $e.base ~~ Name && $e.expr ~~ Call
};

# ---- arguments ------------------------------------------------------------------
check "f( , 1, , ): four positions, the empty ones as Omitted",
{
  my @a = expr('f( , 1, , )').args;
  @a == 4 && @a[0] ~~ Omitted && @a[1] ~~ Literal && @a[2] ~~ Omitted && @a[3] ~~ Omitted
};
check "f() has no argument, f(1) has one",
{
  expr('f()').args == 0 && expr('f(1)').args == 1
};
check "f(@aX, 1): passing by reference",
{
  my $a = expr('f(@aX, 1)').args[0];
  $a ~~ Ref && $a.target.name eq 'aX'
};
check "If(c, a, cA := u): an assignment as an argument",
{
  my $a = expr('If(c, a, cA := u)').args[2];
  $a ~~ AssignExpr && $a.target.name eq 'cA' && $a.value.name eq 'u'
};

# ---- blocks, macros, literals -----------------------------------------------------
check '{ |a, b| a + b, c }: parameters and two expressions',
{
  my $e = expr('{ |a, b| a + b, c }');
  $e ~~ CodeBlock && $e.params.join(',') eq 'a,b' && $e.body == 2 && $e.type eq 'Block'
};
check '{ || x := 1, y }: an assignment inside the block',
{
  my $e = expr('{ || x := 1, y }');
  !$e.params && $e.body[0] ~~ AssignExpr && names($e) eq 'x y'
};
check "&cVar reads cVar, &(cA + cB) reads both",
{
  my $x = expr('&cVar');
  my $y = expr('&(cA + cB)');
  $x ~~ Macro && names($x) eq 'cVar' && $y ~~ Macro && names($y) eq 'cA cB'
};
check '{1, n, 3}: an array with its items, and type Array',
{
  my $e = expr('{1, n, 3}');
  $e ~~ ArrayLit && $e.items == 3 && $e.type eq 'Array' && names($e) eq 'n'
};
check '{ "a": nX } and { 1 => nY }: pairs, with their values read',
{
  my $j = expr('{ "a": nX }');
  my $h = expr('{ 1 => nY }');
  $j ~~ JsonLit && $j.pairs == 1 && names($j) eq 'nX'
    && $h ~~ HashLit && names($h) eq 'nY'
};
check '{ "a": nX } is JSON, not an array holding member nX of "a"',
{
  my $e = expr('{ "a": nX, "b": 2 }');
  $e ~~ JsonLit && $e.type eq 'JSON' && $e.pairs[0].key ~~ Literal
};
check '{ : }, { => } and {}: the empty one of each kind',
{
  expr('{ : }') ~~ JsonLit && expr('{ => }') ~~ HashLit && expr('{}') ~~ ArrayLit
};

# ---- the reference file -------------------------------------------------------------
# Every name read or written in saldo.xtpl, through the statements' expressions.
# 'nX' used to appear only inside 'aTitulos[nX]:nSaldo', which was text.
check 'saldo.xtpl: every name appears in the tree, nX included',
{
  my $src = slurp('examples/saldo.xtpl');
  my $p = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src)).made;
  my %seen;
  walk($p.functions[0].body, -> $s
  {
    walk-expr($_, { %seen{.name} = True if $_ ~~ Name }) for exprs-of($s);
  });
  %seen.keys.sort.join(' ') eq 'aTitulos cCliente jResposta nLimite nTotal nX'
};

# ---- TL++ dotted path -------------------------------------------------------------
check 'totvs.tools.Alguma.Coisa(): the whole path is the name, no reads',
{
  my $e = expr('totvs.tools.Alguma.Coisa()');
  $e ~~ Call && $e.name eq 'totvs.tools.Alguma.Coisa' && names($e) eq ''
};
check 'with a trailer: :New() is a method on the qualified call',
{
  my $e = expr('totvs.tools.X():New()');
  $e ~~ MethodCall && $e.name eq 'New' && $e.base ~~ Call
    && $e.base.name eq 'totvs.tools.X'
};
check 'the arguments of a qualified call are read',
{
  names(expr('pacote.Classe():Novo(nA, cB)')) eq 'nA cB'
    || names(expr('pacote.Classe():Novo(nA, cB)')) eq 'cB nA'
};
check 'a.b() with two segments is already a path',
{
  my $e = expr('a.b()');
  $e ~~ Call && $e.name eq 'a.b'
};
# The other end of the ambiguity: not ending in a call, it is the operator.
check 'nA.And.nB is still the .and. operator, not a path',
{
  my $e = expr('nA.And.nB');
  $e ~~ Binary && names($e) eq 'nA nB'
};
check 'nA .and. foo(): the operator wins, with the call on one side',
{
  my $e = expr('nA .and. foo()');
  $e ~~ Binary && $e.right ~~ Call && $e.right.name eq 'foo'
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse =
  'a[]'       => 'empty index',
  'o:'        => 'member with no name',
  'a->'       => 'field with no name',
  '&'         => 'macro with nothing',
  'f(1 2)'    => 'arguments without a comma',
  'o:x('      => 'unclosed parenthesis',
  '{|a b| a}' => 'block parameters without a comma',
  '"a":x'     => 'member of a string',
  '1[2]'      => 'index of a number',
  'a.b'       => 'dotted path that does not end in a call',
  ;

for @refuse -> $c
{
  check "refuses: {$c.value} ({$c.key})", { !expr($c.key).defined };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
