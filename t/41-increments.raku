use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;
use XC::Check;

# 'n++', '++n', 'n--', '--n': TL++'s increment and decrement, which xc reads
# in xtpl and writes in what it generates instead of 'n := n + 1'. Read, one
# is an assignment of one more or one less -- '+= 1', '-= 1' -- so what
# handles those handles it; the rest is copied as written.

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# The body of a function, compiled, without the hoisted Locals.
sub body-of(Str $lines)
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, o)\n  local n := 0\n  local x := 0\n  local h := \{=>\}\n$lines\nreturn n + x\n]);
  $out ?? $out.lines[6 .. *-2].grep({ !/^ \s* 'Local ' / }).join("\n") !! Nil
}

sub result(Str $lines)
{
  my $src = "user function f(a)\n$lines\nreturn a\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  my %c = check-all($m.made, source => $src);
  %(errors => %c<errors>.map(*.value).List, warnings => %c<warnings>.map(*.value).List)
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

# ---- read, and copied as written ---------------------------------------------
lowers 'statements: after and before, up and down',
  "  n++\n  ++n\n  n--\n  --n", "  n++\n  ++n\n  n--\n  --n";
lowers 'on an element, a member, a field',
  "  a[1]++\n  o:nX--\n  SA1->A1_SALDO++", "  a[1]++\n  o:nX--\n  SA1->A1_SALDO++";
lowers 'in an expression, and in an index',
  "  x := n++ + 1\n  x := a[++n]", "  x := n++ + 1\n  x := a[++n]";
lowers 'in a lambda: the code block takes it as it is',
  "  aeval(a, [e] n++)", "  aeval(a, \{|e| n++\})";
lowers "and 'n := n + 1' written so stays so: xc does not rewrite what is written",
  "  n := n + 1", "  n := n + 1";

# ---- a hash element: TL++ has no h{k}, so it is lowered ----------------------
lowers 'statements: a Set of the value, plus or minus one',
  "  h\{\"k\"\}++\n  --h\{\"k\"\}",
  "  h:Set(\"k\", u_xtpl_hget(h, \"k\") + (1))\n  h:Set(\"k\", u_xtpl_hget(h, \"k\") - (1))";
lowers "in an expression, '++h\{k\}' gives the value after",
  "  x := ++h\{\"k\"\}", "  x := u_xtpl_hset(h, \"k\", u_xtpl_hget(h, \"k\") + (1))";
lowers "and 'h\{k\}++' the value before: the one written, less one",
  "  x := h\{\"k\"\}++", "  x := (u_xtpl_hset(h, \"k\", u_xtpl_hget(h, \"k\") + (1))) - 1";
lowers "with a key that may be a method: hash and key once each, through a block",
  "  x := h\{o:cK\}--",
  "  x := (Eval(\{|__h, __k, __v| u_xtpl_hset(__h, __k, u_xtpl_hget(__h, __k) - __v)\}, h, o:cK, 1)) + 1";

# ---- the checks --------------------------------------------------------------
check "a <const> cannot be incremented; an external neither",
{
  result("  local nC <const> := 1\n  nC++\n  a := nC")<errors>[0].contains("'nC' is <const>")
    && result("  cEmp++")<warnings>.elems == 1
};
check "an increment reads what it changes: no 'never read'",
{
  !result("  local nK := 0\n  nK++")<warnings>
};

# ---- what xc writes ----------------------------------------------------------
check "its own counters: 'fo_0_0++', not 'fo_0_0 := fo_0_0 + 1'",
{
  my $b = body-of("  n := a |> filter([e] e > 1) |> take(2) |> count");
  $b.contains("      fn_0_0++\n      fo_0_0++") && !$b.contains(' + 1')
};

check 'the output compiles to itself',
{
  my $once = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a)\n  local n := 0\n  n++\n  n := a |> filter([e] e > n++) |> count\nreturn --n\n]);
  my $*GENERATED-OK = True;
  $once.defined && compile($once) eq $once
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
