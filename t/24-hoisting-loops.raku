use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;

# Block locals hoisted to the function's top, and the loops and header forms
# built on that. The shapes follow xtpl's output for the same code -- xtpl
# names its slots s_1_0 and so on; xc keeps the names as written, and gives
# its hidden ones xtpl's reserved shapes (fs_0_0, fi_0_0, fn_0_0).

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# The body of a function, compiled: the lines after the header, up to 'return'.
sub body-of(Str $lines)
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, n)\n$lines\nreturn n\n]);
  $out ?? $out.lines[3 .. *-2].join("\n") !! Nil
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

# ---- block locals -----------------------------------------------------------------------
lowers 'a local in a block: an assignment there, a Local at the top',
  "  local nT := 0\n  if n > 0\n    local nX := 1\n    local cY\n    nT := nX\n  endif",
  "  local nT := 0\n  Local nX  // a block local\n  Local cY  // a block local\n  if n > 0\n    nX := 1\n    cY := Nil\n    nT := nX\n  endif";

lowers 'with no prologue, the Locals go before the first statement',
  "  if n > 0\n    local nX := 1\n    conout(nX)\n  endif",
  "  Local nX  // a block local\n  if n > 0\n    nX := 1\n    conout(nX)\n  endif";

lowers 'several declarators in one block declaration',
  "  local nT := 0\n  while n > 0\n    local a1 := 1, a2   // two\n    n := n - a1\n  enddo",
  "  local nT := 0\n  Local a1  // a block local\n  Local a2  // a block local\n  while n > 0\n    a1 := 1\n    a2 := Nil  // two\n    n := n - a1\n  enddo";

# ---- header forms ---------------------------------------------------------------------
lowers 'if local x := e, cond: bound, then tested; the comment on the If',
  "  local nT := 0\n  if local lR := check(), lR   // bound\n    nT := 1\n  endif",
  "  local nT := 0\n  Local lR  // a block local\n  lR := check()\n  If lR  // bound\n    nT := 1\n  endif";

lowers 'if local with elseif and else',
  "  local nT := 0\n  if local nV := calc(), nV > 1\n    nT := 1\n  elseif nV > 0\n    nT := 2\n  else\n    nT := 3\n  endif",
  "  local nT := 0\n  Local nV  // a block local\n  nV := calc()\n  If nV > 1\n    nT := 1\n  elseif nV > 0\n    nT := 2\n  else\n    nT := 3\n  endif";

lowers 'while local x := e, cond: bound and tested every round',
  "  local nT := 0\n  while local c := nx(), c != Nil\n    conout(c)\n  enddo",
  "  local nT := 0\n  Local c  // a block local\n  While .T.\n    c := nx()\n    If !(c != Nil)\n      Exit\n    EndIf\n    conout(c)\n  enddo";

lowers 'for local i: a plain For, i hoisted',
  "  local nT := 0\n  for local i := 1 to n step 2\n    nT := nT + i\n  next",
  "  local nT := 0\n  Local i  // a block local\n  For i := 1 To n Step 2\n    nT := nT + i\n  next";

lowers 'for x in src: the source once, a hidden counter, the element first',
  "  local nT := 0\n  for oI in a        // each\n    nT := nT + oI:nV\n  next oI",
  "  local nT := 0\n  Local oI  // a block local\n  Local fs_0_0  // the source of a 'for ... in'\n  Local fi_0_0  // the counter of a 'for ... in'\n  fs_0_0 := a\n  For fi_0_0 := 1 To Len(fs_0_0)  // each\n    oI := fs_0_0[fi_0_0]\n    nT := nT + oI:nV\n  next";

lowers 'for x, i in src: the index is the counter',
  "  local nT := 0\n  for oI, nP in a |> distinct\n    nT := nT + nP\n  next",
  "  local nT := 0\n  Local oI  // a block local\n  Local nP  // a block local\n  Local fs_0_0  // the source of a 'for ... in'\n  fs_0_0 := u_xtpl_distinct(a)\n  For nP := 1 To Len(fs_0_0)\n    oI := fs_0_0[nP]\n    nT := nT + nP\n  next";

lowers 'for n times, with a number: no count to keep',
  "  local nT := 0\n  for 3 times\n    nT := nT + 1\n  next",
  "  local nT := 0\n  Local fi_0_0  // the counter of a 'for ... times'\n  For fi_0_0 := 1 To 3\n    nT := nT + 1\n  next";

lowers 'for expr times: the count evaluated once',
  "  local nT := 0\n  for len(a) times\n    nT := nT + 1\n  next",
  "  local nT := 0\n  Local fi_0_0  // the counter of a 'for ... times'\n  Local fn_0_0  // the count of a 'for ... times'\n  fn_0_0 := len(a)\n  For fi_0_0 := 1 To fn_0_0\n    nT := nT + 1\n  next";

lowers 'do case with local: the subject evaluated once',
  "  local nT := 0\n  do case with local nS := calc(nT)\n    case nS == 6\n      nT := 1\n    otherwise\n      nT := 2\n  endcase",
  "  local nT := 0\n  Local nS  // a block local\n  nS := calc(nT)\n  Do Case\n    case nS == 6\n      nT := 1\n    otherwise\n      nT := 2\n  endcase";

lowers 'do case with an assignment: nothing to hoist',
  "  local nT := 0\n  do case with nT := calc(n)\n    case nT == 6\n      conout(1)\n  endcase",
  "  local nT := 0\n  nT := calc(n)\n  Do Case\n    case nT == 6\n      conout(1)\n  endcase";

# ---- names ----------------------------------------------------------------------------
lowers 'the same name in sibling blocks shares one Local',
  "  local nT := 0\n  for o in a\n    nT := nT + 1\n  next\n  for o in a\n    nT := nT + 1\n  next",
  "  local nT := 0\n  Local o  // a block local\n  Local fs_0_0  // the source of a 'for ... in'\n  Local fi_0_0  // the counter of a 'for ... in'\n  Local fs_0_1  // the source of a 'for ... in'\n  Local fi_0_1  // the counter of a 'for ... in'\n  fs_0_0 := a\n  For fi_0_0 := 1 To Len(fs_0_0)\n    o := fs_0_0[fi_0_0]\n    nT := nT + 1\n  next\n  fs_0_1 := a\n  For fi_0_1 := 1 To Len(fs_0_1)\n    o := fs_0_1[fi_0_1]\n    nT := nT + 1\n  next";

check 'a hidden name skips one the function already uses',
{
  body-of("  local nT := 0\n  for 3 times\n    fi_0_0 := 1\n  next").contains('For fi_0_1 := 1 To 3')
};

sub problems(Str $lines)
{
  my $src = "user function f(a, n)\n$lines\nreturn n\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  my $out = try emit($m.made, $src);
  $out.defined ?? () !! $!.problems.map({ .key ~ ': ' ~ .value }).List
}
check 'a block local with the name of a variable of the function is reported',
{
  problems("  local oI := 0\n  for oI in a\n    n := 1\n  next")
    eqv ("3: block local 'oI', with the name of a variable of the function,",)
};
check 'a block local shadowing an enclosing one is reported',
{
  problems("  for x in a\n    for x in a\n      n := 1\n    next\n  next")
    eqv ("3: block local 'x', with the name of an enclosing block local,",)
};
check "'for ... in' over rows() is reported (xtpl's corpus never walks one that way)",
{
  problems("  for cL in rows(\"SA1\")\n    n := 1\n  next") eqv ("2: 'for ... in' over rows()",)
};

check 'the output compiles to itself',
{
  my $once = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(a, n)\n  local nT := 0\n  for o, i in a\n    if local x := i, x > 1\n      nT := nT + x\n    endif\n  next\nreturn nT\n]);
  my $*GENERATED-OK = True;
  compile($once) eq $once
};

# ---- the driver: line ends and encodings ------------------------------------------------
my $dir = $*TMPDIR.add("xc-hoist-$*PID");
mkdir $dir;
my $src = "user function f(a)\r\n  // ção\r\n  local n := 0\r\n  for o in a\r\n    n := n + 1\r\n  next\r\nreturn n\r\n";

sub run-xc(Blob $bytes --> Blob)
{
  my $in = $dir.add('in.xtpl');
  spurt $in, $bytes;
  run $*EXECUTABLE, 'bin/xc', $in.Str, :out, :err;
  $dir.add('in.tlpp').slurp(:bin)
}
# On the bytes: decoded, "\r\n" is one character, and it matches '\n' too.
sub crlf-only(Blob $b)
{
  my @b = $b.list;
  my @lf = @b.keys.grep({ @b[$_] == 10 });
  @lf && !@lf.first({ $_ == 0 || @b[$_ - 1] != 13 }).defined
}

check 'a CRLF source comes out CRLF on every line, generated ones included',
{
  crlf-only(run-xc($src.encode('utf-8')))
};
check 'a windows-1252 source comes out windows-1252',
{
  my $out = run-xc($src.encode('windows-1252'));
  $out.decode('windows-1252').contains('// ção') && crlf-only($out)
};
check 'a UTF-8 byte-order mark is kept',
{
  my $out = run-xc(Blob.new(0xEF, 0xBB, 0xBF) ~ $src.encode('utf-8'));
  $out.list[0..2] eqv (0xEF, 0xBB, 0xBF) && $out.subbuf(3).decode('utf-8').starts-with('#include')
};

.unlink for $dir.dir;
rmdir $dir;

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
