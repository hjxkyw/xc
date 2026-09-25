use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;

# More of what a chain from rows() or lines() fuses into its loop -- drop,
# dropwhile, expand, distinctAdjacent, in xtpl's shapes -- a bare function
# name standing for a block, and a chain as the value of a 'local'. These are
# what kept four of xtpl's tests and two of its examples from compiling.

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# The body of a function, compiled, without the hoisted Locals.
sub body-of(Str $lines)
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, n, cP)\n$lines\nreturn n\n]);
  $out ?? $out.lines[3 .. *-2].grep({ !/^ \s* 'Local ' / }).join("\n") !! Nil
}

sub problems(Str $lines)
{
  my $src = "user function f(a, n, cP)\n$lines\nreturn n\n";
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

# The loop's body: from the line after 'While' to the line before the advance.
sub loop-of(Str $body)
{
  my @l = $body.lines;
  my $w = @l.first(*.contains('While '), :k);
  my $e = @l.first(*.contains('EndDo'), :k);
  @l[$w + 1 .. $e - 2].map(*.substr(4)).join("\n")
}

# ---- the stages -----------------------------------------------------------------------------
check 'drop: the rest of the chain in the Else, the first n pass by',
{
  loop-of(body-of("  local x := \{\}\n  x := lines(cP) |> drop(2)")) eq q:to/END/.chomp
    fv_0_0 := FT_FReadLn()
    If fn_0_0 < 2
      fn_0_0 := fn_0_0 + 1
    Else
      AAdd(fo_0_0, fv_0_0)
    EndIf
    END
};
check 'dropwhile: a flag, so an element after the leading run always passes',
{
  my $b = body-of("  local x := \{\}\n  x := lines(cP) |> dropwhile([l] empty(l))");
  $b.contains("fdr_0_0 := .T.") && loop-of($b) eq q:to/END/.chomp
    fv_0_0 := FT_FReadLn()
    If !(fdr_0_0 .And. (empty(fv_0_0)))
      fdr_0_0 := .F.
      AAdd(fo_0_0, fv_0_0)
    EndIf
    END
};
check 'expand over rows(): a loop inside the loop, its elements values',
{
  loop-of(body-of("  local x := \{\}\n  x := rows(\"SC5\") |> expand([r] itens(r:C5_NUM)) |> map([i] i:cProduto)")) eq q:to/END/.chomp
    fbg_0_0 := itens(SC5->C5_NUM)
    For fj_0_0 := 1 To Len(fbg_0_0)
      fv_0_0 := fbg_0_0[fj_0_0]
      fv_0_0 := fv_0_0:cProduto
      AAdd(fo_0_0, fv_0_0)
    Next
    END
};
check 'distinctAdjacent over rows(), by a key',
{
  my $b = body-of("  local x := \{\}\n  x := rows(\"SC6\") |> distinctAdjacent([r] r:C6_NUM) |> map([r] r:C6_NUM)");
  $b.contains("fop_0_0 := .F.\n  fls_0_0 := Nil\n  fpb_0_0 := Nil") && loop-of($b) eq q:to/END/.chomp
    fpb_0_0 := SC6->C6_NUM
    If !(fop_0_0 .And. (fpb_0_0 == fls_0_0))
      fop_0_0 := .T.
      fls_0_0 := fpb_0_0
      fv_0_0 := SC6->C6_NUM
      AAdd(fo_0_0, fv_0_0)
    EndIf
    END
};
check 'distinctAdjacent over values needs no key',
{
  loop-of(body-of("  local x := \{\}\n  x := lines(cP) |> distinctAdjacent")).contains("fpb_0_0 := fv_0_0")
};
# An Exit inside the expand's inner loop would leave only that loop.
check 'after an expand, a stage that stops the walk applies to what was collected',
{
  my $b = body-of("  local x := \{\}\n  x := rows(\"SC5\") |> expand([r] itens(r:C5_NUM)) |> take(3)");
  !$b.contains('Exit') && $b.ends-with("x := u_xtpl_take(fo_0_0, 3)")
};

# ---- a function name for a block -------------------------------------------------------------
check 'map(alltrim) in a fused loop calls the function with the element',
{
  loop-of(body-of("  local x := \{\}\n  x := lines(cP) |> map(alltrim)")).contains("fv_0_0 := alltrim(fv_0_0)")
};
check 'map(alltrim) elsewhere is the block that calls it; a variable stays a variable',
{
  my $b = body-of("  local x := \{\}\n  local bOk := \{|v| .T.\}\n  x := a |> map(alltrim) |> filter(bOk)\n  x := map(a, upper)");
  $b.contains("x := u_xtpl_filter(u_xtpl_map(a, \{|__it| alltrim(__it)\}), bOk)")
    && $b.contains("x := u_xtpl_map(a, \{|__it| upper(__it)\})")
};

# ---- a chain as the value of a 'local' ------------------------------------------------------
check 'in the prologue: names kept, values after it, in the order written',
{
  body-of("  local nA := 1\n  local aT := lines(cP) |> count   // lines\n  local nB := aT + nA\n  static nS := 0\n  n := nB") eq q:to/END/.chomp
    local nA := 1
    local aT  // lines
    local nB
    static nS := 0
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
    aT := fo_0_0
    nB := aT + nA
    n := nB
  END
};
check 'a type stays on the declaration',
{
  body-of("  local aT := lines(cP) as A\n  n := len(aT)").starts-with("  local aT as A\n")
};
check 'in a block: the loop where the declaration was',
{
  my $b = body-of("  if n > 0\n    local aT := lines(cP) |> count\n    n := aT\n  endif");
  $b.contains("  if n > 0\n    fok_0_0 := File(cP)") && $b.contains("    aT := fo_0_0\n    n := aT\n  endif")
};
check 'the output compiles to itself',
{
  my $once = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(cP)\n  local aT := lines(cP) |> dropwhile([l] empty(l)) |> map(alltrim)\n  local n := len(aT)\nreturn n\n]);
  my $*GENERATED-OK = True;
  $once.defined && compile($once) eq $once
};

# ---- what is still refused ------------------------------------------------------------------
check "a chain as a 'private' value",
{
  problems("  private x := lines(cP) |> count").first(*.starts-with('a chain from lines() where it cannot run'))
};
check 'distinctAdjacent over rows() with no key: the record is not a value',
{
  problems("  local x := \{\}\n  x := rows(\"SC6\") |> distinctAdjacent |> map([r] r:C6_NUM)").first(*.contains('needs a key'))
};
check 'a function given the record over rows()',
{
  problems("  local x := \{\}\n  x := rows(\"SA1\") |> filter(isOk) |> map([r] r:A1_COD)").first(*.contains('can only name a field'))
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
