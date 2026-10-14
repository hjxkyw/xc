# The C++ xc against the Raku one: every source given read by both, the
# trees compared -- the whole source, and each expression on its own.
#
#   rakupp tools/compare-cpp.raku [--xc=PATH] [--keep=DIR] FILE-OR-FOLDER...
#
# A folder is every .xtpl, .prw, .prx and .tlpp under it. The Raku trees go
# to a folder of their own (--keep: that one, and kept), made by
# tools/ast-json.raku; the C++ xc reads them back and says what differs.
# From the repository's top, as the tests are run.

sub sources(Str $p --> List)
{
  return ($p,) unless $p.IO.d;
  $p.IO.dir.sort.map({ .d ?? |sources(.Str) !! (.extension.lc eq 'xtpl' | 'prw' | 'prx' | 'tlpp' ?? .Str !! Empty) }).List
}

# Where CMake puts it: cpp/build, or a configuration's folder under it
# (Visual Studio's generators).
sub built(--> Str)
{
  <cpp/build/xc cpp/build/xc.exe cpp/build/Release/xc.exe cpp/build/Debug/xc.exe>.first(*.IO.f) // 'cpp/build/xc'
}

sub MAIN(Str :$xc = built(), Str :$keep, *@paths)
{
  die "no C++ xc at $xc: cmake -S cpp -B cpp/build && cmake --build cpp/build --config Release" unless $xc.IO.f;
  my @files = @paths.map({ |sources($_) });
  die "no sources" unless @files;
  my $dir = $keep // $*TMPDIR.add("xc-compare-$*PID").Str;
  mkdir $dir;
  my $list = "$dir/list.txt";
  $list.IO.spurt(@files.map({ .IO.absolute ~ "\n" }).join);
  my $tool = $?FILE.IO.parent.add('ast-json.raku').Str;
  my $lib = $?FILE.IO.parent.parent.add('lib').Str;
  run $*EXECUTABLE, "-I$lib", $tool, "--out=$dir", "--list=$list";
  my @trees = (^@files).map({ "$dir/$_.tree" });
  my @roots = (^@files).map({ "$dir/$_.roots" });
  my $t = run $xc, '--tree', |@trees;
  my $r = run $xc, '--roots', |@roots;
  unless $keep
  {
    unlink $_ for $dir.IO.dir;
    rmdir $dir;
  }
  exit($t.exitcode || $r.exitcode ?? 1 !! 0);
}
