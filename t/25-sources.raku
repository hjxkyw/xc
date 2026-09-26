use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;

# rows() and lines(): a chain from one becomes a single loop over the work area
# or the file, with the stages inside it; 'for x in lines()' walks the file.
# Checked against xtpl's own output for its three source tests, and case by
# case. Both directions: what comes out, and what has to be refused.

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# The body of a function, compiled, without the hoisted Locals: the statement
# lines after the header, up to the last line.
sub body-of(Str $lines)
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, n, cP, cK)\n  local x := 0\n$lines\nreturn x\n]);
  $out ?? $out.lines[4 .. *-2].grep({ !/^ \s* 'Local ' / }).join("\n") !! Nil
}

sub problems(Str $lines)
{
  my $src = "user function f(a, n, cP)\n  local x := 0\n$lines\nreturn x\n";
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
# The statements, compared line by line, lower case, without comments, blank
# lines and Local lines. xtpl reuses one set of hidden locals across loops
# (fo_0_0 again and again) where xc numbers them, so a hidden name is compared
# by its kind ('fo'); xtpl names its block-local slots after the variable
# (s_1_cLinha), and those are compared as the variable. %rename maps the
# hidden locals xtpl names after what they hold.
sub normalised(Str $text, %rename)
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
    $l .= subst(/ << 's_1_' (<[A..Za..z]> \w*) >> /, { ~$0 }, :g);
    $l .= subst(/ << (\w+) >> /, { %rename{~$0} // ~$0 }, :g);
    @out.push($l.lc);
  }
  # xtpl puts a stage that does not fuse into a temporary and then assigns
  # it; xc assigns the call. 'pt := X' then 'Y := pt' is 'Y := X'.
  my @joined;
  for @out -> $l
  {
    if @joined && @joined[*-1] ~~ /^ 'pt_0_0 := ' (.*) $/ && $l ~~ /^ (.*) ' := pt_0_0' $/
    {
      @joined[*-1] = "{$0} := {(@joined[*-1] ~~ /^ 'pt_0_0 := ' (.*) $/)[0]}";
    }
    else
    {
      @joined.push($l);
    }
  }
  @joined
}

for '43_rows' => {}, '44_lines' => {}, '45_foreach_lines' => { each => 'fs', opened => 'fok' } -> $t
{
  check "{$t.key}: the same statements as xtpl's output",
  {
    my $src = slurp("t/xtpl/tests/{$t.key}.xtpl");
    normalised(compile($src), $t.value) eqv normalised(slurp("t/xtpl/tests/{$t.key}.tlpp"), $t.value)
  };
}

# ---- rows() ------------------------------------------------------------------------------
lowers 'a literal alias written out; the area and record put back',
  "  x := rows(\"SA1\") |> map([r] r:A1_COD)",
  q:to/END/.chomp;
    far_0_0 := Alias()
    DbSelectArea("SA1")
    frc_0_0 := SA1->(RecNo())
    SA1->(DbGoTop())
    fo_0_0 := {}
    While !SA1->(Eof())
      fv_0_0 := SA1->A1_COD
      AAdd(fo_0_0, fv_0_0)
      SA1->(DbSkip())
    EndDo
    SA1->(DbGoto(frc_0_0))
    If !Empty(far_0_0)
      DbSelectArea(far_0_0)
    EndIf
    x := fo_0_0
  END

check 'an alias in a variable is bound once and reached as (alias)->',
{
  my $b = body-of("  x := rows(cP) |> map([r] r:A1_COD)");
  $b.contains("fal_0_0 := cP") && $b.contains("DbSelectArea(fal_0_0)")
    && $b.contains("fv_0_0 := (fal_0_0)->A1_COD") && $b.contains("While !(fal_0_0)->(Eof())")
};
check 'a key seeks instead of starting at the top, and takewhile stops the walk',
{
  my $b = body-of("  x := rows(\"SC6\", cK) |> takewhile([r] r:C6_NUM == n) |> map([r] r:C6_PROD)");
  $b.contains("SC6->(DbSeek(cK))") && !$b.contains('DbGoTop')
    && $b.contains("If !(SC6->C6_NUM == n)\n      Exit\n    EndIf\n    fv_0_0 := SC6->C6_PROD")
};
check 'count needs no value: a record is enough',
{
  my $b = body-of("  x := rows(\"SA1\") |> filter([r] r:A1_SALDO > 0) |> count");
  $b.contains("fo_0_0 := 0") && $b.contains("If SA1->A1_SALDO > 0\n      fo_0_0 := fo_0_0 + 1\n    EndIf")
};
check 'anyof stops at the first match',
{
  my $b = body-of("  x := rows(\"SA1\") |> anyof([r] r:A1_BLOQ == \"1\")");
  $b.contains("fo_0_0 := .F.") && $b.contains("If SA1->A1_BLOQ == \"1\"\n      fo_0_0 := .T.\n      Exit\n    EndIf")
};

# ---- lines() ------------------------------------------------------------------------------
lowers 'filter, map and a literal take: one pass that stops after the tenth',
  "  x := lines(cP) |> filter([l] !empty(l)) |> map([l] alltrim(l)) |> take(10)",
  q:to/END/.chomp;
    fok_0_0 := File(cP)
    If fok_0_0
      FT_FUse(cP)
      FT_FGoTop()
    EndIf
    fn_0_0 := 0
    fo_0_0 := {}
    While fok_0_0 .And. !FT_FEof()
      fv_0_0 := FT_FReadLn()
      If !empty(fv_0_0)
        fv_0_0 := alltrim(fv_0_0)
        If fn_0_0 >= 10
          Exit
        EndIf
        fn_0_0 := fn_0_0 + 1
        AAdd(fo_0_0, fv_0_0)
      EndIf
      FT_FSkip()
    EndDo
    If fok_0_0
      FT_FUse()
    EndIf
    x := fo_0_0
  END

check 'a path that is not a variable is bound once',
{
  my $b = body-of("  x := lines(cP + \".txt\") |> count");
  $b.contains("fs_0_0 := cP + \".txt\"") && $b.contains("fok_0_0 := File(fs_0_0)")
};
check 'a take with a variable binds its limit',
{
  body-of("  x := lines(cP) |> take(n)").contains("flm_0_0 := n")
};
check 'no stages: every line',
{
  my $b = body-of("  x := lines(cP)");
  $b.contains("AAdd(fo_0_0, fv_0_0)") && $b.ends-with("x := fo_0_0")
};
check 'a stage that does not fuse applies to what was collected',
{
  body-of("  x := lines(cP) |> map([l] upper(l)) |> sort").ends-with("x := u_xtpl_sort(fo_0_0)")
};
check 'reject, allof, first with a condition',
{
  my $a = body-of("  x := lines(cP) |> reject([l] empty(l)) |> allof([l] len(l) > 3)");
  my $b = body-of("  x := lines(cP) |> first([l] l = \"#\")");
  $a.contains("If !(empty(fv_0_0))") && $a.contains("If !(len(fv_0_0) > 3)\n        fo_0_0 := .F.\n        Exit")
    && $b.contains("fo_0_0 := Nil") && $b.contains("If fv_0_0 = \"#\"\n      fo_0_0 := fv_0_0\n      Exit")
};
check 'return of a chain',
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(cP)\n  return lines(cP) |> count\n]);
  $out.lines[*-1] eq '  return fo_0_0'
};
check 'a chain on its own, for its effects: the loop and nothing collected',
{
  my $b = body-of("  lines(cP) |> tap([l] conout(l))");
  $b.contains("  conout(fv_0_0)") && !$b.contains('AAdd') && !$b.contains('fo_0_0')
};

# ---- for x in lines() -------------------------------------------------------------------
check "for over lines(): opened if it exists, advanced at the top, 'next' closes it",
{
  my $b = body-of("  for cL, nN in lines(cP)\n    loop if empty(cL)\n    x := x + nN\n  next cL");
  $b eq q:to/END/.chomp
    fs_0_0 := cP
    fok_0_0 := File(fs_0_0)
    If fok_0_0
      FT_FUse(fs_0_0)
      FT_FGoTop()
    EndIf
    nN := 0
    While fok_0_0 .And. !FT_FEof()
      nN := nN + 1
      cL := FT_FReadLn()
      FT_FSkip()
      If empty(cL)
        loop
      EndIf
      x := x + nN
    EndDo
    If fok_0_0
      FT_FUse()
    EndIf
  END
};
check 'every return inside closes the file first, also under a modifier',
{
  my $b = body-of("  for cL in lines(cP)\n    if empty(cL)\n      return 0\n    endif\n    return 1 if cL = \"x\"\n  next");
  $b.contains("    if empty(cL)\n      If fok_0_0\n        FT_FUse()\n      EndIf\n      return 0\n    endif")
    && $b.contains("    If cL = \"x\"\n      If fok_0_0\n        FT_FUse()\n      EndIf\n      return 1\n    EndIf")
};
check 'nested walks: a return closes the inner file, then the outer',
{
  body-of("  for cA in lines(cP)\n    for cB in lines(cA)\n      return 1\n    next\n  next").contains(
    "      If fok_0_1\n        FT_FUse()\n      EndIf\n      If fok_0_0\n        FT_FUse()\n      EndIf\n      return 1")
};
check 'a return after the walk does not close anything',
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(cP)\n  for cL in lines(cP)\n    conout(cL)\n  next\n  return 1\n]);
  $out.lines[*-1] eq '  return 1'
};

# ---- the output is plain TL++ --------------------------------------------------------------
check 'the output compiles to itself',
{
  my $once = compile(slurp('t/xtpl/tests/43_rows.xtpl'));
  my $*GENERATED-OK = True;
  compile($once) eq $once
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse =
  "  x := rows(\"SA1\") |> filter([r] isOk(r)) |> map([r] r:A1_COD)"
    => 'over rows() the element is the current record, so it can only name a field',
  "  x := rows(\"SA1\") |> filter([r] r:A1_SALDO > 0)"
    => "over rows() nothing to collect before a 'map' makes the record a value",
  "  x := rows(\"SA1\")"
    => "over rows() nothing to collect before a 'map' makes the record a value",
  "  local bOk := \{|l| .T.\}\n  x := lines(cP) |> filter(bOk)"
    => "'filter' over lines() without its lambda written in the stage",
  "  x := len(lines(cP))"
    => "'lines()' outside the head of a chain (it is a source)",
  "  if (lines(cP) |> count) > 0\n    x := 1\n  endif"
    => "a chain from lines() where it cannot run as a loop first (it goes in 'x := ...', 'return ...' or a statement of its own)",
  "  x := lines(cP) |> count if n > 0"
    => 'a chain from a source under a postfix modifier',
  "  x := rows(\"SA1\", cP, n) |> map([r] r:A1_COD)"
    => "'rows()' with no alias, or more than an alias and a key",
  ;

for @refuse -> $c
{
  check "refuses: {$c.value}", { problems($c.key).first($c.value).defined };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
