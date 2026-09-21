use lib 'lib';
use XC::Grammar;

my @casos =
  'local aLista := {}'                => 'array implicito',
  'local aLista as Array'             => 'array explicito',
  'local aLista := {} as Array'       => 'array, os dois',
  'local aLista as A'                 => 'array abreviado',
  'local nX := 0'                     => 'numero implicito',
  'local nX as Numeric'               => 'numero explicito',
  'local nX := 0 as N'                => 'numero abreviado',
  'local cS := ""'                    => 'string com aspas duplas',
  "local cS := ''"                    => 'string com aspas simples',
  'local cS as Character'             => 'string explicita',
  'local oO := Nil'                   => 'objeto implicito',
  'local oO as Object'                => 'objeto explicito',
  'local jJ := { : }'                 => 'json vazio',
  'local jJ as JSON'                  => 'json explicito',
  'local hH := { => }'                => 'hash vazio',
  'local nA := 1, cB := "x", oC as O' => 'varios num comando',
  # A ordem do xtpl: o TL++ recusa, o xtpl aceita e emite o tipo depois.
  'local nA as Numeric := 1'          => 'tipo antes, ordem do xtpl',
  'local cS as C := ""'               => 'idem, abreviado',
  ;

my $ok = 0;
for @casos -> $c
{
  my $m = XC::Grammar.parse($c.key, rule => 'declaration');
  $ok++ if $m;
  say(($m ?? '  ok    ' !! '  FALHA '), $c.value.fmt('%-26s'), $c.key);
}

# E o que tem de ser RECUSADO.
my @recusar =
  'local nA as Numeric := 1 as Numeric' => 'tipo duas vezes',
  'local nA := as Numeric'               => 'inicializador vazio',
  ;

for @recusar -> $c
{
  my $m = XC::Grammar.parse($c.key, rule => 'declaration');
  $ok++ unless $m;
  say(($m ?? '  ACEITOU ' !! '  recusa  '), $c.value.fmt('%-30s'), $c.key);
}

my $total = @casos + @recusar;
say "\n  $ok de $total";
exit($ok == $total ?? 0 !! 1);
