# XC::Parser -- xtpl read by hand.
#
# A cursor over the source's characters and a routine per form, making the
# tree XC::Grammar and XC::Actions make: the same nodes, the same spans. Where
# the grammar is written as a rule -- whitespace taken after each part -- the
# routine takes it in the same places; where it is a token, only where the
# token does. A form that ends past its whitespace (every rule does) leaves
# nothing for a <.ws> after it to take, so no second look is made there.
#
# This first part reads expressions: what a statement holds -- a value, a
# condition, a target, a call made a statement, a chain run for its effect.
#
# Written for rakupp's costs, which are not a compiler's: a call costs a
# microsecond or more, and so does each look at an attribute, where a look
# at a lexical variable -- one of the module's too -- costs some thirty times
# less. So the read under way keeps its state in variables of the module, a
# character is tested where it is read rather than by a call, and the
# operators are read by precedence climbing -- one routine for every level,
# not one call per level for every operand.

unit module XC::Parser;

use XC::AST;
use XC::Grammar;

# ---- characters --------------------------------------------------------------
# Raku's own classes for each character -- \w, \h, \v, \N, \d, and '\n' as a
# character class holds it -- worked out with the regexes themselves, once,
# so that the parser reads them as the grammar did. A "\r\n" is one
# character; it reads as "\r". ASCII is tested where it is read; these are
# for the rest.
my constant CW  = 1;     # \w
my constant CH  = 2;     # \h
my constant CV  = 4;     # \v
my constant CNN = 8;     # \N: not a newline
my constant CD  = 16;    # \d
my constant CNL = 32;    # <[\n]>, in a character class

sub class-of(Int $c --> Int)
{
  my $s = $c == 13 ?? "\r" !! $c.chr;
  my $b = 0;
  $b +|= CW  if $s ~~ / ^ \w $ /;
  $b +|= CH  if $s ~~ / ^ \h $ /;
  $b +|= CV  if $s ~~ / ^ \v $ /;
  $b +|= CNN if $s ~~ / ^ \N $ /;
  $b +|= CD  if $s ~~ / ^ \d $ /;
  $b +|= CNL if $s ~~ / ^ <[\n]> $ /;
  $b
}
my @CLASS = (^256).map(&class-of);
my %WIDE;
sub cls($c) { $c < 0 ?? 0 !! $c < 256 ?? @CLASS[$c] !! (%WIDE{$c} //= class-of($c)) }

sub w($c)
{
  ($c >= 97 && $c <= 122) || ($c >= 65 && $c <= 90) || ($c >= 48 && $c <= 57) || $c == 95
    || ($c > 127 && so cls($c) +& CW)
}
sub hs($c) { $c == 32 || $c == 9 || ($c > 127 && so cls($c) +& CH) }
sub vs($c) { $c >= 0 && so cls($c) +& CV }
sub nn($c) { $c >= 0 && so cls($c) +& CNN }
sub dg($c) { ($c >= 48 && $c <= 57) || ($c > 127 && so cls($c) +& CD) }
sub alpha($c) { ($c >= 97 && $c <= 122) || ($c >= 65 && $c <= 90) || $c == 95 }

# The words a statement starts with, which a value cannot (XC::Grammar,
# 'stmtword').
my constant STMT-KEYWORDS = set <
  return local private public static if elseif else endif while enddo for next
  exit loop do case endcase otherwise begin recover end namespace using
>;

# ---- the read under way ------------------------------------------------------
my $SRC = '';
my @O;                   # a code per character, and three -1 after
my $N = 0;
my $P = 0;               # the cursor
my %TRANS;               # the source's own translations: start => end
my $USER-ON = False;
my $IN-WITH = False;     # inside 'with object': ':x' is the subject's
my $IN-BLOCK = 0;        # in a lambda or a code block: no '|>', no 'fallback'
my $IN-DQ = 0;           # in a '"' string's '${ }': no '"' string
my $IN-SQ = 0;
my $IN-EXP = 0;          # in '%exp:...%': a '%' is its end
my @LS;                  # each line's start, end (its \v, or $N) and what
my @LE;                  # it holds (L-HAS-...)
my @LF;
my @LQ;                  # the last ';' that carries each line on, -1, or -2: not yet known
my $LK = 0;              # the line line-of() found last
my $CURRENT;             # the parser whose source the above are

my constant L-HAS-EQ   = 1;     # a '='
my constant L-HAS-BAR  = 2;     # a '|'
my constant L-HAS-DIV  = 4;     # a '/'
my constant L-HAS-SEMI = 8;     # a ';'

# The levels of the operators, loosest first (see climb).
my constant L-ELVIS = 1;
my constant L-OR    = 2;
my constant L-AND   = 3;
my constant L-NOT   = 4;
my constant L-CMP   = 5;
my constant L-RANGE = 6;
my constant L-ADD   = 7;
my constant L-MUL   = 8;
my constant L-POW   = 9;

my $OP = '';             # the operator op-at() found, and its length
my $OPLEN = 0;

sub back($at) { $P = $at; Nil }
sub text($from, $to) { $SRC.substr($from, $to - $from) }

# ---- nodes, as XC::Actions makes them ----------------------------------------
sub span($e, $from, $to)
{
  $e.src-from = $from;
  $e.src-to   = $to;
  $e
}

sub joined($b)
{
  my $l = $b.left;
  if $l.defined
  {
    my $f = $l.src-from;
    my $t = $b.right.src-to;
    if $f >= 0 && $t >= 0
    {
      $b.src-from = $f;
      $b.src-to   = $t;
    }
  }
  $b
}

sub interval($lo, $hi)
{
  my $i = Interval.new(lo => $lo, hi => $hi);
  my $f = $lo.src-from;
  my $t = $hi.src-to;
  if $f >= 0 && $t >= 0
  {
    $i.src-from = $f;
    $i.src-to   = $t;
  }
  $i
}

sub assign-expr($a)
{
  AssignExpr.new(target => $a.target, op => $a.op, value => $a.value)
}

sub incdec($target, $op, $where)
{
  AssignExpr.new(target => $target, op => ($op eq '++' ?? '+=' !! '-='),
                 value => Literal.new(type => 'Numeric', text => '1'), incdec => $where)
}

# A trailer is a list: what it makes, where it ends, and what it holds.
my constant T-TRANS  = 0;    # text
my constant T-HASH   = 1;    # key
my constant T-SCALL  = 2;    # name, args
my constant T-SMEM   = 3;    # name
my constant T-METHOD = 4;    # name, args
my constant T-MEMBER = 5;    # name
my constant T-INDEX  = 6;    # indices
my constant T-INALS  = 7;    # expr
my constant T-FIELD  = 8;    # name, macro

sub applied($b, $t)
{
  my $k = $t[0];
  return Member.new(base => $b, name => $t[2])                      if $k == T-MEMBER;
  return MethodCall.new(base => $b, name => $t[2], args => $t[3].list)   if $k == T-METHOD;
  return Index.new(base => $b, indices => $t[2].list)                    if $k == T-INDEX;
  return AliasField.new(base => $b, field => $t[2], macro => $t[3]) if $k == T-FIELD;
  return HashIndex.new(base => $b, key => $t[2])                    if $k == T-HASH;
  return SafeMember.new(base => $b, name => $t[2])                  if $k == T-SMEM;
  return SafeCall.new(base => $b, name => $t[2], args => $t[3].list)     if $k == T-SCALL;
  return InAlias.new(base => $b, expr => $t[2])                     if $k == T-INALS;
  UserTrans.new(base => $b, text => $t[2])
}

# A base and the trailers after it, each step spanning from the start of the
# whole to the end of its trailer ($outer: the caller spans a base with no
# trailer itself).
sub trailed($base, $bf, $bt, @trailers, $from, $outer = False)
{
  span($base, $bf, $bt) if $base.src-from < 0 && !($outer && !@trailers);
  return $base unless @trailers;
  my $e = $base;
  for @trailers -> $t
  {
    $e = applied($e, $t);
    $e.src-from = $from;
    $e.src-to   = $t[1];
  }
  $e
}

# ---- the parser --------------------------------------------------------------
class Parser is export
{
  has Str  $.src;
  has      %.trans;                # the source's own translations: start => end
  has Bool $.in-with is rw = False; # inside 'with object': ':x' is the subject's
  has      @!o;
  has Int  $!n;
  has      @!ls;
  has      @!le;
  has      @!lf;
  has      @!lq;

  submethod TWEAK()
  {
    my $t = $!src.contains("\r\n") ?? $!src.subst("\r\n", "\r", :g) !! $!src;
    my @o = $t.ords;
    my $n = @o.elems;
    die "XC::Parser: a character of more than one code in the source" unless $n == $!src.chars;
    # The lines, and what each holds that sees() looks for. (In lexical
    # variables: a loop over an attribute costs thirty times more.)
    # (No call, no '+|' and no constant in the loop: rakupp runs such a loop
    # some fifty times faster. A wide character is looked at after it.)
    my @ls = 0;
    my @le;
    my @lf;
    my @wide;
    my $eq = 0;
    my $bar = 0;
    my $div = 0;
    my $semi = 0;
    my $i = 0;
    while $i < $n
    {
      my $c = @o[$i];
      if $c >= 10 && $c <= 13
      {
        @le.push($i);
        @lf.push($eq + $bar * 2 + $div * 4 + $semi * 8);      # L-HAS-...
        @ls.push($i + 1);
        $eq = 0;
        $bar = 0;
        $div = 0;
        $semi = 0;
      }
      elsif $c == 61  { $eq = 1 }
      elsif $c == 124 { $bar = 1 }
      elsif $c == 47  { $div = 1 }
      elsif $c == 59  { $semi = 1 }
      elsif $c > 127  { @wide.push($i) }
      $i++;
    }
    @le.push($n);
    @lf.push($eq * L-HAS-EQ + $bar * L-HAS-BAR + $div * L-HAS-DIV + $semi * L-HAS-SEMI);
    # A line end beyond ASCII (none comes from windows-1252): the lines
    # again, a character at a time.
    if @wide.first({ cls(@o[$_]) +& CV })
    {
      @ls = 0;
      @le = ();
      @lf = ();
      my $f = 0;
      for ^$n -> $k
      {
        my $c = @o[$k];
        if vs($c)
        {
          @le.push($k);
          @lf.push($f);
          @ls.push($k + 1);
          $f = 0;
        }
        elsif $c == 61  { $f +|= L-HAS-EQ }
        elsif $c == 124 { $f +|= L-HAS-BAR }
        elsif $c == 47  { $f +|= L-HAS-DIV }
        elsif $c == 59  { $f +|= L-HAS-SEMI }
      }
      @le.push($n);
      @lf.push($f);
    }
    @o.push(-1, -1, -1);
    @!o := @o;
    $!n = $n;
    @!ls := @ls;
    @!le := @le;
    @!lf := @lf;
    @!lq = -2 xx @ls.elems;
  }

  # Reads one form at $at: 'value', 'guardexpr', 'cond', 'expr', 'lvalue',
  # 'callst' or 'pipest'. Gives the node -- Nil when it does not read -- and
  # where it ended.
  method read(Str $form, Int $at)
  {
    unless $CURRENT === self
    {
      $SRC = $!src;
      @O := @!o;
      $N = $!n;
      %TRANS := %!trans;
      $USER-ON = so %!trans;
      @LS := @!ls;
      @LE := @!le;
      @LF := @!lf;
      @LQ := @!lq;
      $LK = 0;
      $CURRENT = self;
    }
    $IN-WITH = $!in-with;
    $IN-BLOCK = $IN-DQ = $IN-SQ = $IN-EXP = 0;
    $P = $at;
    my $node;
    if    $form eq 'value'     { $node = value() }
    elsif $form eq 'guardexpr' { $node = guardexpr() }
    elsif $form eq 'cond'      { $node = cond() }
    elsif $form eq 'expr'      { $node = expr() }
    elsif $form eq 'lvalue'    { $node = lvalue() }
    elsif $form eq 'callst'    { $node = callst() }
    elsif $form eq 'pipest'    { $node = pipest() }
    else                       { die "XC::Parser: no form '$form'" }
    ($node, $P)
  }
}

# ---- whitespace --------------------------------------------------------------
# <.ws>: blanks, comments, and a ';' that carries the line on. Not between two
# word characters: there it does not match, and what wants it fails.
sub ws()
{
  my $p = $P;
  my $c = @O[$p];
  unless $c == 32 || $c == 9 || $c == 59 || $c == 47 || $c == 38 || ($c > 127 && hs($c))
  {
    if $p > 0 && (($c >= 97 && $c <= 122) || ($c >= 65 && $c <= 90) || ($c >= 48 && $c <= 57) || $c == 95
                  || ($c > 127 && cls($c) +& CW))
    {
      my $b = @O[$p - 1];
      return False if ($b >= 97 && $b <= 122) || ($b >= 65 && $b <= 90) || ($b >= 48 && $b <= 57) || $b == 95
                      || ($b > 127 && cls($b) +& CW);
    }
    return True;
  }
  loop
  {
    $c = @O[$p];
    if $c == 32 || $c == 9
    {
      $p++;
    }
    elsif $c == 59
    {
      my $q = linecont($p);
      last if $q < 0;
      $p = $q;
    }
    elsif ($c == 47 || $c == 38) && @O[$p + 1] == $c
    {
      $p = line-end($p + 2);
    }
    elsif $c == 47 && @O[$p + 1] == 42
    {
      my $q = block-end($p);
      last if $q < 0;
      $p = $q;
    }
    elsif $c > 127 && hs($c)
    {
      $p++;
    }
    else
    {
      last;
    }
  }
  $P = $p;
  True
}

# '\N*' from $p: where the line ends.
sub line-end($p) { @LE[line-of($p)] }

# The line $p is on: the one found last, the next, or a search.
sub line-of($p)
{
  my $k = $LK;
  return $k if @LS[$k] <= $p && $p <= @LE[$k];
  $k++;
  if $k < @LS.elems && @LS[$k] <= $p && $p <= @LE[$k]
  {
    $LK = $k;
    return $k;
  }
  my $lo = 0;
  my $hi = @LS.elems - 1;
  while $lo < $hi
  {
    my $mid = ($lo + $hi + 1) div 2;
    if @LS[$mid] <= $p { $lo = $mid } else { $hi = $mid - 1 }
  }
  $LK = $lo;
  $lo
}

# '/*' .*? '*/' at $p: where it ends, or -1.
sub block-end($p)
{
  my $q = $p + 2;
  while $q < $N
  {
    last if @O[$q] == 42 && @O[$q + 1] == 47;
    $q++;
  }
  $q < $N ?? $q + 2 !! -1
}

# ';' \h* [ <linecomment> || <blockcomment> ]? \h* \v at $p: where it ends,
# or -1.
sub linecont($p)
{
  my $q = $p + 1;
  $q++ while hs(@O[$q]);
  my $c = @O[$q];
  if ($c == 47 || $c == 38) && @O[$q + 1] == $c
  {
    $q = line-end($q + 2);
  }
  elsif $c == 47 && @O[$q + 1] == 42
  {
    my $e = block-end($q);
    $q = $e if $e >= 0;
  }
  $q++ while hs(@O[$q]);
  vs(@O[$q]) ?? $q + 1 !! -1
}

# ---- small pieces ------------------------------------------------------------
# Where a name starting at $p ends ('<[A..Za..z_]> \w*'), or -1.
sub name-end($p)
{
  my $c = @O[$p];
  return -1 unless ($c >= 97 && $c <= 122) || ($c >= 65 && $c <= 90) || $c == 95;
  my $q = $p + 1;
  loop
  {
    while $q < $N
    {
      my $d = @O[$q];
      last unless ($d >= 97 && $d <= 122) || ($d >= 65 && $d <= 90) || ($d >= 48 && $d <= 57) || $d == 95;
      $q++;
    }
    last unless @O[$q] > 127 && w(@O[$q]);
    $q++;
  }
  $q
}

# Whether the text at $p is the word whose codes, lower case, are @c --
# letter case aside.
sub iword-at($p, @c)
{
  my $i = 0;
  for @c -> $k
  {
    my $c = @O[$p + $i];
    return False unless $c == $k || ($k >= 97 && $k <= 122 && $c == $k - 32);
    $i++;
  }
  True
}
my constant W-FALLBACK = 'fallback'.ords.List;
my constant W-NOT      = '.not.'.ords.List;
my constant W-EXP      = 'exp'.ords.List;
my constant W-ATAIL    = 'atail'.ords.List;

sub stmtword-at($p)
{
  my $e = name-end($p);
  $e >= 0 && (STMT-KEYWORDS{text($p, $e).lc}:exists)
}

# <sees>: the rest of the line, and the lines a ';' carries it on to, as
# the grammar's look-ahead took it, given to its ahead(). Without a '=' (a
# '|' for a chain) nor a '/' in it, ahead() says no before reading it: so
# does this.
sub sees($what, $item)
{
  my $p = $P;
  my $k = line-of($p);
  my $mark = ($what eq 'pipe' ?? L-HAS-BAR !! L-HAS-EQ) +| L-HAS-DIV;
  my $any = False;
  loop
  {
    my $e = @LE[$k];
    my $f = @LF[$k];
    $any = True if $f +& $mark;
    if $e < $N && $f +& L-HAS-SEMI && continued($p, $e)
    {
      $k++;
      $p = $e + 1;
      next;
    }
    return False unless $any;
    return XC::Grammar::ahead(text($P, $e), $what, $item);
  }
}

# Whether a ';' in [$p, $e) has only blanks, and a '//' or '&&' comment,
# after it.
sub continued($p, $e)
{
  my $k = line-of($p);
  my $q = @LQ[$k];
  $q = @LQ[$k] = last-semi(@LS[$k], $e) if $q == -2;
  $q >= $p
}

# The last ';' in [$p, $e) with only blanks, and a '//' or '&&' comment,
# after it -- or -1.
sub last-semi($p, $e)
{
  my $last = -1;
  my $k = $p;
  loop
  {
    while $k < $e
    {
      last if @O[$k] == 59;
      $k++;
    }
    last if $k >= $e;
    my $q = $k + 1;
    $q++ while $q < $e && hs(@O[$q]);
    my $c = @O[$q];
    $last = $k if $q == $e || (($c == 47 || $c == 38) && @O[$q + 1] == $c);
    $k++;
  }
  $last
}

# <opnext>: an operator's first character, or 'in' or 'has' as a word.
sub opnext()
{
  my $c = @O[$P];
  return True if $c == 42 || $c == 47 || $c == 37 || $c == 43 || $c == 45 || $c == 46 || $c == 60 || $c == 62
              || $c == 61 || $c == 33 || $c == 36 || $c == 35 || $c == 63 || $c == 124 || $c == 94;
  my $d = @O[$P + 1] +| 32;
  return True if ($c +| 32) == 105 && $d == 110 && !w(@O[$P + 2]);
  ($c +| 32) == 104 && $d == 97 && (@O[$P + 2] +| 32) == 115 && !w(@O[$P + 3])
}

# ---- values, conditions, guards ----------------------------------------------
# [ <chained> || <guardexpr> ]: a declaration's or an assignment's value.
sub value()
{
  my $start = $P;
  my $c = chained();
  return $c if $c.defined;
  $P = $start;
  guardexpr()
}

# token chained { <.sees('bind')> <assignment> }
sub chained()
{
  my $start = $P;
  return Nil unless sees('bind', False);
  my $a = assignment();
  return back($start) without $a;
  span(assign-expr($a), $start, $P)
}

# token passign { <.sees('bind item')> <assignment> }
sub passign()
{
  my $start = $P;
  return Nil unless sees('bind', True);
  my $a = assignment();
  return back($start) without $a;
  span(assign-expr($a), $start, $P)
}

# token cond { [ <.sees('bind item')> <assignment> ] || <expr> }
sub cond()
{
  my $start = $P;
  if sees('bind', True)
  {
    my $a = assignment();
    return span(assign-expr($a), $start, $P) if $a.defined;
    $P = $start;
  }
  expr()
}

# token listitem { <passign> || <guardexpr> }
sub listitem()
{
  my $start = $P;
  my $a = passign();
  return $a if $a.defined;
  $P = $start;
  guardexpr()
}

# rule guardexpr { <guarded> [ <?[fF]> <!{ in a block }> <fbkw> <fallback> ]? }
sub guardexpr()
{
  my $start = $P;
  my $g = expr();
  return Nil without $g;
  my $fb;
  my $c = @O[$P];
  if ($c == 102 || $c == 70) && !$IN-BLOCK && iword-at($P, W-FALLBACK) && !w(@O[$P + 8])
  {
    my $save = $P;
    $P += 8;
    if ws()
    {
      my $f = expr();
      $fb = $f if $f.defined;
    }
    $P = $save without $fb;
  }
  span($fb.defined ?? Guard.new(expr => $g, fallback => $fb) !! $g, $start, $P)
}

# ---- expressions -------------------------------------------------------------
# token expr { [ <unary> <!before <.opnext>> ] || [ <elvis> <feed>* ] }
#
# The value read alone first is the operators' first operand too: they would
# read it again the same, so they are given it.
sub expr()
{
  my $start = $P;
  my $u = unary();
  if $u.defined
  {
    return span($u, $start, $P) unless opnext();
  }
  else
  {
    $P = $start;
  }
  my $source = climb(L-ELVIS, $u, False);
  return back($start) without $source;
  my $elvis-end = $P;
  my @stages;
  while @O[$P] == 124 && @O[$P + 1] == 62 && !$IN-BLOCK
  {
    my $save = $P;
    my $st = feed();
    if $st.defined { @stages.push($st) } else { $P = $save; last }
  }
  if @stages
  {
    span($source, $start, $elvis-end);
    return span(Pipeline.new(source => $source, stages => @stages), $start, $P);
  }
  span($source, $start, $P)
}

# rule feed { <?[|]> <!{ in a block }> '|>' <stage> }
# rule stage { <nscall> || <call> || <name> }
sub feed()
{
  $P += 2;
  return Nil unless ws();
  my $start = $P;
  my $e = name-end($start);
  return Nil if $e < 0;
  my $st = nscall();
  return $st if $st.defined;
  $P = $start;
  $st = call();
  return $st if $st.defined;
  $P = $e;
  return Nil unless ws();
  Call.new(name => text($start, $e), args => ())
}

# The levels of the operators, loosest first, as the grammar nests its rules:
#
#   rule elvis     { <orexpr> [ <?[?]> <elvisop> <orexpr> ]* }       '?:', from the right
#   rule orexpr    { <andexpr> [ <?[.]> <orop> <andexpr> ]* }        '.or.'
#   rule andexpr   { <notexpr> [ <?[.]> <andop> <notexpr> ]* }       '.and.'
#   rule notexpr   { [ <?[!.]> <negate> ]? <cmpexpr> }               '!' '.not.', before one
#   rule cmpexpr   { <rangeexpr> [ <?[=!<>$#iIhH]> <cmptail> ]* }
#   rule cmptail   { [ <op=inop> <inrhs> ] || [ <op=cmpop> <rangeexpr> ] }
#   rule rangeexpr { <lo> [ '..' <hi> <?before <.ws> '|>'> ]? }      once; 'in': no '|>'
#   rule addexpr   { <mulexpr> [ <?[+\-]> <addop> <mulexpr> ]* }
#   rule mulexpr   { <powexpr> [ <?[*/%]> <mulop> <powexpr> ]* }
#   rule powexpr   { <unary> [ <?[*^]> <powop> <unary> ]* }
# (The levels: L-ELVIS and on, at the top.)

# The level of the operator at the cursor, or 0; the operator in $OP.
sub op-at()
{
  my $p = $P;
  my $c = @O[$p];
  my $d = @O[$p + 1];
  if $c == 43 { $OP = '+'; $OPLEN = 1; return L-ADD }
  if $c == 45 { $OP = '-'; $OPLEN = 1; return L-ADD }
  if $c == 42
  {
    if $d == 42 { $OP = '**'; $OPLEN = 2; return L-POW }
    $OP = '*'; $OPLEN = 1;
    return L-MUL;
  }
  if $c == 47 { $OP = '/'; $OPLEN = 1; return L-MUL }
  if $c == 37
  {
    if $d == 37 { $OP = '%%'; $OPLEN = 2; return L-MUL }
    return 0 if $IN-EXP;
    $OP = '%'; $OPLEN = 1;
    return L-MUL;
  }
  if $c == 94 { $OP = '^'; $OPLEN = 1; return L-POW }
  if $c == 46
  {
    if $d == 46 { $OP = '..'; $OPLEN = 2; return L-RANGE }
    my $d2 = @O[$p + 2] +| 32;
    if ($d +| 32) == 111 && $d2 == 114 && @O[$p + 3] == 46
    {
      $OP = '.or.'; $OPLEN = 4;
      return L-OR;
    }
    if ($d +| 32) == 97 && $d2 == 110 && (@O[$p + 3] +| 32) == 100 && @O[$p + 4] == 46
    {
      $OP = '.and.'; $OPLEN = 5;
      return L-AND;
    }
    return 0;
  }
  if $c == 63
  {
    return 0 unless $d == 58;
    $OP = '?:'; $OPLEN = 2;
    return L-ELVIS;
  }
  # inop: 'in' >> (letter case aside); cmpop: '==' '!=' '<>' '>=' '<=' '>'
  # '<' '$' '#' '=' (not before '>') 'has' >>.
  if $c == 61
  {
    if $d == 61 { $OP = '=='; $OPLEN = 2; return L-CMP }
    return 0 if $d == 62;
    $OP = '='; $OPLEN = 1;
    return L-CMP;
  }
  if $c == 60
  {
    if $d == 62 { $OP = '<>'; $OPLEN = 2; return L-CMP }
    if $d == 61 { $OP = '<='; $OPLEN = 2; return L-CMP }
    $OP = '<'; $OPLEN = 1;
    return L-CMP;
  }
  if $c == 62
  {
    if $d == 61 { $OP = '>='; $OPLEN = 2; return L-CMP }
    $OP = '>'; $OPLEN = 1;
    return L-CMP;
  }
  if $c == 33
  {
    return 0 unless $d == 61;
    $OP = '!='; $OPLEN = 2;
    return L-CMP;
  }
  if $c == 36 { $OP = '$'; $OPLEN = 1; return L-CMP }
  if $c == 35 { $OP = '#'; $OPLEN = 1; return L-CMP }
  if ($c +| 32) == 105 && ($d +| 32) == 110 && !w(@O[$p + 2])
  {
    $OP = 'in'; $OPLEN = 2;
    return L-CMP;
  }
  if ($c +| 32) == 104 && ($d +| 32) == 97 && (@O[$p + 2] +| 32) == 115 && !w(@O[$p + 3])
  {
    $OP = 'has'; $OPLEN = 3;
    return L-CMP;
  }
  0
}

# The operators from level $min on, $first the first operand when it has
# been read; $in: a range needs no '|>' after it (the right of 'in').
#
# The tree is the grammar's: left to right at each level, '?:' from the
# right, and a level's operand made of the tighter ones. An operator whose
# operand does not read is not taken, and the cursor goes back before it.
# $cap: the tightest operator that may still come -- the tighter ones were
# read by the operand before, or failed there.
sub climb($min, $first, $in)
{
  my $start = $P;
  my $x = $first;
  my $cap = 99;
  unless $x.defined
  {
    my $c = @O[$P];
    if $min <= L-NOT && ($c == 33 || ($c == 46 && iword-at($P, W-NOT)))
    {
      $P += $c == 33 ?? 1 !! 5;
      return back($start) unless ws();
      my $r = climb(L-CMP, Nil, False);
      return back($start) without $r;
      $x = span(Binary.new(op => '!', left => Expr, right => $r), $start, $P);
      $cap = L-NOT;
    }
    else
    {
      $x = unary();
      return back($start) without $x;
    }
  }
  loop
  {
    my $level = op-at();
    last if $level == 0 || $level < $min || $level > $cap;
    my $save = $P;
    if $level == L-RANGE
    {
      $P += 2;
      my $hi;
      $hi = climb(L-ADD, Nil, False) if ws();
      if $hi.defined && ($in || (@O[$P] == 124 && @O[$P + 1] == 62))
      {
        $x = interval($x, $hi);
        $cap = L-CMP;
        next;
      }
      $P = $save;
      last;
    }
    my $op = $OP;
    $P += $OPLEN;
    my $r;
    if ws()
    {
      if    $level == L-ELVIS { $r = climb(L-ELVIS, Nil, False) }
      elsif $level == L-CMP   { $r = climb(L-RANGE, Nil, $op eq 'in') }
      else                    { $r = climb($level + 1, Nil, False) }
    }
    unless $r.defined
    {
      $P = $save;
      last;
    }
    $x = joined(Binary.new(op => $op, left => $x, right => $r));
    $cap = $level == L-ELVIS ?? 0 !! $level;
  }
  $x
}

# token unary
# {
#      [ <?[+\-]> <incop> <.ws> <!before <.ws><.ws><literal>> <postfix> ]
#   || [ [ <?[+\-]> <sign> <.ws> ]? <.ws> <postfix> ]
# }
sub unary()
{
  my $start = $P;
  my $c = @O[$start];
  if $c == 43 || $c == 45
  {
    if @O[$start + 1] == $c
    {
      $P += 2;
      if ws()
      {
        my $at = $P;
        my $lit = literal();
        $P = $at;
        unless $lit.defined
        {
          my $x = postfix();
          return span(incdec($x, $c == 43 ?? '++' !! '--', 'pre'), $start, $P) if $x.defined;
        }
      }
      $P = $start;
    }
    $P++;
    my $neg = False;
    if ws() { $neg = $c == 45 } else { $P = $start }
    return back($start) unless ws();
    my $x = postfix();
    return back($start) without $x;
    return $neg ?? span(Binary.new(op => 'neg', left => Expr, right => $x), $start, $P) !! $x;
  }
  return back($start) unless ws();
  my $x = postfix();
  return back($start) without $x;
  $x
}

# token postfix
# {
#      [ <?litstart> <literal> <.ws> ]
#   || [ <primary> [ [ <?{ $user-on }> || <?[{?:\[\-]> ] <trailer> ]* [ <?[+\-]> <incop> <.ws> ]? ]
# }
sub postfix()
{
  my $start = $P;
  my $c = @O[$start];
  if ($c >= 48 && $c <= 57) || $c == 46 || $c == 34 || $c == 39
     || (($c +| 32) == 110 && (@O[$start + 1] +| 32) == 105 && (@O[$start + 2] +| 32) == 108 && !w(@O[$start + 3]))
  {
    my $lit = literal();
    return span($lit, $start, $P) if $lit.defined && ws();
    $P = $start;
  }
  my $base = primary();
  return back($start) without $base;
  my $base-end = $P;
  my @tr;
  loop
  {
    my $t = trailer();
    last without $t;
    @tr.push($t);
  }
  my $d = @O[$P];
  if ($d == 43 || $d == 45) && @O[$P + 1] == $d
  {
    my $save = $P;
    $P += 2;
    if ws()
    {
      my $operand = trailed($base, $start, $base-end, @tr, $start);
      return span(incdec($operand, $d == 43 ?? '++' !! '--', 'post'), $start, $P);
    }
    $P = $save;
  }
  return span($base, $start, $P) unless @tr;
  span(trailed($base, $start, $base-end, @tr, $start, True), $start, $P)
}

# rule trailer
# {
#      [<?{ $user-on }><ttrans>]
#   || <?[{]><thash> || <?[?]><tsafe> || <?[:]>[ <tmethod> || <tmember> ]
#   || <?[\[]><tindex> || <?[\-]>[ <tinalias> || <tfield> ]
# }
# The trailer (see T-TRANS), or Nil.
sub trailer()
{
  my $start = $P;
  my $c = @O[$start];
  if $USER-ON && (%TRANS{$start}:exists) && %TRANS{$start} > $start
  {
    my $end = %TRANS{$start};
    my $t = text($start, $end);
    $P = $end;
    return [T-TRANS, $P, $t] if ws();
    $P = $start;
  }
  if $c == 58
  {
    # rule tmethod { [ '::' || ':' ] <member> '(' ~ ')' <arglist> }
    # rule tmember { [ '::' || ':' ] <member> }
    $P += @O[$start + 1] == 58 ?? 2 !! 1;
    return back($start) unless ws();
    my $me = name-end($P);
    return back($start) if $me < 0;
    my $name = text($P, $me);
    $P = $me;
    return back($start) unless ws();
    my $args = call-args();
    return [T-METHOD, $P, $name, $args] if $args.defined;
    return [T-MEMBER, $P, $name];
  }
  if $c == 91
  {
    # rule tindex { '[' ~ ']' [ <expr> [ ',' <expr> ]* ] }
    $P++;
    return back($start) unless ws();
    my @i;
    my $x = expr();
    return back($start) without $x;
    @i.push($x);
    while @O[$P] == 44
    {
      my $save = $P;
      $P++;
      my $y;
      $y = expr() if ws();
      if $y.defined { @i.push($y) } else { $P = $save; last }
    }
    return back($start) unless @O[$P] == 93;
    $P++;
    return back($start) unless ws();
    return [T-INDEX, $P, @i];
  }
  if $c == 45
  {
    return Nil unless @O[$start + 1] == 62;
    my $t = tinalias();
    return $t if $t.defined;
    return tfield();
  }
  if $c == 123 { return thash() }
  if $c == 63  { return tsafe() }
  Nil
}

# rule thash { <?after <[\w)\]}]>> '{' ~ '}' <key> }
sub thash()
{
  my $start = $P;
  my $b = $start > 0 ?? @O[$start - 1] !! -1;
  return Nil unless w($b) || $b == 41 || $b == 93 || $b == 125;
  $P++;
  return back($start) unless ws();
  my $key = expr();
  return back($start) unless $key.defined && @O[$P] == 125;
  $P++;
  return back($start) unless ws();
  [T-HASH, $P, $key]
}

# rule tsafe { '?.' <member> [ '(' ~ ')' <arglist> ]? }
sub tsafe()
{
  my $start = $P;
  return Nil unless @O[$start + 1] == 46;
  $P += 2;
  return back($start) unless ws();
  my $me = name-end($P);
  return back($start) if $me < 0;
  my $name = text($P, $me);
  $P = $me;
  return back($start) unless ws();
  my $args = call-args();
  return [T-SCALL, $P, $name, $args] if $args.defined;
  [T-SMEM, $P, $name]
}

# '(' ~ ')' <arglist> in a rule: the arguments, past the whitespace after the
# ')' -- or Nil, the cursor where it was.
sub call-args()
{
  my $start = $P;
  return Nil unless @O[$start] == 40;
  $P++;
  return back($start) unless ws();
  my $args = arglist();
  return back($start) unless @O[$P] == 41;
  $P++;
  return back($start) unless ws();
  $args
}

# rule tinalias { '->' '(' ~ ')' <expr> }
sub tinalias()
{
  my $start = $P;
  $P += 2;
  return back($start) unless ws() && @O[$P] == 40;
  $P++;
  return back($start) unless ws();
  my $e = expr();
  return back($start) unless $e.defined && @O[$P] == 41;
  $P++;
  return back($start) unless ws();
  [T-INALS, $P, $e]
}

# rule tfield { '->' [ <fieldmacro> || <member> ] }
sub tfield()
{
  my $start = $P;
  $P += 2;
  return back($start) unless ws();
  if @O[$P] == 38
  {
    my $at = $P;
    my $m = amacro();
    return [T-FIELD, $P, '', $m] if $m.defined;
    $P = $at;
  }
  my $me = name-end($P);
  return back($start) if $me < 0;
  my $name = text($P, $me);
  $P = $me;
  return back($start) unless ws();
  [T-FIELD, $P, $name, Expr]
}

# ---- primaries ---------------------------------------------------------------
# token primary: each form behind the character it starts with, whitespace
# after it.
sub primary()
{
  my $start = $P;
  if $USER-ON && (%TRANS{$start}:exists) && %TRANS{$start} > $start
  {
    my $end = %TRANS{$start};
    $P = $end;
    my $u = span(UserTrans.new(text => text($start, $end)), $start, $end);
    return $u if ws();
    $P = $start;
  }
  my $c = @O[$start];
  my $x;
  if ($c >= 97 && $c <= 122) || ($c >= 65 && $c <= 90) || $c == 95
  {
    my $we = name-end($start);
    $x = nscall() if @O[$we] == 46 && w(@O[$we + 1]);
    unless $x.defined
    {
      $P = $we;
      if ws()
      {
        my $k = @O[$P];
        if $k == 40
        {
          $P = $start;
          $x = call();
        }
        elsif $k == 45 && @O[$P + 1] == 62
        {
          $P = $start;
          $x = aliasfield();
        }
      }
      unless $x.defined
      {
        $P = $we;
        $x = Name.new(name => text($start, $we));
      }
    }
  }
  elsif $c == 40
  {
    return parens();
  }
  elsif $c == 58
  {
    $x = selfacc();
    $x //= subjacc();
  }
  elsif $c == 123
  {
    $x = codeblock();
    $x //= jsonliteral();
    $x //= hashliteral();
    $x //= arrayliteral();
  }
  elsif $c == 91 { $x = lambda() }
  elsif $c == 38 { $x = amacro() }
  elsif $c == 37
  {
    my $e = sqlexp();
    $x = span(ExprList.new(items => ($e,)), $start, $P) if $e.defined;
  }
  return back($start) without $x;
  return back($start) unless ws();
  $x
}

# [:s '(' ~ ')' [ [ <passign> || <guardexpr> ] [ ',' <listitem> ]* ] ]
sub parens()
{
  my $start = $P;
  $P++;
  return back($start) unless ws();
  my $first = passign();
  $first //= guardexpr();
  return back($start) without $first;
  my @more;
  while @O[$P] == 44
  {
    my $save = $P;
    $P++;
    my $y;
    $y = listitem() if ws();
    if $y.defined { @more.push($y) } else { $P = $save; last }
  }
  return back($start) unless @O[$P] == 41;
  $P++;
  return back($start) unless ws();
  @more ?? span(ExprList.new(items => ($first, |@more)), $start, $P) !! $first
}

# rule selfacc { '::' <member> [ '(' ~ ')' <arglist> ]? }
sub selfacc()
{
  my $start = $P;
  return Nil unless @O[$start + 1] == 58;
  $P += 2;
  member-call(SelfRef.new, $start)
}

# rule subjacc { <?{ in 'with object' }> ':' <member> [ '(' ~ ')' <arglist> ]? }
sub subjacc()
{
  my $start = $P;
  return Nil unless $IN-WITH;
  $P++;
  member-call(SubjectRef.new, $start)
}

sub member-call($base, $start)
{
  return back($start) unless ws();
  my $me = name-end($P);
  return back($start) if $me < 0;
  my $name = text($P, $me);
  $P = $me;
  return back($start) unless ws();
  my $args = call-args();
  $args.defined ?? MethodCall.new(base => $base, name => $name, args => $args.list)
                !! Member.new(base => $base, name => $name)
}

# rule call { <name> '(' ~ ')' <arglist> }
sub call()
{
  my $start = $P;
  my $e = name-end($start);
  return Nil if $e < 0;
  $P = $e;
  return back($start) unless ws();
  my $args = call-args();
  return back($start) without $args;
  span(Call.new(name => text($start, $e), args => $args.list), $start, $P)
}

# rule nscall { <qname> '(' ~ ')' <arglist> }
# token qname { <[A..Za..z_]> \w* [ '.' <!logword> <[A..Za..z_]> \w* ]+ }
# token logword { :i [ 'and' || 'or' || 'not' ] <![\w]> }
sub nscall()
{
  my $start = $P;
  my $e = name-end($start);
  return Nil if $e < 0;
  my $segments = 0;
  while @O[$e] == 46
  {
    my $s = $e + 1;
    my $se = name-end($s);
    last if $se < 0;
    my $len = $se - $s;
    last if ($len == 2 || $len == 3) && text($s, $se).lc eq 'and' | 'or' | 'not';
    $e = $se;
    $segments++;
  }
  return Nil unless $segments;
  my $name = text($start, $e);
  $P = $e;
  return back($start) unless ws();
  my $args = call-args();
  return back($start) without $args;
  span(Call.new(name => $name, args => $args.list), $start, $P)
}

# rule arglist { <slot> [ ',' <slot> ]* }   rule slot { <arg>? }
# Omitted for an empty position; none at all for '()'.
sub arglist()
{
  my @s;
  my $a = arg();
  @s.push($a // Omitted.new);
  while @O[$P] == 44
  {
    my $save = $P;
    $P++;
    unless ws()
    {
      $P = $save;
      last;
    }
    my $b = arg();
    @s.push($b // Omitted.new);
  }
  (@s == 1 && @s[0] ~~ Omitted) ?? () !! @s.List
}

# rule arg { [<?[@]><byref>] || [ <.sees('assign item')> <assignment> ] || <expr> }
sub arg()
{
  my $start = $P;
  if @O[$start] == 64
  {
    my $r = byref();
    return span($r, $start, $P) if $r.defined;
    $P = $start;
  }
  if sees('assign', True)
  {
    my $a = assignment();
    return span(assign-expr($a), $start, $P) if $a.defined;
    $P = $start;
  }
  my $e = expr();
  return back($start) without $e;
  span($e, $start, $P)
}

# rule byref { '@' [ <selfacc> || [ <name> <trailer>* ] ] }
sub byref()
{
  my $start = $P;
  $P++;
  return back($start) unless ws();
  my $at = $P;
  if @O[$at] == 58
  {
    my $s = selfacc();
    return Ref.new(target => $s) if $s.defined;
    $P = $at;
  }
  my $e = name-end($at);
  return back($start) if $e < 0;
  my $name = Name.new(name => text($at, $e));
  $P = $e;
  return back($start) unless ws();
  my @tr = trailers();
  return Ref.new(target => trailed($name, $at, $e, @tr, $start)) if @tr;
  Ref.new(target => span($name, $at, $e))
}

# rule macro { '&' [ [ '(' ~ ')' <expr> ] || [ <name> '.'? ] ] <mcall>? }
# token mcall { '(' ~ ')' <arglist> }
sub amacro()
{
  my $start = $P;
  $P++;
  return back($start) unless ws();
  my $target;
  if @O[$P] == 40
  {
    my $at = $P;
    $P++;
    if ws()
    {
      my $e = expr();
      if $e.defined && @O[$P] == 41
      {
        $P++;
        $target = $e if ws();
      }
    }
    $P = $at without $target;
  }
  unless $target.defined
  {
    my $e = name-end($P);
    return back($start) if $e < 0;
    $target = Name.new(name => text($P, $e));
    $P = $e;
    return back($start) unless ws();
    if @O[$P] == 46
    {
      $P++;
      return back($start) unless ws();
    }
  }
  my $args;
  if @O[$P] == 40
  {
    my $at = $P;
    $P++;
    my $a = arglist();
    if @O[$P] == 41
    {
      $P++;
      if ws() { $args = $a } else { $P = $at }
    }
    else
    {
      $P = $at;
    }
  }
  Macro.new(target => $target, called => $args.defined, args => $args.defined ?? $args.list !! ())
}

# token sqlexp { '%' :i 'exp' ':' <.ws> [ <expr> ] <.ws> '%' } -- a '%' inside
# is its end
sub sqlexp()
{
  my $start = $P;
  return Nil unless iword-at($start + 1, W-EXP) && @O[$start + 4] == 58;
  $P += 5;
  return back($start) unless ws();
  $IN-EXP++;
  my $e = expr();
  $IN-EXP--;
  return back($start) without $e;
  return back($start) unless ws() && @O[$P] == 37;
  $P++;
  $e
}

# rule aliasfield
# {
#   <alias=name> '->' [ [ '(' ~ ')' [ <expr> [ ',' <listitem> ]* ] ] || <fieldmacro> || <field=member> ]
# }
sub aliasfield()
{
  my $start = $P;
  my $e = name-end($start);
  return Nil if $e < 0;
  my $alias = text($start, $e);
  $P = $e;
  return back($start) unless ws() && @O[$P] == 45 && @O[$P + 1] == 62;
  $P += 2;
  return back($start) unless ws();
  if @O[$P] == 40
  {
    my $at = $P;
    $P++;
    if ws()
    {
      my $x = expr();
      if $x.defined
      {
        my @more;
        while @O[$P] == 44
        {
          my $save = $P;
          $P++;
          my $y;
          $y = listitem() if ws();
          if $y.defined { @more.push($y) } else { $P = $save; last }
        }
        if @O[$P] == 41
        {
          $P++;
          if ws()
          {
            return InAlias.new(alias => $alias, expr => @more ?? ExprList.new(items => ($x, |@more)) !! $x);
          }
        }
      }
    }
    $P = $at;
  }
  if @O[$P] == 38
  {
    my $at = $P;
    my $m = amacro();
    return AliasField.new(alias => $alias, field => '', macro => $m) if $m.defined;
    $P = $at;
  }
  my $fe = name-end($P);
  return back($start) if $fe < 0;
  my $field = text($P, $fe);
  $P = $fe;
  return back($start) unless ws();
  AliasField.new(alias => $alias, field => $field)
}

# rule lambda
# {
#   '[' <lparam=name> [ ',' <lparam=name> ] ** 0..5 ']' <lbody> <!before \h* '|>'>
# }
sub lambda()
{
  my $start = $P;
  $P++;
  return back($start) unless ws();
  my @params;
  my $e = name-end($P);
  return back($start) if $e < 0;
  @params.push(text($P, $e));
  $P = $e;
  return back($start) unless ws();
  while @params < 6 && @O[$P] == 44
  {
    my $save = $P;
    $P++;
    my $ok = False;
    if ws()
    {
      my $pe = name-end($P);
      if $pe >= 0
      {
        my $p = text($P, $pe);
        $P = $pe;
        if ws() { @params.push($p); $ok = True }
      }
    }
    unless $ok
    {
      $P = $save;
      last;
    }
  }
  return back($start) unless @O[$P] == 93;
  $P++;
  return back($start) unless ws();
  $IN-BLOCK++;
  my $body = blockexpr();
  $IN-BLOCK--;
  return back($start) without $body;
  my $q = $P;
  $q++ while hs(@O[$q]);
  return back($start) if @O[$q] == 124 && @O[$q + 1] == 62;
  Lambda.new(type => 'Block', text => text($start, $P).trim, params => @params, body => ($body,))
}

# rule codeblock
# {
#   '{' [ '||' || [ '|' <name>* % ',' '|' ] ] <blockexpr>* % ',' '}'
# }
sub codeblock()
{
  my $start = $P;
  $P++;
  return back($start) unless ws();
  my @params;
  if @O[$P] == 124 && @O[$P + 1] == 124
  {
    $P += 2;
    return back($start) unless ws();
  }
  elsif @O[$P] == 124
  {
    $P++;
    return back($start) unless ws();
    my $e = name-end($P);
    if $e >= 0
    {
      @params.push(text($P, $e));
      $P = $e;
      while @O[$P] == 44
      {
        my $save = $P;
        $P++;
        my $ok = False;
        if ws()
        {
          my $pe = name-end($P);
          if $pe >= 0
          {
            @params.push(text($P, $pe));
            $P = $pe;
            $ok = True;
          }
        }
        unless $ok
        {
          $P = $save;
          last;
        }
      }
    }
    return back($start) unless ws() && @O[$P] == 124;
    $P++;
    return back($start) unless ws();
  }
  else
  {
    return back($start);
  }
  $IN-BLOCK++;
  my @body;
  my $b = blockexpr();
  if $b.defined
  {
    @body.push($b);
    while @O[$P] == 44
    {
      my $save = $P;
      $P++;
      my $y;
      $y = blockexpr() if ws();
      if $y.defined { @body.push($y) } else { $P = $save; last }
    }
  }
  $IN-BLOCK--;
  return back($start) unless ws() && @O[$P] == 125;
  $P++;
  return back($start) unless ws();
  CodeBlock.new(type => 'Block', text => text($start, $P).trim, params => @params, body => @body)
}

# rule blockexpr { [ <.sees('assign item')> <assignment> ] || <expr> }
sub blockexpr()
{
  my $start = $P;
  if sees('assign', True)
  {
    my $a = assignment();
    return span(assign-expr($a), $start, $P) if $a.defined;
    $P = $start;
  }
  my $e = expr();
  return back($start) without $e;
  span($e, $start, $P)
}

# rule jsonliteral { '{' ~ '}' [ ':' || [ <pair>+ % ',' ] ] }
# rule hashliteral { '{' ~ '}' [ '=>' || [ <hashpair>+ % ',' ] ] }
sub jsonliteral() { pairs(False) }
sub hashliteral() { pairs(True) }

sub pairs($hash)
{
  my $start = $P;
  $P++;
  return back($start) unless ws();
  my @pairs;
  if $hash ?? (@O[$P] == 61 && @O[$P + 1] == 62) !! @O[$P] == 58
  {
    $P += $hash ?? 2 !! 1;
    return back($start) unless ws();
  }
  else
  {
    my $p = kv-pair($hash);
    return back($start) without $p;
    @pairs.push($p);
    while @O[$P] == 44
    {
      my $save = $P;
      $P++;
      my $q;
      $q = kv-pair($hash) if ws();
      if $q.defined { @pairs.push($q) } else { $P = $save; last }
    }
  }
  return back($start) unless @O[$P] == 125;
  $P++;
  return back($start) unless ws();
  $hash ?? HashLit.new(type => 'Object', text => text($start, $P).trim, pairs => @pairs)
        !! JsonLit.new(type => 'JSON', text => text($start, $P).trim, pairs => @pairs)
}

# rule pair { <expr> ':' <expr> }   rule hashpair { <expr> '=>' <expr> }
sub kv-pair($hash)
{
  my $start = $P;
  my $k = expr();
  return back($start) without $k;
  if $hash
  {
    return back($start) unless @O[$P] == 61 && @O[$P + 1] == 62;
    $P += 2;
  }
  else
  {
    return back($start) unless @O[$P] == 58;
    $P++;
  }
  return back($start) unless ws();
  my $v = expr();
  return back($start) without $v;
  KeyValue.new(key => $k, value => $v)
}

# rule arrayliteral { '{' ~ '}' [ <aitem> [ ',' <aitem> ]* ] }   rule aitem { <expr>? }
sub arrayliteral()
{
  my $start = $P;
  $P++;
  return back($start) unless ws();
  my @items;
  my $x = expr();
  @items.push($x // Omitted.new);
  while @O[$P] == 44
  {
    my $save = $P;
    $P++;
    unless ws()
    {
      $P = $save;
      last;
    }
    my $y = expr();
    @items.push($y // Omitted.new);
  }
  return back($start) unless @O[$P] == 125;
  $P++;
  return back($start) unless ws();
  @items = () if @items == 1 && @items[0] ~~ Omitted;
  ArrayLit.new(type => 'Array', text => text($start, $P).trim, items => @items)
}

# ---- literals ----------------------------------------------------------------
# token literal { <number> || <string> || <logical> || <nildef> }: the node, the
# cursor at its end (no whitespace taken), or Nil.
sub literal()
{
  my $start = $P;
  my $c = @O[$start];
  my $d = @O[$start + 1];
  if ($c >= 48 && $c <= 57) || ($c > 127 && dg($c)) || ($c == 46 && dg($d))
  {
    my $e = number-end($start);
    $P = $e;
    return Literal.new(type => 'Numeric', text => text($start, $e));
  }
  if $c == 34 || $c == 39
  {
    return string();
  }
  if $c == 46 && (($d +| 32) == 116 || ($d +| 32) == 102) && @O[$start + 2] == 46
  {
    $P = $start + 3;
    return Literal.new(type => 'Logical', text => text($start, $start + 3));
  }
  if ($c +| 32) == 110 && ($d +| 32) == 105 && (@O[$start + 2] +| 32) == 108 && !w(@O[$start + 3])
  {
    $P = $start + 3;
    return Literal.new(type => 'Variant', text => text($start, $start + 3));
  }
  Nil
}

# token number { [ \d+ [ "'" \d+ ]* [ '.' \d+ [ "'" \d+ ]* ]? ] || [ '.' \d+ ] }
sub number-end($p)
{
  my $q = $p;
  if @O[$q] == 46
  {
    $q++;
    $q++ while dg(@O[$q]);
    return $q;
  }
  $q++ while dg(@O[$q]);
  $q = groups($q);
  if @O[$q] == 46 && dg(@O[$q + 1])
  {
    $q++;
    $q++ while dg(@O[$q]);
    $q = groups($q);
  }
  $q
}

sub groups($p is copy)
{
  while @O[$p] == 39 && dg(@O[$p + 1])
  {
    $p++;
    $p++ while dg(@O[$p]);
  }
  $p
}

# token string { '"' ... || "'" ... }, with xtpl's '${ }': a Literal, or an
# Interp when it holds an expression. A string inside a '${ }' cannot use
# the quote of one around it.
sub string()
{
  my $q = @O[$P];
  return Nil if ($q == 34 && $IN-DQ) || ($q == 39 && $IN-SQ);
  if $q == 34 { $IN-DQ++ } else { $IN-SQ++ }
  my $s = string-in($q);
  if $q == 34 { $IN-DQ-- } else { $IN-SQ-- }
  $s
}

sub string-in($q)
{
  my $start = $P;
  $P++;
  my @parts;
  my $exprs = False;
  loop
  {
    my $c = @O[$P];
    if $c == 36 && @O[$P + 1] == 123
    {
      my $at = $P;
      $P += 2;
      if ws()
      {
        my $e = expr();
        if $e.defined && ws() && @O[$P] == 125
        {
          $P++;
          @parts.push($e);
          $exprs = True;
          next;
        }
      }
      $P = $at;
      last;
    }
    my $t = $P;
    loop
    {
      while $t < $N
      {
        my $d = @O[$t];
        last if $d == $q || $d < 32 || $d > 127 || ($d == 36 && @O[$t + 1] == 123);
        $t++;
      }
      my $d = @O[$t];
      last if $d == $q || $d < 0 || ($d == 36 && @O[$t + 1] == 123) || (cls($d) +& CNL);
      $t++;
    }
    last if $t == $P;
    @parts.push(text($P, $t));
    $P = $t;
  }
  if @O[$P] == $q
  {
    $P++;
  }
  elsif !(@O[$P] < 0 || !nn(@O[$P]))
  {
    return back($start);
  }
  my $text = text($start, $P);
  $exprs ?? Interp.new(type => 'Character', text => $text, parts => @parts)
         !! Literal.new(type => 'Character', text => $text)
}

# ---- assignments, targets, statements made of a call -------------------------
# rule assignment { <!stmtword> <lvalue> <assignop> [ <chained> || <guardexpr> ] }
sub assignment()
{
  my $start = $P;
  return Nil if stmtword-at($start);
  return back($start) unless ws();
  my $t = lvalue();
  return back($start) without $t;
  my $op = assignop();
  return back($start) without $op;
  return back($start) unless ws();
  my $v = value();
  return back($start) without $v;
  Assignment.new(target => $t, op => $op, value => $v)
}

# token assignop { ':=' || '+=' || '-=' || '*=' || '/=' || '=' }
sub assignop()
{
  my $c = @O[$P];
  my $d = @O[$P + 1];
  if $d == 61
  {
    if $c == 58 { $P += 2; return ':=' }
    if $c == 43 { $P += 2; return '+=' }
    if $c == 45 { $P += 2; return '-=' }
    if $c == 42 { $P += 2; return '*=' }
    if $c == 47 { $P += 2; return '/=' }
  }
  if $c == 61
  {
    $P++;
    return '=';
  }
  Nil
}

# rule lvalue
# {
#      [ '(' ~ ')' <pexpr> <trailer>+ ] || [ <call> <trailer>+ ] || <atail>
#   || [ <macro> <trailer>* ]
#   || [ '@'? [ <selfacc> || <subjacc> || <name> ] <trailer>* ]
# }
sub lvalue()
{
  my $start = $P;
  my $c = @O[$start];
  if $c == 40
  {
    $P++;
    if ws()
    {
      my $bf = $P;
      my $e = expr();
      if $e.defined && @O[$P] == 41
      {
        my $bt = $P;
        $P++;
        if ws()
        {
          my @tr = trailers();
          return span(trailed($e, $bf, $bt, @tr, $start, True), $start, $P) if @tr;
        }
      }
    }
    $P = $start;
  }
  if alpha($c)
  {
    my $call = call();
    if $call.defined
    {
      my $bt = $P;
      my @tr = trailers();
      return span(trailed($call, $start, $bt, @tr, $start, True), $start, $P) if @tr;
    }
    $P = $start;
    if iword-at($start, W-ATAIL)
    {
      my $q = $start + 5;
      $q++ while hs(@O[$q]);
      if @O[$q] == 40
      {
        my $a = call();
        return span($a, $start, $P) if $a.defined;
        $P = $start;
      }
    }
  }
  if $c == 38
  {
    my $m = amacro();
    if $m.defined
    {
      my $bt = $P;
      my @tr = trailers();
      return span(trailed($m, $start, $bt, @tr, $start, True), $start, $P);
    }
    $P = $start;
  }
  if $c == 64
  {
    $P++;
    return back($start) unless ws();
  }
  my $bf = $P;
  my $base;
  my $bt;
  if @O[$bf] == 58
  {
    $base = selfacc();
    $base //= subjacc();
    $bt = $P;
  }
  unless $base.defined
  {
    my $e = name-end($bf);
    return back($start) if $e < 0;
    $base = Name.new(name => text($bf, $e));
    $P = $e;
    $bt = $e;
    return back($start) unless ws();
  }
  my @tr = trailers();
  span(trailed($base, $bf, $bt, @tr, $start, True), $start, $P)
}

sub trailers()
{
  my @tr;
  loop
  {
    my $t = trailer();
    last without $t;
    @tr.push($t);
  }
  @tr
}

# rule callst
# {
#   <!stmtword> [ [ <call> <trailer>* ] || [ <name> <trailer>+ ] || [ <subjacc> <trailer>* ]
#              || [ <selfacc> <trailer>* ] || [ <macrocall> <trailer>* ] || [ <nscall> <trailer>* ]
#              || [ <macro> ] || [ <inalias> ] || [ '(' ~ ')' <pexpr> <trailer>* ] ]
# }
# The call the statement makes, spanned as the statement's.
sub callst()
{
  my $start = $P;
  return Nil if stmtword-at($start);
  return back($start) unless ws();
  my $at = $P;
  my $c = @O[$at];
  if alpha($c)
  {
    my $call = call();
    if $call.defined
    {
      my $bt = $P;
      my @tr = trailers();
      return span(trailed($call, $at, $bt, @tr, $start, True), $start, $P);
    }
    $P = $at;
    my $e = name-end($at);
    $P = $e;
    if ws()
    {
      my @tr = trailers();
      return span(trailed(Name.new(name => text($at, $e)), $at, $e, @tr, $start, True), $start, $P) if @tr;
    }
    $P = $at;
  }
  if $c == 58
  {
    my $s = subjacc();
    $s //= selfacc();
    if $s.defined
    {
      my $bt = $P;
      my @tr = trailers();
      return span(trailed($s, $at, $bt, @tr, $start, True), $start, $P);
    }
    $P = $at;
  }
  if $c == 38
  {
    my $m = amacro();
    if $m.defined && $m.called
    {
      my $bt = $P;
      my @tr = trailers();
      return span(trailed($m, $at, $bt, @tr, $start, True), $start, $P);
    }
    $P = $at;
  }
  if alpha($c)
  {
    my $ns = nscall();
    if $ns.defined
    {
      my $bt = $P;
      my @tr = trailers();
      return span(trailed($ns, $at, $bt, @tr, $start, True), $start, $P);
    }
    $P = $at;
  }
  if $c == 38
  {
    my $m = amacro();
    return span(trailed($m, $at, $P, (), $start, True), $start, $P) if $m.defined;
    $P = $at;
  }
  if alpha($c)
  {
    my $a = aliasfield();
    if $a.defined && $a ~~ InAlias
    {
      return span(trailed($a, $at, $P, (), $start, True), $start, $P);
    }
    $P = $at;
  }
  if $c == 40
  {
    $P++;
    if ws()
    {
      my $bf = $P;
      my $e = expr();
      if $e.defined && @O[$P] == 41
      {
        my $bt = $P;
        $P++;
        if ws()
        {
          my @tr = trailers();
          return span(trailed($e, $bf, $bt, @tr, $start, True), $start, $P);
        }
      }
    }
  }
  back($start)
}

# rule pipest { <!stmtword> <elvis> <feed>+ }
sub pipest()
{
  my $start = $P;
  return Nil if stmtword-at($start);
  return back($start) unless ws();
  my $at = $P;
  my $source = climb(L-ELVIS, Nil, False);
  return back($start) without $source;
  my $elvis-end = $P;
  my @stages;
  while @O[$P] == 124 && @O[$P + 1] == 62 && !$IN-BLOCK
  {
    my $save = $P;
    my $st = feed();
    if $st.defined { @stages.push($st) } else { $P = $save; last }
  }
  return back($start) unless @stages;
  span($source, $at, $elvis-end);
  span(Pipeline.new(source => $source, stages => @stages), $start, $P)
}
