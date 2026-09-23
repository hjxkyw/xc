use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# xtpl's 'defer' and 'fallback'. The cases come from xtpl's tests and examples.
# Both directions: the shape that comes out, and what has to be refused -- above
# all 'fallback' outside the four places where xtpl accepts it.

sub body(Str $lines)
{
  my $src = "user function f()\n$lines\nreturn\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? $m.made.functions[0].body !! Nil
}

sub stmt(Str $line) { my $b = body("  $line"); $b ?? $b[0] !! Nil }

sub parses(Str $line)
{
  XC::Grammar.parse("user function f()\n  $line\nreturn\n").defined
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- fallback ---------------------------------------------------------------------
check 'in the value of an assignment: a Guard with the expression and the fallback',
{
  my $g = stmt('cResposta := chamaServico(cUrl, cChave) fallback ""').value;
  $g ~~ Guard && $g.expr ~~ Call && $g.expr.name eq 'chamaServico'
    && $g.fallback ~~ Literal
};
check 'it guards the whole pipeline: looser than |>',
{
  my $g = stmt('nSafe := aNums |> filter([x] x > 100) |> asum fallback 0').value;
  $g ~~ Guard && $g.expr ~~ Pipeline && $g.expr.stages == 2
};
check 'in parentheses it guards just a piece: (a fallback {}) |> ...',
{
  my $p = stmt('aList := (riskyCall(2) fallback {}) |> filter([x] x > 1)').value;
  $p ~~ Pipeline && $p.source ~~ Guard && $p.source.fallback ~~ ArrayLit
};
check 'in parentheses, with ?: after',
{
  my $e = stmt('aItens := (jDados["itens"] fallback nil) ?: {}').value;
  $e ~~ Binary && $e.op eq '?:' && $e.left ~~ Guard
};
check 'in the initializer of a declaration',
{
  stmt('local nH := riskyCall(1) fallback 0').declarators[0].init ~~ Guard
};
check 'in a return',
{
  my $r = stmt('return f() fallback 0');
  $r ~~ ReturnStmt && $r.value ~~ Guard
};
check 'a negative fallback: nTmp := aNums[99] fallback -1',
{
  my $g = stmt('nTmp := aNums[99] fallback -1').value;
  $g.expr ~~ Index && $g.fallback ~~ Binary && $g.fallback.op eq 'neg'
};
check 'with a modifier: the guard stays inside the statement',
{
  my $s = stmt('nS := riskyCall(1) fallback 0 if lX');
  $s ~~ Modified && $s.stmt.value ~~ Guard
};
check 'without fallback there is no Guard',
{
  stmt('x := f()').value ~~ Call
};
check 'fallbackX is a name',
{
  stmt('x := fallbackX').value.name eq 'fallbackX'
};
check 'names read: both sides',
{
  my @n;
  walk-expr(stmt('x := f(nA) fallback nB').value, { @n.push(.name) if $_ ~~ Name });
  @n.join(' ') eq 'nA nB'
};

# ---- defer ------------------------------------------------------------------------
check 'defer closeCursor(): a Deferred holding the call',
{
  my $d = stmt('defer closeCursor()');
  $d ~~ Deferred && $d.stmt ~~ CallStmt && $d.stmt.call.name eq 'closeCursor'
};
check 'defer of a method and of an alias',
{
  stmt('defer oLog:Close()').stmt.call ~~ MethodCall
    && stmt('defer ZAPUR->(DbCloseArea())').stmt.call ~~ InAlias
};
check 'defer of an assignment',
{
  my $d = stmt('defer nTotal := nTotal + 1');
  $d.stmt ~~ Assignment && $d.stmt.target.name eq 'nTotal'
};
check 'defer of a pipeline',
{
  my $d = stmt('defer aRows |> validate() |> flush()');
  $d.stmt ~~ CallStmt && $d.stmt.call ~~ Pipeline
};
check 'defer inside a block',
{
  my @s = body("  if nX > 0\n    local nA := 5\n    defer logIt(nA)\n  endif");
  @s[0].branches[0].body[1] ~~ Deferred
};
check 'a name read only by the defer shows up in the walk',
{
  my @n;
  walk(body("  defer reportTotal(nCount)"), -> $s
  {
    walk-expr($_, { @n.push(.name) if $_ ~~ Name }) for exprs-of($s);
  });
  @n.join eq 'nCount'
};
check 'deferred := 1 is an ordinary assignment',
{
  stmt('deferred := 1') ~~ Assignment
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse =
  'f(a fallback 0)'                         => 'fallback in an argument',
  'x := a fallback b fallback c'            => 'two fallbacks',
  'x := map(a, [y] g(y) fallback 0)'        => 'fallback inside a lambda',
  'f() fallback g()'                        => 'fallback on a call statement',
  'x := a fallback'                         => 'fallback with no alternative',
  'defer'                                   => 'defer with no statement',
  'defer x'                                 => 'defer of a bare name',
  'defer f() if c'                          => 'defer with a modifier',
  'defer local x := 1'                      => 'defer of a declaration',
  'defer return 1'                          => 'defer of a return',
  ;

for @refuse -> $c
{
  check "refuses: {$c.value} ({$c.key})", { !parses($c.key) };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
