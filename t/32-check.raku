use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Check;

# XC::Check, case by case: what has to pass (a name declared some way, or not
# a variable at all) and what has to be refused, beyond the one case per rule
# in t/xtpl/errors/ (t/17-xtpl-errors.raku). The whole of xtpl's corpus has to
# pass too (t/31-xtpl-corpus.raku).

# The errors and the warnings, as 'line: message'.
sub result(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  die "does not parse" unless $m;
  my %c = check-all($m.made);
  %(errors   => %c<errors>.map({ .key ~ ': ' ~ .value }).List,
    warnings => %c<warnings>.map({ .key ~ ': ' ~ .value }).List)
}
sub problems(Str $src) { result($src)<errors> }

# A function around some lines; the lines start at line 2.
sub in-function(Str $lines, Str $params = 'a') { result("user function f($params)\n$lines\nreturn 1\n") }

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# Passes: no error, and no warning either.
sub passes(Str $what, Str $lines, Str $params = 'a')
{
  check "passes: $what", { my %r = in-function($lines, $params); !%r<errors> && !%r<warnings> };
}
sub refuses(Str $what, Str $lines, Str $problem, Str $params = 'a')
{
  check "refuses: $what", { in-function($lines, $params)<errors> eqv ($problem,) };
}
# Warns: compiles, with these warnings.
sub warns(Str $what, Str $lines, *@warnings)
{
  check "warns: $what", { my %r = in-function($lines); !%r<errors> && %r<warnings> eqv @warnings.List };
}

# ---- declared ------------------------------------------------------------------------------
passes 'a parameter, a local, a static, a public',
  "  local nL := a\n  static nS := 0\n  public nP := 1\n  nL := nS + nP\n  a := nL";
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
  "  DbSelectArea(\"SA1\")\n  a := SA1->A1_COD\n  a := SA1->(A1_SALDO + A1_JUROS)";
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
  "  local oErr\n  begin sequence\n    a := 1\n  recover using oErr\n    a := oErr\n  end sequence";

# ---- not declared: a warning --------------------------------------------------------------
# xtpl refuses these; xc warns, so plain TL++ that uses the system's globals
# compiles unchanged. xtpl's words when it only warns (its legacy mode).
warns 'a name read that nothing declares',
  "  a := nX + 1", "2: 'nX' is not declared";
warns 'a name written that nothing declares: AdvPL makes a PRIVATE of it',
  "  nX := 1", "2: 'nX' is not declared, so this creates a PRIVATE";
warns "the counter of a plain 'for' that nothing declares",
  "  for i := 1 to 3\n    a := a + 1\n  next", "2: 'i' is not declared, so this creates a PRIVATE";
warns 'a system global, as plain TL++ uses it',
  "  a := cFilAnt + dDataBase", "2: 'cFilAnt' is not declared", "2: 'dDataBase' is not declared";
warns 'once per name',
  "  a := nX\n  a := nX + 1", "2: 'nX' is not declared";
warns 'a PRIVATE made by a write is known from then on',
  "  nX := 1\n  a := nX", "2: 'nX' is not declared, so this creates a PRIVATE";
refuses 'a name used after its block, as out of scope',
  "  if a > 0\n    local nT := 5\n  endif\n  a := nT", "5: 'nT' is out of scope here (block local declared on line 3).";
warns "a lambda's parameter outside the lambda",
  "  a := map(a, [x] x)\n  a := x", "3: 'x' is not declared";
warns "a function's name read as a value, outside a verb that takes a block",
  "  a := alltrim", "2: 'alltrim' is not declared";
check "refuses: a name used after its block stays an error -- it is xtpl's block locals",
{
  in-function("  if a > 0\n    local nT := 5\n  endif\n  a := nT")<errors>
    eqv ("5: 'nT' is out of scope here (block local declared on line 3).",)
};

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
  "  local x := lines(\"a.txt\")\n  a := lines(\"b.txt\")\n  a := x\n  for cL in lines(\"c.txt\")\n  next";

# ---- xtpl's warnings: never read, returns, areas ---------------------------------------------
warns 'a variable assigned but never read, on its declaration',
  "  local nX := 0\n  nX := a", "2: 'nX' is assigned but never read";
warns 'a variable declared and never used',
  "  local nX", "2: 'nX' is declared but never used";
passes "a read counts in raw text, in '+=', in '\@x' and as a 'for' counter",
  "  local n1 := 0, n2 := 0, n3 := 0, n4 := 0\n  raw ANOTE n1\n  n2 += 1\n  aadd(@n3, 1)\n  for n4 := 1 to 2\n  next";
passes "not reported: a parameter, a private, a public, what a loop declares",
  "  private pX := 1\n  public uX := 1\n  for eX, iX in a\n  next\n  for local cX := 1 to 2\n  next";

check "warns: a bare 'return' where the function also returns a value",
{
  result("user function f(a)\n  return 1 if a > 0\n  return\n")<warnings>
    eqv ("3: this returns nothing, but the function returns a value on line 2",)
};
check "warns: the end reached without a return, on the function's last line",
{
  result("user function f(a)\n  return 1 if a > 0\n  a := 2\n\nuser function g()\nreturn 1\n")<warnings>
    eqv ("4: the function can reach its end without a return, but returns a value on line 2",)
};
check "passes: every path returns a value",
{
  !result("user function f(a)\n  if a > 0\n    return 1\n  endif\nreturn 2\n")<warnings>
};

warns 'a field of an area nothing opened: once per area',
  "  a := SA1->A1_COD + SA1->A1_NOME",
  "2: nothing in this function opened SA1. Wrap the use in 'using alias SA1 do', or declare 'external alias SA1' if the caller opens it.";
passes 'opened by DbSelectArea, ChkFile, rows() or using alias',
  "  DbSelectArea(\"SA1\")\n  ChkFile(\"SB1\")\n  a := SA1->A1_COD + SB1->B1_COD\n  a := rows(\"SC5\") |> map([r] r:C5_NUM)\n  a := SC5->C5_NUM\n  using alias SD1 do\n    a := SD1->D1_COD\n  end using";
check "passes: an area the caller opens, declared 'external alias'",
{
  !result("external alias SA1\nuser function f()\nreturn SA1->A1_COD\n")<warnings>
};
warns 'used before the line that opens it',
  "  a := SA1->A1_COD\n  DbSelectArea(\"SA1\")",
  "2: nothing in this function opened SA1. Wrap the use in 'using alias SA1 do', or declare 'external alias SA1' if the caller opens it.";
passes 'an area held in a variable is not checked',
  "  local cAl := \"SA1\"\n  a := (cAl)->A1_COD";

# ---- the driver ----------------------------------------------------------------------------
check 'bin/xc prints a warning with its file and line, and compiles',
{
  my $dir = $*TMPDIR.add("xc-check-$*PID");
  mkdir $dir;
  my $in = $dir.add('w.xtpl');
  spurt $in, "user function f()\n  local n := 0\n  n := cFilAnt\nreturn n\n";
  my $p = run $*EXECUTABLE, 'bin/xc', $in.Str, :out, :err;
  my $err = $p.err.slurp(:close);
  $p.out.slurp(:close);
  my $done = $p.exitcode == 0 && $err.contains("w.xtpl:3: warning: 'cFilAnt' is not declared")
             && $dir.add('w.tlpp').e;
  .unlink for $dir.dir;
  rmdir $dir;
  $done
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
