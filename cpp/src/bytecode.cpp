// xc -- a program as bytecode (see bytecode.h, and docs/bytecode.md for the
// instructions).
//
// Each function is compiled to a list of instructions, its jumps to labels;
// what it is written as comes at the end, when it is known which of its
// locals a code block shares -- those become cells (a 'box' at the start,
// 'cell' for 'local') -- and where each label is.

#include "bytecode.h"

#include <algorithm>
#include <deque>
#include <functional>
#include <memory>
#include <optional>
#include <unordered_map>
#include <unordered_set>

#include "chains.h"
#include "chars.h"
#include "decimal.h"
#include "parser.h"
#include "text.h"
#include "walk.h"

namespace xc
{
  NotBytecode::NotBytecode(std::vector<Finding> found)
    : std::runtime_error("cannot become bytecode yet"), problems(std::move(found))
  {
  }

  namespace
  {
    // ---- a function's instructions ------------------------------------------
    struct Ins
    {
      std::string op;
      std::string arg;               // the words after it; a string's text
      bool str = false;              // arg is a string, written in quotes
      int target = -1;               // the label a jump goes to
      int local = -1;                // the local it names, from 0
    };

    enum class Sym { Local, Static, Memvar };
    struct Entry
    {
      Sym kind;
      int index;
    };
    using Scope = std::unordered_map<std::string, Entry>;

    // A cell a code block shares: its function's local, or a cell of the
    // block around it.
    struct Upval
    {
      bool from_local;
      int index;
      std::string name;
    };

    // What a way out of a construct -- an 'exit', a 'loop', a 'return' --
    // does on the way: end its region, or put back what it changed.
    struct Exit
    {
      enum Kind { Region, Restore } kind;
      std::function<void()> run;
    };

    struct Loop
    {
      int brk;
      int cont;
      std::size_t exits;             // how many exits are around the loop
    };

    struct Fn
    {
      std::string name;
      std::string kind;
      int params = 0;
      std::vector<std::string> names;
      std::vector<bool> captured;
      std::vector<Ins> code;
      std::vector<int> labels;
      Fn* parent = nullptr;          // a block's: the function that makes it
      std::vector<Upval> upvals;
      std::vector<Scope> scopes;
      std::vector<Loop> loops;
      std::vector<Exit> exits;
      int line = -1;
      int temps = 0;
      int number = 0;                // a block's
      int made_count = 0;            // a function's: its blocks, in the order made
      std::vector<Fn*> made;
      bool defers = false;           // it has a 'defer': each return runs them
      struct Deferred
      {
        int label;
        const Stmt* stmt;
        std::vector<Scope> scopes;
        std::vector<std::pair<Fn*, int>> subjects;
      };
      std::vector<Deferred> deferred;
    };

    // What a name is where it is read.
    struct Var
    {
      enum Kind { Local, Upval, Static, Memvar, Define, Crlf } kind = Memvar;
      int index = -1;
      std::string name;              // a memvar's, in upper case; a #define's
      bool declared = false;         // a memvar a Private or a Public declares
    };

    enum class Want { None, New, Old };

    // Where an assignment writes: what it pushes first (the array and the
    // index, the object...), how it reads the value there without taking
    // them, and how it writes it, taking them.
    struct Target
    {
      int operands = 0;
      std::function<void()> push;
      std::function<void()> read;
      std::function<void()> write;
    };

    bool is(const Expr* e, EK k) { return e && e->kind == k; }

    const std::string& name_of(const Expr* e) { return static_cast<const Name*>(e)->name; }

    std::string arith_op(const std::string& op)
    {
      if (op == "+") { return "add"; }
      if (op == "-") { return "sub"; }
      if (op == "*") { return "mul"; }
      if (op == "/") { return "div"; }
      if (op == "%") { return "mod"; }
      return "pow";
    }

    std::string compare_op(const std::string& op)
    {
      if (op == "=") { return "eq"; }
      if (op == "==") { return "exact"; }
      if (op == "!=" || op == "<>" || op == "#") { return "ne"; }
      if (op == "<") { return "lt"; }
      if (op == ">") { return "gt"; }
      if (op == "<=") { return "le"; }
      if (op == ">=") { return "ge"; }
      return "contains";
    }

    bool compound(const std::string& op) { return op == "+=" || op == "-=" || op == "*=" || op == "/=" || op == "%="; }

    // A number literal's text as the machine reads it: no digit separators,
    // a digit before its point.
    std::string number_text(const std::string& t)
    {
      std::string out;
      for (char c : t)
      {
        if (c != '\'') { out += c; }
      }
      if (!out.empty() && out[0] == '.') { out = "0" + out; }
      return out;
    }

    // A string literal's text, without its quotes -- one the line ended has
    // none at its end.
    std::string string_text(const std::string& t)
    {
      if (t.empty()) { return t; }
      std::string s = t.substr(1);
      if (!s.empty() && s.back() == t[0]) { s.pop_back(); }
      return s;
    }

    bool name_or_literal(const Expr* e) { return is(e, EK::Name) || is(e, EK::Literal); }

    // ---- the compiler -------------------------------------------------------
    class Compiler
    {
    public:
      Compiler(const Program* p, std::string_view src, bool advpl, std::string source)
        : p_(p), src_(src), advpl_(advpl), source_(std::move(source))
      {
      }

      std::string run();

    private:
      const Program* p_;
      std::string_view src_;
      bool advpl_;
      std::string source_;
      std::vector<std::string> statics_;
      Scope file_;
      struct Define
      {
        const Expr* body = nullptr;
        bool params = false;
        bool read = false;           // its value reads as an expression
      };
      std::unordered_map<std::string, Define> defines_;
      std::unordered_set<std::string> expanding_;
      std::deque<std::string> texts_;
      Tree tree_;
      Decimals dec_;
      DecimalValues dv_;
      const Expr* unwrapped_ = nullptr;
      std::vector<std::unique_ptr<Fn>> fns_;
      std::vector<Fn*> order_;
      std::vector<Finding> problems_;
      Fn* f_ = nullptr;
      Fn* init_ = nullptr;
      Fn* top_ = nullptr;
      int line_ = 0;
      std::vector<std::pair<Fn*, int>> subjects_;

      // ---- emitting ---------------------------------------------------------
      void op(const std::string& o, const std::string& arg = "")
      {
        Ins i;
        i.op = o;
        i.arg = arg;
        f_->code.push_back(std::move(i));
      }
      void num(int n) { op("num", std::to_string(n)); }
      void str(const std::string& t)
      {
        Ins i;
        i.op = "str";
        i.arg = t;
        i.str = true;
        f_->code.push_back(std::move(i));
      }
      void jump(const std::string& o, int label, const std::string& arg = "")
      {
        Ins i;
        i.op = o;
        i.arg = arg;
        i.target = label;
        f_->code.push_back(std::move(i));
      }
      void on_local(const std::string& o, int local)
      {
        Ins i;
        i.op = o;
        i.local = local;
        f_->code.push_back(std::move(i));
      }
      void call(std::size_t argc, const std::string& name) { op("call", std::to_string(argc) + " " + name); }
      int label()
      {
        f_->labels.push_back(-1);
        return static_cast<int>(f_->labels.size()) - 1;
      }
      void place(int l) { f_->labels[static_cast<std::size_t>(l)] = static_cast<int>(f_->code.size()); }
      int add_local(Fn* g, const std::string& name)
      {
        g->names.push_back(name);
        g->captured.push_back(false);
        return static_cast<int>(g->names.size()) - 1;
      }
      int temp() { return add_local(f_, ".t" + std::to_string(++f_->temps)); }
      void problem(const std::string& what) { problems_.push_back({ line_, what }); }
      // A line said where nothing has run since the last one said replaces
      // it -- unless a jump goes to that one.
      void force_line(int n)
      {
        if (n <= 0) { return; }
        int last = static_cast<int>(f_->code.size()) - 1;
        if (last >= 0 && f_->code.back().op == "line"
            && std::find(f_->labels.begin(), f_->labels.end(), last) == f_->labels.end())
        {
          f_->code.back().arg = std::to_string(n);
        }
        else
        {
          op("line", std::to_string(n));
        }
        f_->line = n;
      }
      void line(int n)
      {
        if (n > 0 && n != f_->line) { force_line(n); }
      }
      // The top of a loop, where its line is said again: a jump back to it
      // comes from the body's last line.
      void loop_top(int top, int n)
      {
        if (!f_->code.empty() && f_->code.back().op == "line" && f_->code.back().arg == std::to_string(n))
        {
          f_->labels[static_cast<std::size_t>(top)] = static_cast<int>(f_->code.size()) - 1;
          return;
        }
        place(top);
        force_line(n);
      }

      // ---- names ------------------------------------------------------------
      Var resolve(const std::string& name);
      Var local_of(Fn* owner, int index);
      int upval(Fn* f, Fn* owner, int index);
      int declare(const std::string& name);
      bool variable(const Var& v) const
      {
        return v.kind == Var::Local || v.kind == Var::Upval || v.kind == Var::Static
               || (v.kind == Var::Memvar && v.declared) || v.kind == Var::Define;
      }
      void load(const Var& v);
      void store(const Var& v);
      void ref(const Var& v);
      void subject();

      // ---- expressions ------------------------------------------------------
      void expr(const Expr* e);
      void effect(const Expr* e);
      void literal(const Literal* l);
      void binary(const Binary* b);
      void call_expr(const Call* c);
      void arg(const Expr* a);
      void block_arg(const std::string& verb, const Expr* a);
      void name_block(const std::string& fname);
      void block(const CodeBlock* b);
      void member_base(const Expr* base);
      void safe(const Expr* base, const std::function<void()>& rest);
      void alias_field(const AliasField* a);
      void in_area(const std::function<void()>& alias, const std::function<void()>& body);
      void pairs(const std::vector<KeyValue*>& ps, bool hash);
      void pipeline(const Pipeline* p);
      std::optional<Target> target_of(const Expr* t);
      void assign(const Expr* t, const std::string& o, const Expr* value, Want want, const std::string& incdec);
      void operand(const Expr* t, const std::string& o, const Expr* value, const std::string& incdec);
      void nil_assign(const Expr* t, const Expr* value);
      bool fused(const Expr* v, bool for_effect);
      bool fused_stmt(const Stmt* s);
      void dims(const std::vector<Expr*>& ds);
      bool start(const Declarator* v);

      // ---- Decimals ---------------------------------------------------------
      bool lowered_decimal(const Expr* e) const;
      void decimal_expr(const Expr* e);
      void as_decimal(const Expr* e);
      void dec_literal(const std::string& text);

      // ---- statements -------------------------------------------------------
      void stmt(const Stmt* s);
      void statements(const Body& b);
      void block_body(const Body& b);
      void declaration(const Declaration* d);
      void static_value(const Declarator* v, Scope& into);
      void local_header(const Declarator* d);
      void if_stmt(const IfStmt* s);
      void case_stmt(const CaseStmt* s);
      void while_stmt(const WhileStmt* s);
      void for_stmt(const ForStmt* s);
      void for_in(const ForInStmt* s);
      void for_times(const ForTimesStmt* s);
      void modified(const Modified* m);
      void using_alias(const UsingAlias* u);
      void try_stmt(const TryStmt* t);
      void sequence(const SequenceStmt* s);
      void return_stmt(const ReturnStmt* r);
      void jump_out(bool exit);
      void run_exits(std::size_t down_to, bool regions);

      // ---- the file ---------------------------------------------------------
      int line_of(std::string_view text) const;
      void directives();
      void function(const std::string& name, const std::string& kind, const std::vector<Param*>& params,
                    const Body& body, const OptStr& returns);
      void finish();
      std::string written(const Fn& f) const;
    };

    // ---- names --------------------------------------------------------------
    // A name, from the function compiled out: a local of it or of a function
    // around it (a block's), a static, a variable a Private or a Public
    // declares; then the file's statics, its #defines, CRLF; anything else is
    // a memvar.
    Var Compiler::resolve(const std::string& name)
    {
      std::string k = lc(name);
      for (Fn* g = f_; g; g = g->parent)
      {
        for (auto s = g->scopes.rbegin(); s != g->scopes.rend(); ++s)
        {
          auto it = s->find(k);
          if (it == s->end()) { continue; }
          const Entry& e = it->second;
          if (e.kind == Sym::Static) { return Var{ Var::Static, e.index, "", false }; }
          if (e.kind == Sym::Memvar) { return Var{ Var::Memvar, -1, uc(name), true }; }
          return local_of(g, e.index);
        }
      }
      if (auto it = file_.find(k); it != file_.end()) { return Var{ Var::Static, it->second.index, "", false }; }
      if (auto d = defines_.find(k); d != defines_.end() && !d->second.params)
      {
        return Var{ Var::Define, -1, k, false };
      }
      if (k == "crlf") { return Var{ Var::Crlf, -1, "", false }; }
      return Var{ Var::Memvar, -1, uc(name), false };
    }

    Var Compiler::local_of(Fn* owner, int index)
    {
      if (owner == f_) { return Var{ Var::Local, index, "", false }; }
      return Var{ Var::Upval, upval(f_, owner, index), "", false };
    }

    // The cell of f that is owner's local: a block's cell, made of its
    // maker's local or of a cell of the block around it.
    int Compiler::upval(Fn* f, Fn* owner, int index)
    {
      Upval u;
      if (f->parent == owner)
      {
        owner->captured[static_cast<std::size_t>(index)] = true;
        u = Upval{ true, index, owner->names[static_cast<std::size_t>(index)] };
      }
      else
      {
        int j = upval(f->parent, owner, index);
        u = Upval{ false, j, f->parent->upvals[static_cast<std::size_t>(j)].name };
      }
      for (std::size_t i = 0; i < f->upvals.size(); i++)
      {
        if (f->upvals[i].from_local == u.from_local && f->upvals[i].index == u.index) { return static_cast<int>(i); }
      }
      f->upvals.push_back(u);
      return static_cast<int>(f->upvals.size()) - 1;
    }

    // A local declared in the innermost scope. One the function declared
    // already at its own level is the same variable.
    int Compiler::declare(const std::string& name)
    {
      std::string k = lc(name);
      Scope& s = f_->scopes.back();
      if (f_->scopes.size() == 1)
      {
        auto it = s.find(k);
        if (it != s.end() && it->second.kind == Sym::Local) { return it->second.index; }
      }
      int i = add_local(f_, name);
      s[k] = Entry{ Sym::Local, i };
      return i;
    }

    void Compiler::load(const Var& v)
    {
      switch (v.kind)
      {
        case Var::Local: on_local("local", v.index); break;
        case Var::Upval: op("upval", std::to_string(v.index + 1)); break;
        case Var::Static: op("static", std::to_string(v.index + 1)); break;
        case Var::Memvar: op("memvar", v.name); break;
        case Var::Define:
        {
          // Its value, compiled where it is read.
          const Define& d = defines_.at(v.name);
          if (!d.read || expanding_.count(v.name))
          {
            problem("'" + v.name + "', a #define whose value " + (d.read ? "names itself" : "is no expression"));
            op("nil");
          }
          else if (!d.body) { op("nil"); }
          else
          {
            expanding_.insert(v.name);
            expr(d.body);
            expanding_.erase(v.name);
          }
          break;
        }
        case Var::Crlf:
          num(13);
          call(1, "Chr");
          num(10);
          call(1, "Chr");
          op("add");
          break;
      }
    }

    void Compiler::store(const Var& v)
    {
      switch (v.kind)
      {
        case Var::Local: on_local("setlocal", v.index); break;
        case Var::Upval: op("setupval", std::to_string(v.index + 1)); break;
        case Var::Static: op("setstatic", std::to_string(v.index + 1)); break;
        case Var::Memvar: op("setmemvar", v.name); break;
        default:
          problem("an assignment to a #define");
          op("pop");
          break;
      }
    }

    void Compiler::ref(const Var& v)
    {
      switch (v.kind)
      {
        case Var::Local: on_local("reflocal", v.index); break;
        case Var::Upval: op("refupval", std::to_string(v.index + 1)); break;
        case Var::Static: op("refstatic", std::to_string(v.index + 1)); break;
        case Var::Memvar: op("refmemvar", v.name); break;
        default:
          problem("'@' before a #define");
          op("nil");
          break;
      }
    }

    // ':x' inside 'with object': the innermost subject, a local of the
    // function that holds the block -- a code block in it shares it.
    void Compiler::subject()
    {
      if (subjects_.empty())
      {
        problem("':' outside 'with object'");
        op("nil");
        return;
      }
      load(local_of(subjects_.back().first, subjects_.back().second));
    }

    // ---- expressions --------------------------------------------------------
    void Compiler::expr(const Expr* e)
    {
      if (!e || e->kind == EK::Omitted)
      {
        op("nil");
        return;
      }
      if (lowered_decimal(e))
      {
        decimal_expr(e);
        return;
      }
      switch (e->kind)
      {
        case EK::Literal:
          literal(static_cast<const Literal*>(e));
          return;
        case EK::Name:
          load(resolve(name_of(e)));
          return;
        case EK::UserTrans:
          problem("'" + static_cast<const UserTrans*>(e)->text + "', a translation of the source's own");
          op("nil");
          return;
        case EK::Call:
          call_expr(static_cast<const Call*>(e));
          return;
        case EK::Binary:
          binary(static_cast<const Binary*>(e));
          return;
        case EK::Index:
        {
          auto x = static_cast<const Index*>(e);
          expr(x->base);
          for (const Expr* i : x->indices)
          {
            expr(i);
            op("index");
          }
          return;
        }
        case EK::SelfRef:
          op("self");
          return;
        case EK::SubjectRef:
          subject();
          return;
        case EK::Member:
        {
          auto m = static_cast<const Member*>(e);
          member_base(m->base);
          op("member", m->name);
          return;
        }
        case EK::SafeMember:
        {
          auto m = static_cast<const Member*>(e);
          safe(m->base, [&] { op("member", m->name); });
          return;
        }
        case EK::HashIndex:
        {
          auto h = static_cast<const HashIndex*>(e);
          expr(h->base);
          expr(h->key);
          call(2, "u_xtpl_hget");
          return;
        }
        case EK::Interval:
          problem("a range 'lo..hi' -- one is read after 'in', at the head of a chain and as what 'for ... in' walks");
          op("nil");
          return;
        case EK::MethodCall:
        {
          auto m = static_cast<const MethodCall*>(e);
          member_base(m->base);
          for (const Expr* a : m->args) { arg(a); }
          op("method", std::to_string(m->args.size()) + " " + m->name);
          return;
        }
        case EK::SafeCall:
        {
          auto m = static_cast<const MethodCall*>(e);
          safe(m->base, [&]
          {
            for (const Expr* a : m->args) { arg(a); }
            op("method", std::to_string(m->args.size()) + " " + m->name);
          });
          return;
        }
        case EK::AliasField:
          alias_field(static_cast<const AliasField*>(e));
          return;
        case EK::InAlias:
        {
          auto in = static_cast<const InAlias*>(e);
          std::function<void()> alias = in->alias ? std::function<void()>([this, in] { str(*in->alias); })
                                                  : std::function<void()>([this, in] { expr(in->base); });
          in_area(alias, [&] { expr(in->expr); });
          return;
        }
        case EK::Macro:
        {
          auto m = static_cast<const Macro*>(e);
          expr(m->target);
          if (m->called)
          {
            for (const Expr* a : m->args) { arg(a); }
            op("callx", std::to_string(m->args.size()));
          }
          else
          {
            op("macro");
          }
          return;
        }
        case EK::Ref:
          expr(static_cast<const Ref*>(e)->target);
          return;
        case EK::ExprList:
        {
          // '(a, b, c)': each in turn, the last the value; '%exp:x%' is one.
          auto l = static_cast<const ExprList*>(e);
          for (std::size_t i = 0; i + 1 < l->items.size(); i++) { effect(l->items[i]); }
          expr(l->items.empty() ? nullptr : l->items.back());
          return;
        }
        case EK::AssignExpr:
        {
          auto a = static_cast<const AssignExpr*>(e);
          assign(a->target, a->op, a->value, a->incdec == "post" ? Want::Old : Want::New, a->incdec);
          return;
        }
        case EK::ArrayLit:
        {
          auto a = static_cast<const ArrayLit*>(e);
          for (const Expr* x : a->items) { expr(x); }
          op("array", std::to_string(a->items.size()));
          return;
        }
        case EK::Interp:
        {
          // A sum of strings: the text as it is, each value its cValToChar().
          bool first = true;
          for (const Part& p : static_cast<const Interp*>(e)->parts)
          {
            if (auto x = std::get_if<Expr*>(&p))
            {
              expr(*x);
              call(1, "cValToChar");
            }
            else if (!std::get<std::string>(p).empty())
            {
              str(std::get<std::string>(p));
            }
            else
            {
              continue;
            }
            if (!first) { op("add"); }
            first = false;
          }
          if (first) { str(""); }
          return;
        }
        case EK::JsonLit:
          pairs(static_cast<const JsonLit*>(e)->pairs, false);
          return;
        case EK::HashLit:
          pairs(static_cast<const HashLit*>(e)->pairs, true);
          return;
        case EK::CodeBlock:
        case EK::Lambda:
          block(static_cast<const CodeBlock*>(e));
          return;
        case EK::Guard:
        {
          // As TL++ has it: the error block one that breaks, a sequence
          // around the value -- an error, or a Break, gives the alternative
          // -- and the error block put back.
          auto g = static_cast<const Guard*>(e);
          int kept = temp();
          int caught = label();
          int end = label();
          name_block("Break");
          call(1, "ErrorBlock");
          on_local("setlocal", kept);
          jump("seq", caught);
          expr(g->expr);
          op("endseq");
          jump("jump", end);
          place(caught);
          op("pop");
          expr(g->fallback);
          place(end);
          on_local("local", kept);
          call(1, "ErrorBlock");
          op("pop");
          return;
        }
        case EK::Pipeline:
          pipeline(static_cast<const Pipeline*>(e));
          return;
        default:
          return;
      }
    }

    // An expression for what it does: an assignment wants no value back.
    void Compiler::effect(const Expr* e)
    {
      if (is(e, EK::AssignExpr) && !lowered_decimal(e))
      {
        auto a = static_cast<const AssignExpr*>(e);
        assign(a->target, a->op, a->value, Want::None, a->incdec);
        return;
      }
      expr(e);
      op("pop");
    }

    void Compiler::literal(const Literal* l)
    {
      if (l->type == "Numeric") { op("num", number_text(l->text)); }
      else if (l->type == "Character") { str(string_text(l->text)); }
      else if (l->type == "Logical") { op(l->text.size() > 1 && lower(static_cast<unsigned char>(l->text[1])) == 't' ? "true" : "false"); }
      else { op("nil"); }
    }

    void Compiler::binary(const Binary* b)
    {
      const std::string& o = b->op;
      if (o == ".and." || o == ".or.")
      {
        int end = label();
        expr(b->left);
        jump(o == ".and." ? "andjump" : "orjump", end);
        expr(b->right);
        place(end);
        return;
      }
      if (o == "!" || o == "neg")
      {
        expr(b->right);
        op(o == "!" ? "not" : "neg");
        return;
      }
      if (o == "in")
      {
        if (is(b->right, EK::Interval))
        {
          // 'x in lo..hi': both ends, x read once.
          auto r = static_cast<const Interval*>(b->right);
          int end = label();
          std::function<void()> x;
          if (name_or_literal(b->left))
          {
            x = [this, b] { expr(b->left); };
          }
          else
          {
            int t = temp();
            expr(b->left);
            on_local("setlocal", t);
            x = [this, t] { on_local("local", t); };
          }
          x();
          expr(r->lo);
          op("ge");
          jump("andjump", end);
          x();
          expr(r->hi);
          op("le");
          place(end);
          return;
        }
        expr(b->left);
        expr(b->right);
        call(2, "u_xtpl_in");
        return;
      }
      if (o == "has")
      {
        expr(b->left);
        expr(b->right);
        call(2, "u_xtpl_hhas");
        return;
      }
      if (o == "%%")
      {
        expr(b->left);
        expr(b->right);
        op("mod");
        num(0);
        op("exact");
        return;
      }
      if (o == "?:")
      {
        // A literal is Nil or never is: the side it picks.
        if (is(b->left, EK::Literal))
        {
          expr(static_cast<const Literal*>(b->left)->type == "Variant" ? b->right : b->left);
          return;
        }
        int end = label();
        expr(b->left);
        op("dup");
        op("isnil");
        jump("jumpf", end);
        op("pop");
        expr(b->right);
        place(end);
        return;
      }
      expr(b->left);
      expr(b->right);
      op(arithmetic(o) ? arith_op(o) : compare_op(o));
    }

    void Compiler::call_expr(const Call* c)
    {
      std::string n = lc(c->name);
      if ((n == "iif" || n == "if") && c->args.size() == 3)
      {
        // Only the branch taken is evaluated.
        int other = label();
        int end = label();
        expr(c->args[0]);
        jump("jumpf", other);
        expr(c->args[1]);
        jump("jump", end);
        place(other);
        expr(c->args[2]);
        place(end);
        return;
      }
      if (auto d = defines_.find(n); d != defines_.end() && d->second.params)
      {
        problem("'" + c->name + "()', a #define with parameters");
        op("nil");
        return;
      }
      bool verb = is_runtime_verb(c->name);
      if (verb && !c->args.empty() && is_source(c->args[0]))
      {
        problem("a walk over rows(), lines() or a range");
        op("nil");
        return;
      }
      for (std::size_t i = 0; i < c->args.size(); i++)
      {
        if (verb && i > 0) { block_arg(n, c->args[i]); }
        else { arg(c->args[i]); }
      }
      call(c->args.size(), verb ? "u_xtpl_" + n : c->name);
    }

    // An argument: left out, Nil; '@x', a reference to x.
    void Compiler::arg(const Expr* a)
    {
      if (is(a, EK::Ref))
      {
        const Expr* t = static_cast<const Ref*>(a)->target;
        if (is(t, EK::Name))
        {
          ref(resolve(name_of(t)));
          return;
        }
        auto f = static_cast<const AliasField*>(t);
        if (is(t, EK::AliasField) && f->alias && !f->macro && (uc(*f->alias) == "M" || uc(*f->alias) == "MEMVAR"))
        {
          op("refmemvar", uc(f->field));
          return;
        }
        problem("'@' before what is not a variable -- an element, a member");
        op("nil");
        return;
      }
      expr(a);
    }

    // An argument of a verb that takes a block: a bare name that is not a
    // variable is the function of that name.
    void Compiler::block_arg(const std::string& verb, const Expr* a)
    {
      if (takes_block(verb) && is(a, EK::Name) && !variable(resolve(name_of(a))))
      {
        name_block(name_of(a));
        return;
      }
      arg(a);
    }

    // '{|__it| f(__it)}'.
    void Compiler::name_block(const std::string& fname)
    {
      auto fn = std::make_unique<Fn>();
      Fn* g = fn.get();
      g->number = ++top_->made_count;
      g->name = top_->name + "#" + std::to_string(g->number);
      g->kind = "block";
      g->params = 1;
      g->parent = f_;
      fns_.push_back(std::move(fn));
      top_->made.push_back(g);
      add_local(g, "__it");
      Fn* was = f_;
      f_ = g;
      force_line(was->line);
      on_local("local", 0);
      call(1, fname);
      op("ret");
      f_ = was;
      op("block", g->name + " 0");
    }

    // A code block, a lambda: a function of its own, which the cells it
    // shares are given to when it is made.
    void Compiler::block(const CodeBlock* b)
    {
      auto fn = std::make_unique<Fn>();
      Fn* g = fn.get();
      g->number = ++top_->made_count;
      g->name = top_->name + "#" + std::to_string(g->number);
      g->kind = "block";
      g->params = static_cast<int>(b->params.size());
      g->parent = f_;
      fns_.push_back(std::move(fn));
      top_->made.push_back(g);
      g->scopes.emplace_back();
      // A name given to two parameters is the last of them.
      for (const std::string& p : b->params)
      {
        int i = add_local(g, p);
        g->scopes.back()[lc(p)] = Entry{ Sym::Local, i };
      }
      Fn* was = f_;
      f_ = g;
      force_line(was->line);
      if (b->body.empty()) { op("nil"); }
      for (std::size_t i = 0; i < b->body.size(); i++)
      {
        if (i + 1 < b->body.size()) { effect(b->body[i]); }
        else { expr(b->body[i]); }
      }
      op("ret");
      f_ = was;
      for (const Upval& u : g->upvals)
      {
        if (u.from_local) { on_local("reflocal", u.index); }
        else { op("refupval", std::to_string(u.index + 1)); }
      }
      op("block", g->name + " " + std::to_string(g->upvals.size()));
    }

    void Compiler::member_base(const Expr* base)
    {
      if (is(base, EK::SubjectRef)) { subject(); }
      else { expr(base); }
    }

    // 'o?.x', 'o?.m()': Nil when o is -- but ':x?.y' inside 'with object' is
    // a plain ':'.
    void Compiler::safe(const Expr* base, const std::function<void()>& rest)
    {
      if (is(base, EK::SubjectRef))
      {
        subject();
        rest();
        return;
      }
      int end = label();
      expr(base);
      op("dup");
      op("isnil");
      jump("jumpt", end);
      rest();
      place(end);
    }

    // 'SA1->A1_NOME', '(cAlias)->A1_NOME', 'M->nX'; a field named by a macro
    // is FieldGet() in the area.
    void Compiler::alias_field(const AliasField* a)
    {
      if (a->macro)
      {
        const Expr* name = static_cast<const Macro*>(a->macro)->target;
        std::function<void()> alias = a->alias ? std::function<void()>([this, a] { str(*a->alias); })
                                               : std::function<void()>([this, a] { expr(a->base); });
        in_area(alias, [&]
        {
          expr(name);
          call(1, "FieldPos");
          call(1, "FieldGet");
        });
        return;
      }
      if (a->alias)
      {
        std::string al = uc(*a->alias);
        if (al == "M" || al == "MEMVAR") { op("memvar", uc(a->field)); }
        else { op("field", al + " " + uc(a->field)); }
        return;
      }
      expr(a->base);
      op("fieldx", uc(a->field));
    }

    // What runs in an area, 'SA1->(...)': the area selected, the body, and
    // the area selected before selected again.
    void Compiler::in_area(const std::function<void()>& alias, const std::function<void()>& body)
    {
      alias();
      op("area");
      body();
      op("endarea");
    }

    // A hash, a JSON object: the runtime's, made of {key, value} pairs.
    void Compiler::pairs(const std::vector<KeyValue*>& ps, bool hash)
    {
      if (ps.empty())
      {
        call(0, hash ? "THashMap" : "JsonObject");
        op("method", "0 New");
        return;
      }
      for (const KeyValue* kv : ps)
      {
        expr(kv->key);
        expr(kv->value);
        op("array", "2");
      }
      op("array", std::to_string(ps.size()));
      call(1, hash ? "u_xtpl_hnew" : "u_xtpl_jnew");
    }

    // A chain: each stage a call, what came before its first argument.
    void Compiler::pipeline(const Pipeline* p)
    {
      if (is_source(p->source))
      {
        problem("a chain from rows(), lines() or a range");
        op("nil");
        return;
      }
      expr(p->source);
      for (const Call* st : p->stages)
      {
        bool verb = is_runtime_verb(st->name);
        for (const Expr* a : st->args)
        {
          if (verb) { block_arg(lc(st->name), a); }
          else { arg(a); }
        }
        call(st->args.size() + 1, verb ? "u_xtpl_" + lc(st->name) : st->name);
      }
    }

    // ---- chains that are loops ----------------------------------------------
    // A chain TL++ makes a loop of (emit.cpp's fused_value): a statement's
    // whole value -- or what a 'fallback' there guards -- over an array, with
    // stages that fuse; verbs written as calls are the chain they stand for.
    // Not yet here: run as calls, a 'tap' before a 'take' would see what the
    // loop never reads.
    bool Compiler::fused(const Expr* v, bool for_effect)
    {
      if (is(v, EK::Guard) && !for_effect)
      {
        auto g = static_cast<const Guard*>(v);
        return fused(g->expr, false) || fused(g->fallback, false);
      }
      std::vector<Call*> stages;
      const Expr* head = nullptr;
      if (is(v, EK::Pipeline))
      {
        head = static_cast<const Pipeline*>(v)->source;
        stages = static_cast<const Pipeline*>(v)->stages;
      }
      else if (is(v, EK::Call) && is_runtime_verb(static_cast<const Call*>(v)->name))
      {
        std::vector<const Call*> outer;
        const Expr* x = v;
        while (is(x, EK::Call) && is_runtime_verb(static_cast<const Call*>(x)->name)
               && !static_cast<const Call*>(x)->args.empty())
        {
          outer.push_back(static_cast<const Call*>(x));
          x = outer.back()->args[0];
        }
        if (!x || x->kind == EK::Omitted || is_source(x) || is(x, EK::Pipeline)) { return false; }
        head = x;
        for (auto c = outer.rbegin(); c != outer.rend(); ++c)
        {
          Call* st = tree_.make<Call>();
          st->name = (*c)->name;
          st->args.assign((*c)->args.begin() + 1, (*c)->args.end());
          stages.push_back(st);
        }
      }
      else
      {
        return false;
      }
      if (is_source(head)) { return false; }
      return fuse_from(stages, [this](const std::string& n) { return variable(resolve(n)); }, for_effect) >= 0;
    }

    bool Compiler::fused_stmt(const Stmt* s)
    {
      switch (s->kind)
      {
        case SK::Assignment:
        {
          auto a = static_cast<const Assignment*>(s);
          return a->op == ":=" && fused(a->value, false);
        }
        case SK::ReturnStmt:
          return fused(static_cast<const ReturnStmt*>(s)->value, false);
        case SK::CallStmt:
          return fused(static_cast<const CallStmt*>(s)->call, true);
        case SK::Declaration:
        {
          auto d = static_cast<const Declaration*>(s);
          std::string scope = lc(d->scope);
          if (scope == "static" || (scope == "local" && f_->scopes.size() == 1)) { return false; }
          for (const Declarator* v : d->declarators)
          {
            if (v->init && fused(v->init, false)) { return true; }
          }
          return false;
        }
        default:
          return false;
      }
    }

    // ---- assignments --------------------------------------------------------
    std::optional<Target> Compiler::target_of(const Expr* t)
    {
      if (is(t, EK::Ref)) { t = static_cast<const Ref*>(t)->target; }
      switch (t ? t->kind : EK::Omitted)
      {
        case EK::Name:
        {
          Var v = resolve(name_of(t));
          return Target{ 0, nullptr, [this, v] { load(v); }, [this, v] { store(v); } };
        }
        case EK::Index:
        {
          auto x = static_cast<const Index*>(t);
          return Target{ 2,
                         [this, x]
                         {
                           expr(x->base);
                           for (std::size_t i = 0; i + 1 < x->indices.size(); i++)
                           {
                             expr(x->indices[i]);
                             op("index");
                           }
                           expr(x->indices.back());
                         },
                         [this]
                         {
                           op("dup2");
                           op("index");
                         },
                         [this] { op("setindex"); } };
        }
        case EK::Member:
        case EK::SafeMember:
        {
          auto m = static_cast<const Member*>(t);
          return Target{ 1, [this, m] { member_base(m->base); },
                         [this, m]
                         {
                           op("dup");
                           op("member", m->name);
                         },
                         [this, m] { op("setmember", m->name); } };
        }
        case EK::HashIndex:
        {
          auto h = static_cast<const HashIndex*>(t);
          return Target{ 2,
                         [this, h]
                         {
                           expr(h->base);
                           expr(h->key);
                         },
                         [this]
                         {
                           op("dup2");
                           call(2, "u_xtpl_hget");
                         },
                         [this]
                         {
                           call(3, "u_xtpl_hset");
                           op("pop");
                         } };
        }
        case EK::Call:
        {
          // 'aTail(a) := x': the last element.
          auto c = static_cast<const Call*>(t);
          if (lc(c->name) != "atail" || c->args.size() != 1) { break; }
          return Target{ 2,
                         [this, c]
                         {
                           expr(c->args[0]);
                           op("dup");
                           call(1, "Len");
                         },
                         [this]
                         {
                           op("dup2");
                           op("index");
                         },
                         [this] { op("setindex"); } };
        }
        case EK::AliasField:
        {
          auto a = static_cast<const AliasField*>(t);
          if (a->macro)
          {
            // '(cAlias)->&(cField) := x': FieldPut() in the area.
            const Expr* name = static_cast<const Macro*>(a->macro)->target;
            std::function<void()> alias = a->alias ? std::function<void()>([this, a] { str(*a->alias); })
                                                   : std::function<void()>([this, a] { expr(a->base); });
            return Target{ 0, nullptr,
                           [this, alias, name]
                           {
                             in_area(alias, [this, name]
                             {
                               expr(name);
                               call(1, "FieldPos");
                               call(1, "FieldGet");
                             });
                           },
                           [this, alias, name]
                           {
                             int value = temp();
                             on_local("setlocal", value);
                             in_area(alias, [this, name, value]
                             {
                               expr(name);
                               call(1, "FieldPos");
                               on_local("local", value);
                               call(2, "FieldPut");
                             });
                             op("pop");
                           } };
          }
          if (a->alias)
          {
            std::string al = uc(*a->alias);
            std::string f = uc(a->field);
            if (al == "M" || al == "MEMVAR")
            {
              Var v{ Var::Memvar, -1, f, false };
              return Target{ 0, nullptr, [this, v] { load(v); }, [this, v] { store(v); } };
            }
            return Target{ 0, nullptr, [this, al, f] { op("field", al + " " + f); },
                           [this, al, f] { op("setfield", al + " " + f); } };
          }
          std::string f = uc(a->field);
          return Target{ 1, [this, a] { expr(a->base); },
                         [this, f]
                         {
                           op("dup");
                           op("fieldx", f);
                         },
                         [this, f] { op("setfieldx", f); } };
        }
        case EK::Macro:
        {
          auto m = static_cast<const Macro*>(t);
          if (m->called) { break; }
          return Target{ 1, [this, m] { expr(m->target); },
                         [this]
                         {
                           op("dup");
                           op("macro");
                         },
                         [this] { op("setmacro"); } };
        }
        default:
          break;
      }
      problem("an assignment to this -- a call");
      return std::nullopt;
    }

    // An assignment: the target's operands, the value, and the write. As a
    // value it leaves the value written (New) or the one before it (Old: 'n++').
    void Compiler::assign(const Expr* t, const std::string& o, const Expr* value, Want want, const std::string& incdec)
    {
      std::optional<Target> where = target_of(t);
      if (!where)
      {
        if (want != Want::None) { op("nil"); }
        return;
      }
      const Target& tg = *where;
      int kept = -1;
      auto keep = [&]
      {
        op("dup");
        if (tg.operands > 0)
        {
          kept = temp();
          on_local("setlocal", kept);
        }
      };
      if (tg.push) { tg.push(); }
      if (o == ":=" || o == "=")
      {
        expr(value);
        if (want != Want::None) { keep(); }
      }
      else
      {
        tg.read();
        if (want == Want::Old) { keep(); }
        operand(t, o, value, incdec);
        if (want == Want::New) { keep(); }
      }
      tg.write();
      if (kept >= 0) { on_local("local", kept); }
    }

    // The right side of '+=' and the like, and its operator: with a Decimal
    // target, the DEC_ function.
    void Compiler::operand(const Expr* t, const std::string& o, const Expr* value, const std::string& incdec)
    {
      std::string bare = o.substr(0, o.size() - 1);
      if (!advpl_ && is(t, EK::Name) && compound(o) && dec_.decimal(t))
      {
        if (incdec.empty()) { as_decimal(value); }
        else { dec_literal("1"); }
        call(2, dec_function(bare));
        return;
      }
      expr(value);
      op(arith_op(bare));
    }

    // '?=', 'Default': only when what is there is Nil.
    void Compiler::nil_assign(const Expr* t, const Expr* value)
    {
      int end = label();
      expr(t);
      op("isnil");
      jump("jumpf", end);
      assign(t, ":=", value, Want::None, "");
      place(end);
    }

    // 'Local aX[10][2]': Array(10, 2).
    void Compiler::dims(const std::vector<Expr*>& ds)
    {
      for (const Expr* d : ds) { expr(d); }
      call(ds.size(), "Array");
    }

    // What a variable declared with a type and no value starts at, in TL++.
    bool Compiler::start(const Declarator* v)
    {
      if (advpl_ || !v->typespec_text) { return false; }
      std::vector<std::string> w = words(*v->typespec_text);
      std::string t = w.empty() ? "" : lc(w.back());
      if (t == "numeric" || t == "integer" || t == "double") { num(0); }
      else if (t == "character") { str(""); }
      else if (t == "logical") { op("false"); }
      else if (t == "date")
      {
        str("18991231");
        call(1, "StoD");
      }
      else { return false; }
      return true;
    }

    // ---- Decimals -----------------------------------------------------------
    // What TL++ writes with the DEC_ functions (lower.cpp), written so here.
    bool Compiler::lowered_decimal(const Expr* e) const
    {
      if (!e || advpl_) { return false; }
      if (dv_.into_numeric.count(e) && e != unwrapped_ && dec_.decimal(e)) { return true; }
      if (dv_.into_decimal.count(e) && dec_.constant(e) && !dec_.decimal(e)) { return true; }
      if (e->kind == EK::Binary)
      {
        auto b = static_cast<const Binary*>(e);
        if (arithmetic(b->op)) { return dec_.decimal(e); }
        if (!comparison(b->op)) { return false; }
        bool l = dec_.decimal(b->left);
        bool r = dec_.decimal(b->right);
        return (l && !r && dec_.constant(b->right)) || (r && !l && dec_.constant(b->left));
      }
      if (e->kind == EK::Call)
      {
        auto c = static_cast<const Call*>(e);
        std::string n = lc(c->name);
        if (n == "round" || n == "noround") { return c->args.size() == 2 && dec_.decimal(c->args[0]); }
        return n == "empty" && c->args.size() == 1 && dec_.decimal(c->args[0]);
      }
      return false;
    }

    void Compiler::decimal_expr(const Expr* e)
    {
      if (dv_.into_numeric.count(e) && e != unwrapped_ && dec_.decimal(e))
      {
        const Expr* was = unwrapped_;
        unwrapped_ = e;
        expr(e);
        unwrapped_ = was;
        call(1, "DEC_TO_DBL");
        return;
      }
      if (dv_.into_decimal.count(e) && dec_.constant(e) && !dec_.decimal(e))
      {
        as_decimal(e);
        return;
      }
      if (e->kind == EK::Binary)
      {
        auto b = static_cast<const Binary*>(e);
        if (arithmetic(b->op))
        {
          as_decimal(b->left);
          as_decimal(b->right);
          call(2, dec_function(b->op));
          return;
        }
        auto side = [&](const Expr* x)
        {
          if (dec_.decimal(x)) { expr(x); }
          else { as_decimal(x); }
        };
        side(b->left);
        side(b->right);
        op(compare_op(b->op));
        return;
      }
      auto c = static_cast<const Call*>(e);
      std::string n = lc(c->name);
      expr(c->args[0]);
      if (n == "empty")
      {
        dec_literal("0");
        op("exact");
        return;
      }
      expr(c->args[1]);
      num(n == "round" ? 0 : 2);
      call(3, "DEC_RESCALE");
    }

    void Compiler::as_decimal(const Expr* e)
    {
      if (!e || dec_.decimal(e))
      {
        expr(e);
        return;
      }
      if (number_literal(e))
      {
        dec_literal(static_cast<const Literal*>(e)->text);
        return;
      }
      if (e->kind == EK::Binary && dec_.constant(e))
      {
        auto b = static_cast<const Binary*>(e);
        if (b->op == "neg")
        {
          as_decimal(b->right);
          op("neg");
          return;
        }
        as_decimal(b->left);
        as_decimal(b->right);
        call(2, dec_function(b->op));
        return;
      }
      expr(e);
    }

    // DEC_CREATE of a literal's own text: its digits and its decimals.
    void Compiler::dec_literal(const std::string& text)
    {
      std::string t = number_text(text);
      std::size_t dot = t.find('.');
      std::string whole = dot == std::string::npos ? t : t.substr(0, dot);
      std::string decimals = dot == std::string::npos ? "" : t.substr(dot + 1);
      std::size_t nz = whole.find_first_not_of('0');
      whole = nz == std::string::npos ? "0" : whole.substr(nz);
      str(decimals.empty() ? whole : whole + "." + decimals);
      num(static_cast<int>(whole.size() + decimals.size()));
      num(static_cast<int>(decimals.size()));
      call(3, "DEC_CREATE");
    }

    // ---- statements ---------------------------------------------------------
    void Compiler::statements(const Body& b)
    {
      for (const Stmt* s : b) { stmt(s); }
    }

    // A block's body: its block locals live to its end.
    void Compiler::block_body(const Body& b)
    {
      f_->scopes.emplace_back();
      statements(b);
      f_->scopes.pop_back();
    }

    void Compiler::stmt(const Stmt* s)
    {
      line_ = s->line;
      line(s->line);
      if (fused_stmt(s))
      {
        problem("a chain that runs as a loop -- its stages fuse");
        return;
      }
      switch (s->kind)
      {
        case SK::Declaration:
          declaration(static_cast<const Declaration*>(s));
          break;
        case SK::Assignment:
        {
          auto a = static_cast<const Assignment*>(s);
          if (a->op == "?=") { nil_assign(a->target, a->value); }
          else { assign(a->target, a->op, a->value, Want::None, ""); }
          break;
        }
        case SK::CallStmt:
          effect(static_cast<const CallStmt*>(s)->call);
          break;
        case SK::ReturnStmt:
          return_stmt(static_cast<const ReturnStmt*>(s));
          break;
        case SK::ExitStmt:
          jump_out(true);
          break;
        case SK::LoopStmt:
          jump_out(false);
          break;
        case SK::IfStmt:
          if_stmt(static_cast<const IfStmt*>(s));
          break;
        case SK::CaseStmt:
          case_stmt(static_cast<const CaseStmt*>(s));
          break;
        case SK::WhileStmt:
          while_stmt(static_cast<const WhileStmt*>(s));
          break;
        case SK::ForStmt:
          for_stmt(static_cast<const ForStmt*>(s));
          break;
        case SK::ForInStmt:
          for_in(static_cast<const ForInStmt*>(s));
          break;
        case SK::ForTimesStmt:
          for_times(static_cast<const ForTimesStmt*>(s));
          break;
        case SK::Modified:
          modified(static_cast<const Modified*>(s));
          break;
        case SK::Deferred:
        {
          // The statement goes after the function's code, with the names it
          // sees here, and the subjects of the 'with object's around it.
          int l = label();
          int id = static_cast<int>(f_->deferred.size()) + 1;
          jump("defer", l, std::to_string(id));
          f_->deferred.push_back(Fn::Deferred{ l, static_cast<const Deferred*>(s)->stmt, f_->scopes, subjects_ });
          break;
        }
        case SK::UsingAlias:
          using_alias(static_cast<const UsingAlias*>(s));
          break;
        case SK::WithObject:
        {
          auto w = static_cast<const WithObject*>(s);
          int t = temp();
          expr(w->subject);
          on_local("setlocal", t);
          subjects_.push_back({ f_, t });
          block_body(w->body);
          subjects_.pop_back();
          break;
        }
        case SK::RawStmt:
        {
          auto r = static_cast<const RawStmt*>(s);
          std::string first = r->lines.empty() ? "" : trim(r->lines[0]);
          if (r->block) { problem("a 'raw' block"); }
          else if (!first.empty() && first[0] == '#') { problem("a directive inside a function ('" + first + "')"); }
          else { problem("a command for the preprocessor ('" + first + "')"); }
          break;
        }
        case SK::TryStmt:
          try_stmt(static_cast<const TryStmt*>(s));
          break;
        case SK::TransactionStmt:
          call(0, "BeginTran");
          op("pop");
          block_body(static_cast<const TransactionStmt*>(s)->body);
          call(0, "EndTran");
          op("pop");
          break;
        case SK::BreakStmt:
        {
          const Expr* v = static_cast<const BreakStmt*>(s)->value;
          if (v) { expr(v); }
          call(v ? 1 : 0, "Break");
          op("pop");
          break;
        }
        case SK::DefaultStmt:
          for (const Assignment* a : static_cast<const DefaultStmt*>(s)->pairs) { nil_assign(a->target, a->value); }
          break;
        case SK::SequenceStmt:
          sequence(static_cast<const SequenceStmt*>(s));
          break;
        case SK::Annotation:
        case SK::NoOpStmt:
          break;
      }
    }

    void Compiler::declaration(const Declaration* d)
    {
      std::string scope = lc(d->scope);
      for (const Declarator* v : d->declarators)
      {
        line(v->line);
        if (scope == "local")
        {
          // The value first: it reads the names as they were before. A block
          // local with none is Nil each time, as TL++ has it, whatever its
          // type.
          bool block_local = f_->scopes.size() > 1;
          bool known = !block_local && f_->scopes.back().count(lc(v->name))
                       && f_->scopes.back().at(lc(v->name)).kind == Sym::Local;
          bool pushed = true;
          if (v->init) { expr(v->init); }
          else if (!v->dims.empty()) { dims(v->dims); }
          else if (block_local) { op("nil"); }
          else if (!known && start(v)) {}
          else { pushed = false; }
          int i = declare(v->name);
          if (pushed) { on_local("setlocal", i); }
        }
        else if (scope == "static")
        {
          static_value(v, f_->scopes.front());
        }
        else
        {
          std::string name = v->name;
          if (name.size() > 3 && uc(name.substr(0, 3)) == "M->") { name = name.substr(3); }
          std::string u = uc(name);
          op(scope == "private" ? "private" : "public", u);
          bool pushed = true;
          if (v->init) { expr(v->init); }
          else if (!v->dims.empty()) { dims(v->dims); }
          else { pushed = false; }
          if (pushed) { op("setmemvar", u); }
          f_->scopes.front()[lc(name)] = Entry{ Sym::Memvar, -1 };
        }
      }
    }

    // A static: a number of the module's, given its value in __INIT.
    // A static: a number of the module's, given its value in __INIT -- where
    // the statics its function declared before it are seen, and nothing
    // else of the function's.
    void Compiler::static_value(const Declarator* v, Scope& into)
    {
      int n = static_cast<int>(statics_.size());
      statics_.push_back(v->name);
      Scope seen;
      if (f_ != init_)
      {
        for (const Scope& s : f_->scopes)
        {
          for (const auto& [k, e] : s)
          {
            if (e.kind == Sym::Static) { seen[k] = e; }
          }
        }
      }
      Fn* was = f_;
      Fn* top = top_;
      f_ = init_;
      top_ = init_;
      init_->scopes.push_back(seen);
      line(v->line);
      bool pushed = true;
      if (v->init) { expr(v->init); }
      else if (!v->dims.empty()) { dims(v->dims); }
      else if (start(v)) {}
      else { pushed = false; }
      if (pushed) { op("setstatic", std::to_string(n + 1)); }
      init_->scopes.pop_back();
      f_ = was;
      top_ = top;
      into[lc(v->name)] = Entry{ Sym::Static, n };
    }

    void Compiler::local_header(const Declarator* d)
    {
      expr(d->init);
      on_local("setlocal", declare(d->name));
    }

    void Compiler::if_stmt(const IfStmt* s)
    {
      f_->scopes.emplace_back();
      if (s->header_decl) { local_header(s->header_decl); }
      int end = label();
      for (std::size_t i = 0; i < s->branches.size(); i++)
      {
        const Branch* b = s->branches[i];
        int next = label();
        expr(b->cond);
        jump("jumpf", next);
        block_body(b->body);
        if (i + 1 < s->branches.size() || !s->otherwise.empty()) { jump("jump", end); }
        place(next);
      }
      block_body(s->otherwise);
      place(end);
      f_->scopes.pop_back();
    }

    void Compiler::case_stmt(const CaseStmt* s)
    {
      f_->scopes.emplace_back();
      if (s->subject_decl) { local_header(s->subject_decl); }
      if (s->subject_assign) { assign(s->subject_assign->target, ":=", s->subject_assign->value, Want::None, ""); }
      int end = label();
      for (std::size_t i = 0; i < s->branches.size(); i++)
      {
        const Branch* b = s->branches[i];
        int next = label();
        expr(b->cond);
        jump("jumpf", next);
        block_body(b->body);
        if (i + 1 < s->branches.size() || !s->otherwise.empty()) { jump("jump", end); }
        place(next);
      }
      block_body(s->otherwise);
      place(end);
      f_->scopes.pop_back();
    }

    void Compiler::while_stmt(const WhileStmt* s)
    {
      f_->scopes.emplace_back();
      int top = label();
      int end = label();
      loop_top(top, s->line);
      if (s->header_decl) { local_header(s->header_decl); }
      expr(s->cond);
      jump("jumpf", end);
      f_->loops.push_back(Loop{ end, top, f_->exits.size() });
      block_body(s->body);
      f_->loops.pop_back();
      jump("jump", top);
      place(end);
      f_->scopes.pop_back();
    }

    // 'For i := a To b [Step s]': To and Step evaluated each time round; a
    // Step that is no literal decides which way it counts when it runs.
    void Compiler::for_stmt(const ForStmt* s)
    {
      f_->scopes.emplace_back();
      expr(s->from_);
      Var v = s->var_local ? Var{ Var::Local, declare(s->var), "", false } : resolve(s->var);
      store(v);
      int top = label();
      int cont = label();
      int end = label();
      loop_top(top, s->line);
      std::optional<bool> down;
      if (!s->step || number_literal(s->step)) { down = false; }
      else if (is(s->step, EK::Binary) && static_cast<const Binary*>(s->step)->op == "neg"
               && number_literal(static_cast<const Binary*>(s->step)->right))
      {
        down = true;
      }
      if (down)
      {
        load(v);
        expr(s->to_);
        op(*down ? "ge" : "le");
        jump("jumpf", end);
      }
      else
      {
        int neg = label();
        int body = label();
        expr(s->step);
        num(0);
        op("ge");
        jump("jumpf", neg);
        load(v);
        expr(s->to_);
        op("le");
        jump("jumpf", end);
        jump("jump", body);
        place(neg);
        load(v);
        expr(s->to_);
        op("ge");
        jump("jumpf", end);
        place(body);
      }
      f_->loops.push_back(Loop{ end, cont, f_->exits.size() });
      block_body(s->body);
      f_->loops.pop_back();
      place(cont);
      load(v);
      if (s->step) { expr(s->step); }
      else { num(1); }
      op("add");
      store(v);
      jump("jump", top);
      place(end);
      f_->scopes.pop_back();
    }

    // 'for x [, i] in source': an array read once, its index the counter
    // when named; a range counted, its ends read once.
    void Compiler::for_in(const ForInStmt* s)
    {
      if (is(s->source, EK::Call) && is_source(s->source))
      {
        problem("'for ... in' over " + lc(static_cast<const Call*>(s->source)->name) + "()");
        return;
      }
      f_->scopes.emplace_back();
      int top = label();
      int cont = label();
      int end = label();
      if (is(s->source, EK::Interval))
      {
        auto r = static_cast<const Interval*>(s->source);
        auto bound = [&](const Expr* x) -> std::function<void()>
        {
          if (name_or_literal(x)) { return [this, x] { expr(x); }; }
          int t = temp();
          expr(x);
          on_local("setlocal", t);
          return [this, t] { on_local("local", t); };
        };
        std::function<void()> lo = bound(r->lo);
        std::function<void()> hi = bound(r->hi);
        int el = declare(s->elem);
        int ix = s->index ? declare(*s->index) : -1;
        if (ix >= 0)
        {
          num(0);
          on_local("setlocal", ix);
        }
        int ctr = temp();
        lo();
        on_local("setlocal", ctr);
        loop_top(top, s->line);
        on_local("local", ctr);
        hi();
        op("le");
        jump("jumpf", end);
        on_local("local", ctr);
        on_local("setlocal", el);
        if (ix >= 0)
        {
          on_local("local", ix);
          num(1);
          op("add");
          on_local("setlocal", ix);
        }
        f_->loops.push_back(Loop{ end, cont, f_->exits.size() });
        block_body(s->body);
        f_->loops.pop_back();
        place(cont);
        on_local("local", ctr);
        num(1);
        op("add");
        on_local("setlocal", ctr);
      }
      else
      {
        int src = temp();
        expr(s->source);
        on_local("setlocal", src);
        int el = declare(s->elem);
        int ctr = s->index ? declare(*s->index) : temp();
        num(1);
        on_local("setlocal", ctr);
        loop_top(top, s->line);
        on_local("local", ctr);
        on_local("local", src);
        call(1, "Len");
        op("le");
        jump("jumpf", end);
        on_local("local", src);
        on_local("local", ctr);
        op("index");
        on_local("setlocal", el);
        f_->loops.push_back(Loop{ end, cont, f_->exits.size() });
        block_body(s->body);
        f_->loops.pop_back();
        place(cont);
        on_local("local", ctr);
        num(1);
        op("add");
        on_local("setlocal", ctr);
      }
      jump("jump", top);
      place(end);
      f_->scopes.pop_back();
    }

    // 'for n times': n read once, unless it is a number already.
    void Compiler::for_times(const ForTimesStmt* s)
    {
      std::function<void()> count;
      if (number_literal(s->count))
      {
        count = [this, s] { expr(s->count); };
      }
      else
      {
        int n = temp();
        expr(s->count);
        on_local("setlocal", n);
        count = [this, n] { on_local("local", n); };
      }
      int ctr = temp();
      int top = label();
      int cont = label();
      int end = label();
      num(1);
      on_local("setlocal", ctr);
      loop_top(top, s->line);
      on_local("local", ctr);
      count();
      op("le");
      jump("jumpf", end);
      f_->loops.push_back(Loop{ end, cont, f_->exits.size() });
      block_body(s->body);
      f_->loops.pop_back();
      place(cont);
      on_local("local", ctr);
      num(1);
      op("add");
      on_local("setlocal", ctr);
      jump("jump", top);
      place(end);
    }

    // 'x if c': an If around it; 'x while c', a loop.
    void Compiler::modified(const Modified* m)
    {
      int end = label();
      if (m->op == "while")
      {
        int top = label();
        loop_top(top, m->line);
        expr(m->cond);
        jump("jumpf", end);
        f_->loops.push_back(Loop{ end, top, f_->exits.size() });
        stmt(m->stmt);
        f_->loops.pop_back();
        jump("jump", top);
      }
      else
      {
        expr(m->cond);
        jump("jumpf", end);
        stmt(m->stmt);
      }
      place(end);
    }

    // 'using alias': the area selected, and put back -- with its record and
    // its order -- at its end and on every way out.
    void Compiler::using_alias(const UsingAlias* u)
    {
      Var v = resolve(u->area);
      std::function<void()> alias;
      if (v.kind != Var::Define && v.kind != Var::Crlf && variable(v))
      {
        int fal = temp();
        load(v);
        on_local("setlocal", fal);
        alias = [this, fal] { on_local("local", fal); };
      }
      else
      {
        std::string area = u->area;
        alias = [this, area] { str(area); };
      }
      int far = temp();
      int frc = temp();
      int fol = -1;
      call(0, "Alias");
      on_local("setlocal", far);
      alias();
      call(1, "DbSelectArea");
      op("pop");
      in_area(alias, [&] { call(0, "RecNo"); });
      on_local("setlocal", frc);
      if (u->order)
      {
        fol = temp();
        in_area(alias, [&] { call(0, "IndexOrd"); });
        on_local("setlocal", fol);
        in_area(alias, [&]
        {
          expr(u->order);
          call(1, "DbSetOrder");
        });
        op("pop");
      }
      auto restore = [this, alias, far, frc, fol]
      {
        if (fol >= 0)
        {
          in_area(alias, [&]
          {
            on_local("local", fol);
            call(1, "DbSetOrder");
          });
          op("pop");
        }
        in_area(alias, [&]
        {
          on_local("local", frc);
          call(1, "DbGoto");
        });
        op("pop");
        int skip = label();
        on_local("local", far);
        call(1, "Empty");
        jump("jumpt", skip);
        on_local("local", far);
        call(1, "DbSelectArea");
        op("pop");
        place(skip);
      };
      f_->exits.push_back(Exit{ Exit::Restore, restore });
      block_body(u->body);
      f_->exits.pop_back();
      restore();
    }

    // 'Try ... Catch e ... Finally ... EndTry': the Finally after the body
    // and after the Catch, and on a way out of either.
    void Compiler::try_stmt(const TryStmt* t)
    {
      int caught = label();
      int end = label();
      bool fin = !t->finally.empty();
      auto finally = [this, t] { block_body(t->finally); };
      if (fin) { f_->exits.push_back(Exit{ Exit::Restore, finally }); }
      f_->exits.push_back(Exit{ Exit::Region, nullptr });
      jump("try", caught);
      block_body(t->body);
      op("endseq");
      f_->exits.pop_back();
      if (fin)
      {
        f_->exits.pop_back();
        finally();
      }
      jump("jump", end);
      place(caught);
      if (t->error_var) { store(resolve(*t->error_var)); }
      else { op("pop"); }
      if (fin) { f_->exits.push_back(Exit{ Exit::Restore, finally }); }
      block_body(t->handler);
      if (fin)
      {
        f_->exits.pop_back();
        finally();
      }
      place(end);
    }

    void Compiler::sequence(const SequenceStmt* s)
    {
      int recover = label();
      int end = label();
      f_->exits.push_back(Exit{ Exit::Region, nullptr });
      jump("seq", recover);
      block_body(s->body);
      op("endseq");
      f_->exits.pop_back();
      jump("jump", end);
      place(recover);
      if (s->has_recover && s->error_var) { store(resolve(*s->error_var)); }
      else { op("pop"); }
      if (s->has_recover) { block_body(s->recover); }
      place(end);
    }

    // A 'return': the defers reached, what is open put back, then its value.
    void Compiler::return_stmt(const ReturnStmt* r)
    {
      if (f_->defers) { op("rundefers"); }
      run_exits(0, false);
      expr(r->value);
      op("ret");
    }

    void Compiler::jump_out(bool exit)
    {
      if (f_->loops.empty())
      {
        problem(std::string(exit ? "'exit'" : "'loop'") + " outside a loop");
        return;
      }
      Loop l = f_->loops.back();
      run_exits(l.exits, true);
      jump("jump", exit ? l.brk : l.cont);
    }

    // What the exits above down_to do, the innermost first -- each with the
    // ones inside it gone while it is written.
    void Compiler::run_exits(std::size_t down_to, bool regions)
    {
      std::vector<Exit> all = f_->exits;
      for (std::size_t i = all.size(); i-- > down_to;)
      {
        f_->exits.resize(i);
        if (all[i].kind == Exit::Region)
        {
          if (regions) { op("endseq"); }
        }
        else
        {
          all[i].run();
        }
      }
      f_->exits = all;
    }

    // ---- the file -----------------------------------------------------------
    int Compiler::line_of(std::string_view text) const
    {
      std::size_t at = src_.find(text);
      if (at == std::string_view::npos) { return 1; }
      return 1 + static_cast<int>(std::count(src_.begin(), src_.begin() + static_cast<std::ptrdiff_t>(at), '\n'));
    }

    // '#define NAME value': the value read as an expression, compiled where
    // the name is read. The preprocessor's choices -- '#ifdef' and the
    // like -- are not made here.
    void Compiler::directives()
    {
      for (const std::string& d : p_->directives)
      {
        std::size_t i = d.find_first_not_of(" \t", 1);
        if (i == std::string::npos) { continue; }
        std::size_t w = i;
        while (i < d.size() && is_w(static_cast<unsigned char>(d[i]))) { i++; }
        std::string word = lc(d.substr(w, i - w));
        if (word == "if" || word == "ifdef" || word == "ifndef" || word == "elif" || word == "else" || word == "endif")
        {
          line_ = line_of(d);
          problem("'#" + word + "', a choice of the preprocessor's");
          continue;
        }
        if (word != "define") { continue; }
        std::size_t n = d.find_first_not_of(" \t", i);
        if (n == std::string::npos) { continue; }
        std::size_t e = n;
        while (e < d.size() && is_w(static_cast<unsigned char>(d[e]))) { e++; }
        std::string name = lc(d.substr(n, e - n));
        Define def;
        if (e < d.size() && d[e] == '(')
        {
          def.params = true;
          defines_[name] = def;
          continue;
        }
        texts_.push_back(trim(split_comment(d.substr(e)).first));
        const std::string& value = texts_.back();
        if (value.empty())
        {
          def.read = true;
          defines_[name] = def;
          continue;
        }
        Parser parser(value, {}, tree_);
        int end = 0;
        Expr* x = parser.read(Form::Expr, 0, false, end);
        def.body = x;
        def.read = x && trim(std::string_view(value).substr(static_cast<std::size_t>(end))).empty();
        defines_[name] = def;
      }
    }

    void Compiler::function(const std::string& name, const std::string& kind, const std::vector<Param*>& params,
                            const Body& body, const OptStr& returns)
    {
      auto fn = std::make_unique<Fn>();
      Fn* g = fn.get();
      g->name = name;
      g->kind = kind;
      g->params = static_cast<int>(params.size());
      fns_.push_back(std::move(fn));
      order_.push_back(g);
      f_ = g;
      top_ = g;
      g->scopes.emplace_back();
      for (const Param* q : params)
      {
        int i = add_local(g, q->name);
        g->scopes.back()[lc(q->name)] = Entry{ Sym::Local, i };
      }
      dec_.function(params, body);
      dv_ = decimal_values(dec_, body, Returns{ decimal_word(returns), numeric_word(returns) });
      walk(body, [&](Stmt* s)
      {
        if (s->kind == SK::Deferred) { g->defers = true; }
      });
      statements(body);
      finish();
    }

    // The function's end, a return of Nil, and after it the code of its
    // defers.
    void Compiler::finish()
    {
      bool target = std::find(f_->labels.begin(), f_->labels.end(), static_cast<int>(f_->code.size()))
                    != f_->labels.end();
      if (f_->code.empty() || f_->code.back().op != "ret" || target)
      {
        if (f_->defers) { op("rundefers"); }
        op("nil");
        op("ret");
      }
      std::vector<Fn::Deferred> deferred = f_->deferred;
      for (const Fn::Deferred& d : deferred)
      {
        place(d.label);
        f_->scopes = d.scopes;
        subjects_ = d.subjects;
        f_->line = -1;
        stmt(d.stmt);
        op("enddefer");
        subjects_.clear();
      }
    }

    std::string Compiler::written(const Fn& f) const
    {
      std::vector<int> boxes;
      for (std::size_t i = 0; i < f.captured.size(); i++)
      {
        if (f.captured[i]) { boxes.push_back(static_cast<int>(i)); }
      }
      int shift = static_cast<int>(boxes.size());
      std::string out = "function " + f.name + " " + f.kind + " " + std::to_string(f.params) + " "
                        + std::to_string(f.names.size()) + "\n";
      out += "  locals";
      for (const std::string& n : f.names) { out += " " + n; }
      out += "\n";
      if (!f.upvals.empty())
      {
        out += "  upvals";
        for (const Upval& u : f.upvals) { out += " " + u.name; }
        out += "\n";
      }
      for (int b : boxes) { out += "  box " + std::to_string(b + 1) + "\n"; }
      for (const Ins& i : f.code)
      {
        std::string o = i.op;
        if (i.local >= 0)
        {
          if (f.captured[static_cast<std::size_t>(i.local)])
          {
            o = o == "local" ? "cell" : o == "setlocal" ? "setcell" : "refcell";
          }
          o += " " + std::to_string(i.local + 1);
        }
        if (!i.arg.empty() || i.str) { o += " " + (i.str ? "\"" + i.arg + "\"" : i.arg); }
        if (i.target >= 0)
        {
          int at = f.labels[static_cast<std::size_t>(i.target)];
          if (at < 0) { throw std::logic_error("a label never placed in " + f.name); }
          o += " " + std::to_string(at + shift + 1);
        }
        out += "  " + o + "\n";
      }
      out += "end\n";
      return out;
    }

    std::string Compiler::run()
    {
      directives();
      if (p_->ns)
      {
        line_ = line_of("namespace");
        problem("a namespace");
      }
      for (const ClassDef* c : p_->classes)
      {
        line_ = c->line;
        problem("a class ('" + c->name + "')");
      }
      for (const MethodImpl* m : p_->methods)
      {
        line_ = m->line;
        problem("a method ('" + m->class_name + ":" + m->name + "')");
      }

      // The statics' values, run first: the file's, then each function's.
      auto init = std::make_unique<Fn>();
      init_ = init.get();
      init_->name = "__INIT";
      init_->kind = "init";
      fns_.push_back(std::move(init));
      f_ = init_;
      top_ = init_;
      if (!advpl_) { dec_.file(p_); }
      dec_.function({}, {});
      for (const Declaration* d : p_->statics)
      {
        line_ = d->line;
        for (const Declarator* v : d->declarators)
        {
          if (v->init && decimal_word(v->typespec_text)) { dv_.into_decimal.insert(v->init); }
          static_value(v, file_);
        }
      }

      for (const FunctionDef* fd : p_->functions)
      {
        line_ = fd->line;
        std::string t = lc(fd->type);
        std::string name = uc(fd->name);
        std::string kind;
        if (t == "user")
        {
          kind = "user";
          name = "U_" + name;
        }
        else if (t == "static") { kind = "static"; }
        else if (t == "main") { kind = "main"; }
        else if (t.empty()) { kind = name.rfind("U_", 0) == 0 ? "user" : "function"; }
        else
        {
          problem("a " + fd->type + " function");
          continue;
        }
        function(name, kind, fd->params, fd->body, fd->rettype_word);
      }

      if (!problems_.empty()) { throw NotBytecode(problems_); }

      std::string out = "xbc 1\nsource " + source_ + "\nstatics " + std::to_string(statics_.size()) + "\n";
      auto with_blocks = [&](const Fn* g)
      {
        out += "\n" + written(*g);
        for (const Fn* b : g->made) { out += "\n" + written(*b); }
      };
      if (!init_->code.empty())
      {
        f_ = init_;
        op("nil");
        op("ret");
        with_blocks(init_);
      }
      for (const Fn* g : order_) { with_blocks(g); }
      return out;
    }
  }

  std::string bytecode(const Program* p, std::string_view src, bool advpl, const std::string& source_name)
  {
    Compiler c(p, src, advpl, source_name);
    return c.run();
  }
}
