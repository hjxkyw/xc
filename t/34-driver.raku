use lib 'lib';

# bin/xc's command line: one source, a source and its output, several sources,
# folders, --check. What fails is reported and the rest goes on; the exit code
# is 0 when all went well, 1 when a file failed, 2 when the command line itself
# is wrong.

my $dir = $*TMPDIR.add("xc-driver-$*PID");
sub reset-dir()
{
  run 'rm', '-rf', ~$dir;
  mkdir $dir.add('src/sub');
  spurt $dir.add('src/a.xtpl'), "user function a()\n  local n := 1\nreturn n\n";
  spurt $dir.add('src/sub/b.xtpl'), "user function b()\n  local n := 0\n  n := cFilAnt\nreturn n\n";
  spurt $dir.add('src/sub/c.xtpl'), "user function c()\n  local n := := 1\nreturn n\n";
  spurt $dir.add('src/notes.txt'), "not a source\n";
}

sub xc(*@args)
{
  my $p = run $*EXECUTABLE, 'bin/xc', |@args, :out, :err;
  my $out = $p.out.slurp(:close);
  my $err = $p.err.slurp(:close);
  %(code => $p.exitcode, :$out, :$err)
}

# The .tlpp files under src/, as one string ('a.tlpp b.tlpp').
sub written() { $dir.add('src').dir.map({ .d ?? |.dir !! $_ }).grep(*.extension eq 'tlpp').map(*.basename).sort.join(' ') }

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- --check ------------------------------------------------------------------------------
reset-dir;
check '--check: a clean file is ok, and nothing is written',
{
  my %r = xc('--check', "$dir/src/a.xtpl");
  %r<code> == 0 && %r<out>.contains('a.xtpl: ok') && !written()
};
check '--check: a warning is printed, and it is still ok',
{
  my %r = xc('--check', "$dir/src/sub/b.xtpl");
  %r<code> == 0 && %r<err>.contains("b.xtpl:3: warning: 'cFilAnt' is not declared") && %r<out>.contains('b.xtpl: ok')
};
check '--check: a file that does not parse fails, with its line',
{
  my %r = xc('--check', "$dir/src/sub/c.xtpl");
  %r<code> == 1 && %r<err>.contains('c.xtpl:2: cannot parse this line')
};
check '--check: what the checks refuse fails, with its line: a <const> assigned, a chain where it cannot run',
{
  spurt $dir.add('src/d.xtpl'), "user function d()\n  local nL <const> := 1\n  nL := 2\nreturn nL\n";
  spurt $dir.add('src/e.xtpl'), "user function e(a)\n  local n := 0\n  while (lines(\"y.txt\") |> count) > n\n    n := n + 1\n  enddo\nreturn n\n";
  my %d = xc('--check', "$dir/src/d.xtpl");
  my %e = xc('--check', "$dir/src/e.xtpl");
  $dir.add('src/d.xtpl').unlink;
  $dir.add('src/e.xtpl').unlink;
  %d<code> == 1 && %d<err>.contains('<const>') && %e<code> == 1 && %e<err>.contains('runs as a loop, before its statement')
};

# ---- several sources, folders ------------------------------------------------------------------
check 'a folder: every .xtpl under it, a bad one reported, the others compiled, a summary',
{
  my %r = xc("$dir/src");
  %r<code> == 1 && written() eq 'a.tlpp b.tlpp' && %r<out>.contains('xc: 3 files, 2 compiled, 1 failed')
    && %r<err>.contains('c.xtpl:2: cannot parse')
};
reset-dir;
check '--check on a folder: the same, and nothing written',
{
  my %r = xc('--check', "$dir/src");
  %r<code> == 1 && !written() && %r<out>.contains('xc: 3 files, 2 checked ok, 1 failed')
};
check 'two sources: each next to itself',
{
  my %r = xc("$dir/src/a.xtpl", "$dir/src/sub/b.xtpl");
  %r<code> == 0 && written() eq 'a.tlpp b.tlpp' && %r<out>.contains('xc: 2 files, 2 compiled')
};
reset-dir;
check 'a source that is not there: reported, and the others go on',
{
  my %r = xc("$dir/src/a.xtpl", "$dir/nowhere.xtpl");
  %r<code> == 1 && %r<err>.contains('nowhere.xtpl: no such file') && written() eq 'a.tlpp'
};
check 'a folder with no .xtpl in it',
{
  mkdir $dir.add('empty');
  my %r = xc("$dir/empty");
  %r<code> == 1 && %r<err>.contains('empty: no .xtpl files in it')
};

# ---- one source and its output --------------------------------------------------------------
reset-dir;
check "'file.xtpl out.tlpp' still names the output",
{
  my %r = xc("$dir/src/a.xtpl", "$dir/out.tlpp");
  %r<code> == 0 && $dir.add('out.tlpp').e && written() eq ''
};

# ---- the command line itself -----------------------------------------------------------------
check 'a wrong command line exits with 2: --check with an output, an unknown option, nothing given',
{
  xc('--check', "$dir/src/a.xtpl", "$dir/x.tlpp")<code> == 2
    && xc('--chek', "$dir/src/a.xtpl")<code> == 2
    && xc()<code> == 2
};

# ---- the test runner ------------------------------------------------------------------------
# Only the refusals: running it for real would run this very suite.
check "run-tests.raku: an option it does not know is refused before any test runs, '-all' with a hint",
{
  my $p = run $*EXECUTABLE, 'run-tests.raku', '-all', :out, :err;
  my $out = $p.out.slurp(:close);
  my $err = $p.err.slurp(:close);
  my $q = run $*EXECUTABLE, 'run-tests.raku', '--quick', :out, :err;
  $q.out.slurp(:close);
  my $qerr = $q.err.slurp(:close);
  $p.exitcode == 2 && !$out.contains('ok ') && $err.contains("-all: no such option -- '--all', with two dashes")
    && $q.exitcode == 2 && $qerr.contains('--quick: no such option') && !$qerr.contains('two dashes')
};
check 'run-tests.raku --help: the usage, and 0',
{
  my $p = run $*EXECUTABLE, 'run-tests.raku', '--help', :out, :err;
  my $out = $p.out.slurp(:close);
  $p.err.slurp(:close);
  $p.exitcode == 0 && $out.contains('usage: rakupp run-tests.raku [--all]')
};

run 'rm', '-rf', ~$dir;

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
