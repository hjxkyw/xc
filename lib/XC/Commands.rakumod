# XC::Commands -- the commands and translations a source brings with it.
#
# AdvPL's preprocessor takes '#command', '#xcommand', '#translate' and
# '#xtranslate': a pattern, '=>', and what it stands for. TOTVS' own include
# files are compressed, and xc cannot read them -- their commands are a list
# in the grammar. But a library's are plain text, in the source itself or in
# an include file beside it:
#
#     #xcommand Feature <cFeat> TestSuite <cSuite> => Function ___TestSuite_<cSuite>____Feat_<cFeat>()
#     #xtranslate @Not_Eof => ( Self:nPosition <= Self:nSourceSize )
#
# xc reads those, and finds in the source where each is used -- matching the
# patterns as the preprocessor does, against the line -- but does not apply
# them: what is written goes out as written. A use is
#
#   - a command, a whole statement: taken whole, as raw text;
#   - a command that stands for a function's header ('Function', 'Static
#     Function', 'Method ... Class'): a function, its header as written and
#     its body read like any other;
#   - a translation inside an expression: a value nothing here looks into.
#
# user-spans() gives, for a text, where each use starts and ends, in
# characters. Nothing is done for a text that brings no directive.

unit module XC::Commands;

# One element of a pattern: a word or a sign ('lit'), a match marker, or an
# optional clause ('[ ... ]') with the elements inside it.
class Elem
{
  has Str  $.kind;                 # lit regular list restricted wild opt
  has Str  $.text = '';            # a lit's text, lower case
  has Str  @.words;                # a restricted marker's words, lower case
  has Elem @.inner;                # an optional clause's elements
}

class Rule
{
  has Str  $.kind;                 # 'command' or 'translate'
  has Bool $.exact;                # 'x': every word in full; else four letters do
  has Elem @.pattern;
  has Str  $.result;
  has Bool $.header;               # it stands for a function's header

  # The first word, lower case -- or Str when the pattern starts with a marker.
  method first(--> Str) { @!pattern && @!pattern[0].kind eq 'lit' ?? @!pattern[0].text !! Str }
}

# ---- tokens ------------------------------------------------------------------
# A line's tokens: strings (closed or not -- TL++ ends one at the line end),
# '.and.'-like words, numbers, names, two-sign operators, and single signs.
my regex token
{
     '"' <-["]>* '"'?
  || "'" <-[']>* "'"?
  || '.' <[A..Za..z]>+ '.'
  || \d+ [ '.' \d+ ]?
  || '.' \d+
  || <[A..Za..z_]> \w*
  || ':=' || '+=' || '-=' || '*=' || '/=' || '==' || '!=' || '<>' || '<=' || '>='
  || '->' || '::' || '++' || '--' || '**' || '=>'
  || \S
}

# The tokens of one line: [text, from, to], the offsets from $base.
sub tokens-of(Str $line, Int $base --> List)
{
  $line.match(/ <token=&token> /, :g).map({ [~$_, $base + .from, $base + .to] }).List
}

# ---- the directives ------------------------------------------------------------
# A directive with its continuation lines -- each ending in ';' -- as one.
sub directives-of(Str $text --> List)
{
  my @out;
  my @lines = $text.lines;
  my $i = 0;
  while $i < @lines
  {
    my $l = @lines[$i];
    if $l ~~ m:i/ ^ \h* '#' \h* (x?) (command || translate) >> \h* (.*) $ /
    {
      my ($x, $kind, $rest) = ~$0, ~$1, ~$2;
      while $rest ~~ / ';' \h* $ / && $i + 1 < @lines
      {
        $rest = $rest.subst(/ ';' \h* $ /, '') ~ ' ' ~ @lines[++$i];
      }
      @out.push(%( :$kind, exact => $x.chars > 0, text => $rest ));
    }
    $i++;
  }
  @out
}

# The pattern's elements, from its text: '<x>', '<x,...>', '<x: a, b>',
# '<*x*>', '<(x)>', '<!x!>', '[ ... ]', and the rest word by word.
sub elements-of(Str $text --> List)
{
  my @stack = [[],];
  my $s = $text;
  my $pos = 0;
  while $pos < $s.chars
  {
    my $rest = $s.substr($pos);
    if $rest ~~ / ^ \s+ /
    {
      $pos += $/.chars;
    }
    elsif $rest ~~ / ^ '\\' (\S) /
    {
      @stack[*-1].push(Elem.new(kind => 'lit', text => (~$0).lc));
      $pos += $/.chars;
    }
    elsif $rest ~~ / ^ '<' \s* ( '*' \s* \w+ \s* '*' || '(' \s* \w+ \s* ')' || '!' \s* \w+ \s* '!' || '"' \s* \w+ \s* '"'
                                 || '#'? \w+ \s* [ ',' \s* '...' || ':' <-[>]>+ ]? ) \s* '>' /
    {
      my $m = ~$0;
      @stack[*-1].push(
          $m.starts-with('*')   ?? Elem.new(kind => 'wild')
       !! $m.contains('...')    ?? Elem.new(kind => 'list')
       !! $m.contains(':')      ?? Elem.new(kind => 'restricted',
                                            words => $m.split(':', 2)[1].split(',').map(*.trim.lc).grep(*.chars).list)
       !!                          Elem.new(kind => 'regular'));
      $pos += $/.chars;
    }
    elsif $rest.starts-with('[')
    {
      @stack.push([]);
      $pos++;
    }
    elsif $rest.starts-with(']') && @stack > 1
    {
      my @inner = @stack.pop.list;
      @stack[*-1].push(Elem.new(kind => 'opt', inner => @inner));
      $pos++;
    }
    else
    {
      my $t = $rest.match(/ ^ <token=&token> /);
      last unless $t;
      @stack[*-1].push(Elem.new(kind => 'lit', text => (~$t).lc));
      $pos += $t.chars;
    }
  }
  @stack[0].list
}

# Whether what a rule stands for opens a function: its first statement (up to
# ';;') starts as a function's header does.
sub is-header(Str $result --> Bool)
{
  my $first = $result.split(';;')[0].trim.lc;
  so $first ~~ / ^ [ [ 'user' || 'static' || 'main' ] \s+ ]? 'function' >> /
  || ($first ~~ / ^ 'method' >> / && $first ~~ / \s 'class' >> /)
  || $first ~~ / ^ 'wsmethod' >> /
}

sub rules-of(Str $text --> List)
{
  directives-of($text).map(-> %d
  {
    my ($pattern, $result) = %d<text>.split('=>', 2);
    $result //= '';
    Rule.new(kind => %d<kind>.lc, exact => %d<exact>, pattern => elements-of($pattern),
             result => $result, header => is-header($result))
  }).grep(*.pattern.elems).List
}

# ---- the include files ---------------------------------------------------------
# The names a text includes: '#include "x.ch"', "'x.ch'", '<x.ch>'.
sub includes-of(Str $text --> List)
{
  $text.lines.map({ m:i/ ^ \h* '#' \h* 'include' \h* <["'<]> (<-["'>]>+) <["'>]> / ?? (~$0).trim !! Empty }).List
}

# A file's text, when it is text: TOTVS' include files start '#zip' and are
# compressed; those are skipped.
sub text-of(IO::Path $p --> Str)
{
  my $bytes = try $p.slurp(:bin);
  return Str without $bytes;
  return Str if $bytes.elems >= 4 && $bytes.subbuf(0, 4).decode('latin-1') eq '#zip';
  my $t = try $bytes.decode('utf-8');
  $t //= $bytes.decode('windows-1252');
  $t
}

# The rules of a text and of every include file found -- beside the source,
# then in each include folder -- each file once.
sub rules-with-includes(Str $text, $dir, @dirs --> List)
{
  my @rules = rules-of($text);
  my %seen;
  my @todo = includes-of($text);
  while @todo
  {
    my $name = @todo.shift;
    next if %seen{$name.lc}++;
    my @places;
    @places.push($dir.IO) if $dir.defined;
    @places.append(@dirs.map(*.IO));
    for @places -> $d
    {
      my $p = $d.add($name);
      next unless $p.f;
      with text-of($p) -> $t
      {
        @rules.append(rules-of($t));
        @todo.append(includes-of($t));
      }
      last;
    }
  }
  @rules
}

# ---- matching -------------------------------------------------------------------
# A word of the pattern against a word of the source: the same, any case; for
# '#command', the first four letters or more of it.
sub same-word(Str $pat, Str $src, Bool $exact --> Bool)
{
  my $s = $src.lc;
  return True if $s eq $pat;
  so !$exact && $s.chars >= 4 && $s.chars < $pat.chars && $pat.starts-with($s) && $pat ~~ / ^ \w+ $ /
}

# The words that can come after element $k: where a marker before them stops.
sub stops-after(@elems, Int $k --> List)
{
  my @s;
  for ($k + 1) ..^ @elems.elems -> $j
  {
    my $e = @elems[$j];
    if $e.kind eq 'lit' { @s.push($e.text); last }
    if $e.kind eq 'opt'
    {
      @s.append(stops-after([Elem.new(kind => 'lit', text => ''), |$e.inner], 0).grep(*.chars));
      next;
    }
    last;
  }
  @s
}

my %OPEN  = '(' => ')', '[' => ']', '{' => '}';

# Whether a token ends an operand -- a name, a number, a string, '.t.', a
# closing bracket -- or starts one: then two in a row are two expressions.
sub ends-operand(Str $t --> Bool)   { so $t ~~ / ^ [ \w || '"' || "'" || '.' <[tTfF]> '.' || <[)\]}]> ] / }
sub starts-operand(Str $t --> Bool) { so $t ~~ / ^ [ \w || '"' || "'" || '.' <[tTfF]> '.' || '{' ] / }

# An expression's tokens from $i: brackets balanced, to a stop word at depth
# zero, a comma -- unless $commas -- or where a second expression starts:
# 'Enable Environment 'T3' 'S SC 01'' is two.
sub expression-end(@toks, Int $i is copy, @stops, Bool $commas, Bool $exact --> Int)
{
  my $start = $i;
  my $depth = 0;
  while $i < @toks.elems
  {
    my $t = @toks[$i][0];
    if $depth == 0 && $i > $start
    {
      last if !$commas && $t eq ',';
      last if @stops.first({ same-word($_, $t, $exact) }).defined;
      last if ends-operand(@toks[$i - 1][0]) && starts-operand($t);
    }
    # A translation inside it is one piece: 'Eval iteratee( value )' in the
    # last part of an 'If c ? a : b'.
    my $inner = translation-end(@toks, $i);
    if $inner > $i
    {
      $i = $inner;
      next;
    }
    if %OPEN{$t}:exists { $depth++ }
    elsif $t eq ')' || $t eq ']' || $t eq '}'
    {
      last if $depth == 0;
      $depth--;
    }
    $i++;
  }
  $i > $start ?? $i !! -1
}

# Where a translation of the source's that starts at token $i ends, or -1.
sub translation-end(@toks, Int $i --> Int)
{
  my $by = $*XC-TRANSLATES // return -1;
  my $rules = $by{@toks[$i][0].lc} // return -1;
  for $rules.list -> $r
  {
    my $end = match-elems($r.pattern, @toks, $i, $r.exact, ());
    return $end if $end > $i;
  }
  -1
}

# The elements against the tokens from $i: where the match ends, or -1.
sub match-elems(@elems, @toks, Int $i is copy, Bool $exact, @outer-stops --> Int)
{
  my $k = 0;
  while $k < @elems.elems
  {
    my $e = @elems[$k];
    if $e.kind eq 'opt'
    {
      # A run of optional clauses, in any order, each at most once.
      my $last = $k;
      $last++ while $last + 1 < @elems.elems && @elems[$last + 1].kind eq 'opt';
      my @run = ($k .. $last).map({ @elems[$_] });
      my @after = (|stops-after(@elems, $last), |@outer-stops);
      my @firsts = @run.map({ stops-after([Elem.new(kind => 'lit', text => ''), |.inner], 0) }).flat;
      my %done;
      loop
      {
        my $moved = False;
        for @run.kv -> $n, $o
        {
          next if %done{$n};
          my $end = match-elems($o.inner, @toks, $i, $exact, (|@firsts, |@after));
          if $end > $i
          {
            $i = $end;
            %done{$n} = True;
            $moved = True;
          }
        }
        last unless $moved;
      }
      $k = $last + 1;
      next;
    }
    return -1 if $i >= @toks.elems;
    given $e.kind
    {
      when 'lit'
      {
        return -1 unless same-word($e.text, @toks[$i][0], $exact);
        $i++;
      }
      when 'restricted'
      {
        return -1 unless $e.words.first({ same-word($_, @toks[$i][0], $exact) }).defined;
        $i++;
      }
      when 'wild'
      {
        $i = @toks.elems;
      }
      default
      {
        my $end = expression-end(@toks, $i, (|stops-after(@elems, $k), |@outer-stops), $e.kind eq 'list', $exact);
        return -1 if $end < 0;
        $i = $end;
      }
    }
    $k++;
  }
  $i
}

# ---- the uses in a source --------------------------------------------------------
# Comments blanked to spaces, the line ends kept: what is left is code and
# strings, at the same offsets.
# (By hand, from mark to mark: a 'subst' with a block gave rakupp a text of
# another length.)
sub line-end(Str $text, Int $from --> Int)
{
  ("\r\n", "\n", "\r").map({ $text.index($_, $from) // $text.chars }).min
}

sub without-comments(Str $text --> Str)
{
  my @out;
  my $n = $text.chars;
  my @marks = '"', "'", '//', '/*';
  my @next = @marks.map({ $text.index($_, 0) // $n });
  my $pos = 0;
  while $pos < $n
  {
    for ^4 -> $k { @next[$k] = $text.index(@marks[$k], $pos) // $n if @next[$k] < $pos }
    my $at = @next.min;
    @out.push($text.substr($pos, $at - $pos));
    last if $at >= $n;
    my $k = (^4).first({ @next[$_] == $at });
    my $end;
    if $k < 2
    {
      # A string: to its quote, or to the end of its line.
      my $close = $text.index(@marks[$k], $at + 1) // $n;
      my $eol = line-end($text, $at + 1);
      $end = $close < $eol ?? $close + 1 !! $eol;
      @out.push($text.substr($at, $end - $at));
    }
    elsif $k == 2
    {
      $end = line-end($text, $at);
      @out.push(' ' x ($end - $at));
    }
    else
    {
      my $close = $text.index('*/', $at + 2);
      $end = $close.defined ?? $close + 2 !! $n;
      @out.push($text.substr($at, $end - $at).subst(/ \N /, ' ', :g));
    }
    $pos = $end;
  }
  @out.join
}

# Where each use is, in characters:
#   cmd   => { from => [to, 'stmt' | 'header'] }
#   trans => { from => to }
our sub user-spans(Str $text, :$dir, :@dirs --> Hash) is export
{
  my %none = cmd => {}, trans => {};
  # Nothing to do for a text that neither defines nor includes anything.
  return %none unless $text ~~ m:i/ '#' \h* [ 'x'? [ 'command' || 'translate' ] || 'include' ] /;
  my @rules = rules-with-includes($text, $dir, @dirs);
  return %none unless @rules;
  my @commands   = @rules.grep(*.kind eq 'command').reverse;
  my @translates = @rules.grep({ .kind eq 'translate' && .first.defined }).reverse;
  # By their first word, for a translation inside a marker's expression. (A
  # '#command' cut to four letters is not looked for there.)
  my %by-first;
  for @translates -> $r { (%by-first{$r.first} //= []).push($r) }
  my $*XC-TRANSLATES = %by-first;

  my %cmd;
  my %trans;
  my $code = without-comments($text);
  my @lines = $code.lines(:!chomp);
  my $offset = 0;
  my $n = 0;
  while $n < @lines.elems
  {
    # A logical line: on through the lines that end in ';'.
    my @toks;
    loop
    {
      my $l = @lines[$n];
      my $body = $l.subst(/ \v+ $ /, '');
      @toks.append(tokens-of($body, $offset));
      $offset += $l.chars;
      $n++;
      last unless $body ~~ / ';' \h* $ / && $n < @lines.elems;
      @toks.pop if @toks && @toks[*-1][0] eq ';';
    }
    next unless @toks;
    next if @toks[0][0] eq '#';
    my $done = False;
    for @commands -> $r
    {
      next unless $r.first.defined && same-word($r.first, @toks[0][0], $r.exact);
      if match-elems($r.pattern, @toks, 0, $r.exact, ()) == @toks.elems
      {
        %cmd{@toks[0][1]} = [@toks[*-1][2], $r.header ?? 'header' !! 'stmt'];
        $done = True;
        last;
      }
    }
    next if $done;
    my $i = 0;
    while $i < @toks.elems
    {
      my $end = -1;
      for @translates -> $r
      {
        next unless same-word($r.first, @toks[$i][0], $r.exact);
        $end = match-elems($r.pattern, @toks, $i, $r.exact, ());
        last if $end > $i;
      }
      if $end > $i
      {
        # A translation that starts the statement takes it whole.
        if $i == 0 { %cmd{@toks[0][1]} = [@toks[*-1][2], 'stmt']; last }
        %trans{@toks[$i][1]} = @toks[$end - 1][2];
        $i = $end;
      }
      else
      {
        $i++;
      }
    }
  }
  %( cmd => %cmd, trans => %trans )
}
