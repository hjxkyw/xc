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

unit module XC::Emit;

class X::XC::NotLowered is Exception is export
{
  has @.problems;                  # Pairs: line => what
  method message
  {
    @!problems.map({ "line {.key}: {.value} is not lowered yet" }).join("\n")
  }
}

# Splits a piece of source into its code and its comments, outside strings.
# The comments come back joined on one line, a block comment as its text: a
# rewritten line has only its end to put them on.
sub split-comment(Str $text --> List) is export
{
  my ($code, @comments) = '';
  my ($i, $n, $quote) = 0, $text.chars, '';
  while $i < $n
  {
    my $c = $text.substr($i, 1);
    if $quote
    {
      $quote = '' if $c eq $quote;
      $code ~= $c;
      $i++;
    }
    elsif $c eq '"' || $c eq "'"
    {
      $quote = $c;
      $code ~= $c;
      $i++;
    }
    elsif $text.substr($i, 2) eq '//'
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
      $quote = '' if $c eq $quote;
      $end = ++$i;
    }
    elsif $c eq '"' || $c eq "'"
    {
      $quote = $c;
      $end = ++$i;
    }
    elsif $text.substr($i, 2) eq '//'
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
    elsif $c eq ';' && $text.substr($i + 1) ~~ / ^ \h* [ '//' \N* || '/*' .*? '*/' \h* ]? \v /
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
>;

sub call-name(Str $name --> Str)
{
  VERBS{$name.lc}:exists ?? "u_xtpl_{$name.lc}" !! $name
}

# An expression that is rewritten itself, not just for what it holds.
sub lowers-itself(Expr $e --> Bool)
{
  so $e ~~ Lambda | Pipeline || ($e ~~ Call && VERBS{$e.name.lc}:exists)
}

sub contains-lowering(Expr $e --> Bool)
{
  lowers-itself($e) || so subexprs($e).first({ contains-lowering($_) })
}

class Emitter
{
  has Str $.src;
  has Str $!nl;                    # the source's own line ending
  has @!edits;                     # [from, to, text]

  # Per function: the names in use, and the Locals to add after its prologue.
  has %!used;
  has @!hoist;                     # [name, comment]
  has %!hoisted;

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

  # ---- what is not lowered yet --------------------------------------------------
  method not-lowered(Program $p --> List)
  {
    my @found;
    for $p.externals -> $x { @found.push($x.line => "'external'") }
    for |$p.functions, |$p.methods -> $f
    {
      walk($f.body, -> $s
      {
        my $what = do given $s
        {
          when Deferred     { "'defer'" }
          when UsingAlias   { "'using alias'" }
          when WithObject   { "'with object'" }
          when RawStmt      { "'raw'" }
          when ForInStmt    { .source ~~ Call && .source.name.lc (elem) <rows lines>
                                ?? "'for ... in' over {.source.name.lc}()" !! Str }
          default           { Str }
        };
        @found.push($s.line => $what) with $what;
        for exprs-of($s) -> $e
        {
          walk-expr($e, -> $x
          {
            my $w = self!expr-extension($x);
            @found.push($s.line => $w) with $w;
          });
        }
      });
      @found.append(self!scope-problems($f));
    }
    @found.unique(:as({ .key ~ "\0" ~ .value })).sort(*.key).List
  }

  method !expr-extension(Expr $x --> Str)
  {
    given $x
    {
      when Pipeline   { .source ~~ Call && .source.name.lc (elem) <rows lines>
                          ?? "'|>' over {.source.name.lc}()" !! Str }
      when Guard      { "'fallback'" }
      when Interp     { 'string interpolation' }
      when SafeMember { "'?.'" }
      when HashIndex  { 'hash access' }
      when Interval   { "'lo..hi'" }
      when HashLit    { "'\{ => \}'" }
      when SubjectRef { "':x' of 'with object'" }
      when Binary     { .op (elem) <in has %% ?:> ?? "'{.op}'" !! Str }
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

    my sub declare(Str $n, Int $line, @stack)
    {
      my $k = $n.lc;
      if %fn{$k}
      {
        @found.push($line => "block local '$n', with the name of a variable of the function,");
      }
      elsif @stack[0 ..^ @stack.end].first({ .{$k} })
      {
        @found.push($line => "block local '$n', with the name of an enclosing block local,");
      }
      @stack[*-1]{$k} = True;
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
    @found
  }

  # ---- the whole file ----------------------------------------------------------
  method emit(Program $p --> Str)
  {
    my @problems = self.not-lowered($p);
    die X::XC::NotLowered.new(problems => @problems) if @problems;

    self!function($_) for |$p.functions, |$p.methods;
    my $out = $!src;
    for @!edits.sort({ -.[0], -.[1] }) -> [$from, $to, $text]
    {
      $out = $out.substr(0, $from) ~ $text ~ $out.substr($to);
    }
    add-includes($out, $!nl)
  }

  method !function($f)
  {
    %!used    = ();
    @!hoist   = ();
    %!hoisted = ();
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

    self!collect($f.body, True);
    self!hoist-edit($f) if @!hoist;
  }

  # A Local to add after the function's prologue, once per name.
  method !hoist(Str $name, Str $comment)
  {
    return if %!hoisted{$name.lc}++;
    @!hoist.push([$name, $comment]);
  }

  # A hidden name, in the shape xtpl reserves for generated names, and not
  # used anywhere in the function.
  method !gen(Str $kind, Str $comment --> Str)
  {
    my $n = 0;
    $n++ while %!used{"{$kind}_0_$n"};
    my $name = "{$kind}_0_$n";
    %!used{$name} = True;
    self!hoist($name, $comment);
    $name
  }

  # The hoisted Locals go after the last declaration of the function's
  # prologue, or before its first statement when it has none.
  method !hoist-edit($f)
  {
    my @body = $f.body;
    my $indent = @body ?? self!indent-at(@body[0].src-from) !! '  ';
    my @decls;
    for @body -> $s { last unless $s ~~ Declaration; @decls.push($s) }
    my @lines = @!hoist.map(-> [$name, $comment] { "{$indent}Local $name  // $comment" });
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

  # ---- statements --------------------------------------------------------------
  method !collect(@body, Bool $top)
  {
    for @body -> $s
    {
      given $s
      {
        # A block local: an assignment where it was, a Local at the top. One
        # with no value is reset to Nil, so each entry starts fresh.
        # 'when { ... }', not 'when T && ...': a type object is false, so '&&'
        # would return the type itself, and every T would match.
        when { $_ ~~ Declaration && !$top && .scope eq 'local' }
        {
          self!hoist($_, 'a block local') for .declarators.map(*.name);
          self!replace($s, False,
            .declarators.map({ "{.name} := {.init.defined ?? self!expr(.init) !! 'Nil'}" }));
        }
        when { needs-lowering($_) }
        {
          my ($block, @lines) = self!lower($s);
          self!replace($s, $block, @lines);
        }
        when { $_ ~~ IfStmt && .header-decl.defined }
        {
          my $d = .header-decl;
          self!hoist($d.name, 'a block local');
          self!header($s, .branches[0].cond, 1,
            "{$d.name} := {self!expr($d.init)}", "If {self!expr(.branches[0].cond)}");
          self!expressions($s, .branches[1..*].map(*.cond));
        }
        when { $_ ~~ WhileStmt && .header-decl.defined }
        {
          # Bound and tested on every round, 'loop' included.
          my $d = .header-decl;
          self!hoist($d.name, 'a block local');
          self!header($s, .cond, 0, 'While .T.', "  {$d.name} := {self!expr($d.init)}",
            "  If !({self!expr(.cond)})", '    Exit', '  EndIf');
        }
        when { $_ ~~ ForStmt && .var-local }
        {
          self!hoist(.var, 'a block local');
          self!header($s, .step // .to, 0,
            "For {.var} := {self!expr(.from)} To {self!expr(.to)}"
              ~ (.step.defined ?? " Step {self!expr(.step)}" !! ''));
        }
        when ForInStmt
        {
          # The source evaluated once; the index, when named, is the counter.
          self!hoist(.elem, 'a block local');
          self!hoist(.index, 'a block local') if .index.defined;
          my $src = self!gen('fs', "the source of a 'for ... in'");
          my $ctr = .index // self!gen('fi', "the counter of a 'for ... in'");
          self!header($s, .source, 1, "$src := {self!expr(.source)}",
            "For $ctr := 1 To Len($src)", "  {.elem} := {$src}[$ctr]");
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
            self!hoist($d.name, 'a block local');
            $bind = "{$d.name} := {self!expr($d.init)}";
            $last = $d.init;
          }
          else
          {
            my $a = $c.subject-assign;
            $bind = "{self!expr($a.target)} := {self!expr($a.value)}";
            $last = $a.value;
          }
          self!header($s, $last, 1, $bind, 'Do Case');
          self!expressions($s, $c.branches.map(*.cond));
        }
        default
        {
          self!expressions($s, exprs-of($s));
        }
      }
      # A Modified is lowered whole, with what it holds.
      unless $s ~~ Modified
      {
        self!collect($_, False) for bodies-of($s);
      }
    }
  }

  # A whole statement replaced by lines; the comment goes back on the header
  # line of a block ($block), on the last line otherwise.
  method !replace(Stmt $s, Bool $block, @lines is copy)
  {
    my $comment = split-comment(self!slice($s))[1];
    @lines[$block ?? 0 !! @lines.end] ~= "  $comment" if $comment;
    @!edits.push([$s.src-from, $s.src-to, self!join-at($s.src-from, @lines)]);
  }

  # A block's header replaced by lines, up to the end of the line where the
  # expression $last ends; the body and the closer stay where they are. The
  # header's comment goes back on line $at.
  method !header(Stmt $s, Expr $last, Int $at, *@lines)
  {
    my $end = self!line-end($last.src-from + code-end(self!slice($last)));
    my $comment = split-comment($!src.substr($s.src-from, $end - $s.src-from))[1];
    @lines[$at] ~= "  $comment" if $comment;
    @!edits.push([$s.src-from, $end, self!join-at($s.src-from, @lines)]);
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
      next unless contains-lowering($e);
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
        "\{|{.params.join(', ')}| {.body.map({ self!expr($_) }).join(', ')}\}"
      }
      when Pipeline
      {
        my $acc = self!expr(.source);
        for .stages -> $st
        {
          $acc = call-name($st.name) ~ '(' ~ ($acc, |$st.args.map({ self!part($_) })).join(', ') ~ ')';
        }
        $acc
      }
      when Call
      {
        lowers-itself($_)
          ?? call-name(.name) ~ '(' ~ .args.map({ self!part($_) }).join(', ') ~ ')'
          !! self!with-edits($_, subexprs($_))
      }
      default { self!with-edits($_, subexprs($_)) }
    }
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
    self!with-edits($s, exprs-of($s)).lines.List
  }
}

sub needs-lowering(Stmt $s --> Bool)
{
  given $s
  {
    when Modified    { True }
    when Assignment  { .op eq '?=' }
    when Declaration { so .declarators.first({ .type-first || .attributes }) }
    default          { False }
  }
}

# The two includes xtpl puts at the top of every file, when missing.
sub add-includes(Str $out, Str $nl --> Str)
{
  my @missing = ('totvs.ch', 'tlpp-core.th').grep(-> $h
  {
    !($out ~~ m:i/ ^^ \h* '#include' \h* '"' $h '"' /)
  });
  @missing ?? @missing.map({ "#include \"$_\"" }).join($nl) ~ $nl ~ $nl ~ $out !! $out
}

# The whole file: TL++ from the tree and its source.
sub emit(Program $p, Str $src --> Str) is export
{
  Emitter.new(src => $src).emit($p)
}
