use lib 'lib';
use XC::Grammar;

# Um arquivo inteiro, do comeco ao fim. Por padrao o exemplo que vem junto;
# passe caminhos na linha de comando para testar os seus.
sub testa($caminho)
{
  my $src = try slurp($caminho);
  unless $src
  {
    say "  ?     {$caminho} -- nao consegui ler";
    return False;
  }
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

my @arquivos = @*ARGS || 'exemplos/saldo.tlpp';
my $ok = 0;
$ok++ for @arquivos.grep({ testa($_) });
say "\n  $ok de {@arquivos.elems}";
exit($ok == @arquivos.elems ?? 0 !! 1);
