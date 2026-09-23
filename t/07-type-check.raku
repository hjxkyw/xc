use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Types;

# What has to pass and what has to be refused. Both lists matter: a checker
# tested only on what it refuses may be refusing everything.
my @pass =
  'local nX := 1 as Numeric',
  'local nX := 1 + 2 as N',
  'local cS := "a" + "b" as Character',
  'local lB := nX > 3 as Logical',
  'local aL := {} as Array',
  'local jJ := { : } as JSON',
  'local oO := Nil as Object',
  'local nX := f() as Numeric',
  'local xV := "qualquer" as Variant',
  # xtpl's order, checked the same way.
  'local nX as Numeric := 1',
  ;

my @refuse =
  'local nX := "texto" as Numeric',
  'local cS := 42 as Character',
  'local aL := "x" as Array',
  'local lB := 1 + 1 as Logical',
  'local nX := "a" + "b" as N',
  # One comparison of each kind, because 'when a || b' only caught the first
  # of the list and left the others as "unknown" -- which the checker accepts.
  'local nX := a != b as Numeric',
  'local nX := a < b as Numeric',
  'local nX := a >= b as Numeric',
  'local nX := a .and. b as Numeric',
  'local cS := a * b as Character',
  # It matched as an array: the pair's ':' was read as a member of "a".
  'local jJ := { "a": nX } as Array',
  'local cS as Character := 42',
  ;

my ($ok, $total) = 0, @pass + @refuse;

for @pass -> $src
{
  my $m = XC::Grammar.parse($src, rule => 'declaration', actions => XC::Actions.new(source => $src));
  my @p = $m ?? check-declaration($m.made) !! ('did not parse',);
  if @p
  {
    say "  REFUSED  $src";
    say "           {@p[0]}";
  }
  else
  {
    $ok++;
    say "  passes   $src";
  }
}

for @refuse -> $src
{
  my $m = XC::Grammar.parse($src, rule => 'declaration', actions => XC::Actions.new(source => $src));
  my @p = $m ?? check-declaration($m.made) !! ();
  if @p
  {
    $ok++;
    say "  refused  $src";
    say "           {@p[0]}";
  }
  else
  {
    say "  ACCEPTED $src";
  }
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
