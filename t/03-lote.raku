use lib 'lib';
use XC::Grammar;
my ($ok, $no) = 0, 0;
my @falhas;
for '/tmp/utf'.IO.dir.sort -> $f {
  my $src = try slurp($f.Str);
  next unless $src;
  if XC::Grammar.parse($src) { $ok++ }
  else
  {
    $no++;
    @falhas.push($f.basename);
  }
}
say "  casaram: $ok    nao casaram: $no";
