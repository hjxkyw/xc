# xc's output, compiled and run by a Protheus AppServer.
#
#   rakupp run-protheus.raku --env=NAME --includes=PATH [--appserver=PATH]
#                            [--authorization=FILE] [--out=DIR] [--rebuild]
#                            [--compile-only | --run-only | --corpus] [--verbose]
#
# The self-tests (the default):
#
# 1. bin/xc compiles the two self-tests -- xtpl's xtpl/tests/54_selftest.xtpl
#    and xc's own protheus/xc_selftest.xtpl -- into build/protheus/: each
#    only when its .tlpp is missing, or older than its source, bin/xc or
#    anything in lib/XC/ (a few seconds each); --rebuild compiles both anyway.
# 2. The AppServer compiles them, with runtime/xtpl_runtime.tlpp -- copied in
#    beside them, so that build/protheus/ holds exactly the three -- into the
#    environment's RPO, given the folder:
#      appserver -compile -files=<folder> -includes=<path> -env=<name>
#                [-authorization=<file>]
#    (-files takes a file, a folder, or a .lst of one line with files and
#    folders separated by ';'; a list with ';' on the command line does not
#    work. -outreport is not used: the console says it all.)
# 3. It runs each one:
#      appserver -run=u_selftest -env=<name>
#      appserver -run=u_xc_selftest -env=<name>
#    Each prints a line per failed check and a total; this shows those and
#    reads the totals.
#
# The corpus (--corpus): bin/xc compiles every program of xtpl's corpus --
# its tests and its examples, but 51_legacy (xtpl's legacy mode) and
# 54_selftest (the self-tests' own) -- into build/corpus/, in one run, and
# the AppServer compiles that folder, with the runtime, in one run too.
# Nothing is run: what it checks is that Protheus takes all of xc's output.
#
# What the AppServer says goes whole into a log -- build/logs/<folder>/
# compile.log, run-u_selftest.log, ...; never in the folder it compiles,
# which it would take for one more source -- and only what matters is shown: the
# sources that did not compile and why, the results line, each failed check,
# the totals. --verbose shows all of it as it comes.
#
# Exit code: 0 when everything compiled and no check failed; 1 when something
# failed; 2 when the command line is wrong.
#
# Every option can come from the environment instead, so that once set a run
# is just 'rakupp run-protheus.raku': XC_APPSERVER, XC_ENV, XC_INCLUDES,
# XC_AUTHORIZATION. --appserver defaults to appserver.exe on Windows and
# appsrvlinux elsewhere, found on the PATH; given as a path, the AppServer is
# started from its own folder, where its appserver.ini is.

my %opt =
  appserver     => %*ENV<XC_APPSERVER> // ($*DISTRO.is-win ?? 'appserver.exe' !! 'appsrvlinux'),
  env           => %*ENV<XC_ENV>,
  includes      => %*ENV<XC_INCLUDES>,
  authorization => %*ENV<XC_AUTHORIZATION>,
  out           => Str;
my ($compile, $run, $rebuild, $corpus, $verbose) = True, True, False, False, False;

sub usage(Str $why)
{
  note "$why\n"
     ~ "usage: rakupp run-protheus.raku --env=NAME --includes=PATH [--appserver=PATH]\n"
     ~ "                                [--authorization=FILE] [--out=DIR] [--rebuild]\n"
     ~ "                                [--compile-only | --run-only | --corpus] [--verbose]";
  exit 2;
}

for @*ARGS -> $a
{
  if $a eq '--compile-only'  { $run = False }
  elsif $a eq '--run-only'   { $compile = False }
  elsif $a eq '--rebuild'    { $rebuild = True }
  elsif $a eq '--corpus'     { $corpus = True }
  elsif $a eq '--verbose'    { $verbose = True }
  elsif $a ~~ / ^ '--' (appserver || env || includes || authorization || out) '=' (.+) $ / { %opt{~$0} = ~$1 }
  else                       { usage("$a: no such option") }
}
usage("--compile-only and --run-only together leave nothing to do") unless $compile || $run;
usage("--corpus only compiles: not with --run-only") if $corpus && !$compile;
$run = False if $corpus;
usage("no environment: --env=NAME, or XC_ENV") unless %opt<env>;
usage("no include folder: --includes=PATH, or XC_INCLUDES") if $compile && !%opt<includes>;

# Everything from the top of the repository, wherever this is run from.
my $root = $*PROGRAM.IO.absolute.IO.parent;
%opt<out> //= $corpus ?? 'build/corpus' !! 'build/protheus';
my $out = %opt<out>.IO.is-absolute ?? %opt<out>.IO !! $root.add(%opt<out>);
# The logs: beside the compiled folder, not in it -- the AppServer compiles a
# folder whole, and counted a log there as one more source.
my $logs = $out.parent.add('logs').add($out.basename);

# A path as the system writes it: on Windows, '\' throughout -- not the
# 'xc/build/protheus' a join leaves.
sub native($p --> Str)
{
  my $s = $p.IO.absolute.Str;
  $*DISTRO.is-win ?? $s.subst('/', '\\', :g) !! $s
}

# Relative inside the repository, whole outside it.
sub shown($p --> Str)
{
  my $s = $p.IO.absolute.Str;
  $s.starts-with($root.Str) ?? $p.IO.absolute.IO.relative($root) !! native($p)
}

# The self-tests: the source, the file bin/xc writes, the function to run.
my @tests =
  %(source => 'xtpl/tests/54_selftest.xtpl', file => 'selftest.tlpp',    run => 'u_selftest'),
  %(source => 'protheus/xc_selftest.xtpl', file => 'xc_selftest.tlpp', run => 'u_xc_selftest');

# The AppServer: a path is started from its own folder, a bare name from here.
my $server = %opt<appserver>;
my $cwd = $server.contains('/') || $server.contains('\\') ?? $server.IO.absolute.IO.parent.Str !! $*CWD.Str;

# The AppServer run with these arguments; all it says goes into $log, and is
# shown too with --verbose.
sub appserver(IO::Path $log, *@args)
{
  say "  \$ {$server} {@args.join(' ')}";
  my $p = run $server, |@args, :cwd($cwd), :merge;
  my $text = $p.out.slurp(:close);
  spurt $log, $text;
  print $text.lines.map({ "    $_\n" }).join if $verbose;
  ($p.exitcode, $text)
}

# The lines of a compile worth showing: a source that failed, an error, the
# results and the list of what failed. Not the start-up banner, the memory
# pools, the threads stopping.
sub worth-showing(Str $l --> Bool)
{
  return True if $l.contains('Compilation Results');
  return so $l ~~ / ':' \h* \S / if $l.contains('Error List');
  return False if $l ~~ / 'Errors(' | 'compile_errors.log' | 'compile_success.log' /;
  so $l ~~ m:i/ error | fail | warning: /
}

# The folder compiled by the AppServer, $count sources in it. Shows what
# matters, and returns why it failed -- or Str, when it did not.
sub compile-folder(IO::Path $dir, Int $count --> Str)
{
  # The AppServer writes compile_errors.log where it runs; its time before
  # tells a new one from an old one (a file's time against a file's time:
  # 'now' may run on another scale).
  my $errors = $cwd.IO.add('compile_errors.log');
  my $before = $errors.e ?? $errors.modified !! Instant;
  mkdir $logs;
  my $log = $logs.add('compile.log');
  my ($code, $text) = appserver($log, '-compile', "-files={native($dir)}", "-includes={%opt<includes>}",
                                "-env={%opt<env>}", |(%opt<authorization> ?? "-authorization={%opt<authorization>}" !! ()));
  unless $verbose
  {
    say "    $_" for $text.lines.map(*.trim).grep({ worth-showing($_) });
  }
  say "    the AppServer's whole output: {shown($log)}";
  # Its results line -- not the exit code alone -- says whether it compiled:
  # every source in the folder, none with an error.
  my $results = $text ~~ / 'Compilation Results' \N*? 'Total sources(' (\d+) ')' \h* 'Success(' (\d+) ')'
                           \h* 'Errors(' (\d+) ')' /;
  if $results && +$results[2]
  {
    # Why, from the file the AppServer writes in the folder it ran in -- if
    # this run wrote it.
    if $errors.e && (!$before.defined || $errors.modified != $before)
    {
      say "    {shown($errors)}:";
      say "      $_" for $errors.lines.grep(*.trim);
    }
  }
  # Every problem, not just the first: an error must not hide a count that is
  # off, nor the other way round.
  return "no 'Compilation Results' line from the AppServer: its compile did not finish" unless $results;
  my @why;
  @why.push("the AppServer compiled with {+$results[2]} error(s)") if +$results[2];
  @why.push("$count sources in the folder, the AppServer counted {+$results[0]}") if +$results[0] != $count;
  @why.push("{+$results[1]} of {+$results[0]} sources compiled") if !+$results[2] && +$results[1] != +$results[0];
  @why.push("the AppServer's compile ended with exit code $code") if $code && !@why;
  @why ?? @why.join("\n  ") !! Str
}

# The runtime goes into the folder beside the sources, and nothing else may
# be there: the AppServer would compile it too.
sub prepare-folder(IO::Path $dir, @ours)
{
  my $runtime = $root.add('runtime/xtpl_runtime.tlpp');
  my $copy = $dir.add('xtpl_runtime.tlpp');
  $runtime.copy($copy) if !$copy.e || $copy.modified < $runtime.modified || $copy.s != $runtime.s;
  my %ours = (|@ours, 'xtpl_runtime.tlpp').map(*.lc => True);
  # Logs an earlier version wrote here: the AppServer would take them too.
  .unlink for $dir.dir.grep({ .f && (.basename eq 'compile.log' | 'xc.log' || .basename ~~ / ^ 'run-' .* '.log' $ /) });
  for $dir.dir.grep({ .f && .extension.lc (elem) <tlpp prw prx tlh ch th lst> && !%ours{.basename.lc} }) -> $stray
  {
    say "  removed {$stray.basename}: only what xc wrote here, and the runtime, is compiled from here";
    $stray.unlink;
  }
  %ours.elems
}

# ---- the corpus --------------------------------------------------------------
if $corpus
{
  my @sources = |$root.add('xtpl/tests').dir.grep({ .extension eq 'xtpl'
                                                    && .basename ne '51_legacy.xtpl' && .basename ne '54_selftest.xtpl' }),
                |$root.add('xtpl/examples').dir.grep(*.d).map({ |.dir.grep(*.extension eq 'xtpl') });
  @sources = @sources.sort;
  say "xc: compiling {+@sources} programs of xtpl's corpus into {shown($out)}/";
  mkdir $out;
  my $p = run $*EXECUTABLE, $root.add('bin/xc').Str, "--outdir={$out.absolute}", |@sources.map(*.Str),
              :cwd($root.Str), :merge;
  my $text = $p.out.slurp(:close);
  mkdir $logs;
  spurt $logs.add('xc.log'), $text;
  if $verbose || $p.exitcode
  {
    print $text.lines.map({ "  $_\n" }).join;
  }
  else
  {
    say "  {$text.lines.first(*.starts-with('xc:')) // ''}  (all it said: {shown($logs.add('xc.log'))})";
  }
  if $p.exitcode
  {
    say "\n  xc could not compile all of them";
    exit 1;
  }

  say "\nProtheus: compiling them, with the runtime, into '{%opt<env>}', in one run";
  my $count = prepare-folder($out, @sources.map({ .basename.subst(/ '.xtpl' $ /, '.tlpp') }));
  with compile-folder($out, $count)
  {
    say "\n  $_";
    exit 1;
  }
  say "\n  Protheus took all {$count - 1} programs, and the runtime";
  exit 0;
}

# ---- the self-tests ----------------------------------------------------------
if $compile
{
  say "xc: compiling the self-tests into {shown($out)}/";
  mkdir $out;
  # The newest of what makes the output: bin/xc and the modules.
  my $xc-made = ($root.add('bin/xc'), |$root.add('lib/XC').dir).map(*.modified).max;
  for @tests -> %t
  {
    my $made = $out.add(%t<file>);
    if !$rebuild && $made.e && $made.modified > $root.add(%t<source>).modified && $made.modified > $xc-made
    {
      say "  {%t<source>}: up to date";
      next;
    }
    my $p = run $*EXECUTABLE, $root.add('bin/xc').Str, $root.add(%t<source>).Str, $out.add(%t<file>).Str,
                :cwd($root.Str), :merge;
    my $text = $p.out.slurp(:close);
    print $text.lines.map({ "  $_\n" }).join;
    if $p.exitcode
    {
      say "\n  xc could not compile {%t<source>}";
      exit 1;
    }
  }

  say "\nProtheus: compiling them, with the runtime, into '{%opt<env>}'";
  my $count = prepare-folder($out, @tests.map(*.<file>));
  with compile-folder($out, $count)
  {
    say "\n  $_";
    exit 1;
  }
}

exit 0 unless $run;
mkdir $logs;                                 # when nothing was compiled first

# A total, as both self-tests print it: 'selftest: 71 ok, 0 falhas',
# 'xc_selftest: 55 ok, 0 failed'.
my $failed = 0;
for @tests -> %t
{
  say "\nProtheus: running {%t<run>}";
  my ($code, $text) = appserver($logs.add("run-{%t<run>}.log"), "-run={%t<run>}", "-env={%opt<env>}");
  my @lines = $text.lines;
  my $total = @lines.first({ / \w+ ':' \h* \d+ ' ok, ' \d+ \h+ [ 'falhas' || 'failed' ] / });
  if $total.defined
  {
    # The failed checks, and the total.
    unless $verbose
    {
      say "    $_" for @lines.grep({ .starts-with('FALHA') || .starts-with('FAILED') });
      say "    {$total.trim}";
    }
    my $bad = +($total ~~ / (\d+) \h+ [ 'falhas' || 'failed' ] /)[0];
    $failed += $bad;
  }
  else
  {
    # No total: it did not run to the end. What the AppServer said, whole.
    say "    $_" for @lines;
    say "    no total from {%t<run>} (exit code $code) -- it did not run to the end";
    $failed++;
  }
}

say "\n  {$failed ?? "$failed failed" !! 'every check passed'}";
exit($failed ?? 1 !! 0);
