use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;

# Block locals share slots. A block local lives only while its block runs, so
# two whose blocks are never one inside the other can share a Local; each
# takes the lowest slot no enclosing block's local holds -- the fewest Locals
# there can be. Not one that can still be reached after its block: captured
# by a code block, passed by reference, read by a defer, named in raw text --
# 'pinned', a Local of its own. A slot one name uses goes by that name.

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# A function around $lines, compiled: the lines between its header and its
# return, the Locals among them.
sub out-of(Str $lines, Str $params = 'a, aH, aC')
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f($params)\n$lines\nreturn a\n]);
  $out ?? $out.lines[3 .. *-2].join("\n") !! Nil
}

# The Locals of an output, as 'name: comment'.
sub locals(Str $out --> List)
{
  $out.lines.grep(/^ \s* 'Local ' /).map({ .trim.substr(6) }).List
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- sharing ------------------------------------------------------------------
check 'sibling blocks share one slot; its Local says who; each value says what it was',
{
  my $o = out-of("  if a > 0\n    local nFirst := 1\n    conout(nFirst)\n  endif\n  if a > 1\n    local cSecond := \"x\"\n    conout(cSecond)\n  endif");
  locals($o) eqv ("s_0_0  // a slot: the block locals 'nFirst', 'cSecond'",)
    && $o.contains("    s_0_0 := 1  // nFirst\n    conout(s_0_0)") && $o.contains("    s_0_0 := \"x\"  // cSecond\n    conout(s_0_0)")
};
check 'a nested block does not share with its enclosing one -- alone in its slot, it keeps its name',
{
  my $o = out-of("  if a > 0\n    local nA := 1\n    if a > 1\n      local nB := 2\n      conout(nA + nB)\n    endif\n  endif\n  if a > 2\n    local nC := 3\n    conout(nC)\n  endif");
  locals($o) eqv ("s_0_0  // a slot: the block locals 'nA', 'nC'", "nB  // a block local")
};
check 'the fewest slots: as many as the most block locals alive at once, whatever the depth',
{
  my $o = out-of("  if a > 0\n    local n1 := 1\n    conout(n1)\n  endif\n  if a > 1\n    local c2 := \"x\"\n    if a > 2\n      local n3 := 2\n      conout(c2 + str(n3))\n    endif\n  endif\n  for local i := 1 to 3\n    local nSq := i * i\n    conout(nSq)\n  next");
  locals($o) eqv ("s_0_0  // a slot: the block locals 'n1', 'c2', 'i'", "s_0_1  // a slot: the block locals 'n3', 'nSq'")
};
check "loops share too: a while's block local, then a for's counter -- and the for's own local, nested, apart",
{
  my $o = out-of("  while a > 0\n    local nW := a\n    a := a - nW\n  enddo\n  for local i := 1 to 2\n    local nF := i\n    conout(nF)\n  next");
  locals($o) eqv ("s_0_0  // a slot: the block locals 'nW', 'i'", "nF  // a block local")
};
check 'a slot taken again starts fresh: a local with no value is set to Nil',
{
  out-of("  if a > 0\n    local nA := 1\n    conout(nA)\n  endif\n  if a > 1\n    local nB\n    conout(nB)\n  endif").contains("    s_0_0 := Nil  // nB\n")
};

# ---- pinned: reachable after its block ----------------------------------------
check 'pinned: captured by a code block -- its own Local',
{
  my $o = out-of("  if a > 0\n    local nF := 10\n    aadd(aH, \{|| nF * 2\})\n  endif\n  if a > 1\n    local nG := 1\n    conout(nG)\n  endif");
  locals($o) eqv ("nF  // a block local", "nG  // a block local")
};
check 'pinned: passed by reference; read by a defer; named in raw text',
{
  my $r = out-of("  if a > 0\n    local nR := 1\n    f(\@nR)\n  endif\n  if a > 1\n    local nS := 1\n    conout(nS)\n  endif");
  my $d = out-of("  if a > 0\n    local nD := 1\n    defer conout(nD)\n  endif\n  if a > 1\n    local nS := 1\n    conout(nS)\n  endif");
  my $w = out-of("  if a > 0\n    local nW := 1\n    raw ANOTE nW\n  endif\n  if a > 1\n    local nS := 1\n    conout(nS)\n  endif");
  # The defer's: its flag first -- whether it was reached -- then the local.
  locals($r)[0] eq 'nR  // a block local' && locals($d).grep(!*.starts-with('fdf_'))[0] eq 'nD  // a block local'
    && locals($w)[0] eq 'nW  // a block local'
};
check 'not pinned: its value handed to a function, or stored -- the slot gets a new value next time',
{
  my $o = out-of("  if a > 0\n    local aR := \{\}\n    processRows(aR)\n  endif\n  if a > 1\n    local aI := \{\}\n    aadd(aC, aI)\n  endif");
  locals($o) eqv ("s_0_0  // a slot: the block locals 'aR', 'aI'",)
};
check 'not pinned: a lambda parameter of the same name is the parameter',
{
  my $o = out-of("  if a > 0\n    local x := 1\n    aeval(aC, [x] conout(x))\n    conout(x)\n  endif\n  if a > 1\n    local y := 2\n    conout(y)\n  endif");
  locals($o)[0] eq "s_0_0  // a slot: the block locals 'x', 'y'"
};
check 'two pinned of one name in sibling blocks: a Local each -- one would hand a code block the other value',
{
  my $o = out-of("  if a > 0\n    local x := 1\n    aadd(aH, \{|| x\})\n  endif\n  if a > 1\n    local x := 2\n    aadd(aH, \{|| x\})\n  endif");
  locals($o) eqv ("b_1_x  // the block local 'x'", "b_2_x  // the block local 'x'")
    && $o.contains("aadd(aH, \{|| b_1_x\})") && $o.contains("aadd(aH, \{|| b_2_x\})")
};

check 'pinning is per declaration: one aTmp captured, another of the name in a slot',
{
  my $o = out-of("  if a > 0\n    local aTmp := \{\}\n    aadd(aH, \{|| aTmp\})\n  endif\n  if a > 1\n    local aTmp := \{\}\n    conout(len(aTmp))\n  endif\n  if a > 2\n    local aOther := \{\}\n    conout(len(aOther))\n  endif");
  locals($o) eqv ("b_1_aTmp  // the block local 'aTmp'", "s_0_0  // a slot: the block locals 'aTmp', 'aOther'")
};

# ---- names ----------------------------------------------------------------------
check 'one name in sibling blocks: one slot, which goes by the name',
{
  locals(out-of("  if a > 0\n    local x := 1\n    conout(x)\n  endif\n  if a > 1\n    local x := 2\n    conout(x)\n  endif"))
    eqv ("x  // a block local",)
};
check "the function's own name: the block local goes by s_<slot>_<name>",
{
  my $o = out-of("  local x := 0\n  if a > 0\n    local x := 1\n    conout(x)\n  endif\n  conout(x)");
  locals($o) eqv ("s_0_x  // the block local 'x'",) && $o.contains("    s_0_x := 1  // x\n    conout(s_0_x)\n  endif\n  conout(x)")
};

check 'the output compiles to itself',
{
  my $once = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, aH)\n  if a > 0\n    local nA := 1\n    aadd(aH, \{|| nA\})\n  endif\n  if a > 1\n    local nB := 2\n    if a > 2\n      local nC := 3\n      conout(nB + nC)\n    endif\n  endif\n  if a > 3\n    local nD\n    conout(nD)\n  endif\nreturn a\n]);
  my $*GENERATED-OK = True;
  $once.defined && compile($once) eq $once
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
