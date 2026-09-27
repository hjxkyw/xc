# xc's output, compiled and run by a Protheus AppServer.
#
#   rakupp run-protheus.raku --env=NAME --includes=PATH [--appserver=PATH]
#                            [--authorization=FILE] [--out=DIR] [--rebuild]
#                            [--compile-only | --run-only]
#
# 1. bin/xc compiles the two self-tests -- xtpl's xtpl/tests/54_selftest.xtpl
#    and xc's own t/protheus/xc_selftest.xtpl -- into build/protheus/: each
#    only when its .tlpp is missing, or older than its source, bin/xc or
#    anything in lib/XC/ (a few seconds each); --rebuild compiles both anyway.
# 2. The AppServer compiles them, with runtime/xtpl_runtime.tlpp, into the
#    environment's RPO:
#      appserver -compile -files=<file;file;file> -includes=<path> -env=<name>
#                [-authorization=<file>]
# 3. It runs each one:
#      appserver -run=u_selftest -env=<name>
#      appserver -run=u_xc_selftest -env=<name>
#    Each prints a line per failed check and a total; this shows those and
#    reads the totals.
#
# Exit code: 0 when both ran and no check failed; 1 when something failed;
# 2 when the command line is wrong.
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
  out           => 'build/protheus';
my ($compile, $run, $rebuild) = True, True, False;

sub usage(Str $why)
{
  note "$why\n"
     ~ "usage: rakupp run-protheus.raku --env=NAME --includes=PATH [--appserver=PATH]\n"
     ~ "                                [--authorization=FILE] [--out=DIR] [--rebuild] [--compile-only | --run-only]";
  exit 2;
}

for @*ARGS -> $a
{
  if $a eq '--compile-only'  { $run = False }
  elsif $a eq '--run-only'   { $compile = False }
  elsif $a eq '--rebuild'    { $rebuild = True }
  elsif $a ~~ / ^ '--' (appserver || env || includes || authorization || out) '=' (.+) $ / { %opt{~$0} = ~$1 }
  else                       { usage("$a: no such option") }
}
usage("--compile-only and --run-only together leave nothing to do") unless $compile || $run;
usage("no environment: --env=NAME, or XC_ENV") unless %opt<env>;
usage("no include folder: --includes=PATH, or XC_INCLUDES") if $compile && !%opt<includes>;

# Everything from the top of the repository, wherever this is run from.
my $root = $*PROGRAM.IO.absolute.IO.parent;
my $out = %opt<out>.IO.is-absolute ?? %opt<out>.IO !! $root.add(%opt<out>);

# The self-tests: the source, the file bin/xc writes, the function to run.
my @tests =
  %(source => 'xtpl/tests/54_selftest.xtpl', file => 'selftest.tlpp',    run => 'u_selftest'),
  %(source => 't/protheus/xc_selftest.xtpl', file => 'xc_selftest.tlpp', run => 'u_xc_selftest');

# The AppServer: a path is started from its own folder, a bare name from here.
my $server = %opt<appserver>;
my $cwd = $server.contains('/') || $server.contains('\\') ?? $server.IO.absolute.IO.parent.Str !! $*CWD.Str;

sub appserver(*@args)
{
  say "  \$ {$server} {@args.join(' ')}";
  my $p = run $server, |@args, :cwd($cwd), :merge;
  my $text = $p.out.slurp(:close);
  ($p.exitcode, $text)
}

if $compile
{
  # Relative inside the repository, whole outside it.
  my $shown = $out.Str.starts-with($root.Str) ?? $out.relative($root) !! $out.Str;
  say "xc: compiling the self-tests into $shown/";
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
  my @files = $root.add('runtime/xtpl_runtime.tlpp').Str, |@tests.map({ $out.add(.<file>).Str });
  my ($code, $text) = appserver('-compile', "-files={@files.join(';')}", "-includes={%opt<includes>}",
                                "-env={%opt<env>}", |(%opt<authorization> ?? "-authorization={%opt<authorization>}" !! ()));
  print $text.lines.map({ "    $_\n" }).join;
  if $code
  {
    say "\n  the AppServer's compile ended with exit code $code";
    exit 1;
  }
}

exit 0 unless $run;

# A total, as both self-tests print it: 'selftest: 47 ok, 0 falhas',
# 'xc_selftest: 44 ok, 0 failed'.
my $failed = 0;
for @tests -> %t
{
  say "\nProtheus: running {%t<run>}";
  my ($code, $text) = appserver("-run={%t<run>}", "-env={%opt<env>}");
  my @lines = $text.lines;
  my $total = @lines.first({ / \w+ ':' \h* \d+ ' ok, ' \d+ \h+ [ 'falhas' || 'failed' ] / });
  if $total.defined
  {
    # The failed checks, and the total.
    say "    $_" for @lines.grep({ .starts-with('FALHA') || .starts-with('FAILED') });
    say "    {$total.trim}";
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
