use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;
use XC::Check;

# Forms of real AdvPL and TL++ -- found running xc over 1,407 sources from
# GitHub -- that xc did not read. TL++ goes through xc as it came: each source
# here compiles to itself, byte for byte, and passes the checks.

sub parse(Str $src)
{
  my $*FURTHEST = 0;
  XC::Grammar.parse($src, actions => XC::Actions.new(source => $src))
}

my $head = qq[#include "totvs.ch"\n#include "tlpp-core.th"\n\n];

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# As it came, and no error from the checks.
sub same(Str $what, Str $body)
{
  check $what, {
    my $src = $head ~ $body;
    my $m = parse($src);
    $m && emit($m.made, $src) eq $src && !check-all($m.made, source => $src)<errors>
  };
}
# The warnings the checks give, as text.
sub warnings(Str $body)
{
  my $src = $head ~ $body;
  check-all(parse($src).made, source => $src)<warnings>.map(*.value).List
}

# ---- functions --------------------------------------------------------------
same 'a function with no parentheses', "User Function TLeroy\nreturn 1\n";
same 'a return type; integer, decimal, codeblock among the types',
  "Static Function Scheddef() as array\nreturn \{\}\n\nUser Function f(n as integer, x as decimal, b as codeblock) as logical\nreturn .T.\n";

# ---- assignments as values --------------------------------------------------
same 'an assignment in parentheses is a value',
  "User Function f(a)\n  Local lErr := .F.\n  if !( lErr := g(\@a) )\n    a := 1\n  endif\nreturn lErr\n";
same "chained, from the right -- and 'b = 0' in a value compares",
  "User Function f(a)\n  Local b := 0, c := 0\n  a := b := c := 0\n  a := b = 0\nreturn a + c\n";

# ---- statements ---------------------------------------------------------------
same "'Do While' ... 'EndDo'", "User Function f(a)\n  Do While a > 0\n    a--\n  EndDo\nreturn a\n";
same "'Default', one or more", "User Function f(a, b)\n  Default a := 1\n  DEFAULT b := \{\}, a := 2\nreturn a\n";
same "';' between statements on one line; at its end, a continuation",
  "User Function f(a)\n  conout(1); a++; a += 2\n  a := 1 + ;\n    2\nreturn a\n";
same "'try' ... 'catch' ... 'endtry'; without 'catch' too",
  "User Function f(a)\n  Local oErr\n  try\n    a := 1\n  catch oErr\n    conout(oErr:Description)\n  endtry\n  try\n    a := 2\n  endtry\nreturn a\n";
same "'Break' in a 'begin sequence'", "User Function f(a)\n  begin sequence\n    Break(a)\n  recover\n    a := 0\n  end sequence\nreturn a\n";
same "'Begin Transaction' ... 'End Transaction'", "User Function f(a)\n  Begin Transaction\n    a := 1\n  End Transaction\nreturn a\n";

# ---- the file ---------------------------------------------------------------------
same "a 'Static' of the file, typed or not, with a value or not",
  "Static aDados__ as array\nStatic cToken__ := \"\" as character // a comment\nStatic lInit := .F.\n\nUser Function f()\n  aDados__ := \{\}\n  lInit := .T.\nreturn cToken__\n";

# ---- classes ------------------------------------------------------------------------
same "'Data ... default', 'Static Method', visibilities, '::' calls as statements",
  "Class Gw from Base\n  Public Data cId as character default \"\"\n  Static Method Make()\n  Private Method Wait( nWait as integer )\n  Public Static Method Other()\n  Method New() Constructor\nEndClass\n\nMethod New() Class Gw\n  ::Init()\n  ::oLog:Error( \"x\", \{ 1 \} )\n  ::cId := \"a\"\nReturn Self\n";

# ---- what the checks make of them ------------------------------------------------
check "'Default' reads what it sets: no 'never read'",
{
  !warnings("User Function f(a)\n  Local n\n  Default n := 1\nreturn a\n").first(*.contains('never read'))
};
check "a file 'Static' is known in every function of the file",
{
  !warnings("Static nCount := 0\n\nUser Function f()\n  nCount++\nreturn nCount\n")
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
