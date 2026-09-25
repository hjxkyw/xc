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

# ---- sources ---------------------------------------------------------------------
#
# rows() and lines() are sources, not functions: a chain from one becomes a
# loop over the work area or the file, with the stages inside it, and nothing
# is materialised. These stages fuse into the loop; a terminal ends it; any
# other stage applies, as an ordinary call, to what the loop collected.
my constant FUSED        = set <filter reject map tap take takewhile>;
my constant TERMINAL     = set <asum count anyof allof noneof first>;
my constant NEEDS-LAMBDA = set <filter reject map tap takewhile anyof allof noneof>;

# The rows()/lines() call a chain starts from, or the call itself.
sub source-call(Expr $e --> Call)
{
  return $e.source if $e ~~ Pipeline && $e.source ~~ Call && $e.source.name.lc (elem) <rows lines>;
  return $e if $e ~~ Call && $e.name.lc (elem) <rows lines>;
  Call
}

# The stages split into the fused run, the terminal that may end it, and the
# rest, which apply to the result. A Hash, not a List of Lists: rakupp 4.0.1
# flattens the inner Lists when a returned List is destructured.
sub split-stages(@stages --> Hash)
{
  my (@fused, $terminal, @rest);
  for @stages -> $st
  {
    my $n = $st.name.lc;
    if !@rest && !$terminal.defined && FUSED{$n}         { @fused.push($st) }
    elsif !@rest && !$terminal.defined && TERMINAL{$n}   { $terminal = $st }
    else                                                  { @rest.push($st) }
  }
  %(fused => @fused.List, terminal => $terminal, rest => @rest.List)
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

  # The function's defers, in the order written: [where, lines]. A 'return'
  # runs those written before it, the last one first.
  has @!defers;

  # The names the function declares: a 'using alias' word that is one of
  # them is a variable holding the alias, not the alias itself.
  has %!declared;

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
    for |$p.functions, |$p.methods -> $f
    {
      walk($f.body, -> $s
      {
        my $what = do given $s
        {
          when WithObject   { "'with object'" }
          when RawStmt      { "'raw'" }
          when ForInStmt    { source-call(.source).defined && source-call(.source).name.lc eq 'rows'
                                ?? "'for ... in' over rows()" !! Str }
          when Modified     { self!stream-value(.stmt).defined
                                ?? 'a chain from a source under a postfix modifier' !! Str }
          default           { Str }
        };
        @found.push($s.line => $what) with $what;

        # A source only reads at the head of a chain in a statement that can
        # run the loop first -- 'x := ...', 'return ...', the chain alone -- or
        # as the source of a 'for'.
        my $top = self!stream-value($s);
        my $for = $s ~~ ForInStmt && $s.source ~~ Call ?? $s.source !! Expr;
        my %heads;                     # the source calls that head a chain
        for exprs-of($s) -> $e
        {
          walk-expr($e, { %heads{.source.WHICH} = True if $_ ~~ Pipeline && .source ~~ Call });
        }
        for exprs-of($s) -> $e
        {
          walk-expr($e, -> $x
          {
            my $w = self!expr-extension($x);
            @found.push($s.line => $w) with $w;
            if $x ~~ Call && $x.name.lc (elem) <rows lines>
            {
              my $ok = ($top.defined && source-call($top) === $x) || ($for.defined && $for === $x);
              unless $ok
              {
                @found.push($s.line => %heads{$x.WHICH}
                  ?? "a chain from {$x.name.lc}() where it cannot run as a loop first "
                     ~ "(it goes in 'x := ...', 'return ...' or a statement of its own)"
                  !! "'{$x.name.lc}()' outside the head of a chain (it is a source)");
              }
            }
          });
        }
        @found.append(self!chain-problems($top, $s)) if $top.defined;
      });
      @found.append(self!scope-problems($f));
    }
    @found.unique(:as({ .key ~ "\0" ~ .value })).sort(*.key).List
  }

  method !expr-extension(Expr $x --> Str)
  {
    given $x
    {
      when Interval   { "'lo..hi'" }
      when SubjectRef { "':x' of 'with object'" }
      # A write inside an expression ('[k] h{k} := 1'): Set is a statement.
      when AssignExpr { .target ~~ HashIndex ?? 'a hash write inside an expression' !! Str }
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

  # What stops a chain from a source from being lowered.
  method !chain-problems(Expr $chain, Stmt $s --> List)
  {
    my @p;
    my $call = source-call($chain);
    my $kind = $call.name.lc;
    # One by one: rakupp 4.0.1 flattens Lists inside a list assignment.
    my %split = split-stages($chain ~~ Pipeline ?? $chain.stages.list !! ());
    my $fused    = %split<fused>;
    my $terminal = %split<terminal>;
    my $rest     = %split<rest>;

    @p.push("'rows()' with no alias, or more than an alias and a key")
      if $kind eq 'rows' && !(1 <= $call.args <= 2);
    @p.push("'lines()' with no path, or more than one") if $kind eq 'lines' && $call.args != 1;

    # A fused stage's lambda has to be written in the stage: it becomes the
    # loop's code, and a block held in a variable cannot.
    for |$fused, |($terminal // ()) -> $st
    {
      my $n = $st.name.lc;
      my $needs = NEEDS-LAMBDA{$n} || ($n (elem) <count first> && $st.args);
      if $needs && !($st.args == 1 && $st.args[0] ~~ Lambda && $st.args[0].params == 1)
      {
        @p.push("'$n' over {$kind}() without its lambda written in the stage");
      }
      @p.push("'take' over {$kind}() without a count") if $n eq 'take' && $st.args != 1;
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
        if $l ~~ Lambda && $l.params == 1 && self!record-misused($l)
        {
          @p.push("over rows() the element is the current record, so it can only name a field");
        }
        $mapped = True if $st.name.lc eq 'map';
      }
      my $t = $terminal.defined ?? $terminal.name.lc !! '';
      my $needs-value = $t (elem) <asum first> || (!$t && ($rest || $s !~~ CallStmt));
      @p.push("over rows() nothing to collect before a 'map' makes the record a value")
        if $needs-value && !$mapped;
    }
    @p.map({ $s.line => $_ }).List
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

  # ---- the whole file ----------------------------------------------------------
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

    # The defers, lowered once each, with their comment on their last line.
    @!defers = ();
    walk($f.body, -> $s
    {
      if $s ~~ Deferred
      {
        my @lines = self!stmt-lines($s.stmt);
        my $comment = split-comment(self!slice($s))[1];
        @lines[*-1] ~= "  $comment" if $comment;
        @!defers.push([$s.src-from, @lines.List]);
      }
    });

    self!collect($f.body, True);

    # The natural end: unless the body ends in a 'return', every defer runs
    # after its last statement.
    my $last = $f.body[*-1];
    if @!defers && $last.defined && $last !~~ ReturnStmt
    {
      my $at = self!line-end($last.src-from + code-end(self!slice($last)));
      my $indent = self!indent-at($f.body[0].src-from);
      my @lines = @!defers.reverse.map({ |.[1] });
      @!edits.push([$at, $at, @lines.map({ $!nl ~ $indent ~ $_ }).join]);
    }
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
      my $walked = False;             # set by a branch that walks the bodies itself
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
        # A 'defer' leaves where it is written; its body runs at the exits.
        when Deferred
        {
          my $from = self!line-start($s.src-from);
          my $end  = self!line-end($s.src-from + code-end(self!slice($s)));
          $end++ if $end < $!src.chars;              # the line break too
          @!edits.push([$from, $end, '']);
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
          my $m   = $raw.substr(0, $ce).lc.match(/ 'end' \s+ 'using' /, :g)[*-1];
          my $start = $s.src-from + $m.from;
          @!edits.push([$start, $s.src-from + $ce, self!join-at($start, @restore)]);

          @!closers.push('using' => @restore.List);
          self!collect($_, False) for bodies-of($s);
          @!closers.pop;
          $walked = True;
        }
        # A chain from a source: the loop first, then the statement with its
        # result -- or the loop alone, for a chain run for its effects.
        when { self!stream-value($_).defined }
        {
          my $statement = $s ~~ CallStmt;
          my ($result, @lines) = self!stream(self!stream-value($s), !$statement);
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
        when { $_ ~~ ForInStmt && source-call(.source).defined }
        {
          # 'for x in lines(p)': opened only if it exists, and advanced at the
          # top, so a 'loop' in the body does not stall on the same line. Every
          # way out closes it: the end of the loop, and each 'return' inside.
          self!hoist(.elem, 'a block local');
          self!hoist(.index, 'a block local') if .index.defined;
          my $fs  = self!gen('fs', 'the path of the file walked');
          my $fok = self!gen('fok', 'whether the file opened');
          my @h = "$fs := {self!expr(.source.args[0])}", "$fok := File($fs)",
                  "If $fok", "  FT_FUse($fs)", "  FT_FGoTop()", 'EndIf';
          @h.push("{.index} := 0") if .index.defined;
          my $while = @h.elems;
          @h.push("While $fok .And. !FT_FEof()");
          @h.push("  {.index} := {.index} + 1") if .index.defined;
          @h.append("  {.elem} := FT_FReadLn()", '  FT_FSkip()');
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
          self!collect($_, False) for bodies-of($s);
          @!closers.pop;
          @!closers.pop;
          $walked = True;
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
      # A Modified is lowered whole, with what it holds. A loop's body is
      # marked, so an 'exit' in it knows what it leaves.
      unless $s ~~ Modified || $walked
      {
        my $loop = $s ~~ WhileStmt || $s ~~ ForStmt || $s ~~ ForInStmt || $s ~~ ForTimesStmt;
        @!closers.push('loop' => ()) if $loop;
        self!collect($_, False) for bodies-of($s);
        @!closers.pop if $loop;
      }
    }
  }

  # What a 'return' at $s does first: the defers written before it, the last
  # one first -- they may still want the areas -- then everything open,
  # innermost first.
  method !return-exits(Stmt $s --> List)
  {
    (|@!defers.grep({ .[0] < $s.src-from }).reverse.map({ |.[1] }),
     |@!closers.reverse.grep(*.key ne 'loop').map({ |.value })).List
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
    with self!stream-value($s) -> $chain
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
    my %split = split-stages($chain ~~ Pipeline ?? $chain.stages.list !! ());
    my $fused    = %split<fused>;
    my $terminal = %split<terminal>;
    my $rest     = %split<rest>;
    my (@setup, @ahead, @body, @close, @teardown, $head, $advance, $read);
    my ($elem, $prefix, $fv) = Str, Str, Str;

    if $call.name.lc eq 'rows'
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
    my &lambda = -> $st { self!bound($st.args[0], $elem, $prefix) };
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
          @body.append("{$ind}If $fn >= $limit", "{$ind}  Exit", "{$ind}EndIf", "{$ind}$fn := $fn + 1");
        }
        when 'takewhile' { @body.append("{$ind}If !({lambda($st)})", "{$ind}  Exit", "{$ind}EndIf") }
      }
    }

    my $fo = Str;
    my $t = $terminal.defined ?? $terminal.name.lc !! '';
    if $t || $collect || $rest
    {
      $fo = self!gen('fo', 'the result of the chain');
      my $cond = $terminal.defined && $terminal.args ?? lambda($terminal) !! Str;
      given $t
      {
        when 'asum'   { @ahead.push("$fo := 0");   @body.push("{$ind}$fo := $fo + $elem") }
        when 'count'
        {
          @ahead.push("$fo := 0");
          @body.append($cond.defined
            ?? ("{$ind}If $cond", "{$ind}  $fo := $fo + 1", "{$ind}EndIf")
            !! ("{$ind}$fo := $fo + 1",));
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
        default       { @ahead.push("$fo := \{\}"); @body.push("{$ind}AAdd($fo, $elem)") }
      }
    }

    my @loop = $head, |(($read // ()).map({ "  $_" })), |(@body, @close).flat.map({ "  $_" }), "  $advance", 'EndDo';
    my $result = $fo // 'Nil';
    for @$rest -> $st
    {
      $result = call-name($st.name) ~ '(' ~ ($result, |$st.args.map({ self!part($_) })).join(', ') ~ ')';
    }
    ($result, |@setup, |@ahead, |@loop, |@teardown).List
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
    self!header-to($s, self!line-end($last.src-from + code-end(self!slice($last))), $at, |@lines);
  }

  # The same, up to a given end.
  method !header-to(Stmt $s, Int $end, Int $at, *@lines)
  {
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
      # 'h{k}': a call, right wherever it is (xtpl lifts a Get, which goes
      # wrong in a 'while' condition, an 'elseif' or a lambda).
      when HashIndex { "u_xtpl_hget({self!expr(.base)}, {self!expr(.key)})" }
      when HashLit
      {
        .pairs
          ?? 'u_xtpl_hnew({' ~ .pairs.map({ '{' ~ self!expr(.key) ~ ', ' ~ self!expr(.value) ~ '}' }).join(', ') ~ '})'
          !! 'THashMap():New()'
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
        my ($l, $rt) = self!expr(.left), self!expr(.right);
        given .op
        {
          when 'in'  { "u_xtpl_in($l, $rt)" }
          when 'has' { "u_xtpl_hhas($l, $rt)" }
          when '%%'  { "(($l) % ($rt) == 0)" }
          # The right side only when the left is Nil: a block, run if needed.
          default    { "u_xtpl_elvis($l, \{|| $rt\})" }
        }
      }
      when Name
      {
        %!subst{.name.lc}:exists ?? %!subst{.name.lc} !! self!with-edits($_, ())
      }
      when Member
      {
        .base ~~ Name && %!field{.base.name.lc}:exists
          ?? %!field{.base.name.lc} ~ .name
          !! self!with-edits($_, subexprs($_))
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
        self!lowers-itself($_)
          ?? call-name(.name) ~ '(' ~ .args.map({ self!part($_) }).join(', ') ~ ')'
          !! self!with-edits($_, subexprs($_))
      }
      default { self!with-edits($_, subexprs($_)) }
    }
  }

  # An expression that is rewritten itself, not just for what it holds.
  method !lowers-itself(Expr $e --> Bool)
  {
    return True if $e ~~ Lambda || $e ~~ Pipeline;
    return True if $e ~~ Call && VERBS{$e.name.lc}:exists;
    return True if $e ~~ Name && %!subst{$e.name.lc}:exists;
    return True if $e ~~ Member && $e.base ~~ Name && %!field{$e.base.name.lc}:exists;
    return True if $e ~~ HashIndex || $e ~~ HashLit || $e ~~ Guard || $e ~~ Interp;
    return True if $e ~~ SafeMember || $e ~~ SafeCall;
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
  # xtpl does; anything else is evaluated once, as the argument of a block.
  method !safe(Expr $base, Str $tail --> Str)
  {
    my $b = self!expr($base);
    $base ~~ Name
      ?? "If($b != Nil, $b$tail, Nil)"
      !! "Eval(\{|__v| If(__v != Nil, __v$tail, Nil)\}, $b)"
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
      when { $_ (elem) (':=', '=') } { (False, |@pre, "$h:Set($k, $v)") }
      when '?='       { (!@pre, |@pre, "If u_xtpl_hget($h, $k) == Nil", "  $h:Set($k, $v)", 'EndIf') }
      default         { (False, |@pre, "$h:Set($k, u_xtpl_hget($h, $k) {$a.op.chop} ($v))") }
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
