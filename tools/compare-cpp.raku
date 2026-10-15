# The C++ xc against the Raku one: every source given read by both, the
# trees compared -- the whole source, and each expression on its own --,
# what the checks say of it, and the TL++ it becomes; and the two drivers,
# bin/xc and cpp/build/xc, run with --check on all the files at once.
#
#   rakupp tools/compare-cpp.raku [--xc=PATH] [--compare=PATH] [--keep=DIR]
#                                 [--dict=sx3.csv [--strict]] FILE-OR-FOLDER...
#
# A folder is every .xtpl, .prw, .prx and .tlpp under it. The Raku trees go
# to a folder of their own (--keep: that one, and kept), made by
# tools/ast-json.raku; xc-compare reads them back and says what differs.
# From the repository's top, as the tests are run.

sub sources(Str $p --> List)
{
  return ($p,) unless $p.IO.d;
  $p.IO.dir.sort.map({ .d ?? |sources(.Str) !! (.extension.lc eq 'xtpl' | 'prw' | 'prx' | 'tlpp' ?? .Str !! Empty) }).List
}

# Where CMake puts a program: cpp/build, or a configuration's folder under
# it (Visual Studio's generators).
sub built(Str $name --> Str)
{
  ("cpp/build/$name", "cpp/build/$name.exe", "cpp/build/Release/$name.exe", "cpp/build/Debug/$name.exe")
    .first(*.IO.f) // "cpp/build/$name"
}

# The first line where two outputs differ, both ways.
sub first-difference(Blob $a, Blob $b --> Str)
{
  my @a = $a.decode('utf8-c8').lines;
  my @b = $b.decode('utf8-c8').lines;
  my $i = (^max(@a.elems, @b.elems)).first({ (@a[$_] // '') ne (@b[$_] // '') }) // 0;
  "  raku: {@a[$i] // '(nothing)'}\n  c++:  {@b[$i] // '(nothing)'}"
}

sub MAIN(Str :$xc = built('xc'), Str :$compare = built('xc-compare'), Str :$keep, Str :$dict, Bool :$strict = False,
         *@paths)
{
  for $xc, $compare -> $p
  {
    die "no $p: cmake -S cpp -B cpp/build && cmake --build cpp/build --config Release" unless $p.IO.f;
  }
  my @files = @paths.map({ |sources($_) });
  die "no sources" unless @files;
  my $dir = $keep // $*TMPDIR.add("xc-compare-$*PID").Str;
  mkdir $dir;
  my $list = "$dir/list.txt";
  $list.IO.spurt(@files.map({ .IO.absolute ~ "\n" }).join);
  my $tool = $?FILE.IO.parent.add('ast-json.raku').Str;
  my $lib = $?FILE.IO.parent.parent.add('lib').Str;
  my @dict = $dict.defined ?? ("--dict=$dict", |($strict ?? '--strict' !! ())) !! ();
  run $*EXECUTABLE, "-I$lib", $tool, "--out=$dir", "--list=$list", |@dict;
  my @trees = (^@files).map({ "$dir/$_.tree" });
  my @roots = (^@files).map({ "$dir/$_.roots" });
  my @checks = (^@files).map({ "$dir/$_.check" });
  my @outs = (^@files).map({ "$dir/$_.out" });
  my $t = run $compare, '--tree', |@trees;
  my $r = run $compare, '--roots', |@roots;
  my $c = run $compare, '--check', |($dict.defined ?? ('--dict', $dict, |($strict ?? '--strict' !! ())) !! ()), |@checks;
  my $e = run $compare, '--emit', |@outs;

  # The two drivers, bin/xc and the C++ xc, with --check on all the files at
  # once: what each says, on its output and on its errors, and how it exits.
  my @opts = '--check', |($dict.defined ?? ('--dict', $dict, |($strict ?? '--dict-strict' !! ())) !! ());
  my %said;
  for (raku => ($*EXECUTABLE, $?FILE.IO.parent.parent.add('bin').add('xc').Str), cpp => ($xc,)) -> $p
  {
    my $out = "$dir/{$p.key}.out".IO.open(:w);
    my $err = "$dir/{$p.key}.err".IO.open(:w);
    my $run = run |$p.value, |@opts, |@files, :$out, :$err;
    $out.close;
    $err.close;
    %said{$p.key} = ("$dir/{$p.key}.out".IO.slurp(:bin), "$dir/{$p.key}.err".IO.slurp(:bin), $run.exitcode);
  }
  my ($ro, $re, $rx) = |%said<raku>;
  my ($co, $ce, $cx) = |%said<cpp>;
  my $d = 0;
  unless $ro eqv $co { say "the drivers say something else:\n{first-difference($ro, $co)}"; $d = 1 }
  unless $re eqv $ce { say "the drivers' errors differ:\n{first-difference($re, $ce)}"; $d = 1 }
  if $rx != $cx { say "the drivers exit with $rx and $cx"; $d = 1 }
  say "the drivers: the same, on {@files.elems} files" unless $d;

  unless $keep
  {
    unlink $_ for $dir.IO.dir;
    rmdir $dir;
  }
  exit($t.exitcode || $r.exitcode || $c.exitcode || $e.exitcode || $d ?? 1 !! 0);
}
