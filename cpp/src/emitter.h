// xc -- the emitter's insides, shared by emit.cpp (the file, the functions,
// the statements) and lower.cpp (the expressions and the chains).

#pragma once

#include <functional>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "ast.h"
#include "check.h"

namespace xc
{
  using Map = std::unordered_map<std::string, std::string>;
  using Lines = std::vector<std::string>;

  // ---- what is shared by both halves ----------------------------------------
  bool is_expr(const Expr* e, EK k);
  bool is_literal_kind(const Expr* e);
  const Expr* source_call(const Expr* e);
  std::string source_kind(const Expr* src);
  std::string call_name(const std::string& name);
  bool needs_lowering(const Stmt* s);
  std::string chop(const std::string& s);
  std::string attrs_text(const std::vector<std::string>& a);
  std::string note_of(const Declarator* d, const std::string& shown);
  std::string notes_of(const Declaration* d);
  std::string block_local_comment(const Declarator* d, const std::string& shown);
  std::string names_line(const std::string& kw, const Declaration* d);

  class Emitter
  {
  public:
    explicit Emitter(std::string src, bool advpl = false);

    std::string emit(const Program* p);

    // An expression parsed from a piece of text of its own (a raw line's
    // string), rendered with the given renames.
    std::string render_snippet(const Expr* e, const Map& subst);

  private:
    // ---- types --------------------------------------------------------------
    struct Edit
    {
      int from;
      int to;
      std::string text;
    };

    // A statement's place: the bodies down to it -- each the statement that
    // holds it (null: the function's own), which of its bodies, and where in
    // it -- and the loops around it.
    struct Step
    {
      const Stmt* parent;
      int body;
      int index;
    };
    struct Place
    {
      std::vector<Step> path;
      std::vector<const Stmt*> loops;
    };

    struct Defer
    {
      int from = 0;
      Lines lines;
      const Place* at = nullptr;
      std::string flag;              // '' when it needs none
      std::string text;
    };

    struct Closer
    {
      std::string key;               // 'lines', 'using' or 'loop'
      Lines lines;
    };

    struct Renames
    {
      Map head;
      std::vector<Map> bodies;
    };

    struct Hoist
    {
      std::string name;
      std::string comment;
      std::string value;
    };

    // A chain as a loop: the text of its result, and the lines.
    struct Stream
    {
      std::string result;
      Lines lines;
    };

    // A statement lowered: whether it opens a block, and its lines.
    struct Lowered
    {
      bool block;
      Lines lines;
    };

    struct ExprEdit
    {
      int from;
      int to;
      std::string text;
      std::string comment;
    };

    // ---- state --------------------------------------------------------------
    std::string src_;
    bool advpl_;
    std::string nl_;
    std::vector<Edit> edits_;
    std::unordered_set<std::string> used_;
    std::unordered_set<std::string> slots_;
    std::unordered_map<std::string, Lines> slot_users_;
    std::vector<Hoist> hoist_;
    std::unordered_set<std::string> hoisted_;
    Map subst_;
    Map field_;
    std::vector<Closer> closers_;
    std::vector<Defer> defers_;
    std::unordered_map<const Stmt*, Place> paths_;
    std::unordered_set<std::string> declared_;
    std::unordered_set<const Stmt*> done_;
    Lines subjects_;
    std::unordered_map<const Stmt*, Renames> renames_;
    bool chains_ = false;
    // Temps: an expression that reads a value twice holds it in a Local --
    // not in a snippet, whose Locals would be lost, nor in a 'static', which
    // runs before any. In a declaration of the prologue the Locals go just
    // before it (early_at_ where it starts), in the order made. pool_: the
    // temps of each kind, to be used again; busy_: those the statement holds.
    bool snippet_ = false;
    int no_temps_ = 0;
    int in_block_ = 0;
    int early_at_ = -1;
    std::map<int, Lines> early_;
    std::unordered_set<std::string> early_names_;
    std::unordered_map<std::string, Lines> pool_;
    std::unordered_set<std::string> busy_;
    // The names the function declares with a type ('as N'), which TL++ will
    // not compare with Nil.
    std::unordered_set<std::string> typed_;
    // The bodies of 'with object', a level less deep, the lines that made the
    // level gone: the lines from 'from' up to 'to', and how many characters of
    // indentation they lose.
    struct Dedent
    {
      int from;
      int to;
      int by;
    };
    std::vector<Dedent> dedents_;
    // The indentation of the function's body: its first statement's, or two
    // blanks when that is the 'return' that ends it.
    std::string body_indent_;
    // Verbs written as calls, as the chains they are (as_chain): xc's own
    // Pipelines, made once each.
    mutable Tree made_;
    mutable std::unordered_map<const Expr*, const Expr*> chains_made_;

    // ---- lines --------------------------------------------------------------
    int line_start(int p) const;
    int line_end(int p) const;
    int after_break(int e) const;
    std::string indent_at(int p) const;
    int dedent_at(int p) const;
    void dedent_edits();
    int comment_col(int from, int to) const;
    std::string before_comment(int from, int to) const;
    void align_comments(const Body& body);
    std::string join_at(int p, const Lines& lines) const;
    template <class N> std::string slice(const N* n) const
    {
      return src_.substr(static_cast<std::size_t>(n->from), static_cast<std::size_t>(n->to - n->from));
    }
    std::string text(int from, int to) const
    {
      return src_.substr(static_cast<std::size_t>(from), static_cast<std::size_t>(to - from));
    }
    void edit(int from, int to, std::string t) { edits_.push_back(Edit{ from, to, std::move(t) }); }
    bool declared(const std::string& n) const { return declared_.count(n) > 0; }
    std::function<bool(const std::string&)> declared_fn() const
    {
      return [this](const std::string& n) { return declared(n); };
    }

    // ---- what is not lowered yet --------------------------------------------
    std::vector<Finding> not_lowered(const Program* p);
    std::vector<Finding> scope_problems(const Body& body);
    std::vector<Finding> chain_problems(const Expr* chain, const Stmt* s);
    bool fusable_array(const Expr* e, bool for_effect) const;
    const Expr* as_chain(const Expr* e) const;
    const Expr* fused_value(const Stmt* s) const;
    bool loop_value(const Expr* e) const;
    const Expr* stream_value(const Stmt* s) const;
    std::vector<const Expr*> stream_values(const Stmt* s) const;
    bool is_lambda(const Expr* e) const;
    bool is_function_name(const std::string& verb, const Expr* e) const;
    bool record_misused(const Lambda* l) const;

    // ---- the functions ------------------------------------------------------
    void param_attributes(const std::vector<Param*>& params);
    void function(const std::vector<Param*>& params, const Body& body);
    void declare_names(const std::vector<Param*>& params, const Body& body);
    void plan_renames(const std::vector<Param*>& params, const Body& body);
    std::string nm(const Stmt* s, const std::string& name) const;
    std::string local(const std::string& name) const;
    void collect_bodies(const Stmt* s);
    void hoist(const std::string& name, const std::string& comment, const std::string& value = "");
    std::string gen(const std::string& kind, const std::string& comment, const std::string& value = "");
    bool temps_ok() const { return !snippet_ && no_temps_ == 0; }
    bool plain_name(const Expr* e) const;
    std::string temp(const std::string& kind, const std::string& comment);
    void hoist_edit(const Body& body);

    // ---- statements ---------------------------------------------------------
    void collect(const Body& body, bool top);
    Lines return_exits(const Stmt* s);
    std::string defer_at(const Defer& d, const Stmt* r);
    Lines guarded(const Defer& d) const;
    void place_statements(const Body& body);
    Lines jump_exits() const;
    Lines stmt_lines(const Stmt* s);
    void drop_closer(const Stmt* s, std::string_view word);
    void drop_endname(int from, int to);
    std::string raw_text(const std::string& t);
    std::string raw_string(const std::string& str);
    void replace(const Stmt* s, bool block, Lines lines, const Lines& notes = {});
    void header(const Stmt* s, const Expr* last, std::size_t at, Lines lines);
    void header_to(const Stmt* s, int end, std::size_t at, Lines lines);
    void expressions(const std::vector<Expr*>& exprs);
    std::vector<ExprEdit> expr_edits(const std::vector<Expr*>& exprs);
    Lowered lower(const Stmt* s);
    Lines lower_inner(const Stmt* s);

    // ---- chains -------------------------------------------------------------
    Stream stream(const Expr* chain, bool collect);
    std::string calls(const std::string& text, const std::vector<Call*>& stages);
    Stream walk_chain(const Expr* call, const std::optional<std::string>& over, const std::vector<Call*>& stages,
                      bool collect);
    std::string range_end(const Expr* e, const std::string& kind, const std::string& comment, Lines& setup);
    std::string bound(const Lambda* l, const std::optional<std::string>& elem, const std::optional<std::string>& prefix);
    std::string bound2(const Lambda* l, const std::string& carried, const std::string& element);
    Lines init_lines(const std::string& name, const Expr* value);
    const Guard* guard_value(const Stmt* s) const;
    Lines guard_stmt(const Stmt* s, const Guard* g);
    Lines sequence_lines(const std::string& target, const Guard* g);

    // ---- expressions --------------------------------------------------------
    std::string expr(const Expr* e);
    bool lowers_itself(const Expr* e) const;
    bool contains_lowering(const Expr* e) const;
    std::string interpolated(const Interp* i);
    std::string safe(const Expr* base, const std::string& tail);
    std::string safe_chain(const Expr* e);
    void safe_steps(const Expr* e, Lines& conds, std::string& value);
    Lowered hash_set(const Assignment* a);
    std::string block_arg(const std::string& verb, const Expr* e);
    std::string part(const Expr* e);
    template <class N> std::string with_edits(const N* node, const std::vector<Expr*>& exprs);
  };
}
