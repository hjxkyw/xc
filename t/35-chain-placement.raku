use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;
use XC::Check;

# Where a chain from rows(), lines() or 'lo..hi' goes. It is a loop, and runs
# before its statement; so it is only ever the whole value of 'x := ...', of a
# 'local', 'private' or 'public', of 'return', or a statement of its own -- or,
# the source alone, the source of a 'for'. A postfix modifier does not change
# that: the loop goes inside the If (or the While) it becomes. Anywhere else --
# a condition, an argument, a 'static' -- the loop would run at another time,
# or when the original does not run it at all: the checks refuse it, with the
# rule.

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# The body of a function, compiled, without the hoisted Locals.
sub body-of(Str $lines)
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(cP, l, n)\n$lines\nreturn n\n]);
  $out ?? $out.lines[3 .. *-2].grep({ !/^ \s* 'Local ' / }).join("\n") !! Nil
}

# The checks' errors, as messages.
sub refused(Str $lines)
{
  my $src = "user function f(cP, l, n)\n$lines\nreturn n\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  check-program($m.made).map(*.value).List
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# The lines of a count over lines(cP), indented by $in.
sub count-loop(Str $in = '  ')
{
  q:to/END/.chomp.lines.map({ $in ~ $_ }).join("\n");
    fok_0_0 := File(cP)
    If fok_0_0
      FT_FUse(cP)
      FT_FGoTop()
    EndIf
    fo_0_0 := 0
    While fok_0_0 .And. !FT_FEof()
      fv_0_0 := FT_FReadLn()
      fo_0_0 := fo_0_0 + 1
      FT_FSkip()
    EndDo
    If fok_0_0
      FT_FUse()
    EndIf
    END
}

# ---- private and public -----------------------------------------------------------------
check "a private's value at the top: declared there, given after the loop",
{
  body-of("  private pT := lines(cP) |> count   // how many\n  n := pT")
    eq "  private pT  // how many\n{count-loop}\n  pT := fo_0_0\n  n := pT"
};
check "a public's too",
{
  body-of("  public pU := lines(cP) |> count\n  n := pU").starts-with("  public pU\n")
};
check "a private in a block: declared where it is, its value after the loop",
{
  body-of("  if n > 0\n    private pB := lines(cP) |> count\n    n := pB\n  endif")
    eq "  if n > 0\n    private pB\n{count-loop('    ')}\n    pB := fo_0_0\n    n := pB\n  endif"
};

# ---- under a postfix modifier --------------------------------------------------------------
check "x := chain if c: the loop inside the If, so only when the condition holds",
{
  body-of("  n := lines(cP) |> count if l   // maybe")
    eq "  If l  // maybe\n{count-loop('    ')}\n    n := fo_0_0\n  EndIf"
};
check "return chain if c",
{
  body-of("  return lines(cP) |> count if l").ends-with("    return fo_0_0\n  EndIf")
};
check "a chain on its own under 'while': the loop inside, every round",
{
  body-of("  lines(cP) |> tap([x] conout(x)) while n > 0").starts-with("  While n > 0\n    fok_0_0 := File(cP)")
};

# ---- the rule --------------------------------------------------------------------------------
my $rule = "a chain from lines() runs as a loop, before its statement, so it is only the whole value "
         ~ "of 'x := ...', of a local, private or public, or of 'return', or a statement of its own. "
         ~ "Assign it to a variable first, where it should run.";
check "refused: in an if condition, a while condition, an elseif, behind .and.",
{
  refused("  if (lines(cP) |> count) > 10\n  endif") eqv ($rule,)
    && refused("  while (lines(cP) |> count) > n\n    n := n + 1\n  enddo") eqv ($rule,)
    && refused("  if l\n  elseif (lines(cP) |> count) > 0\n  endif") eqv ($rule,)
    && refused("  if l .and. (lines(cP) |> count) > 0\n  endif") eqv ($rule,)
};
check "refused: in an argument, in a sum, as a static's value, after '+='",
{
  refused("  conout(lines(cP) |> count)") eqv ($rule,)
    && refused("  n := 1 + (lines(cP) |> count)") eqv ($rule,)
    && refused("  static sX := lines(cP) |> count") eqv ($rule,)
    && refused("  n += lines(cP) |> count") eqv ($rule,)
};
check "a range says 'a range'",
{
  refused("  conout(1..10 |> count)")[0].starts-with('a chain from a range runs as a loop')
};
check "allowed: x :=, a local, return, alone, under a modifier -- and the sources of a for",
{
  !refused("  local a := lines(cP) |> count\n  n := lines(cP) |> count\n  lines(cP) |> tap([x] conout(x))\n"
           ~ "  n := 1..5 |> asum if l\n  for cL in lines(cP)\n  next\n  for i in 1..n\n  next\n  n := a\n  return lines(cP) |> count")
};

check "the output compiles to itself",
{
  my $once = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(cP, n)\n  private pT := lines(cP) |> count\n  n := lines(cP) |> count if pT > 0\nreturn n\n]);
  my $*GENERATED-OK = True;
  $once.defined && compile($once) eq $once
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
