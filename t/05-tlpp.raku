use lib 'lib';
use XC::Grammar;

my @cases =
  'namespace minha.app'                   => 'namespace',
  'using namespace tlpp.regex'            => 'using namespace',
  '@Get("/clientes")'                     => 'annotation with an argument',
  '@Deprecated'                           => 'annotation without arguments',
  ;

my $ok = 0;
for @cases -> $c
{
  my $m = XC::Grammar.parse($c.key, rule => 'toplevel');
  $ok++ if $m;
  say(($m ?? '  ok    ' !! '  FAIL  '), $c.value.fmt('%-28s'), $c.key);
}

my $source = q:to/END/;
namespace minha.app

using namespace tlpp.regex

@Get("/saldo/:id")
@Deprecated
user function saldo(cId as Character, nLimite as N)
  local aLinhas := {} as Array
  local jResposta as JSON
  local nTotal := 0

  if !empty(cId)
    nTotal := calcula(cId)
  endif

  return nTotal
END

my $m = XC::Grammar.parse($source);
$ok++ if $m;
say(($m ?? '  ok    ' !! '  FAIL  '), 'a whole TL++ file');
my $total = @cases.elems + 1;
say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
