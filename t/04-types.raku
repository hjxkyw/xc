use lib 'lib';
use XC::Grammar;

my @cases =
  'local aLista := {}'                => 'implicit array',
  'local aLista as Array'             => 'explicit array',
  'local aLista := {} as Array'       => 'array, both',
  'local aLista as A'                 => 'abbreviated array',
  'local nX := 0'                     => 'implicit number',
  'local nX as Numeric'               => 'explicit number',
  'local nX := 0 as N'                => 'abbreviated number',
  'local cS := ""'                    => 'double-quoted string',
  "local cS := ''"                    => 'single-quoted string',
  'local cS as Character'             => 'explicit string',
  'local oO := Nil'                   => 'implicit object',
  'local oO as Object'                => 'explicit object',
  'local jJ := { : }'                 => 'empty json',
  'local jJ as JSON'                  => 'explicit json',
  'local hH := { => }'                => 'empty hash',
  'local nA := 1, cB := "x", oC as O' => 'several in one statement',
  # xtpl's order: TL++ refuses it, xtpl accepts it and emits the type after.
  'local nA as Numeric := 1'          => 'type first, xtpl order',
  'local cS as C := ""'               => 'same, abbreviated',
  ;

my $ok = 0;
for @cases -> $c
{
  my $m = XC::Grammar.parse($c.key, rule => 'declaration');
  $ok++ if $m;
  say(($m ?? '  ok    ' !! '  FAIL  '), $c.value.fmt('%-26s'), $c.key);
}

# And what has to be REFUSED.
my @refuse =
  'local nA as Numeric := 1 as Numeric' => 'type twice',
  'local nA := as Numeric'               => 'empty initializer',
  ;

for @refuse -> $c
{
  my $m = XC::Grammar.parse($c.key, rule => 'declaration');
  $ok++ unless $m;
  say(($m ?? '  ACCEPTED ' !! '  refused  '), $c.value.fmt('%-30s'), $c.key);
}

my $total = @cases + @refuse;
say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
