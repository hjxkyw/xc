# xc's output, compiled and run by a Protheus AppServer.
#
#   rakupp run-protheus.raku --env=NAME --includes=PATH [--appserver=PATH]
#                            [--authorization=FILE] [--out=DIR] [--rebuild]
#                            [--xc=PATH] [--rootpath=PATH]
#                            [--compile-only | --run-only | --corpus | --interp | --bench]
#                            [--trace] [--nojit] [--verbose]
#
# The self-tests (the default):
#
# 1. xc compiles the two self-tests -- xtpl's xtpl/tests/54_selftest.xtpl
#    and xc's own protheus/xc_selftest.xtpl -- into build/protheus/: each
#    only when its .tlpp is missing, or older than its source or than xc;
#    --rebuild compiles both anyway. xc is the program --xc=PATH names, or
#    the one CMake built: cpp/build/xc, or cpp\build\Release\xc.exe with
#    Visual Studio.
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
# The bytecode's interpreter (--interp): xc compiles interp/xbc.xtpl into
# build/interp/, and the AppServer compiles it with the runtime; xc compiles
# the runtime, each case of cpp/tests/bytecode that has a NAME.out -- but
# one with a NAME.vmonly, which needs what only xc-vm does: its own areas,
# Decimals -- and xtpl's self-test to bytecode, into build/interp-xbc/.
# Then the AppServer runs the interpreter on each --
#   appserver -run=u_xbc -env=<name> out=\xbc\NAME.got \xbc\xtpl_runtime.xbc \xbc\NAME.xbc
# -- and what it writes is compared with NAME.out, what xc-vm does; a
# self-test has to end with its total and no check failed, and runs again
# without the runtime's bytecode, its calls of the runtime the RPO's. The AppServer
# reads and writes files under the environment's RootPath only -- a path with
# a drive letter fails --, so the .xbc go to xbc/ in the RootPath, and what
# the cases read by a relative name (08-chains.txt) to its StartPath, where a
# relative name is; those copies are removed at the end. Both come from the
# environment's section of the appserver.ini in the AppServer's folder;
# --rootpath=PATH names the RootPath, as this machine reaches it, instead.
# With --trace each run gives the interpreter 'trace=\xbc\NAME.trace' too --
# each instruction it ran, each call of the AppServer's, each Break taken
# -- and the trace is kept beside the logs, build/logs/interp/NAME.trace.
# With --nojit, 'jit=off': the interpreter has no run of instructions made
# a code block by the AppServer's macro compiler.
#
# The interpreter's speed (--bench): xc compiles interp/bench.xtpl -- parts
# that each do one thing over and over: a loop, calls, the AppServer's
# functions, arrays, strings, methods, blocks, hashes, a chain -- as TL++,
# with the interpreter, into build/bench/, and as bytecode into
# build/bench-xbc/; the AppServer compiles the first and runs it --
#   appserver -run=u_bench -env=<name>
# -- then the interpreter on the second, with the runtime the RPO's:
#   appserver -run=u_xbc -env=<name> out=\xbc\bench.got \xbc\bench.xbc
# Each part prints the time of one of the things it does, in microseconds;
# this shows them side by side, and how many times slower the interpreter
# is -- and the interpreter's times with no JIT, jit=off, which --nojit
# makes the only ones. Nothing is checked: a run takes a minute or so.
#
# The corpus (--corpus): xc compiles every program of xtpl's corpus --
# its tests and its examples, but 51_legacy (xtpl's legacy mode) and
# 54_selftest (the self-tests' own) -- into build/corpus/, in one run, and
# the AppServer compiles that folder, with the runtime, in one run too.
# Nothing is run: what it checks is that Protheus takes all of xc's output.
# The few of xtpl's sources that are UTF-8 -- xc takes windows-1252 only, as
# Protheus' sources are -- go to xc as cp1252 copies, in build/cp1252/corpus/.
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
# XC_AUTHORIZATION, XC_COMPILER (--xc), XC_ROOTPATH. --appserver defaults to
# appserver.exe on Windows and appsrvlinux elsewhere, found on the PATH;
# given as a path, the AppServer is started from its own folder, where its
# appserver.ini is.

my %opt =
  appserver     => %*ENV<XC_APPSERVER> // ($*DISTRO.is-win ?? 'appserver.exe' !! 'appsrvlinux'),
  env           => %*ENV<XC_ENV>,
  includes      => %*ENV<XC_INCLUDES>,
  authorization => %*ENV<XC_AUTHORIZATION>,
  xc            => %*ENV<XC_COMPILER>,
  rootpath      => %*ENV<XC_ROOTPATH>,
  out           => Str;
my ($compile, $run, $rebuild, $corpus, $interp, $bench, $verbose, $trace, $nojit) =
   True, True, False, False, False, False, False, False, False;

sub usage(Str $why)
{
  note "$why\n"
     ~ "usage: rakupp run-protheus.raku --env=NAME --includes=PATH [--appserver=PATH]\n"
     ~ "                                [--authorization=FILE] [--out=DIR] [--rebuild]\n"
     ~ "                                [--xc=PATH] [--rootpath=PATH]\n"
     ~ "                                [--compile-only | --run-only | --corpus | --interp | --bench]\n"
     ~ "                                [--trace] [--nojit] [--verbose]";
  exit 2;
}

for @*ARGS -> $a
{
  if $a eq '--compile-only'  { $run = False }
  elsif $a eq '--run-only'   { $compile = False }
  elsif $a eq '--rebuild'    { $rebuild = True }
  elsif $a eq '--corpus'     { $corpus = True }
  elsif $a eq '--interp'     { $interp = True }
  elsif $a eq '--bench'      { $bench = True }
  elsif $a eq '--verbose'    { $verbose = True }
  elsif $a eq '--trace'      { $trace = True }
  elsif $a eq '--nojit'      { $nojit = True }
  elsif $a ~~ / ^ '--' (appserver || env || includes || authorization || out || xc || rootpath) '=' (.+) $ / { %opt{~$0} = ~$1 }
  else                       { usage("$a: no such option") }
}
usage("--compile-only and --run-only together leave nothing to do") unless $compile || $run;
usage("--corpus only compiles: not with --run-only") if $corpus && !$compile;
usage("--corpus, --interp and --bench: one at a time") if ($corpus, $interp, $bench).grep(*.so) > 1;
usage("--trace is for --interp") if $trace && !$interp;
usage("--nojit is for --interp and --bench") if $nojit && !($interp || $bench);
$run = False if $corpus;
usage("no environment: --env=NAME, or XC_ENV") unless %opt<env>;
usage("no include folder: --includes=PATH, or XC_INCLUDES") if $compile && !%opt<includes>;
usage("no xc at {%opt<xc>}: --xc=PATH names the program") if $compile && %opt<xc> && !%opt<xc>.IO.f;

# Everything from the top of the repository, wherever this is run from.
my $root = $*PROGRAM.IO.absolute.IO.parent;
%opt<out> //= $corpus ?? 'build/corpus' !! $interp ?? 'build/interp' !! $bench ?? 'build/bench' !! 'build/protheus';
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

# Relative inside the repository, whole outside it -- with the system's
# separator, as native() writes it.
sub shown($p --> Str)
{
  my $s = $p.IO.absolute.Str;
  return native($p) unless $s.starts-with($root.Str);
  my $r = $p.IO.absolute.IO.relative($root);
  $*DISTRO.is-win ?? $r.subst('/', '\\', :g) !! $r
}

# Which xc: what --xc names, else the one CMake built.
my $built = ('cpp/build/xc', 'cpp/build/xc.exe', 'cpp/build/Release/xc.exe', 'cpp/build/Debug/xc.exe')
              .map({ $root.add($_) }).first(*.f);
%opt<xc> //= $built.absolute if $built;
usage("no xc in cpp/build: build it (README.md, Building), or name it with --xc=PATH")
  if $compile && !%opt<xc>;
my $xc-path = (%opt<xc> // 'xc').IO;
my $xc-shown = shown($xc-path);

# What xc says of itself, --version: the commit it is built from -- shown
# with its path. One that says nothing of it shows its path alone.
if $compile
{
  my $p = run native($xc-path), '--version', :out, :err;
  my $said = $p.out.slurp(:close).trim;
  $p.err.slurp(:close);
  $xc-shown ~= ", {$said.substr(11)}" if $p.exitcode == 0 && $said.starts-with('xc version ');
}

# xc run with these arguments.
sub xc(*@args)
{
  run(native($xc-path), |@args, :cwd($root.Str), :merge)
}

# The self-tests: the source, the file xc writes, the function to run.
my @tests =
  %(source => 'xtpl/tests/54_selftest.xtpl', file => 'selftest.tlpp',    run => 'u_selftest'),
  %(source => 'protheus/xc_selftest.xtpl', file => 'xc_selftest.tlpp', run => 'u_xc_selftest');

# The AppServer: a path is started from its own folder, a bare name from here.
# The folder is what comes before the last separator, as written: on Windows
# the path's parent was taken for this folder.
my $server = %opt<appserver>;
my @cut = ($server.rindex('/'), $server.rindex('\\')).grep(*.defined);
my $cwd = @cut ?? $server.substr(0, @cut.max) !! $*CWD.Str;

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
  unless $results
  {
    # Nothing to go by but how it ended: what it said last, shown -- unless
    # --verbose showed all of it already.
    unless $verbose
    {
      my @last = $text.lines.map(*.trim).grep(*.chars).tail(15);
      say @last ?? "    what it said last:" !! "    it said nothing";
      say "      $_" for @last;
    }
    return "no 'Compilation Results' line from the AppServer (exit code $code): its compile did not finish";
  }
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
  # Written whole every time, the bytes read and written here. It used to be
  # copied only when the copy looked out of date -- older, or of another size
  # -- and on Windows an old copy stayed: compiled after the corpus, it put
  # the old runtime back into the RPO, and U_XTPL_JNEW was not there.
  spurt $dir.add('xtpl_runtime.tlpp'), $root.add('runtime/xtpl_runtime.tlpp').slurp(:bin);
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
  # Protheus' sources are windows-1252 (cp1252), and xc refuses UTF-8; xtpl's
  # files are kept byte for byte, and a few of them are UTF-8. Those go to xc
  # as cp1252 copies, in a folder of their own beside the compiled one -- the
  # AppServer would compile them too, in it.
  my $copies = $out.parent.add('cp1252').add($out.basename);
  @sources = @sources.map(-> $s
  {
    my $b = $s.slurp(:bin);
    if $b.list.first(* >= 0x80).defined && (try $b.decode('utf-8')).defined
    {
      mkdir $copies;
      spurt $copies.add($s.basename), $b.decode('utf-8').encode('windows-1252');
      $copies.add($s.basename)
    }
    else
    {
      $s
    }
  });
  say "xc ($xc-shown): compiling {+@sources} programs of xtpl's corpus into {shown($out)}";
  mkdir $out;
  my $p = xc("--outdir={native($out)}", |@sources.map({ native($_) }));
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

# The environment's RootPath -- --rootpath, else its section of the
# appserver.ini in the AppServer's folder -- and its StartPath, '/system/'
# when the section has none.
sub env-paths(--> List)
{
  my ($rootpath, $startpath) = %opt<rootpath>, Str;
  my $ini = $cwd.IO.add('appserver.ini');
  if $ini.f
  {
    my $in = False;
    for $ini.slurp(:bin).decode('windows-1252').lines>>.trim -> $l
    {
      if $l ~~ / ^ '[' (.*) ']' $ /                     { $in = ~$0.trim.lc eq %opt<env>.lc }
      elsif $in && $l ~~ / ^ :i rootpath \s* '=' (.*) $ / { $rootpath //= ~$0.trim }
      elsif $in && $l ~~ / ^ :i startpath \s* '=' (.*) $ / { $startpath = ~$0.trim }
    }
  }
  usage("no RootPath for '{%opt<env>}' in {native($ini)}: --rootpath=PATH, or XC_ROOTPATH") unless $rootpath;
  ($rootpath.IO, $startpath // '/system/')
}

# ---- the interpreter ---------------------------------------------------------
if $interp
{
  my $xbc = $out.parent.add('interp-xbc');
  my $cases = $root.add('cpp/tests/bytecode');
  # Not those that need xc-vm's own areas: NAME.vmonly says why.
  my @cases = $cases.dir.grep(*.extension eq 'out').map(*.basename.subst(/ '.out' $ /, ''))
                        .grep({ !$cases.add("$_.vmonly").e }).sort;
  # Not xc's self-test: it has Decimals, which go wrong in the interpreter on
  # the AppServer (docs/bytecode.md, The interpreter) -- as 05-decimal does,
  # which its NAME.vmonly leaves out.
  my @selftests =
    %(source => 'xtpl/tests/54_selftest.xtpl', name => '54_selftest', run => 'U_SELFTEST',
      total => / 'selftest: ' \d+ ' ok, 0 falhas' /),;
  if $compile
  {
    say "xc ($xc-shown): compiling the interpreter into {shown($out)}";
    mkdir $out;
    my $p = xc(native($root.add('interp/xbc.xtpl')), native($out.add('xbc.tlpp')));
    print $p.out.slurp(:close).lines.map({ "  $_\n" }).join;
    if $p.exitcode
    {
      say "\n  xc could not compile interp/xbc.xtpl";
      exit 1;
    }
    say "\nProtheus: compiling it, with the runtime, into '{%opt<env>}'";
    my $count = prepare-folder($out, ['xbc.tlpp']);
    with compile-folder($out, $count)
    {
      say "\n  $_";
      exit 1;
    }
    say "\nxc: the runtime, {+@cases} cases and xtpl's self-test as bytecode, into {shown($xbc)}";
    mkdir $xbc;
    my @sources = ($root.add('runtime/xtpl_runtime.tlpp') => 'xtpl_runtime',
                   |@cases.map({ ($cases.add("$_.xtpl").e ?? $cases.add("$_.xtpl") !! $cases.add("$_.prw")) => $_ }),
                   |@selftests.map({ $root.add(.<source>) => .<name> }));
    for @sources -> $s
    {
      my $q = xc('--bytecode', native($s.key), native($xbc.add($s.value ~ '.xbc')));
      my $said = $q.out.slurp(:close);
      if $q.exitcode
      {
        print $said.lines.map({ "  $_\n" }).join;
        say "\n  xc could not make {shown($s.key)} bytecode";
        exit 1;
      }
    }
  }
  exit 0 unless $run;
  mkdir $logs;
  my @bad;
  # Where the AppServer reads them: the .xbc in xbc/ of the RootPath, named
  # \xbc\NAME.xbc; what the cases read by a relative name in the StartPath.
  my ($rootpath, $startpath) = env-paths();
  my $stage = $rootpath.add('xbc');
  my $start = $rootpath.add($startpath.subst(/ ^ <[\\/]>+ /, ''));
  say "\nThe bytecode into {native($stage)}, the cases' files into {native($start)}";
  mkdir $stage;
  .unlink for $stage.dir.grep({ .f && .extension eq 'xbc' | 'got' });
  spurt $stage.add(.basename), .slurp(:bin) for $xbc.dir.grep(*.extension eq 'xbc');
  my @data = $cases.dir.grep(*.extension eq 'txt').map({ $start.add(.basename) => $_ });
  spurt .key, .value.slurp(:bin) for @data;
  sub on-server(Str $name --> Str) { "\\xbc\\$name" }
  # The interpreter run on the modules; what it wrote, '\r\n' read as '\n'.
  sub interpret(Str $name, *@args --> Str)
  {
    my $got = $stage.add("$name.got");
    $got.unlink if $got.e;
    my @traced = $trace ?? ("trace={on-server("$name.trace")}",) !! ();
    @traced.push('jit=off') if $nojit;
    my ($code, $text) = appserver($logs.add("run-$name.log"), '-run=u_xbc', "-env={%opt<env>}",
                                  "out={on-server("$name.got")}", |@traced, |@args);
    spurt $logs.add("$name.trace"), $stage.add("$name.trace").slurp(:bin) if $trace && $stage.add("$name.trace").e;
    $got.e ?? $got.slurp(:bin).decode('windows-1252').subst("\r\n", "\n", :g)
           !! "(no {$got.basename}: the interpreter did not get to write it -- exit code $code)\n"
              ~ $text.lines.grep(*.trim).tail(10).map({ "  $_\n" }).join
  }
  say "\nProtheus: the interpreter running {+@cases} cases and xtpl's self-test";
  for @cases -> $c
  {
    my @with = $cases.add("$c.with").e ?? $cases.add("$c.with").lines>>.trim.grep(*.chars).map({ on-server("$_.xbc") })
                                       !! ();
    my $got = interpret($c, on-server('xtpl_runtime.xbc'), |@with, on-server("$c.xbc"));
    my $expect = $cases.add("$c.out").slurp(:bin).decode('windows-1252').subst("\r\n", "\n", :g);
    if $got eq $expect
    {
      say "    ok    $c";
      next;
    }
    @bad.push($c);
    say "    DIFF  $c";
    my @e = $expect.lines;
    my @g = $got.lines;
    for ^max(+@e, +@g) -> $i
    {
      next if @e[$i].defined && @g[$i].defined && @e[$i] eq @g[$i];
      say "          {$i + 1}: expected {@e[$i] // '(nothing)'}";
      say "          {' ' x ($i + 1).chars}  got      {@g[$i] // '(nothing)'}";
    }
  }
  # Each self-test twice: with the runtime's bytecode, and without it -- its
  # calls of the runtime then the RPO's, through the interpreter's table.
  for @selftests.map({ |(%(|$_, with => True), %(|$_, with => False)) }) -> %t
  {
    my $as = %t<with> ?? %t<name> !! "{%t<name>}-rpo";
    my @runtime = %t<with> ?? on-server('xtpl_runtime.xbc') !! ();
    my $got = interpret($as, "run={%t<run>}", |@runtime, on-server(%t<name> ~ '.xbc'));
    my $total = $got.lines.first({ $_ ~~ %t<total> });
    my $how = %t<with> ?? '' !! " (the runtime's calls the RPO's)";
    if $total.defined && $got.starts-with("exit 0\n")
    {
      say "    ok    {%t<name>}: $total$how";
      next;
    }
    @bad.push($as);
    say "    FAIL  {%t<name>}$how";
    say "          $_" for $got.lines;
  }
  .key.IO.unlink for @data;
  say "\n  {@bad ?? "{+@bad} of {@cases + 2 * @selftests} differ: {@bad.join(', ')}" !! 'every one as xc-vm runs it'}";
  exit(@bad ?? 1 !! 0);
}

# ---- the interpreter's speed -------------------------------------------------
if $bench
{
  my $xbc = $out.parent.add('bench-xbc');
  if $compile
  {
    say "xc ($xc-shown): compiling the interpreter and interp/bench.xtpl into {shown($out)}";
    mkdir $out;
    for <xbc bench> -> $n
    {
      my $p = xc(native($root.add("interp/$n.xtpl")), native($out.add("$n.tlpp")));
      print $p.out.slurp(:close).lines.map({ "  $_\n" }).join;
      if $p.exitcode
      {
        say "\n  xc could not compile interp/$n.xtpl";
        exit 1;
      }
    }
    say "\nProtheus: compiling them, with the runtime, into '{%opt<env>}'";
    my $count = prepare-folder($out, ['xbc.tlpp', 'bench.tlpp']);
    with compile-folder($out, $count)
    {
      say "\n  $_";
      exit 1;
    }
    say "\nxc: interp/bench.xtpl as bytecode, into {shown($xbc)}";
    mkdir $xbc;
    my $q = xc('--bytecode', native($root.add('interp/bench.xtpl')), native($xbc.add('bench.xbc')));
    my $said = $q.out.slurp(:close);
    if $q.exitcode
    {
      print $said.lines.map({ "  $_\n" }).join;
      say "\n  xc could not make interp/bench.xtpl bytecode";
      exit 1;
    }
  }
  exit 0 unless $run;
  mkdir $logs;
  # 'bench loop  0.052 us': the part, and its time.
  sub times(Str $text --> Hash)
  {
    my %t;
    for $text.lines -> $l
    {
      %t{~$0} = +$1 if $l ~~ / 'bench ' (\w+) \h+ (<[\d.]>+) ' us' /;
    }
    %t
  }
  say "\nProtheus: the bench, compiled";
  my ($code, $text) = appserver($logs.add('run-u_bench.log'), '-run=u_bench', "-env={%opt<env>}");
  my %compiled = times($text);
  my ($rootpath, $startpath) = env-paths();
  my $stage = $rootpath.add('xbc');
  mkdir $stage;
  spurt $stage.add('bench.xbc'), $xbc.add('bench.xbc').slurp(:bin);
  my $got = $stage.add('bench.got');
  $got.unlink if $got.e;
  # The interpreter on the bench: what it printed, the times in it.
  sub interpreted(Str $how, *@args --> List)
  {
    say "\nProtheus: the bench, interpreted$how";
    $got.unlink if $got.e;
    appserver($logs.add("run-bench{@args ?? '-nojit' !! ''}.log"), '-run=u_xbc', "-env={%opt<env>}",
              "out=\\xbc\\bench.got", |@args, "\\xbc\\bench.xbc");
    my $said = $got.e ?? $got.slurp(:bin).decode('windows-1252') !! '';
    ($said, times($said))
  }
  my ($said, %interpreted) = interpreted($nojit ?? ', with no JIT' !! '', |($nojit ?? ('jit=off',) !! ()));
  my %nojit = $nojit ?? () !! interpreted(', with no JIT', 'jit=off')[1];
  $stage.add('bench.xbc').unlink;
  $got.unlink if $got.e;
  my @parts = $text.lines.grep(/ 'bench ' \w+ \h /).map({ ~(.match(/ 'bench ' (\w+) /)[0]) });
  unless @parts && %interpreted
  {
    say "    nothing to show: {@parts ?? 'the interpreter' !! 'the compiled bench'} printed no times";
    say "      $_" for (@parts ?? $said.lines !! $text.lines).grep(*.trim).tail(15);
    exit 1;
  }
  sub us($x --> Str) { $x.defined ?? sprintf("%.3f", $x) !! '-' }
  say "\n  part      compiled us  interpreted us   times slower{$nojit ?? '' !! '      no JIT us'}";
  for @parts -> $p
  {
    my ($c, $i) = %compiled{$p}, %interpreted{$p};
    say sprintf("  %-8s %12.3f %15s %14s", $p, $c, us($i), $i.defined && $c > 0 ?? sprintf("%.0f", $i / $c) !! '-')
        ~ ($nojit ?? '' !! sprintf(" %15s", us(%nojit{$p})));
  }
  exit 0;
}

# ---- the self-tests ----------------------------------------------------------
if $compile
{
  say "xc ($xc-shown): compiling the self-tests into {shown($out)}";
  mkdir $out;
  # A .tlpp older than xc is made again.
  my $xc-made = $xc-path.modified;
  for @tests -> %t
  {
    my $made = $out.add(%t<file>);
    if !$rebuild && $made.e && $made.modified > $root.add(%t<source>).modified && $made.modified > $xc-made
    {
      say "  {%t<source>}: up to date";
      next;
    }
    # Paths as the system writes them: xc says them back, 'x -> y'.
    my $p = xc(native($root.add(%t<source>)), native($out.add(%t<file>)));
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
