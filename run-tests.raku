# Runs the tests in t/ and adds up the "N of M" lines.
#
#   rakupp run-tests.raku          all but the slow ones -- each with its time
#   rakupp run-tests.raku --all    all of them -- before a push
#   rakupp run-tests.raku --jobs=4 four test files at a time
#
# The files run several at a time -- as many as the machine has cores, unless
# --jobs says otherwise; --jobs=1 runs them one after another. Each is a
# process of its own, and each that writes files does so in a folder named
# for its process, so they do not meet. The results come out in the files'
# order, as each is done.
#
# A test is slow when a line near its top says so: '# slow: <why>'. Left out,
# it is named at the end, so a quick run never passes for a full one.
#
# Anything else on the command line is refused before a test runs, with exit
# code 2: a mistyped '-all' used to be ignored, and a quick run passed for a
# full one.
#
# Each test ends with a line "  N of M" and exits with 1 if N < M. A test
# counts as failed if its tally does not add up, if it exits with a non-zero
# code, or if it prints no tally at all -- that last one catches a test that
# died halfway, or a new test that forgot to count.

my $usage = 'usage: rakupp run-tests.raku [--all] [--jobs=N]';
my $jobs = $*KERNEL.cpu-cores // 1;
for @*ARGS -> $a
{
  next if $a eq '--all';
  if $a ~~ / ^ '--jobs=' (\d+) $ / && +$0 >= 1
  {
    $jobs = +$0;
    next;
  }
  if $a.starts-with('--jobs')
  {
    note "$a: --jobs takes how many files at a time, 1 or more: --jobs=4\n$usage";
    exit 2;
  }
  if $a eq '--help'
  {
    say $usage;
    exit 0;
  }
  # '-all', 'all', '---all': what was meant, most likely.
  my $hint = $a.subst(/ ^ '-'* /, '') eq 'all' ?? " -- '--all', with two dashes" !! '';
  note "$a: no such option$hint\n$usage";
  exit 2;
}
my $all = so @*ARGS.first('--all');
my $root = $*PROGRAM.IO.absolute.IO.parent;
my @tests = $root.add('t').dir.grep(*.extension eq 'raku').sort;

# The names in a column as wide as the longest, slow ones included, so the
# counts line up the same in a quick run and a full one.
my $width = @tests.map(*.basename.chars).max + 2;

# A '# slow: ...' line among the first ten.
sub slow(IO::Path $t --> Bool)
{
  so $t.lines.head(10).first(/ ^ '#' \h* 'slow:' /)
}
my @slow = $all ?? () !! @tests.grep({ slow($_) });
@tests = @tests.grep({ $_ !(elem) @slow });

my ($ok, $total) = 0, 0;
my @failed;
my @times;                                   # file => seconds
my $started = now;

# The workers: each takes the next file, runs it, and leaves the result.
my $lock = Lock.new;
my @queue = @tests;
my %result;
my @workers = (^min($jobs, @tests.elems max 1)).map: -> $
{
  start
  {
    loop
    {
      my $t = $lock.protect({ @queue ?? @queue.shift !! Nil });
      last unless $t.defined;
      my $t0 = now;
      my $p = run $*EXECUTABLE, $t.relative($root), :cwd($root.Str), :merge;
      my $output = $p.out.slurp(:close);
      my $code = $p.exitcode;
      $lock.protect({ %result{$t.basename} = %(:$output, :$code, secs => now - $t0) });
    }
  }
};

# In the files' order, each as soon as it is done.
for @tests -> $t
{
  my %r;
  until %r
  {
    %r = $lock.protect({ %result{$t.basename}:exists ?? %result{$t.basename} !! () });
    sleep 0.02 unless %r;
  }
  my $output = %r<output>;
  my $code = %r<code>;
  my $secs = %r<secs>;
  @times.push($t.basename => $secs);

  my $tally = $output.lines.grep(/\S/).tail;
  my ($n, $m);
  if $tally && $tally ~~ /^ \s* (\d+) \s+ 'of' \s+ (\d+) \s* $/
  {
    ($n, $m) = +$0, +$1;
  }

  my $passed = $m.defined && $n == $m && $code == 0;
  my $count = $m.defined ?? "$n of $m" !! 'no tally';
  $count ~= " (exited with $code)" if $code != 0;

  # The time each file took: a slow one shows at a glance.
  say(($passed ?? '  ok    ' !! '  FAIL  '), $t.basename.fmt("%-{$width}s"), $count.fmt('%-26s'),
      $secs.fmt('%6.1f s'));

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
await @workers;

for @failed -> $f
{
  say "\n--- {$f.key}";
  print $f.value;
}

say "\n  files that failed: {@failed.map(*.key).join(', ')}" if @failed;
say "\n  left out, slow: {@slow.map(*.basename).join(', ')} -- 'rakupp run-tests.raku --all' runs them" if @slow;
say "\n  $ok of $total, in {(now - $started).fmt('%.1f')} s, {$jobs == 1 ?? 'one file at a time' !! "up to $jobs files at a time"}";
# The three slowest, when there is more than one file.
if @times > 1
{
  my @slowest = @times.sort(-*.value).head(3);
  say "  the slowest: {@slowest.map({ "{.key} {.value.fmt('%.1f')} s" }).join(', ')}";
}
exit(@failed ?? 1 !! 0);
