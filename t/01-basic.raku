use lib 'lib';
use XC::Grammar;

my @cases =
  "user function f()\n  return"                          => 'signature only',
  "user function f()\n  local n := 0\n  return n"        => 'declaration and return',
  "user function f(a, b)\n  n := a + b * 2\n  return n"  => 'precedence',
  "user function f()\n  conout(\"ola\", 1)\n  return"    => 'call',
  "user function f()\n  if n > 0\n    n := 1\n  endif\n  return"  => 'if',
  ;

my $ok = 0;
for @cases -> $c
{
  my $m = XC::Grammar.parse($c.key);
  $ok++ if $m;
  say ($m ?? "  ok    " !! "  FAIL  "), $c.value;
}
say "\n  $ok of {@cases.elems}";
exit($ok == @cases.elems ?? 0 !! 1);
