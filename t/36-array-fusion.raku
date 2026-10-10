use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;

# Fusion over arrays. A chain is one call per stage, each walking its input
# and building a new array. As a statement's whole value, a chain over an
# array whose stages can be written into a loop becomes that loop instead --
# no array between the stages, a 'take' or a 'first' that stops it -- when at
# least two of its stages fuse, or, run for its effects, all of them: xtpl's
# rule. Anywhere else, and when its first stage cannot fuse, it stays calls.
#
# The terminals now fused -- over arrays and over rows()/lines() too: aprod,
# amax, amin, join, reduce, fold, maxby, minby, chunkby; the stages: scan,
# pairwise. xtpl's shapes and names, checked against its 34_stream_stages.

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# The body of a function, compiled, without the hoisted Locals.
sub body-of(Str $lines)
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, b, n, l, cS, bOk)\n$lines\nreturn n\n]);
  $out ?? $out.lines[3 .. *-2].grep({ !/^ \s* 'Local ' / }).join("\n") !! Nil
}

sub problems(Str $lines)
{
  my $src = "user function f(a, n)\n$lines\nreturn n\n";
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

# ---- what fuses, and what stays calls ----------------------------------------
lowers 'filter |> map |> sort: one loop, and the sort applies to what it built',
  "  n := a |> filter([x] x > 0) |> map([x] x * 2) |> sort",
  "  fo_0_0 := \{\}\n  For fi_0_0 := 1 To Len(a)\n    fv_0_0 := a[fi_0_0]\n    If fv_0_0 > 0\n      fv_0_0 := fv_0_0 * 2\n"
  ~ "      AAdd(fo_0_0, fv_0_0)\n    EndIf\n  Next\n  n := u_xtpl_sort(fo_0_0)";
lowers 'an array that is not a name is bound once',
  "  n := \{1, 2, 3\} |> map([x] x * 2) |> asum",
  "  fs_0_0 := \{1, 2, 3\}\n  fo_0_0 := 0\n  For fi_0_0 := 1 To Len(fs_0_0)\n    fv_0_0 := fs_0_0[fi_0_0]\n    fv_0_0 := fv_0_0 * 2\n    fo_0_0 := fo_0_0 + fv_0_0\n  Next\n  n := fo_0_0";
lowers 'run for its effects, every stage fused: the loop alone',
  "  a |> tap([x] conout(x))",
  "  For fi_0_0 := 1 To Len(a)\n    fv_0_0 := a[fi_0_0]\n    conout(fv_0_0)\n  Next";
lowers 'one stage with a block: a loop -- no Eval of the block per element',
  "  n := a |> map([x] x * 2)",
  "  fo_0_0 := \{\}\n  For fi_0_0 := 1 To Len(a)\n    fv_0_0 := a[fi_0_0]\n    fv_0_0 := fv_0_0 * 2\n    AAdd(fo_0_0, fv_0_0)\n  Next\n  n := fo_0_0";
lowers 'one terminal with a block, a function named as one: loops',
  "  n := a |> count([x] x > 1)\n  m := a |> filter(empty)",
  "  fo_0_0 := 0\n  For fi_0_0 := 1 To Len(a)\n    fv_0_0 := a[fi_0_0]\n    If fv_0_0 > 1\n      fo_0_0++\n    EndIf\n  Next\n  n := fo_0_0\n"
  ~ "  fo_0_1 := \{\}\n  For fi_0_1 := 1 To Len(a)\n    fv_0_1 := a[fi_0_1]\n    If empty(fv_0_1)\n      AAdd(fo_0_1, fv_0_1)\n    EndIf\n  Next\n  m := fo_0_1";
lowers 'one stage with no block: a call -- there is nothing to save',
  "  n := a |> asum\n  m := a |> take(3)",
  "  n := u_xtpl_asum(a)\n  m := u_xtpl_take(a, 3)";
lowers 'a first stage that cannot fuse: calls',
  "  n := a |> sort |> take(3)",
  "  n := u_xtpl_take(u_xtpl_sort(a), 3)";
lowers 'a block held in a variable cannot be written into a loop: calls',
  "  n := a |> filter(bOk) |> map([x] x * 2)",
  "  n := u_xtpl_map(u_xtpl_filter(a, bOk), \{|x| x * 2\})";
lowers 'inside an expression: calls',
  "  n := len(a |> filter([x] x > 0) |> map([x] x * 2))",
  "  n := len(u_xtpl_map(u_xtpl_filter(a, \{|x| x > 0\}), \{|x| x * 2\}))";
lowers 'run for its effects, a stage that cannot fuse: calls',
  "  a |> tap([x] conout(x)) |> sort",
  "  u_xtpl_sort(u_xtpl_tap(a, \{|x| conout(x)\}))";

# ---- where -------------------------------------------------------------------
lowers 'under a postfix if: the loop inside the If',
  "  n := a |> filter([x] x > 0) |> count if l",
  "  If l\n    fo_0_0 := 0\n    For fi_0_0 := 1 To Len(a)\n      fv_0_0 := a[fi_0_0]\n      If fv_0_0 > 0\n        fo_0_0++\n      EndIf\n    Next\n    n := fo_0_0\n  EndIf";
lowers 'in the prologue: declared there, the values after it, in order',
  "  local x := a |> filter([o] o > 1) |> count\n  local y := 5\n  n := x + y",
  "  local x\n  local y\n  fo_0_0 := 0\n  For fi_0_0 := 1 To Len(a)\n    fv_0_0 := a[fi_0_0]\n    If fv_0_0 > 1\n      fo_0_0++\n    EndIf\n  Next\n  x := fo_0_0\n  y := 5\n  n := x + y";

# ---- the terminals and stages now fused --------------------------------------
lowers 'aprod',
  "  n := a |> map([x] x * 2) |> aprod",
  "  fo_0_0 := 1\n  For fi_0_0 := 1 To Len(a)\n    fv_0_0 := a[fi_0_0]\n    fv_0_0 := fv_0_0 * 2\n    fo_0_0 := fo_0_0 * fv_0_0\n  Next\n  n := fo_0_0";
lowers 'amax: the first element, then Max',
  "  n := a |> map([x] x:nV) |> amax",
  "  fo_0_0 := Nil\n  For fi_0_0 := 1 To Len(a)\n    fv_0_0 := a[fi_0_0]\n    fv_0_0 := fv_0_0:nV\n    If fo_0_0 == Nil\n      fo_0_0 := fv_0_0\n    Else\n      fo_0_0 := Max(fo_0_0, fv_0_0)\n    EndIf\n  Next\n  n := fo_0_0";
# Not xtpl's shape: xtpl appends to a growing text in the loop, which is
# quadratic if '+=' copies the text. The elements are collected and the
# runtime joins them once, pairwise.
lowers 'join: the elements collected, and joined once after the loop',
  "  n := a |> map([x] x:cC) |> join(\", \")",
  "  fo_0_0 := \{\}\n  For fi_0_0 := 1 To Len(a)\n    fv_0_0 := a[fi_0_0]\n    fv_0_0 := fv_0_0:cC\n    AAdd(fo_0_0, fv_0_0)\n  Next\n  fo_0_0 := u_xtpl_join(fo_0_0, \", \")\n  n := fo_0_0";
check 'join: a separator in a variable bound once, before the loop; none, none',
{
  my $b = body-of("  n := a |> map([x] x:cC) |> join(cS)");
  $b.starts-with("  fsp_0_0 := cS\n") && $b.contains("  fo_0_0 := u_xtpl_join(fo_0_0, fsp_0_0)")
    && body-of("  n := a |> filter([x] x > 1) |> join").contains("  fo_0_0 := u_xtpl_join(fo_0_0)\n")
};
lowers 'reduce: the seed once, the step on the result so far and the element',
  "  n := a |> filter([x] x > 0) |> reduce([s, x] s + x * 2, 10)",
  "  fo_0_0 := 10\n  For fi_0_0 := 1 To Len(a)\n    fv_0_0 := a[fi_0_0]\n    If fv_0_0 > 0\n      fo_0_0 := fo_0_0 + fv_0_0 * 2\n    EndIf\n  Next\n  n := fo_0_0";
check 'fold: the first element is the start',
{
  body-of("  n := a |> map([x] x:nV) |> fold([s, x] s * x)").contains(
    "    If fo_0_0 == Nil\n      fo_0_0 := fv_0_0\n    Else\n      fo_0_0 := fo_0_0 * fv_0_0\n    EndIf")
};
lowers 'minby: the first element with the least key',
  "  n := a |> filter([x] x:lOk) |> minby([x] x:nV)",
  "  fbs_0_0 := Nil\n  fop_0_0 := .F.\n  fpb_0_0 := Nil\n  fo_0_0 := Nil\n  For fi_0_0 := 1 To Len(a)\n    fv_0_0 := a[fi_0_0]\n    If fv_0_0:lOk\n      fpb_0_0 := fv_0_0:nV\n      If !fop_0_0 .Or. fpb_0_0 < fbs_0_0\n        fop_0_0 := .T.\n        fbs_0_0 := fpb_0_0\n        fo_0_0 := fv_0_0\n      EndIf\n    EndIf\n  Next\n  n := fo_0_0";
check 'scan: the running value, and a take after it stops the loop',
{
  my $b = body-of("  n := a |> scan([s, x] s + x, 0) |> take(3)");
  $b.starts-with("  fa_0_0 := 0\n  fn_0_0 := 0\n  fo_0_0 := \{\}")
    && $b.contains("    fa_0_0 := fa_0_0 + fv_0_0\n    fv_0_0 := fa_0_0\n    If fn_0_0 >= 3\n      Exit")
};
check 'pairwise: the rest of the chain inside the If, from the second element',
{
  body-of("  n := a |> pairwise |> map([p] p[2] - p[1])").contains(
    "    fol_0_0 := fpv_0_0\n    frd_0_0 := fhd_0_0\n    fpv_0_0 := fv_0_0\n    fhd_0_0 := .T.\n    If frd_0_0\n"
    ~ "      fv_0_0 := \{fol_0_0, fv_0_0\}\n      fv_0_0 := fv_0_0[2] - fv_0_0[1]\n      AAdd(fo_0_0, fv_0_0)\n    EndIf")
};
check 'chunkby: a new chunk when the key changes, the last added after the loop',
{
  my $b = body-of("  n := a |> map([x] x:cP) |> chunkby([c] c)");
  $b.contains("    ElseIf !(fsn_0_0 == fky_0_0)\n      AAdd(fo_0_0, fch_0_0)")
    && $b.contains("  Next\n  If fop_0_0\n    AAdd(fo_0_0, fch_0_0)\n  EndIf\n  n := fo_0_0")
};
lowers 'a join with a separator held in a variable, alone: one stage, a call',
  "  n := a |> join(cS)",
  "  n := u_xtpl_join(a, cS)";

# ---- over the sources too ----------------------------------------------------
check 'rows() |> map |> amax: the table walked once, no array of it',
{
  my $b = body-of("  n := rows(\"SA1\") |> map([r] r:A1_SALDO) |> amax");
  $b.contains("fv_0_0 := SA1->A1_SALDO") && $b.contains("fo_0_0 := Max(fo_0_0, fv_0_0)") && !$b.contains('AAdd')
};
check "over rows(), maxby hands back the record: a map first, as for 'first'",
{
  problems("  n := rows(\"SA1\") |> maxby([r] r:A1_SALDO)")
    eqv ("over rows() nothing to collect before a 'map' makes the record a value",)
};

# ---- against xtpl ------------------------------------------------------------
# Normalised as in t/30-ranges-with-raw.raku: statements, lower case, hidden
# names by kind.
sub normalised(Str $text)
{
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
    # 'x := x + 1' is 'x++': xc writes the one, xtpl the other.
    $l .= subst(/^ (\w+) \s* ':=' \s* $0 \s* '+' \s* 1 $/, { "$0++" });
    $l .= subst(/^ (\w+) \s* ':=' \s* $0 \s* '-' \s* 1 $/, { "$0--" });
    @out.push($l.lc);
  }
  @out
}
check "34_stream_stages -- map, scan, pairwise, expand, fused over arrays: xtpl's statements",
{
  normalised(compile(slurp('xtpl/tests/34_stream_stages.xtpl')))
    eqv normalised(slurp('xtpl/tests/34_stream_stages.tlpp'))
};

check 'the output compiles to itself',
{
  my $once = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, n)\n  n := a |> filter([x] x > 0) |> scan([s, x] s + x, 0) |> amax\n  a |> pairwise |> tap([p] conout(p[1]))\nreturn n\n]);
  my $*GENERATED-OK = True;
  $once.defined && compile($once) eq $once
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
