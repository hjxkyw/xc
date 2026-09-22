# Roda todos os testes de t/ e soma as linhas "N de M".
#
#   rakupp testes.raku
#
# Cada teste termina com uma linha "  N de M" e sai com 1 se N < M. Um teste
# conta como falho se o placar nao fecha, se ele sai com codigo diferente de 0,
# ou se nao imprime placar nenhum -- este ultimo e o que pega um teste que
# morreu no meio, ou um teste novo que esqueceu de contar.

my $raiz = $*PROGRAM.IO.absolute.IO.parent;
my @testes = $raiz.add('t').dir.grep(*.extension eq 'raku').sort;

my ($ok, $total) = 0, 0;
my @falhas;

for @testes -> $t
{
  my $p = run $*EXECUTABLE, $t.relative($raiz), :cwd($raiz.Str), :merge;
  my $saida = $p.out.slurp(:close);
  my $codigo = $p.exitcode;

  my $placar = $saida.lines.grep(/\S/).tail;
  my ($n, $m);
  if $placar && $placar ~~ /^ \s* (\d+) \s+ 'de' \s+ (\d+) \s* $/
  {
    ($n, $m) = +$0, +$1;
  }

  my $passou = $m.defined && $n == $m && $codigo == 0;
  my $conta = $m.defined ?? "$n de $m" !! 'sem placar';
  $conta ~= " (saiu com $codigo)" if $codigo != 0;

  say(($passou ?? '  ok    ' !! '  FALHA '), $t.basename.fmt('%-24s'), $conta);

  if $m.defined
  {
    $ok += $n;
    $total += $m;
  }
  unless $passou
  {
    @falhas.push($t.basename => $saida);
  }
}

for @falhas -> $f
{
  say "\n--- {$f.key}";
  print $f.value;
}

say "\n  arquivos com falha: {@falhas.map(*.key).join(', ')}" if @falhas;
say "\n  $ok de $total";
exit(@falhas ?? 1 !! 0);
