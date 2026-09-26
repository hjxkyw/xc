use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;

# The last three of xtpl's constructs: a range 'lo..hi' (a counting loop at
# the head of a chain or in 'for ... in', a range test after 'in'), 'with
# object' (the subject bound once, ':x' its 'x') and 'raw' (text for the
# preprocessor, with its strings interpolated and its renamed locals renamed).
# Checked against xtpl's own output, and case by case.

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# The body of a function, compiled, without the hoisted Locals.
sub body-of(Str $lines)
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, n, o)\n  local x := 0\n$lines\nreturn n\n]);
  $out ?? $out.lines[4 .. *-2].grep({ !/^ \s* 'Local ' / }).join("\n") !! Nil
}

sub problems(Str $lines)
{
  my $src = "user function f(a, n, o)\n  local x := 0\n$lines\nreturn n\n";
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

# ---- against xtpl's own output --------------------------------------------------------
# As in t/25-sources.raku: statements, lower case; hidden names by kind; xtpl's
# slots as the variable, its subject slot as xc's hidden 'fbs'. xc also wraps
# '%%' whole -- '((fv % 3) == 0)', where xtpl writes '(fv % 3) == 0' -- since
# the node is rewritten in place and '!x %% 3' must stay right.
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
    $l .= subst(/ << 's_' \d+ '_obj' >> /, 'fbs', :g);
    $l .= subst(/ << <[sb]> '_' \d+ '_' (<[A..Za..z]> \w*) >> /, { ~$0 }, :g);
    $l .= subst(/ '((' (\w+ ' % ' \w+) ') == 0)' /, { "({$0}) == 0" }, :g);
    @out.push($l.lc);
  }
  @out
}

for <57_range_source 20_object 26_raw> -> $t
{
  check "$t: the same statements as xtpl's output",
  {
    normalised(compile(slurp("t/xtpl-output/$t.xtpl"))) eqv normalised(slurp("t/xtpl-output/$t.tlpp"))
  };
}

# ---- ranges ---------------------------------------------------------------------------------
lowers 'a range at the head of a chain counts; the element is a copy of the counter',
  "  n := 1..10 |> map([i] i * 2) |> asum",
  "  fo_0_0 := 0\n  For fi_0_0 := 1 To 10\n    fv_0_0 := fi_0_0\n    fv_0_0 := fv_0_0 * 2\n    fo_0_0 := fo_0_0 + fv_0_0\n  Next\n  n := fo_0_0";

check 'an end that is not a number or a name is bound before the loop',
{
  body-of("  n := x..calc(n) |> count").contains("fhi_0_0 := calc(n)\n  fo_0_0 := 0\n  For fi_0_0 := x To fhi_0_0")
};
check 'a take stops the count',
{
  body-of("  a := 1..1000000 |> filter([i] i %% 3) |> take(4)").contains("      If fn_0_0 >= 4\n        Exit")
};
lowers "'for x in lo..hi', with an index",
  "  for i, k in 5..n\n    x := x + i * k\n  next i",
  "  k := 0\n  For fi_0_0 := 5 To n\n    i := fi_0_0\n    k := k + 1\n    x := x + i * k\n  next";

lowers "'x in lo..hi': a range test",
  "  n := x in 1..100",
  "  n := (x >= 1 .And. x <= 100)";
lowers "'f() in lo..hi': the left side read once",
  "  n := calc(x) in 1..n",
  "  n := Eval(\{|__v| __v >= 1 .And. __v <= n\}, calc(x))";

check 'a range anywhere else does not parse',
{
  !compile("user function f()\n  local a := len(1..10)\nreturn a\n").defined
};

# ---- with object ------------------------------------------------------------------------
lowers "'with object': the subject once, ':x' its 'x', the 'end with' line gone",
  "  with object o:GetModel(\"M\")   // the model\n    :SetValue(\"A\", 1)\n    x := :GetValue(\"B\") + :nTam\n    :cNome := \"z\"\n  end with",
  "  fbs_0_0 := o:GetModel(\"M\")  // the model\n    fbs_0_0:SetValue(\"A\", 1)\n    x := fbs_0_0:GetValue(\"B\") + fbs_0_0:nTam\n    fbs_0_0:cNome := \"z\"";

lowers 'nested: the innermost subject; a subject read from the outer one',
  "  with object o\n    with object :oFilho\n      :Ativa()\n    end with\n    :Grava()\n  end with",
  "  fbs_0_0 := o\n    fbs_0_1 := fbs_0_0:oFilho\n      fbs_0_1:Ativa()\n    fbs_0_0:Grava()";

lowers "a comment after 'end with' stays",
  "  with object o\n    :Ativa()\n  end with   // done",
  "  fbs_0_0 := o\n    fbs_0_0:Ativa()\n  // done";

lowers "':x' followed by more, and inside other rewrites",
  "  with object o\n    x := :GetModel(\"M\"):GetValue(1)\n    n := 1 if :lOk\n  end with",
  "  fbs_0_0 := o\n    x := fbs_0_0:GetModel(\"M\"):GetValue(1)\n    If fbs_0_0:lOk\n      n := 1\n    EndIf";

# ---- raw -----------------------------------------------------------------------------------
lowers 'a raw line, as written',
  "  raw @ 10, 5 SAY \"Total\" GET x PICTURE \"@E 999\"",
  "  @ 10, 5 SAY \"Total\" GET x PICTURE \"@E 999\"";

lowers "a raw block: the lines as written; 'raw' and 'end raw' go, their comments stay",
  "  raw        // the dialog\n    @ 1, 1 SAY \"a\"\n    ACTIVATE DIALOG o\n  end raw",
  "  // the dialog\n    @ 1, 1 SAY \"a\"\n    ACTIVATE DIALOG o";

lowers 'a string holding ${...} is interpolated',
  "  raw MsgInfo(\"n = \$\{n\}\", \"x\")",
  "  MsgInfo((\"n = \" + cValToChar(n)), \"x\")";

check 'a renamed block local is renamed in raw text; a member or a function of that name is not',
{
  body-of("  if n > 0\n    local x := 1\n    raw ANOTE x + o:x + x(1) + A->x\n  endif").contains(
    "    ANOTE s_1_x + o:x + x(1) + A->x")
};
check "a comment in a raw line is left as it is",
{
  body-of("  raw ANOTE x   // \"\$\{x\}\"").ends-with("ANOTE x   // \"\$\{x\}\"")
};

# ---- the output ---------------------------------------------------------------------------
check 'the output compiles to itself (without raw: raw text is TL++ only after the preprocessor)',
{
  my $once = compile(slurp('t/xtpl-output/20_object.xtpl') ~ "\nuser function g()\n  return 1..5 |> asum\n");
  my $*GENERATED-OK = True;
  $once.defined && compile($once) eq $once
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
