use lib 'lib';
use XC::Grammar;

# A whole file, start to end. By default the example that ships with this;
# pass paths on the command line to test your own.
sub check-file($path)
{
  my $src = try slurp($path);
  unless $src
  {
    say "  ?     {$path} -- could not read it";
    return False;
  }
  my $m = XC::Grammar.parse($src);
  if $m
  {
    say "  ok    {$path.IO.basename}  ({$src.lines.elems} lines, ",
        "{$m<toplevel>.elems} top-level items)";
    return True;
  }
  say "  FAIL  {$path.IO.basename}";
  return False;
}

my @files = @*ARGS || 'examples/saldo.xtpl';
my $ok = 0;
$ok++ for @files.grep({ check-file($_) });
say "\n  $ok of {@files.elems}";
exit($ok == @files.elems ?? 0 !! 1);
