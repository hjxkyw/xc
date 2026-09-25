use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;
use XC::Emit;
use XC::Source;

# The compiler: source positions, the comment splitter, the emitter (source
# plus edits), and the driver. The expected outputs follow xtpl's layout for
# the constructs lowered so far: a trailing comment goes back on the header
# line of a block, on the last line otherwise.

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# A source with both includes, so the output is only the edits.
sub with-includes(Str $body) { qq[#include "totvs.ch"\n#include "tlpp-core.th"\n$body] }

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- positions ---------------------------------------------------------------------
grammar Marker { token TOP { .*? <m> .* }; token m { 'XX' } }
sub at(Str $s) { my $m = Marker.parse($s); my $p = XC::Source.new(text => $s); ($p.char($m<m>.from), $p.line($m<m>.from)) }

check 'an accent before a match: characters, not bytes',
{
  at("ção\nXX") eqv (4, 2)
};
check 'CRLF: one character per line end, and the right line',
{
  at("ab\r\ncd\r\nXX") eqv (6, 3) && at("é\r\nçã\r\nXX") eqv (5, 3)
};
check 'the line of every statement holds its text, with accents and CRLF',
{
  my $src = "// cabeçalho com acentuação\r\nuser function f(n)\r\n  // ção\r\n  n := 1\r\n  n := n + 1\r\nreturn n\r\n";
  my $p = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src)).made;
  my @l = $src.lines;
  $p.functions[0].body.map({ @l[.line - 1].contains($src.substr(.src-from, 6)) }).all.so
};

# ---- the comment splitter ------------------------------------------------------------
check 'code and a trailing comment',
{
  split-comment('x := 1   // note') eqv ('x := 1', '// note')
};
check '// inside a string is not a comment',
{
  split-comment('x := "http://a"  // real') eqv ('x := "http://a"', '// real')
};
check 'a block comment in the middle joins the trailing one',
{
  split-comment('x := /* mid */ 1 // end') eqv ('x :=   1', '// mid // end')
};

# ---- identity: plain TL++ comes out as it went in ---------------------------------------
my $plain = with-includes(q:to/END/);
// a header comment
/* a block comment
   over two lines */
namespace minha.app

@Get("/x")
user function f(nX as Numeric)   // a trailing comment
  local aL := {}, nY := 0       // declarations stay as written

  if nX > 0                     // an ordinary if
    aadd(aL, nX)
  endif
  nY := len(aL) /* inline */ + 1
return nY

static function g()
return nil
END

check 'plain TL++ with both includes comes out byte for byte',
{
  compile($plain) eq $plain
};
check 'the includes are added at the top when missing',
{
  my $src = "user function f()\nreturn 1\n";
  compile($src) eq qq[#include "totvs.ch"\n#include "tlpp-core.th"\n\n$src]
};
check 'only the missing include is added',
{
  my $src = qq[#include "TOTVS.CH"\nuser function f()\nreturn 1\n];
  compile($src) eq qq[#include "tlpp-core.th"\n\n$src]
};

# ---- lowering ------------------------------------------------------------------------
sub lowers(Str $what, Str $in, Str $out)
{
  check $what, { compile(with-includes($in)) eq with-includes($out) };
}

lowers 'x := v if c, with its comment on the If line',
  "user function f(n)\n  nY := n * 2 if n > 0    // a note\nreturn nY\n",
  "user function f(n)\n  If n > 0  // a note\n    nY := n * 2\n  EndIf\nreturn nY\n";

lowers 'f() while c',
  "user function f(n)\n  conout(\"x\") while n > 10\nreturn n\n",
  "user function f(n)\n  While n > 10\n    conout(\"x\")\n  EndDo\nreturn n\n";

lowers 'return x if c, nested in an if, keeps its indentation',
  "user function f(n)\n  if n > 1\n    return n if n > 100\n  endif\nreturn 0\n",
  "user function f(n)\n  if n > 1\n    If n > 100\n      return n\n    EndIf\n  endif\nreturn 0\n";

lowers 'exec f() if c',
  "user function f(n)\n  exec reset() if n == 0\nreturn n\n",
  "user function f(n)\n  If n == 0\n    reset()\n  EndIf\nreturn n\n";

lowers 'x ?= v',
  "user function f(c)\n  c ?= \"empty\"   // assign if Nil\nreturn c\n",
  "user function f(c)\n  If c == Nil  // assign if Nil\n    c := \"empty\"\n  EndIf\nreturn c\n";

lowers 'x ?= v if c: one rewrite inside another',
  "user function f(c, n)\n  c ?= \"e\" if n > 0\nreturn c\n",
  "user function f(c, n)\n  If n > 0\n    If c == Nil\n      c := \"e\"\n    EndIf\n  EndIf\nreturn c\n";

lowers 'the type first: swapped back, comment on the only line',
  "user function f()\n  local nX as Numeric := 1   // typed\nreturn nX\n",
  "user function f()\n  local nX := 1 as Numeric  // typed\nreturn nX\n";

lowers 'attributes dropped, the other declarators kept',
  "user function f()\n  local a <const> := 1, b := 2, c <contained> as A := \{\}\nreturn a\n",
  "user function f()\n  local a := 1, b := 2, c := \{\} as A\nreturn a\n";

lowers 'a string holding // in a rewritten line keeps its text',
  "user function f(n)\n  c := \"http://x\" if n > 0\nreturn c\n",
  "user function f(n)\n  If n > 0\n    c := \"http://x\"\n  EndIf\nreturn c\n";

lowers 'a rewrite inside a method implementation',
  "method go(n) class C\n  ::n := n if n > 0\nreturn Self\n",
  "method go(n) class C\n  If n > 0\n    ::n := n\n  EndIf\nreturn Self\n";

check 'the output of a compile compiles to itself',
{
  my $once = compile(with-includes("user function f(c, n)\n  local nZ as N := 1\n  c ?= \"e\" if n > 0   // x\nreturn c\n"));
  compile($once) eq $once
};

# ---- what is not lowered yet ------------------------------------------------------------
check 'every construct not lowered yet is reported with its line, and nothing is emitted',
{
  my $src = "user function f(a, o)\n  local n := 1..3 |> asum\n  raw ANOTE n\n  with object o\n    :Ativa()\n  end with\nreturn n\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  my $out = try emit($m.made, $src);
  !$out.defined && $! ~~ X::XC::NotLowered
    && $!.problems.map({ .key ~ ' ' ~ .value }).join(', ')
       eq "2 'lo..hi', 3 'raw', 4 'with object', 5 ':x' of 'with object'"
};

# ---- the driver ------------------------------------------------------------------------
my $dir = $*TMPDIR.add("xc-test-$*PID");
mkdir $dir;
sub xc(*@args)
{
  my $p = run $*EXECUTABLE, 'bin/xc', |@args, :out, :err;
  ($p.exitcode, $p.out.slurp(:close), $p.err.slurp(:close))
}

check 'bin/xc writes file.tlpp next to file.xtpl',
{
  my $in = $dir.add('ok.xtpl');
  spurt $in, "user function f(n)\n  n := 1 if n == Nil\nreturn n\n";
  my ($code) = xc($in.Str);
  $code == 0 && $dir.add('ok.tlpp').slurp.contains("If n == Nil\n    n := 1\n  EndIf")
};
check 'bin/xc: a parse error names the line, and no .tlpp is written',
{
  my $in = $dir.add('bad.xtpl');
  spurt $in, "user function f(a)\r\n  // ção\r\n  n := 1\r\n  n := := 2\r\nreturn n\r\n";
  my ($code, $, $err) = xc($in.Str);
  $code == 1 && $err.contains('bad.xtpl:4: cannot parse this line: n := := 2')
    && !$dir.add('bad.tlpp').e
};
check 'bin/xc: a block never closed',
{
  my $in = $dir.add('open.xtpl');
  spurt $in, "user function f(a)\n  if a\n    n := 1\nreturn n\n";
  my ($code, $, $err) = xc($in.Str);
  $code == 1 && $err.contains('the file ends inside a block that was never closed')
};
check 'bin/xc: a construct not lowered yet names its line, and no .tlpp is written',
{
  my $in = $dir.add('ext.xtpl');
  spurt $in, "user function f(o)\n  with object o\n    :Ativa()\n  end with\nreturn 1\n";
  my ($code, $, $err) = xc($in.Str);
  $code == 1 && $err.contains("ext.xtpl:2: 'with object' is not lowered yet") && !$dir.add('ext.tlpp').e
};

.unlink for $dir.dir;
rmdir $dir;

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
