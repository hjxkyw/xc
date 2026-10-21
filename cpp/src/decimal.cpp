// xc -- TL++'s Decimal ('F') (see decimal.h).

#include "decimal.h"

#include <functional>

#include "chars.h"
#include "text.h"
#include "walk.h"

namespace xc
{
  namespace
  {
    std::string last_word(const std::optional<std::string>& written)
    {
      if (!written) { return ""; }
      std::vector<std::string> w = words(*written);
      return w.empty() ? "" : lc(w.back());
    }

    bool is(const Expr* e, EK k) { return e && e->kind == k; }

    const std::unordered_set<std::string> DEC_CALLS =
    {
      "dec_create", "dec_add", "dec_sub", "dec_mul", "dec_div", "dec_mod", "dec_pow", "dec_resize", "dec_rescale",
      "dec_round",
    };

    bool compound(const std::string& op) { return op == "+=" || op == "-=" || op == "*=" || op == "/=" || op == "%="; }

    // How a function of the file is called: a user function with its 'u_'.
    std::string called_as(const FunctionDef* f)
    {
      std::string t = lc(f->type);
      if (t == "user") { return "u_" + lc(f->name); }
      if (t.empty() || t == "static") { return lc(f->name); }
      return "";
    }

    // The whole part (no leading zeros, at least one digit) and the decimals
    // of a number literal, its digit separators dropped.
    std::pair<std::string, std::string> literal_parts(const std::string& text)
    {
      std::string t;
      for (char c : text)
      {
        if (c != '\'') { t += c; }
      }
      std::size_t dot = t.find('.');
      std::string whole = dot == std::string::npos ? t : t.substr(0, dot);
      std::string decimals = dot == std::string::npos ? "" : t.substr(dot + 1);
      std::size_t nz = whole.find_first_not_of('0');
      whole = nz == std::string::npos ? "0" : whole.substr(nz);
      return { whole, decimals };
    }
  }

  bool decimal_word(const std::optional<std::string>& written) { return last_word(written) == "decimal"; }

  bool numeric_word(const std::optional<std::string>& written)
  {
    std::string w = last_word(written);
    return w == "numeric" || w == "integer" || w == "double";
  }

  bool arithmetic(const std::string& op)
  {
    return op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "**" || op == "^";
  }

  bool comparison(const std::string& op)
  {
    return op == "==" || op == "=" || op == "!=" || op == "<>" || op == "#" || op == "<" || op == ">" || op == "<="
           || op == ">=";
  }

  std::string dec_function(const std::string& op)
  {
    if (op == "+") { return "DEC_ADD"; }
    if (op == "-") { return "DEC_SUB"; }
    if (op == "*") { return "DEC_MUL"; }
    if (op == "/") { return "DEC_DIV"; }
    if (op == "%") { return "DEC_MOD"; }
    return "DEC_POW";
  }

  bool number_literal(const Expr* e)
  {
    return is(e, EK::Literal) && static_cast<const Literal*>(e)->type == "Numeric";
  }

  int literal_digits(const std::string& text)
  {
    auto [whole, decimals] = literal_parts(text);
    return static_cast<int>(whole.size() + decimals.size());
  }

  std::string dec_create(const std::string& text)
  {
    auto [whole, decimals] = literal_parts(text);
    std::string value = decimals.empty() ? whole : whole + "." + decimals;
    return "DEC_CREATE(\"" + value + "\", " + std::to_string(whole.size() + decimals.size()) + ", "
           + std::to_string(decimals.size()) + ")";
  }

  // ---- what is a Decimal in a file ------------------------------------------
  void Decimals::file(const Program* p)
  {
    on_ = true;
    for (const FunctionDef* f : p->functions)
    {
      std::string name = called_as(f);
      if (name.empty()) { continue; }
      if (decimal_word(f->rettype_word)) { functions_.insert(name); }
      if (numeric_word(f->rettype_word)) { numeric_functions_.insert(name); }
      std::vector<bool> ds;
      std::vector<bool> ns;
      bool any = false;
      bool any_n = false;
      for (const Param* q : f->params)
      {
        ds.push_back(q && decimal_word(q->type_word));
        ns.push_back(q && numeric_word(q->type_word));
        any = any || ds.back();
        any_n = any_n || ns.back();
      }
      if (any) { params_[name] = ds; }
      if (any_n) { numeric_params_[name] = ns; }
    }
    for (const Declaration* d : p->statics)
    {
      for (const Declarator* v : d->declarators)
      {
        if (decimal_word(v->typespec_text)) { statics_.insert(lc(v->name)); }
        if (numeric_word(v->typespec_text)) { static_numerics_.insert(lc(v->name)); }
      }
    }
    names_ = statics_;
    numerics_ = static_numerics_;
  }

  void Decimals::function(const std::vector<Param*>& params, const Body& body)
  {
    names_ = statics_;
    numerics_ = static_numerics_;
    for (const Param* q : params)
    {
      if (q && decimal_word(q->type_word)) { names_.insert(lc(q->name)); }
      if (q && numeric_word(q->type_word)) { numerics_.insert(lc(q->name)); }
    }
    walk(body, [&](Stmt* s)
    {
      if (s->kind != SK::Declaration) { return; }
      for (const Declarator* v : static_cast<Declaration*>(s)->declarators)
      {
        if (decimal_word(v->typespec_text)) { names_.insert(lc(v->name)); }
        if (numeric_word(v->typespec_text)) { numerics_.insert(lc(v->name)); }
      }
    });
  }

  bool Decimals::decimal(const Expr* e) const
  {
    if (!e || !on_) { return false; }
    switch (e->kind)
    {
      case EK::Name:
        return names_.count(lc(static_cast<const Name*>(e)->name)) > 0;
      case EK::Call:
      {
        auto c = static_cast<const Call*>(e);
        std::string n = lc(c->name);
        if (DEC_CALLS.count(n) || functions_.count(n)) { return true; }
        if ((n == "if" || n == "iif") && c->args.size() == 3) { return decimal(c->args[1]) || decimal(c->args[2]); }
        if ((n == "round" || n == "noround") && c->args.size() == 2) { return decimal(c->args[0]); }
        return false;
      }
      case EK::Binary:
      {
        auto b = static_cast<const Binary*>(e);
        if (b->op == "neg") { return decimal(b->right); }
        return arithmetic(b->op) && (decimal(b->left) || decimal(b->right));
      }
      case EK::AssignExpr:
        return decimal(static_cast<const AssignExpr*>(e)->target);
      default:
        return false;
    }
  }

  bool Decimals::numeric(const Expr* e) const
  {
    if (!e || decimal(e)) { return false; }
    if (is(e, EK::Name))
    {
      std::string n = lc(static_cast<const Name*>(e)->name);
      return numerics_.count(n) > 0 && !names_.count(n);
    }
    if (is(e, EK::Call))
    {
      std::string n = lc(static_cast<const Call*>(e)->name);
      return n == "dec_to_dbl" || numeric_functions_.count(n) > 0;
    }
    if (is(e, EK::Binary))
    {
      auto b = static_cast<const Binary*>(e);
      if (b->op == "neg") { return numeric(b->right); }
      return arithmetic(b->op) && (numeric(b->left) || numeric(b->right));
    }
    return false;
  }

  bool Decimals::constant(const Expr* e) const
  {
    if (number_literal(e)) { return true; }
    if (!is(e, EK::Binary)) { return false; }
    auto b = static_cast<const Binary*>(e);
    if (b->op == "neg") { return constant(b->right); }
    return arithmetic(b->op) && (constant(b->left) || decimal(b->left)) && (constant(b->right) || decimal(b->right));
  }

  const std::vector<bool>* Decimals::params_of(const Expr* call) const
  {
    if (!is(call, EK::Call)) { return nullptr; }
    auto it = params_.find(lc(static_cast<const Call*>(call)->name));
    return it == params_.end() ? nullptr : &it->second;
  }

  const std::vector<bool>* Decimals::numeric_params_of(const Expr* call) const
  {
    if (!is(call, EK::Call)) { return nullptr; }
    auto it = numeric_params_.find(lc(static_cast<const Call*>(call)->name));
    return it == numeric_params_.end() ? nullptr : &it->second;
  }

  // ---- where a value goes ---------------------------------------------------
  DecimalValues decimal_values(const Decimals& dec, const Body& body, Returns returns)
  {
    DecimalValues out;
    auto into = [&](Expr* target, Expr* value)
    {
      if (!value) { return; }
      if (dec.decimal(target)) { out.into_decimal.insert(value); }
      else if (is(target, EK::Name) && dec.numeric(target)) { out.into_numeric.insert(value); }
    };
    auto args = [&](Expr* x)
    {
      auto c = static_cast<Call*>(x);
      const std::vector<bool>* ds = dec.params_of(x);
      const std::vector<bool>* ns = dec.numeric_params_of(x);
      for (std::size_t i = 0; i < c->args.size(); i++)
      {
        if (!c->args[i]) { continue; }
        if (ds && i < ds->size() && (*ds)[i]) { out.into_decimal.insert(c->args[i]); }
        if (ns && i < ns->size() && (*ns)[i]) { out.into_numeric.insert(c->args[i]); }
      }
    };
    walk(body, [&](Stmt* s)
    {
      switch (s->kind)
      {
        case SK::Declaration:
          for (const Declarator* v : static_cast<Declaration*>(s)->declarators)
          {
            if (v->init && decimal_word(v->typespec_text)) { out.into_decimal.insert(v->init); }
            if (v->init && numeric_word(v->typespec_text)) { out.into_numeric.insert(v->init); }
          }
          break;
        case SK::Assignment:
        {
          auto a = static_cast<Assignment*>(s);
          if (a->op == ":=" || a->op == "=") { into(a->target, a->value); }
          break;
        }
        case SK::ReturnStmt:
        {
          Expr* v = static_cast<ReturnStmt*>(s)->value;
          if (returns.decimal && v) { out.into_decimal.insert(v); }
          if (returns.numeric && v) { out.into_numeric.insert(v); }
          break;
        }
        default:
          break;
      }
      for (Expr* e : exprs_of(s))
      {
        walk_expr(e, [&](Expr* x)
        {
          if (x->kind == EK::AssignExpr)
          {
            auto a = static_cast<AssignExpr*>(x);
            if (a->op == ":=" || a->op == "=") { into(a->target, a->value); }
          }
          else if (x->kind == EK::Call)
          {
            args(x);
          }
        });
      }
    });
    return out;
  }

  // ---- what is refused ------------------------------------------------------
  std::vector<Finding> decimal_problems(const Program* p, std::optional<std::string_view> source, bool advpl)
  {
    std::vector<Finding> found;
    if (advpl) { return found; }
    Decimals d;
    d.file(p);
    auto shown = [&](const Expr* e) -> std::string
    {
      if (is(e, EK::Name)) { return static_cast<const Name*>(e)->name; }
      if (source && e->from >= 0 && e->to <= static_cast<int>(source->size()))
      {
        return trim(std::string(source->substr(static_cast<std::size_t>(e->from),
                                               static_cast<std::size_t>(e->to - e->from))));
      }
      return "a value";
    };
    // A value that goes into a Decimal, or meets one.
    std::function<void(const Expr*, int)> into = [&](const Expr* e, int line)
    {
      if (!e) { return; }
      int at = e->line > 0 ? e->line : line;
      if (number_literal(e))
      {
        const std::string& t = static_cast<const Literal*>(e)->text;
        int n = literal_digits(t);
        if (n > DECIMAL_DIGITS)
        {
          found.push_back({ at, "'" + t + "' has " + std::to_string(n) + " digits, and a Decimal holds "
                                + std::to_string(DECIMAL_DIGITS) + " at most." });
        }
        return;
      }
      if (d.numeric(e))
      {
        found.push_back({ at, "'" + shown(e) + "' is a number, and meets a Decimal: TL++ takes no Numeric with a "
                              + "Decimal (\"Incompatible types between F and N\") -- make it one with "
                              + "DEC_CREATE(" + shown(e) + ", digits, decimals)." });
        return;
      }
      if (is(e, EK::Binary))
      {
        auto b = static_cast<const Binary*>(e);
        if (b->op == "neg") { into(b->right, at); }
        else if (arithmetic(b->op) && d.constant(e)) { into(b->left, at); into(b->right, at); }
      }
    };
    auto one = [&](const std::vector<Param*>& params, const Body& body, bool returns_decimal)
    {
      d.function(params, body);
      walk(body, [&](Stmt* s)
      {
        switch (s->kind)
        {
          case SK::Declaration:
            for (const Declarator* v : static_cast<Declaration*>(s)->declarators)
            {
              if (decimal_word(v->typespec_text)) { into(v->init, v->line); }
            }
            break;
          case SK::Assignment:
          {
            auto a = static_cast<Assignment*>(s);
            if (d.decimal(a->target)) { into(a->value, s->line); }
            if (compound(a->op) && d.numeric(a->target) && d.decimal(a->value))
            {
              found.push_back({ s->line, "'" + shown(a->value) + "' is a Decimal, and meets the number '"
                                         + shown(a->target) + "': TL++ takes no Decimal with a Numeric -- make it "
                                         + "a number with DEC_TO_DBL(" + shown(a->value) + ")." });
            }
            break;
          }
          case SK::ReturnStmt:
            if (returns_decimal) { into(static_cast<ReturnStmt*>(s)->value, s->line); }
            break;
          default:
            break;
        }
        for (Expr* x : exprs_of(s))
        {
          walk_expr(x, [&](Expr* y)
          {
            if (is(y, EK::Binary))
            {
              auto b = static_cast<Binary*>(y);
              if (arithmetic(b->op) && d.decimal(b))
              {
                into(b->left, s->line);
                into(b->right, s->line);
              }
              else if (comparison(b->op) && (d.decimal(b->left) || d.decimal(b->right)))
              {
                if (!d.decimal(b->left)) { into(b->left, s->line); }
                if (!d.decimal(b->right)) { into(b->right, s->line); }
              }
            }
            else if (is(y, EK::AssignExpr))
            {
              auto a = static_cast<AssignExpr*>(y);
              if (d.decimal(a->target)) { into(a->value, s->line); }
            }
            else if (const std::vector<bool>* ps = d.params_of(y))
            {
              auto c = static_cast<Call*>(y);
              for (std::size_t i = 0; i < c->args.size() && i < ps->size(); i++)
              {
                if ((*ps)[i]) { into(c->args[i], s->line); }
              }
            }
          });
        }
      });
    };
    d.function({}, {});
    for (const Declaration* s : p->statics)
    {
      for (const Declarator* v : s->declarators)
      {
        if (decimal_word(v->typespec_text)) { into(v->init, v->line); }
      }
    }
    for (const FunctionDef* f : p->functions) { one(f->params, f->body, decimal_word(f->rettype_word)); }
    for (const MethodImpl* m : p->methods) { one(m->params, m->body, decimal_word(m->returns)); }
    return found;
  }
}
