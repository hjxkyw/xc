use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# xtpl's '|>': the value on the left becomes the first argument of the stage on
# the right. Both directions: the shape that comes out, and what has to be
# refused -- above all a pipeline inside a lambda or code block, which xtpl
# refuses and which, if it merely ended the body, would change the program
# silently.

sub stmt(Str $lines)
{
  my $src = "user function f()\n$lines\nreturn\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? $m.made.functions[0].body[0] !! Nil
}

sub parses(Str $lines)
{
  XC::Grammar.parse("user function f()\n$lines\nreturn\n").defined
}

sub expr(Str $src)
{
  my $m = XC::Grammar.parse($src, rule => 'expr', actions => XC::Actions.new(source => $src));
  $m ?? $m.made !! Nil
}

sub stages(Pipeline $p) { $p.stages.map({ .name ~ '/' ~ .args.elems }).join(' ') }

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- the shape --------------------------------------------------------------------
check 'filter |> map: the source, and the stages without their first argument',
{
  my $p = stmt('  aC := aPedidos |> filter([o] o:nValor > 1000) |> map([o] o:cCodigo)').value;
  $p ~~ Pipeline && $p.source ~~ Name && $p.source.name eq 'aPedidos'
    && stages($p) eq 'filter/1 map/1' && $p.stages[0].args[0] ~~ Lambda
};
check 'a stage as a bare name: |> distinct |> asum',
{
  stages(expr('aNums |> distinct |> asum')) eq 'distinct/0 asum/0'
};
check 'without |> there is no Pipeline',
{
  expr('aNums') ~~ Name && expr('f(x)') ~~ Call
};
check 'a stage with arguments of its own: |> meuAuxiliar(3)',
{
  my $p = expr('aPedidos |> meuAuxiliar(3) |> ordenaLinhas');
  stages($p) eq 'meuAuxiliar/1 ordenaLinhas/0' && $p.stages[0].args[0] ~~ Literal
};
check 'a qualified stage: |> pkg.util.f(1)',
{
  expr('a |> pkg.util.f(1)').stages[0].name eq 'pkg.util.f'
};

# ---- where the pipeline sits ---------------------------------------------------------
check 'inside an argument: len(aNums |> distinct)',
{
  my $e = stmt('  nTotal := len(aNums |> distinct)').value;
  $e ~~ Call && $e.name eq 'len' && $e.args[0] ~~ Pipeline
};
check 'in an argument, without dragging the others in: f(a |> g, b)',
{
  my $e = expr('f(a |> g, b)');
  $e.args == 2 && $e.args[0] ~~ Pipeline && $e.args[1] ~~ Name
};
check "nested in a stage's argument: a |> take(len(b |> distinct))",
{
  my $p = expr('a |> take(len(b |> distinct))');
  $p ~~ Pipeline && $p.stages[0].args[0].args[0] ~~ Pipeline
};
check 'as a statement, for its effects: aPedidos |> valida() |> grava()',
{
  my $s = stmt('  aPedidos |> valida() |> grava()');
  $s ~~ CallStmt && $s.call ~~ Pipeline && stages($s.call) eq 'valida/0 grava/0'
};
check 'a statement starting with a call: f(x) |> g()',
{
  my $s = stmt('  f(x) |> g()');
  $s ~~ CallStmt && $s.call ~~ Pipeline && $s.call.source ~~ Call
};
check 'return of a pipeline',
{
  my $s = stmt('  return aNums |> asum');
  $s ~~ ReturnStmt && $s.value ~~ Pipeline
};
check 'with a modifier: nB := aNums |> asum if lFlag',
{
  my $s = stmt('  nB := aNums |> asum if lFlag');
  $s ~~ Modified && $s.stmt.value ~~ Pipeline && $s.cond.name eq 'lFlag'
};
check "over several lines, with ';'",
{
  my $p = stmt("  aX := aP ;\n    |> filter([o] o:lOk) ;\n    |> map([o] o:cCod)").value;
  $p ~~ Pipeline && stages($p) eq 'filter/1 map/1'
};

# ---- precedence ----------------------------------------------------------------
check '|> is the loosest: a + b |> f has the sum as its source',
{
  my $p = expr('a + b |> f');
  $p ~~ Pipeline && $p.source ~~ Binary && $p.source.op eq '+'
};
check 'looser than .or.: lA .or. lB |> f',
{
  my $p = expr('lA .or. lB |> f');
  $p ~~ Pipeline && $p.source ~~ Binary
};
check 'a literal as the source: {1, 2, 3} |> asum',
{
  expr('{1, 2, 3} |> asum').source ~~ ArrayLit
};

# ---- walking ---------------------------------------------------------------------
check 'names read: the source and the lambda bodies; a stage name is not a read',
{
  my @n;
  walk-expr(expr('aP |> filter([o] o:nV > nLim) |> asum'), { @n.push(.name) if $_ ~~ Name });
  @n.join(' ') eq 'aP o nLim'
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse =
  '  aOut := map(aNums, [x] x |> triplica)'    => 'a pipeline in the body of a lambda',
  '  aOut := map(aNums, {|x| x |> triplica})'  => 'a pipeline in a code block',
  '  aOut := map(aNums, [x] f(x |> g))'        => 'a pipeline nested inside a lambda',
  '  x := a |>'                                => 'no stage',
  '  |> f'                                     => 'no source',
  '  x := a |> 1'                              => 'a literal as a stage',
  '  x := a |> (f)'                            => 'a parenthesized stage',
  '  x := a |> o:m()'                          => 'a method as a stage',
  ;

for @refuse -> $c
{
  check "refuses: {$c.value}", { !parses($c.key) };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
