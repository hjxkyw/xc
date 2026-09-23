# XC::AST -- the tree the grammar produces.
#
# Each node is a small class holding what matters about that piece of the
# program, and none of the syntax that wrote it. 'local nX := 1 as N' and
# 'local nX := 1 as Numeric' become the same node: the abbreviation is
# spelling.
#
# Expressions, statements, functions, classes and the file. Nothing stays as
# text: every name an expression reads is a node, even inside 'o:x(n)[i]', a
# code block or a macro. An analysis looking for who reads a variable can
# trust that no read hides inside a string -- except the one the macro itself
# does at run time, which no tree can see.

unit module XC::AST;

# The TL++ types, by full name. The grammar accepts the abbreviation; the tree
# always keeps the full name, so a reader need not know that 'N' is 'Numeric'.
#
# Strings, not an 'enum'. 'Array', 'Numeric', 'Date' and 'Block' are already
# Raku types, and an enum with those keys does not win against them: the name
# stays Raku's type object, which is empty inside a string.
constant @TYPES is export =
  <Array Numeric Character Logical Date Object Block JSON Variant>;

constant UNKNOWN is export = '?';

sub type-of-name(Str $name --> Str) is export
{
  given $name.lc
  {
    when 'array'     | 'a' { 'Array'     }
    when 'numeric'   | 'n' { 'Numeric'   }
    when 'character' | 'c' { 'Character' }
    when 'logical'   | 'l' { 'Logical'   }
    when 'date'      | 'd' { 'Date'      }
    when 'object'    | 'o' { 'Object'    }
    when 'block'     | 'b' { 'Block'     }
    when 'json'      | 'j' { 'JSON'      }
    when 'variant'   | 'u' { 'Variant'   }
    default                { UNKNOWN     }
  }
}

# ---- expressions --------------------------------------------------------------
class Expr is export
{
  has Int $.line is rw = 0;
}

class Literal is Expr is export
{
  has Str  $.type;
  has Str  $.text;
}

class Name is Expr is export
{
  has Str $.name;
}

class Call is Expr is export
{
  has Str  $.name;
  has Expr @.args;
}

# Also the unary forms: '!' and 'neg', with 'left' undefined.
class Binary is Expr is export
{
  has Str  $.op;
  has Expr $.left;
  has Expr $.right;
}

# ---- what comes after an expression -----------------------------------------
class Index is Expr is export             # a[i, j]
{
  has Expr $.base;
  has Expr @.indices;
}

# The '::' of '::x' -- the object itself, as the implicit base of a Member or
# MethodCall. It reads no variable.
class SelfRef is Expr is export { }

class Member is Expr is export            # o:nX  (and ::nX, based on SelfRef)
{
  has Expr $.base;
  has Str  $.name;
}

# ---- xtpl: operators with a node of their own -----------------------------------
# The ones that are an ordinary binary operator -- 'in', 'has', '%%', '?:' --
# are a Binary with their own 'op'; the 'op' is what marks the extension.
# These three have a shape of their own.

# 'oUser?.cCity': a Member that returns Nil when its base is Nil.
class SafeMember is Member is export { }

# 'hCfg{"rate"}': braces index a hash, brackets index an array.
class HashIndex is Expr is export
{
  has Expr $.base;
  has Expr $.key;
}

# '1..100', only on the right of an 'in' or as the source of a pipeline.
class Interval is Expr is export
{
  has Expr $.lo;
  has Expr $.hi;
}

class MethodCall is Expr is export        # o:Sum(1, 2)
{
  has Expr $.base;
  has Str  $.name;
  has Expr @.args;
}

# A work-area field. 'SA1->A1_NOME' names the area ('alias', with 'base'
# undefined); '(cAlias)->A1_NOME' has the area in an expression ('base').
class AliasField is Expr is export
{
  has Expr $.base;
  has Str  $.alias;
  has Str  $.field;
}

# An expression evaluated in a work area: 'SA1->( DbGoTop() )'. The area as
# above.
class InAlias is Expr is export
{
  has Expr $.base;
  has Str  $.alias;
  has Expr $.expr;
}

# ---- the rest -------------------------------------------------------------------
# '&cVar' and '&(cA + cB)'. The 'target' is what yields the string -- the Name
# 'cVar' is READ. What the string does at run time, nothing here knows.
class Macro is Expr is export
{
  has Expr $.target;
}

class Ref is Expr is export              # '@aX' in an argument: read and written
{
  has Expr $.target;
}

class Omitted is Expr is export { }      # the empty position in 'f( , 1)'

# An assignment where an expression goes: 'If(c, a, cA := u)', '{|| n := 1}'.
class AssignExpr is Expr is export
{
  has Expr $.target;
  has Str  $.op;
  has Expr $.value;
}

# Literals with parts. Still Literal -- with the type and the text --, so
# whoever only wants the type need not know each one.
class KeyValue is export
{
  has Expr $.key;
  has Expr $.value;
}

class ArrayLit is Literal is export { has Expr     @.items; }
class JsonLit  is Literal is export { has KeyValue @.pairs; }
class HashLit  is Literal is export { has KeyValue @.pairs; }

class CodeBlock is Literal is export
{
  has Str  @.params;
  has Expr @.body;
}

# '[o] o:nValue' -- xtpl's lambda. It is a code block with a single body, so
# it is a CodeBlock (type 'Block', params, body), and whoever only wants the
# type or walks the expressions need not tell them apart. The class of its
# own marks the extension: lowering writes '{|o| o:nValue}'.
class Lambda is CodeBlock is export { }

# 'callService(cUrl) fallback ""': if the expression raises an error, the
# fallback is the value. It only appears in the value of an assignment,
# declaration or 'return', or inside parentheses. Lowering is
# 'u_xtpl_safe_pipe({|| expr}, {|| fallback})'.
class Guard is Expr is export
{
  has Expr $.expr;
  has Expr $.fallback;
}

# 'aOrders |> filter([o] ...) |> map([o] ...)' -- the source and the stages, in
# order. Each stage is the call as written, WITHOUT the first argument: '|>'
# supplies it. '|> asum' is a Call with no arguments. Lowering chains the
# calls ('map(filter(aOrders, ...), ...)', a temporary per stage, or the fused
# loop) -- and that is code generation, not the tree.
class Pipeline is Expr is export
{
  has Expr $.source;
  has Call @.stages;
}

# ---- statements -----------------------------------------------------------------
#
# A body is an array of Stmt. The optional parts that are missing hold the type
# object -- 'Expr' with no value --, which is what '.defined' answers false to.
class Stmt is export
{
  has Int $.line = 0;
}

class Declarator is export
{
  has Str   $.name;
  has Expr  $.init;            # undefined when there is none
  has Str   $.declared;        # the 'as ...', or '?' when there is none
  has Str   @.attributes;      # 'const', 'contained' -- xtpl's
  has Int   $.line;
}

class Declaration is Stmt is export
{
  has Str        $.scope;        # local, private, public, static
  has Declarator @.declarators;
}

# 'n := 1', 'n += 1', 'o:x := 2'. The target is a Name, or the chain that ends
# in what gets written: an Index, a Member, an AliasField.
class Assignment is Stmt is export
{
  has Expr $.target;
  has Str  $.op;
  has Expr $.value;
}

# An expression as a statement: 'conout(x)', 'oDlg:Activate()', a pipeline.
class CallStmt is Stmt is export
{
  has Expr $.call;
}

class ReturnStmt is Stmt is export { has Expr $.value; }   # undefined: 'return'
class ExitStmt   is Stmt is export { }                      # exit
class LoopStmt   is Stmt is export { }                      # loop

class Annotation is Stmt is export
{
  has Str  $.name;
  has Expr @.args;
}

# A condition and what runs when it holds. 'if/elseif' and 'do case' are the
# same thing: branches in order, and what is left over.
class Branch is export
{
  has Expr $.cond;
  has Stmt @.body;
}

class IfStmt is Stmt is export
{
  has Branch     @.branches;       # the 'if' and each 'elseif'
  has Stmt       @.otherwise;
  has Declarator $.header-decl;    # 'if local x := ..., cond'; undefined if not
}

class CaseStmt is Stmt is export
{
  has Branch     @.branches;       # each 'case'
  has Stmt       @.otherwise;      # 'otherwise'
  # 'do case with <subject>': evaluated once. With 'local' it is a declarator
  # (a new local); without, an assignment to a variable declared before. Only
  # one of the two.
  has Declarator $.subject-decl;
  has Assignment $.subject-assign;
}

class WhileStmt is Stmt is export
{
  has Expr       $.cond;
  has Stmt       @.body;
  has Declarator $.header-decl;    # 'while local x := ..., cond'; undefined if not
}

class ForStmt is Stmt is export
{
  has Str  $.var;
  has Bool $.var-local = False;    # 'for local i := ...': 'i' is a new local
  has Expr $.from;
  has Expr $.to;
  has Expr $.step;                 # undefined: step 1
  has Stmt @.body;
}

# ---- xtpl: postfix modifier -----------------------------------------------------
# 'x := 1 if c', 'return n if c', 'f() while c', 'exec f() if c'. The inner
# statement is what runs; 'op' says how: 'if' becomes a one-branch If,
# 'while' a While. Lowering is just that -- the statement stays the same,
# inside the block.
class Modified is Stmt is export
{
  has Stmt $.stmt;
  has Str  $.op;                   # 'if' or 'while'
  has Expr $.cond;
}

# 'defer f()': the statement runs before every exit from the function, in the
# reverse order of registration. Lowering emits it before each 'return' and at
# the end of the body. A name read only by a defer counts as read -- 'walk'
# goes into it.
class Deferred is Stmt is export
{
  has Stmt $.stmt;
}

class SequenceStmt is Stmt is export
{
  has Stmt @.body;
  has Bool $.has-recover = False;
  has Str  $.error-var;            # 'recover using oErr'; undefined if not
  has Stmt @.recover;
}

# ---- the file -------------------------------------------------------------------
class Param is export
{
  has Str $.name;
  has Str $.declared;              # '?' when there is none
}

class FunctionDef is export
{
  has Str        $.type;           # user, static, main -- or '' for a bare 'function'
  has Str        $.name;
  has Param      @.params;
  has Annotation @.annotations;
  has Stmt       @.body;
  has Int        $.line;
}

class DataMember is export         # 'Data name as type'
{
  has Str $.name;
  has Str $.type;                  # undefined when there is none
  has Str $.visibility;            # public/protected/private; undefined if none
}

class MethodSig is export          # 'Method name(params) [Constructor] [as type]'
{
  has Str   $.name;
  has Param @.params;
  has Str   $.visibility;
  has Bool  $.constructor = False;
  has Str   $.returns;             # undefined when there is none
}

class ClassDef is export
{
  has Str        $.name;
  has Str        @.supers;         # 'From A, B'
  has DataMember @.members;
  has MethodSig  @.methods;        # the signatures in the block
  has Int        $.line;
}

# 'Method name(params) [as type] Class Name' + body. Like a FunctionDef, but
# bound to a class.
class MethodImpl is export
{
  has Str   $.class-name;
  has Str   $.name;
  has Param @.params;
  has Str   $.returns;             # undefined when there is none
  has Stmt  @.body;
  has Int   $.line;
}

class Program is export
{
  has Str         $.namespace;     # undefined when there is none
  has Str         @.usings;
  has Str         @.directives;    # '#include ...' whole, as it came
  has Annotation  @.annotations;   # the ones not before a function
  has FunctionDef @.functions;
  has ClassDef    @.classes;
  has MethodImpl  @.methods;       # the loose implementations
}

# ---- walking --------------------------------------------------------------------

# The expressions right below one, in reading order. Missing parts (the empty
# side of a '!', the base of an 'SA1->') do not appear.
sub subexprs(Expr $e --> List) is export
{
  my @s = do given $e
  {
    when Binary     { .left, .right }
    when Call       { |.args }
    when Index      { .base, |.indices }
    when Member     { .base }
    when MethodCall { .base, |.args }
    when AliasField { .base }
    when InAlias    { .base, .expr }
    when Macro      { .target }
    when Ref        { .target }
    when AssignExpr { .target, .value }
    when ArrayLit   { |.items }
    when JsonLit | HashLit { |.pairs.map({ .key, .value }).flat }
    when CodeBlock  { |.body }
    when Pipeline   { .source, |.stages }
    when Guard      { .expr, .fallback }
    when HashIndex  { .base, .key }
    when Interval   { .lo, .hi }
    default         { () }
  };
  @s.grep(*.defined).List
}

# Calls &f on an expression and on every one inside it, in reading order.
sub walk-expr(Expr $e, &f) is export
{
  return without $e;
  f($e);
  walk-expr($_, &f) for subexprs($e);
}

# The expressions a statement holds, without going into its bodies -- 'walk'
# does that. The variable of a 'for' is a name, not an expression, and is left
# out.
sub exprs-of(Stmt $s --> List) is export
{
  my @s = do given $s
  {
    when Declaration { |.declarators.map(*.init) }
    when Assignment  { .target, .value }
    when CallStmt    { .call }
    when ReturnStmt  { .value }
    when Annotation  { |.args }
    when Modified    { .cond }
    when IfStmt      { .header-decl.defined ?? (.header-decl.init, |.branches.map(*.cond))
                                             !! |.branches.map(*.cond) }
    when CaseStmt    { (.subject-decl.defined   ?? .subject-decl.init    !! Expr),
                       (.subject-assign.defined ?? .subject-assign.value !! Expr),
                       |.branches.map(*.cond) }
    when WhileStmt   { .header-decl.defined ?? (.header-decl.init, .cond) !! .cond }
    when ForStmt     { .from, .to, .step }
    default          { () }
  };
  @s.grep(*.defined).List
}

# The bodies a statement holds, in reading order. It is what any analysis
# needs to go down the tree without knowing every kind of statement.
sub bodies-of(Stmt $s --> List) is export
{
  given $s
  {
    when IfStmt | CaseStmt { (|.branches.map({ .body.List }), .otherwise.List).List }
    when WhileStmt         { (.body.List,).List }
    when ForStmt           { (.body.List,).List }
    when SequenceStmt      { (.body.List, .recover.List).List }
    when Modified          { ((.stmt,).List,).List }
    when Deferred          { ((.stmt,).List,).List }
    default                { ().List }
  }
}

# Calls &f on each statement of a body, and on the ones inside, in reading
# order.
sub walk(@body, &f) is export
{
  for @body -> $s
  {
    f($s);
    walk($_, &f) for bodies-of($s);
  }
}
