use lib 'lib';
use XC::Grammar;

my @casos =
  'namespace minha.app'                   => 'namespace',
  'using namespace tlpp.regex'            => 'using namespace',
  '@Get("/clientes")'                     => 'anotacao com argumento',
  '@Deprecated'                           => 'anotacao sem argumento',
  ;

my $ok = 0;
for @casos -> $c
{
  my $m = XC::Grammar.parse($c.key, rule => 'toplevel');
  $ok++ if $m;
  say(($m ?? '  ok    ' !! '  FALHA '), $c.value.fmt('%-24s'), $c.key);
}

my $fonte = q:to/FIM/;
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
FIM

my $m = XC::Grammar.parse($fonte);
$ok++ if $m;
say(($m ?? '  ok    ' !! '  FALHA '), 'arquivo TL++ inteiro');
say "\n  $ok de {@casos.elems + 1}";
