use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;

# 'defer' and 'using alias', and what runs on each way out: a 'return' runs
# the defers written before it, the last one first, then restores the work
# areas and closes the files, innermost first; an 'exit' or 'loop' restores
# and closes what it leaves. Checked against xtpl's own output, and case by
# case.

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# The body of a function, compiled, without the hoisted Locals.
sub body-of(Str $lines, Str $params = 'n, cA, cP')
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f($params)\n$lines\n]);
  $out ?? $out.lines[3 .. *].grep({ !/^ \s* 'Local ' / }).join("\n") !! Nil
}

sub problems(Str $lines)
{
  my $src = "user function f(n)\n$lines\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  my $out = try emit($m.made, $src);
  $out.defined ?? () !! $!.problems.map(*.value).List
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

sub lowers(Str $what, Str $in, Str $out) { check $what, { body-of($in) eq $out } }

# ---- against xtpl's own output -------------------------------------------------------
# As in t/25-sources.raku: statements only, lower case; hidden names by kind;
# xtpl's slots (s_1_x, s_2_x, and b_1_x for the ones a defer pins) as the
# variable; and the names xtpl gives a using's hidden locals mapped to xc's.
sub normalised(Str $text)
{
  my %rename = usearea => 'far', userec => 'frc', useord => 'fol', usealias => 'fal';
  my @out;
  my $started = False;
  for $text.lines -> $l is copy
  {
    $l .= trim;
    if $l ~~ m:i/^ 'user function' / { $started = True; next }
    next if !$started || !$l || $l.starts-with('//') || $l ~~ m:i/^ 'local ' /;
    $l .= subst(/ \s* '//' .* $ /, '');
    $l .= subst(/ << (f <[a..z]>+) '_0_' \d+ >> /, { ~$0 }, :g);
    $l .= subst(/ << <[sb]> '_' \d+ '_' (<[A..Za..z]> \w*) >> /, { ~$0 }, :g);
    $l .= subst(/ << (\w+) >> /, { %rename{~$0} // ~$0 }, :g);
    @out.push($l.lc);
  }
  @out
}

for <19_defer_pinning 21_using> -> $t
{
  check "$t: the same statements as xtpl's output",
  {
    normalised(compile(slurp("t/xtpl/tests/$t.xtpl"))) eqv normalised(slurp("t/xtpl/tests/$t.tlpp"))
  };
}

# ---- defer --------------------------------------------------------------------------------
lowers "before each 'return', the last one first; the 'defer' lines leave no trace",
  "  local nC := 0\n  defer closeIt()          // first\n  defer logIt(nC)          // second\n  nC := 99\n  return nC if n > 100\n  return 0",
  "  local nC := 0\n  nC := 99\n  If n > 100\n    logIt(nC)  // second\n    closeIt()  // first\n    return nC\n  EndIf\n  logIt(nC)  // second\n  closeIt()  // first\n  return 0";

lowers "only the defers written before a 'return' are pending at it",
  "  return 1 if n > 0\n  defer bye()\n  conout(n)\n  return 0",
  "  If n > 0\n    return 1\n  EndIf\n  conout(n)\n  bye()\n  return 0";

lowers "no 'return' at the end: the defers run after the last statement",
  "  defer bye()\n  conout(n)",
  "  conout(n)\n  bye()";

lowers "a body of declarations and defers only (xtpl's 18_defer_only)",
  "  local nCount := n\n  defer closeCursor()\n  defer logExit(nCount)",
  "  local nCount := n\n  logExit(nCount)\n  closeCursor()";

lowers 'a defer inside a block still runs at every exit: it is registered, not reached',
  "  if n > 0\n    defer bye()\n  endif\n  return n",
  "  if n > 0\n  endif\n  bye()\n  return n";

lowers 'a chain in a defer body is lowered where it is spliced',
  "  defer cA |> validate() |> flush()\n  return 1",
  "  flush(validate(cA))\n  return 1";

check 'a chain from lines() in a defer body is its loop, spliced',
{
  my $b = body-of("  defer lines(cP) |> tap([l] conout(l))\n  return 1");
  $b.contains("While fok_0_0 .And. !FT_FEof()") && $b.contains("conout(fv_0_0)") && $b.ends-with("EndIf\n  return 1")
};

# ---- using alias ----------------------------------------------------------------------------
lowers 'a literal alias with an order: saved, selected, put back',
  "  using alias SA1 order 1 do\n    n := SA1->A1_SALDO\n  end using   // done\n  return n",
  "  far_0_0 := Alias()\n  DbSelectArea(\"SA1\")\n  frc_0_0 := SA1->(RecNo())\n  fol_0_0 := SA1->(IndexOrd())\n  SA1->(DbSetOrder(1))\n    n := SA1->A1_SALDO\n  SA1->(DbSetOrder(fol_0_0))\n  SA1->(DbGoto(frc_0_0))\n  If !Empty(far_0_0)\n    DbSelectArea(far_0_0)\n  EndIf   // done\n  return n";

check 'a variable holding the alias is bound once, and reached as (alias)->',
{
  my $b = body-of("  using alias cA do\n    n := 1\n  end using\n  return n");
  $b.contains("fal_0_0 := cA") && $b.contains("DbSelectArea(fal_0_0)")
    && $b.contains("(fal_0_0)->(DbGoto(frc_0_0))") && !$b.contains('IndexOrd')
};
check "a 'return' inside: the defers first, then the area",
{
  body-of("  defer bye()\n  using alias SA1 do\n    return 1 if n > 0\n  end using\n  return 0").contains(
    "    If n > 0\n      bye()\n      SA1->(DbGoto(frc_0_0))\n      If !Empty(far_0_0)\n        DbSelectArea(far_0_0)\n      EndIf\n      return 1\n    EndIf")
};
check "nested: a 'return' puts back the inner area, then the outer",
{
  my $b = body-of("  using alias SA1 do\n    using alias SB1 do\n      return 1\n    end using\n  end using\n  return 0");
  $b.contains("      SB1->(DbGoto(frc_0_1))\n      If !Empty(far_0_1)\n        DbSelectArea(far_0_1)\n      EndIf\n      SA1->(DbGoto(frc_0_0))")
};
# xtpl lets an 'exit' or 'loop' leave the block without putting the area back.
check "an 'exit' out of the loop around the block puts the area back first (xtpl does not)",
{
  body-of("  while n > 0\n    using alias SA1 do\n      exit if n > 5\n      n := n - 1\n    end using\n  enddo\n  return n").contains(
    "      If n > 5\n        SA1->(DbGoto(frc_0_0))\n        If !Empty(far_0_0)\n          DbSelectArea(far_0_0)\n        EndIf\n        exit\n      EndIf")
};
check "a 'loop' likewise",
{
  body-of("  while n > 0\n    using alias SA1 do\n      n := n - 1\n      loop\n    end using\n  enddo\n  return n").contains(
    "      SA1->(DbGoto(frc_0_0))\n      If !Empty(far_0_0)\n        DbSelectArea(far_0_0)\n      EndIf\n      loop")
};
check "an 'exit' from a loop inside the block leaves the area alone",
{
  body-of("  using alias SA1 do\n    while n > 0\n      exit if n > 5\n      n := n - 1\n    enddo\n  end using\n  return n").contains(
    "      If n > 5\n        exit\n      EndIf")
};

# ---- files ---------------------------------------------------------------------------------
check "a 'return' inside a walk over lines(): the defers, then the file",
{
  body-of("  defer bye()\n  for cL in lines(cP)\n    return 1\n  next\n  return 0").contains(
    "    bye()\n    If fok_0_0\n      FT_FUse()\n    EndIf\n    return 1")
};
check "an 'exit' from the walk leaves the closing to the end of the loop",
{
  my $b = body-of("  for cL in lines(cP)\n    exit if empty(cL)\n  next\n  return 0");
  $b.contains("    If empty(cL)\n      exit\n    EndIf") && $b.contains("EndDo\n  If fok_0_0\n    FT_FUse()\n  EndIf")
};

# ---- what has to be refused ---------------------------------------------------------------
check 'a block local read by a defer, declared in more than one block',
{
  problems("  if n > 0\n    local nA := 5\n    defer logIt(nA)\n  endif\n  if n > 1\n    local nA := 6\n    conout(nA)\n  endif\n  return n")
    eqv ("block local 'nA', read by a defer and declared in more than one block,",)
};

# ---- the output is plain TL++ -----------------------------------------------------------
check 'the output compiles to itself',
{
  my $once = compile(slurp('t/xtpl/tests/21_using.xtpl'));
  my $*GENERATED-OK = True;
  compile($once) eq $once
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
