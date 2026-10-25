// xc -- typed arrays and hashes: what goes into one (see typed.h).

#include "typed.h"

#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>

#include "chars.h"
#include "text.h"
#include "walk.h"

namespace xc
{
  namespace
  {
    bool is(const Expr* e, EK k) { return e && e->kind == k; }

    // ---- types --------------------------------------------------------------
    // As ast.h writes them: 'N', 'C', 'L', 'D', 'A', 'H', 'O', 'B', 'J', 'F',
    // 'A<T>', 'H<K,V>'; and here, NIL (fits every type), UNKNOWN, and NONE --
    // nothing known yet, while the types of a function's names are worked out.
    const std::string NIL;
    const std::string UNKNOWN = "?";
    const std::string NONE = "_";

    bool generic(const std::string& t) { return t.size() > 2 && t[1] == '<'; }

    // The types between the '<' and the '>' of 'A<T>' or 'H<K,V>'.
    std::vector<std::string> args_of(const std::string& t)
    {
      std::vector<std::string> out;
      if (!generic(t)) { return out; }
      int depth = 0;
      std::size_t from = 2;
      for (std::size_t i = 2; i + 1 < t.size(); i++)
      {
        char c = t[i];
        if (c == '<') { depth++; }
        else if (c == '>') { depth--; }
        else if (c == ',' && depth == 0)
        {
          out.push_back(t.substr(from, i - from));
          from = i + 1;
        }
      }
      out.push_back(t.substr(from, t.size() - 1 - from));
      return out;
    }

    // What an element of an array of type t is; a key, a value of a hash.
    std::string part_of(const std::string& t, char kind, std::size_t n)
    {
      if (t == NONE) { return NONE; }
      if (!generic(t) || t[0] != kind) { return UNKNOWN; }
      return args_of(t).at(n);
    }
    std::string elem_of(const std::string& t) { return part_of(t, 'A', 0); }
    std::string key_of(const std::string& t) { return part_of(t, 'H', 0); }
    std::string value_of(const std::string& t) { return part_of(t, 'H', 1); }

    std::string array_of(const std::string& t)
    {
      if (t == NONE) { return NONE; }
      return t.empty() || t == UNKNOWN ? "A" : "A<" + t + ">";
    }

    // A type as xtpl writes it: 'Numeric', 'Array<n>', 'Hash<c, Array<n>>'.
    std::string show(const std::string& t);

    std::string inner(const std::string& t)
    {
      return generic(t) ? show(t) : lc(t);
    }

    std::string show(const std::string& t)
    {
      if (generic(t))
      {
        std::vector<std::string> a = args_of(t);
        return t[0] == 'A' ? "Array<" + inner(a[0]) + ">" : "Hash<" + inner(a[0]) + ", " + inner(a[1]) + ">";
      }
      static const std::unordered_map<std::string, std::string> names =
      {
        { "N", "Numeric" }, { "C", "Character" }, { "L", "Logical" }, { "D", "Date" }, { "A", "Array" },
        { "H", "Hash" }, { "O", "Object" }, { "B", "CodeBlock" }, { "J", "JSON" }, { "F", "Decimal" },
      };
      auto n = names.find(t);
      return n != names.end() ? n->second : t;
    }

    // With its article, for an array or a hash: 'an Array<n>', 'Character'.
    std::string shown(const std::string& t)
    {
      if (!t.empty() && t[0] == 'A') { return "an " + show(t); }
      if (!t.empty() && t[0] == 'H') { return "a " + show(t); }
      return show(t);
    }

    // A type TL++ declares, as its word: 'Numeric' is 'N'.
    std::string letter_of(const std::string& declared)
    {
      static const std::unordered_map<std::string, std::string> letters =
      {
        { "numeric", "N" }, { "integer", "N" }, { "double", "N" }, { "character", "C" }, { "logical", "L" },
        { "date", "D" }, { "array", "A" }, { "object", "O" }, { "codeblock", "B" }, { "json", "J" },
        { "decimal", "F" },
      };
      auto l = letters.find(lc(declared));
      return l != letters.end() ? l->second : UNKNOWN;
    }

    // What a declarator is declared as, if it is: 'Local nX as Numeric' is
    // 'N', 'Local aX[10]' an array.
    std::string declared_type(const Declarator* d)
    {
      std::vector<std::string> w = words(d->typespec_text.value_or(""));
      if (w.size() > 1) { return letter_of(w.back()); }
      return d->declared == "Array" ? "A" : UNKNOWN;
    }

    enum class Fit { Ok, Wrong, Unknown };

    // Whether a value of type v goes where slot is wanted.
    Fit fits(const std::string& v, const std::string& slot)
    {
      if (slot.empty() || slot == UNKNOWN || v.empty()) { return Fit::Ok; }
      if (v == UNKNOWN || v == NONE) { return Fit::Unknown; }
      if (v == slot) { return Fit::Ok; }
      char vk = v[0];
      char sk = slot[0];
      if (sk == 'O' && vk == 'H') { return Fit::Ok; }          // a THashMap is an object
      if (vk == 'O' && sk == 'H') { return Fit::Unknown; }     // and an object may be one
      if (vk != sk) { return Fit::Wrong; }
      if (!generic(slot)) { return Fit::Ok; }                  // an array, whatever it holds
      if (!generic(v)) { return Fit::Unknown; }                // what it holds, not known
      std::vector<std::string> va = args_of(v);
      std::vector<std::string> sa = args_of(slot);
      Fit worst = Fit::Ok;
      for (std::size_t i = 0; i < sa.size(); i++)
      {
        Fit f = fits(va[i], sa[i]);
        if (f == Fit::Wrong) { return Fit::Wrong; }
        if (f == Fit::Unknown) { worst = Fit::Unknown; }
      }
      return worst;
    }

    // What a name holds, given two of its values.
    std::string join(const std::string& a, const std::string& b)
    {
      if (a == NONE || a.empty()) { return b; }
      if (b == NONE || b.empty()) { return a; }
      if (a == b) { return a; }
      if (a == UNKNOWN || b == UNKNOWN) { return UNKNOWN; }
      if (a[0] == b[0] && (a[0] == 'A' || a[0] == 'H')) { return std::string(1, a[0]); }
      return UNKNOWN;
    }

    const std::unordered_set<std::string> LOGICAL =
    {
      "==", "=", "!=", "<>", "#", "<", ">", "<=", ">=", "$", ".and.", ".or.", "!", "in", "has", "%%",
    };

    // An operator's result, given its operands'.
    std::string binop(const std::string& op, const std::string& l, const std::string& r)
    {
      if (LOGICAL.count(op)) { return "L"; }
      if (op == "?:")
      {
        if (l == NONE || r == NONE) { return NONE; }
        return l == r || r.empty() ? l : l.empty() ? r : UNKNOWN;
      }
      if (op == "neg")
      {
        return r == NONE ? NONE : r == "N" || r == "F" ? r : UNKNOWN;
      }
      if (l == NONE || r == NONE) { return NONE; }
      bool num = (l == "N" || l == "F") && (r == "N" || r == "F");
      if (num) { return l == "F" || r == "F" ? "F" : "N"; }
      if (op == "+" || op == "-")
      {
        // A string and something xc cannot tell: a string, or an error.
        if ((l == "C" && (r == "C" || r == UNKNOWN)) || (r == "C" && l == UNKNOWN)) { return "C"; }
      }
      if (op == "+")
      {
        if (l == "C" && r == "C") { return "C"; }
        if ((l == "D" && r == "N") || (l == "N" && r == "D")) { return "D"; }
      }
      if (op == "-")
      {
        if (l == "C" && r == "C") { return "C"; }
        if (l == "D" && r == "N") { return "D"; }
        if (l == "D" && r == "D") { return "N"; }
      }
      return UNKNOWN;
    }

    std::string chop(const std::string& s) { return s.empty() ? s : s.substr(0, s.size() - 1); }

    // TL++'s functions, and what each gives.
    const std::unordered_map<std::string, std::string> RETURNS =
    {
      { "len", "N" }, { "val", "N" }, { "at", "N" }, { "rat", "N" }, { "asc", "N" }, { "mod", "N" },
      { "sqrt", "N" }, { "exp", "N" }, { "log", "N" }, { "year", "N" }, { "month", "N" }, { "day", "N" },
      { "dow", "N" }, { "seconds", "N" }, { "ascan", "N" }, { "recno", "N" }, { "reccount", "N" },
      { "lastrec", "N" }, { "fcount", "N" }, { "randomize", "N" },
      { "str", "C" }, { "strzero", "C" }, { "alltrim", "C" }, { "trim", "C" }, { "rtrim", "C" }, { "ltrim", "C" },
      { "upper", "C" }, { "lower", "C" }, { "substr", "C" }, { "left", "C" }, { "right", "C" }, { "padl", "C" },
      { "padr", "C" }, { "padc", "C" }, { "replicate", "C" }, { "space", "C" }, { "chr", "C" },
      { "strtran", "C" }, { "stuff", "C" }, { "transform", "C" }, { "dtos", "C" }, { "dtoc", "C" },
      { "time", "C" }, { "cvaltochar", "C" }, { "valtype", "C" }, { "capital", "C" }, { "cmonth", "C" },
      { "cdow", "C" }, { "elaptime", "C" }, { "procname", "C" }, { "alias", "C" }, { "encodeutf8", "C" },
      { "decodeutf8", "C" }, { "memoline", "C" },
      { "empty", "L" }, { "file", "L" }, { "isdigit", "L" }, { "isalpha", "L" }, { "isupper", "L" },
      { "islower", "L" }, { "eof", "L" }, { "bof", "L" }, { "found", "L" }, { "deleted", "L" },
      { "dbseek", "L" },
      { "date", "D" }, { "ctod", "D" }, { "stod", "D" }, { "msdate", "D" }, { "lastday", "D" },
      { "firstday", "D" }, { "daysum", "D" }, { "daysub", "D" }, { "monthsum", "D" }, { "monthsub", "D" },
      { "yearsum", "D" }, { "yearsub", "D" },
      { "array", "A" }, { "directory", "A" }, { "strtokarr", "A<C>" }, { "strtokarr2", "A<C>" },
      { "separa", "A<C>" },
    };

    // The runtime's verbs that give an array of what they walk, as they walk
    // it: some of it, or in another order.
    const std::unordered_set<std::string> KEEPS =
    {
      "filter", "reject", "tap", "take", "drop", "takewhile", "dropwhile", "distinct", "distinctadjacent",
      "sort", "sortby", "reverse", "apick", "aroll",
    };

    // How a function of the file is called: a user function with its 'u_'.
    std::string called_as(const FunctionDef* f)
    {
      std::string t = lc(f->type);
      if (t == "user") { return "u_" + lc(f->name); }
      if (t.empty() || t == "static") { return lc(f->name); }
      return "";
    }

    // ---- the pass -----------------------------------------------------------
    struct Var
    {
      std::string name;
      bool fixed = false;            // its type declared, or one xc does not work out
      std::string type = NONE;       // what it holds
      std::string container;         // the typed array or hash it is declared as
    };

    struct Event
    {
      enum Kind { Decl, Assign, Counter, ForIn, Unknown, CallE, MethodE, Return } kind = Decl;
      int line = 0;
      Var* var = nullptr;
      Var* index = nullptr;
      const Declarator* decl = nullptr;
      const Expr* target = nullptr;
      std::string op;
      std::string incdec;
      const Expr* value = nullptr;
      const Call* call = nullptr;
      const Pipeline* chain = nullptr;   // a stage's chain, and the stage
      std::size_t stage = 0;
      const MethodCall* method = nullptr;
    };

    struct Function
    {
      std::vector<const Param*> params;
      std::string name;
    };

    // A function's events -- the file's statics' too --, and what it returns
    // if that is a typed array or hash.
    struct Unit
    {
      std::vector<Event> events;
      std::string ret;
      std::string name;
    };

    using Scope = std::unordered_map<std::string, Var*>;

    class Typer
    {
    public:
      Typer(const Program* p, const Dictionary& dictionary) : p_(p), dictionary_(dictionary) {}

      void run();

      std::vector<Finding> errors;
      std::vector<Finding> warnings;

    private:
      const Program* p_;
      const Dictionary& dictionary_;
      std::vector<std::unique_ptr<Var>> vars_;
      std::vector<Scope> scopes_;
      std::unordered_map<const Expr*, Var*> names_;  // what each name is
      std::unordered_map<const Expr*, std::vector<Var*>> block_params_;
      std::vector<Unit> units_;
      std::unordered_map<std::string, std::string> returns_;    // the file's functions
      std::unordered_map<std::string, Function> functions_;
      std::string ret_;              // what the function returns, if it is a typed array or hash
      std::string ret_name_;
      int line_ = 0;

      bool any_typed() const;
      Var* declare(const std::string& name, bool fixed, const std::string& type, const std::string& container);
      Var* find(const std::string& name) const;
      void function(const std::vector<Param*>& params, const Body& body, const std::string& ret,
                    const std::string& name);
      void body(const Body& b);
      void stmt(Stmt* s);
      void expr(Expr* e);
      void declarator(Declarator* d, const std::string& scope);
      void event(Event e)
      {
        e.line = line_;
        units_.back().events.push_back(std::move(e));
      }
      void infer();
      void check(const Unit& u);

      std::string type(const Expr* e);
      std::string call_type(const std::string& name, const std::vector<Expr*>& args, const std::string* fed);
      std::string chain_type(const Pipeline* p, std::size_t stages);
      std::string field_type(const AliasField* f) const;
      std::string elem_in(const Expr* source);

      void into(const Expr* e, const std::string& slot, const std::string& who, bool key = false);
      std::string who_of(const Expr* base);
      void call_check(const std::string& name, const std::vector<Expr*>& args, const Expr* fed_expr,
                      const std::string* fed);
    };

    // ---- what the file has --------------------------------------------------
    bool Typer::any_typed() const
    {
      for (const Declaration* d : p_->statics)
      {
        for (const Declarator* v : d->declarators)
        {
          if (!v->container.empty()) { return true; }
        }
      }
      for (const FunctionDef* f : p_->functions)
      {
        if (!f->ret_container.empty()) { return true; }
        for (const Param* q : f->params)
        {
          if (q && !q->container.empty()) { return true; }
        }
      }
      bool found = false;
      auto look = [&](Expr* e)
      {
        walk_expr(e, [&](Expr* x)
        {
          if (is(x, EK::ArrayLit) && !static_cast<ArrayLit*>(x)->elem.empty()) { found = true; }
          if (is(x, EK::HashLit) && !static_cast<HashLit*>(x)->key_type.empty()) { found = true; }
        });
      };
      auto in_body = [&](const Body& b)
      {
        walk(b, [&](Stmt* s)
        {
          if (found) { return; }
          if (s->kind == SK::Declaration)
          {
            for (const Declarator* v : static_cast<Declaration*>(s)->declarators)
            {
              if (!v->container.empty()) { found = true; }
            }
          }
          for (Expr* e : exprs_of(s)) { look(e); }
        });
      };
      for (const Declaration* d : p_->statics)
      {
        for (Declarator* v : d->declarators) { look(v->init); }
      }
      for (const FunctionDef* f : p_->functions) { in_body(f->body); }
      for (const MethodImpl* m : p_->methods) { in_body(m->body); }
      return found;
    }

    // ---- names --------------------------------------------------------------
    Var* Typer::declare(const std::string& name, bool fixed, const std::string& type, const std::string& container)
    {
      vars_.push_back(std::make_unique<Var>());
      Var* v = vars_.back().get();
      v->name = name;
      v->fixed = fixed;
      v->type = fixed ? type : NONE;
      v->container = container;
      scopes_.back()[lc(name)] = v;
      return v;
    }

    Var* Typer::find(const std::string& name) const
    {
      std::string k = lc(name);
      for (auto s = scopes_.rbegin(); s != scopes_.rend(); ++s)
      {
        if (auto it = s->find(k); it != s->end()) { return it->second; }
      }
      return nullptr;
    }

    // A declarator's name: declared as a typed array or hash -- by its type,
    // or by its value, '{ <n> }' --, with a type, or worked out from what it
    // is given (a Local's, a Static's).
    void Typer::declarator(Declarator* d, const std::string& scope)
    {
      expr(d->init);
      for (Expr* x : d->dims) { expr(x); }
      std::string container = d->container;
      if (container.empty() && d->init && (scope == "local" || scope == "static"))
      {
        if (is(d->init, EK::ArrayLit) && !static_cast<ArrayLit*>(d->init)->elem.empty())
        {
          container = type(d->init);
        }
        else if (is(d->init, EK::HashLit) && !static_cast<HashLit*>(d->init)->key_type.empty())
        {
          container = type(d->init);
        }
      }
      Var* v = nullptr;
      if (!container.empty()) { v = declare(d->name, true, container, container); }
      else if (scope != "local" && scope != "static") { v = declare(d->name, true, UNKNOWN, ""); }
      else if (d->declared != "?") { v = declare(d->name, true, declared_type(d), ""); }
      else { v = declare(d->name, false, NONE, ""); }
      Event e;
      e.kind = Event::Decl;
      e.var = v;
      e.decl = d;
      event(e);
    }

    // ---- the walk -----------------------------------------------------------
    void Typer::run()
    {
      if (!any_typed()) { return; }
      for (const FunctionDef* f : p_->functions)
      {
        std::string name = called_as(f);
        if (name.empty()) { continue; }
        if (!f->ret_container.empty()) { returns_[name] = f->ret_container; }
        else if (f->rettype_word) { returns_[name] = letter_of(*f->rettype_word); }
        Function fn;
        fn.name = f->name;
        for (const Param* q : f->params) { fn.params.push_back(q); }
        functions_[name] = fn;
      }
      // The file's statics -- only its functions give them anything, so what
      // they hold is worked out over all of them.
      scopes_.assign(1, Scope{});
      units_.emplace_back();
      for (const Declaration* d : p_->statics)
      {
        for (Declarator* v : d->declarators)
        {
          line_ = v->line;
          declarator(v, "static");
        }
      }
      Scope file = scopes_.front();
      for (const FunctionDef* f : p_->functions)
      {
        scopes_.assign(1, file);
        function(f->params, f->body, f->ret_container, f->name);
      }
      for (const MethodImpl* m : p_->methods)
      {
        scopes_.assign(1, file);
        function(m->params, m->body, "", m->name);
      }
      infer();
      for (const Unit& u : units_) { check(u); }
    }

    void Typer::function(const std::vector<Param*>& params, const Body& b, const std::string& ret,
                         const std::string& name)
    {
      units_.emplace_back();
      units_.back().ret = ret;
      units_.back().name = name;
      scopes_.emplace_back();
      for (const Param* q : params)
      {
        if (!q) { continue; }
        std::string t = !q->container.empty() ? q->container : q->type_word ? letter_of(*q->type_word) : UNKNOWN;
        declare(q->name, true, t, q->container);
      }
      body(b);
      scopes_.pop_back();
    }

    void Typer::body(const Body& b)
    {
      scopes_.emplace_back();
      for (Stmt* s : b) { stmt(s); }
      scopes_.pop_back();
    }

    void Typer::stmt(Stmt* s)
    {
      if (!s) { return; }
      if (s->line > 0) { line_ = s->line; }
      switch (s->kind)
      {
        case SK::Declaration:
        {
          auto d = static_cast<Declaration*>(s);
          for (Declarator* v : d->declarators) { declarator(v, lc(d->scope)); }
          break;
        }
        case SK::Assignment:
        {
          auto a = static_cast<Assignment*>(s);
          expr(a->target);
          expr(a->value);
          Event e;
          e.kind = Event::Assign;
          e.target = a->target;
          e.op = a->op;
          e.value = a->value;
          event(e);
          break;
        }
        case SK::CallStmt:
          expr(static_cast<CallStmt*>(s)->call);
          break;
        case SK::ReturnStmt:
        {
          auto r = static_cast<ReturnStmt*>(s);
          expr(r->value);
          Event e;
          e.kind = Event::Return;
          e.value = r->value;
          event(e);
          break;
        }
        case SK::IfStmt:
        {
          auto i = static_cast<IfStmt*>(s);
          scopes_.emplace_back();
          if (i->header_decl) { declarator(i->header_decl, "local"); }
          for (Branch* br : i->branches)
          {
            line_ = s->line;
            expr(br->cond);
            body(br->body);
          }
          body(i->otherwise);
          scopes_.pop_back();
          break;
        }
        case SK::CaseStmt:
        {
          auto c = static_cast<CaseStmt*>(s);
          scopes_.emplace_back();
          if (c->subject_decl) { declarator(c->subject_decl, "local"); }
          if (c->subject_assign) { stmt(c->subject_assign); }
          for (Branch* br : c->branches)
          {
            expr(br->cond);
            body(br->body);
          }
          body(c->otherwise);
          scopes_.pop_back();
          break;
        }
        case SK::WhileStmt:
        {
          auto w = static_cast<WhileStmt*>(s);
          scopes_.emplace_back();
          if (w->header_decl) { declarator(w->header_decl, "local"); }
          expr(w->cond);
          body(w->body);
          scopes_.pop_back();
          break;
        }
        case SK::ForStmt:
        {
          auto f = static_cast<ForStmt*>(s);
          expr(f->from_);
          expr(f->to_);
          expr(f->step);
          scopes_.emplace_back();
          Var* v = f->var_local ? declare(f->var, false, NONE, "") : find(f->var);
          if (v)
          {
            Event e;
            e.kind = Event::Counter;
            e.var = v;
            event(e);
          }
          body(f->body);
          scopes_.pop_back();
          break;
        }
        case SK::ForInStmt:
        {
          auto f = static_cast<ForInStmt*>(s);
          expr(f->source);
          scopes_.emplace_back();
          Event e;
          e.kind = Event::ForIn;
          e.var = declare(f->elem, false, NONE, "");
          if (f->index) { e.index = declare(*f->index, false, NONE, ""); }
          e.value = f->source;
          event(e);
          body(f->body);
          scopes_.pop_back();
          break;
        }
        case SK::ForTimesStmt:
        {
          auto f = static_cast<ForTimesStmt*>(s);
          expr(f->count);
          body(f->body);
          break;
        }
        case SK::Modified:
        {
          auto m = static_cast<Modified*>(s);
          expr(m->cond);
          stmt(m->stmt);
          break;
        }
        case SK::Deferred:
          stmt(static_cast<Deferred*>(s)->stmt);
          break;
        case SK::UsingAlias:
        {
          auto u = static_cast<UsingAlias*>(s);
          expr(u->order);
          body(u->body);
          break;
        }
        case SK::WithObject:
        {
          auto w = static_cast<WithObject*>(s);
          expr(w->subject);
          body(w->body);
          break;
        }
        case SK::RawStmt:
        {
          // TL++ as written: a name in it may be given anything.
          for (const std::string& l : static_cast<RawStmt*>(s)->lines)
          {
            std::string w;
            for (std::size_t i = 0; i <= l.size(); i++)
            {
              int c = i < l.size() ? static_cast<unsigned char>(l[i]) : ' ';
              if (is_w(c))
              {
                w += static_cast<char>(c);
                continue;
              }
              if (Var* v = w.empty() ? nullptr : find(w))
              {
                Event e;
                e.kind = Event::Unknown;
                e.var = v;
                event(e);
              }
              w.clear();
            }
          }
          break;
        }
        case SK::TryStmt:
        {
          auto t = static_cast<TryStmt*>(s);
          body(t->body);
          if (t->error_var)
          {
            if (Var* v = find(*t->error_var))
            {
              Event e;
              e.kind = Event::Unknown;
              e.var = v;
              event(e);
            }
          }
          body(t->handler);
          body(t->finally);
          break;
        }
        case SK::TransactionStmt:
          body(static_cast<TransactionStmt*>(s)->body);
          break;
        case SK::SequenceStmt:
        {
          auto q = static_cast<SequenceStmt*>(s);
          body(q->body);
          if (q->error_var)
          {
            if (Var* v = find(*q->error_var))
            {
              Event e;
              e.kind = Event::Unknown;
              e.var = v;
              event(e);
            }
          }
          body(q->recover);
          break;
        }
        case SK::DefaultStmt:
          for (Assignment* a : static_cast<DefaultStmt*>(s)->pairs) { stmt(a); }
          break;
        default:
          for (Expr* e : exprs_of(s)) { expr(e); }
          break;
      }
    }

    void Typer::expr(Expr* e)
    {
      if (!e) { return; }
      switch (e->kind)
      {
        case EK::Name:
          if (Var* v = find(static_cast<Name*>(e)->name)) { names_[e] = v; }
          return;
        case EK::Lambda:
        case EK::CodeBlock:
        {
          auto b = static_cast<CodeBlock*>(e);
          scopes_.emplace_back();
          std::vector<Var*> ps;
          for (const std::string& n : b->params) { ps.push_back(declare(n, true, UNKNOWN, "")); }
          block_params_[e] = ps;
          for (Expr* x : b->body) { expr(x); }
          scopes_.pop_back();
          return;
        }
        case EK::AssignExpr:
        {
          auto a = static_cast<AssignExpr*>(e);
          expr(a->target);
          expr(a->value);
          Event ev;
          ev.kind = Event::Assign;
          ev.target = a->target;
          ev.op = a->op;
          ev.incdec = a->incdec;
          ev.value = a->value;
          event(ev);
          return;
        }
        case EK::Ref:
        {
          auto r = static_cast<Ref*>(e);
          expr(r->target);
          if (is(r->target, EK::Name))
          {
            if (Var* v = find(static_cast<Name*>(r->target)->name))
            {
              Event ev;
              ev.kind = Event::Unknown;
              ev.var = v;
              event(ev);
            }
          }
          return;
        }
        case EK::Call:
        {
          auto c = static_cast<Call*>(e);
          for (Expr* a : c->args) { expr(a); }
          Event ev;
          ev.kind = Event::CallE;
          ev.call = c;
          event(ev);
          return;
        }
        case EK::MethodCall:
        case EK::SafeCall:
        {
          auto m = static_cast<MethodCall*>(e);
          expr(m->base);
          for (Expr* a : m->args) { expr(a); }
          Event ev;
          ev.kind = Event::MethodE;
          ev.method = m;
          event(ev);
          return;
        }
        case EK::Pipeline:
        {
          auto p = static_cast<Pipeline*>(e);
          expr(p->source);
          for (std::size_t i = 0; i < p->stages.size(); i++)
          {
            for (Expr* a : p->stages[i]->args) { expr(a); }
            Event ev;
            ev.kind = Event::CallE;
            ev.call = p->stages[i];
            ev.chain = p;
            ev.stage = i;
            event(ev);
          }
          return;
        }
        default:
          for (Expr* x : subexprs(e)) { expr(x); }
          return;
      }
    }

    // ---- what each name holds -----------------------------------------------
    // Every value a Local or a Static is given, over and over until nothing
    // changes: what it holds, when they agree.
    void Typer::infer()
    {
      bool changed = true;
      auto give = [&](Var* v, const std::string& t)
      {
        if (!v || v->fixed) { return; }
        std::string n = join(v->type, t);
        if (n != v->type)
        {
          v->type = n;
          changed = true;
        }
      };
      for (int round = 0; changed && round < 20; round++)
      {
        changed = false;
        for (const Unit& u : units_)
        {
          for (const Event& e : u.events)
          {
            switch (e.kind)
            {
              case Event::Decl:
                if (e.decl->init) { give(e.var, type(e.decl->init)); }
                break;
              case Event::Assign:
              {
                if (!is(e.target, EK::Name)) { break; }
                auto it = names_.find(e.target);
                if (it == names_.end()) { break; }
                Var* v = it->second;
                if (!e.incdec.empty()) { give(v, binop("+", v->type, "N")); }
                else if (e.op == ":=" || e.op == "=" || e.op == "?=") { give(v, type(e.value)); }
                else { give(v, binop(chop(e.op), v->type, type(e.value))); }
                break;
              }
              case Event::Counter:
                give(e.var, "N");
                break;
              case Event::ForIn:
                give(e.var, elem_in(e.value));
                give(e.index, "N");
                break;
              case Event::Unknown:
                give(e.var, UNKNOWN);
                break;
              default:
                break;
            }
          }
        }
      }
      for (const std::unique_ptr<Var>& v : vars_)
      {
        if (!v->fixed && v->type == NONE) { v->type = UNKNOWN; }
      }
    }

    // What a 'for ... in' gives its name, walking source.
    std::string Typer::elem_in(const Expr* source)
    {
      if (is(source, EK::Interval)) { return "N"; }
      std::string t = type(source);
      if (t == NONE) { return NONE; }
      if (t == "C") { return "C"; }
      return elem_of(t);
    }

    // ---- what an expression is ----------------------------------------------
    std::string Typer::type(const Expr* e)
    {
      if (!e) { return UNKNOWN; }
      switch (e->kind)
      {
        case EK::Literal:
        {
          auto l = static_cast<const Literal*>(e);
          if (l->type == "Numeric") { return "N"; }
          if (l->type == "Character") { return "C"; }
          if (l->type == "Logical") { return "L"; }
          if (l->type == "Variant" && lc(l->text) == "nil") { return NIL; }
          return UNKNOWN;
        }
        case EK::Interp:
          return "C";
        case EK::ArrayLit:
        {
          auto a = static_cast<const ArrayLit*>(e);
          return a->elem.empty() ? "A" : "A<" + a->elem + ">";
        }
        case EK::HashLit:
        {
          auto h = static_cast<const HashLit*>(e);
          return h->key_type.empty() ? "H" : "H<" + h->key_type + "," + h->value_type + ">";
        }
        case EK::JsonLit:
          return "J";
        case EK::CodeBlock:
        case EK::Lambda:
          return "B";
        case EK::Name:
        {
          auto it = names_.find(e);
          return it != names_.end() ? it->second->type : UNKNOWN;
        }
        case EK::Index:
        {
          auto x = static_cast<const Index*>(e);
          std::string t = type(x->base);
          for (std::size_t i = 0; i < x->indices.size(); i++) { t = elem_of(t); }
          return t;
        }
        case EK::HashIndex:
          return value_of(type(static_cast<const HashIndex*>(e)->base));
        case EK::Binary:
        {
          auto b = static_cast<const Binary*>(e);
          if (LOGICAL.count(b->op)) { return "L"; }
          return binop(b->op, b->left ? type(b->left) : UNKNOWN, type(b->right));
        }
        case EK::AssignExpr:
        {
          auto a = static_cast<const AssignExpr*>(e);
          if (!a->incdec.empty()) { return binop("+", type(a->target), "N"); }
          if (a->op == ":=" || a->op == "=") { return type(a->value); }
          return binop(chop(a->op), type(a->target), type(a->value));
        }
        case EK::Call:
        {
          auto c = static_cast<const Call*>(e);
          return call_type(lc(c->name), c->args, nullptr);
        }
        case EK::Pipeline:
        {
          auto p = static_cast<const Pipeline*>(e);
          return chain_type(p, p->stages.size());
        }
        case EK::Guard:
        {
          auto g = static_cast<const Guard*>(e);
          return binop("?:", type(g->expr), type(g->fallback));
        }
        case EK::MethodCall:
        {
          // 'Name():New()': THashMap's a hash, JsonObject's a JSON, any
          // other an object.
          auto m = static_cast<const MethodCall*>(e);
          if (lc(m->name) != "new" || !is(m->base, EK::Call)) { return UNKNOWN; }
          std::string c = lc(static_cast<const Call*>(m->base)->name);
          return c == "thashmap" ? "H" : c == "jsonobject" ? "J" : "O";
        }
        case EK::ExprList:
        {
          auto l = static_cast<const ExprList*>(e);
          return l->items.empty() ? UNKNOWN : type(l->items.back());
        }
        case EK::AliasField:
          return field_type(static_cast<const AliasField*>(e));
        default:
          return UNKNOWN;
      }
    }

    // A field's type, from the dictionary.
    std::string Typer::field_type(const AliasField* f) const
    {
      if (!f->alias || f->field.empty() || f->base) { return UNKNOWN; }
      auto a = dictionary_.find(uc(*f->alias));
      if (a == dictionary_.end()) { return UNKNOWN; }
      auto x = a->second.find(uc(f->field));
      if (x == a->second.end()) { return UNKNOWN; }
      const std::string& t = x->second.type;
      if (t == "C" || t == "M") { return "C"; }
      if (t == "N" || t == "D" || t == "L") { return t; }
      return UNKNOWN;
    }

    // What a call gives -- 'fed' the type of what a chain feeds it, its first
    // argument then.
    std::string Typer::call_type(const std::string& name, const std::vector<Expr*>& args, const std::string* fed)
    {
      std::size_t off = fed ? 1 : 0;
      auto arg = [&](std::size_t i) -> std::string
      {
        if (fed && i == 0) { return *fed; }
        return i - off < args.size() ? type(args[i - off]) : UNKNOWN;
      };
      auto arg_expr = [&](std::size_t i) -> const Expr*
      {
        return i >= off && i - off < args.size() ? args[i - off] : nullptr;
      };
      if (auto r = RETURNS.find(name); r != RETURNS.end()) { return r->second; }
      if (name == "round" || name == "noround" || name == "int" || name == "abs")
      {
        std::string a = arg(0);
        return a == NONE ? NONE : a == "F" ? "F" : "N";
      }
      if (name == "max" || name == "min" || name == "if" || name == "iif")
      {
        std::size_t i = name[0] == 'm' ? 0 : 1;
        return binop("?:", arg(i), arg(i + 1));
      }
      if (name == "aclone" || name == "asort" || name == "asize" || name == "adel" || name == "ains"
          || name == "afill")
      {
        return arg(0);
      }
      if (name == "aadd" || name == "acopy") { return arg(1); }
      if (name == "atail") { return elem_of(arg(0)); }
      // The runtime's verbs.
      std::string s = arg(0);
      if (KEEPS.count(name)) { return s == NONE ? NONE : generic(s) && s[0] == 'A' ? s : "A"; }
      if (name == "map")
      {
        const Expr* f = arg_expr(1);
        if (is(f, EK::Lambda) || is(f, EK::CodeBlock))
        {
          auto b = static_cast<const CodeBlock*>(f);
          auto ps = block_params_.find(f);
          if (b->body.empty() || ps == block_params_.end()) { return "A"; }
          std::string t = elem_of(s);
          std::vector<std::string> was;
          for (Var* v : ps->second) { was.push_back(v->type); }
          if (!ps->second.empty()) { ps->second[0]->type = t == NONE ? UNKNOWN : t; }
          std::string r = type(b->body.back());
          for (std::size_t i = 0; i < ps->second.size(); i++) { ps->second[i]->type = was[i]; }
          return s == NONE ? NONE : array_of(r);
        }
        if (is(f, EK::Name) && !names_.count(f))
        {
          std::string n = lc(static_cast<const Name*>(f)->name);
          if (auto r = RETURNS.find(n); r != RETURNS.end()) { return array_of(r->second); }
          if (auto r = returns_.find(n); r != returns_.end()) { return array_of(r->second); }
        }
        return "A";
      }
      if (name == "count") { return "N"; }
      if (name == "asum" || name == "aprod") { return elem_of(s) == "F" ? "F" : "N"; }
      if (name == "amax" || name == "amin" || name == "first" || name == "maxby" || name == "minby")
      {
        return elem_of(s);
      }
      if (name == "anyof" || name == "allof" || name == "noneof") { return "L"; }
      if (name == "chunks" || name == "chunkby" || name == "pairwise")
      {
        return s == NONE ? NONE : generic(s) && s[0] == 'A' ? "A<" + s + ">" : "A<A>";
      }
      if (name == "enumerate" || name == "zip" || name == "pairs") { return "A<A>"; }
      if (name == "flatten" || name == "expand") { return "A"; }
      if (name == "keys") { return s == NONE ? NONE : array_of(key_of(s)); }
      if (name == "values") { return s == NONE ? NONE : array_of(value_of(s)); }
      if (name == "split") { return "A<C>"; }
      if (name == "join") { return "C"; }
      if (name == "starts" || name == "ends" || name == "contains") { return "L"; }
      if (auto r = returns_.find(name); r != returns_.end()) { return r->second; }
      return UNKNOWN;
    }

    // What a chain gives after its first n stages.
    std::string Typer::chain_type(const Pipeline* p, std::size_t stages)
    {
      std::string t = type(p->source);
      for (std::size_t i = 0; i < stages && i < p->stages.size(); i++)
      {
        const Call* c = p->stages[i];
        t = call_type(lc(c->name), c->args, &t);
      }
      return t;
    }

    // ---- what goes in -------------------------------------------------------
    // A value that goes where slot is wanted -- who: what it goes into, said
    // so; a literal array or hash, each of what it holds.
    void Typer::into(const Expr* e, const std::string& slot, const std::string& who, bool key)
    {
      if (!e || slot.empty() || slot == UNKNOWN || is(e, EK::Ref) || is(e, EK::Omitted)) { return; }
      if (is(e, EK::ArrayLit) && static_cast<const ArrayLit*>(e)->elem.empty() && generic(slot) && slot[0] == 'A')
      {
        std::string t = elem_of(slot);
        for (const Expr* x : static_cast<const ArrayLit*>(e)->items) { into(x, t, who); }
        return;
      }
      if (is(e, EK::HashLit) && static_cast<const HashLit*>(e)->key_type.empty() && generic(slot) && slot[0] == 'H')
      {
        for (const KeyValue* kv : static_cast<const HashLit*>(e)->pairs)
        {
          into(kv->key, key_of(slot), who, true);
          into(kv->value, value_of(slot), who);
        }
        return;
      }
      std::string t = type(e);
      std::string what = key ? "this key" : "this";
      switch (fits(t, slot))
      {
        case Fit::Wrong:
          errors.push_back({ line_, who + ": " + what + " is " + shown(t) + ", not " + shown(slot) + "." });
          break;
        case Fit::Unknown:
          warnings.push_back({ line_, who + ": xc cannot tell that " + what + " is " + shown(slot) + "." });
          break;
        case Fit::Ok:
          break;
      }
    }

    // What an element written to belongs to, said so: the name it is read
    // from, and what that is.
    std::string Typer::who_of(const Expr* base)
    {
      const Expr* root = base;
      while (is(root, EK::Index) || is(root, EK::HashIndex))
      {
        root = is(root, EK::Index) ? static_cast<const Index*>(root)->base : static_cast<const HashIndex*>(root)->base;
      }
      if (is(root, EK::Name)) { return "'" + static_cast<const Name*>(root)->name + "' is " + shown(type(root)); }
      std::string t = type(base);
      return std::string(t[0] == 'H' ? "the hash" : "the array") + " is " + shown(t);
    }

    // AAdd(), AFill(), ACopy(), and a function of the file whose parameters
    // are typed arrays or hashes: what each puts in, or is given.
    void Typer::call_check(const std::string& name, const std::vector<Expr*>& args, const Expr* fed_expr,
                           const std::string* fed)
    {
      std::size_t off = fed ? 1 : 0;
      auto arg = [&](std::size_t i) -> const Expr*
      {
        if (fed && i == 0) { return fed_expr; }
        return i - off < args.size() ? args[i - off] : nullptr;
      };
      auto arg_type = [&](std::size_t i) -> std::string
      {
        if (fed && i == 0) { return *fed; }
        return type(arg(i));
      };
      if (name == "aadd" || name == "afill")
      {
        std::string t = arg_type(0);
        if (generic(t) && t[0] == 'A' && arg(1))
        {
          into(arg(1), elem_of(t), fed && !fed_expr ? "the array is " + shown(t) : who_of(arg(0)));
        }
        return;
      }
      if (name == "acopy")
      {
        std::string t = type(arg(1));
        if (generic(t) && t[0] == 'A' && arg(0)) { into(arg(0), t, who_of(arg(1))); }
        return;
      }
      auto f = functions_.find(name);
      if (f == functions_.end()) { return; }
      const std::vector<const Param*>& ps = f->second.params;
      for (std::size_t i = 0; i < ps.size(); i++)
      {
        if (!ps[i] || ps[i]->container.empty() || !arg(i)) { continue; }
        std::string who = "the parameter '" + ps[i]->name + "' of " + f->second.name + "() is "
                          + shown(ps[i]->container);
        if (fed && i == 0)
        {
          switch (fits(*fed, ps[i]->container))
          {
            case Fit::Wrong:
              errors.push_back({ line_, who + ": this is " + shown(*fed) + ", not " + shown(ps[i]->container) + "." });
              break;
            case Fit::Unknown:
              warnings.push_back({ line_, who + ": xc cannot tell that this is " + shown(ps[i]->container) + "." });
              break;
            case Fit::Ok:
              break;
          }
          continue;
        }
        into(arg(i), ps[i]->container, who);
      }
    }

    void Typer::check(const Unit& u)
    {
      ret_ = u.ret;
      ret_name_ = u.name;
      for (const Event& e : u.events)
      {
        line_ = e.line;
        switch (e.kind)
        {
          case Event::Decl:
            if (!e.var->container.empty() && e.decl->init && !e.decl->init_made)
            {
              into(e.decl->init, e.var->container, "'" + e.var->name + "' is " + shown(e.var->container));
            }
            break;
          case Event::Assign:
          {
            if (is(e.target, EK::Name))
            {
              auto it = names_.find(e.target);
              Var* v = it != names_.end() ? it->second : nullptr;
              if (v && !v->container.empty() && e.incdec.empty() && (e.op == ":=" || e.op == "=" || e.op == "?="))
              {
                into(e.value, v->container, "'" + v->name + "' is " + shown(v->container));
              }
              break;
            }
            const Expr* base = is(e.target, EK::Index) ? static_cast<const Index*>(e.target)->base
                               : is(e.target, EK::HashIndex) ? static_cast<const HashIndex*>(e.target)->base
                                                             : nullptr;
            if (!base) { break; }
            std::string slot = type(e.target);
            if (slot == UNKNOWN || slot == NONE) { break; }
            std::string who = who_of(base);
            if (is(e.target, EK::HashIndex))
            {
              into(static_cast<const HashIndex*>(e.target)->key, key_of(type(base)), who, true);
            }
            if (!e.incdec.empty()) { break; }
            if (e.op == ":=" || e.op == "=" || e.op == "?=")
            {
              into(e.value, slot, who);
              break;
            }
            // 'a[i] += v': what the operator makes of the two.
            std::string v = type(e.value);
            std::string r = binop(chop(e.op), slot, v);
            if (v == UNKNOWN || v == NONE)
            {
              warnings.push_back({ line_, who + ": xc cannot tell that this is " + shown(slot) + "." });
            }
            else if (r == UNKNOWN || fits(r, slot) == Fit::Wrong)
            {
              errors.push_back({ line_, who + ": this is " + shown(v) + ", and '" + e.op + "' makes no " + shown(slot)
                                        + " of it." });
            }
            break;
          }
          case Event::CallE:
          {
            if (e.chain)
            {
              std::string fed = chain_type(e.chain, e.stage);
              const Expr* fed_expr = e.stage == 0 ? e.chain->source : nullptr;
              call_check(lc(e.call->name), e.call->args, fed_expr, &fed);
            }
            else
            {
              call_check(lc(e.call->name), e.call->args, nullptr, nullptr);
            }
            break;
          }
          case Event::MethodE:
          {
            const MethodCall* m = e.method;
            std::string t = type(m->base);
            if (lc(m->name) == "set" && m->args.size() >= 2 && generic(t) && t[0] == 'H')
            {
              std::string who = who_of(m->base);
              into(m->args[0], key_of(t), who, true);
              into(m->args[1], value_of(t), who);
            }
            break;
          }
          case Event::Return:
            if (!ret_.empty() && e.value) { into(e.value, ret_, ret_name_ + "() returns " + shown(ret_)); }
            break;
          default:
            break;
        }
      }
    }
  }

  Checked typed_problems(const Program* p, const Dictionary& dictionary)
  {
    Typer t(p, dictionary);
    t.run();
    return Checked{ std::move(t.errors), std::move(t.warnings) };
  }
}
