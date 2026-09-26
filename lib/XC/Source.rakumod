# XC::Source -- positions in a source text: characters and lines.
#
# Two things make this less simple than it looks:
#
# - rakupp 4.0.1 reports a submatch's '.from' and '.to' in UTF-8 BYTES (and a
#   grammar's top-level '.to', and '$/.to' in a code block); Rakudo in
#   characters. A source with an accent anywhere before a node -- any real
#   Protheus source -- puts every later byte offset past the character it
#   means. The unit is probed once at run time rather than assumed, so this
#   keeps working if rakupp starts reporting characters.
# - "\r\n" is ONE character in Raku (a single grapheme), so a CRLF file has no
#   "\n" for '.index' to find. Lines come from '.lines', which knows all three
#   line ends.
#
# Everything else in xc works in characters: this is the only place that
# knows about bytes.

unit class XC::Source;

has Str $.text;
has @!rows;                    # per line: [char-start, byte-start, ascii?, text]

# Whether grammar match offsets are bytes: after 'é' (one character, two
# bytes), a match at the next character starts at 1 in characters and 2 in
# bytes. A grammar, not a plain '~~': rakupp gives characters for a plain
# match and bytes only in grammar matches.
my grammar Probe
{
  token TOP { . <x> }
  token x   { '!' }
}

sub offsets-in-bytes(--> Bool)
{
  state $bytes = Probe.parse('é!')<x>.from == 2;
  $bytes
}

submethod TWEAK()
{
  my ($c, $b) = 0, 0;
  for $!text.lines(:!chomp) -> $line
  {
    my $ascii = $line.chars == $line.encode.bytes;
    @!rows.push([$c, $b, $ascii, $line]);
    $c += $line.chars;
    $b += $line.encode.bytes;
  }
  @!rows.push([$c, $b, True, '']);          # the end of the text
}

# The row holding a match offset: the last one starting at or before it.
method !row(Int $o --> Int)
{
  my $col = offsets-in-bytes() ?? 1 !! 0;
  my ($lo, $hi) = 0, @!rows.end;
  while $lo < $hi
  {
    my $mid = ($lo + $hi + 1) div 2;
    if @!rows[$mid][$col] <= $o { $lo = $mid } else { $hi = $mid - 1 }
  }
  $lo
}

# A match offset as a character offset.
method char(Int $o --> Int)
{
  return $o unless offsets-in-bytes();
  my ($c, $b, $ascii, $text) = @!rows[self!row($o)];
  return $c + ($o - $b) if $ascii;
  # A line with a multi-byte character: walk it to the byte.
  my $n = 0;
  for $text.comb -> $g
  {
    last if $b >= $o;
    $b += $g.encode.bytes;
    $n++;
  }
  $c + $n
}

# The line (from 1) a match offset is on.
method line(Int $o --> Int)
{
  my $last = max(1, @!rows.elems - 1);      # the real lines, without the end row
  min(self!row($o) + 1, $last)
}
