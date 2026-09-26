use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Check;

# XC::Check, case by case: what has to pass (a name declared some way, or not
# a variable at all) and what has to be refused, beyond the one case per rule
# in t/xtpl/errors/ (t/17-xtpl-errors.raku). The whole of xtpl's corpus has to
# pass too (t/31-xtpl-corpus.raku).

sub problems(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  die "does not parse" unless $m;
  check-program($m.made).map({ .key ~ ': ' ~ .value }).List
}

# A function around some lines; the lines start at line 2.
sub in-function(Str $lines, Str $params = 'a') { problems("user function f($params)\n$lines\nreturn 1\n") }

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

sub passes(Str $what, Str $lines, Str $params = 'a')
{
  check "passes: $what", { !in-function($lines, $params) };
}
sub refuses(Str $what, Str $lines, Str $problem, Str $params = 'a')
{
  check "refuses: $what", { in-function($lines, $params) eqv ($problem,) };
}

# ---- declared ------------------------------------------------------------------------------
passes 'a parameter, a local, a static, a public',
  "  local nL := a\n  static nS := 0\n  public nP := 1\n  nL := nS + nP";
passes 'a private, even in a function the file calls: it is dynamic',
  "  private nPriv := 1\n  g()";
check "passes: a private read in another function of the file",
{
  !problems("user function f()\n  private nP := 1\n  g()\nreturn 1\nstatic function g()\nreturn nP\n")
};
passes 'a block local inside its block, and in a block inside that',
  "  if a > 0\n    local nB := 1\n    if a > 1\n      a := nB\n    endif\n  endif";
passes "a header local ('if local', 'for x in', 'for local') in its condition and body",
  "  if local nH := a * 2, nH > 1\n    a := nH\n  endif\n  for nE, nI in \{1\}\n    a := nE + nI\n  next\n  for local nC := 1 to 3\n    a := nC\n  next";
passes "a lambda's and a code block's parameters",
  "  a := map(a, [x] x + 1)\n  a := aeval(a, \{|y, z| y + z\})";
check "passes: an external name, and a #define of the file",
{
  !problems("#define cConst \"x\"\nexternal CRLF\nuser function f(a)\n  a := CRLF + cConst\nreturn a\n")
};
passes 'Self, nil and the known words',
  "  a := Self\n  a := nil";
passes "a name before '->' is the area, and inside 'ALIAS->( ... )' a bare name is a field",
  "  a := SA1->A1_COD\n  a := SA1->(A1_SALDO + A1_JUROS)";
passes 'a bare function name given to a verb that takes a block',
  "  a := map(a, alltrim)\n  a := a |> filter(isOk) |> map(upper)";
passes "a member, a method, a call, 'Self''s '::x'",
  "  a := o():x + a:Soma(1) + len(a)";
passes "the same name in sibling blocks",
  "  if a > 0\n    local nT := 1\n    a := nT\n  endif\n  if a > 1\n    local nT := 2\n    a := nT\n  endif";
passes "a block local with the name of a function variable: it is its own (and renamed)",
  "  local nT := 0\n  if a > 0\n    local nT := 5\n    a := nT\n  endif\n  a := nT";
passes 'names inside an interpolation and a hash access',
  "  local h := \{=>\}\n  a := \"v=\$\{a\}\" + h\{\"k\"\}";
passes 'raw text is not read',
  "  raw MOSTRE nNaoDeclarado";
passes "'recover using' writes a declared variable",
  "  local oErr\n  begin sequence\n    a := 1\n  recover using oErr\n    a := 2\n  end sequence";

# ---- not declared -------------------------------------------------------------------------
refuses 'a name read that nothing declares',
  "  a := nX + 1", "2: 'nX' is not declared. Everything used in xtpl must be declared.";
refuses 'a name written that nothing declares',
  "  nX := 1", "2: Variable 'nX' used without declaration.";
refuses "the counter of a plain 'for' that nothing declares",
  "  for i := 1 to 3\n    a := a + 1\n  next", "2: Variable 'i' used without declaration.";
refuses 'a name used after its block, as out of scope',
  "  if a > 0\n    local nT := 5\n  endif\n  a := nT", "5: 'nT' is out of scope here (block local declared on line 3).";
refuses "a lambda's parameter outside the lambda",
  "  a := map(a, [x] x)\n  a := x", "3: 'x' is not declared. Everything used in xtpl must be declared.";
refuses "a function's name read as a value, outside a verb that takes a block",
  "  a := alltrim", "2: 'alltrim' is not declared. Everything used in xtpl must be declared.";

# ---- const, contained, external ---------------------------------------------------------------
refuses "a <const> assigned inside a lambda",
  "  local nL <const> := 1\n  a := map(a, [x] nL := x)", "3: 'nL' is <const> (declared on line 2) and cannot be assigned.";
refuses "a <const> as a plain 'for' counter",
  "  local nL <const> := 1\n  for nL := 1 to 3\n  next", "3: 'nL' is <const> (declared on line 2) and cannot be assigned.";
refuses "a <contained> named in a raw command (GET holds on to it)",
  "  local nC <contained> := 1\n  raw @ 1, 1 GET nC", "3: 'nC' is <contained> (declared on line 2) and cannot leave its block.";
refuses "a <contained> read inside a lambda",
  "  local nC <contained> := 1\n  a := map(a, [x] x + nC)", "3: 'nC' is <contained> (declared on line 2) and cannot leave its block.";
passes "a <contained> used where it is",
  "  local nC <contained> := 1\n  a := nC + len(a)";
check "refuses: an external written",
{
  problems("external dDataBase\nuser function f()\n  dDataBase := Date()\nreturn 1\n")
    eqv ("3: 'dDataBase' is external (line 1) and cannot be assigned.",)
};

# ---- calls to the file's functions ---------------------------------------------------------
my $two = "static function s(x, y)\nreturn x\nuser function u(x)\nreturn x\n";
check 'passes: the right forms, and fewer arguments than parameters',
{
  !problems($two ~ "user function f()\n  local a := s(1) + s(1, 2) + u_u(3)\nreturn a\n")
};
check "refuses: a user function called without its 'u_'",
{
  problems($two ~ "user function f()\n  local a := u(3)\nreturn a\n")
    eqv ("6: 'u' is a user function (line 3), so it is called as 'u_u' -- the compiler puts the prefix on the declaration.",)
};
check "refuses: a user function given too many arguments, through its 'u_'",
{
  problems($two ~ "user function f()\n  local a := u_u(1, 2)\nreturn a\n")
    eqv ("6: u() takes 1 parameter (line 3), but is given 2.",)
};
check 'passes: an omitted argument does not count',
{
  !problems($two ~ "user function f()\n  local a := s(1, , )\nreturn a\n")
};

# ---- chains --------------------------------------------------------------------------------
refuses "a variable declared 'as numeric' as a chain's source",
  "  local nN as numeric := 0\n  a := nN |> asum",
  "3: nN is a single value -- it is declared 'as numeric', and a chain walks a collection. Write \{nN\} for a one-element array, or 'lo..hi' for a range.";
passes 'a parameter as a chain source: it says nothing about what it holds',
  "  a := a |> asum";
passes "rows() and lines() where a source may stand alone",
  "  local x := lines(\"a.txt\")\n  a := lines(\"b.txt\")\n  for cL in lines(\"c.txt\")\n  next";

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
