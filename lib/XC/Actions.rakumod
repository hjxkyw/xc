# XC::Actions -- what turns a grammar match into a tree.
#
# One method per rule that produces a node. A statement without a method does
# not vanish silently: 'statement' dies naming it, because a body missing a
# statement is a wrong tree that looks right.

use XC::AST;
use XC::Source;

unit class XC::Actions;

# The whole text, to know which line each node is on and where it came from:
#
#     XC::Grammar.parse($src, actions => XC::Actions.new(source => $src))
#
# It has to come from outside because under rakupp 4.0.1 '$/.orig' is only the
# matched text, not the whole target as under Rakudo -- and no other method of
# the match returns it. Positions go through XC::Source, which turns match
# offsets (bytes under rakupp 4.0.1) into characters and lines.
has Str $.source;
has XC::Source $!pos;

submethod TWEAK()
{
  $!pos = XC::Source.new(text => $_) with $!source;
}

method !line($m --> Int)
{
  die "XC::Actions needs the source text: XC::Actions.new(source => \$src)"
    without $!source;
  $!pos.line($m.from)
}

# A match's start and end as character offsets.
method !from($m --> Int) { $!pos.char($m.from) }
method !to($m --> Int)   { $!pos.char($m.to) }

# Records where an expression came from. The same node can pass up through
# several levels ('(a)' is the node 'a'); the widest span wins, and it still
# denotes that node.
method !spanned(Expr $e, $/)
{
  $e.src-from = self!from($/);
  $e.src-to   = self!to($/);
  $e
}

# A folded operator spans from its left operand to its right one: the
# emitter rewrites some of them whole ('%%', 'in', 'has', '?:').
sub joined(Binary $b --> Binary)
{
  if $b.left.defined && $b.left.src-from >= 0 && $b.right.src-to >= 0
  {
    $b.src-from = $b.left.src-from;
    $b.src-to   = $b.right.src-to;
  }
  $b
}

# ---- the file -------------------------------------------------------------------
method TOP($/)
{
  my ($ns, @usings, @directives, @annotations, @functions, @classes, @methods, @externals);
  for $<toplevel> -> $t
  {
    if $t<function>
    {
      @functions.push($t<function>.made);
    }
    elsif $t<classdecl>
    {
      @classes.push($t<classdecl>.made);
    }
    elsif $t<methodimpl>
    {
      @methods.push($t<methodimpl>.made);
    }
    elsif $t<preproc>
    {
      @directives.push((~$t<preproc>).trim);
    }
    elsif $t<externalst>
    {
      @externals.push($t<externalst>.made);
    }
    elsif $t<annotation>
    {
      @annotations.push($t<annotation>.made);
    }
    elsif $t<namespacest>
    {
      my $n = $t<namespacest>;
      if (~$n).trim.lc.starts-with('using')
      {
        @usings.push(~$n<dottedname>);
      }
      else
      {
        $ns = ~$n<dottedname>;
      }
    }
  }
  make Program.new(
    namespace   => $ns,
    usings      => @usings,
    directives  => @directives,
    annotations => @annotations,
    functions   => @functions,
    classes     => @classes,
    methods     => @methods,
    externals   => @externals,
  );
}

method externalst($/)
{
  my $x = External.new(
    alias => ?$<isalias>,
    names => $<xname>.map(~*).list,
    line  => self!line($/),
  );
  $x.src-from = self!from($/);
  $x.src-to   = self!to($/);
  make $x;
}

method function($/)
{
  my @w = (~$<funckind>).lc.words;
  make FunctionDef.new(
    type        => @w > 1 ?? @w[0] !! '',
    name        => ~$<name>,
    params      => $<params><param>.map(*.made).list,
    annotations => $<annotation>.map(*.made).list,
    body        => $<body>.made,
    line        => self!line($<funckind>),
  );
}

method param($/)
{
  make Param.new(
    name     => ~$<name>,
    declared => $<typespec> ?? type-of-name(~$<typespec><typename>) !! UNKNOWN,
  );
}

# ---- TL++: classes --------------------------------------------------------------
method classdecl($/)
{
  my (@members, @methods);
  for $<classmember> -> $m
  {
    if $m<datadecl> { @members.append($m<datadecl>.made.list) }
    else            { @methods.push($m<methdecl>.made) }
  }
  make ClassDef.new(
    name    => ~$<cname>,
    supers  => $<supers> ?? $<supers>.map(~*).list !! (),
    members => @members,
    methods => @methods,
    line    => self!line($/),
  );
}

method datadecl($/)
{
  my $vis = $<visib> ?? ~$<visib>.trim.lc !! Str;
  make $<datavar>.map(-> $d
  {
    DataMember.new(
      name       => ~$d<dname>,
      type       => $d<dtype> ?? ~$d<dtype> !! Str,
      visibility => $vis,
    )
  }).list;
}

method methdecl($/)
{
  my ($constructor, $returns) = False, Str;
  for $<methtag> -> $t
  {
    if $t<ret> { $returns = ~$t<ret> } else { $constructor = True }
  }
  make MethodSig.new(
    name        => ~$<mname>,
    params      => $<params><param>.map(*.made).list,
    visibility  => $<visib> ?? ~$<visib>.trim.lc !! Str,
    constructor => $constructor,
    returns     => $returns,
  );
}

method methodimpl($/)
{
  make MethodImpl.new(
    class-name => ~$<cname>,
    name       => ~$<mname>,
    params     => $<params><param>.map(*.made).list,
    returns    => $<ret> ?? ~$<ret> !! Str,
    body       => $<body>.made,
    line       => self!line($/),
  );
}

# '::x': the object itself as the base. A member ('::aBuf') or a method
# ('::Grow()').
method selfacc($/)
{
  my $base = SelfRef.new;
  make $<arglist>
    ?? MethodCall.new(base => $base, name => ~$<member>, args => $<arglist>.made.list)
    !! Member.new(base => $base, name => ~$<member>);
}

method annotation($/)
{
  make Annotation.new(
    name => ~$<name>,
    args => $<arglist> ?? $<arglist>.made !! (),
    line => self!line($/),
  );
}

# ---- statements -----------------------------------------------------------------
method body($/)       { make $<statement>.map(*.made).list }
method funcbody($/)   { make $<statement>.map(*.made).list }
method closedbody($/) { make $<statement>.map(*.made).list }

# What matched is the only child: the alternation is ordered, only one side
# wins.
method statement($/)
{
  my $node;
  if $<simple>
  {
    $node = $<simple>.made;
    with $<modifier> -> $m
    {
      $node = Modified.new(stmt => $node, op => (~$m<kw>).lc, cond => $m<cond>.made,
                           line => self!line($/));
    }
  }
  else
  {
    $node = $/.hash.values[0].made;
  }
  die "no node for '{$/.hash.keys.sort.join(',')}': {(~$/).trim}" without $node;
  # The inner statement of a modifier has a span of its own, for the emitter.
  with $<simple> -> $s
  {
    $s.made.src-from = self!from($s);
    $s.made.src-to   = self!to($s);
  }
  $node.src-from = self!from($/);
  $node.src-to   = self!to($/);
  make $node;
}

method simple($/) { make $/.hash.values[0].made }

method deferst($/)
{
  my $m = $<assignment> // $<pipest> // $<callst>;
  my $stmt = $m.made;
  $stmt.src-from = self!from($m);      # the deferred statement's own span
  $stmt.src-to   = self!to($m);
  make Deferred.new(stmt => $stmt, line => self!line($/));
}

# 'exec f() if c': the expression becomes a statement, inside the modifier.
method execst($/)
{
  my $call = CallStmt.new(call => $<expr>.made, line => self!line($/));
  $call.src-from = self!from($<expr>);
  $call.src-to   = self!to($<expr>);
  make Modified.new(
    stmt => $call,
    op   => (~$<modifier><kw>).lc,
    cond => $<modifier><cond>.made,
    line => self!line($/),
  );
}

method returnst($/)
{
  make ReturnStmt.new(value => $<expr> ?? $<expr>.made !! Expr, line => self!line($/));
}

method exitst($/) { make ExitStmt.new(line => self!line($/)) }
method loopst($/) { make LoopStmt.new(line => self!line($/)) }

# 'x ?= v': an Assignment with op '?='. Lowering is 'If x == Nil / x := v'.
method nilassign($/)
{
  make Assignment.new(
    target => $<lvalue>.made,
    op     => '?=',
    value  => $<expr>.made,
    line   => self!line($/),
  );
}

method assignment($/)
{
  make Assignment.new(
    target => $<lvalue>.made,
    op     => ~$<assignop>,
    value  => $<expr>.made,
    line   => self!line($/),
  );
}

method lvalue($/)
{
  my $base = $<selfacc> ?? $<selfacc>.made
          !! $<subjacc> ?? $<subjacc>.made
          !! $<pexpr>   ?? $<pexpr>.made
          !! $<call>    ?? $<call>.made
          !!               Name.new(name => ~$<name>);
  make self!spanned(self!trailed($base, $<selfacc> // $<subjacc> // $<pexpr> // $<call> // $<name>,
                                 $<trailer>, $/), $/);
}

method callst($/)
{
  my $base = $<call>    ?? $<call>.made
          !! $<subjacc> ?? $<subjacc>.made
          !! $<pexpr>   ?? $<pexpr>.made
          !!               Name.new(name => ~$<name>);
  make CallStmt.new(
    call => self!spanned(self!trailed($base, $<call> // $<subjacc> // $<pexpr> // $<name>, $<trailer>, $/), $/),
    line => self!line($/),
  );
}

method ifst($/)
{
  make IfStmt.new(
    branches    => branches($<cond>, $<then>),
    otherwise   => $<else> ?? $<else>.made !! (),
    header-decl => $<hdrdecl> ?? $<hdrdecl>.made !! Declarator,
    line        => self!line($/),
  );
}

method docasest($/)
{
  my ($decl, $assign);
  with $<subject>
  {
    if .<subjlocal> { $decl   = .<hdrdecl>.made }
    else            { $assign = .<assignment>.made }
  }
  make CaseStmt.new(
    branches       => branches($<cond>, $<then>),
    otherwise      => $<else> ?? $<else>.made !! (),
    subject-decl   => $decl   // Declarator,
    subject-assign => $assign // Assignment,
    line           => self!line($/),
  );
}

method whilest($/)
{
  make WhileStmt.new(
    cond        => $<cond>.made,
    body        => $<block>.made,
    header-decl => $<hdrdecl> ?? $<hdrdecl>.made !! Declarator,
    line        => self!line($/),
  );
}

method forst($/)
{
  make ForStmt.new(
    var       => ~$<var>,
    var-local => ?$<varlocal>,
    from      => $<from>.made,
    to        => $<to>.made,
    step      => $<step> ?? $<step>.made !! Expr,
    body      => $<block>.made,
    line      => self!line($/),
  );
}

method forinst($/)
{
  my $node = ForInStmt.new(
    elem   => ~$<elem>,
    index  => $<idx> ?? ~$<idx> !! Str,
    source => $<source>.made,
    body   => $<block>.made,
    line   => self!line($/),
  );
  with $<endname> -> $e
  {
    $node.endname-from = self!from($e);
    $node.endname-to   = self!to($e);
  }
  make $node;
}

method fortimesst($/)
{
  make ForTimesStmt.new(
    count => $<count>.made,
    body  => $<block>.made,
    line  => self!line($/),
  );
}

method withst($/)
{
  make WithObject.new(
    subject => $<subject>.made,
    body    => $<block>.made,
    line    => self!line($/),
  );
}

method withbody($/) { make $<statement>.map(*.made).list }

# ':x' / ':m(...)': the subject of the innermost 'with object' as the base.
method subjacc($/)
{
  my $base = SubjectRef.new;
  make $<arglist>
    ?? MethodCall.new(base => $base, name => ~$<member>, args => $<arglist>.made.list)
    !! Member.new(base => $base, name => ~$<member>);
}

method rawst($/)
{
  # The block has a list of lines; the one-line form has a single match, and
  # '.map' over a single match would walk its (empty) positional captures.
  my @lines = $<rawblock> ?? $<rawblock><rawline>.map(*.Str)
                          !! (~$<rawone><rawline>,);
  make RawStmt.new(
    block => ?$<rawblock>,
    lines => @lines,
    line  => self!line($/),
  );
}

method usingst($/)
{
  make UsingAlias.new(
    area  => ~$<area>,
    order => $<order> ?? $<order>.made !! Expr,
    body  => $<block>.made,
    line  => self!line($/),
  );
}

method seqst($/)
{
  make SequenceStmt.new(
    body        => $<block>.made,
    has-recover => ?$<recover>,
    error-var   => $<errvar> ?? ~$<errvar> !! Str,
    recover     => $<recover> ?? $<recover>.made !! (),
    line        => self!line($/),
  );
}

# ---- declarations ---------------------------------------------------------------
method declaration($/)
{
  make Declaration.new(
    scope       => ~$<declkind>.lc.trim,
    declarators => $<declarator>.map(*.made).list,
    line        => self!line($/),
  );
}

method !make-declarator($/)
{
  Declarator.new(
    type-first    => ?($<typespec> && $<expr> && $<typespec>.from < $<expr>.from),
    typespec-text => $<typespec> ?? (~$<typespec>).trim !! Str,
    name       => ~$<name>,
    attributes => $<attrs> ?? (~$<attrs>).comb(/\w+/).map(*.lc).list !! (),
    init       => $<expr> ?? $<expr>.made !! Expr,
    declared   => $<typespec> ?? type-of-name(~$<typespec><typename>) !! UNKNOWN,
    line       => self!line($/),
  )
}

method declarator($/) { make self!make-declarator($/) }
method hdrdecl($/)    { make self!make-declarator($/) }

# ---- expressions: down the precedence -------------------------------------------
#
# Each level with a single child passes the child on. An 'orexpr' that is just
# an 'andexpr' is not an 'or' of anything, and must not become an 'or' node.
method expr($/)
{
  # The source gets its own span first: the emitter renders it on its own,
  # and a folded operator ('a + b') has no span otherwise.
  make self!spanned(pipeline(self!spanned($<elvis>.made, $<elvis>), $<feed>), $/);
}

# 'a ?: b ?: c' chains to the right: a ?: (b ?: c).
method elvis($/)
{
  my @p = $<orexpr>.map(*.made);
  my $acc = @p.pop;
  $acc = joined(Binary.new(op => '?:', left => $_, right => $acc)) for @p.reverse;
  make $acc;
}

# Without 'fallback' it is just the expression; most have none, and must not
# gain a node.
method guardexpr($/)
{
  make self!spanned($<fallback>
    ?? Guard.new(expr => $<guarded>.made, fallback => $<fallback>.made)
    !! $<guarded>.made, $/);
}

method stage($/)
{
  make $<nscall> ?? $<nscall>.made
    !! $<call>   ?? $<call>.made
    !!              Call.new(name => ~$<name>, args => ());
}

# A pipeline as a statement, for its effects. It sits in a CallStmt like any
# expression that becomes a statement.
method pipest($/)
{
  make CallStmt.new(
    call => self!spanned(pipeline(self!spanned($<elvis>.made, $<elvis>), $<feed>), $/),
    line => self!line($/),
  );
}

method orexpr($/)  { make fold-ops($/, 'andexpr', 'orop') }
method andexpr($/) { make fold-ops($/, 'notexpr', 'andop') }

method notexpr($/)
{
  make $<negate> ?? self!spanned(Binary.new(op => '!', left => Expr, right => $<cmpexpr>.made), $/)
                 !! $<cmpexpr>.made;
}

method cmpexpr($/)
{
  my $acc = $<rangeexpr>.made;
  for $<cmptail>.list -> $t
  {
    $acc = joined(Binary.new(op => (~$t<op>).lc, left => $acc, right => $t<rhs>.made));
  }
  make $acc;
}

method rangeexpr($/) { make interval($<lo>.made, $<hi>) }
method inrhs($/)     { make interval($<lo>.made, $<hi>) }
method addexpr($/)   { make fold-ops($/, 'mulexpr', 'addop') }
method mulexpr($/)   { make fold-ops($/, 'unary',   'mulop') }

method unary($/)
{
  make $<sign> && ~$<sign> eq '-'
    ?? self!spanned(Binary.new(op => 'neg', left => Expr, right => $<postfix>.made), $/)
    !! $<postfix>.made;
}

# A primary and its trailers, from the inside out: 'o:x(1)[2]' is the Index
# of a MethodCall on a Name.
method postfix($/)
{
  make self!spanned($<literal> ?? $<literal>.made !! self!trailed($<primary>.made, $<primary>, $<trailer>, $/), $/);
}

# Each trailer makes a function that takes what is to its left.
method trailer($/) { make $/.hash.values[0].made }

method tmethod($/)
{
  my $name = ~$<member>;
  my @args = $<arglist>.made.list;
  make -> $base { MethodCall.new(base => $base, name => $name, args => @args) }
}

method thash($/)
{
  my $key = $<key>.made;
  make -> $base { HashIndex.new(base => $base, key => $key) }
}

method tsafe($/)
{
  my $name = ~$<member>;
  with $<arglist> -> $args
  {
    my @args = $args.made.list;
    make -> $base { SafeCall.new(base => $base, name => $name, args => @args) };
  }
  else
  {
    make -> $base { SafeMember.new(base => $base, name => $name) };
  }
}

method tmember($/)
{
  my $name = ~$<member>;
  make -> $base { Member.new(base => $base, name => $name) }
}

method tindex($/)
{
  my @i = $<expr>.map(*.made);
  make -> $base { Index.new(base => $base, indices => @i) }
}

method tinalias($/)
{
  my $e = $<expr>.made;
  make -> $base { InAlias.new(base => $base, expr => $e) }
}

method tfield($/)
{
  my $name = ~$<member>;
  make -> $base { AliasField.new(base => $base, field => $name) }
}

# No fallback that returns text: a new kind of primary without a node has to
# show up here, not become a silent string.
method primary($/)
{
  make   $<selfacc>      ?? $<selfacc>.made
      !! $<subjacc>      ?? $<subjacc>.made
      !! $<literal>      ?? $<literal>.made
      !! $<nscall>       ?? $<nscall>.made
      !! $<call>         ?? $<call>.made
      !! $<name>         ?? Name.new(name => ~$<name>)
      !! $<expr>         ?? $<expr>.made
      !! $<macro>        ?? $<macro>.made
      !! $<aliasfield>   ?? $<aliasfield>.made
      !! $<jsonliteral>  ?? $<jsonliteral>.made
      !! $<hashliteral>  ?? $<hashliteral>.made
      !! $<arrayliteral> ?? $<arrayliteral>.made
      !! $<codeblock>    ?? $<codeblock>.made
      !! $<lambda>       ?? $<lambda>.made
      !! die "primary with no node: {(~$/).trim}";
}

method macro($/)
{
  make Macro.new(target => $<expr> ?? $<expr>.made !! Name.new(name => ~$<name>));
}

method aliasfield($/)
{
  make $<expr>
    ?? InAlias.new(alias => ~$<alias>, expr => $<expr>.made)
    !! AliasField.new(alias => ~$<alias>, field => ~$<field>);
}

method jsonliteral($/)
{
  make JsonLit.new(type => 'JSON', text => (~$/).trim,
                   pairs => $<pair>.map(*.made).list);
}

method hashliteral($/)
{
  make HashLit.new(type => 'Object', text => (~$/).trim,
                   pairs => $<hashpair>.map(*.made).list);
}

method pair($/)     { make KeyValue.new(key => $<expr>[0].made, value => $<expr>[1].made) }
method hashpair($/) { make KeyValue.new(key => $<expr>[0].made, value => $<expr>[1].made) }

method arrayliteral($/)
{
  make ArrayLit.new(type => 'Array', text => (~$/).trim,
                    items => $<expr>.map(*.made).list);
}

method lambda($/)
{
  make Lambda.new(type => 'Block', text => (~$/).trim,
                  params => $<lparam>.map(~*).list,
                  body   => ($<lbody>.made,));
}

method codeblock($/)
{
  make CodeBlock.new(type => 'Block', text => (~$/).trim,
                     params => $<name>.map(~*).list,
                     body   => $<blockexpr>.map(*.made).list);
}

# In a block and in an argument, an assignment is an expression.
method blockexpr($/)
{
  make self!spanned($<assignment> ?? assign-expr($<assignment>.made) !! $<expr>.made, $/);
}

method call($/)
{
  make self!spanned(Call.new(name => ~$<name>, args => $<arglist>.made.list), $/);
}

# The whole path is the name; the dots stay in it, and no segment is a variable
# read (they are namespace parts), so walk-expr does not go into them.
method nscall($/)
{
  make self!spanned(Call.new(name => ~$<qname>, args => $<arglist>.made.list), $/);
}

# 'f()' has a single empty position and no arguments; 'f( , 1)' has two, and
# the first is Omitted.
method arglist($/)
{
  my @s = $<slot>.map({ .<arg> ?? .<arg>.made !! Omitted.new });
  make (@s == 1 && @s[0] ~~ Omitted) ?? () !! @s.List;
}

method arg($/)
{
  make self!spanned(
         $<byref>      ?? Ref.new(target => Name.new(name => ~$<byref><name>))
      !! $<assignment> ?? assign-expr($<assignment>.made)
      !!                  $<expr>.made, $/);
}

method literal($/)
{
  return make $<string>.made if $<string>;
  make Literal.new(
    type =>   $<number>  ?? 'Numeric'
           !! $<string>  ?? 'Character'
           !! $<logical> ?? 'Logical'
           !! $<nildef>  ?? 'Variant'
           !!               UNKNOWN,
    text => ~$/,
  );
}

# A string: a plain Literal, or an Interp when it holds a '${ }'.
method string($/)
{
  my $s = $<dqstring> // $<sqstring>;
  my @parts = $s<spart>.map({ .<interp> ?? .<interp><expr>.made !! ~.<text> });
  make @parts.grep(Expr)
    ?? Interp.new(type => 'Character', text => ~$/, parts => @parts)
    !! Literal.new(type => 'Character', text => ~$/);
}

# ---- helpers --------------------------------------------------------------------


# The trailers, in order, over a base.
# The base with its trailers applied, each step spanning from the start of the
# whole ($whole) to the end of its trailer: the emitter may rewrite any of
# them ('o:hCfg' in 'o:hCfg{"k"} := 1'). The base gets its own match's span
# when it has none.
method !trailed(Expr $base, $base-match, $trailers, $whole --> Expr)
{
  self!spanned($base, $base-match) if $base.src-from < 0 && $base-match.defined;
  my $from = self!from($whole);
  my $e = $base;
  for $trailers.list -> $t
  {
    $e = $t.made()($e);
    $e.src-from = $from;
    $e.src-to   = self!to($t);
  }
  $e
}

# The source, and the stages if any. With none, it is just the source -- most
# expressions have no '|>' and must not gain a node.
sub pipeline(Expr $source, $feeds)
{
  my @stages = $feeds.list.map(*<stage>.made);
  @stages ?? Pipeline.new(source => $source, stages => @stages) !! $source
}

# 'lo..hi' when there is a '..', otherwise just 'lo'.
sub interval(Expr $lo, $hi)
{
  $hi ?? Interval.new(lo => $lo, hi => $hi.made) !! $lo
}

sub assign-expr(Assignment $a)
{
  AssignExpr.new(target => $a.target, op => $a.op, value => $a.value)
}

# Conditions and bodies come back as two lists of the same length; a branch
# is one of each.
sub branches($conds, $bodies)
{
  my @c = $conds.list;
  my @b = $bodies.list;
  (^@c).map({ Branch.new(cond => @c[$_].made, body => @b[$_].made) }).list
}

# 'a + b - c', with the operator of each round.
sub fold-ops($/, Str $child, Str $opname)
{
  my @parts = $/{$child}.map(*.made);
  return @parts[0] if @parts == 1;
  my @ops = $/{$opname}.map({ (~$_).lc });
  my $acc = @parts.shift;
  for @parts.kv -> $i, $r
  {
    $acc = joined(Binary.new(op => @ops[$i], left => $acc, right => $r));
  }
  $acc
}
