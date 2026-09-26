# XC::Check -- what xtpl refuses although it parses.
#
# Between the parse and the emitter: names and their scopes, '<const>' and
# '<contained>', 'external', the calls to this file's own functions, and a few
# shapes of chain. Each rule and each message is xtpl's (t/xtpl/errors/ has one
# case for each, with xtpl's message).
#
# NAMES
#
# Everything used should be declared, as in xtpl: a parameter, a 'local',
# 'static' or 'public', a 'private' anywhere in the function (it is dynamic), a
# block local while its block lasts, a lambda's or code block's parameter, an
# 'external', a '#define' of the file. A name is not a variable where it is a
# call, a member, a field, or anywhere inside 'ALIAS->( ... )', where bare
# names are the area's fields. A bare function name given to a verb that takes
# a block ('map(alltrim)') is that function. A block local is in scope from
# its declaration to the end of its block; after that its name is 'out of
# scope', not 'not declared'.
#
# A name nothing declares is a warning, not an error -- a choice xtpl did not
# make: plain TL++ uses the system's globals (cFilAnt, dDataBase, CRLF from
# totvs.ch) without declaring them, and it compiles unchanged. The messages
# are the ones xtpl gives when it only warns, in its legacy mode: once per
# name and file, and a name an undeclared write has made a PRIVATE is known
# from then on.

#
# WARNINGS
#
# Besides a name nothing declares: a variable assigned but never read (or
# declared and never used), a function that returns a value on one path and
# nothing on another, and a field of an area nothing in the function opened --
# xtpl's, in xtpl's words. Not its fusion warnings: they are about fusing
# chains over arrays, which xc does not do.

use XC::AST;
use XC::Grammar;

unit module XC::Check;

# The calls that open a work area, when given its name as a string.
my constant OPENERS = set <dbselectarea dbusearea chkfile>;

# Words that are never a variable (xtpl's 'known_words').
my constant KNOWN = set <nil to step exit loop self super iif in and or not t f class data method
                         endclass begin sequence recover always endsequence try catch endtry case
                         endcase switch default parameters then as from of nonempty _super>;

# The verbs that take a block, where a bare function name is that function.
my constant TAKES-BLOCK = set <map filter reject tap takewhile dropwhile expand maxby minby
                               sortby chunkby distinctadjacent first count anyof allof noneof>;

# What a chain cannot walk: a type that holds one value.
my constant SCALAR-TYPES = set <numeric character logical date json>;

# A scope: the names it declares, and the one around it. A closure scope is a
# lambda's or a code block's: a name found beyond it is captured.
my class Scope
{
  has Scope $.outer;
  has Bool  $.closure = False;
  has %.names;                     # lower case => %(name, line, const, contained)
}

my class Checker
{
  has @.found;                     # Pairs: line => message -- errors
  has @.warned;                    # Pairs: line => message -- warnings
  has %!warned-names;              # 'read x' / 'write x' => True: each warned once
  has %!implicit;                  # lower case => True: made a PRIVATE by a write
  has %!funcs;                     # lower case => %(name, kind, params, line)
  has %!externals;                 # lower case => the line of its 'external'
  has %!defines;                   # lower case => True
  has %!privates;                  # lower case => True, in the whole file
  has %!retired;                   # lower case => line: block locals whose block is over
  has %!scalar;                    # lower case => why a chain cannot walk it
  has %!sources-ok;                # WHICH of the rows()/lines() calls where a source may be
  has Scope $!scope;
  has Int  $!line = 0;
  has Bool $!in-defer = False;
  has @!records;                   # this function's variables, for 'never read'
  has %!opened;                    # upper case => True: areas this function opened
  has %!warned-alias;              # upper case => True: 'not opened' said already
  has %!external-alias;            # upper case => True: 'external alias'
  has Int $.lines = 0;             # the file's length: where the last function ends
  has @!ends;                      # the lines the functions start on, sorted

  method !problem(Str $message) { @!found.push($!line => $message) }
  method !warning(Str $message)  { @!warned.push($!line => $message) }

  # ---- the file ---------------------------------------------------------------
  method program(Program $p)
  {
    for $p.functions -> $f
    {
      %!funcs{$f.name.lc} = %(name => $f.name, kind => $f.type.lc, params => $f.params.elems, line => $f.line);
    }
    for $p.externals.grep(!*.alias) -> $x
    {
      %!externals{.lc} = $x.line for $x.names;
    }
    for $p.externals.grep(*.alias) -> $x
    {
      %!external-alias{.uc} = True for $x.names;
    }
    @!ends = (|$p.functions, |$p.methods, |$p.classes).map(*.line).sort;
    for $p.directives -> $d
    {
      %!defines{~$0.lc} = True if $d ~~ m:i/ ^ '#' \h* 'define' \h+ (\w+) /;
    }
    # A 'private' is dynamic: a function the file calls sees it, so its name
    # is known in the whole file, as in xtpl.
    for |$p.functions, |$p.methods -> $f
    {
      walk($f.body, -> $s
      {
        if $s ~~ Declaration && $s.scope eq 'private'
        {
          %!privates{.name.lc} = True for $s.declarators;
        }
      });
    }
    self!function($_) for |$p.functions, |$p.methods;
  }

  method !function($f)
  {
    %!retired      = ();
    %!scalar       = ();
    @!records      = ();
    %!opened       = ();
    %!warned-alias = ();
    $!scope = Scope.new;
    $!line  = $f.line;
    self!declare(.name, $f.line, kind => 'param') for $f.params;
    self!body($f.body);
    self!never-read;
    self!returns($f);
  }

  # A variable never read: assigned, or not even that. Not a parameter, a
  # public or a private (a callee may read those), nor what a loop declares.
  method !never-read()
  {
    for @!records.grep({ .<kind> eq 'local' && !.<reads> }).sort(*.<line>) -> %v
    {
      @!warned.push(%v<line> => (%v<writes>
        ?? "'{%v<name>}' is assigned but never read"
        !! "'{%v<name>}' is declared but never used"));
    }
  }

  # A function that returns a value on one path and nothing on another hands
  # its caller a Nil, found out somewhere else and later.
  method !returns($f)
  {
    my (@valued, @bare);
    walk($f.body, -> $s
    {
      if $s ~~ ReturnStmt { ($s.value.defined ?? @valued !! @bare).push($s) }
    });
    return unless @valued;
    my $first = @valued.map(*.line).min;
    for @bare -> $b
    {
      @!warned.push($b.line => "this returns nothing, but the function returns a value on line $first");
    }
    my $last = $f.body[*-1];
    unless $last ~~ ReturnStmt || ($last ~~ Modified && $last.stmt ~~ ReturnStmt)
    {
      # On the function's last line, as xtpl does: the one before the next
      # function, or the file's last.
      my $next = @!ends.first(* > $f.line);
      my $end = $next.defined ?? $next - 1 !! ($!lines || $last.line);
      @!warned.push($end => "the function can reach its end without a return, but returns a value on line $first");
    }
  }

  # ---- scopes -------------------------------------------------------------------
  # $kind: 'local' (a local or a static: reported if never read), 'param',
  # 'loop' (what a loop header declares) or 'public'. $written: it has a value.
  method !declare(Str $name, Int $line, :@attributes = (), Str :$kind = 'local', Bool :$written = False)
  {
    my $k = $name.lc;
    if $!scope.names{$k}:exists
    {
      @!found.push($line => "'$name' is already declared in this block.");
      return;
    }
    my %v = name => $name, line => $line, kind => $kind, reads => 0, writes => +$written,
            const => so('const' (elem) @attributes),
            contained => so('contained' (elem) @attributes);
    $!scope.names{$k} = %v;
    @!records.push(%v);
    %!retired{$k}:delete;
  }

  # The declaration itself, to count its reads and writes. Held in a variable
  # before '<reads>++': under rakupp 4.0.1, '++' on an element of a Hash a
  # method returned changes a copy (Rakudo changes the Hash).
  method !record(Str $k)
  {
    my $s = $!scope;
    while $s.defined
    {
      return $s.names{$k} if $s.names{$k}:exists;
      $s = $s.outer;
    }
    Nil
  }

  # Code in a block of its own. Its names are retired when it ends, unless an
  # enclosing scope has them too.
  method !in-block(&code)
  {
    my $outer = $!scope;
    $!scope = Scope.new(outer => $outer);
    code();
    my %names = $!scope.names;
    $!scope = $outer;
    for %names.kv -> $k, $v
    {
      %!retired{$k} = $v<line> unless self!find($k).defined;
    }
  }

  # A name's declaration, and whether a closure lies between here and it.
  method !find(Str $k --> Map)
  {
    my $s = $!scope;
    my $crossed = False;
    while $s.defined
    {
      return %( |$s.names{$k}, captured => $crossed ).Map if $s.names{$k}:exists;
      $crossed ||= $s.closure;
      $s = $s.outer;
    }
    Map
  }

  method !exempt(Str $name --> Bool)
  {
    my $k = $name.lc;
    so KNOWN{$k} || XC::Grammar::is-reserved($name) || XC::Grammar::is-generated($name)
       || %!externals{$k} || %!defines{$k} || %!privates{$k}
  }

  # ---- names ----------------------------------------------------------------------
  # A '<contained>' variable cannot leave its block: not captured by a lambda
  # or a code block, not passed by reference, not read by a 'defer' (which
  # runs at the end of the function), not given to a 'raw' command.
  method !leaves(%v, Str $name, Bool $how)
  {
    self!problem("'$name' is <contained> (declared on line {%v<line>}) and cannot leave its block.")
      if %v<contained> && $how;
  }

  method !read(Str $name)
  {
    my $k = $name.lc;
    with self!find($k) -> %v
    {
      my $r = self!record($k);
      $r<reads>++;
      self!leaves(%v, $name, %v<captured> || $!in-defer);
      return;
    }
    return self!problem("'$name' is out of scope here (block local declared on line {%!retired{$k}}).")
      if %!retired{$k}:exists;
    return if self!exempt($name) || %!implicit{$k};
    self!warning("'$name' is not declared") unless %!warned-names{"read $k"}++;
  }

  # $reads: it reads too ('+=', '?=', a 'for' counter) -- xtpl counts a name
  # as written only alone on the left of ':='.
  method !write(Str $name, Bool :$reads = False)
  {
    my $k = $name.lc;
    with self!find($k) -> %v
    {
      my $r = self!record($k);
      $reads ?? $r<reads>++ !! $r<writes>++;
      self!problem("'$name' is <const> (declared on line {%v<line>}) and cannot be assigned.") if %v<const>;
      self!leaves(%v, $name, %v<captured> || $!in-defer);
      return;
    }
    return self!problem("'$name' is out of scope here (block local declared on line {%!retired{$k}}).")
      if %!retired{$k}:exists;
    return self!problem("'$name' is external (line {%!externals{$k}}) and cannot be assigned.")
      if %!externals{$k}:exists;
    return if self!exempt($name) || %!implicit{$k};
    # AdvPL makes a PRIVATE of it; from here on it exists.
    %!implicit{$k} = True;
    self!warning("'$name' is not declared, so this creates a PRIVATE") unless %!warned-names{"write $k"}++;
  }

  # '@x': read and written, and handed over.
  method !by-ref(Str $name)
  {
    my $k = $name.lc;
    with self!find($k) -> %v
    {
      my $r = self!record($k);
      $r<reads>++;
      self!problem("'$name' is <const> (declared on line {%v<line>}) and cannot be passed by reference with '@'.")
        if %v<const>;
      self!leaves(%v, $name, True);
      return;
    }
    self!read($name);
  }

  # A bare name given to a verb where a block goes: a function, unless it is a
  # variable.
  method !block-arg(Str $verb, Expr $e)
  {
    return self!expr($e) unless TAKES-BLOCK{$verb.lc} && $e ~~ Name;
    my $k = $e.name.lc;
    self!read($e.name) if self!find($k).defined || %!retired{$k}:exists || self!exempt($e.name);
  }

  # ---- statements -----------------------------------------------------------------
  method !body(@stmts) { self!stmt($_) for @stmts }

  method !stmt(Stmt $s)
  {
    $!line = $s.line if $s.line;
    %!sources-ok = ();
    # Where a rows()/lines() call may stand alone: the whole value of an
    # assignment, a declaration, a 'return', the source of a 'for'.
    my @whole = do given $s
    {
      when Assignment  { (.value,) }
      when ReturnStmt  { (.value // ()) }
      when Declaration { .declarators.map(*.init).grep(*.defined) }
      when ForInStmt   { (.source,) }
      default          { () }
    };
    %!sources-ok{.WHICH} = True for @whole.grep({ $_ ~~ Call });

    given $s
    {
      when Declaration
      {
        for .declarators -> $d
        {
          self!expr($d.init) if $d.init.defined;
          next if $s.scope eq 'private';
          self!declare($d.name, $d.line, attributes => $d.attributes,
                       kind => $s.scope eq 'public' ?? 'public' !! 'local', written => $d.init.defined);
          self!note-scalar($d);
        }
      }
      when Assignment { self!expr(.value); self!target(.target, .op) }
      when CallStmt   { self!expr(.call) }
      when ReturnStmt { self!expr(.value) if .value.defined }
      when IfStmt
      {
        my $if = $_;
        self!expr($if.header-decl.init) if $if.header-decl.defined;
        self!in-block({
          with $if.header-decl -> $d { self!declare($d.name, $d.line, attributes => $d.attributes, :written) }
          for $if.branches -> $b
          {
            self!expr($b.cond);
            self!body($b.body);
          }
          self!body($if.otherwise);
        });
      }
      when WhileStmt
      {
        my $w = $_;
        self!expr($w.header-decl.init) if $w.header-decl.defined;
        self!in-block({
          with $w.header-decl -> $d { self!declare($d.name, $d.line, attributes => $d.attributes, :written) }
          self!expr($w.cond);
          self!body($w.body);
        });
      }
      when ForStmt
      {
        my $f = $_;
        self!expr($_) for $f.from, $f.to, $f.step;
        self!write($f.var, :reads) unless $f.var-local;
        self!in-block({
          self!declare($f.var, $f.line, kind => 'loop') if $f.var-local;
          self!body($f.body);
        });
      }
      when ForInStmt
      {
        my $f = $_;
        self!expr($f.source);
        self!in-block({
          self!declare($f.elem, $f.line, kind => 'loop');
          self!declare($f.index, $f.line, kind => 'loop') if $f.index.defined;
          self!body($f.body);
        });
      }
      when ForTimesStmt
      {
        my $f = $_;
        self!expr($f.count);
        self!in-block({ self!body($f.body) });
      }
      when CaseStmt
      {
        my $c = $_;
        self!expr($c.subject-decl.init) if $c.subject-decl.defined;
        with $c.subject-assign -> $a { self!expr($a.value); self!target($a.target, $a.op) }
        self!in-block({
          with $c.subject-decl -> $d { self!declare($d.name, $d.line, attributes => $d.attributes, :written) }
          for $c.branches -> $b
          {
            self!expr($b.cond);
            self!body($b.body);
          }
          self!body($c.otherwise);
        });
      }
      when SequenceStmt
      {
        my $q = $_;
        self!in-block({ self!body($q.body) });
        self!write($q.error-var) if $q.error-var.defined;
        self!in-block({ self!body($q.recover) });
      }
      when UsingAlias
      {
        my $u = $_;
        self!expr($u.order) if $u.order.defined;
        # The word is a variable holding the alias if one is declared by
        # that name, and the alias itself otherwise.
        if self!find($u.area.lc).defined { self!read($u.area) } else { %!opened{$u.area.uc} = True }
        self!in-block({ self!body($u.body) });
      }
      when WithObject
      {
        my $w = $_;
        self!expr($w.subject);
        self!in-block({ self!body($w.body) });
      }
      when Modified
      {
        self!expr(.cond);
        self!stmt(.stmt);
      }
      when Deferred
      {
        my $saved = $!in-defer;
        $!in-defer = True;
        self!stmt(.stmt);
        $!in-defer = $saved;
      }
      when RawStmt
      {
        # Raw text is not read -- xtpl is lenient there -- but a command can
        # hold on to what it is given (GET does), so a '<contained>' variable
        # named in it leaves its block.
        for .lines -> $l
        {
          for $l.comb(/ <[A..Za..z_]> \w* /) -> $w
          {
            with self!find($w.lc) -> %v
            {
              my $r = self!record($w.lc);
              $r<reads>++;
              self!leaves(%v, %v<name>, True);
            }
          }
        }
      }
    }
  }

  # The target of an assignment: a name is written; anything else reads its
  # parts ('o' in 'o:x := 1', 'h' and 'k' in 'h{k} := v').
  method !target(Expr $t, Str $op = ':=')
  {
    $t ~~ Name ?? self!write($t.name, reads => !($op (elem) (':=', '='))) !! self!expr($t);
  }

  # A declaration that says its variable holds one value -- a scalar literal,
  # or a scalar type -- for the chain check.
  method !note-scalar(Declarator $d)
  {
    my $k = $d.name.lc;
    my $type = ($d.typespec-text // '').subst(/:i ^ 'as' \s+ /, '').lc;
    if SCALAR-TYPES{$type}
    {
      %!scalar{$k} = " -- it is declared 'as $type'";
    }
    elsif $d.init ~~ Literal && is-scalar($d.init)
    {
      %!scalar{$k} = " -- it was declared as {$d.init.text}";
    }
  }

  # ---- expressions ------------------------------------------------------------------
  method !expr($e)
  {
    return unless $e.defined && $e ~~ Expr;
    given $e
    {
      when Name { self!read(.name) }
      when CodeBlock
      {
        # A lambda or a code block: its parameters are its own, and a name
        # from outside is captured.
        my $outer = $!scope;
        $!scope = Scope.new(outer => $outer, closure => True);
        self!declare($_, $!line, kind => 'param') for .params;
        self!expr($_) for .body;
        $!scope = $outer;
      }
      # 'SA1->x', 'SA1->( ... )': the name before '->' is the area, not a
      # variable -- in AdvPL a variable needs parentheses, '(cAlias)->x', and
      # the tree does not keep them. So a name there is read only if a
      # variable by that name exists. Inside '( ... )' a bare name is a field.
      when InAlias    { self!alias-base(.base) }
      when AliasField { self!field($_); self!alias-base(.base) }
      when Ref        { .target ~~ Name ?? self!by-ref(.target.name) !! self!expr(.target) }
      when AssignExpr { self!expr(.value); self!target(.target, .op) }
      when Call
      {
        self!call($_);
        my $c = $_;
        for $c.args.kv -> $i, $a
        {
          $i == 0 ?? self!expr($a) !! self!block-arg($c.name, $a);
        }
      }
      when Pipeline
      {
        my $p = $_;
        self!chain($p);
        self!expr($p.source);
        for $p.stages -> $st
        {
          self!block-arg($st.name, $_) for $st.args;
        }
      }
      when Guard
      {
        with source-of(.expr)
        {
          self!problem("'fallback' cannot guard a walk over {.name.lc}(). The guard needs an expression "
                       ~ "and a walk is a loop. Assign the chain first, then guard what uses it.")
            if $_ ~~ Call;
        }
        self!expr(.expr);
        self!expr(.fallback);
      }
      default { self!expr($_) for subexprs($e) }
    }
  }

  # A call to one of this file's functions: the right form -- 'u_name' for a
  # user function, the plain name for a static one -- and no more arguments
  # than it takes. AdvPL checks neither: the wrong form fails at run time,
  # and extra arguments are silently unreachable.
  method !call(Call $c)
  {
    my $n = $c.name.lc;
    # An area opened here: DbSelectArea("SA1") and the like, and rows("SA1").
    if OPENERS{$n} || $n eq 'rows'
    {
      for $c.args.grep({ $_ ~~ Literal && .type eq 'Character' && $_ !~~ Interp }) -> $a
      {
        my $name = $a.text.substr(1, *-1);
        %!opened{$name.uc} = True if $name ~~ / ^ <[A..Za..z_]> \w* $ /;
      }
    }
    if $n (elem) <rows lines> && !%!sources-ok{$c.WHICH}
    {
      self!problem("'{$n}()' is a source, and only reads at the head of a chain. Assign it, "
                   ~ "or feed it into stages with '|>'.");
    }
    my $plain = $n.starts-with('u_') ?? $n.substr(2) !! $n;
    with %!funcs{$plain} -> %f
    {
      if $n.starts-with('u_') && %f<kind> eq 'static'
      {
        self!problem("'{$c.name}' -- {%f<name>} is a static function in this file, so it is called by "
                     ~ "its plain name, without the 'u_'.");
      }
      elsif !$n.starts-with('u_') && %f<kind> eq 'user'
      {
        self!problem("'{$c.name}' is a user function (line {%f<line>}), so it is called as "
                     ~ "'u_{$c.name}' -- the compiler puts the prefix on the declaration.");
      }
    }
    my %f = %!funcs{$n} // %!funcs{$plain} // return;
    my $given = $c.args.grep({ $_ !~~ Omitted }).elems;
    if $given > %f<params>
    {
      self!problem("{%f<name>}() takes {%f<params>} parameter{%f<params> == 1 ?? '' !! 's'} "
                   ~ "(line {%f<line>}), but is given $given.");
    }
  }

  # 'SA1->A1_COD': an area nothing in the function opened, said once per
  # area. A variable holding the alias ('(cAlias)->x') cannot be checked.
  method !field(AliasField $f)
  {
    my $word = $f.alias // ($f.base ~~ Name ?? $f.base.name !! Str);
    return unless $word.defined && !self!find($word.lc).defined;
    my $a = $word.uc;
    return if %!opened{$a} || %!external-alias{$a} || $a.starts-with('__') || %!warned-alias{$a}++;
    self!warning("nothing in this function opened $a. Wrap the use in 'using alias $a do', "
                 ~ "or declare 'external alias $a' if the caller opens it.");
  }

  method !alias-base($b)
  {
    return unless $b.defined;
    return self!expr($b) unless $b ~~ Name;
    self!read($b.name) if self!find($b.name.lc).defined;
  }

  # A chain: a source it can walk.
  method !chain(Pipeline $p)
  {
    my $src = $p.source;
    %!sources-ok{$src.WHICH} = True if $src ~~ Call;
    if $src ~~ Literal && is-scalar($src)
    {
      self!scalar-source($src.text, '');
    }
    elsif $src ~~ Name && %!scalar{$src.name.lc}:exists
    {
      self!scalar-source($src.name, %!scalar{$src.name.lc});
    }
    # Over rows(), before a 'map' the element is the record: no value to
    # compare for distinctAdjacent without a key.
    if $src ~~ Call && $src.name.lc eq 'rows'
    {
      for $p.stages -> $st
      {
        last if $st.name.lc (elem) <map expand>;
        if $st.name.lc eq 'distinctadjacent' && !$st.args
        {
          self!problem("distinctAdjacent over rows() needs a key -- the record is not a value to compare "
                       ~ "against the previous one. Give it one, as distinctAdjacent([r] r:C6_NUM), or map first.");
          last;
        }
      }
    }
  }

  method !scalar-source(Str $shown, Str $why)
  {
    self!problem("$shown is a single value$why, and a chain walks a collection. Write \{$shown\} for a "
                 ~ "one-element array, or 'lo..hi' for a range.");
  }
}

# A literal that holds one value: not an array, a hash, a JSON or a block.
sub is-scalar(Literal $l --> Bool)
{
  !($l ~~ ArrayLit || $l ~~ HashLit || $l ~~ JsonLit || $l ~~ CodeBlock)
}

# The rows()/lines() call a chain walks, if it walks one.
sub source-of($e)
{
  return $e.source if $e ~~ Pipeline && $e.source ~~ Call && $e.source.name.lc (elem) <rows lines>;
  return $e if $e ~~ Call && $e.name.lc (elem) <rows lines>;
  Nil
}

# What xtpl refuses in a program that parses: Pairs, line => message, in the
# order of the lines. Not called 'check': every test file has a helper by
# that name.
sub check-program(Program $p --> List) is export
{
  check-all($p)<errors>
}

# The same, with the warnings: %(errors => ..., warnings => ...).
sub check-all(Program $p, Int :$lines = 0 --> Hash) is export
{
  my $c = Checker.new(:$lines);
  $c.program($p);
  my &tidy = { .unique(:as({ .key ~ "\0" ~ .value })).sort(*.key).List };
  %(errors => tidy($c.found), warnings => tidy($c.warned))
}
