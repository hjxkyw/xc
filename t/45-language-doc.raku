use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;
use XC::Check;

# docs/language.md says every example in it was compiled by xc, and shows
# what came out. This keeps it so. Each ```xtpl block is compiled, and the
# ```tlpp block right after it is what has to come out; a ```text block right
# after those is the messages bin/xc has to give, the file named as the
# message names it. An example with nothing after it has to compile. And in
# the tables headed '| xtpl | TL++ |', each row's xtpl has to come out as the
# TL++ beside it.
#
# A block that starts no function, class or file of its own -- no header,
# no include -- is a fragment of a function body: it is compiled inside
# 'User Function Doc()' ... 'Return nil', and what comes out between the two
# is compared. When an example has no include lines, the two xc adds are left
# out of what it shows.

my $doc = 'docs/language.md'.IO.slurp;
my @lines = $doc.lines;

# The fenced blocks, in order: info string, text (its fence's indentation
# taken off), the line of the opening fence and of the closing one.
my @blocks;
my $i = 0;
while $i < @lines
{
  if @lines[$i] ~~ / ^ (\h*) '```' (\w*) \h* $ /
  {
    my ($indent, $info, $open) = ~$0, ~$1, $i + 1;
    my @body;
    $i++;
    while @lines[$i] !~~ / ^ \h* '```' \h* $ /
    {
      my $l = @lines[$i];
      @body.push($l.starts-with($indent) ?? $l.substr($indent.chars) !! $l.trim-leading);
      $i++;
    }
    @blocks.push(%( :$info, text => @body.join("\n"), :$open, close => $i + 1 ));
  }
  $i++;
}

# Whether only blank lines stand between two blocks.
sub adjacent(%a, %b --> Bool)
{
  !@lines[%a<close> ..^ (%b<open> - 1)].grep(*.trim)
}

# A header of its own: the block is a whole file, not a fragment.
sub whole(Str $text --> Bool)
{
  so $text ~~ m:i/ ^^ \h* [ '#include' || [ [ 'user' || 'static' || 'main' ] \s+ ]? 'function' >>
                         || 'class' >> || 'interface' >> || 'method' >> || 'wsrestful' >> || 'wsmethod' >> ] /
}

# The output without the includes xc adds to a source that has none, and a
# fragment's without the function around it.
sub shown(Str $out, Str $text, Bool $whole --> Str)
{
  my $o = $out;
  unless $text.contains('#include')
  {
    $o = $o.subst("#include \"totvs.ch\"\n", '').subst("#include \"tlpp-core.th\"\n", '');
    $o = $o.subst(/ ^ \n+ /, '');
  }
  my @o = $o.lines;
  @o = @o[1 ..^ (@o - 1)] unless $whole;
  @o.map(*.trim-trailing).join("\n")
}

sub same-text(Str $a, Str $b --> Bool)
{
  $a.lines.map(*.trim-trailing).join("\n") eq $b.lines.map(*.trim-trailing).join("\n")
}

# The messages bin/xc gives for a source, the folder taken off the file name.
my $dir = $*TMPDIR.add("xc-language-doc-$*PID");
mkdir $dir;
sub messages(Str $name, Str $src --> List)
{
  my $path = $dir.add("$name.xtpl");
  spurt $path, $src;
  my $p = run $*EXECUTABLE, 'bin/xc', '--check', $path.Str, :out, :err;
  my $said = $p.out.slurp(:close) ~ $p.err.slurp(:close);
  $path.unlink;
  my $prefix = $dir.Str ~ ($*DISTRO.is-win ?? '\\' !! '/');
  $said.lines.map(*.subst($prefix, '', :g).trim).List
}

# What comes out of a source, or Str when it does not parse or the checks
# find an error -- said, so that a failure shows why.
sub compiled(Str $src --> Str)
{
  my $*FURTHEST = 0;
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  unless $m
  {
    note "    it does not parse";
    return Str;
  }
  my %c = check-all($m.made, lines => $src.lines.elems, source => $src);
  if %c<errors>
  {
    note "    line {.key}: {.value}" for %c<errors>.list;
    return Str;
  }
  emit($m.made, $src)
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  note "    {$!.message}" if $!;
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# The messages of a ```text block, each one given by bin/xc.
sub says(Int $line, Str $msgs, Str $src)
{
  my $name = ($msgs ~~ / ^ (\w+) '.xtpl:' /) ?? ~$0 !! "ex$line";
  my @said = messages($name, $src);
  for $msgs.lines.grep(*.trim) -> $m
  {
    check "line $line: says $m.substr(0, 60)...", { so @said.first(* eq $m.trim) };
  }
}

for @blocks.kv -> $k, %b
{
  next unless %b<info> eq 'xtpl';
  my ($expect, $msgs);
  my %next  = @blocks[$k + 1] // %();
  my %after = @blocks[$k + 2] // %();
  if %next && adjacent(%b, %next) && %next<info> eq 'tlpp'
  {
    $expect = %next<text>;
    $msgs = %after<text> if %after && adjacent(%next, %after) && %after<info> eq 'text';
  }
  elsif %next && adjacent(%b, %next) && %next<info> eq 'text'
  {
    $msgs = %next<text>;
  }
  my $text = %b<text>;
  my $whole = whole($text);
  my $src = $whole ?? "$text\n" !! "User Function Doc()\n$text\nReturn nil\n";
  my $line = %b<open>;

  # Refused on purpose, with nothing shown to come out: the messages tell.
  if $msgs.defined && !$expect.defined
  {
    says($line, $msgs, $src);
    next;
  }
  my $made = compiled($src);
  my $shown = $made.defined ?? shown($made, $text, $whole) !! Str;
  check "line $line: {$expect.defined ?? 'what comes out' !! 'compiles'}{$whole ?? '' !! ' (a fragment)'}", {
    $made.defined && (!$expect.defined || same-text($shown, $expect))
  };
  if $made.defined && $expect.defined && !same-text($shown, $expect)
  {
    note "    what came out:";
    note "      $_" for $shown.lines;
  }
  says($line, $msgs, $src) if $msgs.defined;
}

$dir.rmdir;

# The tables of expressions, '| xtpl | TL++ |': each row's xtpl, assigned in
# a function, has to come out as the row's TL++.
my $in-table = False;
my $rows = 0;
for @lines.kv -> $n, $l
{
  if $l ~~ / ^ '|' \h* 'xtpl' \h* '|' \h* 'TL++' \h* '|' \h* $ /
  {
    $in-table = True;
    next;
  }
  $in-table = False unless $l.starts-with('|');
  next unless $in-table;
  next if $l ~~ / ^ '|' [ \h* '-'+ \h* '|' ]+ \h* $ /;
  # Two code spans; '\|' is a '|' inside one.
  my @cells = ($l ~~ m:g/ '`' ( [ '\\|' || <-[`]> ]+ ) '`' /).map({ (~.[0]).subst('\\|', '|', :g) });
  next unless @cells == 2;
  $rows++;
  my ($x, $t) = @cells[0], @cells[1];
  my $src = "User Function Doc()\n  xDoc := $x\nReturn nil\n";
  my $made = compiled($src);
  my $shown = $made.defined ?? shown($made, '', False) !! Str;
  check "line {$n + 1}: $x", { $made.defined && same-text($shown, "  xDoc := $t") };
  note "    came out: $shown" if $made.defined && !same-text($shown, "  xDoc := $t");
}
check "the tables of expressions were found ($rows rows)", { $rows >= 15 };

# No example lost: the count is the document's, and a block that went
# missing from it -- a fence broken by an edit -- shows here.
check "the examples were all found ({@blocks.grep(*<info> eq 'xtpl').elems})", {
  @blocks.grep(*<info> eq 'xtpl') >= 20
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
