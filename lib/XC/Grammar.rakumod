# XC::Grammar -- the grammar of xtpl: TL++ plus xtpl's extensions.
#
# Every valid TL++ file must match; the extensions are what the compiler
# lowers to plain TL++. AdvPL in general is not a target: a grammar that
# accepted everything AdvPL does could refuse nothing, which is how one ends
# up back at regular expressions.
#
# ORDERED ALTERNATION EVERYWHERE
#
# This file uses '||' and never '|'. Two reasons, and both count.
#
# The first is design: in a language grammar the order of the alternatives IS
# the specification. 'declaration || assignment' says a line that could be
# either is a declaration. Raku's '|' picks the longest match, which is a rule
# about the text, not about the language.
#
# The second is that, in a 'rule', rakupp 4.0.1's '|' refuses an alternative
# holding a quantified subrule with a separator, which Rakudo accepts:
#
#     rule  call { <name> "(" <expr>* % "," ")" }
#     rule  asg  { <name> ":=" \d+ }
#     rule  alt  { <call> | <asg> }       # 'f("a")': Rakudo matches, rakupp not
#     rule  alt2 { <call> || <asg> }      # both match
#
# (With 'token', both refuse the '|' -- that is Raku, not rakupp.) Since '||'
# is what is wanted anyway, this is no concession.

unit grammar XC::Grammar;

# ---- looking ahead, cheaply --------------------------------------------------
#
# Several rules try an assignment first and fall back: a statement, an
# argument, a lambda's body. The left side of an assignment is a whole
# expression -- 'check(a, b, c)' is parsed in full before the missing ':='
# says no -- and then again as what it is; a statement also tries '?=' and
# '|>'. Under rakupp 4.0.1 each attempt runs its actions and leaves its nodes
# behind (the '||' capture leak), so a call statement's arguments were built
# four or five times over, and nested calls multiplied it.
#
# ahead() reads the text instead: from where the alternative starts to where
# the statement -- or the argument -- ends, outside brackets, strings and
# comments, is there an assignment operator ('assign') or a '|>' ('pipe')?
# If not, the alternative cannot match and is not tried. It only ever skips
# what would fail: when it cannot tell -- a bracket closed that it did not see
# open, or no text to read -- it says yes, and the parse goes as before.

# The text, in the units match offsets count: UTF-8 bytes under rakupp,
# characters under Rakudo. Only ASCII punctuation is looked for, and UTF-8
# never uses an ASCII byte inside a longer character.
my grammar OffsetProbe
{
  token TOP { . <x> }
  token x   { '!' }
}
my $offsets-in-bytes = OffsetProbe.parse('é!')<x>.from == 2;

sub text-units(Str $t)
{
  # Rakudo counts graphemes, and "\r\n" is one: one unit each, the line end
  # as a "\n" -- not .ords, which gives it two and shifts every later offset.
  $offsets-in-bytes ?? $t.encode.list.Array !! $t.comb.map({ $_ eq "\r\n" ?? 10 !! .ord }).Array
}

# Whether the text at $from, past spaces, is the word 'private', 'public' or
# 'static' -- a declaration that may come after a statement. ('static
# function' is not one: 'function' is reserved, and the declaration fails.)
sub decl-ahead(Int $from --> Bool)
{
  my $u = $*UNITS // return False;
  my $i = $from;
  $i++ while $i < $u.elems && ($u[$i] == 32 || $u[$i] == 9);
  for 'private', 'public', 'static' -> $word
  {
    my $n = $word.chars;
    next unless $i + $n <= $u.elems;
    next unless (^$n).map({ $u[$i + $_] +| 0x20 }) eqv $word.ords.map(* +| 0x20);
    my $after = $i + $n < $u.elems ?? $u[$i + $n] !! 0;
    # Not part of a longer word: 'privateX' is a name.
    return True unless 48 <= $after <= 57 || 65 <= $after <= 90 || 97 <= $after <= 122 || $after == 95;
  }
  False
}

# $item: an argument or a lambda's body, which also ends at a ',' or at a
# bracket closing what it is in.
sub ahead(Int $from, Str $what, Bool :$item = False --> Bool)
{
  my $u = $*UNITS // return True;
  my $n = $u.elems;
  my $depth = 0;
  my $last = 0;                              # the last code character: ';' continues the line
  my $i = $from;
  while $i < $n
  {
    my $c = $u[$i];
    my $next = $i + 1 < $n ?? $u[$i + 1] !! 0;
    if $c == 34 || ($c == 39 && !($i > 0 && 48 <= $u[$i - 1] <= 57 && 48 <= $next <= 57))
    {
      # A string, to its closing quote or the end of the line. (A "'" between
      # two digits groups them: '12'345'.)
      $i++;
      $i++ while $i < $n && $u[$i] != $c && $u[$i] != 10;
      $last = $c;
      $i++;
      next;
    }
    if $c == 47 && $next == 47
    {
      $i++ while $i < $n && $u[$i] != 10;    # '//' to the end of the line
      next;
    }
    if $c == 47 && $next == 42
    {
      $i += 2;                               # '/* ... */'
      $i++ while $i + 1 < $n && !($u[$i] == 42 && $u[$i + 1] == 47);
      $i += 2;
      next;
    }
    if $c == 10
    {
      return False unless $last == 59;       # the end of the line: of the statement, unless ';' goes on
      $last = 0;
      $i++;
      next;
    }
    if $c == 40 || $c == 91 || $c == 123     # ( [ {
    {
      $depth++;
    }
    elsif $c == 41 || $c == 93 || $c == 125  # ) ] }
    {
      return !$item if --$depth < 0;         # an item ends here; a statement cannot tell
    }
    elsif $depth == 0
    {
      return False if $item && $c == 44;     # ',' ends an item
      if $what eq 'assign' || $what eq 'bind'
      {
        # ':=', '+=', '-=', '*=', '/=', '?=', or '=' on its own -- not '==',
        # '<=', '>=', '!='. 'bind': not '=' on its own, which in an
        # expression compares.
        return True if $next == 61 && ($c == 58 || $c == 43 || $c == 45 || $c == 42 || $c == 47 || $c == 63);
        if $c == 61 && $what eq 'assign'
        {
          if $next == 61 { $i += 2; $last = 61; next }
          my $prev = $i > 0 ?? $u[$i - 1] !! 0;
          return True unless $prev == 60 || $prev == 62 || $prev == 33;
        }
      }
      elsif $c == 124 && $next == 62         # '|>'
      {
        return True;
      }
    }
    $last = $c unless $c == 32 || $c == 9 || $c == 13;
    $i++;
  }
  False
}

# The text for ahead(), in the units of the match offsets.
method parse($target, |c)
{
  my $*UNITS = text-units($target);
  callsame;
}

# ---- names that cannot be declared ------------------------------------------
#
# The same rules as xtpl, checked against it case by case:
#
# Reserved words -- xtpl's list, which includes a few native functions. They
# apply to local, private, parameters, header declarations and 'for local';
# not to lambda parameters, which xtpl accepts.
my constant RESERVED = set <
  function static user return if else elseif endif for next while enddo do
  local private public with without orwith given when otherwise end
  conout len eval array aadd substr userexception
>;

# 'our': under rakupp 4.0.1 a lexical 'sub' in this file is not visible from
# inside a '<!{ }>' (under Rakudo it is).
our sub is-reserved(Str $n --> Bool) { RESERVED{$n.lc}:exists }

# The shape of a name xtpl generates: a leading '__', a short temporary
# '<kind>_<depth>_<index>', or a slot 's_'/'b_'. Only a function-level
# 'local'/'private' refuses it -- the only declaration emitted with the name
# as written. xc's own output declares such names, so reading it back
# (checking that it compiles to itself) sets '$*GENERATED-OK'.
our sub is-generated(Str $n --> Bool)
{
  so ($n.starts-with('__')
      || $n ~~ m:i/ ^ [ f [ a | al | ar | bg | bs | ch | dr | fs | hd | hi | i | j | ky | ls
                         | lm | lo | n | ok | ol | op | o | pv | pb | rd | rc | sn | sp | s | v ]
                       | et | gt | ht | pt ] '_' \d+ '_' \d+ $ /
      || $n ~~ m:i/ ^ <[sb]> '_' \d+ '_' \w+ $ /)
}

# ONE STATEMENT PER LINE
#
# In AdvPL a line break ends the statement, unless the line ends in ';'. Here
# it used to be plain whitespace, which let a statement run on into the next
# line:
#
#     return                    the return's value became 'endif', and the
#   endif                       whole file stopped matching
#
#     return                    the value became 'user', and the next function
#                               turned into a 'function g()' without 'user'
#   user function g()           -- silently
#
# So '<.ws>' does not cross lines, and every place a line may end says so with
# '<.nl>'. Blank and comment-only lines live inside '<.nl>'; they are not
# statements.
# <.mark> after each toplevel item: how far the parse got, so that a file
# that fails before its first function is reported at the line that failed,
# not at line 1.
rule TOP
{
  ^ <.gap> <.mark> [ <toplevel> <.gap> <.mark> ]* $
}

# The function first: it starts with its annotations, and only when what
# follows is not a function does an annotation stand alone.
rule toplevel
{
     <function>
  || <classdecl>
  || <interfacedecl>
  || <methodimpl>
  || <wsmethodimpl>
  || [ [ <preproc> || <namespacest> || <externalst> || <filestatic> || <wsblock> || <cmdst> || <annotation> ] <.eol> ]
}

# ---- what the preprocessor takes whole ------------------------------------
# A directive goes whole to the TL++ preprocessor -- '#include', '#define',
# '#command', '#xtranslate'. Nothing here looks inside: the body of a
# '#command' is a language of its own, and not ours.
#
# But it can CONTINUE: a line ending in ';' carries on to the next, and an
# '#xtranslate' with a body usually spans three or four.
token preproc
{
  # The '\N*?' is frugal on purpose: the greedy one eats its own ';' and then
  # has nothing left to match.
  '#' [ \N*? ';' \h* \n ]* \N*
}

# ---- TL++: namespace -------------------------------------------------------
rule namespacest
{
  :i [ 'using' 'namespace' || 'namespace' ] <dottedname>
}

token dottedname { <[A..Za..z_]> \w* [ '.' <[A..Za..z_]> \w* ]* }

# ---- xtpl: 'external' --------------------------------------------------------
#
#     external CRLF, dDataBase         names that exist but xtpl cannot see
#     external alias SA1, SB1          work areas the caller opens
#
# A promise, not a declaration: it emits nothing. File level, beside the
# includes, and at least one name -- what xtpl's doc says and all of its
# corpus does. xtpl itself is laxer: it also takes 'external' inside a
# function, and with no names at all (where it does nothing). xc follows the
# doc.
# No name may be the word 'alias': 'external alias' with nothing after it
# would otherwise declare one called that. The name refuses it itself, by a
# lookahead -- not a '<!{ }>' over the names after them: in a code assertion
# rakupp (5.3.0 too) sees a repeated capture as its last match alone, so an
# 'alias' first went through. Under 5.2.1 it was refused all the same, but
# only because '[ <isalias=kwalias> ]?' kept the word and never gave it back.
rule externalst { :i 'external' [ <isalias=kwalias> ]? <xname> [ ',' <xname> ]* }
token kwalias   { :i 'alias' >> }
token xname     { <!before <.kwalias>> <name> }

# ---- TL++: annotations -----------------------------------------------------
#
# A line starting with '@'. It may or may not take arguments in parentheses,
# and it comes before what it annotates.
rule annotation
{
  '@' <name> [ '(' ~ ')' <arglist> ]?
}

# ---- functions -------------------------------------------------------------
rule function
{
  [ <annotation> <.nl> ]*
  <funckind> <name> [ '(' ~ ')' <params> ]? <rettype>? <.nl>
  <funcbody>
}

# A bare 'function' is accepted on purpose. AdvPL refuses it ("Regular
# functions are not allowed in code"), but TL++ accepts it when the name
# starts with 'u_' -- and maybe other prefixes, not yet surveyed. Refusing it
# here would refuse valid TL++.
token funckind { :i [ [ 'user' || 'static' || 'main' ] \s+ ]? 'function' }

# 'User Function X' needs no parentheses in AdvPL; and TL++ may say what it
# returns: 'Static Function Scheddef() as array'.
token rettype { <typespec> }

# ---- web services: REST and SOAP -------------------------------------------
# AdvPL's web services come from include files (restful.ch, apwebsrv.ch) that
# xc cannot read. The declaration -- 'WSRESTFUL Name ... END WSRESTFUL', its
# WSDATA and WSMETHOD lines; 'WSSERVICE', 'WSSTRUCT', 'WSCLIENT' alike -- is
# taken whole, at file level, and goes out as it came. Each method's
# implementation is a function: the header, through its continuation lines,
# as written, ending in 'WSSERVICE Name' or 'WSRESTFUL Name'; the body like
# any other, with 'self' and '::' for the service:
#
#   WSMETHOD GET PedVendaLb WSRECEIVE QUERYPARAM, Page WSSERVICE dsapirest
#
# ('WSREST Name' ends a header as well: real sources write it so.)
#     Local lRet := .T.
#     ::SetContentType("application/json")
#   Return lRet
token wsblock
{
  :i [ 'wsrestful' || 'wsservice' || 'wsstruct' || 'wsclient' ] <!ww> \N* \v
  [ <!before \h* <.wsend> > \N* \v ]*
  \h* <.wsend> \N*
}
token wsend { :i 'end' \h* [ 'wsrestful' || 'wsservice' || 'wsstruct' || 'wsclient' ] <!ww> }

rule wsmethodimpl
{
  <wshead> <.nl>
  <funcbody>
}
token wshead
{
  :i 'wsmethod' <!ww> [ \N*? ';' \h* \v ]* \N*? <!ww> [ 'wsservice' || 'wsrestful' || 'wsrest' ] \h+ <svc=name>
  <?before \h* [ <.linecomment> || \v || $ ]>
}

# ---- TL++: classes ---------------------------------------------------------
# Native to TL++, not an xtpl extension. Two parts: the 'Class ... EndClass'
# block with its 'Data' members and 'Method' signatures, and the
# implementations 'Method name(...) Class Name' loose in the file, each with
# its own body.
# A superclass may be named with its namespace -- 'from
# totvs.framework.treports.integratedprovider.IntegratedProvider' -- and a
# class may implement interfaces: 'class cX Implements iX'.
rule classdecl
{
  :i 'class' <cname=name> [ :i [ 'from' || 'inherit' ] <supers=dottedname>+ % ',' ]?
     [ :i 'implements' <ifaces=dottedname>+ % ',' ]? <.nl>
  [ <classmember> <.nl> ]*
  :i [ 'endclass' || 'end' 'class' ]
}

# TL++'s interface: method signatures, as in a class, and nothing else.
rule interfacedecl
{
  :i 'interface' <cname=name> <.nl>
  [ <classmember> <.nl> ]*
  :i [ 'endinterface' || 'end' 'interface' ]
}

# '@Get("/x")' before a method: the annotation goes with it, as written.
rule classmember
{
  [ <annotation> <.nl> ]*
  [ <datadecl> || <methdecl> ]
}

rule visib { :i [ 'public' || 'protected' || 'private' || 'exported' || 'hidden' ] }

# 'Data name [as type]', one or more per line. The type here is any name (a
# class included), not the closed list of 'as' in declarations.
rule datadecl { <visib>? :i 'data' <datavar>+ % ',' }
rule datavar  { <dname=name> [ :i 'as' <dtype=name> ]? [ :i [ 'default' || 'init' ] <datadefault> ]? }
# 'Data cId as character default ""': its value when an object is made.
# AdvPL's classes say 'init': 'DATA aTrack AS ARRAY INIT {}'.
token datadefault { <guardexpr> }

# The signature: 'Constructor' and the return type are optional and come in
# any order.
# 'Static Method', with or without a visibility, in either order: a method of
# the class, not of an object.
# TL++'s operators are declared and written as methods: 'Public Operator
# Add()', 'Operator Add(xParam1) Class DateTime' -- Add, Sub, Mult, Div,
# Compare, ToString.
rule methdecl { [ <visib> || <mstatic> ]* :i [ 'method' || 'operator' ] <mname=name> [ '(' ~ ')' <params> ]? <methtag>* }
token mstatic { :i 'static' >> }
rule methtag  { :i 'constructor' || [ :i 'as' <ret=name> ] }

# The implementation, at file level. The 'as type' before 'class Name', or
# after it: 'method getData() class MySVLookup as logical'.
rule methodimpl
{
  [ <annotation> <.nl> ]*
  :i [ 'method' || 'operator' ] <mname=name> '(' ~ ')' <params>
     [ :i 'as' <ret=name> ]?
     :i 'class' <cname=name>
     [ :i 'as' <retafter=name> ]? <.nl>
  <funcbody>
}

rule params
{
  <param>? [ ',' <param>? ]*
}

# A parameter can be typed too: 'f(nX as Numeric)'.
# '<const>' and '<contained>' as on a local: a parameter not assigned, one
# that does not leave the function.
rule param
{
  <name> <!{ is-reserved(~$<name>) }> <attrs>? <typespec>?
}

# 'return' is a STATEMENT, not just the end of the function. An early return
# inside an 'if' is common, and if the final 'return' were part of the
# function rule, the body would swallow the inner ones and leave nothing to
# close it.
# The value is optional, and an 'if'/'while' right after 'return' starts a
# modifier, not the value: 'return if lSkip' returns nothing. Without the
# '<!modkw>' the 'if' became a name and the line stopped matching.
# 'Return()': nothing, in parentheses.
rule returnst
{
  :i 'return' [ [ '(' ')' ] || [ <!modkw> <guardexpr> ] ]?
}

rule exitst { :i 'exit' }
rule loopst { :i 'loop' }

# Each statement ends its line. The body stops at the first one that does not
# match -- 'endif', 'next', the next 'function' -- and the caller decides what
# it is.
#
# THE PROLOGUE
#
# Declarations come before the first statement of the body -- what AdvPL
# requires of 'local', and what xtpl extends to blocks. A block has ONE
# prologue, at the start of its first body: that of 'if', 'while', 'for'.
# 'elseif' and 'else' are statements of the same block, so their bodies start
# closed; so does 'case', and 'begin sequence' is not even a scope for xtpl.
# Checked against xtpl itself, case by case.
#
# Three bodies, differing only in what they open:
#
#     funcbody      prologue open, at function level
#     body          prologue open, inside a block
#     closedbody    prologue already closed: no declarations
#
# '$*PAST-PROLOGUE' says whether the prologue has closed; 'statement' sets it
# after every statement that is not a declaration. '$*TOP-LEVEL' says whether
# declarations here are emitted with the name as written -- block locals
# become slots, and only function-level ones can collide with a generated
# name.
rule funcbody   { :my $*PAST-PROLOGUE = False; :my $*TOP-LEVEL = True;  [ <statement> <.nl> ]* }
rule body       { :my $*PAST-PROLOGUE = False; :my $*TOP-LEVEL = False; [ <statement> <.nl> ]* }
rule closedbody { :my $*PAST-PROLOGUE = True;  :my $*TOP-LEVEL = False; [ <statement> <.nl> ]* }

# ---- types ------------------------------------------------------------------
#
# The type can be declared or come from the initializer:
#
#     local aList := {}              implicit
#     local aList as Array           explicit
#     local aList := {} as Array     both, and they must agree
#
# The names abbreviate to their first letter: 'as A' and 'as Array'.
rule typespec
{
  :i 'as' <typename>
}

token typename
{
  # 'variadic': TL++'s parameter that takes every argument there is --
  # 'parm As Variadic', read as 'parm:vCount' and 'parm:vArgs[i]'.
  :i [
       'integer' || 'decimal' || 'codeblock' || 'variadic' >>
    || 'array'     || 'a' >>
    || 'numeric'   || 'n' >>
    || 'character' || 'c' >>
    || 'logical'   || 'l' >>
    || 'date'      || 'd' >>
    || 'object'    || 'o' >>
    || 'block'     || 'b' >>
    || 'json'      || 'j' >>
    || 'variant'   || 'u' >>
  ]
}

# ---- statements --------------------------------------------------------------
# Block statements and declarations take no modifier; simple ones take one,
# optionally, at the end of the line: 'x := 1 if c', 'return n if c',
# 'exit if c', 'f() while c'. 'exec' is a simple statement that only exists
# with a modifier.
rule statement
{
  [
     <cmdst>
  || <dirst>
  || <annotation>
  || <seqst>
  || <tryst>
  || <transst>
  # A 'private' or 'public' is a statement in TL++, allowed anywhere one is;
  # so is a 'static' -- Protheus takes one after a statement, file-wide. None
  # closes the prologue here: a 'local' after one is then parsed, and the
  # checks can say what is wrong with it.
  || [ <?{ !($*PAST-PROLOGUE // False) || decl-ahead($/.from) }> <declaration> ]
  || <ifcallst>
  || <ifst>
  || <whilest>
  || <forst>
  || <forinst>
  || <fortimesst>
  || <docasest>
  || <execst>
  || <deferst>
  || <usingst>
  || <withst>
  || <rawst>
  || [ <simple> <modifier>? ]
  ]
  # Any other statement closes the prologue -- a 'Default' too: it is an 'If'
  # once the preprocessor is done with it, and a local after it is an error.
  { try $*PAST-PROLOGUE = True unless $<declaration> }
}

# ---- xtpl: 'defer' ----------------------------------------------------------
#
#     defer closeCursor()
#     defer aLines |> validate() |> save()
#     defer nTotal := nTotal + 1
#
# Registers a statement to run before every exit from the function, in the
# reverse order of registration. The body is an ordinary statement --
# assignment, pipeline or call --, and a 'defer' may sit inside a block. It
# takes no modifier: in 'defer f() if c' there would be no telling whose 'if'
# it is.
# No '>>' after 'defer': in a 'rule', the space before it inserts a <.ws> that
# eats the space, and '>>' would then demand a word end at the start of the
# next word. <.ws> already refuses to split a word, so 'deferred' does not
# match.
rule deferst { :i 'defer' [ [ <?{ ahead($/.from, 'assign') }> <assignment> ]
                          || [ <?{ ahead($/.from, 'pipe') }> <pipest> ] || <callst> ] }

# ---- xtpl: 'using alias' -- a scoped work area ------------------------------
#
#     using alias SA1 order 1 do
#       nTotal := SA1->A1_SALDO
#       return nTotal if nTotal > 100
#     end using
#
# Selects the area, optionally sets an index order, and puts back what it
# found at every way out of the block, an early 'return' included. The name is
# a bare word: the alias itself, or a variable in scope holding one -- which of
# the two is for name resolution to say, not the grammar. The body opens a
# prologue, like 'while'. Only 'end using' closes it: xtpl refuses a bare
# 'end' and 'endusing'.
rule usingst
{
  :i 'using' 'alias' <area=name> [ :i 'order' <order=expr> ]? :i 'do' <.nl>
     <block>
  :i 'end' 'using'
}

# ---- xtpl: 'with object' ----------------------------------------------------
#
#     with object oModel:GetModel("SA1DETAIL")
#       :SetValue("A1_COD", cCod)
#       cName := :GetValue("A1_NOME")
#     end with
#
# The subject is evaluated once; inside the block a ':' where AdvPL could not
# have one -- at the start of an operand or of a statement -- means "the
# subject". A ':' after a name, ')' or ']' stays ordinary member access. Blocks
# nest, and the innermost subject wins. The body opens a prologue.
#
# Only 'end with' closes it, and ':x' outside a block is refused: xtpl takes a
# bare 'end' and a stray ':x' and emits them as they are, which is not AdvPL.
# 'with' without 'object' is one of xtpl's removed constructs.
rule withst
{
  :i 'with' 'object' <subject=expr> <.nl>
     <withblock>
  :i 'end' 'with'
}

# A body like 'body', with the subject in reach. A rule of its own so the
# subject expression itself still sees only the enclosing block's subject.
rule withbody
{
  :my $*IN-WITH = True; :my $*PAST-PROLOGUE = False; :my $*TOP-LEVEL = False;
  [ <statement> <.nl> ]*
}

# ':member' or ':method(...)' on the subject of the enclosing 'with object'.
rule subjacc { <?{ $*IN-WITH // False }> ':' <member> [ '(' ~ ')' <arglist> ]? }

# ---- xtpl: 'raw' -- a line for the preprocessor ------------------------------
#
#     raw @ 10, 5 SAY "Total" GET nTotal PICTURE "@E 999,999.99"
#
#     raw
#       @ 12, 5 SAY "Name" GET cName PICTURE "@!"
#     end raw
#
# Text for a '#command' or '#xtranslate' -- not AdvPL until the preprocessor
# runs, so the grammar does not read it. A raw line carries on over a ';'
# continuation. The lowering still reads inside it: xtpl interpolates the
# strings there and renames declared variables.
#
# 'raw' followed by a space starts a raw line; 'raw(1)' is a call. 'raw := 2'
# is an assignment to a variable named 'raw' -- xtpl would emit ':= 2'.
# Only 'end raw' closes the block: xtpl takes 'endraw' as one more raw line
# and never closes it. Not at file level, where directives already pass
# through whole (xtpl accepts it there).
# ---- the commands of TOTVS' include files --------------------------------------
# '#command' statements, which xc cannot read: their includes are not to be
# had. A statement that starts with one of their words is taken whole, as
# 'raw' text -- through its continuation lines; 'BeginSql' and
# 'BeginContent' to their closing line -- and goes out as it came. The checks
# see the names of variables in it, as in raw text. The words are a list: a
# word that is not on it is still a line xc cannot parse, so a typo in a
# keyword of xc's own is not taken for a command.
#
# Tried before an annotation: a rule does not go back into an alternation, and
# '@ nRow, nCol SAY ...' would be half an annotation.
token cmdst    { <cmdblock> || <cmdone> }
token cmdone   { <.cmdword> <rawline> }
token cmdword
{
  :i [
       [ 'define' || 'activate' || 'redefine' || 'set' || 'menu' || 'publish' || 'replace' ] \h+ <[A..Za..z_]>
    || [ 'add' \h+ 'option' || 'prepare' \h+ 'environment' || 'reset' \h+ 'environment'
       || 'append' \h+ 'blank' || 'count' \h+ 'to' || 'menuitem' || 'endmenu' || 'tcquery'
       # Mail (ap5mail.ch).
       || [ 'connect' || 'disconnect' ] \h+ 'smtp' || 'send' \h+ 'mail' || 'get' \h+ 'mail' \h+ 'error'
       || 'paramtype' || 'throw'
       # The RF terminal's (apvt100.ch).
       || 'vtpause' || 'vtread' || 'vtclear' || 'vtsave' || 'vtrestore' ] <!ww>
    # '@ row, col SAY ...': '@' with a space or a digit after -- an
    # annotation has its name right after the '@'.
    || '@' [ \h+ || <?before \d> ]
  ]
}
# 'BeginSql' ... 'EndSql', 'BeginContent' ... 'EndContent': SQL, CSS, any text.
token cmdblock { <sqlblock> || <contentblock> }
token sqlblock
{
  :i 'beginsql' <!ww> \N* \v
  [ <!before \h* :i 'endsql' <!ww> > \N* \v ]*
  \h* :i 'endsql' <!ww> \N*
}
token contentblock
{
  :i 'begincontent' <!ww> \N* \v
  [ <!before \h* :i 'endcontent' <!ww> > \N* \v ]*
  \h* :i 'endcontent' <!ww> \N*
}

# A directive inside a function -- '#IFDEF TOP', '#ENDIF': as it came.
token dirst    { <preproc> }

token rawst    { <rawblock> || <rawone> }
token rawblock
{
  :i 'raw' \h* <.linecomment>? <.rawnl>
  # '<!ww>', not '>>': under rakupp 4.0.1 any '>>' inside a lookahead makes it
  # give the wrong answer ('»' works too; Rakudo is fine).
  [ <!before \h* :i 'end' \h+ 'raw' <!ww> > <rawline> <.rawnl> ]*
  \h* :i 'end' \h+ 'raw' >>
}
token rawone   { :i 'raw' \h+ <!before [ <assignop> || '?=' ]> <rawline> }
token rawline { [ \N*? ';' \h* \v ]* \N* }
token rawnl   { \r\n || \v }

rule simple
{
     <returnst>
  || <exitst>
  || <loopst>
  || <breakst>
  || <defaultst>
  || [ <?{ ahead($/.from, 'assign') }> [ <assignment> || <nilassign> ] ]
  || [ <?{ ahead($/.from, 'pipe') }> <pipest> ]
  || <incst>
  || <callst>
}

# 'Break' [value]: out to a 'begin sequence''s recover. ('word'>>, no space:
# in a rule a space before '>>' puts the whitespace first, and '>>' then
# looks for a word's end where the next word starts.)
rule breakst { :i 'break'>> <guardexpr>? }

# 'Default x := 1, y := 2' (totvs.ch): each takes its value when it is Nil.
rule defaultst { :i 'default'>> <defpair>+ % ',' }
rule defpair   { <lvalue> ':=' <guardexpr> }

# 'n++', '++n', 'a[i]--': TL++'s increment and decrement, as a statement.
rule incst  { [ <incop> <lvalue> ] || [ <lvalue> <incop> ] }
token incop { '++' || '--' }

# ---- xtpl: '?=' -- assign if Nil ---------------------------------------------
# Only as a statement: 'cCache ?= "empty"'. Never in an expression --
# '(f() ?= {})' is refused, xtpl's doc says to use '?:' --, nor in a
# declaration: 'local x ?= v' could never fail the test, and is refused.
rule nilassign { <!stmtword> <lvalue> '?=' <expr> }

# A pipeline for its effects, with no assignment in front: 'aOrders |>
# validate() |> save()'. Before 'callst', which would match 'validate()' alone
# on a line starting with 'f(x) |> ...' and leave the rest without an owner.
rule pipest { <!stmtword> <elvis> <feed>+ }

# ---- xtpl: postfix modifiers ------------------------------------------------
#
#     lDone := .T. if nTotal > 5          If nTotal > 5 / lDone := .T. / EndIf
#     conout("x") while nTotal < 0        While nTotal < 0 / conout("x") / EndDo
#     exec clearAll() if nTotal == 0      If ... / clearAll() / EndIf
#     return(nTotal) if nX > 100          'return' too, touching the '('
#
# The word only counts on its own: the 'rule' word boundary keeps the 'if' of
# 'iif(' from being read as a modifier. The condition runs to the end of the
# line.
# The word comes through the 'modkw' token: captured as '$<kw>=[...]' inside
# this 'rule', the space that :sigspace adds after it got into the capture
# ("if ").
rule modifier { <kw=modkw> <cond> }
token modkw   { :i [ 'if' || 'while' ] >> }

# 'exec <expr>' marks an expression as a statement. It does not exist without
# a modifier.
rule execst   { :i 'exec' <expr> <modifier> }

token blockcomment { '/*' .*? '*/' }

# A 'Static' of the file, outside every function: 'Static aDados__ as array',
# 'Static cX := "y"'. Every function of the file sees it.
rule filestatic { :i 'static'>> <!before \s+ <.kwfunction> > <declarator>+ % ',' }
token kwfunction { :i 'function' >> }

rule declaration
{
  <declkind> <declarator>+ % ','
}

rule declkind { :i [ 'local' || 'private' || 'public' || 'static' ] }

# 'local' on its own, for the block headers that declare.
token kwlocal { :i 'local' }

# The type, before or after the initializer:
#
#     local nX := 1 as Numeric        TL++
#     local nX as Numeric             TL++, no initializer
#     local nX as Numeric := 1        xtpl -- TL++ refuses it
#
# TL++ only accepts the type after. xtpl accepts both orders and emits TL++'s
# (docs/language.en.md, "TLPP types"). This is xtpl's grammar, so xtpl's order
# is in, and lowering to TL++ swaps the two parts.
#
# The type only once: 'local nX as Numeric := 1 as Numeric' is refused.
#
# And xtpl's attributes, right after the name: 'local aBuf <contained, const>
# := {}'. No expression fits between a name and ':=', so '<' and '>' are not
# comparisons there. '<const>' needs a value -- it can never be given
# another --, and the last line refuses a 'const' without an initializer.
#
# The attributes are captured ONCE, before the alternatives, not in each one:
# under rakupp 4.0.1 a quantified capture ('<x>?') made in a '||' alternative
# that later fails is not discarded -- it is merged into the one that matched,
# and '<contained>' came back four times.
#
# Clipper's dimensions after the name make an array of that size, its
# elements Nil: 'Local aDados[10]', 'Private aTela[0][0], aGets[0]'.
rule declarator
{
  <name>
  <!{ is-reserved(~$<name>) }>
  <!{ ($*TOP-LEVEL // False) && is-generated(~$<name>) && !($*GENERATED-OK // False) }>
  <dims>?
  <attrs>?
  [    [ ':=' [ <chained> || <guardexpr> ] <typespec>? ]
    || [ <typespec> ':=' <guardexpr> ]
    || [ <typespec> ]
    || <?> ]
  <!{ $<attrs> && (~$<attrs>).lc.contains('const') && !$<guardexpr> }>
}

rule dims  { [ '[' ~ ']' <expr> ]+ }
token attrs { '<' \s* <attr>+ % [ \s* ',' \s* ] \s* '>' }
token attr  { :i [ 'const' || 'contained' ] >> }

# The parts have names of their own -- <cond>, <then>, <thenc>, <else>, tokens
# below -- because repeated ones come back as a list, and unnamed the 'else'
# body would be just the last of a list that sometimes has one more.
# 'if local x := f(), <cond>' declares a block local in the header itself, and
# only then the condition. 'local' is a reserved word, so the comma separates
# the declarator from the condition unambiguously: 'f()' stops at the comma,
# and what follows is the condition. Only the opening 'if' declares; 'elseif'
# does not.
# 'If( c, a, b )' as a statement: AdvPL's If(), IIf's twin, not a block.
# Three arguments and nothing after: a block's condition has one. (Three
# slots written out: rakupp does not show a code block what is inside a
# capture -- '$<arglist><slot>' -- so they cannot be counted there.)
rule ifcallst { :i 'if' '(' <slot> ',' <slot> ',' <slot> ')' <?before <.eol> > }

rule ifst
{
  :i 'if' [ :i <hdrlocal=kwlocal> <hdrdecl> ',' ]? <cond> <.nl>
     <then>
  [ :i 'elseif' <cond> <.nl> <thenc> ]*
  [ :i 'else' <.nl> <else> ]?
  # 'End' closes it too, as Clipper's.
  :i [ 'endif' || 'end' [ 'if' ]? ]
}

rule whilest
{
  :i [ 'do' <.ws> ]? 'while' [ :i <hdrlocal=kwlocal> <hdrdecl> ',' ]? <cond> <.nl>
     <block>
  :i [ 'enddo' || 'end' ]
}

# 'for local i := ...' makes 'i' a new local of the loop. Without 'local', 'i'
# is a variable declared before.
rule forst
{
  :i 'for' [ :i <varlocal=kwlocal> ]? <var=name>
     <!{ is-reserved(~$<var>) }> [ ':=' || '=' ] <from=expr>
     :i 'to' <to=expr> [ :i 'step' <step=expr> ]? <.nl>
     <block>
  :i 'next' [ <endname=name> || [ '(' <endname=name> ')' ] ]?
}

# ---- xtpl: 'for x in ...' and 'for n times' ----------------------------------
#
#     for oItem in aItems              for oItem, nPos in aItems
#       nTotal += oItem:nValue           conout(cValToChar(nPos))
#     next                             next
#
#     for 3 times                      for countLines(oDoc) times
#       conout("line")                   nTotal := nTotal + 1
#     next                             next
#
# The element and the index are new block locals of the loop, declared by the
# header without 'local' -- so 'for local x in a' is refused, as xtpl does,
# and so are reserved words. The source is any expression, a pipeline included,
# and the count too. Tried after the classic 'for', which needs ':=' right
# after the name, so 'for n times' and 'for x in a' fall through to these.
#
# Only 'next' closes them. xtpl also takes 'enddo', and would emit 'For ...
# EndDo', which is not AdvPL.
rule forinst
{
  :i 'for' <elem=name> <!{ is-reserved(~$<elem>) }>
     [ ',' <idx=name> <!{ is-reserved(~$<idx>) }> ]?
     :i 'in' [ <srange=forrange> || <source> ] <.nl>
     <block>
  :i 'next' [ <endname=name> || [ '(' <endname=name> ')' ] ]?
}

rule fortimesst
{
  :i 'for' <count=expr> :i 'times' <.nl>
     <block>
  :i 'next'
}

# 'do case with <subject>' evaluates the subject once and names it, instead of
# repeating the expression in every 'case'. With 'local' the subject is a new
# block local; without, it assigns to a variable declared before.
rule docasest
{
  :i 'do' 'case' [ :i 'with' <subject> ]? <.nl>
  [ :i 'case' <cond> <.nl> <thenc> ]+
  [ :i 'otherwise' <.nl> <else> ]?
  :i [ 'endcase' || 'end' [ 'case' ]? ]
}

rule subject
{
     [ :i <subjlocal=kwlocal> <hdrdecl> ]
  || <assignment>
}

# A block header declaration needs an initializer: it is the value it binds
# for the condition or for the 'case's. A bare 'local x' would belong in the
# prologue.
rule hdrdecl { <name> <!{ is-reserved(~$<name>) }> ':=' <expr> <typespec>? }

# BEGIN SEQUENCE ... RECOVER ... END SEQUENCE -- error handling.
rule seqst
{
  :i 'begin' 'sequence' <.nl>
     <seqblock>
  [ :i 'recover' [ :i 'using' <errvar=name> ]? <.nl> <recover> ]?
  :i 'end' [ :i 'sequence' ]?
}

# TL++'s try: the handler, a block that opens no prologue, as 'recover'.
rule tryst
{
  :i 'try' <.nl>
     <seqblock>
  [ :i 'catch' <errvar=name>? <.nl> <recover> ]?
  [ :i 'finally' <.nl> <finblock> ]?
  :i 'endtry'
}

# A transaction (TOTVS' command): its body read and checked, the rest as is.
rule transst
{
  :i 'begin' 'transaction' <.nl>
     <seqblock>
  :i 'end' 'transaction'
}

rule assignment
{
  <!stmtword> <lvalue> <assignop> [ <chained> || <guardexpr> ]
}

# 'a := b := 0': the value an assignment of its own, from the right.
token chained { <?{ ahead($/.from, 'bind') }> <assignment> }

token assignop { ':=' || '+=' || '-=' || '*=' || '/=' || '=' }

token atail { <?before :i 'atail' \h* '('> <call> }

# A real call, not a bare name: either it has parentheses, or at least one
# ':' / '->' / '[' after. It may start with a parenthesised expression, as
# in '(cAlias)->(DbSkip())' -- plain TL++, and how an alias held in a
# variable is reached.
#
# And it cannot START with a word that opens a statement. Without that guard,
# 'return (.t.)' matches as a call to a function named 'return', the body
# swallows the line, and the function ends without the return that closes it.
#
# The guard lives here and in <assignment>, not in <name>: 'If', 'End' and
# 'Next' are function and method names -- 'If(c,a,b)' is the ternary and
# 'oDlg:End()' closes a dialog. Only the start of a statement is reserved.
rule callst
{
  <!stmtword> [ [ <call> <trailer>* ] || [ <name> <trailer>+ ] || [ <subjacc> <trailer>* ]
             || [ <selfacc> <trailer>* ]
             || [ <macrocall> <trailer>* ]
             || [ <nscall> <trailer>* ]
             || [ <macro> ]
             || [ <inalias> ]
             || [ '(' ~ ')' <pexpr> <trailer>* ] ]
}

token stmtword
{
  :i [ 'return' || 'local' || 'private' || 'public' || 'static'
    || 'if' || 'elseif' || 'else' || 'endif'
    || 'while' || 'enddo' || 'for' || 'next' || 'exit' || 'loop'
    || 'do' || 'case' || 'endcase' || 'otherwise'
    || 'begin' || 'recover' || 'end'
    || 'namespace' || 'using'
  ] >>
}

# ---- expressions, by precedence ---------------------------------------------
#
# Each level written as 'a [ op a ]*', not as 'a+ % op'. In a 'rule',
# '<n>+ % <op>' does not match when the input has spaces:
#
#     rule TOP { <n>+ % <op> }          # no match on '1 + 2 - 3', matches '1+2-3'
#     rule TOP { <n> [ <op> <n> ]* }     # matches both
#
# That is Raku, not rakupp: Rakudo 2026.08 does the same.
#
# Without the operator captured, 'a + b' became a sum node with an empty
# operator, and the type checker could not tell it was a sum.
#
# ---- xtpl: '|>' ------------------------------------------------------------
#
#     aCodes := aOrders |> filter([o] o:nValue > 1000) |> map([o] o:cCode)
#     nTotal := len(aNums |> distinct)
#
# The value on the left becomes the FIRST argument of the stage on the right.
# '|>' is the loosest level: the source runs back to the comma, the
# parenthesis or the start of the expression holding it. A stage is a call or
# a bare name ('|> asum' is 'asum(x)').
#
# Not inside a lambda or code block: the body runs later, and lifting a stage
# out of it would run the stage first. The lambda and the code block set
# '$*IN-BLOCK', and with it set no expression inside accepts '|>'.
rule expr        { <elvis> <feed>* }

# ---- xtpl: 'fallback' --------------------------------------------------------
#
#     cReply := callService(cUrl) fallback ""
#     n := aNums |> filter([x] x > 1) |> asum fallback 0
#     aL := (risky(2) fallback {}) |> map([x] x * 2)
#
# Guards an expression: if it raises an error, the alternative is the value.
# xtpl strips 'fallback' off the tail of the line, so it is not an operator
# that fits anywhere: only in the value of an assignment, a declaration or a
# 'return', and inside parentheses -- parentheses are how to guard just a
# piece. Looser than '|>': it guards the whole pipeline. Not inside a lambda
# or code block, like '|>'.
#
# Both parts are named: an <expr> and an <alt=expr> at the same level would
# come back together as a list in $<expr>.
rule guardexpr { <guarded> [ <!{ $*IN-BLOCK // False }> <fbkw> <fallback> ]? }
token fbkw     { :i 'fallback' >> }

# ---- parts with a name: tokens of their own, not aliases ---------------------
# Under rakupp 4.0.1 an alias -- '<cond=expr>' -- runs the actions of what it
# names twice, and those of the whole tree under it, twice over (Rakudo:
# once). On the way from a statement to a literal they multiplied: a function
# body, an 'if' body, an assignment's value twice, a range's low end -- 32
# times over for an expression in an 'if' in a function. A token of its own
# for each part runs them once, and keeps the name the actions read. Tokens,
# not rules: the part is exactly what it holds, not the space around it.
# 'If lOk := aRet[1]': an assignment is a value, the condition too. ':=' and
# the like only: 'If a = b' compares.
token cond      { [ <?{ ahead($/.from, 'bind', :item) }> <assignment> ] || <expr> }
token guarded   { <expr> }
token fallback  { <expr> }
token pexpr     { <expr> }
token key       { <expr> }
token source    { <expr> }
token lo        { <addexpr> }
token hi        { <addexpr> }
token lbody     { <blockexpr> }
token then      { <body> }              # an 'if''s: a new prologue may open it
token thenc     { <closedbody> }        # an 'elseif''s, a 'case''s
token else      { <closedbody> }
token block     { <body> }
token seqblock  { <closedbody> }
token withblock { <withbody> }
token recover   { <closedbody> }
token finblock  { <closedbody> }

# ---- xtpl: '?:' -- elvis -----------------------------------------------------
# The value on the left, unless it is Nil. Between '.or.' and '|>', and it
# chains to the right: 'first() ?: second() ?: "last"'.
rule elvis     { <orexpr> [ <elvisop> <orexpr> ]* }
token elvisop  { '?:' }
rule feed      { <!{ $*IN-BLOCK // False }> '|>' <stage> }
rule stage     { <nscall> || <call> || <name> }
rule orexpr    { <andexpr> [ <orop> <andexpr> ]* }
token orop     { :i '.or.' }
rule andexpr   { <notexpr> [ <andop> <notexpr> ]* }
token andop    { :i '.and.' }
rule notexpr   { <negate>? <cmpexpr> }
token negate   { '!' || [ :i '.not.' ] }

# ---- comparison, with xtpl's 'in' and 'has' ----------------------------------
#
#     cCode in aCodes       u_xtpl_in(cCode, aCodes)
#     nValue in 1..100      (nValue >= 1 .And. nValue <= 100)
#     hCfg has "rate"       the logical result of the Get
#
# Both at the level of AdvPL's '$', which is what they are: the collection of
# 'in' runs to the comma, the bracket or the '.and.'/'.or.' of the same level.
# The right of 'in' is the only place, besides the source of a pipeline,
# where a 'lo..hi' fits.
rule cmpexpr   { <rangeexpr> <cmptail>* }
rule cmptail   { [ <op=inop> <inrhs> ] || [ <op=cmpop> <rangeexpr> ] }
# AdvPL's own two as well: '=' compares in an expression (the loose
# equality; as a statement it is still an assignment, which <statement> tries
# first), and '#' is not-equal. '==' before '=', '>=' and '<=' before '>' and
# '<': the alternation is ordered.
token cmpop    { '==' || '!=' || '<>' || '>=' || '<=' || '>' || '<' || '$' || '#'
               || [ '=' <!before '>'> ]
               || [ :i 'has' >> ] }
token inop     { :i 'in' >> }

# ---- xtpl: 'lo..hi' ---------------------------------------------------------
# Only in two places: the right of an 'in', and as the source of a pipeline
# ('1..999 |> filter(...)'). Anywhere else there is nothing a range could be,
# so outside an 'in' it only matches when followed by '|>'.
# Both ends are named: an aliased capture also lands under the original name
# (that is Raku), so two <addexpr> at the same level would come back together
# as a list in $<addexpr>.
rule rangeexpr { <lo> [ '..' <hi> <?before <.ws> '|>'> ]? }
rule inrhs     { <lo> [ '..' <hi> ]? }

# 'for i in 1..n': a range as the source of a 'for'. xtpl takes it, and emits
# 'x := 1..n' -- not TL++; xc counts.
rule forrange  { <lo> '..' <hi> }
rule addexpr   { <mulexpr> [ <addop> <mulexpr> ]* }
token addop    { '+' || '-' }
rule mulexpr   { <powexpr> [ <mulop> <powexpr> ]* }
# AdvPL's power: 'nVal ^ 2', 'nVal ** 2' -- tighter than '*'.
rule powexpr   { <unary> [ <powop> <unary> ]* }
token powop    { '**' || '^' }
# '%%' -- divisible by -- before AdvPL's '%', which passes through untouched.
token mulop    { '%%' || '*' || '/' || '%' }
# '++n' and '--n' in an expression: on a variable, an element, a field --
# never a literal ('--5' is not one).
rule unary     { [ <incop> <!before <.ws> <literal>> <postfix> ] || [ <sign>? <postfix> ] }
token sign     { '-' || '+' }

# A literal takes no trailer: strings and numbers have no members or indices.
# Without this, '{ "a": nX }' matched as an ARRAY whose item was member 'nX'
# of the string "a" -- the pair's ':' became a member's, and the JSON fell
# back to an array.
rule postfix
{
     <literal>
  || [ <primary> <trailer>* <incop>? ]
}

# One rule per form, so the tree knows which one matched.
rule trailer
{
     <thash>
  || <tsafe>
  || <tmethod>
  || <tmember>
  || <tindex>
  || <tinalias>
  || <tfield>
}

# ':' followed by a method WITH arguments: 'MSDialog():New(...)'. Before the
# plain member, or that would match the name and leave the parentheses
# behind.
rule tmethod  { [ '::' || ':' ] <member> '(' ~ ')' <arglist> }
rule tmember  { ':' <member> }

# ---- xtpl: 'h{"k"}' -- hash access ------------------------------------------
# Braces index a hash, brackets index an array. A '{' RIGHT after a name, a
# ')', a ']' or a '}' -- no space -- is hash access, which AdvPL never has:
# 'hCfg{"k"}', 'getHash(){"k"}', 'aHashes[1]{"k"}', 'h{"a"}{"b"}'.
# '<?after ...>' is the 'right after': a space before the '{' has already
# been eaten by the caller's <.ws>, and then what lies behind is that space.
rule thash    { <?after <[\w)\]}]>> '{' ~ '}' <key> }

# ---- xtpl: '?.' -- safe access ----------------------------------------------
# 'oUser?.oAddress?.cCity', 'oUser?.Method(1)': Nil when the base is Nil,
# instead of an error. xtpl's doc shows members; it takes the call form too,
# and emits 'If(...)(1)' for it, which is broken -- xc lowers it.
rule tsafe    { '?.' <member> [ '(' ~ ')' <arglist> ]? }
rule tindex   { '[' ~ ']' [ <expr> [ ',' <expr> ]* ] }
rule tinalias { '->' '(' ~ ')' <expr> }
rule tfield   { '->' [ <fieldmacro> || <member> ] }

# After ':' or '->' comes a MEMBER, and a member can be called 'End' or
# 'Next'. The reserved list applies where a statement starts, not here.
token member { <[A..Za..z_]> \w* }

rule primary
{
     <selfacc>
  || <subjacc>
  || <lambda>
  || <macro>
  || <literal>
  || <codeblock>
  || <jsonliteral>
  || <hashliteral>
  || <arrayliteral>
  || <nscall>
  || <call>
  || <aliasfield>
  || <name>
  || [ '(' ~ ')' [ [ <passign> || <guardexpr> ] [ ',' <listitem> ]* ] ]
}

# '( fA(), fB() )': more than one, each in turn -- the first is read once, as
# for one alone, and the rest after it: no parse of it twice.
token listitem { <passign> || <guardexpr> }

# An assignment in parentheses is an expression -- 'if !( lOk := f() )'. Only
# when one is there, by ahead(): no capture is left when it is not.
token passign { <?{ ahead($/.from, 'bind', :item) }> <assignment> }

# A call qualified by a TL++ dotted path:
#
#     totvs.tools.Some.Thing():New()
#
# What sets it apart from 'nA.And.nB' -- lexically the same -- is ending in a
# call: 'qname' requires the '(' right after. And the segments cannot be the
# words of the '.and.'/'.or.'/'.not.' operators, or this rule would steal
# 'nA.And.nB' from the operator. Apart from that it is plain TL++ and goes
# out as it came in, so the node is an ordinary Call whose name carries the
# dots.
rule nscall { <qname> '(' ~ ')' <arglist> }

token qname
{
  <[A..Za..z_]> \w* [ '.' <!logword> <[A..Za..z_]> \w* ]+
}
token logword { :i [ 'and' || 'or' || 'not' ] <![\w]> }

# The macro operator: '&(expression)' or '&name'. Compiles and runs the
# string at run time -- nothing here sees what is inside.
# '&cVar', '&(cExpr)'; '&cFunc.()' -- the '.' ends the name -- a call.
rule macro
{
  '&' [ [ '(' ~ ')' <expr> ] || [ <name> '.'? ] ] <mcall>?
}
token mcall { '(' ~ ')' <arglist> }
# A macro that is called -- '&cFunc.( ... )' -- as a statement.
rule macrocall { '&' [ [ '(' ~ ')' <expr> ] || [ <name> '.'? ] ] <mcall> }

rule call        { <name> '(' ~ ')' <arglist> }

# One position per comma, empty or not: 'f( , 1, , )' has four, and the tree
# needs to know which one the '1' is in. Written by hand instead of with '%':
# an item that can match empty inside a '*' stops on the first round, and then
# ',1' does not match.
rule arglist     { <slot> [ ',' <slot> ]* }
rule slot        { <arg>? }

# An assignment is a valid argument too: 'If( c, a, cA := u )'.
rule arg         { <byref> || [ <?{ ahead($/.from, 'assign', :item) }> <assignment> ] || <expr> }
# '@::cTab': a member of the object, by reference, too; and an element of an
# array, '@aCampos[nX][8]'.
rule byref       { '@' [ <selfacc> || [ <name> <trailer>* ] ] }

# 'SA1->A1_NOME' and 'SA1->( DbGoTop() )'. 'SA1' is the NAME of a work area,
# not a variable: with a variable one writes '(cAlias)->A1_NOME', which is a
# parenthesized primary followed by a trailer.
rule aliasfield  { <alias=name> '->' [ [ '(' ~ ')' [ <expr> [ ',' <listitem> ]* ] ] || <fieldmacro> || <field=member> ] }
# 'SA2->( dbSetOrder(3), dbGoTop() )' as a statement.
token inalias { <aliasfield> <?{ (~$<aliasfield>) ~~ / '->' \s* '(' / }> }
# 'SX3->&("X3_CAMPO")', '(cAlias)->&(cField)': the field named when it runs.
token fieldmacro { <macro> }

# '{ : }' is the empty JSON and '{ => }' the empty hash. They need a spelling
# of their own because '{}' already means the empty array -- and they must
# come BEFORE <arrayliteral>, which would match the braces and leave the ':'
# behind.
# At least one pair, or the ':' of the empty one. With '<pair>*' an empty '{}'
# matched here -- and this rule comes before <arrayliteral>, so every empty
# array became JSON.
rule jsonliteral { '{' ~ '}' [ ':' || [ <pair>+ % ',' ] ] }
rule hashliteral { '{' ~ '}' [ '=>' || [ <hashpair>+ % ',' ] ] }
rule pair        { <expr> ':' <expr> }
rule hashpair    { <expr> '=>' <expr> }
# An element may be empty: '{ "P", , 1 }' -- Nil there.
rule arrayliteral { '{' ~ '}' [ <aitem> [ ',' <aitem> ]* ] }
rule aitem        { <expr>? }

# '{ || ... }' is a block with no parameters, and the two pipes touch.
rule codeblock
{
  :my $*IN-BLOCK = True;
  '{' [ '||' || [ '|' <name>* % ',' '|' ] ] <blockexpr>* % ',' '}'
}

# Inside a code block an assignment IS an expression.
rule blockexpr   { [ <?{ ahead($/.from, 'assign', :item) }> <assignment> ] || <expr> }

# ---- xtpl: lambda ------------------------------------------------------------
#
#     map(aOrders, [o] o:nValue)                      {|o| o:nValue}
#     reduce(aNums, [acc, x] acc + x, 0)              {|acc, x| acc + x}
#     tap([cLine] nRead += 1)                         an assignment too
#
# One to six names, and a single body: the body is an expression (or an
# assignment) and stops at the comma or parenthesis of what holds it -- the
# 'reduce' above has the lambda and the seed as separate arguments. '[' only
# opens a lambda at the start of a primary; after a value it is an index
# ('a[i]').
#
# A '|>' right after the body is refused, not left to whatever is outside:
# otherwise 'map(a, [x] x |> f)' would become 'f([x] x)' -- a different
# program, silently. It is the error xtpl gives: a pipeline does not nest in a
# block.
rule lambda
{
  :my $*IN-BLOCK = True;
  '[' <lparam=name> [ ',' <lparam=name> ] ** 0..5 ']' <lbody>
  <!before \h* '|>'>
}

# '::x' abbreviates access to a member of the object itself -- AdvPL's
# 'Self:x'. It works as a value ('::aBuf'), a call ('::Grow()') and a target
# ('::nHead := 1').
rule selfacc     { '::' <member> [ '(' ~ ')' <arglist> ]? }

# '(cAlias)->A1_COD := x' and 'GetObj():cName := x' too: a parenthesised
# expression or a call, with at least one trailer after it -- a bare '(x)'
# or 'f()' is not something to assign to.
# 'aTail(a) := x': the last element, as AdvPL takes it.
# '&(cCampo) := x', '&cVar := x': the variable a macro names.
rule lvalue      { [ '(' ~ ')' <pexpr> <trailer>+ ] || [ <call> <trailer>+ ] || <atail>
                || [ <macro> <trailer>* ]
                || [ [ <selfacc> || <subjacc> || <name> ] <trailer>* ] }

# ---- terminals ---------------------------------------------------------------
token literal  { <number> || <string> || <logical> || <nildef> }
# Digits may be grouped with an apostrophe, as C++14 does with the same
# character: '12'345'678', '1'234.567'8'. Only between two digits -- never
# first, last, doubled, beside the point, or before a space -- so it cannot be
# taken for a string: a string straight after a number was never valid.
# '.5' too, with no digit before the point, as Clipper writes it.
token number   { [ \d+ [ "'" \d+ ]* [ '.' \d+ [ "'" \d+ ]* ]? ] || [ '.' \d+ ] }
# ---- strings, and xtpl's interpolation ---------------------------------------
#
#     "total = ${nTotal} items"       ("total = " + cValToChar(nTotal) + " items")
#     'rate ${hCfg{"t"}} end'         both quote styles interpolate
#
# The expression inside '${ }' is ordinary code, parsed by the grammar. Settled
# against xtpl's own output:
#
# - '${' commits. If no expression and '}' follow, the string fails -- it does
#   not fall back to literal text, or an unclosed '${h{'k'} ...' would pass.
#   So '${}' is refused, and so is anything that is not a valid expression
#   (xtpl emits '${n +}' as broken code; xc refuses it).
# - A string inside the expression cannot use the quote of any string around
#   it: that quote would end the outer string, as it does in xtpl. The string
#   kinds set '$*IN-DQ' / '$*IN-SQ' for what they hold.
# - '$' not followed by '{' is text ('R$ 10'); there are no escapes.
#
# xtpl does not interpolate a string in a 'local' initializer -- it passes
# through as written. xc interpolates it wherever it is.
token string   { [ <!{ $*IN-DQ // False }> <dqstring> ] || [ <!{ $*IN-SQ // False }> <sqstring> ] }
token dqstring { :my $*IN-DQ = True; '"' <spart=dqpart>* '"' }
token sqstring { :my $*IN-SQ = True; "'" <spart=sqpart>* "'" }
token dqpart   { <interp> || <text=dqtext> }
token sqpart   { <interp> || <text=sqtext> }
token dqtext   { [ <-["$]> || '$' <!before '{'> ]+ }
token sqtext   { [ <-['$]> || '$' <!before '{'> ]+ }
token interp   { '${' <.ws> <expr> <.ws> '}' }
token logical  { :i '.t.' || '.f.' }
token nildef   { :i 'nil' >> }
token name     { <[A..Za..z_]> \w* }

# Whitespace WITHIN a line: blanks, comments, and the ';' continuation --
# which is the only way a statement carries on to the next line.
#
# A comment may follow the ';': 'aNums ;   // note' still continues. A ';'
# INSIDE a comment is just comment text, so '// ;' at the end of a line does
# not continue anything -- the comment token has already taken it.
token ws { <!ww> [ \h || <.linecont> || <.linecomment> || <.blockcomment> ]* }
token linecont    { ';' \h* [ <.linecomment> || <.blockcomment> ]? \h* \v }
token linecomment { '//' \N* }

# The end of a line (or of the file), and whatever comes before the next
# statement: blank lines, comment-only lines, and the indentation.
# A ';' with more on its line ends a statement too: 'conout(1); n++'. At the
# end of a line it is a continuation, and the whitespace rule takes it.
token eol { \h* [ <.linecomment> || <.blockcomment> ]? \h* [ \v || $ || ';' <!before \h* [ <.linecomment> || <.blockcomment> ]? \h* [ \v || $ ]> ] }
token gap { [ \s || <.linecont> || <.linecomment> || <.blockcomment> ]* }
# Every line end records how far the parse got, for the driver's error
# message: the first line it could not continue past. 'try', because the
# grammar is also used without a driver, where '$*FURTHEST' does not exist.
token nl  { <.eol> <.gap> { try $*FURTHEST = $/.to if $/.to > $*FURTHEST } }
token mark { <?> { try $*FURTHEST = $/.to if $/.to > $*FURTHEST } }
