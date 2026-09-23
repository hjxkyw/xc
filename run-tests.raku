# Runs everything in t/ and adds up the "N of M" lines.
#
#   rakupp run-tests.raku
#
# Each test ends with a line "  N of M" and exits with 1 if N < M. A test
# counts as failed if its tally does not add up, if it exits with a non-zero
# code, or if it prints no tally at all -- that last one catches a test that
# died halfway, or a new test that forgot to count.

my $root = $*PROGRAM.IO.absolute.IO.parent;
my @tests = $root.add('t').dir.grep(*.extension eq 'raku').sort;

my ($ok, $total) = 0, 0;
my @failed;

for @tests -> $t
{
  my $p = run $*EXECUTABLE, $t.relative($root), :cwd($root.Str), :merge;
  my $output = $p.out.slurp(:close);
  my $code = $p.exitcode;

  my $tally = $output.lines.grep(/\S/).tail;
  my ($n, $m);
  if $tally && $tally ~~ /^ \s* (\d+) \s+ 'of' \s+ (\d+) \s* $/
  {
    ($n, $m) = +$0, +$1;
  }

  my $passed = $m.defined && $n == $m && $code == 0;
  my $count = $m.defined ?? "$n of $m" !! 'no tally';
  $count ~= " (exited with $code)" if $code != 0;

  say(($passed ?? '  ok    ' !! '  FAIL  '), $t.basename.fmt('%-26s'), $count);

  if $m.defined
  {
    $ok += $n;
    $total += $m;
  }
  unless $passed
  {
    @failed.push($t.basename => $output);
  }
}

for @failed -> $f
{
  say "\n--- {$f.key}";
  print $f.value;
}

say "\n  files that failed: {@failed.map(*.key).join(', ')}" if @failed;
say "\n  $ok of $total";
exit(@failed ?? 1 !! 0);
