// xc -- a source read into a tree.
//
// Recursive descent over the source's bytes, making the tree the Raku xc's
// grammar and actions make: the same nodes, the same spans. Where the
// grammar is written as a rule -- whitespace taken after each part -- the
// parser takes it in the same places; where it is a token, only where the
// token does. A form that ends past its whitespace (every rule does) leaves
// nothing for whitespace after it to take.
//
// For now the expressions: what a statement holds -- a value, a condition,
// a target, a call made a statement, a chain run for its effect.

#pragma once

#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "ahead.h"
#include "ast.h"
#include "commands.h"

namespace xc
{
  // A reserved word, refused where a name is declared ('local len').
  bool is_reserved(const std::string& name);

  // The shape of a name xc generates: '<kind>_<depth>_<index>', or a slot
  // 's_'/'b_'.
  bool is_generated(const std::string& name);

  // The forms a statement holds an expression as.
  enum class Form { Value, GuardExpr, Cond, Expr, LValue, CallSt, PipeSt };

  class Parser
  {
  public:
    // trans: the source's own translations, start => end; cmd: the uses of
    // its own commands, start => what (both from XC::Commands).
    Parser(std::string_view src, std::unordered_map<int, int> trans, Tree& tree,
           std::unordered_map<int, UserCmd> cmd = {});

    // The whole source: its tree, or null when it does not read.
    Program* parse();

    // How far a parse that failed got: the end of the furthest line end it
    // took.
    int furthest() const { return furthest_; }

    // 'any name': no declared name is refused (bin/xc reads a source that did
    // not parse so, to say which name it was); 'generated ok': a name of the
    // shape xc generates may be declared (xc's own output, read back).
    bool any_name = false;
    bool generated_ok = false;

    // One form at 'at': the node, or null when it does not read; 'end' is
    // where it ended.
    Expr* read(Form form, int at, bool in_with, int& end);

    // The whole source as one declaration ('local a := 1, b'), or null:
    // what bin/xc reads the line a source stopped at as.
    Declaration* read_declaration();

  private:
    struct Trailer;

    std::string_view src_;
    std::unordered_map<int, int> trans_;
    std::unordered_map<int, UserCmd> cmd_;
    Tree& tree_;
    int n_;
    int p_ = 0;                  // the cursor
    bool user_on_;
    int furthest_ = 0;
    bool past_prologue_ = false; // the body's declarations are over
    bool memvar_ok_ = false;     // a Private's names: 'M->' may come before one
    bool top_level_ = false;     // in a function's own body, not a block's
    std::vector<int> rows_;      // where each line starts, as Raku's .lines splits them
    bool in_with_ = false;       // inside 'with object': ':x' is the subject's
    int in_block_ = 0;           // in a lambda or a code block: no '|>', no 'fallback'
    int in_dq_ = 0;              // in a '"' string's '${ }': no '"' string
    int in_sq_ = 0;
    int in_exp_ = 0;             // in '%exp:...%': a '%' is its end

    // The lines: where each starts, where it ends (its line end, or n), and
    // what it holds that sees() looks for.
    std::vector<int> ls_;
    std::vector<int> le_;
    std::vector<unsigned char> lf_;
    std::vector<int> lq_;        // the last ';' carrying each line on: -1 none, -2 not yet known
    int lk_ = 0;                 // the line line_of() found last

    // The operator op_at() found.
    std::string op_;
    int oplen_ = 0;

    // The byte at p, or -1 outside the source.
    int c(int p) const { return p >= 0 && p < n_ ? static_cast<unsigned char>(src_[p]) : -1; }
    std::string text(int from, int to) const { return std::string(src_.substr(from, to - from)); }
    Expr* back(int at) { p_ = at; return nullptr; }
    template <class T> T* make() { return tree_.make<T>(); }
    Expr* span(Expr* e, int from, int to) { e->from = from; e->to = to; return e; }
    Expr* joined(Binary* b);
    Expr* interval(Expr* lo, Expr* hi);
    Expr* incdec(Expr* target, bool plus, const char* where);
    Expr* assign_expr(Expr* target, const std::string& op, Expr* value);
    Expr* applied(Expr* base, const Trailer& t);
    Expr* trailed(Expr* base, int bf, int bt, const std::vector<Trailer>& trailers, int from, bool outer);

    // Whitespace and the lines.
    bool ws();
    int line_end(int p);
    int line_of(int p);
    int block_end(int p) const;
    int linecont(int p);
    int name_end(int p) const;
    bool iword_at(int p, std::string_view word) const;
    bool stmtword_at(int p) const;
    bool sees(Ahead what, bool item);
    bool continued(int p, int e);
    int last_semi(int p, int e) const;
    bool opnext() const;

    // Values, conditions, guards.
    Expr* value();
    Expr* chained();
    Expr* passign();
    Expr* cond();
    Expr* listitem();
    Expr* guardexpr();

    // Operators.
    Expr* expr();
    Call* feed();
    int op_at();
    Expr* climb(int min, Expr* first, bool in);
    Expr* unary();
    Expr* postfix();
    bool trailer(Trailer& t);
    bool thash(Trailer& t);
    bool tsafe(Trailer& t);
    bool call_args(std::vector<Expr*>& args);
    bool tinalias(Trailer& t);
    bool tfield(Trailer& t);

    // Primaries.
    Expr* primary();
    Expr* parens();
    Expr* selfacc();
    Expr* subjacc();
    Expr* member_call(Expr* base, int start);
    Call* call();
    Call* nscall();
    std::vector<Expr*> arglist();
    Expr* arg();
    Expr* byref();
    Macro* macro();
    Expr* sqlexp();
    Expr* aliasfield();
    Expr* lambda();
    Expr* codeblock();
    Expr* blockexpr();
    Expr* pairs(bool hash);
    KeyValue* kv_pair(bool hash);
    Expr* arrayliteral();

    // Literals.
    Expr* literal();
    int number_end(int p) const;
    int groups(int p) const;
    Expr* string();
    Expr* string_in(int q);

    // Assignments, targets, statements made of a call.
    struct Assign
    {
      Expr* target = nullptr;
      std::string op;
      Expr* value = nullptr;
    };
    bool assignment(Assign& a);
    const char* assignop();
    Expr* lvalue();
    std::vector<Trailer> trailers();
    Expr* callst();
    Expr* pipest();

    // ---- statements (statements.cpp) ----------------------------------------
    int line(int at);
    bool ilit(std::string_view word);
    bool lit(std::string_view s);
    bool word_end() const;
    bool not_within_word() const;
    bool line_start(int p) const { return p == 0 || c(p - 1) == '\n'; }
    int vchar(int p) const;
    int nlchar(int p) const;
    bool eol(bool consume);
    void gap();
    bool nl();
    int linecomment(int p) const;
    int continued_line(int p, bool nl_only) const;

    bool toplevel(Program* prog);
    FunctionDef* function();
    std::vector<Param*> params();
    Param* param();
    ClassDef* classdecl(bool iface);
    bool classmember(ClassDef* cls, bool iface);
    OptStr visib();
    bool datadecl(std::vector<DataMember*>* out);
    MethodImpl* methodimpl();
    MethodImpl* wsmethodimpl();
    MethodImpl* userfunc();
    int usercmd(bool header);
    int preproc();
    bool namespacest(Program* prog);
    External* externalst();
    Declaration* filestatic();
    int wsblock();
    int annotationdef();
    Annotation* annotation();
    std::string name_text(int& end);

    Body funcbody();
    Body body(bool closed, bool with);
    Stmt* statement();
    Stmt* simple();
    bool stmtstart() const;
    bool simpleword() const;
    bool declsoon() const;
    Declaration* declaration();
    Declarator* declarator(bool hdr);
    bool dims(std::vector<Expr*>& out);
    int attrs(int p) const;
    bool typespec(int& from, std::string& typename_text);
    int type_name_end(int p) const;
    bool refused(const std::string& name) const;
    Stmt* ifcallst();
    Stmt* ifst();
    Stmt* whilest();
    Stmt* forst();
    Stmt* forst_with(bool local, bool& took);
    Stmt* forinst();
    Stmt* fortimesst();
    Stmt* docasest();
    Stmt* seqst();
    Stmt* tryst();
    Stmt* transst();
    Stmt* usingst();
    Stmt* withst();
    Stmt* deferst();
    Stmt* execst();
    Stmt* rawst();
    int rawline(int p) const;
    Stmt* cmdst();
    int cmdword(int p) const;
    int textblock(int p, std::string_view open, std::string_view close) const;
    Stmt* dirst();
    Stmt* noopst();
    Stmt* returnst();
    Stmt* breakst();
    Stmt* defaultst();
    Stmt* incst();
    bool incsoon() const;
    Stmt* nilassign();
    bool modifier(std::string& op, Expr*& cond);
    int modkw(int p) const;
    bool if_call(int p) const;
    bool closer(std::string_view one, std::string_view two, bool word_end_two);
    bool next_name(int& from, int& to);
    Expr* addexpr();
    Stmt* assign_stmt();
  };
}
