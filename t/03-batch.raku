use lib 'lib';
use XC::Grammar;

# How many files of a directory the grammar accepts whole.
#
#   rakupp t/03-batch.raku /path/to/some/sources
#
# Without an argument it uses examples/.
#
# It reads .xtpl and also .tlpp and .prw: xtpl is TL++ with extensions, so
# every valid TL++ file has to match here.
my $dir = @*ARGS[0] // 'examples';

unless $dir.IO.d
{
  say "  $dir is not a directory";
  exit 1;
}

my ($ok, $no) = 0, 0;
my @failed;

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
    @failed.push($f.basename);
  }
}

say "  first failures: ", @failed.head(5).join(', ') if @failed;
say "\n  $ok of {$ok + $no}";
exit($no == 0 ?? 0 !! 1);
