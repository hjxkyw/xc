use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# xtpl's 'for x in ...' and 'for n times'. The forms come from xtpl's tests and
# examples, and the edge cases were run on xtpl itself ('--check'). Both
# directions: the shape that comes out, and what has to be refused.

sub body(Str $lines)
{
  my $src = "user function f(a, n)\n$lines\nreturn 1\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? $m.made.functions[0].body !! Nil
}

sub parses(Str $lines)
{
  XC::Grammar.parse("user function f(a, n)\n$lines\nreturn 1\n").defined
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- for x in ... -----------------------------------------------------------------
check 'for oItem in aItems: element, no index, source and body',
{
  my $f = body("  for oItem in aItems\n    nT := nT + oItem:nValue\n  next")[0];
  $f ~~ ForInStmt && $f.elem eq 'oItem' && !$f.index.defined
    && $f.source ~~ Name && $f.source.name eq 'aItems' && $f.body == 1
};
check 'for oItem, nPos in aItems: the index',
{
  my $f = body("  for oItem, nPos in aItems\n    conout(nPos)\n  next")[0];
  $f.elem eq 'oItem' && $f.index eq 'nPos'
};
check 'a call as the source: for cLine, nNum in lines(cPath)',
{
  my $f = body("  for cLinha, nNum in lines(cPath)\n    conout(cLinha)\n  next")[0];
  $f.source ~~ Call && $f.source.name eq 'lines'
};
check 'a pipeline as the source: for oIt in aRows |> distinct',
{
  my $f = body("  for oIt in aRows |> distinct\n    conout(oIt)\n  next")[0];
  $f.source ~~ Pipeline
};
check 'an array literal as the source: for nEach in {1, 2, 3}',
{
  body("  for nCada in \{1, 2, 3\}\n    conout(nCada)\n  next")[0].source ~~ ArrayLit
};
check 'keys(hCfg) as the source',
{
  body("  for cChave in keys(hCfg)\n    conout(cChave)\n  next")[0].source.name eq 'keys'
};
check 'next with the element name',
{
  body("  for x in a\n    conout(x)\n  next x")[0] ~~ ForInStmt
};
check 'the body opens a prologue: a local at its start',
{
  body("  for x in a\n    local nY := x\n    conout(nY)\n  next")[0].body[0] ~~ Declaration
};
check 'the classic for is still a ForStmt',
{
  body("  for i := 1 to 3\n    conout(i)\n  next")[0] ~~ ForStmt
};

# ---- for n times ---------------------------------------------------------------
check 'for 3 times: a literal count',
{
  my $f = body("  for 3 times\n    conout(1)\n  next")[0];
  $f ~~ ForTimesStmt && $f.count ~~ Literal && $f.count.text eq '3' && $f.body == 1
};
check 'for n times: a variable count',
{
  body("  for n times\n    conout(1)\n  next")[0].count ~~ Name
};
check 'for len(aItems) times: a call to a reserved-word function as the count',
{
  body("  for len(aItens) times\n    conout(1)\n  next")[0].count ~~ Call
};
check 'for hCfg{"n"} times: a hash read as the count',
{
  body("  for hCfg\{\"n\"\} times\n    conout(1)\n  next")[0].count ~~ HashIndex
};
check 'a trailing comment on the header',
{
  body("  for 3 times                // a loop header\n    conout(1)\n  next")[0] ~~ ForTimesStmt
};

# ---- walking ---------------------------------------------------------------------
# (the helper adds the 'return 1' that closes the function)
check 'walk goes into both bodies; exprs-of gives the source and the count',
{
  my @s = body("  for x in aSrc\n    conout(x)\n  next\n  for nCnt times\n    conout(2)\n  next");
  my @seen;
  walk(@s, { @seen.push(.^name.subst('XC::AST::', '')) });
  my @n;
  for @s -> $s { walk-expr($_, { @n.push(.name) if $_ ~~ Name }) for exprs-of($s) }
  @seen.join(' ') eq 'ForInStmt CallStmt ForTimesStmt CallStmt ReturnStmt' && @n.join(' ') eq 'aSrc nCnt'
};

# ---- what has to be refused -----------------------------------------------------------
# Each verdict is xtpl's, except 'enddo': xtpl takes it and would emit
# 'For ... EndDo', which is not AdvPL.
my @refuse =
  "  for local x in a\n    conout(x)\n  next"                 => 'for local x in a',
  "  for x, i, j in a\n    conout(x)\n  next"                 => 'three names',
  "  for x in\n    conout(x)\n  next"                         => 'for x in, with no source',
  "  for len in a\n    conout(1)\n  next"                     => 'a reserved word as the element',
  "  for x, len in a\n    conout(x)\n  next"                  => 'a reserved word as the index',
  "  for times\n    conout(1)\n  next"                        => 'for times, with no count',
  "  for x in a\n    conout(x)\n    local nY := 1\n  next"    => 'a local after a statement in the body',
  "  for x in a\n    conout(x)"                               => 'for-in never closed',
  "  for x in a\n    conout(x)\n  enddo"                      => "for-in closed by enddo",
  "  for 3 times\n    conout(1)\n  enddo"                     => "for-times closed by enddo",
  ;

for @refuse -> $c
{
  check "refuses: {$c.value}", { !parses($c.key) };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
