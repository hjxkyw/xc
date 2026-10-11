use lib 'lib';

# bin/xc's command line: one source, a source and its output, several sources,
# folders, --check. What fails is reported and the rest goes on; the exit code
# is 0 when all went well, 1 when a file failed, 2 when the command line itself
# is wrong.

my $dir = $*TMPDIR.add("xc-driver-$*PID");
# 'rm -rf' in Raku, so it runs on Windows too.
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

sub reset-dir()
{
  remove-tree($dir);
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

# ---- --check -----------------------------------------------------------------
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

# ---- several sources, folders ------------------------------------------------
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

# ---- where a parse fails ---------------------------------------------------
check "a file that fails before its first function: the line that failed, not line 1",
{
  spurt $dir.add('top.xtpl'), "#include \"totvs.ch\"\n\n// a comment\nNotAThing x y z\n\nuser function f()\nreturn 1\n";
  my %r = xc('--check', "$dir/top.xtpl");
  $dir.add('top.xtpl').unlink;
  %r<code> == 1 && %r<err>.contains('top.xtpl:4: cannot parse this line: NotAThing x y z')
};

check "a local after a statement: said so -- a malformed one is still a line that does not parse",
{
  spurt $dir.add('late.xtpl'), "user function f(a)\n  Default a := 1\n  Local x := 1   // a comment\nreturn x\n";
  spurt $dir.add('bad.xtpl'), "user function f(a)\n  conout(a)\n  local x := := 1\nreturn a\n";
  my %late = xc('--check', "$dir/late.xtpl");
  my %bad  = xc('--check', "$dir/bad.xtpl");
  $dir.add($_).unlink for <late.xtpl bad.xtpl>;
  %late<code> == 1 && %late<err>.contains("late.xtpl:3: 'local' cannot be declared here: every local comes before "
                                          ~ "the first statement of its function or its block")
    && %bad<code> == 1 && %bad<err>.contains('bad.xtpl:3: cannot parse this line: local x := := 1')
};

# A name xc keeps for itself: the grammar refuses it, and bin/xc, reading the
# file again with any name allowed, says which one and why -- in xtpl's words,
# on xtpl's line, for xtpl's own two cases.
check "a reserved word declared: xtpl's message; a generated name: xtpl's, but '__', which xc lets through",
{
  my $err = "xtpl/errors/reserved_word.err".IO.slurp.trim.subst(/ ^ 'SyntaxError: ' /, '');
  my %r = xc('--check', "xtpl/errors/reserved_word.xtpl");
  my %g = xc('--check', "xtpl/errors/generated_name.xtpl");
  %r<code> == 1 && %r<err>.contains("reserved_word.xtpl:2: $err")
    && %g<code> == 1 && %g<err>.contains("generated_name.xtpl:12: 'fo_0_0' has the shape of a name xc generates, "
                                         ~ "so it cannot be declared. Reserved: '<kind>_<depth>_<index>' -- fo_0_0, fv_1_2, s_1_0, b_0_x.")
};

check "a reserved word as a parameter, a loop's variable, a block local; a generated name in a block is a block local",
{
  spurt $dir.add('names.xtpl'),
    "user function f(a, given)\n  local n := 0\n  for when in a\n    if .t.\n      local otherwise := 1\n"
    ~ "      local fo_0_1 := 2\n      n += otherwise + fo_0_1 + when\n    endif\n  next\n"
    ~ "  for local with := 1 to 3\n  next\nreturn n\n";
  my %r = xc('--check', "$dir/names.xtpl");
  $dir.add('names.xtpl').unlink;
  my @said = %r<err>.lines.map({ .subst(/ ^ .* 'names.xtpl:' /, '') });
  %r<code> == 1 && @said.join("\n") eq ("1: Cannot use reserved word 'given' as a variable name.",
                                       "3: Cannot use reserved word 'when' as a variable name.",
                                       "5: Cannot use reserved word 'otherwise' as a variable name.",
                                       "10: Cannot use reserved word 'with' as a variable name.").join("\n")
};

check "a reserved word, and a line further down that does not parse anyway: the name, on its line",
{
  spurt $dir.add('both.xtpl'), "user function f(a)\n  local len := 1\n  x := := 2\nreturn a\n";
  my %r = xc('--check', "$dir/both.xtpl");
  $dir.add('both.xtpl').unlink;
  %r<code> == 1 && %r<err>.contains("both.xtpl:2: Cannot use reserved word 'len' as a variable name.")
};

# ---- --outdir: every output into one folder ----------------------------------
reset-dir;
check '--outdir: sources and folders, every .tlpp into the folder, named for its source',
{
  my $od = $dir.add('od');
  my %r = xc("--outdir=$od", "$dir/src/a.xtpl", "$dir/src/sub/b.xtpl");
  %r<code> == 0 && $od.add('a.tlpp').e && $od.add('b.tlpp').e && written() eq ''
};
check '--outdir: two sources of the same name would write one file -- refused; with an output named too',
{
  mkdir $dir.add('src/other');
  spurt $dir.add('src/other/a.xtpl'), "user function a2()\nreturn 1\n";
  my $two = xc("--outdir=$dir/od", "$dir/src/a.xtpl", "$dir/src/other/a.xtpl");
  my $named = xc("--outdir=$dir/od", "$dir/src/a.xtpl", "$dir/x.tlpp");
  $dir.add('src/other/a.xtpl').unlink;
  $dir.add('src/other').rmdir;
  $two<code> == 2 && $two<err>.contains('both would be a.tlpp') && $named<code> == 2
};
check '--outdir: a source given twice, itself and in its folder, compiled once',
{
  my %r = xc("--outdir=$dir/od2", "$dir/src/sub/b.xtpl", "$dir/src/sub");
  %r<code> == 1 && %r<out>.lines.grep(*.contains('b.xtpl ->')).elems == 1
};
check "--outdir: paths with the system's separator -- on Windows '\\', as run-protheus.raku passes them",
{
  my $s = $*DISTRO.is-win ?? '\\' !! '/';
  my $d = $*DISTRO.is-win ?? $dir.Str.subst('/', '\\', :g) !! $dir.Str;
  my %r = xc("--outdir={$d}{$s}od3", "{$d}{$s}src{$s}a.xtpl", "{$d}{$s}src{$s}sub{$s}b.xtpl", "{$d}{$s}src{$s}sub");
  %r<code> == 1 && $dir.add('od3/a.tlpp').e && $dir.add('od3/b.tlpp').e
    && %r<out>.lines.grep(*.contains('b.xtpl ->')).elems == 1
    && %r<out>.contains("a.xtpl -> {$d}{$s}od3{$s}a.tlpp")
};

# ---- one source and its output -----------------------------------------------
reset-dir;
check "'file.xtpl out.tlpp' still names the output",
{
  my %r = xc("$dir/src/a.xtpl", "$dir/out.tlpp");
  %r<code> == 0 && $dir.add('out.tlpp').e && written() eq ''
};

# ---- the command line itself -------------------------------------------------
check 'a wrong command line exits with 2: --check with an output, an unknown option, nothing given',
{
  xc('--check', "$dir/src/a.xtpl", "$dir/x.tlpp")<code> == 2
    && xc('--chek', "$dir/src/a.xtpl")<code> == 2
    && xc()<code> == 2
};

# ---- the test runner ---------------------------------------------------------
# Only the refusals: running it for real would run this very suite.
check "run-tests.raku: an option it does not know is refused before any test runs -- '-all' with a hint, '--jobs=0' too",
{
  my $p = run $*EXECUTABLE, 'run-tests.raku', '-all', :out, :err;
  my $out = $p.out.slurp(:close);
  my $err = $p.err.slurp(:close);
  my $q = run $*EXECUTABLE, 'run-tests.raku', '--quick', :out, :err;
  $q.out.slurp(:close);
  my $qerr = $q.err.slurp(:close);
  my $j = run $*EXECUTABLE, 'run-tests.raku', '--jobs=0', :out, :err;
  $j.out.slurp(:close);
  my $jerr = $j.err.slurp(:close);
  $p.exitcode == 2 && !$out.contains('ok ') && $err.contains("-all: no such option -- '--all', with two dashes")
    && $q.exitcode == 2 && $qerr.contains('--quick: no such option') && !$qerr.contains('two dashes')
    && $j.exitcode == 2 && $jerr.contains('--jobs takes how many files at a time, 1 or more')
};
check 'run-tests.raku --help: the usage, and 0',
{
  my $p = run $*EXECUTABLE, 'run-tests.raku', '--help', :out, :err;
  my $out = $p.out.slurp(:close);
  $p.err.slurp(:close);
  $p.exitcode == 0 && $out.contains('usage: rakupp run-tests.raku [--all]')
};

remove-tree($dir);

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
