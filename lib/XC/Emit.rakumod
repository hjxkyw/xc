# XC::Emit -- from the tree back to TL++.
#
# SOURCE PLUS EDITS
#
# The output is the source, copied through, with the extension constructs
# replaced where they are. What needs no lowering keeps its comments, blank
# lines and layout exactly as written, so a file that is plain TL++ comes out
# unchanged (plus the two includes, if it lacked them).
#
# A rewritten statement loses its trailing comment to the rewrite and gets it
# back, two spaces after the new code, the way xtpl does it: on the header
# line when the rewrite opens a block ('If c  // note'), on the last line
# otherwise.
#
# WHAT IS NOT LOWERED YET IS AN ERROR
#
# Any extension this module cannot lower yet stops the whole file, with the
# line of each one. xtpl syntax never passes silently into a .tlpp.

use XC::AST;
use XC::Grammar;
use XC::Actions;

unit module XC::Emit;

class X::XC::NotLowered is Exception is export
{
  has @.problems;                  # Pairs: line => what
  method message
  {
    @!problems.map({ "line {.key}: {.value} is not lowered yet" }).join("\n")
  }
}

# A '*' that starts a comment line, Clipper's: the first thing on its line,
# and the line before it not carried on to it by a ';' -- there it multiplies.
# The text's own start is no line start: a piece of source starts with code.
sub star-comment(Str $text, Int $i --> Bool)
{
  return False unless $i > 0 && $text.substr($i, 1) eq '*';
  # "\r\n" is one character: a line break is any of the three.
  my &break-before = -> $p { ("\n", "\r\n", "\r").map({ $text.rindex($_, $p) // -1 }).max };
  my $start = break-before($i - 1);
  return False if $start < 0 || $text.substr($start + 1, $i - $start - 1) ~~ / \S /;
  # The line before, its comment aside: does it end in a ';'?
  my $from = $start > 0 ?? break-before($start - 1) + 1 !! 0;
  my $line = $text.substr($from, $start - $from).subst(/ [ '//' || '&&' ] \N* $ /, '');
  !($line ~~ / ';' \h* $ /)
}

# Splits a piece of source into its code and its comments, outside strings.
# The comments come back joined on one line, a block comment as its text: a
# rewritten line has only its end to put them on.
# A "'" between two digits groups them ('12'345'678') -- the grammar's rule --
# and does not open a string. No valid program has a digit, a "'" and a digit
# in a row otherwise: a string cannot follow a number.
sub is-separator(Str $text, Int $i --> Bool)
{
  return False unless $i > 0 && $i + 1 < $text.chars;
  my $before = $text.substr($i - 1, 1);
  my $after  = $text.substr($i + 1, 1);
  so '0' le $before le '9' && '0' le $after le '9'
}

sub split-comment(Str $text --> List) is export
{
  my ($code, @comments) = '';
  my ($i, $n, $quote) = 0, $text.chars, '';
  while $i < $n
  {
    my $c = $text.substr($i, 1);
    if $quote
    {
      # A string ends at its quote, or at the end of its line (TL++ closes it
      # there).
      $quote = '' if $c eq $quote || $c eq "\n" | "\r\n" | "\r";
      $code ~= $c;
      $i++;
    }
    elsif $c eq '"' || ($c eq "'" && !is-separator($text, $i))
    {
      $quote = $c;
      $code ~= $c;
      $i++;
    }
    elsif $text.substr($i, 2) eq '//' | '&&' || star-comment($text, $i)
    {
      my $end = $text.index("\n", $i) // $n;
      @comments.push($text.substr($i + 2, $end - $i - 2).trim);
      $i = $end;
    }
    elsif $text.substr($i, 2) eq '/*'
    {
      my $end = $text.index('*/', $i + 2) // $n - 2;
      @comments.push($text.substr($i + 2, $end - $i - 2).words.join(' '));
      $code ~= ' ';
      $i = $end + 2;
    }
    else
    {
      $code ~= $c;
      $i++;
    }
  }
  my $comment = @comments.grep(*.chars).map({ "// $_" }).join(' ');
  ($code.trim-trailing, $comment)
}

# Where the code of a piece of source ends: before its trailing blanks and
# comments. A node's span can run on over them, since grammar rules swallow the
# whitespace after them.
sub code-end(Str $text --> Int) is export
{
  my ($i, $n, $quote, $end) = 0, $text.chars, '', 0;
  while $i < $n
  {
    my $c = $text.substr($i, 1);
    if $quote
    {
      $quote = '' if $c eq $quote || $c eq "\n" | "\r\n" | "\r";
      $end = ++$i;
    }
    elsif $c eq '"' || ($c eq "'" && !is-separator($text, $i))
    {
      $quote = $c;
      $end = ++$i;
    }
    elsif $text.substr($i, 2) eq '//' | '&&' || star-comment($text, $i)
    {
      $i = $text.index("\n", $i) // $n;
    }
    elsif $text.substr($i, 2) eq '/*'
    {
      $i = ($text.index('*/', $i + 2) // $n - 2) + 2;
    }
    elsif $c ~~ /\s/
    {
      $i++;
    }
    elsif $c eq ';' && $text.substr($i + 1) ~~ / ^ \h* [ [ '//' || '&&' ] \N* || '/*' .*? '*/' \h* ]? \v /
    {
      # A ';' continuation: the rest of its line is not code.
      $i++;
    }
    else
    {
      $end = ++$i;
    }
  }
  $end
}

# xtpl's runtime verbs: a call to one of these names -- not a method -- is
# the runtime's 'u_xtpl_<name>', wherever it is. The runtime is
# runtime/xtpl_runtime.tlpp, which has to be compiled into the RPO.
my constant VERBS = set <
  map filter reject reduce fold take drop distinct sort sortby reverse flatten
  enumerate chunks zip asum aprod amax amin anyof allof noneof keys values
  pairs takewhile dropwhile chunkby first count distinctadjacent maxby minby
  scan expand tap pairwise queue split join starts ends contains
  apick aroll setmaxroll
>;

sub call-name(Str $name --> Str)
{
  VERBS{$name.lc}:exists ?? "u_xtpl_{$name.lc}" !! $name
}

# ---- sources -----------------------------------------------------------------
#
# rows() and lines() are sources, not functions: a chain from one becomes a
# loop over the work area or the file, with the stages inside it, and nothing
# is materialised. These stages fuse into the loop; a terminal ends it; any
# other stage applies, as an ordinary call, to what the loop collected.
#
# A chain over an ARRAY fuses the same way -- one loop, no array between the
# stages, a 'take' that stops it -- when it is a statement's whole value and
# at least two of its stages fuse (all of them, for a chain run for its
# effects), as xtpl does; or one, when that one carries a block: 'aX |>
# map([x] x * 2)' is a loop, not u_xtpl_map's Eval of a block per element.
# Anywhere else it stays one call per stage, which is what a chain means;
# fusing only saves the work.
my constant FUSED        = set <filter reject map tap take takewhile drop dropwhile expand distinctadjacent
                                scan pairwise>;
my constant TERMINAL     = set <asum count anyof allof noneof first aprod amax amin join reduce fold maxby minby
                                chunkby>;

# The stages a chain from a source has fused from the start. The others fuse
# only when written to fuse -- scan with its two-parameter step and a seed --
# and are an ordinary call on what the loop collected otherwise.
my constant FIRST-FUSED = set <filter reject map tap take takewhile drop dropwhile expand distinctadjacent>;

# The terminals a chain from a source has had from the start: a lambda missing
# from one is an error there. The others fuse only when written to fuse, and
# are an ordinary call otherwise.
my constant FIRST-TERMINALS = set <asum count anyof allof noneof first>;
my constant NEEDS-LAMBDA = set <filter reject map tap takewhile dropwhile expand anyof allof noneof>;

# The stages that stop the walk with an 'Exit'. After an 'expand' that Exit
# would only leave the expand's own inner loop -- a take would not stop the
# walk, and a 'first' would be overwritten by every later element -- so from
# there on they apply to what was collected instead.
my constant EXITS        = set <take takewhile anyof allof noneof first>;

# The verbs that take a block, where a bare function name means the block
# that calls it: 'map(alltrim)' is 'map([it] alltrim(it))', as in xtpl. A
# name that is a variable is a block held in it, and stays as it is.
my constant TAKES-BLOCK  = set <map filter reject tap takewhile dropwhile expand maxby minby
                                sortby chunkby distinctadjacent first count anyof allof noneof>;

# The source a chain starts from -- a rows()/lines() call or a range
# 'lo..hi' -- or the source itself.
sub is-source(Expr $e --> Bool) is export
{
  so ($e ~~ Call && $e.name.lc (elem) <rows lines>) || $e ~~ Interval
}

# The locals a statement declares in its header: 'if local x := ...', 'for
# local i := ...', 'for x, i in ...', 'do case with local x := ...'.
sub header-names(Stmt $s --> List)
{
  given $s
  {
    when IfStmt | WhileStmt { .header-decl.defined ?? (.header-decl.name,) !! () }
    when ForStmt            { .var-local ?? (.var,) !! () }
    when ForInStmt          { (.elem, |(.index // ())) }
    when CaseStmt           { .subject-decl.defined ?? (.subject-decl.name,) !! () }
    default                 { () }
  }
}

# Whether the variable $name can be reached after its block -- in @stmts, its
# block, or in @exprs, its header: named in a code block or a lambda (which
# may outlive the block, and sees the variable, not a copy), passed by
# reference ('@x'), read by a defer (run at the function's end), named in raw
# text (which xc does not read). Handing on its value is none of these: the
# next block to use its slot gives it a new value, and what was handed on
# keeps the old one.
sub escapes(Str $name, @stmts, @exprs --> Bool)
{
  my $k = $name.lc;
  my $found = False;
  my sub scan($e, Bool $captured, %shadow)
  {
    return if $found || !$e.defined;
    given $e
    {
      when CodeBlock
      {
        my %s = %shadow;
        %s{.lc} = True for $e.params;
        scan($_, True, %s) for $e.body;
        return;
      }
      when Ref  { $found = True if .target ~~ Name && .target.name.lc eq $k && !%shadow{$k} }
      when Name { $found = True if $captured && .name.lc eq $k && !%shadow{$k} }
    }
    scan($_, $captured, %shadow) for subexprs($e);
  }
  scan($_, False, %()) for @exprs;
  walk(@stmts, -> $s
  {
    if $s ~~ RawStmt
    {
      $found = True if $s.lines.first({ .lc ~~ / << $k >> / });
    }
    elsif $s ~~ Deferred
    {
      walk(($s.stmt,), -> $d { scan($_, True, %()) for exprs-of($d) });
    }
    else
    {
      scan($_, False, %()) for exprs-of($s);
    }
  });
  $found
}

# What a declarator was, for a comment where xc writes it: the name it had,
# when xc renamed it, and its attributes -- 'nB [const]', '[contained]'; ''
# when there is nothing to say.
sub note-of(Declarator $d, Str $shown --> Str)
{
  my @w;
  @w.push($d.name) if $shown.lc ne $d.name.lc;
  @w.push("[{$d.attributes.join(', ')}]") if $d.attributes;
  @w.join(' ')
}

# The same for a declaration kept where it is: one declarator, its
# attributes; several, each with its name.
sub notes-of(Declaration $d --> Str)
{
  my @with = $d.declarators.grep(*.attributes);
  return '' unless @with;
  return "[{@with[0].attributes.join(', ')}]" if $d.declarators == 1;
  @with.map({ "{.name} [{.attributes.join(', ')}]" }).join(', ')
}

# The comment of a block local's Local: which one, when renamed, and its
# attributes.
sub block-local-comment(Declarator $d, Str $shown --> Str)
{
  ($shown.lc ne $d.name.lc ?? "the block local '{$d.name}'" !! 'a block local')
    ~ ($d.attributes ?? " [{$d.attributes.join(', ')}]" !! '')
}

# A body's prologue: its first declarations of locals and statics. A
# 'private' or a 'public' is a statement in TL++ -- it creates the variable
# when it runs -- so it ends the prologue: the Locals xc adds go before it,
# never after, and Protheus refuses a Local after a statement.
sub prologue-of(@body --> List)
{
  my @p;
  for @body -> $s
  {
    last unless $s ~~ Declaration && $s.scope (elem) <local static>;
    @p.push($s);
  }
  @p.List
}

# Whether a name is one of the runtime's verbs, which the output calls as
# u_xtpl_<name>.
sub is-runtime-verb(Str $name --> Bool) is export { so VERBS{$name.lc} }

# A chain's stages split into the fused run, the terminal that may end it,
# and the rest, which apply to the result. Over an array a stage fuses only
# when it can be written into the loop (its lambda in the stage); over a
# source a missing lambda is an error (chain-problems), so the stages from the
# start are taken as they come. A Hash, not a List of Lists: rakupp 4.0.1
# flattens a List inside any list assignment, even one itemized with '$( )'.
#
# Shared with XC::Check, whose warnings say what does not fuse: one decision,
# not two that could drift apart. &declared answers whether a name is a
# variable of the function -- 'filter(bOk)' is a block held in one, not a
# function to call.
sub fusion-split(Expr $chain, &declared --> Hash) is export
{
  my @stages = $chain ~~ Pipeline ?? $chain.stages.list !! ();
  my $array = $chain ~~ Pipeline && !is-source($chain.source);
  my (@fused, $terminal, @rest);
  my $expanded = False;
  for @stages -> $st
  {
    my $n = $st.name.lc;
    my $free = !@rest && !$terminal.defined && !($expanded && EXITS{$n});
    if $free && FUSED{$n} && ((!$array && FIRST-FUSED{$n}) || stage-inlinable($st, &declared))
    {
      @fused.push($st);
      $expanded ||= $n eq 'expand';
    }
    elsif $free && TERMINAL{$n} && ((!$array && FIRST-TERMINALS{$n}) || stage-inlinable($st, &declared))
    {
      $terminal = $st;
    }
    else
    {
      @rest.push($st);
    }
  }
  %(fused => @fused.List, terminal => $terminal, rest => @rest.List)
}

# Whether an array chain, split, runs as a loop where it stands: two stages
# that fuse, or one that carries a block -- its lambda, or a function's name
# (inlinable already says it is no variable). Run for its effects: all of its
# stages fuse, and none is a terminal. Shared with XC::Check, whose warnings
# say when a chain would have fused.
sub array-chain-fuses(%split, Bool $for-effect --> Bool) is export
{
  my $fused = %split<fused>.elems;
  my $terminal = %split<terminal>.defined;
  return so $fused >= 1 && !$terminal && !%split<rest> if $for-effect;
  return True if $fused + $terminal >= 2;
  return False unless $fused + $terminal == 1;
  my $st = $fused ?? %split<fused>[0] !! %split<terminal>;
  so $st.args.first(* ~~ Lambda) || (TAKES-BLOCK{$st.name.lc} && $st.args && $st.args[0] ~~ Name)
}

# Whether a stage can be written into a loop: its block written in the stage
# (a function name is one too), with what it needs.
sub stage-inlinable($st, &declared --> Bool)
{
  my $n = $st.name.lc;
  my @a = $st.args.list;
  # A lambda of one parameter, or a function's name -- a Name that is not a
  # variable of the function, where the verb takes a block.
  my $block = @a == 1 && ((@a[0] ~~ Lambda && @a[0].params == 1)
                          || (TAKES-BLOCK{$n} && @a[0] ~~ Name && !declared(@a[0].name.lc)));
  return @a == 1 if $n (elem) <take drop>;
  return !@a || $block if $n (elem) <distinctadjacent count first>;
  return !@a if $n (elem) <asum aprod amax amin pairwise>;
  if $n eq 'scan'
  {
    my $l = @a[0];
    return False unless @a == 2 && $l ~~ Lambda && $l.params == 2;
    my @p = $l.params.map(*.lc);
    my $writes = False;
    walk-expr($_, { $writes = True if $_ ~~ AssignExpr && .target ~~ Name && .target.name.lc (elem) @p }) for $l.body;
    return !$writes;
  }
  return @a <= 1 if $n eq 'join';
  if $n (elem) <reduce fold>
  {
    my $l = @a[0];
    return False unless @a == ($n eq 'reduce' ?? 2 !! 1) && $l ~~ Lambda && $l.params == 2;
    # A step that assigns its own parameters cannot have them written as
    # the loop's variables: xtpl binds them, xc leaves it a call.
    my @p = $l.params.map(*.lc);
    my $writes = False;
    walk-expr($_, { $writes = True if $_ ~~ AssignExpr && .target ~~ Name && .target.name.lc (elem) @p }) for $l.body;
    return !$writes;
  }
  $block
}

sub source-call(Expr $e --> Expr)
{
  return $e.source if $e ~~ Pipeline && is-source($e.source);
  return $e if is-source($e);
  Expr
}

# 'rows', 'lines' or 'range'.
sub source-kind(Expr $src --> Str)
{
  $src ~~ Interval ?? 'range' !! $src.name.lc
}


# For lowers-itself: what a class of expression needs checked to say whether
# it is rewritten itself.
my constant SELF-OPS = set <in has %% ?:>;
my %LOWERS =
  Lambda.^name     => 'yes',     Pipeline.^name => 'yes',    HashIndex.^name  => 'yes',
  HashLit.^name    => 'yes',     Guard.^name    => 'yes',    Interp.^name     => 'yes',
  SafeMember.^name => 'yes',     SafeCall.^name => 'yes',
  Call.^name       => 'call',    Name.^name     => 'name',   Member.^name     => 'member',
  MethodCall.^name => 'method',  AssignExpr.^name => 'assign',
  JsonLit.^name    => 'yes',
  Literal.^name    => 'literal', ArrayLit.^name => 'literal',
  CodeBlock.^name  => 'literal', Binary.^name   => 'binary',
  Index.^name      => 'no',      SelfRef.^name  => 'no',     SubjectRef.^name => 'no',
  Interval.^name   => 'no',      AliasField.^name => 'no',   InAlias.^name    => 'no',
  ExprList.^name   => 'no',
  Macro.^name      => 'no',      Ref.^name      => 'no',     Omitted.^name    => 'no',
  UserTrans.^name  => 'no';

class Emitter
{
  has Str $.src;
  has Str $!nl;                    # the source's own line ending
  has @!edits;                     # [from, to, text]

  # Per function: the names in use, and the Locals to add after its prologue.
  has %!used;
  has %!slots;                     # the slots made: s_0_0, ... (lower case)
  has %!slot-users;                # slot => the block locals in it, for its comment
  has @!hoist;                     # [name, comment, value]: value '' for none
  has %!hoisted;

  # While a fused stage's lambda is rendered, its parameter stands for the
  # element: %!subst maps it to the text of the value, %!field to the area
  # prefix when the element is a work-area record ('r:A1_COD' -> 'SA1->A1_COD').
  has %!subst;
  has %!field;

  # The way out. Entries, innermost last: 'lines' => the lines that close a
  # file, 'using' => the lines that restore a work area, and 'loop' => ()
  # marking a loop body. A 'return' runs the pending defers and then every
  # entry, innermost first; an 'exit' or 'loop' runs only the entries between
  # it and the loop it leaves.
  has @!closers;

  # The function's defers, in the order written: %(from, lines, at, flag). An
  # exit runs the ones that ran before it, the last written first. 'at' is
  # where the defer is (%!paths), 'flag' the Local that says it ran -- when
  # some exit cannot be sure of it -- or Str.
  has @!defers;

  # Where each statement of the function is: %(path, loops). 'path' is the
  # bodies down to it, each "<body>\t<index>" (the function's own is 'root',
  # a statement's k-th body "<its WHICH>/k"); 'loops' the WHICHs of the loops
  # around it. Strings, not nested lists: rakupp 4.0.1 flattens a List inside
  # a list assignment.
  has %!paths;

  # The names the function declares: a 'using alias' word that is one of
  # them is a variable holding the alias, not the alias itself.
  has %!declared;

  # Statements rewritten already, by the prologue pass: the walk skips them.
  has %!done;

  # The subjects of the 'with object' blocks around the walk, innermost last:
  # ':x' is the last one's 'x'.
  has @!subjects;

  # Block locals renamed, by the block that declares them (its WHICH):
  # head => the header locals ('if local x', 'for x in'), in scope in the
  # header and the body; body => the locals of its prologue, in scope in the
  # body only. Each maps the name, lower case, to the new one.
  has %!renames;

  submethod TWEAK() { $!nl = $!src.contains("\r\n") ?? "\r\n" !! "\n" }

  # ---- lines -----------------------------------------------------------------
  # "\r\n" is one character in Raku, so a line break is found as any of the
  # three line ends, not just "\n".
  method !line-start(Int $p --> Int)
  {
    my @at = ("\n", "\r\n", "\r").map({ $!src.rindex($_, $p - 1) }).grep(*.defined);
    @at ?? @at.max + 1 !! 0
  }

  method !line-end(Int $p --> Int)
  {
    my @at = ("\n", "\r\n", "\r").map({ $!src.index($_, $p) }).grep(*.defined);
    @at ?? @at.min !! $!src.chars
  }

  method !indent-at(Int $p --> Str)
  {
    my $s = $!src.substr(self!line-start($p), $p - self!line-start($p));
    $s ~~ /\S/ ?? ' ' x $s.chars !! $s
  }

  # Lines replacing something that starts at $p: the first at $p itself, the
  # rest at its indentation, with the source's line ending.
  method !join-at(Int $p, @lines --> Str)
  {
    my $indent = self!indent-at($p);
    (@lines[0], |@lines[1..*].map({ $indent ~ $_ })).join($!nl)
  }

  # ---- what is not lowered yet -----------------------------------------------
  method not-lowered(Program $p --> List)
  {
    my @found;
    for |$p.functions, |$p.methods -> $f
    {
      self!declare-names($f);
      walk($f.body, -> $s
      {
        my $what = do given $s
        {
          when ForInStmt    { source-call(.source).defined && source-kind(source-call(.source)) eq 'rows'
                                ?? "'for ... in' over rows()" !! Str }
          default           { Str }
        };
        @found.push($s.line => $what) with $what;

        # A source only reads at the head of a chain in a statement that can
        # run the loop first -- 'x := ...', 'return ...', the chain alone -- or
        # as the source of a 'for'.
        my @tops = self!stream-values($s);
        my $for = $s ~~ ForInStmt && is-source($s.source) ?? $s.source !! Expr;
        my %heads;                     # the source calls that head a chain
        for exprs-of($s) -> $e
        {
          walk-expr($e, { %heads{.source.WHICH} = True if $_ ~~ Pipeline && is-source(.source) });
        }
        # A range is also the right side of 'in': a membership test, no loop.
        my %in-range;
        for exprs-of($s) -> $e
        {
          walk-expr($e, { %in-range{.right.WHICH} = True if $_ ~~ Binary && .op eq 'in' && .right ~~ Interval });
        }
        for exprs-of($s) -> $e
        {
          walk-expr($e, -> $x
          {
            my $w = self!expr-extension($x);
            @found.push($s.line => $w) with $w;
            if is-source($x)
            {
              my $ok = @tops.first({ source-call($_) === $x }).defined || ($for.defined && $for === $x)
                    || %in-range{$x.WHICH};
              unless $ok
              {
                my $what = $x ~~ Interval ?? 'a range' !! "{$x.name.lc}()";
                @found.push($s.line => %heads{$x.WHICH}
                  ?? "a chain from $what where it cannot run as a loop first "
                     ~ "(it goes in 'x := ...', 'return ...' or a statement of its own)"
                  !! $x ~~ Interval
                     ?? "a range outside 'in' and the head of a chain"
                     !! "'{$x.name.lc}()' outside the head of a chain (it is a source)");
              }
            }
          });
        }
        @found.append(self!chain-problems($_, $s)) for @tops;
      });
      @found.append(self!scope-problems($f));
    }
    @found.unique(:as({ .key ~ "\0" ~ .value })).sort(*.key).List
  }

  method !expr-extension(Expr $x --> Str)
  {
    given $x
    {
      default         { Str }
    }
  }

  # Block locals become Locals of the function, with the names as written --
  # renaming them needs name resolution, which xc does not have yet. So a
  # block local may not take the name of a variable of the function, nor of a
  # block local of an enclosing block: both would share one Local. The same
  # name in sibling blocks is fine.
  method !scope-problems($f --> List)
  {
    my %fn;
    %fn{.name.lc} = True for $f.params;
    for $f.body.grep(Declaration) -> $d { %fn{.name.lc} = True for $d.declarators }
    my @found;

    # (A block local with the name of a function variable or of an enclosing
    # block local is renamed; see !plan-renames.)
    my sub declare(Str $n, Int $line, @stack)
    {
      @stack[*-1]{$n.lc} = True;
    }

    my sub visit(@body, @stack, Bool $top)
    {
      for @body -> $s
      {
        if !$top && $s ~~ Declaration && $s.scope eq 'local'
        {
          declare(.name, $s.line, @stack) for $s.declarators;
        }
        my @in = (|@stack, {});
        given $s
        {
          when IfStmt
          {
            declare(.header-decl.name, .line, @in) if .header-decl.defined;
            visit(.body, @in, False) for .branches;
            visit(.otherwise, @in, False);
          }
          when WhileStmt
          {
            declare(.header-decl.name, .line, @in) if .header-decl.defined;
            visit(.body, @in, False);
          }
          when ForStmt
          {
            declare(.var, .line, @in) if .var-local;
            visit(.body, @in, False);
          }
          when ForInStmt
          {
            declare(.elem, .line, @in);
            declare(.index, .line, @in) if .index.defined;
            visit(.body, @in, False);
          }
          when CaseStmt
          {
            declare(.subject-decl.name, .line, @in) if .subject-decl.defined;
            visit(.body, @in, False) for .branches;
            visit(.otherwise, @in, False);
          }
          when ForTimesStmt | SequenceStmt | UsingAlias | WithObject
          {
            visit($_, @in, False) for bodies-of($s);
          }
        }
      }
    }

    visit($f.body, [{},], True);

    # A block local a defer reads, declared in more than one block: xc gives
    # the blocks one Local, so the defer, which runs at the end, could see the
    # other block's value. xtpl gives it storage of its own.
    my %blocks;
    walk($f.body, -> $s
    {
      given $s
      {
        when Declaration { if .scope eq 'local' && !($f.body.first(* === $s)) { %blocks{.name.lc}++ for .declarators } }
        when ForInStmt   { %blocks{.elem.lc}++; %blocks{.index.lc}++ if .index.defined }
        when ForStmt     { %blocks{.var.lc}++ if .var-local }
        when IfStmt | WhileStmt { %blocks{.header-decl.name.lc}++ if .header-decl.defined }
        when CaseStmt    { %blocks{.subject-decl.name.lc}++ if .subject-decl.defined }
      }
    });
    walk($f.body, -> $s
    {
      if $s ~~ Deferred
      {
        for exprs-of($s.stmt) -> $e
        {
          walk-expr($e, -> $x
          {
            if $x ~~ Name && (%blocks{$x.name.lc} // 0) > 1
            {
              @found.push($s.line => "block local '{$x.name}', read by a defer and declared in more than one block,");
            }
          });
        }
      }
    });
    @found
  }

  method !split(Expr $chain --> Hash)
  {
    fusion-split($chain, -> $n { so %!declared{$n} })
  }

  method !inlinable($st --> Bool)
  {
    stage-inlinable($st, -> $n { so %!declared{$n} })
  }

  # An array chain fused where it stands: the whole value of a statement
  # (array-chain-fuses says when).
  method !fusable-array($e, Bool $for-effect --> Bool)
  {
    return False unless $e ~~ Pipeline && !is-source($e.source);
    array-chain-fuses(self!split($e), $for-effect)
  }

  # The chain a statement runs as a loop: one from a source, or an array chain
  # that fuses.
  method !fused-value(Stmt $s --> Expr)
  {
    with self!stream-value($s) -> $c { return $c }
    given $s
    {
      when Assignment { return .value if .op eq ':=' && self!fusable-array(.value, False) }
      when ReturnStmt { return .value if .value.defined && self!fusable-array(.value, False) }
      when CallStmt   { return .call if self!fusable-array(.call, True) }
    }
    Expr
  }

  # A value that is a loop: a chain from a source, or an array chain that fuses.
  method !loop-value($e --> Bool)
  {
    so $e.defined && (source-call($e).defined || self!fusable-array($e, False))
  }

  # The chain from a source that a statement runs, when the statement is one
  # that can run the loop first: 'x := chain', 'return chain', or the chain
  # alone, for its effects.
  method !stream-value(Stmt $s --> Expr)
  {
    given $s
    {
      when Assignment { return .value if .op eq ':=' && source-call(.value).defined }
      when ReturnStmt { return .value if .value.defined && source-call(.value).defined }
      when CallStmt   { return .call if .call ~~ Pipeline && source-call(.call).defined }
    }
    Expr
  }

  # Every chain from a source a statement runs: the one of 'x := chain' and
  # the like, or the values of a 'local' declaration.
  method !stream-values(Stmt $s --> List)
  {
    with self!stream-value($s) -> $c { return ($c,) }
    return $s.declarators.map(*.init).grep({ .defined && source-call($_).defined }).List
      if $s ~~ Declaration && $s.scope (elem) <local private public>;
    ()
  }

  # What stops a chain from a source from being lowered.
  method !chain-problems(Expr $chain, Stmt $s --> List)
  {
    my @p;
    my $call = source-call($chain);
    my $kind = source-kind($call);
    # One by one: rakupp 4.0.1 flattens Lists inside a list assignment.
    my %split = self!split($chain);
    my $fused    = %split<fused>;
    my $terminal = %split<terminal>;
    my $rest     = %split<rest>;

    @p.push("'rows()' with no alias, or more than an alias and a key")
      if $kind eq 'rows' && !(1 <= $call.args <= 2);
    @p.push("'lines()' with no path, or more than one") if $kind eq 'lines' && $call.args != 1;
    my $what = $kind eq 'range' ?? 'a range' !! "{$kind}()";

    # A fused stage's lambda has to be written in the stage: it becomes the
    # loop's code, and a block held in a variable cannot.
    for |$fused, |($terminal // ()) -> $st
    {
      my $n = $st.name.lc;
      my $needs = NEEDS-LAMBDA{$n} || ($n (elem) <count first distinctadjacent> && $st.args);
      if $needs && !($st.args == 1 && (self!is-lambda($st.args[0]) || self!is-function-name($n, $st.args[0])))
      {
        @p.push("'$n' over $what without its lambda written in the stage");
      }
      @p.push("'$n' over $what without a count") if $n (elem) <take drop> && $st.args != 1;
    }

    # Over rows() the element is the current record, not a value, until a
    # 'map' makes one: its name only names fields, and there is nothing to
    # collect from it.
    if $kind eq 'rows'
    {
      my $mapped = False;
      for |$fused, |($terminal // ()) -> $st
      {
        last if $mapped;
        my $l = $st.args[0];
        if ($l ~~ Lambda && $l.params == 1 && self!record-misused($l))
           || self!is-function-name($st.name.lc, $l)
        {
          @p.push("over rows() the element is the current record, so it can only name a field");
        }
        if $st.name.lc eq 'distinctadjacent' && !$st.args
        {
          @p.push("over rows() 'distinctAdjacent' needs a key: the record is not a value to compare");
        }
        @p.push("over rows() '{$st.name.lc}' needs a value -- map the record to one first")
          if $st.name.lc (elem) <scan pairwise>;
        $mapped = True if $st.name.lc (elem) <map expand>;
      }
      my $t = $terminal.defined ?? $terminal.name.lc !! '';
      my $needs-value = ($t && $t !(elem) <anyof allof noneof count>) || (!$t && ($rest || $s !~~ CallStmt));
      @p.push("over rows() nothing to collect before a 'map' makes the record a value")
        if $needs-value && !$mapped;
    }
    @p.map({ $s.line => $_ }).List
  }

  method !is-lambda($e --> Bool) { so $e ~~ Lambda && $e.params == 1 }

  # A bare function name where a block is taken: not a variable of the
  # function, so it names a function to call with the element.
  method !is-function-name(Str $verb, $e --> Bool)
  {
    so TAKES-BLOCK{$verb} && $e ~~ Name && !%!declared{$e.name.lc}
  }

  # Whether a lambda over a record uses its parameter for anything but a field.
  method !record-misused(Lambda $l --> Bool)
  {
    my $p = $l.params[0].lc;
    my %field-base;
    for $l.body -> $b
    {
      walk-expr($b, { %field-base{.base.WHICH} = True if $_ ~~ Member && .base ~~ Name && .base.name.lc eq $p });
    }
    my $misused = False;
    for $l.body -> $b
    {
      walk-expr($b, { $misused = True if $_ ~~ Name && .name.lc eq $p && !%field-base{.WHICH} });
    }
    $misused
  }

  # ---- the whole file --------------------------------------------------------
  method emit(Program $p --> Str)
  {
    my @problems = self.not-lowered($p);
    die X::XC::NotLowered.new(problems => @problems) if @problems;

    # 'external' emits nothing: its line goes, but for its comment.
    for $p.externals.grep(*.src-from >= 0) -> $x
    {
      my $raw  = $!src.substr($x.src-from, $x.src-to - $x.src-from);
      my $from = self!line-start($x.src-from);
      my $end  = self!line-end($x.src-from + code-end($raw));
      my $comment = split-comment($raw)[1];
      if $comment
      {
        @!edits.push([$from, $end, $comment]);
      }
      else
      {
        $end++ if $end < $!src.chars;              # the line break too
        @!edits.push([$from, $end, '']);
      }
    }

    self!function($_) for |$p.functions, |$p.methods;

    # Two edits over the same text would garble it without a word: stop
    # instead. (An insertion at the edge of another edit is fine.)
    my @sorted = @!edits.sort({ .[0], .[1] });
    for 1 ..^ @sorted -> $i
    {
      my ($a, $b) = @sorted[$i - 1], @sorted[$i];
      die "internal: overlapping edits at offsets {$a[0]}..{$a[1]} and {$b[0]}..{$b[1]}"
        if $b[0] < $a[1] && $b[1] > $b[0];
    }

    my $out = $!src;
    for @!edits.sort({ -.[0], -.[1] }) -> [$from, $to, $text]
    {
      $out = $out.substr(0, $from) ~ $text ~ $out.substr($to);
    }
    add-includes($out, $!nl)
  }

  # A parameter's '<const>' or '<contained>' leaves the header, and a comment
  # at the end of the line says it: 'user function f(aRows, nX)  // aRows
  # [contained], nX [const]' -- with the line's own comment after it.
  method !param-attributes($f)
  {
    my @with = $f.params.grep({ $_ ~~ Param && .attributes });
    return unless @with;
    @!edits.push([.attrs-from, .attrs-to, '']) for @with;
    my $note = @with.map({ "{.name} [{.attributes.join(', ')}]" }).join(', ');
    my $from = self!line-start(@with[*-1].attrs-to);
    my $end  = self!line-end(@with[*-1].attrs-to);
    my $line = $!src.substr($from, $end - $from);
    my ($code, $comment) = split-comment($line);
    if $comment && $comment.starts-with('//')
    {
      my $at = $from + $line.index($comment, $code.chars);
      @!edits.push([$at, $at + 2, "// $note --"]);
    }
    else
    {
      @!edits.push([$end, $end, "  // $note"]);
    }
  }

  method !function($f)
  {
    %!used    = ();
    @!hoist   = ();
    %!hoisted = ();
    self!param-attributes($f);
    %!used{.name.lc} = True for $f.params;
    walk($f.body, -> $s
    {
      given $s
      {
        when Declaration { %!used{.name.lc} = True for .declarators }
        when ForStmt     { %!used{.var.lc} = True }
        when ForInStmt   { %!used{.elem.lc} = True; %!used{.index.lc} = True if .index.defined }
      }
      for exprs-of($s) -> $e { walk-expr($e, { %!used{.name.lc} = True if $_ ~~ Name }) }
    });

    self!declare-names($f);
    self!plan-renames($f);

    # The defers, lowered once each, with their comment on their last line.
    self!place-statements($f);
    @!defers = ();
    walk($f.body, -> $s
    {
      if $s ~~ Deferred
      {
        my @lines = self!stmt-lines($s.stmt);
        my $comment = split-comment(self!slice($s))[1];
        @lines[*-1] ~= "  $comment" if $comment;
        @!defers.push(%(from => $s.src-from, lines => @lines.List, at => %!paths{~$s.WHICH}, flag => Str,
                        text => split-comment(self!slice($s))[0].trim.subst(/ \s+ /, ' ', :g)));
      }
    });
    # A defer runs at an exit only if its line was reached. Where that is
    # certain -- the exit comes after it in its own body, or the defer is in
    # the function's -- it runs as it is; where not -- an exit after the block
    # it is in, the function's end, an earlier line of a loop around both --
    # a flag set where it is written says whether it ran.
    my @returns;
    walk($f.body, -> $s { @returns.push($s) if $s ~~ ReturnStmt });
    my $natural = so $f.body && $f.body[*-1] !~~ ReturnStmt;
    for @!defers -> %d
    {
      next unless @returns.first({ self!defer-at(%d, $_) eq 'maybe' }).defined
                  || ($natural && %d<at><path>.elems > 1);
      my $what = %d<text>.chars > 43 ?? %d<text>.substr(0, 40) ~ '...' !! %d<text>;
      %d<flag> = self!gen('fdf', "whether '$what' was reached", value => '.F.');
    }

    # A chain from a source as the value of a prologue declaration runs as a
    # loop, which is a statement, and statements come after the
    # declarations. So from the first such declaration on, the 'local'
    # declarations keep their names and types, and their values become
    # assignments after the prologue, in the order written -- a later value
    # still sees an earlier one.
    %!done = ();
    my @prologue = prologue-of($f.body);
    my $first = @prologue.first({ .scope eq 'local' && .declarators.first({ self!loop-value(.init) }) }, :k);
    my @inits;
    if $first.defined
    {
      for @prologue[$first .. *].grep(*.scope eq 'local') -> $d
      {
        %!done{$d.WHICH} = True;
        my $kw = split-comment(self!slice($d))[0].trim.words[0];
        self!replace($d, False, ("$kw " ~ $d.declarators.map({ .name ~ (.typespec-text.defined ?? " {.typespec-text}" !! '') }).join(', '),),
                     :notes((notes-of($d),)));
        @inits.append(self!init-lines(.name, .init)) for $d.declarators.grep(*.init.defined);
      }
    }

    self!collect($f.body, True);

    # The natural end: unless the body ends in a 'return', every defer runs
    # after its last statement -- one in a block only if it was reached.
    my $last = $f.body ?? $f.body[*-1] !! Any;
    if @!defers && $last.defined && $last !~~ ReturnStmt
    {
      my $at = self!line-end($last.src-from + code-end(self!slice($last)));
      my $indent = self!indent-at($f.body[0].src-from);
      my @lines = @!defers.reverse.map({ .<at><path>.elems == 1 ?? |.<lines> !! |self!guarded($_) });
      @!edits.push([$at, $at, @lines.map({ $!nl ~ $indent ~ $_ }).join]);
    }
    # Inserted at the end of the prologue, after the hoisted Locals and before
    # any defer there: an insert at the same place as another comes out ahead
    # of it when pushed after it, so these go after the defers' and before the
    # Locals'.
    if @inits
    {
      my $last = @prologue[*-1];
      my $at = self!line-end($last.src-from + code-end(self!slice($last)));
      my $indent = self!indent-at($f.body[0].src-from);
      @!edits.push([$at, $at, @inits.map({ $!nl ~ $indent ~ $_ }).join]);
    }
    self!hoist-edit($f) if @!hoist;
  }

  # The names the function declares, anywhere in it: a 'using alias' word or
  # a bare name given to a verb that is one of them is a variable.
  method !declare-names($f)
  {
    %!declared = ();
    %!declared{.name.lc} = True for $f.params;
    walk($f.body, -> $s
    {
      given $s
      {
        when Declaration { %!declared{.name.lc} = True for .declarators }
        when ForStmt     { %!declared{.var.lc} = True if .var-local }
        when ForInStmt   { %!declared{.elem.lc} = True; %!declared{.index.lc} = True if .index.defined }
        when IfStmt | WhileStmt { %!declared{.header-decl.name.lc} = True if .header-decl.defined }
        when CaseStmt    { %!declared{.subject-decl.name.lc} = True if .subject-decl.defined }
      }
    });
  }

  # Block locals: slots, recycled. A block local lives only while its block
  # runs, so two whose blocks are never one inside the other can share a
  # Local -- each entry gives it its value, or Nil, before anything reads it.
  # Each takes the lowest slot (s_0_0, s_0_1, ...) that no local of an
  # enclosing block holds: on a tree of blocks that is the fewest Locals
  # there can be, as many as the most block locals alive at one point.
  #
  # Not one whose variable can still be reached after its block -- 'pinned'
  # (see escapes): it keeps a Local of its own, under its name when no other
  # declaration in the function has it, b_<n>_<name> when one does.
  method !plan-renames($f)
  {
    %!renames    = ();
    %!slots      = ();
    %!slot-users = ();
    # How often each name is declared in the function, anywhere.
    my %count;
    %count{.name.lc}++ for $f.params;
    walk($f.body, -> $s
    {
      if $s ~~ Declaration { %count{.name.lc}++ for $s.declarators }
      else                 { %count{.lc}++ for header-names($s) }
    });
    my $pins = 0;

    # The lowest slot no enclosing block holds.
    my sub slot(@held --> Str)
    {
      my $k = 0;
      $k++ while @held.first("s_0_$k") || (%!used{"s_0_$k"} && !%!slots{"s_0_$k"});
      my $n = "s_0_$k";
      %!used{$n} = True;
      %!slots{$n} = True;
      $n
    }
    # A Local of its own: the name, when it is the only one; else a new one.
    my sub own(Str $n --> Str)
    {
      return $n if (%count{$n.lc} // 0) <= 1;
      loop
      {
        $pins++;
        my $new = "b_{$pins}_$n";
        next if %!used{$new.lc};
        %!used{$new.lc} = True;
        return $new;
      }
    }
    # Who used a slot: the names, and how the comment of its Local says them.
    my %names;
    my %decls;                       # slot => how many declarations it holds
    my sub user(Str $slot, Str $name, Str $who)
    {
      my @u = |(%!slot-users{$slot} // ());
      @u.push($who) unless @u.first($who);
      %!slot-users{$slot} = @u;
      my @n = |(%names{$slot} // ());
      @n.push($name) unless @n.first({ .lc eq $name.lc });
      %names{$slot} = @n;
      %decls{$slot}++;
    }

    my sub visit(@body, @held)
    {
      for @body -> $s
      {
        next if $s ~~ Modified || $s ~~ Deferred;
        my @bodies = bodies-of($s);
        next unless @bodies;
        # The header's locals live in every body of $s.
        my %head;
        my @h = @held;
        for header-names($s) -> $n
        {
          if escapes($n, @bodies.map({ |$_ }).List, exprs-of($s))
          {
            my $new = own($n);
            %head{$n.lc} = $new if $new ne $n;
          }
          else
          {
            my $k = slot(@h);
            %head{$n.lc} = $k;
            @h.push($k);
            user($k, $n, "'$n'");
          }
        }
        # Each body's own, apart: the bodies of one statement never run at
        # once, so they share slots too.
        my @maps;
        for @bodies -> @b
        {
          my %body;
          my @hb = @h;
          for @b.grep({ $_ ~~ Declaration && .scope eq 'local' }).map({ |.declarators }) -> $dc
          {
            my $n = $dc.name;
            next if %body{$n.lc}:exists;
            if escapes($n, @b, ())
            {
              my $new = own($n);
              %body{$n.lc} = $new if $new ne $n;
            }
            else
            {
              my $k = slot(@hb);
              %body{$n.lc} = $k;
              @hb.push($k);
              user($k, $n, "'$n'" ~ ($dc.attributes ?? " [{$dc.attributes.join(', ')}]" !! ''));
            }
          }
          @maps.push(%body);
          visit(@b, @hb);
        }
        %!renames{$s.WHICH} = %(head => %head, bodies => @maps);
      }
    }
    visit($f.body, []);

    # A slot with one name in it -- one block local, or one name declared in
    # blocks that never meet -- goes by that name: the first such slot of a
    # name, when the function itself (a parameter, a local of its prologue)
    # does not have it; the others by s_<slot>_<name>. Only a slot holding
    # different names keeps s_0_<k>. (A pinned one of the same name is
    # always renamed: it is declared twice.)
    my %fn;
    %fn{.name.lc} = True for $f.params;
    %fn{.name.lc} = True for prologue-of($f.body).map({ |.declarators });
    my %first;
    for %names.keys.sort({ +.substr(4) }) -> $slot
    {
      my @n = |%names{$slot};
      next unless @n == 1;
      %first{@n[0].lc} //= $slot unless %fn{@n[0].lc};
    }
    for %names.kv -> $slot, @n
    {
      next unless @n == 1;
      my $name = @n[0];
      my $new = (%first{$name.lc} // '') eq $slot ?? $name !! "s_{$slot.substr(4)}_$name";
      for %!renames.values -> %r
      {
        for (%r<head>, |%r<bodies>) -> %m
        {
          for %m.keys.grep({ %m{$_} eq $slot }) -> $k
          {
            if $new eq $name { %m{$k}:delete } else { %m{$k} = $new }
          }
        }
      }
      %!used{$new.lc} = True;
      %!slots{$slot}:delete;
      %!slot-users{$slot}:delete;
    }
  }

  # The name a header local of $s goes by.
  method !nm(Stmt $s, Str $name --> Str)
  {
    with %!renames{$s.WHICH} { return .<head>{$name.lc} // $name }
    $name
  }

  # The name a local goes by where the walk is now.
  method !local(Str $name --> Str) { %!subst{$name.lc} // $name }

  # Code run with the header locals of $s in scope ('if local x := e, x > 1':
  # the condition sees x).
  method !in-scope(Stmt $s, &code)
  {
    my %saved = %!subst;
    with %!renames{$s.WHICH} -> %r { %!subst{$_} = %r<head>{$_} for %r<head>.keys }
    my $result = code();
    %!subst = %saved;
    $result
  }

  # The bodies of $s, each with the header locals of $s and its own in
  # scope -- the names each body's block locals go by are its own.
  method !collect-bodies(Stmt $s)
  {
    my %saved = %!subst;
    my %r = %!renames{$s.WHICH} // %();
    my @maps = |(%r<bodies> // ());
    for bodies-of($s).kv -> $i, @b
    {
      %!subst = %saved;
      with %r<head> -> %h { %!subst{$_} = %h{$_} for %h.keys }
      with @maps[$i] -> %m { %!subst{$_} = %m{$_} for %m.keys }
      self!collect(@b, False);
    }
    %!subst = %saved;
  }

  # A Local to add after the function's prologue, once per name.
  method !hoist(Str $name, Str $comment, Str $value = '')
  {
    return if %!hoisted{$name.lc}++;
    @!hoist.push([$name, $comment, $value]);
  }

  # A hidden name, in the shape xtpl reserves for generated names, and not
  # used anywhere in the function.
  method !gen(Str $kind, Str $comment, Str :$value = '' --> Str)
  {
    my $n = 0;
    $n++ while %!used{"{$kind}_0_$n"};
    my $name = "{$kind}_0_$n";
    %!used{$name} = True;
    self!hoist($name, $comment, $value);
    $name
  }

  # The hoisted Locals go after the last declaration of the function's
  # prologue, or before its first statement when it has none.
  method !hoist-edit($f)
  {
    my @body = $f.body;
    my $indent = @body ?? self!indent-at(@body[0].src-from) !! '  ';
    my @decls = prologue-of(@body);
    my @lines = @!hoist.map(-> [$name, $comment, $value]
    {
      # A slot says which block locals it holds.
      my @u = |(%!slot-users{$name.lc} // ());
      my $c = !@u    ?? $comment
           !! @u == 1 ?? "a slot: the block local {@u[0]}"
           !!            "a slot: the block locals {@u.join(', ')}";
      "{$indent}Local {$name}{$value ?? " := $value" !! ''}  // $c"
    });
    if @decls
    {
      my $last = @decls[*-1];
      my $at = self!line-end($last.src-from + code-end(self!slice($last)));
      @!edits.push([$at, $at, @lines.map({ $!nl ~ $_ }).join]);
    }
    else
    {
      my $at = self!line-start(@body[0].src-from);
      @!edits.push([$at, $at, @lines.map({ $_ ~ $!nl }).join]);
    }
  }

  # ---- statements ------------------------------------------------------------
  method !collect(@body, Bool $top)
  {
    for @body -> $s
    {
      next if %!done{$s.WHICH};
      my $walked = False;             # set by a branch that walks the bodies itself
      given $s
      {
        # A block local: an assignment where it was, a Local at the top. One
        # with no value is reset to Nil, so each entry starts fresh.
        # 'when { ... }', not 'when T && ...': a type object is false, so '&&'
        # would return the type itself, and every T would match.
        when { $_ ~~ Declaration && !$top && .scope eq 'local' }
        {
          # What each was, where it gets its value and at its Local: the name
          # it had when renamed, its attributes ('s_1_nB := 2  // nB [const]').
          my (@lines, @notes);
          for .declarators -> $dc
          {
            my $nm = self!local($dc.name);
            # Its Local first: a chain in its value adds Locals of its own.
            self!hoist($nm, block-local-comment($dc, $nm));
            # 'local aX[10]' made as 'Local aX[10]' makes it: Array(10).
            my @l = $dc.init.defined ?? self!init-lines($nm, $dc.init)
                 !! $dc.dims        ?? ("$nm := Array({$dc.dims.map({ self!expr($_) }).join(', ')})",)
                 !!                    ("$nm := Nil",);
            # One note per line, the declarator's on its last -- pushed one by
            # one: an empty 'xx' given to append was taken as an element.
            @notes.push('') for 1 ..^ @l.elems;
            @notes.push(note-of($dc, $nm));
            @lines.append(@l);
          }
          self!replace($s, False, @lines, :@notes);
        }
        # A 'defer' leaves where it is written; its body runs at the exits.
        # One with a flag sets it there: reached.
        when Deferred
        {
          my %d = @!defers.first({ .<from> == $s.src-from });
          my $from = self!line-start($s.src-from);
          my $end  = self!line-end($s.src-from + code-end(self!slice($s)));
          if %d<flag>
          {
            @!edits.push([$from, $end, self!indent-at($s.src-from) ~ "{%d<flag>} := .T."]);
          }
          else
          {
            $end++ if $end < $!src.chars;            # the line break too
            @!edits.push([$from, $end, '']);
          }
          $walked = True;                            # its body is spliced, not edited here
        }
        # A 'return' runs the pending defers and closes what is open.
        when { $_ ~~ ReturnStmt && self!return-exits($_) }
        {
          self!replace($s, False, (|self!return-exits($s), self!with-edits($s, exprs-of($s))));
        }
        # An 'exit' or 'loop' closes what it leaves.
        when { ($_ ~~ ExitStmt || $_ ~~ LoopStmt) && self!jump-exits }
        {
          self!replace($s, False, (|self!jump-exits, self!with-edits($s, ())));
        }
        # 'using alias': the area selected, and put back at 'end using' and
        # on every way out of the block.
        when UsingAlias
        {
          my (@setup, @restore, $select, $prefix);
          if %!declared{.area.lc}
          {
            my $fal = self!gen('fal', "the alias of a 'using alias', from a variable");
            @setup.push("$fal := {.area}");
            $select = $fal;
            $prefix = "($fal)->";
          }
          else
          {
            $select = "\"{.area}\"";
            $prefix = "{.area}->";
          }
          my $far = self!gen('far', "the area selected before a 'using alias'");
          my $frc = self!gen('frc', "the record the area was on before a 'using alias'");
          my $at  = @setup.elems + 1;            # the DbSelectArea line takes the comment
          @setup.append("$far := Alias()", "DbSelectArea($select)", "$frc := {$prefix}(RecNo())");
          with .order -> $o
          {
            my $fol = self!gen('fol', "the index order before a 'using alias'");
            @setup.append("$fol := {$prefix}(IndexOrd())", "{$prefix}(DbSetOrder({self!expr($o)}))");
            @restore.push("{$prefix}(DbSetOrder($fol))");
          }
          @restore.append("{$prefix}(DbGoto($frc))", "If !Empty($far)", "  DbSelectArea($far)", 'EndIf');

          self!header-to($s, self!line-end($s.src-from), $at, |@setup);
          my $raw = self!slice($s);
          my $ce  = code-end($raw);
          my $start = $s.src-from + last-from($raw.substr(0, $ce), / 'end' \s+ 'using' /);
          @!edits.push([$start, $s.src-from + $ce, self!join-at($start, @restore)]);

          @!closers.push('using' => @restore.List);
          self!collect-bodies($s);
          @!closers.pop;
          $walked = True;
        }
        # A chain from a source: the loop first, then the statement with its
        # result -- or the loop alone, for a chain run for its effects.
        when { self!fused-value($_).defined }
        {
          my $statement = $s ~~ CallStmt;
          my ($result, @lines) = self!stream(self!fused-value($s), !$statement);
          if $s ~~ ReturnStmt
          {
            @lines.append(self!return-exits($s));
            @lines.push("return $result");
          }
          elsif !$statement
          {
            @lines.push("{self!expr($s.target)} := $result");
          }
          self!replace($s, False, @lines);
        }
        # A 'private' or 'public' with a chain as its value -- a statement, in
        # a block or not: it is declared where it was, and gets its value
        # after the loop.
        when { $_ ~~ Declaration && .scope (elem) <private public>
               && .declarators.first({ self!loop-value(.init) }) }
        {
          my $kw = split-comment(self!slice($s))[0].trim.words[0];
          # The comment stays with the declaration, as for a 'local'.
          self!replace($s, True, ("$kw " ~ .declarators.map({ .name ~ (.typespec-text.defined ?? " {.typespec-text}" !! '') }).join(', '),
                                   |.declarators.grep(*.init.defined).map({ |self!init-lines(.name, .init) })));
        }
        when { needs-lowering($_) }
        {
          my ($block, @lines) = self!lower($s);
          my @notes;
          if $s ~~ Declaration
          {
            @notes.push('') for 1 ..^ @lines.elems;
            @notes.push(notes-of($s));
          }
          self!replace($s, $block, @lines, :@notes);
        }
        when { $_ ~~ IfStmt && .header-decl.defined }
        {
          my $d = .header-decl;
          my $x = self!nm($s, $d.name);
          self!hoist($x, 'a block local');
          my $init = self!expr($d.init);
          self!in-scope($s, {
            self!header($s, $s.branches[0].cond, 1, "$x := $init", "If {self!expr($s.branches[0].cond)}");
            self!expressions($s, $s.branches[1..*].map(*.cond));
          });
        }
        when { $_ ~~ WhileStmt && .header-decl.defined }
        {
          # Bound and tested on every round, 'loop' included.
          my $d = .header-decl;
          my $x = self!nm($s, $d.name);
          self!hoist($x, 'a block local');
          my $init = self!expr($d.init);
          my $cond = self!in-scope($s, { self!expr($s.cond) });
          self!header($s, .cond, 0, 'While .T.', "  $x := $init", "  If !($cond)", '    Exit', '  EndIf');
        }
        # 'for local i', or a counter renamed with its block: the header written
        # out, and a 'next i' loses the name, which is no longer the counter's.
        when { $_ ~~ ForStmt && (.var-local || (%!subst{.var.lc}:exists)) }
        {
          my $x = .var-local ?? self!nm($s, .var) !! self!local(.var);
          self!hoist($x, 'a block local') if .var-local;
          self!header($s, .step // .to, 0,
            "For $x := {self!expr(.from)} To {self!expr(.to)}"
              ~ (.step.defined ?? " Step {self!expr(.step)}" !! ''));
          if .endname-from >= 0 && $x ne .var
          {
            my $from = .endname-from;
            $from-- while $from > 0 && $!src.substr($from - 1, 1) eq ' ' | "\t";
            @!edits.push([$from, .endname-to, '']);
          }
        }
        when { $_ ~~ ForInStmt && .source ~~ Interval }
        {
          # 'for x [, i] in lo..hi': a count, the element a copy of it.
          my $el = self!nm($s, .elem);
          my $ix = .index.defined ?? self!nm($s, .index) !! Str;
          self!hoist($el, 'a block local');
          self!hoist($ix, 'a block local') if $ix.defined;
          my @h;
          my $lo = self!range-end(.source.lo, 'flo', 'the low end of a range', @h);
          my $hi = self!range-end(.source.hi, 'fhi', 'the high end of a range', @h);
          my $fi = self!gen('fi', "the counter of a 'for ... in'");
          @h.push("$ix := 0") if $ix.defined;
          my $at = @h.elems;
          @h.append("For $fi := $lo To $hi", "  $el := $fi");
          @h.push("  {$ix}++") if $ix.defined;
          self!header($s, .source.hi, $at, |@h);
          if .endname-from >= 0
          {
            my $from = .endname-from;
            $from-- while $from > 0 && $!src.substr($from - 1, 1) eq ' ' | "\t";
            @!edits.push([$from, .endname-to, '']);
          }
        }
        when { $_ ~~ ForInStmt && .source ~~ Call && source-kind(.source) eq 'lines' }
        {
          # 'for x in lines(p)': opened only if it exists, and advanced at the
          # top, so a 'loop' in the body does not stall on the same line. Every
          # way out closes it: the end of the loop, and each 'return' inside.
          my $el = self!nm($s, .elem);
          my $ix = .index.defined ?? self!nm($s, .index) !! Str;
          self!hoist($el, 'a block local');
          self!hoist($ix, 'a block local') if $ix.defined;
          my $fs  = self!gen('fs', 'the path of the file walked');
          my $fok = self!gen('fok', 'whether the file opened');
          my @h = "$fs := {self!expr(.source.args[0])}", "$fok := File($fs)",
                  "If $fok", "  FT_FUse($fs)", "  FT_FGoTop()", 'EndIf';
          @h.push("$ix := 0") if $ix.defined;
          my $while = @h.elems;
          @h.push("While $fok .And. !FT_FEof()");
          @h.push("  {$ix}++") if $ix.defined;
          @h.append("  $el := FT_FReadLn()", '  FT_FSkip()');
          self!header($s, .source, $while, |@h);

          # 'next' becomes the end of the walk.
          my $raw = self!slice($s);
          my $ce  = code-end($raw);
          my $at  = $s.src-from + $raw.substr(0, $ce).lc.rindex('next');
          @!edits.push([$at, $s.src-from + $ce,
            self!join-at($at, ('EndDo', "If $fok", '  FT_FUse()', 'EndIf'))]);

          # Below the loop marker: an 'exit' leaves the loop, whose end closes
          # the file; a 'return' has to close it itself.
          @!closers.push('lines' => ("If $fok", '  FT_FUse()', 'EndIf'));
          @!closers.push('loop' => ());
          self!collect-bodies($s);
          @!closers.pop;
          @!closers.pop;
          $walked = True;
        }
        when ForInStmt
        {
          # The source evaluated once; the index, when named, is the counter.
          my $el = self!nm($s, .elem);
          my $ix = .index.defined ?? self!nm($s, .index) !! Str;
          self!hoist($el, 'a block local');
          self!hoist($ix, 'a block local') if $ix.defined;
          my $src = self!gen('fs', "the source of a 'for ... in'");
          my $ctr = $ix // self!gen('fi', "the counter of a 'for ... in'");
          self!header($s, .source, 1, "$src := {self!expr(.source)}",
            "For $ctr := 1 To Len($src)", "  $el := {$src}[$ctr]");
          # 'next oItem' names the element; TL++'s 'Next' names the counter.
          if .endname-from >= 0
          {
            my $from = .endname-from;
            $from-- while $from > 0 && $!src.substr($from - 1, 1) eq ' ' | "\t";
            @!edits.push([$from, .endname-to, '']);
          }
        }
        when ForTimesStmt
        {
          # The count evaluated once, unless it is a number already.
          my $ctr = self!gen('fi', "the counter of a 'for ... times'");
          if .count ~~ Literal && .count.type eq 'Numeric'
          {
            self!header($s, .count, 0, "For $ctr := 1 To {self!expr(.count)}");
          }
          else
          {
            my $n = self!gen('fn', "the count of a 'for ... times'");
            self!header($s, .count, 1, "$n := {self!expr(.count)}", "For $ctr := 1 To $n");
          }
        }
        when { $_ ~~ CaseStmt && (.subject-decl.defined || .subject-assign.defined) }
        {
          # The subject evaluated once, before the 'case's read it. The node
          # is taken first: in the 'else' of a 'with', '$_' is the undefined
          # value the 'with' tested, not the statement.
          my $c = $_;
          my $bind;
          my $last;
          with $c.subject-decl -> $d
          {
            my $x = self!nm($c, $d.name);
            self!hoist($x, 'a block local');
            $bind = "$x := {self!expr($d.init)}";
            $last = $d.init;
          }
          else
          {
            my $a = $c.subject-assign;
            $bind = "{self!expr($a.target)} := {self!expr($a.value)}";
            $last = $a.value;
          }
          self!header($s, $last, 1, $bind, 'Do Case');
          self!in-scope($c, { self!expressions($c, $c.branches.map(*.cond)) });
        }
        # 'with object': the subject bound once, ':x' its 'x', and the
        # 'end with' line gone. The subject is read with the outer one in scope.
        when WithObject
        {
          my $t = self!gen('fbs', "the subject of a 'with object'");
          self!header($s, .subject, 0, "$t := {self!expr(.subject)}");
          self!drop-closer($s, / 'end' \s+ 'with' /);
          @!subjects.push($t);
          self!collect-bodies($s);
          @!subjects.pop;
          $walked = True;
        }
        # 'raw': the text for the preprocessor, as written -- but with its
        # strings interpolated and its renamed block locals renamed, as xtpl
        # does. A block loses its 'raw' and 'end raw' lines, not their comments.
        when RawStmt
        {
          if .block
          {
            my $raw  = self!slice($s);
            my $ce   = code-end($raw);
            my $from = self!line-start($s.src-from);
            my $last = $s.src-from + last-from($raw.substr(0, $ce), / 'end' \s+ 'raw' /);
            my $end  = self!line-end($s.src-from + $ce);
            my @out;
            my $open = split-comment($!src.substr($s.src-from, self!line-end($s.src-from) - $s.src-from))[1];
            @out.push(self!indent-at($s.src-from) ~ $open) if $open;
            @out.append(.lines.map({ self!raw-text($_) }));
            my $shut = split-comment($!src.substr($last, $end - $last))[1];
            @out.push(self!indent-at($last) ~ $shut) if $shut;
            my $to = $end;
            $to++ if $to < $!src.chars;              # the line break too
            @!edits.push([$from, $to, @out ?? @out.map({ $_ ~ $!nl }).join !! '']);
          }
          else
          {
            my $raw = self!slice($s);
            my $at  = $raw.index(.lines[0]);
            @!edits.push([$s.src-from, $s.src-from + $at + .lines[0].chars, self!raw-text(.lines[0])]);
          }
        }
        default
        {
          self!expressions($s, exprs-of($s));
        }
      }
      # A Modified is lowered whole, with what it holds. A loop's body is
      # marked, so an 'exit' in it knows what it leaves.
      unless $s ~~ Modified || $walked
      {
        my $loop = $s ~~ WhileStmt || $s ~~ ForStmt || $s ~~ ForInStmt || $s ~~ ForTimesStmt;
        @!closers.push('loop' => ()) if $loop;
        self!collect-bodies($s);
        @!closers.pop if $loop;
      }
    }
  }

  # What a 'return' at $s does first: the defers that ran before it, the last
  # written first -- they may still want the areas -- then everything open,
  # innermost first.
  method !return-exits(Stmt $s --> List)
  {
    my @lines;
    for @!defers.reverse -> %d
    {
      given self!defer-at(%d, $s)
      {
        when 'yes'   { @lines.append(%d<lines>.list) }
        when 'maybe' { @lines.append(self!guarded(%d)) }
      }
    }
    (|@lines, |@!closers.reverse.grep(*.key ne 'loop').map({ |.value })).List
  }

  # Whether a defer has run when the 'return' $r runs: 'yes', 'no', or
  # 'maybe' -- then its flag says. Written before the return, it certainly
  # ran when the return is in its own body, after it (in the function's body,
  # that is every return after it); otherwise maybe. Written after it, it may
  # have run in an earlier round of a loop around both; otherwise not.
  method !defer-at(%d, Stmt $r --> Str)
  {
    my @dp = %d<at><path>.list;
    my @rp = %!paths{~$r.WHICH}<path>.list;
    if %d<from> < $r.src-from
    {
      my $n = @dp.elems;
      if @rp.elems >= $n && @rp[^($n - 1)].join("\n") eq @dp[^($n - 1)].join("\n")
      {
        my ($db, $di) = @dp[$n - 1].split("\t");
        my ($rb, $ri) = @rp[$n - 1].split("\t");
        return 'yes' if $rb eq $db && +$ri > +$di;
      }
      return 'maybe';
    }
    my @dl = %d<at><loops>.list;
    %!paths{~$r.WHICH}<loops>.first({ $_ (elem) @dl }).defined ?? 'maybe' !! 'no'
  }

  # A defer's lines under its flag.
  method !guarded(%d --> List)
  {
    ("If {%d<flag>}", |%d<lines>.map({ "  $_" }), 'EndIf').List
  }

  # Where each statement of a function is (%!paths).
  method !place-statements($f)
  {
    %!paths = ();
    my sub visit(@body, Str $key, @above, @loops)
    {
      for @body.kv -> $i, $s
      {
        my @here = |@above, "$key\t$i";
        %!paths{~$s.WHICH} = %(path => @here.List, loops => @loops.List);
        my $loop = $s ~~ WhileStmt || $s ~~ ForStmt || $s ~~ ForInStmt || $s ~~ ForTimesStmt;
        my @inner = $loop ?? (|@loops, ~$s.WHICH) !! @loops;
        my $k = 0;
        for bodies-of($s) -> @b
        {
          visit(@b, "{~$s.WHICH}/{$k++}", @here, @inner);
        }
      }
    }
    visit($f.body, 'root', (), ());
  }

  # What an 'exit' or 'loop' does first: close what is open between it and the
  # loop it leaves.
  method !jump-exits(--> List)
  {
    my @lines;
    for @!closers.reverse -> $c
    {
      last if $c.key eq 'loop';
      @lines.append(|$c.value);
    }
    @lines.List
  }

  # A statement as the lines it becomes where it is spliced (a defer's body).
  method !stmt-lines(Stmt $s --> List)
  {
    with self!fused-value($s) -> $chain
    {
      my $statement = $s ~~ CallStmt;
      my ($result, @lines) = self!stream($chain, !$statement);
      @lines.push("{self!expr($s.target)} := $result") if $s ~~ Assignment;
      return @lines.List;
    }
    return self!lower($s)[1..*].List if needs-lowering($s);
    self!with-edits($s, exprs-of($s)).lines.List
  }

  # A chain from a source, as a loop: the lines, and the text of its result.
  # The stages go inside the loop in order -- a filter an If around the rest,
  # a map the new element, a take a count that stops the walk -- and the
  # terminal, or an AAdd when there is none, collects. Any stage after that
  # applies to what was collected, as an ordinary call.
  method !stream(Expr $chain, Bool $collect --> List)
  {
    my $call = source-call($chain);
    my %split = self!split($chain);
    my $fused    = %split<fused>;
    my $terminal = %split<terminal>;
    my $rest     = %split<rest>;
    my (@setup, @ahead, @body, @close, @teardown, @finish, $head, $advance, $read);
    my ($elem, $prefix, $fv) = Str, Str, Str;
    my $end = 'EndDo';

    if $call ~~ Interval
    {
      # A range counts: nothing is allocated, nothing to put back. The element
      # is a copy of the counter, so a map writing it leaves the count alone.
      my $lo = self!range-end($call.lo, 'flo', 'the low end of a range', @setup);
      my $hi = self!range-end($call.hi, 'fhi', 'the high end of a range', @setup);
      my $fi = self!gen('fi', 'the counter of a range');
      $fv    = self!gen('fv', 'the element walked');
      $head  = "For $fi := $lo To $hi";
      $read  = "$fv := $fi";
      $end   = 'Next';
      $elem  = $fv;
    }
    elsif !$call.defined
    {
      # An array: a name is walked as it is, anything else is bound once --
      # as xtpl does.
      my $src = $chain.source;
      my $arr;
      if $src ~~ Name
      {
        $arr = self!expr($src);
      }
      else
      {
        $arr = self!gen('fs', 'the array walked');
        @setup.push("$arr := {self!expr($src)}");
      }
      my $fi = self!gen('fi', 'the position in the array walked');
      $fv    = self!gen('fv', 'the element walked');
      $head  = "For $fi := 1 To Len($arr)";
      $read  = "$fv := {$arr}[$fi]";
      $end   = 'Next';
      $elem  = $fv;
    }
    elsif $call.name.lc eq 'rows'
    {
      # A literal alias is written out ('SA1->A1_COD'); anything else is bound
      # once and reached as '(alias)->'. The area and the record the walk found
      # are put back afterwards.
      my $a = $call.args[0];
      my $select;
      if $a ~~ Literal && $a !~~ Interp && $a.type eq 'Character'
      {
        $select = $a.text;
        $prefix = $a.text.substr(1, *-1) ~ '->';
      }
      else
      {
        my $fal = self!gen('fal', 'the alias of the area walked');
        @setup.push("$fal := {self!expr($a)}");
        $select = $fal;
        $prefix = "($fal)->";
      }
      my $far = self!gen('far', 'the area selected before the walk');
      my $frc = self!gen('frc', 'the record the area was on before the walk');
      @setup.append("$far := Alias()", "DbSelectArea($select)", "$frc := {$prefix}(RecNo())",
        $call.args > 1 ?? "{$prefix}(DbSeek({self!expr($call.args[1])}))" !! "{$prefix}(DbGoTop())");
      $head     = "While !{$prefix}(Eof())";
      $advance  = "{$prefix}(DbSkip())";
      @teardown = "{$prefix}(DbGoto($frc))", "If !Empty($far)", "  DbSelectArea($far)", 'EndIf';
    }
    else
    {
      # A path held in a variable is used as it is; anything else is bound
      # once -- as xtpl does.
      my $path = $call.args[0];
      my $fs;
      if $path ~~ Name
      {
        $fs = self!expr($path);
      }
      else
      {
        $fs = self!gen('fs', 'the path of the file walked');
        @setup.push("$fs := {self!expr($path)}");
      }
      my $fok = self!gen('fok', 'whether the file opened');
      $fv = self!gen('fv', 'the element walked');
      @setup.append("$fok := File($fs)", "If $fok", "  FT_FUse($fs)", "  FT_FGoTop()", 'EndIf');
      $head     = "While $fok .And. !FT_FEof()";
      $read     = "$fv := FT_FReadLn()";
      $advance  = 'FT_FSkip()';
      @teardown = "If $fok", '  FT_FUse()', 'EndIf';
      $elem     = $fv;
    }

    my $ind = '';
    my &lambda = -> $st
    {
      $st.args[0] ~~ Lambda
        ?? self!bound($st.args[0], $elem, $prefix)
        !! "{$st.args[0].name}($elem)"                 # a function name
    };
    for @$fused -> $st
    {
      given $st.name.lc
      {
        when 'filter' { @body.push("{$ind}If {lambda($st)}");      @close.unshift("{$ind}EndIf"); $ind ~= '  ' }
        when 'reject' { @body.push("{$ind}If !({lambda($st)})");   @close.unshift("{$ind}EndIf"); $ind ~= '  ' }
        when 'map'
        {
          $fv //= self!gen('fv', 'the element walked');
          @body.push("{$ind}$fv := {lambda($st)}");
          $elem = $fv;
        }
        when 'tap'    { @body.push("{$ind}{lambda($st)}") }
        when 'take'
        {
          # A number is the limit as it is; anything else is bound once.
          my $n = $st.args[0];
          my $limit;
          my $fn = self!gen('fn', 'how many elements have passed');
          if $n ~~ Literal && $n.type eq 'Numeric'
          {
            $limit = self!expr($n);
          }
          else
          {
            $limit = self!gen('flm', 'the limit of a take');
            @ahead.push("$limit := {self!expr($n)}");
          }
          @ahead.push("$fn := 0");
          @body.append("{$ind}If $fn >= $limit", "{$ind}  Exit", "{$ind}EndIf", "{$ind}{$fn}++");
        }
        when 'takewhile' { @body.append("{$ind}If !({lambda($st)})", "{$ind}  Exit", "{$ind}EndIf") }
        when 'drop'
        {
          # The rest of the chain in the Else: the first n pass by.
          my $n = $st.args[0];
          my $limit;
          my $fn = self!gen('fn', 'how many elements have passed');
          if $n ~~ Literal && $n.type eq 'Numeric' { $limit = self!expr($n) }
          else
          {
            $limit = self!gen('flm', 'the limit of a drop');
            @ahead.push("$limit := {self!expr($n)}");
          }
          @ahead.push("$fn := 0");
          @body.append("{$ind}If $fn < $limit", "{$ind}  {$fn}++", "{$ind}Else");
          @close.unshift("{$ind}EndIf");
          $ind ~= '  ';
        }
        when 'dropwhile'
        {
          # A flag, not a test: once the leading run is over, an element that
          # would have matched still passes.
          my $flag = self!gen('fdr', 'whether the leading run of a dropwhile is still on');
          @ahead.push("$flag := .T.");
          @body.append("{$ind}If !($flag .And. ({lambda($st)}))", "{$ind}  $flag := .F.");
          @close.unshift("{$ind}EndIf");
          $ind ~= '  ';
        }
        when 'expand'
        {
          # A loop inside the loop: the rest runs once per inner element.
          my $bag = self!gen('fbg', 'the inner array of an expand');
          my $j   = self!gen('fj', 'the position in the inner array of an expand');
          $fv //= self!gen('fv', 'the element walked');
          @body.append("{$ind}$bag := {lambda($st)}", "{$ind}For $j := 1 To Len($bag)", "{$ind}  $fv := {$bag}[$j]");
          @close.unshift("{$ind}Next");
          $elem = $fv;
          $ind ~= '  ';
        }
        when 'scan'
        {
          # A running value, carried from element to element: the seed once,
          # before the loop; the element becomes the value so far.
          my $fa = self!gen('fa', 'the running value of a scan');
          @ahead.push("$fa := {self!expr($st.args[1])}");
          $fv //= self!gen('fv', 'the element walked');
          @body.append("{$ind}$fa := {self!bound2($st.args[0], $fa, $elem)}", "{$ind}$fv := $fa");
          $elem = $fv;
        }
        when 'pairwise'
        {
          # Each element with the one before it, from the second on: the rest
          # of the chain runs inside the If.
          my $fpv = self!gen('fpv', 'the element pairwise saw last');
          my $fhd = self!gen('fhd', 'whether pairwise has seen an element');
          my $fol = self!gen('fol', 'the element before, for pairwise');
          my $frd = self!gen('frd', 'whether pairwise has a pair');
          @ahead.append("$fpv := Nil", "$fhd := .F.");
          $fv //= self!gen('fv', 'the element walked');
          @body.append("{$ind}$fol := $fpv", "{$ind}$frd := $fhd", "{$ind}$fpv := $elem", "{$ind}$fhd := .T.",
                       "{$ind}If $frd", "{$ind}  $fv := \{$fol, $elem\}");
          @close.unshift("{$ind}EndIf");
          $elem = $fv;
          $ind ~= '  ';
        }
        when 'distinctadjacent'
        {
          # A key equal to the one before is skipped; the first always passes.
          my $op = self!gen('fop', 'whether distinctAdjacent has seen an element');
          my $ls = self!gen('fls', 'the key distinctAdjacent saw last');
          my $pb = self!gen('fpb', 'the key of the element distinctAdjacent looks at');
          @ahead.append("$op := .F.", "$ls := Nil", "$pb := Nil");
          @body.append("{$ind}$pb := {$st.args ?? lambda($st) !! $elem}",
                       "{$ind}If !($op .And. ($pb == $ls))", "{$ind}  $op := .T.", "{$ind}  $ls := $pb");
          @close.unshift("{$ind}EndIf");
          $ind ~= '  ';
        }
      }
    }

    my $fo = Str;
    my $t = $terminal.defined ?? $terminal.name.lc !! '';
    if $t || $collect || $rest
    {
      $fo = self!gen('fo', 'the result of the chain');
      my $cond = $terminal.defined && $terminal.args && $t !(elem) <reduce fold join> ?? lambda($terminal) !! Str;
      given $t
      {
        when 'asum'   { @ahead.push("$fo := 0");   @body.push("{$ind}$fo := $fo + $elem") }
        when 'count'
        {
          @ahead.push("$fo := 0");
          @body.append($cond.defined
            ?? ("{$ind}If $cond", "{$ind}  {$fo}++", "{$ind}EndIf")
            !! ("{$ind}{$fo}++",));
        }
        when 'anyof'  { @ahead.push("$fo := .F."); @body.append("{$ind}If $cond", "{$ind}  $fo := .T.", "{$ind}  Exit", "{$ind}EndIf") }
        when 'allof'  { @ahead.push("$fo := .T."); @body.append("{$ind}If !($cond)", "{$ind}  $fo := .F.", "{$ind}  Exit", "{$ind}EndIf") }
        when 'noneof' { @ahead.push("$fo := .T."); @body.append("{$ind}If $cond", "{$ind}  $fo := .F.", "{$ind}  Exit", "{$ind}EndIf") }
        when 'first'
        {
          @ahead.push("$fo := Nil");
          @body.append($cond.defined
            ?? ("{$ind}If $cond", "{$ind}  $fo := $elem", "{$ind}  Exit", "{$ind}EndIf")
            !! ("{$ind}$fo := $elem", "{$ind}Exit"));
        }
        when 'aprod'  { @ahead.push("$fo := 1");   @body.push("{$ind}$fo := $fo * $elem") }
        when 'amax' | 'amin'
        {
          @ahead.push("$fo := Nil");
          @body.append("{$ind}If $fo == Nil", "{$ind}  $fo := $elem", "{$ind}Else",
                       "{$ind}  $fo := {$t eq 'amax' ?? 'Max' !! 'Min'}($fo, $elem)", "{$ind}EndIf");
        }
        when 'join'
        {
          # The elements collected, and joined once, after the loop, by the
          # runtime -- not appended to a growing text inside it, as xtpl
          # does: if '+=' copies the text, as it may, that is quadratic. The
          # separator: a literal as it is, anything else bound once, before
          # the loop, as before.
          my $sep = '';
          if $terminal.args
          {
            my $sepx = $terminal.args[0];
            if $sepx ~~ Literal && $sepx !~~ Interp { $sep = ", {self!expr($sepx)}" }
            else
            {
              my $fsp = self!gen('fsp', 'the separator of a join');
              @ahead.push("$fsp := {self!expr($sepx)}");
              $sep = ", $fsp";
            }
          }
          @ahead.push("$fo := \{\}");
          @body.push("{$ind}AAdd($fo, $elem)");
          @finish.push("$fo := u_xtpl_join($fo$sep)");
        }
        when 'reduce'
        {
          # The seed once, before the loop; the step with its parameters
          # written as the result so far and the element.
          @ahead.push("$fo := {self!expr($terminal.args[1])}");
          @body.push("{$ind}$fo := {self!bound2($terminal.args[0], $fo, $elem)}");
        }
        when 'fold'
        {
          # No seed: the first element is the start.
          @ahead.push("$fo := Nil");
          @body.append("{$ind}If $fo == Nil", "{$ind}  $fo := $elem", "{$ind}Else",
                       "{$ind}  $fo := {self!bound2($terminal.args[0], $fo, $elem)}", "{$ind}EndIf");
        }
        when 'chunkby'
        {
          # The runs of elements whose key is equal, each an array: a new one
          # when the key changes, and the last one added after the loop.
          my $fch = self!gen('fch', 'the chunk chunkby is filling');
          my $fky = self!gen('fky', 'the key of the chunk chunkby is filling');
          my $fop = self!gen('fop', 'whether chunkby has seen an element');
          my $fsn = self!gen('fsn', 'the key of the element chunkby looks at');
          @ahead.append("$fch := \{\}", "$fky := Nil", "$fop := .F.", "$fsn := Nil", "$fo := \{\}");
          @body.append("{$ind}$fsn := $cond", "{$ind}If !$fop", "{$ind}  $fop := .T.", "{$ind}  $fky := $fsn",
                       "{$ind}ElseIf !($fsn == $fky)", "{$ind}  AAdd($fo, $fch)", "{$ind}  $fch := \{\}",
                       "{$ind}  $fky := $fsn", "{$ind}EndIf", "{$ind}AAdd($fch, $elem)");
          @finish.append("If $fop", "  AAdd($fo, $fch)", 'EndIf');
        }
        when 'maxby' | 'minby'
        {
          # The element whose key is the greatest (least): the first of them.
          my $fbs = self!gen('fbs', 'the best key maxby/minby has seen');
          my $fop = self!gen('fop', 'whether maxby/minby has seen an element');
          my $fpb = self!gen('fpb', 'the key of the element maxby/minby looks at');
          @ahead.append("$fbs := Nil", "$fop := .F.", "$fpb := Nil", "$fo := Nil");
          @body.append("{$ind}$fpb := $cond", "{$ind}If !$fop .Or. $fpb {$t eq 'maxby' ?? '>' !! '<'} $fbs",
                       "{$ind}  $fop := .T.", "{$ind}  $fbs := $fpb", "{$ind}  $fo := $elem", "{$ind}EndIf");
        }
        default       { @ahead.push("$fo := \{\}"); @body.push("{$ind}AAdd($fo, $elem)") }
      }
    }

    my @loop = $head, |(($read // ()).map({ "  $_" })), |(@body, @close).flat.map({ "  $_" }),
               |(($advance // ()).map({ "  $_" })), $end;
    my $result = $fo // 'Nil';
    for @$rest -> $st
    {
      $result = call-name($st.name) ~ '(' ~ ($result, |$st.args.map({ self!part($_) })).join(', ') ~ ')';
    }
    ($result, |@setup, |@ahead, |@loop, |@finish, |@teardown).List
  }

  # An end of a range: a number or a name as it is, anything else bound once
  # before the loop, so a call does not sit in its header.
  method !range-end(Expr $e, Str $kind, Str $comment, @setup --> Str)
  {
    return self!expr($e) if ($e ~~ Literal && $e.type eq 'Numeric') || $e ~~ Name;
    my $t = self!gen($kind, $comment);
    @setup.push("$t := {self!expr($e)}");
    $t
  }

  # A stage's lambda body, its parameter bound to the element: the value's
  # text, or -- over a record, before a map -- the area prefix for its fields.
  method !bound(Lambda $l, $elem, $prefix --> Str)
  {
    my $p = $l.params[0].lc;
    my %s = %!subst;
    my %f = %!field;
    if $elem.defined { %!subst{$p} = $elem; %!field{$p}:delete }
    else             { %!field{$p} = $prefix; %!subst{$p}:delete }
    my $text = self!expr($l.body[0]);
    %!subst = %s;
    %!field = %f;
    $text
  }

  # A two-parameter lambda's body -- reduce's and fold's step -- with its
  # parameters written as the result so far and the element.
  method !bound2(Lambda $l, Str $carried, Str $element --> Str)
  {
    my ($a, $b) = $l.params.map(*.lc);
    my %s = %!subst;
    my %f = %!field;
    %!subst{$a} = $carried;
    %!subst{$b} = $element;
    %!field{$a}:delete;
    %!field{$b}:delete;
    my $text = self!expr($l.body[0]);
    %!subst = %s;
    %!field = %f;
    $text
  }

  # 'name := value' as lines: the loop first when the value is a chain from a
  # source.
  method !init-lines(Str $name, Expr $value --> List)
  {
    return ("$name := {self!expr($value)}",) unless self!loop-value($value);
    my @lines = self!stream($value, True);
    my $result = @lines.shift;
    (|@lines, "$name := $result").List
  }

  # A block's closing line ('end with') dropped: the whole line, unless a
  # comment follows the keyword, which stays where it was.
  method !drop-closer(Stmt $s, Regex $closer)
  {
    my $raw = self!slice($s);
    my $ce  = code-end($raw);
    my $at  = $s.src-from + last-from($raw.substr(0, $ce), $closer);
    my $end = self!line-end($s.src-from + $ce);
    my $comment = split-comment($!src.substr($at, $end - $at))[1];
    my $from = self!line-start($at);
    if $comment
    {
      @!edits.push([$from, $end, self!indent-at($at) ~ $comment]);
    }
    else
    {
      $end++ if $end < $!src.chars;
      @!edits.push([$from, $end, '']);
    }
  }

  # A raw line, for the preprocessor: as written, but a string holding '${'
  # interpolated (parsed as xtpl, on its own) and a renamed block local
  # renamed. A comment ends the processing; a member or field name ('o:x',
  # 'A->x') and a function name ('x(') are not variables.
  method !raw-text(Str $text --> Str)
  {
    my $out = '';
    my $i = 0;
    my $n = $text.chars;
    while $i < $n
    {
      my $c = $text.substr($i, 1);
      if $text.substr($i, 2) eq '//' | '&&'
      {
        $out ~= $text.substr($i);
        last;
      }
      elsif $c eq '"' || ($c eq "'" && !is-separator($text, $i))
      {
        my $close = $text.index($c, $i + 1) // $n - 1;
        my $str = $text.substr($i, $close - $i + 1);
        $out ~= $str.contains('${') ?? self!raw-string($str) !! $str;
        $i = $close + 1;
      }
      elsif $c ~~ / <[A..Za..z_]> /
      {
        my $word = ($text.substr($i) ~~ / ^ <[A..Za..z_]> \w* /).Str;
        my $before = $out.substr(*-1) // '';
        my $after = $text.substr($i + $word.chars) ~~ / ^ \h* '(' /;
        $out ~= %!subst{$word.lc}:exists && $before ne ':' && $before ne '>' && !$after
          ?? %!subst{$word.lc} !! $word;
        $i += $word.chars;
      }
      else
      {
        $out ~= $c;
        $i++;
      }
    }
    $out
  }

  # A string with interpolation, from a raw line: parsed on its own, and
  # rendered with the renames in effect here. If it is not valid, as written.
  method !raw-string(Str $str --> Str)
  {
    my $m = XC::Grammar.parse($str, rule => 'expr', actions => XC::Actions.new(source => $str));
    return $str unless $m;
    Emitter.new(src => $str).render-snippet($m.made, %!subst)
  }

  # An expression parsed from a piece of text of its own (a raw line's
  # string), rendered with the given renames.
  method render-snippet(Expr $e, %subst --> Str)
  {
    %!subst = %subst;
    self!expr($e)
  }

  # A whole statement replaced by lines; the comment goes back on the header
  # line of a block ($block), on the last line otherwise.
  # @notes: a word per line, or '' -- what a declaration was ('nB [const]');
  # on the line that takes the statement's comment, the two are one.
  method !replace(Stmt $s, Bool $block, @lines is copy, :@notes)
  {
    my $comment = split-comment(self!slice($s))[1];
    my $at = $block ?? 0 !! @lines.end;
    for @notes.kv -> $i, $n
    {
      @lines[$i] ~= "  // $n" if $n && !($i == $at && $comment);
    }
    if $comment
    {
      my $n = @notes[$at] // '';
      @lines[$at] ~= !$n                       ?? "  $comment"
                  !! $comment.starts-with('//') ?? "  // $n -- {$comment.substr(2).trim}"
                  !!                                 "  // $n  $comment";
    }
    @!edits.push([$s.src-from, $s.src-to, self!join-at($s.src-from, @lines)]);
  }

  # A block's header replaced by lines, up to the end of the line where the
  # expression $last ends; the body and the closer stay where they are. The
  # header's comment goes back on line $at.
  method !header(Stmt $s, Expr $last, Int $at, *@lines)
  {
    self!header-to($s, self!line-end($last.src-from + code-end(self!slice($last))), $at, |@lines);
  }

  # The same, up to a given end.
  method !header-to(Stmt $s, Int $end, Int $at, *@lines)
  {
    my $comment = split-comment($!src.substr($s.src-from, $end - $s.src-from))[1];
    # A copy to change: under Rakudo a slurpy's elements cannot be.
    my @out = @lines;
    @out[$at] ~= "  $comment" if $comment;
    @!edits.push([$s.src-from, $end, self!join-at($s.src-from, @out)]);
  }

  # Expression edits in a statement that keeps its shape: only its lowered
  # expressions change, and the rest stays as written, comments included. A
  # comment inside a rewritten expression cannot stay inside generated code,
  # so it moves to the end of that expression's line.
  method !expressions(Stmt $s, @exprs)
  {
    for self!expr-edits(@exprs) -> [$from, $to, $text, $comment]
    {
      @!edits.push([$from, $to, $text]);
      if $comment
      {
        my $at = self!line-end($to);
        @!edits.push([$at, $at, "  $comment"]);
      }
    }
  }

  # Edits for the outermost expressions that hold something to lower:
  # [from, to, new code, the comments that were inside].
  method !expr-edits(@exprs --> List)
  {
    my @edits;
    for @exprs.grep(*.defined) -> $e
    {
      next unless self!contains-lowering($e);
      if $e.src-from >= 0
      {
        my $raw = self!slice($e);
        my $to  = $e.src-from + code-end($raw);
        my $comment = split-comment($raw.substr(0, $to - $e.src-from))[1];
        @edits.push([$e.src-from, $to, self!expr($e), $comment]);
      }
      else
      {
        @edits.append(self!expr-edits(subexprs($e)));
      }
    }
    @edits
  }

  # An expression as TL++ code: built from its parts when it lowers itself,
  # else its source with the lowered expressions inside it replaced. Code
  # only -- the comments are the statement's business.
  method !expr(Expr $e --> Str)
  {
    given $e
    {
      when Lambda
      {
        # Its own parameters are not the element of an enclosing stage.
        my $lambda = $_;
        my %s = %!subst;
        my %f = %!field;
        %!subst{$_.lc}:delete for $lambda.params;
        %!field{$_.lc}:delete for $lambda.params;
        my $text = "\{|{$lambda.params.join(', ')}| {$lambda.body.map({ self!expr($_) }).join(', ')}\}";
        %!subst = %s;
        %!field = %f;
        $text
      }
      # ':x' / ':m(...)' inside 'with object': the innermost subject's.
      when { ($_ ~~ Member || $_ ~~ MethodCall) && .base ~~ SubjectRef }
      {
        @!subjects[*-1] ~ ':' ~ .name ~ ($_ ~~ MethodCall ?? '(' ~ .args.map({ self!part($_) }).join(', ') ~ ')' !! '')
      }
      # 'h{k} := v' inside an expression ('[p] hMap{p[1]} := p[2]'): a call
      # that sets and gives back the value written, as ':=' does. A write that
      # also reads ('+=') names the hash and the key twice, so unless they are
      # a name and a name or a literal, they go through a block, each evaluated
      # once, as parameters -- the block captures nothing.
      when { $_ ~~ AssignExpr && .target ~~ HashIndex }
      {
        my $written = do {
        my $t = .target;
        my $h = self!expr($t.base);
        my $k = self!expr($t.key);
        my $v = self!expr(.value);
        if .op (elem) (':=', '=')
        {
          "u_xtpl_hset($h, $k, $v)"
        }
        elsif $t.base ~~ Name && ($t.key ~~ Name || $t.key ~~ Literal)
        {
          "u_xtpl_hset($h, $k, u_xtpl_hget($h, $k) {.op.chop} ($v))"
        }
        else
        {
          "Eval(\{|__h, __k, __v| u_xtpl_hset(__h, __k, u_xtpl_hget(__h, __k) {.op.chop} __v)\}, $h, $k, $v)"
        }
        };
        # 'h{k}++' gives the value before: the one written, less one ('--':
        # plus one) -- a number's or a date's alike.
        .incdec eq 'post' ?? "($written) {.op eq '+=' ?? '-' !! '+'} 1" !! $written
      }
      # 'h{k}': a call, right wherever it is (xtpl lifts a Get, which goes
      # wrong in a 'while' condition, an 'elseif' or a lambda).
      when HashIndex { "u_xtpl_hget({self!expr(.base)}, {self!expr(.key)})" }
      when HashLit
      {
        .pairs
          ?? 'u_xtpl_hnew({' ~ .pairs.map({ '{' ~ self!expr(.key) ~ ', ' ~ self!expr(.value) ~ '}' }).join(', ') ~ '})'
          !! 'THashMap():New()'
      }
      # TL++ has no JSON literal: '{ : }' is a syntax error to the AppServer.
      # A JsonObject, then, filled from the pairs.
      when JsonLit
      {
        .pairs
          ?? 'u_xtpl_jnew({' ~ .pairs.map({ '{' ~ self!expr(.key) ~ ', ' ~ self!expr(.value) ~ '}' }).join(', ') ~ '})'
          !! 'JsonObject():New()'
      }
      when Guard
      {
        "u_xtpl_safe_pipe(\{|| {self!expr(.expr)}\}, \{|| {self!expr(.fallback)}\})"
      }
      when Interp { self!interpolated($_) }
      when SafeCall
      {
        self!safe(.base, ":{.name}(" ~ .args.map({ self!part($_) }).join(', ') ~ ')')
      }
      when SafeMember { self!safe(.base, ":{.name}") }
      when { $_ ~~ Binary && .op (elem) <in has %% ?:> }
      {
        # The node in a variable: inside 'given .op' the topic is the operator.
        # The right side is rendered only where it is an expression -- a range
        # is not one.
        my $b = $_;
        my $l = self!expr($b.left);
        given $b.op
        {
          when 'in'
          {
            # 'x in lo..hi' is a range test, with x read once. The block's
            # parameter has a generated name's shape: the bounds are the
            # source's own code, and a variable of the source's called '__v'
            # -- TL++ takes the name -- would be hidden by one of that name.
            if $b.right ~~ Interval
            {
              my $lo = self!expr($b.right.lo);
              my $hi = self!expr($b.right.hi);
              $b.left ~~ Name || $b.left ~~ Literal
                ?? "($l >= $lo .And. $l <= $hi)"
                !! "Eval(\{|fbv_0_0| fbv_0_0 >= $lo .And. fbv_0_0 <= $hi\}, $l)"
            }
            else
            {
              "u_xtpl_in($l, {self!expr($b.right)})"
            }
          }
          when 'has' { "u_xtpl_hhas($l, {self!expr($b.right)})" }
          # Parenthesised whole: the node is rewritten in place, and '!x %% 3'
          # must not become '!(x % 3) == 0'. Its operands only when compound.
          when '%%'
          {
            my $ll = $b.left  ~~ Name || $b.left  ~~ Literal ?? $l !! "($l)";
            my $rr = $b.right ~~ Name || $b.right ~~ Literal ?? self!expr($b.right) !! "({self!expr($b.right)})";
            "(($ll % $rr) == 0)"
          }
          # The right side only when the left is Nil: a block, run if needed.
          default    { "u_xtpl_elvis($l, \{|| {self!expr($b.right)}\})" }
        }
      }
      when Name
      {
        %!subst{.name.lc}:exists ?? %!subst{.name.lc} !! self!with-edits($_, ())
      }
      when Member
      {
        .base ~~ Name && (%!field{.base.name.lc}:exists)
          ?? %!field{.base.name.lc} ~ .name
          !! self!with-edits($_, subexprs($_))
      }
      when Pipeline
      {
        my $acc = self!expr(.source);
        for .stages -> $st
        {
          $acc = call-name($st.name) ~ '(' ~ ($acc, |$st.args.map({ self!block-arg($st.name, $_) })).join(', ') ~ ')';
        }
        $acc
      }
      when Call
      {
        # A verb: the first argument is the data, any after it may be a
        # bare function name standing for a block.
        my $call = $_;
        self!lowers-itself($call)
          ?? call-name($call.name) ~ '(' ~ $call.args.kv.map(-> $i, $a
               { $i == 0 ?? self!part($a) !! self!block-arg($call.name, $a) }).join(', ') ~ ')'
          !! self!with-edits($call, subexprs($call))
      }
      # '12'345'678': TL++ has no digit separators.
      when { $_ ~~ Literal && .type eq 'Numeric' } { .text.subst("'", '', :g) }
      default { self!with-edits($_, subexprs($_)) }
    }
  }

  # An expression that is rewritten itself, not just for what it holds. By
  # class first: most nodes are none of these, and it used to take them
  # through a dozen type tests to say so. Subclasses are listed with what they
  # got from the tests below (SafeMember a Member, Interp a Literal, ...); a
  # class the table does not know goes the long way.
  method !lowers-itself(Expr $e --> Bool)
  {
    given %LOWERS{$e.^name}
    {
      when 'no'      { return False }
      when 'yes'     { return True }
      when 'call'    { return so (VERBS{$e.name.lc}:exists) }
      when 'name'    { return so (%!subst{$e.name.lc}:exists) }
      when 'member'  { return so (($e.base ~~ Name && (%!field{$e.base.name.lc}:exists)) || $e.base ~~ SubjectRef) }
      when 'method'  { return so $e.base ~~ SubjectRef }
      when 'assign'  { return so $e.target ~~ HashIndex }
      when 'literal' { return so ($e.type eq 'Numeric' && $e.text.contains("'")) }
      when 'binary'  { return so SELF-OPS{$e.op} }
    }
    return True if $e ~~ Lambda || $e ~~ Pipeline;
    return True if $e ~~ Call && (VERBS{$e.name.lc}:exists);
    return True if $e ~~ Name && (%!subst{$e.name.lc}:exists);
    return True if $e ~~ Member && $e.base ~~ Name && (%!field{$e.base.name.lc}:exists);
    return True if $e ~~ HashIndex || $e ~~ HashLit || $e ~~ JsonLit || $e ~~ Guard || $e ~~ Interp;
    return True if $e ~~ AssignExpr && $e.target ~~ HashIndex;
    return True if $e ~~ SafeMember || $e ~~ SafeCall;
    return True if $e ~~ Literal && $e.type eq 'Numeric' && $e.text.contains("'");
    return True if ($e ~~ Member || $e ~~ MethodCall) && $e.base ~~ SubjectRef;
    return True if $e ~~ Binary && $e.op (elem) <in has %% ?:>;
    False
  }

  method !contains-lowering(Expr $e --> Bool)
  {
    self!lowers-itself($e) || so subexprs($e).first({ self!contains-lowering($_) })
  }

  # '"total ${n} items"' -> '("total " + cValToChar(n) + " items")', in the
  # string's own quote; one part alone needs no parentheses.
  method !interpolated(Interp $i --> Str)
  {
    my $q = $i.text.substr(0, 1);
    my @parts = $i.parts.grep({ $_ ~~ Expr || .chars }).map({ $_ ~~ Expr ?? "cValToChar({self!expr($_)})" !! "$q$_$q" });
    @parts == 1 ?? @parts[0] !! '(' ~ @parts.join(' + ') ~ ')'
  }

  # 'o?.x' / 'o?.M(...)': Nil when the base is Nil. A name is read twice, as
  # xtpl does; anything else is evaluated once, as the argument of a block --
  # whose parameter has a generated name's shape, since a call's arguments in
  # the tail are the source's code.
  method !safe(Expr $base, Str $tail --> Str)
  {
    my $b = self!expr($base);
    $base ~~ Name
      ?? "If($b != Nil, $b$tail, Nil)"
      !! "Eval(\{|fbv_0_0| If(fbv_0_0 != Nil, fbv_0_0$tail, Nil)\}, $b)"
  }

  # 'h{k} := v' -> 'h:Set(k, v)'. One that also reads -- '+=', '?=' -- reads
  # and writes the same hash and key, so anything but a name (and, for the
  # key, a literal) is held first, to be evaluated once.
  method !hash-set(Assignment $a --> List)
  {
    my $t = $a.target;
    my $h = self!expr($t.base);
    my $k = self!expr($t.key);
    my @pre;
    unless $a.op (elem) (':=', '=')
    {
      unless $t.base ~~ Name
      {
        my $n = self!gen('fhd', 'a hash that is read and written back');
        @pre.push("$n := $h");
        $h = $n;
      }
      unless $t.key ~~ Name || $t.key ~~ Literal
      {
        my $n = self!gen('fky', 'a key that is read and written back');
        @pre.push("$n := $k");
        $k = $n;
      }
    }
    my $v = self!expr($a.value);
    given $a.op
    {
      # '{$h}:', not '$h:' -- in a string Rakudo reads '$h:Set' as one name.
      when { $_ (elem) (':=', '=') } { (False, |@pre, "{$h}:Set($k, $v)") }
      when '?='       { (!@pre, |@pre, "If u_xtpl_hget($h, $k) == Nil", "  {$h}:Set($k, $v)", 'EndIf') }
      default         { (False, |@pre, "{$h}:Set($k, u_xtpl_hget($h, $k) {$a.op.chop} ($v))") }
    }
  }

  # An argument of a verb that takes a block: a bare function name becomes
  # the block that calls it ('alltrim' -> '{|__it| alltrim(__it)}').
  method !block-arg(Str $verb, Expr $e --> Str)
  {
    self!is-function-name($verb.lc, $e) ?? "\{|__it| {$e.name}(__it)\}" !! self!part($e)
  }

  # An argument: an omitted one is empty.
  method !part(Expr $e --> Str) { $e ~~ Omitted ?? '' !! self!expr($e) }

  # A node's source, with the edits for the given expressions inside it.
  method !with-edits($node, @exprs --> Str)
  {
    die "internal: no source span for a {$node.^name}" if $node.src-from < 0;
    my $raw = self!slice($node);
    for self!expr-edits(@exprs).sort({ -.[0] }) -> [$from, $to, $text, $]
    {
      $raw = $raw.substr(0, $from - $node.src-from) ~ $text ~ $raw.substr($to - $node.src-from);
    }
    # Up to where the code ends -- a trailing ';' continuation, blanks and
    # comments are not part of it -- and without the comments inside.
    split-comment($raw.substr(0, code-end($raw)))[0].trim
  }

  method !slice($n --> Str) { $!src.substr($n.src-from, $n.src-to - $n.src-from) }

  # The lowered lines of a statement, with their indentation relative to it,
  # and whether they open a block (the comment then goes on the first line).
  method !lower(Stmt $s --> List)
  {
    given $s
    {
      when Modified
      {
        my @inner = self!lower-inner(.stmt).map({ "  $_" });
        .op eq 'while'
          ?? (True, "While {self!expr(.cond)}", |@inner, 'EndDo')
          !! (True, "If {self!expr(.cond)}",    |@inner, 'EndIf')
      }
      when { $_ ~~ Assignment && .target ~~ HashIndex } { self!hash-set($_) }
      when Assignment
      {
        # '?=': assign only when the target is Nil.
        my $t = self!expr(.target);
        (True, "If $t == Nil", "  $t := {self!expr(.value)}", 'EndIf')
      }
      when Declaration
      {
        # xtpl's order ('as T' first) swapped back, and the attributes dropped:
        # '<const>' and '<contained>' are checks, and emit nothing.
        my $kw = split-comment(self!slice($s))[0].trim.words[0];
        my @d = .declarators.map(-> $d
        {
          $d.name
            ~ $d.dims.map({ "[{self!expr($_)}]" }).join
            ~ ($d.init.defined ?? " := {self!expr($d.init)}" !! '')
            ~ ($d.typespec-text.defined ?? " {$d.typespec-text}" !! '')
        });
        (False, "$kw {@d.join(', ')}")
      }
    }
  }

  # A statement inside a rewrite: lowered if it needs it, else its code as
  # written (its comment has already been taken by the outer statement).
  method !lower-inner(Stmt $s --> List)
  {
    return self!lower($s)[1..*].List if needs-lowering($s);
    # A chain from a source under a modifier ('x := lines(p) |> count if lOk'):
    # its loop inside the If -- run only when the condition holds -- or the
    # While, run every round, as the original.
    with self!fused-value($s) -> $chain
    {
      my @l = self!stream($chain, $s !~~ CallStmt);
      my $result = @l.shift;
      return (|@l, |self!return-exits($s), "return $result").List if $s ~~ ReturnStmt;
      return (|@l, "{self!expr($s.target)} := $result").List if $s ~~ Assignment;
      return @l.List;
    }
    my @exits = $s ~~ ReturnStmt                  ?? self!return-exits($s)
             !! ($s ~~ ExitStmt || $s ~~ LoopStmt) ?? self!jump-exits
             !! ();
    (|@exits, |self!with-edits($s, exprs-of($s)).lines).List
  }
}

sub needs-lowering(Stmt $s --> Bool)
{
  given $s
  {
    when Modified    { True }
    when Assignment  { .op eq '?=' || .target ~~ HashIndex }
    when Declaration { so .declarators.first({ .type-first || .attributes }) }
    default          { False }
  }
}

# Where the last match in a block's text starts, in characters, the text
# taken in lower case. Matched on a copy with every "\r\n" made "\n" -- one
# character either way, so the offsets hold for the text as it is -- because
# some rakupp builds count "\r\n" as two in a match's '.from' and '.substr'
# counts one.
sub last-from(Str $text, Regex $re --> Int)
{
  $text.lc.subst("\r\n", "\n", :g).match($re, :g)[*-1].from
}

# The two includes every file gets, when missing: totvs.ch at the top, and
# tlpp-core.th after the last .ch the file includes -- or at the top, after
# totvs.ch, when it includes none: the order of every file known to compile
# (xcq_i: totvs.ch, rwmake.ch, tlpp-core.th).
sub add-includes(Str $out, Str $nl --> Str)
{
  my &included = -> Str $h { so $out ~~ m:i/ ^^ \h* '#' \h* 'include' \h* '"' $h '"' / };
  my @top;
  @top.push('totvs.ch') unless included('totvs.ch');
  my $text = $out;
  unless included('tlpp-core.th')
  {
    # By lines, not by where a match ends: some rakupp builds count "\r\n" as
    # two in a match's '.to' and '.substr' as one, and the include landed one
    # character late -- after the line end, and before the next line's text.
    my @lines = $out.lines(:!chomp);
    my $last = @lines.first(:end, :k, { $_ ~~ m:i/ ^ \h* '#' \h* 'include' \h* '"' <-["]>* '.ch"' / });
    with $last
    {
      @lines[$last] ~= $nl unless @lines[$last] ~~ / \n $ /;
      @lines.splice($last + 1, 0, '#include "tlpp-core.th"' ~ $nl);
      $text = @lines.join;
    }
    else { @top.push('tlpp-core.th') }
  }
  @top ?? @top.map({ "#include \"$_\"" }).join($nl) ~ $nl ~ $nl ~ $text !! $text
}

# The whole file: TL++ from the tree and its source.
sub emit(Program $p, Str $src --> Str) is export
{
  Emitter.new(src => $src).emit($p)
}
