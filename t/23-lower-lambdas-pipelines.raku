use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;

# Lowering lambdas, '|>' and the runtime verbs. The expected lines are what xtpl
# produces for the same code (it renames lambda parameters to slots; xc keeps
# them as written).

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

sub with-includes(Str $body) { qq[#include "totvs.ch"\n#include "tlpp-core.th"\n$body] }

# The one line of the body a statement becomes.
sub line-of(Str $stmt)
{
  my $out = compile(with-includes("user function f(a, b, o, aP)\n  local x := 0\n  $stmt\nreturn x\n"));
  $out ?? $out.lines[4] !! Nil
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

sub lowers(Str $what, Str $in, Str $out) { check $what, { line-of($in) eq "  $out" } }

# ---- lambdas and verbs ------------------------------------------------------------------
lowers 'a lambda becomes a code block, and map the runtime verb',
  'x := map(a, [o] o:nValue)',
  'x := u_xtpl_map(a, {|o| o:nValue})';
lowers 'two parameters, and the seed stays an argument',
  'x := reduce(a, [acc, n] acc + n, 0)',
  'x := u_xtpl_reduce(a, {|acc, n| acc + n}, 0)';
lowers 'an assignment as the body',
  'x := tap(a, [c] b += 1)',
  'x := u_xtpl_tap(a, {|c| b += 1})';
lowers 'a lambda inside a lambda',
  'x := map(a, [r] filter(r, [y] y > 0))',
  'x := u_xtpl_map(a, {|r| u_xtpl_filter(r, {|y| y > 0})})';
lowers 'a verb with no lambda: count, first, keys',
  'x := count(a) + len(keys(b))',
  'x := u_xtpl_count(a) + len(u_xtpl_keys(b))';
lowers 'a verb name in any case',
  'x := Distinct(a)',
  'x := u_xtpl_distinct(a)';
lowers 'a method named like a verb is left alone',
  'x := o:Count() + o:Map(1)',
  'x := o:Count() + o:Map(1)';
lowers 'a function that is not a verb is left alone',
  'x := len(a) + mapear(b)',
  'x := len(a) + mapear(b)';
lowers 'queue() is a runtime verb too',
  'x := queue(256)',
  'x := u_xtpl_queue(256)';

# ---- pipelines ----------------------------------------------------------------------
lowers 'filter |> map: nested calls, the value going first',
  'x := aP |> filter([p] p:nV > 1000) |> map([p] p:cC)',
  'x := u_xtpl_map(u_xtpl_filter(aP, {|p| p:nV > 1000}), {|p| p:cC})';
lowers 'a bare-name stage',
  'x := a |> distinct |> asum',
  'x := u_xtpl_asum(u_xtpl_distinct(a))';
lowers "a stage of one's own, with its own arguments: no prefix",
  'x := aP |> myHelper(3) |> sortRows',
  'x := sortRows(myHelper(aP, 3))';
lowers 'inside an argument, without touching the rest',
  'x := len(a |> distinct) + len(b)',
  'x := len(u_xtpl_distinct(a)) + len(b)';
lowers 'the whole sum as the source',
  'x := a + b |> reverse',
  'x := u_xtpl_reverse(a + b)';
lowers 'a pipeline as a statement',
  'aP |> tap([p] conout(p)) |> save()',
  'save(u_xtpl_tap(aP, {|p| conout(p)}))';
lowers 'a qualified stage',
  'x := a |> pkg.util.f(1)',
  'x := pkg.util.f(a, 1)';
lowers 'an omitted argument in a stage stays omitted',
  'x := a |> f(, 1)',
  'x := f(a, , 1)';

# ---- comments ---------------------------------------------------------------------------
lowers 'the line keeps its comment and spacing where the statement keeps its shape',
  'x := a |> asum          // the total',
  'x := u_xtpl_asum(a)          // the total';
lowers 'a comment inside a rewritten expression moves to the end of the line',
  'x := reduce(a, [s, n] s + /* the sum */ n, 0)',
  'x := u_xtpl_reduce(a, {|s, n| s +   n}, 0)  // the sum';
check "a pipeline over ';' continuations becomes one call, the comment kept",
{
  my $out = compile(with-includes("user function f(a)\n  local x := 0\n  x := a ;     // continued\n    |> distinct ;\n    |> asum\nreturn x\n"));
  $out.lines[4] eq '  x := u_xtpl_asum(u_xtpl_distinct(a))  // continued'
    && $out.lines[5] eq 'return x'
};

# ---- inside other rewrites --------------------------------------------------------------
# The parentheses were there for the '|>'; the call it becomes needs none.
check 'a pipeline in the condition of a postfix modifier',
{
  my $out = compile(with-includes("user function f(a)\n  local x := 0\n  x := 1 if (a |> asum) > 10\nreturn x\n"));
  $out.lines[4..6].join("\n") eq "  If u_xtpl_asum(a) > 10\n    x := 1\n  EndIf"
};
check 'a lambda in the value of a ?=',
{
  my $out = compile(with-includes("user function f(a)\n  local x\n  x ?= map(a, [o] o)\nreturn x\n"));
  $out.lines[4..6].join("\n") eq "  If x == Nil\n    x := u_xtpl_map(a, \{|o| o\})\n  EndIf"
};

# ---- chains from sources ------------------------------------------------------------------
# A chain from rows() or lines() runs as a loop before its statement, so it
# only goes where that is the same thing: t/25-sources.raku has the rest.
# A 'local' can take one (t/25-sources.raku); a 'private' cannot.
check "a chain from a source in a private's value is reported, with where it can go",
{
  my $src = "user function f()\n  private n := rows(\"SA1\") |> count\nreturn n\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  my $out = try emit($m.made, $src);
  !$out.defined && $!.problems[0].value.starts-with('a chain from rows() where it cannot run as a loop first')
};

# ---- the output is plain TL++ -------------------------------------------------------------
check 'the output compiles to itself',
{
  my $once = compile(with-includes("user function f(a)\n  local x := a |> filter([o] o > 1) |> asum  // n\n  aP |> tap([p] conout(p))\nreturn map(a, [o] o * 2)\n"));
  $once.defined && compile($once) eq $once
};

# ---- against xtpl's own output --------------------------------------------------------------
# The lines xtpl lowers the same way, from its test 29_array.
check "29_array's three lambda lines match xtpl's output, but for its slot names",
{
  my $src = q:to/END/;
  user function f(aOrders, aNums)
    local aVals := {}
    local aBig := {}
    local nTotal := 0
    aVals := map(aOrders, [o] o:nValue)
    aBig  := filter(aOrders, [o] o:nValue > 1000)
    nTotal := reduce(aNums, [acc, x] acc + x, 0)
  return nTotal
  END
  my @out = compile(with-includes($src)).lines;
  @out[6..8].join("\n") eq q:to/END/.chomp
    aVals := u_xtpl_map(aOrders, {|o| o:nValue})
    aBig  := u_xtpl_filter(aOrders, {|o| o:nValue > 1000})
    nTotal := u_xtpl_reduce(aNums, {|acc, x| acc + x}, 0)
  END
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
