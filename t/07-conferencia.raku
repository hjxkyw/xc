use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Tipos;

# O que tem de passar e o que tem de ser recusado. As duas listas importam: um
# verificador testado so pelo que ele recusa pode estar recusando tudo.
my @passa =
  'local nX := 1 as Numeric',
  'local nX := 1 + 2 as N',
  'local cS := "a" + "b" as Character',
  'local lB := nX > 3 as Logical',
  'local aL := {} as Array',
  'local jJ := { : } as JSON',
  'local oO := Nil as Object',
  'local nX := f() as Numeric',
  'local xV := "qualquer" as Variant',
  ;

my @recusa =
  'local nX := "texto" as Numeric',
  'local cS := 42 as Character',
  'local aL := "x" as Array',
  'local lB := 1 + 1 as Logical',
  'local nX := "a" + "b" as N',
  # Uma comparacao de cada, porque 'when a || b' so pegava a primeira da
  # lista e deixava as outras em "nao sei" -- que o verificador aceita.
  'local nX := a != b as Numeric',
  'local nX := a < b as Numeric',
  'local nX := a >= b as Numeric',
  'local nX := a .and. b as Numeric',
  'local cS := a * b as Character',
  ;

my ($ok, $total) = 0, @passa + @recusa;

for @passa -> $src
{
  my $m = XC::Grammar.parse($src, rule => 'declaration', actions => XC::Actions.new(fonte => $src));
  my @p = $m ?? confere($m.made) !! ('nao parseou',);
  if @p
  {
    say "  RECUSOU  $src";
    say "           {@p[0]}";
  }
  else
  {
    $ok++;
    say "  passa    $src";
  }
}

for @recusa -> $src
{
  my $m = XC::Grammar.parse($src, rule => 'declaration', actions => XC::Actions.new(fonte => $src));
  my @p = $m ?? confere($m.made) !! ();
  if @p
  {
    $ok++;
    say "  recusa   $src";
    say "           {@p[0]}";
  }
  else
  {
    say "  ACEITOU  $src";
  }
}

say "\n  $ok de $total";
exit($ok == $total ?? 0 !! 1);
