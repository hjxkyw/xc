use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;

# A block local becomes a Local of the function, with its name as written. One
# with the name of a function variable, or of a block local of an enclosing
# block, would share that Local and clobber it -- so it gets a name of its own,
# s_<depth>_<name> (xtpl's slot shape), and every use in its scope follows.
# Outside the scope the name means what it meant before. The scopes: a
# block's prologue locals are seen by its body only; its header locals ('if
# local x', 'for x in') by its condition too; a 'for ... in' source and a
# header local's value are evaluated outside.

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# The body of a function, compiled, without the hoisted Locals.
sub body-of(Str $lines)
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, n)\n  local x := 0\n$lines\nreturn n\n]);
  $out ?? $out.lines[4 .. *-2].grep({ !/^ \s* 'Local ' / }).join("\n") !! Nil
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

# ---- prologue locals ----------------------------------------------------------------------
lowers "a prologue local: renamed in the body, not in the block's condition",
  "  if x > 0\n    local x := 999\n    conout(x)\n  endif\n  conout(x)",
  "  if x > 0\n    s_1_x := 999\n    conout(s_1_x)\n  endif\n  conout(x)";

lowers 'the same name in sibling blocks shares one renamed Local',
  "  if n > 0\n    local x := 1\n    n := x\n  endif\n  if n > 1\n    local x := 2\n    n := x\n  endif",
  "  if n > 0\n    s_1_x := 1\n    n := s_1_x\n  endif\n  if n > 1\n    s_1_x := 2\n    n := s_1_x\n  endif";

check 'three levels: each takes the innermost',
{
  my $b = body-of("  if n > 0\n    local x := 1\n    if n > 1\n      local x := 2\n      n := x\n    endif\n    n := x\n  endif");
  $b.contains("      s_2_x := 2\n      n := s_2_x\n    endif\n    n := s_1_x\n")
};

# ---- header locals ------------------------------------------------------------------------
lowers "'if local': the condition sees it, its value does not",
  "  if local x := x + 1, x > 5\n    n := x\n  endif\n  n := x",
  "  s_1_x := x + 1\n  If s_1_x > 5\n    n := s_1_x\n  endif\n  n := x";

lowers "'while local': the same, every round",
  "  while local x := next(x), x != Nil\n    n := x\n  enddo",
  "  While .T.\n    s_1_x := next(x)\n    If !(s_1_x != Nil)\n      Exit\n    EndIf\n    n := s_1_x\n  enddo";

lowers "'for x in x': the source is the outer x",
  "  for x in x\n    n := x\n  next x",
  "  fs_0_0 := x\n  For fi_0_0 := 1 To Len(fs_0_0)\n    s_1_x := fs_0_0[fi_0_0]\n    n := s_1_x\n  next";

lowers "'for local x': the counter renamed, and 'next x' loses the name",
  "  for local x := 1 to 3\n    n := x\n  next x",
  "  For s_1_x := 1 To 3\n    n := s_1_x\n  next";

lowers "a plain 'for' over a renamed counter follows it",
  "  if n > 0\n    local x := 0\n    for x := 1 to 3\n      n := x\n    next x\n  endif",
  "  if n > 0\n    s_1_x := 0\n    For s_1_x := 1 To 3\n      n := s_1_x\n    next\n  endif";

lowers "'do case with local': the cases see it",
  "  do case with local x := n * 2\n    case x > 5\n      n := x\n  endcase",
  "  s_1_x := n * 2\n  Do Case\n    case s_1_x > 5\n      n := s_1_x\n  endcase";

# ---- uses -------------------------------------------------------------------------------------
check 'a lambda parameter of the same name is its own',
{
  body-of("  if n > 0\n    local x := 1\n    a := map(a, [x] x + 1)\n    n := x\n  endif").contains(
    "    a := u_xtpl_map(a, \{|x| x + 1\})\n    n := s_1_x")
};
check 'inside an interpolation, a hash read and a by-reference argument',
{
  my $b = body-of(q:to/END/.chomp);
      if n > 0
        local x := {=>}
        conout("v=${x}")
        n := x{"k"}
        aadd(@x, 1)
      endif
    END
  $b.contains(q[conout(("v=" + cValToChar(s_1_x)))]) && $b.contains(q[n := u_xtpl_hget(s_1_x, "k")])
    && $b.contains('aadd(@s_1_x, 1)')
};
check 'an assignment to it, and a compound one',
{
  my $b = body-of("  if n > 0\n    local x := 1\n    x := x + 1\n    x += 2\n  endif");
  $b.contains("    s_1_x := s_1_x + 1\n    s_1_x += 2")
};
check 'a return inside the block reads the renamed one',
{
  body-of("  if n > 0\n    local x := 5\n    return x\n  endif").contains("    return s_1_x")
};

# ---- no clash, no rename ----------------------------------------------------------------------
check 'a block local with a name of its own keeps it',
{
  body-of("  if n > 0\n    local nY := 1\n    n := nY\n  endif").contains("    nY := 1\n    n := nY")
};

check 'the output compiles to itself',
{
  my $once = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, n)\n  local x := 0\n  for x in a\n    if local x := n, x > 1\n      n := x\n    endif\n  next\nreturn x\n]);
  my $*GENERATED-OK = True;
  $once.defined && compile($once) eq $once
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
