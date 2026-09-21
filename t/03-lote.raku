use lib 'lib';
use XC::Grammar;

# Quantos arquivos de um diretorio a gramatica aceita por inteiro.
#
#   rakupp t/03-lote.raku /caminho/para/uns/fontes
#
# Sem argumento, usa exemplos/. O numero que interessa e o de codigo de
# verdade: contra 59 arquivos publicos, 3 casavam quando isto foi escrito.
#
# Le .xtpl e tambem .tlpp e .prw: o xtpl e o TL++ com extensoes, entao todo
# TL++ valido tem de casar aqui.
my $dir = @*ARGS[0] // 'exemplos';

unless $dir.IO.d
{
  say "  $dir nao e um diretorio";
  exit 1;
}

my ($ok, $no) = 0, 0;
my @falhas;

for $dir.IO.dir.grep({ .extension.lc eq 'xtpl' | 'tlpp' | 'prw' }).sort -> $f
{
  my $src = try slurp($f.Str);
  next unless $src;
  if XC::Grammar.parse($src)
  {
    $ok++;
  }
  else
  {
    $no++;
    @falhas.push($f.basename);
  }
}

say "  primeiras falhas: ", @falhas.head(5).join(', ') if @falhas;
say "\n  $ok de {$ok + $no}";
exit($no == 0 ?? 0 !! 1);
