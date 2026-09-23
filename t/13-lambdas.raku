use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# xtpl's lambda: '[names] body', one to six names, a single body. The cases
# come from xtpl's tests and examples. Both directions: the shape that comes
# out, and what has to be refused.

sub expr(Str $src)
{
  my $m = XC::Grammar.parse($src, rule => 'expr', actions => XC::Actions.new(source => $src));
  $m ?? $m.made !! Nil
}

sub body(Str $lines)
{
  my $src = "user function f()\n$lines\nreturn\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? $m.made.functions[0].body !! Nil
}

sub lambdas(Expr $e)
{
  my @l;
  walk-expr($e, { @l.push($_) if $_ ~~ Lambda });
  @l
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

# ---- the shape --------------------------------------------------------------------
check 'map(aOrders, [o] o:nValue): the lambda is the second argument',
{
  my $e = expr('map(aOrders, [o] o:nValue)');
  my $l = $e.args[1];
  $e ~~ Call && $e.args == 2 && $l ~~ Lambda
    && $l.params.join eq 'o' && $l.body == 1 && $l.body[0] ~~ Member
};
check 'reduce(aNums, [acc, x] acc + x, 0): the seed stays out of the body',
{
  my $e = expr('reduce(aNums, [acc, x] acc + x, 0)');
  $e.args == 3 && $e.args[1] ~~ Lambda && $e.args[1].params.join(',') eq 'acc,x'
    && $e.args[1].body[0] ~~ Binary && $e.args[2] ~~ Literal
};
check 'tap([cLine] nRead += 1): an assignment as the body',
{
  my $l = expr('tap([cLinha] nLidas += 1)').args[0];
  $l.body[0] ~~ AssignExpr && $l.body[0].op eq '+='
};
check 'a lambda is a CodeBlock of type Block',
{
  my $l = expr('[o] o');
  $l ~~ CodeBlock && $l.type eq 'Block'
};
check 'six names',
{
  expr('[a, b, c, d, e, f] a + f').params == 6
};
check 'a body with an array literal',
{
  expr('map(a, [oCampo] {alltrim(oCampo:X3_CAMPO), 1})').args[1].body[0] ~~ ArrayLit
};
check 'a comma inside a string does not end the body',
{
  my $e = expr('map(a, [c] c + ", " + d)');
  $e.args == 2 && $e.args[1].body[0] ~~ Binary
};

# ---- nested ------------------------------------------------------------------
check 'a lambda inside a lambda',
{
  my @l = lambdas(expr('map(a, [x] filter(x, [y] y > 0))'));
  @l.map({ .params.join }).join(' ') eq 'x y'
};
check 'a verb called directly inside the lambda (what the doc recommends)',
{
  my $l = expr('map(aL, [a] asum(map(a, val)) / 3)').args[1];
  $l.body[0] ~~ Binary && $l.body[0].left ~~ Call
};
check 'names read in the body: the parameter and the outer ones',
{
  names(expr('filter(aP, [o] o:nValor > nLimite)')) eq 'aP o nLimite'
};

# ---- '[' as an index, and as a lambda -------------------------------------------
check 'a[i] is still an index',
{
  expr('a[i]') ~~ Index
};
check 'f(a[1], [o] o): an index in one argument, a lambda in the other',
{
  my $e = expr('f(a[1], [o] o)');
  $e.args[0] ~~ Index && $e.args[1] ~~ Lambda
};
check 'a lambda kept in a variable',
{
  my $s = body("  bVal := [o] o:nValor")[0];
  $s ~~ Assignment && $s.value ~~ Lambda
};
check "the head on one line, the body on the next, with ';'",
{
  my $s = body("  aZ := zip(aA, aB, [cA, cB] ;\n       cA + cB)")[0];
  my $l = $s.value.args[2];
  $l ~~ Lambda && $l.params.join(',') eq 'cA,cB' && $l.body[0] ~~ Binary
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse =
  'map(a, [] x)'                    => 'no name',
  'map(a, [a, b, c, d, e, f, g] a)' => 'seven names',
  'map(a, [x y] x)'                 => 'names without a comma',
  'map(a, [x])'                     => 'no body',
  'map(a, [1] x)'                   => 'a parameter that is not a name',
  'map(a, [o.x] o)'                 => 'a dotted parameter',
  'map(a, [o] local x)'             => 'a declaration as the body',
  ;

for @refuse -> $c
{
  check "refuses: {$c.value} ({$c.key})", { !expr($c.key).defined };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
