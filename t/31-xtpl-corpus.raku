use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;
use XC::Check;

# Every source of xtpl's test suite and every example program, in t/xtpl/,
# passes the checks, with no warning, and compiles -- and what comes out is TL++: read back, it
# parses and compiles to itself. The exceptions, each for a stated reason:
#
# - 51_legacy.xtpl exercises xtpl's --legacy mode, for old AdvPL, which xc
#   does not have;
# - a file with 'raw' is not read back: raw text is TL++ only once the
#   preprocessor has applied its #xtranslate and #command rules.
#
# t/xtpl/errors/ holds what xtpl refuses; t/17-xtpl-errors.raku checks it.

my %skip = '51_legacy.xtpl' => 'xtpl --legacy mode';

# The checks find nothing in a source xtpl compiles, and then it is emitted.
# Not on the output read back: that is TL++, not xtpl -- its 'external' lines
# are gone, for one -- and xtpl's rules for names do not apply to it.
sub compile(Str $src, Bool :$checked = True)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  return Nil unless $m;
  # xtpl compiled every one of these, declaring everything: no error, and no
  # warning either -- a warning here would be a name xc fails to see declared.
  if $checked
  {
    my %c = check-all($m.made);
    die "the checks refuse it: line {%c<errors>[0].key}: {%c<errors>[0].value}" if %c<errors>;
    die "the checks warn: line {%c<warnings>[0].key}: {%c<warnings>[0].value}" if %c<warnings>;
  }
  emit($m.made, $src)
}

my @files = |dir('t/xtpl/tests').grep(*.extension eq 'xtpl'),
            |dir('t/xtpl/examples').grep(*.d).map({ |dir($_).grep(*.extension eq 'xtpl') });

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
  say("        {$!.message.lines[0]}") if $! && !$v;
}

for @files.sort -> $f
{
  my $name = $f.basename;
  next if %skip{$name}:exists;
  my $label = $f.parent.basename eq 'tests' ?? $name !! "{$f.parent.basename}/$name";

  # As bin/xc reads it: bytes, not 'slurp', so line ends stay as they are.
  my $src = $f.slurp(:bin).decode('utf-8');
  check "$label compiles, and the output compiles to itself", {
    my $once = compile($src);
    if $src ~~ m:i/ ^^ \h* 'raw' >> /
    {
      $once.defined                                # raw: not read back
    }
    else
    {
      my $*GENERATED-OK = True;
      $once.defined && compile($once, :!checked) eq $once
    }
  };
}

check "the skipped files are there, so skipping them still means something",
{
  so %skip.keys.all (elem) @files.map(*.basename).Set
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
