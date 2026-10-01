# run-protheus.raku. No AppServer here: a stand-in takes its place -- a shell
# script that writes down how it was called and answers as the self-tests
# would -- so what is checked is what the script asks of the AppServer and
# what it makes of the answers. Most cases start from a build folder already
# up to date, so that bin/xc is not run for each: that part has cases of its
# own. (The self-test itself is checked with the corpus, in t/31: compiled,
# no warning, read back.)

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- the script, against a stand-in AppServer ----------------------------------------------------
if $*DISTRO.is-win
{
  say '  (the stand-in AppServer is a shell script: its cases are for Linux)';
  say "\n  $ok of $total";
  exit($ok == $total ?? 0 !! 1);
}

# 'rm -rf' in Raku.
sub remove-tree(IO::Path $p)
{
  return unless $p.e;
  if $p.d
  {
    remove-tree($_) for $p.dir;
    $p.rmdir;
  }
  else
  {
    $p.unlink;
  }
}

my $dir = $*TMPDIR.add("xc-protheus-$*PID");
mkdir $dir;
my $log = $dir.add('calls.log');
my $fake = $dir.add('appsrvlinux');
spurt $fake, q:to/END/;
  #!/bin/sh
  # As the AppServer: a start-up banner and memory pools around what
  # matters; the sources counted in the folder it is given; on an error, the
  # failed source in the Error List and compile_errors.log where it runs.
  echo "$@" >> "$FAKE_LOG"
  case "$1" in
    -compile)
      dir="${2#-files=}"
      # Every file in the folder: what the AppServer seemed to do with a log
      # left there.
      n=$(ls "$dir" | wc -l)
      [ -n "$FAKE_EXTRA" ] && n=$((n + 1))
      echo "[INFO ][SERVER] TOTVS Application Server Initializing..."
      echo "    pooltString ...        0.12 MB. Count    625 Ok"
      echo "[CMDLINE] Starting source compilation [selftest.tlpp]"
      if [ -n "$FAKE_NO_RESULTS" ]; then echo "THREAD ERROR: include not found"
      elif [ -n "$FAKE_ERRORS" ]; then
        echo "[CMDLINE] Compilation Results .: Total sources($n) Success($((n - 1))) Errors(1)"
        echo "[CMDLINE] Error List ..........: XC_SELFTEST.TLPP"
        echo "XC_SELFTEST.TLPP(12) C2030 Syntax error" > compile_errors.log
      elif [ -n "$FAKE_FEWER" ]; then echo "[CMDLINE] Compilation Results .: Total sources($((n - 1))) Success($((n - 1))) Errors(0)"
      else
        echo "[CMDLINE] Compilation Results .: Total sources($n) Success($n) Errors(0)"
        echo "[CMDLINE] Error List ..........:"
      fi
      echo "[CMDLINE] See more details in the output files: compile_success.log compile_errors.log"
      echo "                 SymTab List ...         2.56 MB. Count 143386 Hits 324585"
      exit ${FAKE_COMPILE_EXIT:-0} ;;
    -run=u_selftest) echo "TOTVS AppServer"; echo "selftest: 47 ok, 0 falhas" ;;
    -run=u_xc_selftest)
      if [ -n "$FAKE_BAD" ]; then echo "FAILED  aPick: one element  (seen: 0)"; echo "xc_selftest: 43 ok, 1 failed"
      elif [ -n "$FAKE_CRASH" ]; then echo "THREAD ERROR: variable does not exist"; exit 1
      else echo "xc_selftest: 44 ok, 0 failed"; fi ;;
  esac
  END
run 'chmod', '+x', ~$fake;
my $out = $dir.add('build');

# A build folder that is up to date: the two .tlpp files newer than
# everything, with a text bin/xc would never write.
sub seed()
{
  mkdir $out;
  spurt $out.add($_), "placeholder\n" for <selftest.tlpp xc_selftest.tlpp>;
}
sub placeholder(Str $file --> Bool) { $out.add($file).slurp eq "placeholder\n" }
seed;

# The script run with these arguments and settings: exit code, output, and the
# AppServer's calls, one per line.
sub protheus(*@args, *%env)
{
  $log.unlink if $log.e;
  my %e = %*ENV;
  %e{$_}:delete for <XC_APPSERVER XC_ENV XC_INCLUDES XC_AUTHORIZATION>;
  %e<FAKE_LOG> = ~$log;
  %e{.key} = .value for %env;
  my $p = run $*EXECUTABLE, 'run-protheus.raku', |@args, :out, :err, :env(%e);
  my $text = $p.out.slurp(:close) ~ $p.err.slurp(:close);
  %(code => $p.exitcode, :$text, calls => ($log.e ?? $log.lines.List !! ()))
}
my @base = "--appserver=$fake", '--env=TST', '--includes=/inc', "--out=$out";

check 'all passes: the AppServer compiles the folder -- both, and the runtime copied in -- then runs each',
{
  my %r = protheus(|@base);
  my $files = $out.absolute;
  %r<code> == 0 && %r<calls> eqv ("-compile -files=$files -includes=/inc -env=TST",
                                  '-run=u_selftest -env=TST', '-run=u_xc_selftest -env=TST')
    && %r<text>.contains('selftest: 47 ok, 0 falhas') && %r<text>.contains('xc_selftest: 44 ok, 0 failed')
    && $out.add('xtpl_runtime.tlpp').slurp eq 'runtime/xtpl_runtime.tlpp'.IO.slurp
    && %r<text>.contains('every check passed')
};
check 'another source in the folder is removed: the AppServer would compile it too',
{
  spurt $out.add('stray.prw'), "user function stray()\nreturn 1\n";
  my %r = protheus(|@base, '--compile-only');
  my $gone = !$out.add('stray.prw').e;
  %r<code> == 0 && $gone && %r<text>.contains('removed stray.prw')
};
check 'up to date: bin/xc is not run, the files are left as they are',
{
  my %r = protheus(|@base, '--compile-only');
  %r<text>.contains('54_selftest.xtpl: up to date') && %r<text>.contains('xc_selftest.xtpl: up to date')
    && placeholder('selftest.tlpp') && placeholder('xc_selftest.tlpp')
};
check 'one older than its source: only that one is compiled again',
{
  run 'touch', '-d', '2000-01-01', ~$out.add('xc_selftest.tlpp');
  my %r = protheus(|@base, '--compile-only');
  %r<code> == 0 && placeholder('selftest.tlpp') && $out.add('xc_selftest.tlpp').slurp.contains('user function xc_selftest')
};
check '--rebuild: bin/xc compiles both, up to date or not',
{
  seed;
  my %r = protheus(|@base, '--compile-only', '--rebuild');
  my $ok = %r<code> == 0 && $out.add('selftest.tlpp').slurp.contains('user function selftest')
           && $out.add('xc_selftest.tlpp').slurp.contains('user function xc_selftest');
  seed;
  $ok
};
check 'an authorization file goes to the compile',
{
  protheus(|@base, '--authorization=/x/key.aut')<calls>[0].ends-with('-env=TST -authorization=/x/key.aut')
};
check 'a check that fails: shown, and the exit code is 1',
{
  my %r = protheus(|@base, FAKE_BAD => 1);
  %r<code> == 1 && %r<text>.contains('FAILED  aPick: one element  (seen: 0)') && %r<text>.contains('1 failed')
};
check 'a self-test that stops before its total: what the AppServer said, and 1',
{
  my %r = protheus(|@base, FAKE_CRASH => 1);
  %r<code> == 1 && %r<text>.contains('THREAD ERROR: variable does not exist')
    && %r<text>.contains('no total from u_xc_selftest')
};
check "the compile's results line: errors, even with exit code 0 -- what failed, why, nothing runs, and 1",
{
  my %r = protheus(|@base, FAKE_ERRORS => 1);
  %r<code> == 1 && %r<calls>.elems == 1 && %r<text>.contains('compiled with 1 error(s)')
    && %r<text>.contains('Total sources(3) Success(2) Errors(1)') && %r<text>.contains('Error List ..........: XC_SELFTEST.TLPP')
    && %r<text>.contains('XC_SELFTEST.TLPP(12) C2030 Syntax error')
};
check "only what matters is shown -- not the banner, not the memory pools -- and all of it goes to compile.log",
{
  my %r = protheus(|@base, '--compile-only');
  my $log = $out.parent.add('logs').add($out.basename).add('compile.log');
  %r<code> == 0 && %r<text>.contains('Total sources(3) Success(3) Errors(0)') && !%r<text>.contains('pooltString')
    && !%r<text>.contains('Error List') && $log.e && $log.slurp.contains('pooltString')
};
check "the folder compiled holds the sources only: the logs go to build/logs/, an old one there is removed",
{
  spurt $out.add('compile.log'), 'from an earlier version';
  my %r = protheus(|@base);
  my @in = $out.dir.map(*.basename).sort;
  my $logs = $out.parent.add('logs').add($out.basename);
  %r<code> == 0 && @in eqv ['selftest.tlpp', 'xc_selftest.tlpp', 'xtpl_runtime.tlpp']
    && $logs.add('compile.log').e && $logs.add('run-u_selftest.log').e && $logs.add('run-u_xc_selftest.log').e
};
check "two problems at once: both said -- an error, and a count that is off",
{
  my %r = protheus(|@base, FAKE_ERRORS => 1, FAKE_EXTRA => 1);
  %r<code> == 1 && %r<text>.contains('compiled with 1 error(s)') && %r<text>.contains('3 sources in the folder, the AppServer counted 4')
};
check "--verbose shows all of it",
{
  protheus(|@base, '--compile-only', '--verbose')<text>.contains('pooltString')
};
check 'no results line: the compile did not finish -- what it said, and 1',
{
  my %r = protheus(|@base, FAKE_NO_RESULTS => 1);
  %r<code> == 1 && %r<calls>.elems == 1 && %r<text>.contains('THREAD ERROR: include not found')
    && %r<text>.contains("no 'Compilation Results' line")
};
check 'fewer sources compiled than in the folder: 1',
{
  my %r = protheus(|@base, FAKE_FEWER => 1);
  %r<code> == 1 && %r<text>.contains('3 sources in the folder, the AppServer counted 2')
};
check 'a clean results line but a failing exit code: 1',
{
  my %r = protheus(|@base, FAKE_COMPILE_EXIT => 3);
  %r<code> == 1 && %r<calls>.elems == 1 && %r<text>.contains('exit code 3')
};
check 'the settings from the environment: XC_APPSERVER, XC_ENV, XC_INCLUDES',
{
  my %r = protheus("--out=$out", XC_APPSERVER => ~$fake, XC_ENV => 'ENV2', XC_INCLUDES => '/inc2');
  %r<code> == 0 && %r<calls>[0].ends-with('-includes=/inc2 -env=ENV2') && %r<calls>[1] eq '-run=u_selftest -env=ENV2'
};
check "--corpus: xc compiles xtpl's corpus into one folder, the AppServer compiles it in one run, nothing runs",
{
  my $c = $dir.add('corpus');
  my %r = protheus("--appserver=$fake", '--env=TST', '--includes=/inc', "--out=$c", '--corpus');
  my @made = $c.dir.grep(*.extension eq 'tlpp').map(*.basename);
  %r<code> == 0 && %r<calls> eqv ("-compile -files={$c.absolute} -includes=/inc -env=TST",)
    && @made.elems == 74 && $c.dir.elems == 74 && $dir.add('logs/corpus/xc.log').e && @made.grep('xtpl_runtime.tlpp') && !@made.grep('54_selftest.tlpp')
    && !@made.grep('51_legacy.tlpp') && %r<text>.contains('Protheus took all 73 programs, and the runtime')
};
check '--compile-only runs nothing; --run-only compiles nothing',
{
  my %c = protheus(|@base, '--compile-only');
  my %r = protheus("--appserver=$fake", '--env=TST', "--out={$dir.add('runonly')}", '--run-only');
  %c<code> == 0 && %c<calls>.elems == 1 && %c<calls>[0].starts-with('-compile')
    && %r<code> == 0 && %r<calls> eqv ('-run=u_selftest -env=TST', '-run=u_xc_selftest -env=TST')
};
check 'a wrong command line: 2 -- no environment, no includes to compile with, an unknown option, --corpus --run-only',
{
  protheus("--appserver=$fake", '--includes=/inc')<code> == 2
    && protheus("--appserver=$fake", '--env=TST')<code> == 2
    && protheus(|@base, '--envv=X')<code> == 2
    && protheus(|@base, '--corpus', '--run-only')<code> == 2
};

remove-tree($dir);

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
