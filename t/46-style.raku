# The house style that a test can see: a separator line -- a comment that is
# a run of dashes, with a title in it or not -- ends at column 80, in xc's
# own files: the library, bin/xc, the tests, the scripts and tools, the
# self-test, the runtime, and the C++ port's sources. xtpl/ is xtpl's, as it
# came, and is not looked at.

my $root = $*PROGRAM.IO.absolute.IO.parent.parent;

sub files-under(IO::Path $dir)
{
  return () unless $dir.d;
  $dir.dir.sort.map({ .d ?? |files-under($_) !! $_ })
}

my @files = |files-under($root.add('lib')), |files-under($root.add('t')),
            |files-under($root.add('protheus')), |files-under($root.add('runtime')),
            |files-under($root.add('tools')), |files-under($root.add('cpp').add('src')),
            $root.add('bin').add('xc'), |$root.dir.grep({ .f && .extension eq 'raku' }).sort;
@files = @files.grep({ .f && .extension (elem) <raku rakumod xtpl tlpp prw cpp h ''> });

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  note "    {$!.message}" if $!;
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

my @wrong;
my $seen = 0;
for @files -> $f
{
  # Bytes, as latin-1: a cp1252 file reads as one character a byte, as does
  # the ASCII the separators are made of.
  my @lines = $f.slurp(:bin).decode('latin-1').lines;
  for @lines.kv -> $i, $l
  {
    my $t = $l.subst(/ \s+ $ /, '');
    next unless $t ~~ / ^ \h* [ '#' | '//' ] \h? '----' /;
    $seen++;
    @wrong.push("{$f.relative($root)}:{$i + 1}: {$t.chars} columns") unless $t.chars == 80;
  }
}
check "the separator lines were found ($seen)", { $seen >= 100 };
check "every separator line ends at column 80", { !@wrong };
note "    $_" for @wrong.head(20);

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
