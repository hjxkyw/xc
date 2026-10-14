# The tree xc makes of a source, as JSON: what the C++ port is compared with.
#
#   rakupp tools/ast-json.raku tree  FILE...    the whole tree, one line a file
#   rakupp tools/ast-json.raku roots FILE...    each expression a statement holds
#   rakupp tools/ast-json.raku check FILE...    what the checks say of it
#   rakupp tools/ast-json.raku --out=DIR --list=LIST [--from=N] [--to=M]
#                                               all three, for each file of
#                                               LIST: DIR/<n>.tree,
#                                               DIR/<n>.roots, DIR/<n>.check
#   --dict=sx3.csv [--strict] before the rest   the checks with a
#                                               dictionary, as bin/xc's
#                                               --dict and --dict-strict
#
# A node is an object: "node", its class's name, then each attribute in the
# order the class declares them (its own, then its parents'), the memos left
# out. An undefined value is null. A string is the source's bytes
# (windows-1252): every byte below 0x20 or above 0x7E, '"' and '\', as \u00XX
# -- the byte, not a character of Unicode. An offset -- an attribute named
# '...-from' or '...-to' -- counts bytes: a "\r\n" is one character to Raku,
# two bytes to C++.
#
# The tree: a line 'cmd' with the uses of the source's own commands ('from
# to kind', in bytes; kind 'stmt' or 'header'), a line 'trans' with its own
# translations ('from to'), then the JSON.
#
# The roots: a line 'file <path>', the 'trans' line, then a line for each
# expression the
# statements hold: its form -- what the grammar read it as: value,
# guardexpr, cond, expr, lvalue, callst, pipest --, its offset, 1 if it is
# inside a 'with object', and its tree.
#
# The checks: a line for each error, then one for each warning, in the
# order XC::Check gives them -- 'error' or 'warning', the line, and the
# message as a JSON string.
#
# The source is read as bin/xc reads it, but without a folder: the commands
# of the include files beside it are not looked for. From the repository's
# top, as the tests are run.

use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;
use XC::Commands;
use XC::Check;

# ---- offsets: characters to bytes --------------------------------------------
my @CRLF;                # where each "\r\n" is, in characters

sub crlf-of(Str $src)
{
  @CRLF = ();
  my $at = 0;
  for $src.lines(:!chomp) -> $l
  {
    $at += $l.chars;
    @CRLF.push($at - 1) if $l.ends-with("\r\n");
  }
}

sub byte-of(Int $c --> Int)
{
  return $c if $c < 0 || !@CRLF;
  my ($lo, $hi) = 0, @CRLF.elems;
  while $lo < $hi
  {
    my $mid = ($lo + $hi) div 2;
    if @CRLF[$mid] < $c { $lo = $mid + 1 } else { $hi = $mid }
  }
  $c + $lo
}

# ---- JSON --------------------------------------------------------------------
sub str-json(Str $s --> Str)
{
  return '"' ~ $s ~ '"' if $s ~~ / ^ <[\x20..\x7E] - ["\\]>* $ /;
  my $b = $s.encode('windows-1252');
  my @out = '"';
  for $b.list -> $c
  {
    if $c >= 0x20 && $c <= 0x7E && $c != 0x22 && $c != 0x5C { @out.push($c.chr) }
    else { @out.push('\\u00' ~ $c.fmt('%02X')) }
  }
  @out.push('"');
  @out.join
}

my %ATTRS;               # class => [attribute name, is an offset]

sub json($x --> Str)
{
  return 'null' unless $x.defined;
  given $x
  {
    when Str        { return str-json($x) }
    when Bool       { return $x ?? 'true' !! 'false' }
    when Int        { return ~$x }
    when Positional { return '[' ~ $x.list.map(&json).join(',') ~ ']' }
  }
  my $class = $x.^name;
  my $attrs = %ATTRS{$class} //= $x.^attributes.grep({ !.name.contains('memo-') })
                                   .map({ [$_, .name.substr(2), so .name ~~ / '-' [ 'from' || 'to' ] $ /] }).List;
  my @parts = '"node":"' ~ $class.subst('XC::AST::', '') ~ '"';
  for @$attrs -> [$a, $name, $offset]
  {
    my $v = $a.get_value($x);
    $v = byte-of($v) if $offset && $v.defined;
    @parts.push('"' ~ $name ~ '":' ~ json($v));
  }
  '{' ~ @parts.join(',') ~ '}'
}

# ---- the expressions the statements hold -------------------------------------
sub roots(@body, Bool $with, @out, Str $src)
{
  stmt-roots($_, $with, @out, $src) for @body;
}

sub add(@out, $e, Str $form, Bool $with)
{
  @out.push([$e, $form, $with]) if $e.defined && $e.src-from >= 0;
}

sub stmt-roots($s, Bool $with, @out, Str $src)
{
  given $s
  {
    when Declaration
    {
      for .declarators -> $d
      {
        add(@out, $d.init, $d.type-first ?? 'guardexpr' !! 'value', $with);
        add(@out, $_, 'expr', $with) for $d.dims;
      }
    }
    when Assignment
    {
      add(@out, .target, 'lvalue', $with);
      add(@out, .value, .op eq '?=' ?? 'expr' !! 'value', $with);
    }
    when DefaultStmt
    {
      for .pairs -> $p
      {
        add(@out, $p.target, 'lvalue', $with);
        add(@out, $p.value, 'guardexpr', $with);
      }
    }
    when CallStmt
    {
      # Not AdvPL's 'If( c, a, b )' made a statement: 'if' starts statements.
      my $c = .call;
      add(@out, $c, $c ~~ Pipeline ?? 'pipest' !! 'callst', $with) unless $c ~~ Call && $c.name eq 'If';
    }
    when ReturnStmt | BreakStmt { add(@out, .value, 'guardexpr', $with) }
    when IfStmt | CaseStmt
    {
      add(@out, .header-decl.init, 'expr', $with) if $_ ~~ IfStmt && .header-decl.defined;
      if $_ ~~ CaseStmt
      {
        add(@out, .subject-decl.init, 'expr', $with) if .subject-decl.defined;
        if .subject-assign.defined
        {
          add(@out, .subject-assign.target, 'lvalue', $with);
          add(@out, .subject-assign.value, 'value', $with);
        }
      }
      add(@out, .cond, 'cond', $with) for .branches;
      roots(.body, $with, @out, $src) for .branches;
      roots(.otherwise, $with, @out, $src);
    }
    when WhileStmt
    {
      add(@out, .header-decl.init, 'expr', $with) if .header-decl.defined;
      add(@out, .cond, 'cond', $with);
      roots(.body, $with, @out, $src);
    }
    when ForStmt
    {
      add(@out, $_, 'expr', $with) for .from, .to, .step;
      roots(.body, $with, @out, $src);
    }
    when ForInStmt
    {
      add(@out, .source, 'expr', $with) unless .source ~~ Interval;
      roots(.body, $with, @out, $src);
    }
    when ForTimesStmt
    {
      add(@out, .count, 'expr', $with);
      roots(.body, $with, @out, $src);
    }
    when Modified
    {
      add(@out, .cond, 'cond', $with);
      # 'exec f() if c': the statement is an expression.
      if .stmt ~~ CallStmt && .src-from >= 0 && $src.substr(.src-from, 5).lc eq 'exec ' | "exec\t"
      {
        add(@out, .stmt.call, 'expr', $with);
      }
      else
      {
        stmt-roots(.stmt, $with, @out, $src);
      }
    }
    when Deferred { stmt-roots(.stmt, $with, @out, $src) }
    when UsingAlias
    {
      add(@out, .order, 'expr', $with);
      roots(.body, $with, @out, $src);
    }
    when WithObject
    {
      add(@out, .subject, 'expr', $with);
      roots(.body, True, @out, $src);
    }
    when TryStmt
    {
      roots($_, $with, @out, $src) for .body, .handler, .finally;
    }
    when SequenceStmt
    {
      roots($_, $with, @out, $src) for .body, .recover;
    }
    when TransactionStmt { roots(.body, $with, @out, $src) }
  }
}

# ---- a source ----------------------------------------------------------------
# What the checks say of a program, as bin/xc asks them.
my %DICTIONARY;
my $STRICT = False;
sub checks(Program $p, Str $src --> Str)
{
  my %c = check-all($p, lines => $src.lines.elems, dictionary => %DICTIONARY, strict => $STRICT, source => $src);
  my @lines;
  @lines.push("error {.key} {str-json(.value)}") for %c<errors>.list;
  @lines.push("warning {.key} {str-json(.value)}") for %c<warnings>.list;
  @lines ?? @lines.join("\n") !! 'none'
}

# The tree's JSON, the roots' lines and the checks' -- or Str when the
# grammar does not read the source.
sub one(Str $file --> List)
{
  my $src = $file.IO.slurp(:bin).decode('windows-1252');
  my $*FURTHEST = 0;
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  return (Str, Str, Str) unless $m;
  crlf-of($src);
  my %spans = user-spans($src, dir => Str, dirs => ());
  my $trans = 'trans' ~ %spans<trans>.sort(+*.key).map({ " {byte-of(+.key)} {byte-of(+.value)}" }).join;
  my $cmd = 'cmd' ~ %spans<cmd>.sort(+*.key).map({ " {byte-of(+.key)} {byte-of(+.value[0])} {.value[1]}" }).join;
  my $tree = "$cmd\n$trans\n" ~ json($m.made);
  my @out;
  roots(.body, False, @out, $src) for |$m.made.functions, |$m.made.methods;
  stmt-roots($_, False, @out, $src) for $m.made.statics;
  my @lines = "file $file", $trans;
  @lines.push("{.[1]} {byte-of(.[0].src-from)} {.[2] ?? 1 !! 0} {json(.[0])}") for @out;
  ($tree, @lines.join("\n"), checks($m.made, $src))
}

multi sub MAIN('tree', *@files)
{
  for @files -> $f
  {
    my ($tree, $, $) = one($f);
    say $tree // 'null';
  }
}

multi sub MAIN('roots', *@files)
{
  for @files -> $f
  {
    my ($, $roots, $) = one($f);
    say $roots // "file $f\nnone";
  }
}

multi sub MAIN('check', Str :$dict, Bool :$strict = False, *@files)
{
  %DICTIONARY = load-dictionary($dict) if $dict.defined;
  $STRICT = $strict;
  for @files -> $f
  {
    my ($, $, $checks) = one($f);
    say $checks // 'null';
  }
}

multi sub MAIN(Str :$out!, Str :$list!, Int :$from = 0, Int :$to = 1_000_000, Str :$dict, Bool :$strict = False)
{
  %DICTIONARY = load-dictionary($dict) if $dict.defined;
  $STRICT = $strict;
  mkdir $out;
  my @files = $list.IO.lines.grep(*.chars);
  for $from ..^ min($to, @files.elems) -> $i
  {
    my ($tree, $roots, $checks) = one(@files[$i]);
    "$out/$i.tree".IO.spurt(($tree // 'null') ~ "\n");
    "$out/$i.roots".IO.spurt(($roots // "file {@files[$i]}\nnone") ~ "\n");
    "$out/$i.check".IO.spurt(($checks // 'null') ~ "\n");
  }
}
