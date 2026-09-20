use lib 'lib';
use XC::Grammar;

sub testa($caminho)
{
  my $src = slurp($caminho);
  my $m = XC::Grammar.parse($src);
  if $m
  {
    say "  ok    {$caminho.IO.basename}  ({$src.lines.elems} linhas, ",
        "{$m<toplevel>.elems} itens de topo)";
    return True;
  }
  say "  FALHA {$caminho.IO.basename}";
  return False;
}

my @arquivos = @*ARGS || '/tmp/exec.prw';
my $ok = 0;
$ok++ for @arquivos.grep({ testa($_) });
say "\n  $ok de {@arquivos.elems}";
