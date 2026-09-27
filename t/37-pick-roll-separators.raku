use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;
use XC::Check;

# Digit separators in numbers -- '12'345'678', as C++14 has them with the
# same character -- and aPick, aRoll and setMaxRoll, which the runtime
# implements.

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# The first line of a function's body, compiled; Nil when it does not parse.
sub line-of(Str $line)
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, n, c)\n$line\nreturn n\n]);
  $out ?? $out.lines[3] !! Nil
}

sub clean(Str $line)
{
  my $src = "user function f(a, n, c)\n$line\nreturn n\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  my %c = check-all($m.made);
  !%c<errors> && !%c<warnings>
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- digit separators -------------------------------------------------------------------------
check "taken out: TL++ has none -- in the whole part and the decimals",
{
  line-of("  n := 12'345'678 + 1'234.567'8") eq "  n := 12345678 + 1234.5678"
};
check "wherever a number goes: an argument, an index, a take, a range",
{
  line-of("  n := iif(c == '1', 1'000, a[1'0])") eq "  n := iif(c == '1', 1000, a[10])"
    && compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, n)\n  n := 1..10'000 |> filter([x] x > 5'000) |> take(1'000) |> count\nreturn n\n])
         .contains("For fi_0_0 := 1 To 10000")
};
check "in a declaration of the prologue, kept in place",
{
  compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f()\n  local nMax := 50'000  // the limit\nreturn nMax\n])
    .contains("  local nMax := 50000  // the limit")
};
check "refused where it is not between two digits: at the end, doubled, by the point, before a space",
{
  !line-of("  n := 12'").defined && !line-of("  n := 1''000").defined && !line-of("  n := 1'.5").defined
    && !line-of("  n := 1.'5").defined && !line-of("  n := 12' 345").defined
};
check "strings are untouched, in either quotes",
{
  line-of("  c := '12' + '34'") eq "  c := '12' + '34'" && line-of(qq[  c := "3'4" + '5']) eq qq[  c := "3'4" + '5']
};
check "a separator is not a quote to the comment finder: the space before '+' stays, a comment with an apostrophe too",
{
  line-of("  c := cValToChar(1'000) + ' itens'") eq "  c := cValToChar(1000) + ' itens'"
    && line-of("  n := len(a) + 2'000 // it's the limit") eq "  n := len(a) + 2000 // it's the limit"
};
check "the checks see an ordinary number", { clean("  n := 1'000 * 2") };

# ---- aPick, aRoll, setMaxRoll ------------------------------------------------------------------
check "calls to the runtime, with or without a count",
{
  line-of("  a := aPick(a)") eq "  a := u_xtpl_apick(a)" && line-of("  a := aPick(a, 3)") eq "  a := u_xtpl_apick(a, 3)"
    && line-of("  a := aRoll(a, 10)") eq "  a := u_xtpl_aroll(a, 10)"
    && line-of("  n := setMaxRoll(5'000)") eq "  n := u_xtpl_setmaxroll(5000)"
};
check "stages of a chain, as every verb",
{
  line-of("  n := a |> aRoll(10) |> asum") eq "  n := u_xtpl_asum(u_xtpl_aroll(a, 10))"
    && line-of("  n := len(a |> aPick(3))") eq "  n := len(u_xtpl_apick(a, 3))"
};
check "no warning: they are not names to declare", { clean("  a := aPick(a, 2)\n  a := aRoll(a)\n  n := setMaxRoll(10)") };

my $rt = slurp('runtime/xtpl_runtime.tlpp');
sub body(Str $name) { ($rt ~~ / 'User Function ' $name '(' .*? \n 'Return' \N* /) // '' }
check "the runtime has the three, and the maximum as a static of 1000",
{
  body('xtpl_apick') && body('xtpl_aroll') && body('xtpl_setmaxroll') && $rt.contains('Static snMaxRoll := 1000')
};
check "Random, not Randomize: Randomize reaches only 32,767 values",
{
  body('xtpl_apick').contains('Random(nI, nLen)') && body('xtpl_aroll').contains('Random(1, nLen)')
    && !body('xtpl_apick').contains('Randomize(') && !body('xtpl_aroll').contains('Randomize(')
};
check "aPick and aRoll give what there is, as take does: at most Len (aPick), at most the maximum (aRoll)",
{
  body('xtpl_apick').contains('Min(nLen, Max(0, nCount))') && body('xtpl_aroll').contains('Min(snMaxRoll, Max(0, nCount))')
    && body('xtpl_aroll').contains('If(nLen == 0, 0,')
};
check "setMaxRoll gives back the maximum it replaced",
{
  body('xtpl_setmaxroll').contains('Local nWas := snMaxRoll') && body('xtpl_setmaxroll').contains('Return nWas')
};

check "the output compiles to itself",
{
  my $once = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, n)\n  n := a |> aPick(1'000) |> asum  // it's many\nreturn n + setMaxRoll(2'000)\n]);
  $once.defined && compile($once) eq $once
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
