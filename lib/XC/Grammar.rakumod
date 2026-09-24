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
# as written.
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
rule TOP
{
  ^ <.gap> [ <toplevel> <.gap> ]* $
}

# The function first: it starts with its annotations, and only when what
# follows is not a function does an annotation stand alone.
rule toplevel
{
     <function>
  || <classdecl>
  || <methodimpl>
  || [ [ <preproc> || <namespacest> || <externalst> || <annotation> ] <.eol> ]
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
rule externalst { :i 'external' [ <isalias=kwalias> ]? <xname=name> [ ',' <xname=name> ]* }
token kwalias   { :i 'alias' >> }

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
  <funckind> <name> '(' ~ ')' <params> <.nl>
  <body=funcbody>
}

# A bare 'function' is accepted on purpose. AdvPL refuses it ("Regular
# functions are not allowed in code"), but TL++ accepts it when the name
# starts with 'u_' -- and maybe other prefixes, not yet surveyed. Refusing it
# here would refuse valid TL++.
token funckind { :i [ [ 'user' || 'static' || 'main' ] \s+ ]? 'function' }

# ---- TL++: classes ---------------------------------------------------------
# Native to TL++, not an xtpl extension. Two parts: the 'Class ... EndClass'
# block with its 'Data' members and 'Method' signatures, and the
# implementations 'Method name(...) Class Name' loose in the file, each with
# its own body.
rule classdecl
{
  :i 'class' <cname=name> [ :i [ 'from' || 'inherit' ] <supers=name>+ % ',' ]? <.nl>
  [ <classmember> <.nl> ]*
  :i 'endclass'
}

rule classmember
{
     <datadecl>
  || <methdecl>
}

rule visib { :i [ 'public' || 'protected' || 'private' || 'exported' || 'hidden' ] }

# 'Data name [as type]', one or more per line. The type here is any name (a
# class included), not the closed list of 'as' in declarations.
rule datadecl { <visib>? :i 'data' <datavar>+ % ',' }
rule datavar  { <dname=name> [ :i 'as' <dtype=name> ]? }

# The signature: 'Constructor' and the return type are optional and come in
# any order.
rule methdecl { <visib>? :i 'method' <mname=name> '(' ~ ')' <params> <methtag>* }
rule methtag  { :i 'constructor' || [ :i 'as' <ret=name> ] }

# The implementation, at file level. The 'as type' comes before 'class Name'.
rule methodimpl
{
  [ <annotation> <.nl> ]*
  :i 'method' <mname=name> '(' ~ ')' <params>
     [ :i 'as' <ret=name> ]?
     :i 'class' <cname=name> <.nl>
  <body=funcbody>
}

rule params
{
  <param>? [ ',' <param>? ]*
}

# A parameter can be typed too: 'f(nX as Numeric)'.
rule param
{
  <name> <!{ is-reserved(~$<name>) }> <typespec>?
}

# 'return' is a STATEMENT, not just the end of the function. An early return
# inside an 'if' is common, and if the final 'return' were part of the
# function rule, the body would swallow the inner ones and leave nothing to
# close it.
# The value is optional, and an 'if'/'while' right after 'return' starts a
# modifier, not the value: 'return if lSkip' returns nothing. Without the
# '<!modkw>' the 'if' became a name and the line stopped matching.
rule returnst
{
  :i 'return' [ <!modkw> <expr=guardexpr> ]?
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
  :i [
       'array'     || 'a' >>
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

# ---- statements ---------------------------------------------------------------
# Block statements and declarations take no modifier; simple ones take one,
# optionally, at the end of the line: 'x := 1 if c', 'return n if c',
# 'exit if c', 'f() while c'. 'exec' is a simple statement that only exists
# with a modifier.
rule statement
{
  [
     <annotation>
  || <seqst>
  || [ <!{ $*PAST-PROLOGUE // False }> <declaration> ]
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
rule deferst { :i 'defer' [ <assignment> || <pipest> || <callst> ] }

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
     <block=body>
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
     <block=withbody>
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

# ---- xtpl: 'raw' -- a line for the preprocessor ---------------------------------
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
token rawst    { <rawblock> || <rawone> }
token rawblock
{
  :i 'raw' \h* <.linecomment>? <.rawnl>
  # '<!ww>', not '>>': under rakupp 4.0.1 a '>>' just before the '>' that
  # closes a lookahead makes the lookahead fail (Rakudo is fine).
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
  || <assignment>
  || <nilassign>
  || <pipest>
  || <callst>
}

# ---- xtpl: '?=' -- assign if Nil ----------------------------------------------
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
rule modifier { <kw=modkw> <cond=expr> }
token modkw   { :i [ 'if' || 'while' ] >> }

# 'exec <expr>' marks an expression as a statement. It does not exist without
# a modifier.
rule execst   { :i 'exec' <expr> <modifier> }

token blockcomment { '/*' .*? '*/' }

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
rule declarator
{
  <name>
  <!{ is-reserved(~$<name>) }>
  <!{ ($*TOP-LEVEL // False) && is-generated(~$<name>) }>
  <attrs>?
  [    [ ':=' <expr=guardexpr> <typespec>? ]
    || [ <typespec> ':=' <expr=guardexpr> ]
    || [ <typespec> ]
    || <?> ]
  <!{ $<attrs> && (~$<attrs>).lc.contains('const') && !$<expr> }>
}

token attrs { '<' \s* <attr>+ % [ \s* ',' \s* ] \s* '>' }
token attr  { :i [ 'const' || 'contained' ] >> }

# The parts are named -- '<cond=expr>', '<then=body>' -- because repeated
# ones come back as a list, and unnamed the 'else' body would be just the last
# of a list that sometimes has one more.
# 'if local x := f(), <cond>' declares a block local in the header itself, and
# only then the condition. 'local' is a reserved word, so the comma separates
# the declarator from the condition unambiguously: 'f()' stops at the comma,
# and what follows is the condition. Only the opening 'if' declares; 'elseif'
# does not.
rule ifst
{
  :i 'if' [ :i <hdrlocal=kwlocal> <hdrdecl> ',' ]? <cond=expr> <.nl>
     <then=body>
  [ :i 'elseif' <cond=expr> <.nl> <then=closedbody> ]*
  [ :i 'else' <.nl> <else=closedbody> ]?
  :i 'endif'
}

rule whilest
{
  :i 'while' [ :i <hdrlocal=kwlocal> <hdrdecl> ',' ]? <cond=expr> <.nl>
     <block=body>
  :i [ 'enddo' || 'end' ]
}

# 'for local i := ...' makes 'i' a new local of the loop. Without 'local', 'i'
# is a variable declared before.
rule forst
{
  :i 'for' [ :i <varlocal=kwlocal> ]? <var=name>
     <!{ $<varlocal> && is-reserved(~$<var>) }> ':=' <from=expr>
     :i 'to' <to=expr> [ :i 'step' <step=expr> ]? <.nl>
     <block=body>
  :i 'next' <endname=name>?
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
     :i 'in' <source=expr> <.nl>
     <block=body>
  :i 'next' <endname=name>?
}

rule fortimesst
{
  :i 'for' <count=expr> :i 'times' <.nl>
     <block=body>
  :i 'next'
}

# 'do case with <subject>' evaluates the subject once and names it, instead of
# repeating the expression in every 'case'. With 'local' the subject is a new
# block local; without, it assigns to a variable declared before.
rule docasest
{
  :i 'do' 'case' [ :i 'with' <subject> ]? <.nl>
  [ :i 'case' <cond=expr> <.nl> <then=closedbody> ]+
  [ :i 'otherwise' <.nl> <else=closedbody> ]?
  :i 'endcase'
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
     <block=closedbody>
  [ :i 'recover' [ :i 'using' <errvar=name> ]? <.nl> <recover=closedbody> ]?
  :i 'end' [ :i 'sequence' ]?
}

rule assignment
{
  <!stmtword> <lvalue> <assignop> <expr=guardexpr>
}

token assignop { ':=' || '+=' || '-=' || '*=' || '/=' || '=' }

# A real call, not a bare name: either it has parentheses, or at least one
# ':' / '->' / '[' after.
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
  <!stmtword> [ [ <call> <trailer>* ] || [ <name> <trailer>+ ] || [ <subjacc> <trailer>* ] ]
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
rule guardexpr { <guarded=expr> [ <!{ $*IN-BLOCK // False }> <fbkw> <fallback=expr> ]? }
token fbkw     { :i 'fallback' >> }

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

# ---- comparison, with xtpl's 'in' and 'has' -----------------------------------
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
rule cmptail   { [ <op=inop> <rhs=inrhs> ] || [ <op=cmpop> <rhs=rangeexpr> ] }
token cmpop    { '==' || '!=' || '<>' || '>=' || '<=' || '>' || '<' || '$'
               || [ :i 'has' >> ] }
token inop     { :i 'in' >> }

# ---- xtpl: 'lo..hi' ---------------------------------------------------------
# Only in two places: the right of an 'in', and as the source of a pipeline
# ('1..999 |> filter(...)'). Anywhere else there is nothing a range could be,
# so outside an 'in' it only matches when followed by '|>'.
# Both ends are named: an aliased capture also lands under the original name
# (that is Raku), so two <addexpr> at the same level would come back together
# as a list in $<addexpr>.
rule rangeexpr { <lo=addexpr> [ '..' <hi=addexpr> <?before <.ws> '|>'> ]? }
rule inrhs     { <lo=addexpr> [ '..' <hi=addexpr> ]? }
rule addexpr   { <mulexpr> [ <addop> <mulexpr> ]* }
token addop    { '+' || '-' }
rule mulexpr   { <unary> [ <mulop> <unary> ]* }
# '%%' -- divisible by -- before AdvPL's '%', which passes through untouched.
token mulop    { '%%' || '*' || '/' || '%' }
rule unary     { <sign>? <postfix> }
token sign     { '-' || '+' }

# A literal takes no trailer: strings and numbers have no members or indices.
# Without this, '{ "a": nX }' matched as an ARRAY whose item was member 'nX'
# of the string "a" -- the pair's ':' became a member's, and the JSON fell
# back to an array.
rule postfix
{
     <literal>
  || [ <primary> <trailer>* ]
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
rule tmethod  { ':' <member> '(' ~ ')' <arglist> }
rule tmember  { ':' <member> }

# ---- xtpl: 'h{"k"}' -- hash access ------------------------------------------
# Braces index a hash, brackets index an array. A '{' RIGHT after a name --
# no space -- is hash access, which AdvPL never has; '<?after \w>' is the
# 'right after': a space between the name and '{' has already been eaten by
# the caller's <.ws>, and then what lies behind is that space.
rule thash    { <?after \w> '{' ~ '}' <key=expr> }

# ---- xtpl: '?.' -- safe access ----------------------------------------------
# 'oUser?.oAddress?.cCity': a Nil link returns Nil. Members only, no calls --
# which is what xtpl's doc and tests show.
rule tsafe    { '?.' <member> }
rule tindex   { '[' ~ ']' [ <expr> [ ',' <expr> ]* ] }
rule tinalias { '->' '(' ~ ')' <expr> }
rule tfield   { '->' <member> }

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
  || [ '(' ~ ')' <expr=guardexpr> ]
}

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
rule macro
{
  '&' [ [ '(' ~ ')' <expr> ] || <name> ]
}

rule call        { <name> '(' ~ ')' <arglist> }

# One position per comma, empty or not: 'f( , 1, , )' has four, and the tree
# needs to know which one the '1' is in. Written by hand instead of with '%':
# an item that can match empty inside a '*' stops on the first round, and then
# ',1' does not match.
rule arglist     { <slot> [ ',' <slot> ]* }
rule slot        { <arg>? }

# An assignment is a valid argument too: 'If( c, a, cA := u )'.
rule arg         { <byref> || <assignment> || <expr> }
rule byref       { '@' <name> }

# 'SA1->A1_NOME' and 'SA1->( DbGoTop() )'. 'SA1' is the NAME of a work area,
# not a variable: with a variable one writes '(cAlias)->A1_NOME', which is a
# parenthesized primary followed by a trailer.
rule aliasfield  { <alias=name> '->' [ [ '(' ~ ')' <expr> ] || <field=member> ] }

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
rule arrayliteral { '{' ~ '}' [ <expr>* % ',' ] }

# '{ || ... }' is a block with no parameters, and the two pipes touch.
rule codeblock
{
  :my $*IN-BLOCK = True;
  '{' [ '||' || [ '|' <name>* % ',' '|' ] ] <blockexpr>* % ',' '}'
}

# Inside a code block an assignment IS an expression.
rule blockexpr   { <assignment> || <expr> }

# ---- xtpl: lambda -------------------------------------------------------------
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
  '[' <lparam=name> [ ',' <lparam=name> ] ** 0..5 ']' <lbody=blockexpr>
  <!before \h* '|>'>
}

# '::x' abbreviates access to a member of the object itself -- AdvPL's
# 'Self:x'. It works as a value ('::aBuf'), a call ('::Grow()') and a target
# ('::nHead := 1').
rule selfacc     { '::' <member> [ '(' ~ ')' <arglist> ]? }

rule lvalue      { [ <selfacc> || <subjacc> || <name> ] <trailer>* }

# ---- terminals ----------------------------------------------------------------
token literal  { <number> || <string> || <logical> || <nildef> }
token number   { \d+ [ '.' \d+ ]? }
# ---- strings, and xtpl's interpolation ----------------------------------------
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
token eol { \h* [ <.linecomment> || <.blockcomment> ]? \h* [ \v || $ ] }
token gap { [ \s || <.linecont> || <.linecomment> || <.blockcomment> ]* }
token nl  { <.eol> <.gap> }
