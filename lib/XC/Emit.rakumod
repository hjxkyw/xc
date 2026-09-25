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

class Emitter
{
  has Str $.src;
  has @!edits;                     # [from, to, text]

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
          when ForInStmt    { "'for ... in'" }
          when ForTimesStmt { "'for ... times'" }
          when WithObject   { "'with object'" }
          when RawStmt      { "'raw'" }
          when IfStmt       { .header-decl.defined ?? "'if local'" !! Str }
          when WhileStmt    { .header-decl.defined ?? "'while local'" !! Str }
          when CaseStmt     { (.subject-decl.defined || .subject-assign.defined) ?? "'do case with'" !! Str }
          when ForStmt      { .var-local ?? "'for local'" !! Str }
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
    }
    @found.unique(:as({ .key ~ "\0" ~ .value })).sort(*.key).List
  }

  method !expr-extension(Expr $x --> Str)
  {
    given $x
    {
      when Pipeline   { "'|>'" }
      when Lambda     { 'a lambda' }
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

  # ---- edits -------------------------------------------------------------------
  method emit(Program $p --> Str)
  {
    my @problems = self.not-lowered($p);
    die X::XC::NotLowered.new(problems => @problems) if @problems;

    self!collect($_.body) for |$p.functions, |$p.methods;
    my $out = $!src;
    for @!edits.sort({ -.[0] }) -> [$from, $to, $text]
    {
      $out = $out.substr(0, $from) ~ $text ~ $out.substr($to);
    }
    add-includes($out)
  }

  # The statements to rewrite. A rewritten statement is lowered whole,
  # whatever it holds, so the walk does not go into it.
  method !collect(@body)
  {
    for @body -> $s
    {
      if needs-lowering($s)
      {
        @!edits.push([$s.src-from, $s.src-to, self!render($s)]);
      }
      else
      {
        self!collect($_) for bodies-of($s);
      }
    }
  }

  # A statement's replacement: its lowered lines, the first at the statement's
  # own place, the rest at its indentation, and its comment put back.
  method !render(Stmt $s --> Str)
  {
    my $start  = ($!src.rindex("\n", $s.src-from - 1) // -1) + 1;
    my $indent = $!src.substr($start, $s.src-from - $start);
    $indent = ' ' x $indent.chars if $indent ~~ /\S/;
    my (Str $code, Str $comment) = split-comment(self!slice($s));

    my ($block, @lines) = self!lower($s);
    if $comment
    {
      my $at = $block ?? 0 !! @lines.end;
      @lines[$at] ~= "  $comment";
    }
    (@lines[0], |@lines[1..*].map({ $indent ~ $_ })).join("\n")
  }

  method !slice($n --> Str) { $!src.substr($n.src-from, $n.src-to - $n.src-from) }
  method !code($n --> Str)  { split-comment(self!slice($n))[0].trim }

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
          ?? (True, "While {self!code(.cond)}", |@inner, 'EndDo')
          !! (True, "If {self!code(.cond)}",    |@inner, 'EndIf')
      }
      when Assignment
      {
        # '?=': assign only when the target is Nil.
        my $t = self!code(.target);
        (True, "If $t == Nil", "  $t := {self!code(.value)}", 'EndIf')
      }
      when Declaration
      {
        # xtpl's order ('as T' first) swapped back, and the attributes dropped:
        # '<const>' and '<contained>' are checks, and emit nothing.
        my $kw = self!code($s).words[0];
        my @d = .declarators.map(-> $d
        {
          $d.name
            ~ ($d.init.defined ?? " := {self!code($d.init)}" !! '')
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
    self!code($s).lines.List
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
sub add-includes(Str $out --> Str)
{
  my @missing = ('totvs.ch', 'tlpp-core.th').grep(-> $h
  {
    !($out ~~ m:i/ ^^ \h* '#include' \h* '"' $h '"' /)
  });
  @missing ?? @missing.map({ "#include \"$_\"" }).join("\n") ~ "\n\n" ~ $out !! $out
}

# The whole file: TL++ from the tree and its source.
sub emit(Program $p, Str $src --> Str) is export
{
  Emitter.new(src => $src).emit($p)
}
