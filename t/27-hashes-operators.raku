use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;

# Hashes and the operators xtpl adds, lowered as expressions -- right in any
# position, so nothing is lifted above its statement. xtpl lifts a hash read's
# Get, which goes wrong in a 'while' condition (read once), an 'elseif' (read
# in the wrong branch) and a lambda (read outside it); those three are checked
# here. Also string interpolation, 'fallback', and 'external'.

sub compile(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? emit($m.made, $src) !! Nil
}

# The line a statement becomes: the body's one line, or its lines joined.
sub lowered(Str $stmt)
{
  my $out = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(h, a, o, l)\n  local x := 0\n$stmt\nreturn x\n]);
  $out ?? $out.lines[4 .. *-2].grep({ !/^ \s* 'Local ' / }).join("\n") !! Nil
}

sub parses(Str $stmt) { XC::Grammar.parse("user function f(h, a)\n  local x\n  $stmt\nreturn x\n").defined }

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

sub lowers(Str $what, Str $in, Str $out) { check $what, { lowered($in) eq $out } }

# ---- hashes ------------------------------------------------------------------------------
lowers 'a read is a call',
  '  x := 10 * h{"taxa"}',
  '  x := 10 * u_xtpl_hget(h, "taxa")';
lowers 'a literal builds a THashMap from its pairs',
  '  x := {"taxa" => 0.05, "limite" => 1000}',
  '  x := u_xtpl_hnew({{"taxa", 0.05}, {"limite", 1000}})';
lowers 'the empty hash',
  '  x := {=>}',
  '  x := THashMap():New()';
lowers 'a literal inside an argument (xtpl leaves it as xtpl)',
  '  conout(len({"a" => 1}))',
  '  conout(len(u_xtpl_hnew({{"a", 1}})))';
lowers 'a write is Set',
  '  h{"limite"} := 2000   // a write',
  '  h:Set("limite", 2000)  // a write';
lowers "'+=' reads and writes back (xtpl never writes it back)",
  '  h{"n"} += 2',
  '  h:Set("n", u_xtpl_hget(h, "n") + (2))';
lowers "'?=' writes only a missing key; a hash from a call is evaluated once",
  '  getHash(){"k"} ?= "padrao"',
  "  fhd_0_0 := getHash()\n  If u_xtpl_hget(fhd_0_0, \"k\") == Nil\n    fhd_0_0:Set(\"k\", \"padrao\")\n  EndIf";
lowers 'a key that is an expression, read and written: evaluated once',
  '  h{a + 1} -= 1',
  "  fky_0_0 := a + 1\n  h:Set(fky_0_0, u_xtpl_hget(h, fky_0_0) - (1))";
lowers 'a hash inside a hash',
  '  x := h{"a"}{"b"}',
  '  x := u_xtpl_hget(u_xtpl_hget(h, "a"), "b")';
lowers 'a hash held in a member, written',
  '  o:hCfg{"k"} := 1',
  '  o:hCfg:Set("k", 1)';
lowers 'has',
  '  x := h has "taxa"',
  '  x := u_xtpl_hhas(h, "taxa")';

# ---- where lifting goes wrong --------------------------------------------------------------
lowers "in a 'while' condition: read on every round",
  "  while h\{\"k\"\} > x\n    x := x + 1\n  enddo",
  "  while u_xtpl_hget(h, \"k\") > x\n    x := x + 1\n  enddo";
lowers "in an 'elseif': read there, and only there",
  "  if l\n    x := 1\n  elseif h\{\"k\"\} > 0\n    x := 2\n  endif",
  "  if l\n    x := 1\n  elseif u_xtpl_hget(h, \"k\") > 0\n    x := 2\n  endif";
lowers 'in a lambda: read inside it, with its parameter',
  '  x := map(a, [k] h{k})',
  '  x := u_xtpl_map(a, {|k| u_xtpl_hget(h, k)})';

# ---- operators -----------------------------------------------------------------------------
lowers "'in' is the runtime's",
  '  x := 3 in a',
  '  x := u_xtpl_in(3, a)';
lowers "'%%' is divisible-by",
  '  x := a %% 3',
  '  x := ((a % 3) == 0)';
lowers "'?:' evaluates its right side only when the left is Nil",
  '  x := o ?: slow(a)',
  '  x := u_xtpl_elvis(o, {|| slow(a)})';
lowers "'?.' on a name: the name read twice, as xtpl does",
  '  x := o?.cNome',
  '  x := If(o != Nil, o:cNome, Nil)';
lowers "'?.' on anything else: evaluated once",
  '  x := getObj()?.cNome',
  '  x := Eval({|__v| If(__v != Nil, __v:cNome, Nil)}, getObj())';
lowers "'?.' with a call (xtpl emits 'If(...)(1)')",
  '  x := o?.Metodo(1)',
  '  x := If(o != Nil, o:Metodo(1), Nil)';
lowers "a chain of '?.'",
  '  x := o?.oA?.cNome',
  '  x := Eval({|__v| If(__v != Nil, __v:cNome, Nil)}, If(o != Nil, o:oA, Nil))';

# ---- fallback and interpolation ----------------------------------------------------------
lowers "'fallback' is the runtime's safe_pipe",
  '  x := calc(a) fallback 0',
  '  x := u_xtpl_safe_pipe({|| calc(a)}, {|| 0})';
lowers 'interpolation joins the parts, in the string\'s own quote',
  q[  x := "total ${x} de ${len(a)}"],
  q[  x := ("total " + cValToChar(x) + " de " + cValToChar(len(a)))];
lowers 'an interpolation alone needs no parentheses',
  q[  x := '${x}'],
  q[  x := cValToChar(x)];
lowers 'a hash read inside an interpolation',
  q[  x := "taxa ${h{'t'}} fim"],
  q[  x := ("taxa " + cValToChar(u_xtpl_hget(h, 't')) + " fim")];

# ---- external -------------------------------------------------------------------------------
check "'external' emits nothing: its line goes, but for its comment",
{
  my $src = qq[#include "totvs.ch"\n#include "tlpp-core.th"\nexternal CRLF      // from totvs.ch\nexternal alias SA1\nuser function f()\nreturn CRLF\n];
  compile($src) eq qq[#include "totvs.ch"\n#include "tlpp-core.th"\n// from totvs.ch\nuser function f()\nreturn CRLF\n]
};

# ---- the grammar -------------------------------------------------------------------------
check q<'{' right after ')' or ']' is a hash access too>,
{
  parses('x := getHash(){"k"}') && parses('x := a[1]{"k"}') && parses('getHash(){"k"} := 1')
};
check "a call with a trailer is something to assign to; a call alone is not",
{
  parses('GetObj():cNome := 1') && !parses('f() := 1') && !parses('x := f() {1}')
};

# ---- what has to be refused ---------------------------------------------------------------
check 'a hash write inside an expression (Set is a statement)',
{
  my $src = "user function f(h, a)\n  local x\n  x := map(a, [k] h\{k\} := 1)\nreturn x\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  my $out = try emit($m.made, $src);
  !$out.defined && $!.problems.map(*.value).join eq 'a hash write inside an expression'
};

# ---- the runtime, and the output ----------------------------------------------------------
check 'the runtime has the three functions the output calls',
{
  my $rt = slurp('runtime/xtpl_runtime.tlpp');
  $rt.contains('User Function xtpl_hget(') && $rt.contains('User Function xtpl_hhas(')
    && $rt.contains('User Function xtpl_hnew(')
};
check 'the output compiles to itself',
{
  my $once = compile(qq[#include "totvs.ch"\n#include "tlpp-core.th"\nuser function f(h, a, o)\n  local x := \{"a" => 1\}\n  h\{"n"\} += 2\n  x := o?.oA?.cNome ?: calc(a) fallback 0\nreturn "v=\$\{x\}"\n]);
  my $*GENERATED-OK = True;
  $once.defined && compile($once) eq $once
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
