// xc -- the tree a source is read into.
//
// The classes of the Raku xc's XC::AST, one for one, with the same
// attributes (README.md, History). What Raku leaves undefined is a null pointer, or an empty optional for a
// string. An offset counts bytes.
//
// The nodes of a tree belong to its Tree, made by Tree::make and freed with
// it; between themselves they point. A tree is not changed once read.

#pragma once

#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace xc
{
  // ---- expressions ----------------------------------------------------------
  enum class EK
  {
    Literal, Name, UserTrans, Call, Binary, Index, SelfRef, SubjectRef, Member, SafeMember,
    HashIndex, Interval, MethodCall, SafeCall, AliasField, InAlias, Macro, Ref, Omitted,
    ExprList, AssignExpr, ArrayLit, Interp, JsonLit, HashLit, CodeBlock, Lambda, Guard,
    Pipeline,
  };

  struct Node
  {
    virtual ~Node() = default;
  };

  struct Expr : Node
  {
    explicit Expr(EK k) : kind(k) {}
    EK  kind;
    int line = 0;
    int from = -1;       // src-from: where it starts in the source, or -1
    int to   = -1;       // src-to
  };

  using OptStr = std::optional<std::string>;

  struct Literal : Expr
  {
    Literal() : Expr(EK::Literal) {}
    explicit Literal(EK k) : Expr(k) {}
    std::string type;
    std::string text;
  };

  struct Name : Expr
  {
    Name() : Expr(EK::Name) {}
    std::string name;
  };

  // A use of a translation the source brings ('#xtranslate'), as written.
  struct UserTrans : Expr
  {
    UserTrans() : Expr(EK::UserTrans) {}
    std::string text;
    Expr* base = nullptr;        // what it follows, when it is a trailer
  };

  struct Call : Expr
  {
    Call() : Expr(EK::Call) {}
    std::string name;
    std::vector<Expr*> args;
  };

  // Also the unary forms: '!' and 'neg', with 'left' null.
  struct Binary : Expr
  {
    Binary() : Expr(EK::Binary) {}
    std::string op;
    Expr* left  = nullptr;
    Expr* right = nullptr;
  };

  struct Index : Expr
  {
    Index() : Expr(EK::Index) {}
    Expr* base = nullptr;
    std::vector<Expr*> indices;
  };

  struct SelfRef : Expr { SelfRef() : Expr(EK::SelfRef) {} };
  struct SubjectRef : Expr { SubjectRef() : Expr(EK::SubjectRef) {} };

  struct Member : Expr
  {
    Member() : Expr(EK::Member) {}
    explicit Member(EK k) : Expr(k) {}
    Expr* base = nullptr;
    std::string name;
  };

  struct SafeMember : Member { SafeMember() : Member(EK::SafeMember) {} };

  struct HashIndex : Expr
  {
    HashIndex() : Expr(EK::HashIndex) {}
    Expr* base = nullptr;
    Expr* key  = nullptr;
  };

  struct Interval : Expr
  {
    Interval() : Expr(EK::Interval) {}
    Expr* lo = nullptr;
    Expr* hi = nullptr;
  };

  struct MethodCall : Expr
  {
    MethodCall() : Expr(EK::MethodCall) {}
    explicit MethodCall(EK k) : Expr(k) {}
    Expr* base = nullptr;
    std::string name;
    std::vector<Expr*> args;
  };

  struct SafeCall : MethodCall { SafeCall() : MethodCall(EK::SafeCall) {} };

  // A work-area field: 'SA1->A1_NOME' names the area (alias, base null);
  // '(cAlias)->A1_NOME' has it in an expression (base).
  struct AliasField : Expr
  {
    AliasField() : Expr(EK::AliasField) {}
    Expr*  base = nullptr;
    OptStr alias;
    std::string field;           // '' with a macro
    Expr*  macro = nullptr;      // '->&(cField)'
  };

  // 'SA1->( DbGoTop() )'.
  struct InAlias : Expr
  {
    InAlias() : Expr(EK::InAlias) {}
    Expr*  base = nullptr;
    OptStr alias;
    Expr*  expr = nullptr;
  };

  struct Macro : Expr
  {
    Macro() : Expr(EK::Macro) {}
    Expr* target = nullptr;
    bool  called = false;        // '&cFunc.()'
    std::vector<Expr*> args;
  };

  struct Ref : Expr
  {
    Ref() : Expr(EK::Ref) {}
    Expr* target = nullptr;
  };

  struct Omitted : Expr { Omitted() : Expr(EK::Omitted) {} };

  struct ExprList : Expr
  {
    ExprList() : Expr(EK::ExprList) {}
    std::vector<Expr*> items;
  };

  struct AssignExpr : Expr
  {
    AssignExpr() : Expr(EK::AssignExpr) {}
    Expr* target = nullptr;
    std::string op;
    Expr* value = nullptr;
    std::string incdec;          // 'pre', 'post', or '' for a plain assignment
  };

  struct KeyValue : Node
  {
    Expr* key   = nullptr;
    Expr* value = nullptr;
  };

  struct ArrayLit : Literal
  {
    ArrayLit() : Literal(EK::ArrayLit) {}
    std::vector<Expr*> items;
  };

  // A string with '${ }': a run of text, or an expression.
  using Part = std::variant<std::string, Expr*>;

  struct Interp : Literal
  {
    Interp() : Literal(EK::Interp) {}
    std::vector<Part> parts;
  };

  struct JsonLit : Literal
  {
    JsonLit() : Literal(EK::JsonLit) {}
    std::vector<KeyValue*> pairs;
  };

  struct HashLit : Literal
  {
    HashLit() : Literal(EK::HashLit) {}
    std::vector<KeyValue*> pairs;
  };

  struct CodeBlock : Literal
  {
    CodeBlock() : Literal(EK::CodeBlock) {}
    explicit CodeBlock(EK k) : Literal(k) {}
    std::vector<std::string> params;
    std::vector<Expr*> body;
  };

  struct Lambda : CodeBlock { Lambda() : CodeBlock(EK::Lambda) {} };

  struct Guard : Expr
  {
    Guard() : Expr(EK::Guard) {}
    Expr* expr     = nullptr;
    Expr* fallback = nullptr;
  };

  struct Pipeline : Expr
  {
    Pipeline() : Expr(EK::Pipeline) {}
    Expr* source = nullptr;
    std::vector<Call*> stages;
  };

  // ---- statements -----------------------------------------------------------
  enum class SK
  {
    Declaration, Assignment, CallStmt, ReturnStmt, ExitStmt, LoopStmt, Annotation, IfStmt,
    CaseStmt, WhileStmt, ForStmt, ForInStmt, ForTimesStmt, Modified, Deferred, UsingAlias,
    WithObject, RawStmt, TryStmt, TransactionStmt, NoOpStmt, BreakStmt, DefaultStmt,
    SequenceStmt,
  };

  struct Stmt : Node
  {
    explicit Stmt(SK k) : kind(k) {}
    SK  kind;
    int line = 0;
    int from = -1;
    int to   = -1;
  };

  using Body = std::vector<Stmt*>;

  struct Declarator : Node
  {
    std::string name;
    Expr* init = nullptr;
    std::string declared;            // the type, or '?' when there is none
    std::vector<std::string> attributes;
    int line = 0;
    bool type_first = false;         // 'local x as N := 1' -- xtpl's order
    OptStr typespec_text;            // the 'as ...' as written
    std::vector<Expr*> dims;         // 'Local aX[10]'
  };

  struct Declaration : Stmt
  {
    Declaration() : Stmt(SK::Declaration) {}
    std::string scope;
    std::vector<Declarator*> declarators;
  };

  struct Assignment : Stmt
  {
    Assignment() : Stmt(SK::Assignment) {}
    Expr* target = nullptr;
    std::string op;
    Expr* value = nullptr;
  };

  struct CallStmt : Stmt
  {
    CallStmt() : Stmt(SK::CallStmt) {}
    Expr* call = nullptr;
  };

  struct ReturnStmt : Stmt
  {
    ReturnStmt() : Stmt(SK::ReturnStmt) {}
    Expr* value = nullptr;
  };

  struct ExitStmt : Stmt { ExitStmt() : Stmt(SK::ExitStmt) {} };
  struct LoopStmt : Stmt { LoopStmt() : Stmt(SK::LoopStmt) {} };

  struct Annotation : Stmt
  {
    Annotation() : Stmt(SK::Annotation) {}
    std::string name;
    std::vector<Expr*> args;
  };

  struct Branch : Node
  {
    Expr* cond = nullptr;
    Body body;
  };

  struct IfStmt : Stmt
  {
    IfStmt() : Stmt(SK::IfStmt) {}
    std::vector<Branch*> branches;
    Body otherwise;
    Declarator* header_decl = nullptr;
  };

  struct CaseStmt : Stmt
  {
    CaseStmt() : Stmt(SK::CaseStmt) {}
    std::vector<Branch*> branches;
    Body otherwise;
    Declarator* subject_decl = nullptr;
    Assignment* subject_assign = nullptr;
  };

  struct WhileStmt : Stmt
  {
    WhileStmt() : Stmt(SK::WhileStmt) {}
    Expr* cond = nullptr;
    Body body;
    Declarator* header_decl = nullptr;
  };

  struct ForStmt : Stmt
  {
    ForStmt() : Stmt(SK::ForStmt) {}
    std::string var;
    bool var_local = false;
    Expr* from_ = nullptr;
    Expr* to_ = nullptr;
    Expr* step = nullptr;
    Body body;
    int endname_from = -1;
    int endname_to = -1;
  };

  struct ForInStmt : Stmt
  {
    ForInStmt() : Stmt(SK::ForInStmt) {}
    std::string elem;
    OptStr index;
    Expr* source = nullptr;
    Body body;
    int endname_from = -1;
    int endname_to = -1;
  };

  struct ForTimesStmt : Stmt
  {
    ForTimesStmt() : Stmt(SK::ForTimesStmt) {}
    Expr* count = nullptr;
    Body body;
  };

  struct Modified : Stmt
  {
    Modified() : Stmt(SK::Modified) {}
    Stmt* stmt = nullptr;
    std::string op;                  // 'if' or 'while'
    Expr* cond = nullptr;
  };

  struct Deferred : Stmt
  {
    Deferred() : Stmt(SK::Deferred) {}
    Stmt* stmt = nullptr;
  };

  struct UsingAlias : Stmt
  {
    UsingAlias() : Stmt(SK::UsingAlias) {}
    std::string area;
    Expr* order = nullptr;
    Body body;
  };

  struct WithObject : Stmt
  {
    WithObject() : Stmt(SK::WithObject) {}
    Expr* subject = nullptr;
    Body body;
  };

  struct RawStmt : Stmt
  {
    RawStmt() : Stmt(SK::RawStmt) {}
    bool block = false;
    std::vector<std::string> lines;
  };

  struct TryStmt : Stmt
  {
    TryStmt() : Stmt(SK::TryStmt) {}
    Body body;
    OptStr error_var;
    Body handler;
    Body finally;
  };

  struct TransactionStmt : Stmt
  {
    TransactionStmt() : Stmt(SK::TransactionStmt) {}
    Body body;
  };

  struct NoOpStmt : Stmt
  {
    NoOpStmt() : Stmt(SK::NoOpStmt) {}
    std::string word;
  };

  struct BreakStmt : Stmt
  {
    BreakStmt() : Stmt(SK::BreakStmt) {}
    Expr* value = nullptr;
  };

  struct DefaultStmt : Stmt
  {
    DefaultStmt() : Stmt(SK::DefaultStmt) {}
    std::vector<Assignment*> pairs;  // op ':='
  };

  struct SequenceStmt : Stmt
  {
    SequenceStmt() : Stmt(SK::SequenceStmt) {}
    Body body;
    bool has_recover = false;
    OptStr error_var;
    Body recover;
  };

  // ---- the file -------------------------------------------------------------
  struct Param : Node
  {
    std::string name;
    std::string declared;            // '?' when there is none
    OptStr type_word;                // the type as written
    std::vector<std::string> attributes;
    int attrs_from = -1;             // from the name's end to the '>'
    int attrs_to = -1;
  };

  struct FunctionDef : Node
  {
    std::string type;                // user, static, main -- or ''
    std::string name;
    std::vector<Param*> params;
    std::vector<Annotation*> annotations;
    Body body;
    int line = 0;
    OptStr rettype_word;
  };

  struct DataMember : Node
  {
    std::string name;
    OptStr type;
    OptStr visibility;
    int line = 0;
    Expr* init = nullptr;            // 'default value', 'init value': the AppServer ignores it
    std::string init_word;           // 'default' or 'init', as written
  };

  struct MethodSig : Node
  {
    std::string name;
    std::vector<Param*> params;
    OptStr visibility;
    bool constructor = false;
    bool is_static = false;          // 'Static Method'
    OptStr returns;
  };

  struct ClassDef : Node
  {
    std::string name;
    std::vector<std::string> supers;
    std::vector<DataMember*> members;
    std::vector<MethodSig*> methods;
    int line = 0;
    bool iface = false;              // an Interface: signatures only
  };

  struct MethodImpl : Node
  {
    std::string class_name;
    std::string name;
    std::vector<Param*> params;
    OptStr returns;
    Body body;
    int line = 0;
    bool ws = false;                 // a web service's: 'WSMETHOD ... WSSERVICE Name'
  };

  struct External : Node
  {
    bool alias = false;
    std::vector<std::string> names;
    int line = 0;
    int from = -1;
    int to = -1;
  };

  struct Program : Node
  {
    OptStr ns;                       // namespace
    std::vector<std::string> usings;
    std::vector<std::string> directives;
    std::vector<Annotation*> annotations;
    std::vector<FunctionDef*> functions;
    std::vector<ClassDef*> classes;
    std::vector<MethodImpl*> methods;
    std::vector<External*> externals;
    std::vector<Declaration*> statics;
  };

  // ---- the tree -------------------------------------------------------------
  class Tree
  {
  public:
    template <class T, class... A>
    T* make(A&&... a)
    {
      auto p = std::make_unique<T>(std::forward<A>(a)...);
      T* raw = p.get();
      nodes_.push_back(std::move(p));
      return raw;
    }

  private:
    std::vector<std::unique_ptr<Node>> nodes_;
  };
}
