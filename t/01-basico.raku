use lib 'lib';
use XC::Grammar;

my @casos =
  "user function f()\n  return"                          => 'assinatura so',
  "user function f()\n  local n := 0\n  return n"        => 'declaracao e return',
  "user function f(a, b)\n  n := a + b * 2\n  return n"  => 'precedencia',
  "user function f()\n  conout(\"ola\", 1)\n  return"    => 'chamada',
  "user function f()\n  if n > 0\n    n := 1\n  endif\n  return"  => 'if',
  ;

my $ok = 0;
for @casos -> $c
{
  my $m = XC::Grammar.parse($c.key);
  $ok++ if $m;
  say ($m ?? "  ok    " !! "  FALHA "), $c.value;
}
say "\n  $ok de {@casos.elems}";
exit($ok == @casos.elems ?? 0 !! 1);
