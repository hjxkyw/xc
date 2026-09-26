use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;

# A chain from rows() or lines() is a loop, so it goes where the loop can run
# first without changing what the program does. Two more such places:
#
# - the value of a 'private' or 'public', as of a 'local': declared where it
#   is, given its value after the loop ('static' cannot: its value is a
#   constant);
# - the condition of an 'if' -- or of a postfix 'if' -- when the condition
#   always reads it: the loop runs before the 'if', and the condition reads
#   its result. Behind '.and.', '.or.' or '?:', in a branch of iif or in a
#   lambda, the condition may not reach it, and running the loop first would
#   run it when the original does not: refused. A 'while' condition, read on
#   every round, and an 'elseif', read only when the 'if' fails, stay refused.

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

sub problems(Str $lines)
{
  my $src = "user function f(cP, l, n)\n$lines\nreturn n\n";
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

# The lines of a count over lines(cP), numbered $i, indented by $in.
sub count-loop(Int $i, Str $in = '  ')
{
  qq:to/END/.chomp.lines.map({ $in ~ $_ }).join("\n");
    fok_0_$i := File(cP)
    If fok_0_$i
      FT_FUse(cP)
      FT_FGoTop()
    EndIf
    fo_0_$i := 0
    While fok_0_$i .And. !FT_FEof()
      fv_0_$i := FT_FReadLn()
      fo_0_$i := fo_0_$i + 1
      FT_FSkip()
    EndDo
    If fok_0_$i
      FT_FUse()
    EndIf
    END
}

# ---- private and public -----------------------------------------------------------------
check "a private's value at the top: declared there, given after the loop",
{
  body-of("  private pT := lines(cP) |> count   // how many\n  n := pT")
    eq "  private pT  // how many\n{count-loop(0)}\n  pT := fo_0_0\n  n := pT"
};
check "a public's too",
{
  body-of("  public pU := lines(cP) |> count\n  n := pU").starts-with("  public pU\n")
};
check "a private in a block: declared where it is, its value after the loop",
{
  body-of("  if n > 0\n    private pB := lines(cP) |> count\n    n := pB\n  endif")
    eq "  if n > 0\n    private pB\n{count-loop(0, '    ')}\n    pB := fo_0_0\n    n := pB\n  endif"
};

# ---- if --------------------------------------------------------------------------------------
check "an if: the loop first, the condition on its result, the comment on the If",
{
  body-of("  if (lines(cP) |> count) > 10   // many\n    n := 1\n  endif")
    eq "{count-loop(0)}\n  If fo_0_0 > 10  // many\n    n := 1\n  endif"
};
check "an elseif after it is left as it is",
{
  body-of("  if (lines(cP) |> count) > 10\n    n := 1\n  elseif n > 0\n    n := 2\n  endif").ends-with(
    "  If fo_0_0 > 10\n    n := 1\n  elseif n > 0\n    n := 2\n  endif")
};
check "two chains in one condition: both loops, in order",
{
  my $b = body-of("  if (lines(cP) |> count) > (lines(cP) |> count)\n    n := 1\n  endif");
  $b.contains("fo_0_0 := 0") && $b.contains("fo_0_1 := 0") && $b.contains("If fo_0_0 > fo_0_1")
    && $b.index("fo_0_0 := 0") < $b.index("fo_0_1 := 0")
};
check "a chain inside a call in the condition, and a bare source",
{
  my $b = body-of("  if len(lines(cP)) > 0\n    n := 1\n  endif");
  $b.contains("AAdd(fo_0_0, fv_0_0)") && $b.contains("If len(fo_0_0) > 0")
};
check "if local: the binding, then the loop, which may read it, then the If",
{
  my $b = body-of("  if local nL := n + 1, (rows(\"SA1\") |> count) > nL\n    n := nL\n  endif");
  $b.starts-with("  nL := n + 1\n  far_0_0 := Alias()") && $b.contains("If fo_0_0 > nL\n    n := nL\n  endif")
};
check "a postfix if: the loop, then the If",
{
  body-of("  n := 1 if (lines(cP) |> count) > 10   // many")
    eq "{count-loop(0)}\n  If fo_0_0 > 10  // many\n    n := 1\n  EndIf"
};

# ---- refused -------------------------------------------------------------------------------
my $maybe = "a chain from lines() that the condition may not reach (behind '.and.', '.or.' or '?:', "
          ~ "in iif or a lambda), whose loop would run all the same,";
check "refuses: behind .and., after ?:, in a branch of iif, in a code block",
{
  problems("  if l .and. (lines(cP) |> count) > 0\n  endif") eqv ($maybe,)
    && problems("  if (l ?: (lines(cP) |> count)) > 0\n  endif") eqv ($maybe,)
    && problems("  n := 1 if iif(l, 0, lines(cP) |> count) > 0") eqv ($maybe,)
    && problems("  if Eval(\{|| len(lines(cP))\}) > 0\n  endif") eqv ($maybe,)
};
check "the first operand of .and. is always read: allowed",
{
  body-of("  if (lines(cP) |> count) > 0 .and. l\n    n := 1\n  endif").contains("If fo_0_0 > 0 .and. l")
};
check "refuses: a while condition, an elseif, a static's value",
{
  my $where = "a chain from lines() where it cannot run as a loop first (it goes in 'x := ...', 'return ...' or a statement of its own)";
  problems("  while (lines(cP) |> count) > n\n    n := n + 1\n  enddo") eqv ($where,)
    && problems("  if l\n  elseif (lines(cP) |> count) > 0\n  endif") eqv ($where,)
    && problems("  static sX := lines(cP) |> count") eqv ($where,)
};

check "the output compiles to itself",
{
  my $once = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(cP, n)\n  private pT := lines(cP) |> count\n  if (lines(cP) |> count) > pT\n    n := 1\n  endif\nreturn n\n]);
  my $*GENERATED-OK = True;
  $once.defined && compile($once) eq $once
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
