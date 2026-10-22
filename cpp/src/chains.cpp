// xc -- chains (see chains.h).

#include "chains.h"

#include <unordered_set>

#include "chars.h"
#include "walk.h"

namespace xc
{
  namespace
  {
    using Set = std::unordered_set<std::string>;

    // xtpl's runtime verbs: a call to one of these names -- not a method --
    // is the runtime's 'u_xtpl_<name>', wherever it is.
    const Set VERBS =
    {
      "map", "filter", "reject", "reduce", "fold", "take", "drop", "distinct", "sort", "sortby",
      "reverse", "flatten", "enumerate", "chunks", "zip", "asum", "aprod", "amax", "amin", "anyof",
      "allof", "noneof", "keys", "values", "pairs", "takewhile", "dropwhile", "chunkby", "first",
      "count", "distinctadjacent", "maxby", "minby", "scan", "expand", "tap", "pairwise", "queue",
      "split", "join", "starts", "ends", "contains", "apick", "aroll", "setmaxroll",
    };

    const Set FUSED =
    {
      "filter", "reject", "map", "tap", "take", "takewhile", "drop", "dropwhile", "expand",
      "distinctadjacent", "scan", "pairwise", "distinct",
    };

    const Set TERMINAL =
    {
      "asum", "count", "anyof", "allof", "noneof", "first", "aprod", "amax", "amin", "join",
      "reduce", "fold", "maxby", "minby", "chunkby",
    };

    // The stages a chain from a source has fused from the start.
    const Set FIRST_FUSED =
    {
      "filter", "reject", "map", "tap", "take", "takewhile", "drop", "dropwhile", "expand",
      "distinctadjacent",
    };

    // The terminals a chain from a source has had from the start.
    const Set FIRST_TERMINALS = { "asum", "count", "anyof", "allof", "noneof", "first" };

    // The stages that stop the walk with an 'Exit': after an 'expand' they
    // apply to what was collected instead.
    const Set EXITS = { "take", "takewhile", "anyof", "allof", "noneof", "first" };

    const Set TAKES_BLOCK =
    {
      "map", "filter", "reject", "tap", "takewhile", "dropwhile", "expand", "maxby", "minby",
      "sortby", "chunkby", "distinctadjacent", "first", "count", "anyof", "allof", "noneof",
    };

    bool is_lambda(const Expr* e) { return e && e->kind == EK::Lambda; }
    bool is_name(const Expr* e) { return e && e->kind == EK::Name; }

    // Whether a step assigns one of its own parameters.
    bool writes_params(const Lambda* l)
    {
      std::unordered_set<std::string> params;
      for (const std::string& p : l->params) { params.insert(lc(p)); }
      bool writes = false;
      for (Expr* b : l->body)
      {
        walk_expr(b, [&](Expr* x)
        {
          if (x->kind != EK::AssignExpr) { return; }
          const Expr* t = static_cast<AssignExpr*>(x)->target;
          if (is_name(t) && params.count(lc(static_cast<const Name*>(t)->name))) { writes = true; }
        });
      }
      return writes;
    }

    // Whether a stage can be written into a loop: its block written in the
    // stage (a function name is one too), with what it needs.
    bool stage_inlinable(const Call* st, const Declared& declared)
    {
      std::string n = lc(st->name);
      const std::vector<Expr*>& a = st->args;
      // A lambda of one parameter, or a function's name -- a Name that is
      // not a variable of the function, where the verb takes a block.
      bool block = a.size() == 1
                   && ((is_lambda(a[0]) && static_cast<const Lambda*>(a[0])->params.size() == 1)
                       || (TAKES_BLOCK.count(n) && is_name(a[0])
                           && !declared(lc(static_cast<const Name*>(a[0])->name))));
      if (n == "take" || n == "drop") { return a.size() == 1; }
      if (n == "distinct") { return a.empty(); }
      if (n == "distinctadjacent" || n == "count" || n == "first") { return a.empty() || block; }
      if (n == "asum" || n == "aprod" || n == "amax" || n == "amin" || n == "pairwise") { return a.empty(); }
      if (n == "scan")
      {
        if (a.size() != 2 || !is_lambda(a[0])) { return false; }
        auto l = static_cast<const Lambda*>(a[0]);
        if (l->params.size() != 2) { return false; }
        return !writes_params(l);
      }
      if (n == "join") { return a.size() <= 1; }
      if (n == "reduce" || n == "fold")
      {
        // A step that assigns its own parameters cannot have them written
        // as the loop's variables: xtpl binds them, xc leaves it a call.
        if (a.size() != (n == "reduce" ? 2u : 1u) || !is_lambda(a[0])) { return false; }
        auto l = static_cast<const Lambda*>(a[0]);
        if (l->params.size() != 2) { return false; }
        return !writes_params(l);
      }
      return block;
    }

    // Whether an array chain, split, runs as a loop where it stands: two
    // stages that fuse, or one that carries a block. Run for its effects:
    // all of its stages fuse, and none is a terminal.
    bool array_chain_fuses(const Split& split, bool for_effect)
    {
      std::size_t fused = split.fused.size();
      std::size_t terminal = split.terminal ? 1 : 0;
      if (for_effect) { return fused >= 1 && !terminal && split.rest.empty(); }
      if (fused + terminal >= 2) { return true; }
      if (fused + terminal != 1) { return false; }
      const Call* st = fused ? split.fused[0] : split.terminal;
      for (const Expr* a : st->args)
      {
        if (is_lambda(a)) { return true; }
      }
      return TAKES_BLOCK.count(lc(st->name)) && !st->args.empty() && is_name(st->args[0]);
    }
  }

  bool is_runtime_verb(const std::string& name) { return VERBS.count(lc(name)) > 0; }

  bool takes_block(const std::string& lc_name) { return TAKES_BLOCK.count(lc_name) > 0; }

  const Expr* source_call(const Expr* e)
  {
    if (e && e->kind == EK::Pipeline && is_source(static_cast<const Pipeline*>(e)->source))
    {
      return static_cast<const Pipeline*>(e)->source;
    }
    if (is_source(e)) { return e; }
    return nullptr;
  }

  std::string source_kind(const Expr* src)
  {
    return src->kind == EK::Interval ? "range" : lc(static_cast<const Call*>(src)->name);
  }

  bool is_source(const Expr* e)
  {
    if (!e) { return false; }
    if (e->kind == EK::Interval) { return true; }
    if (e->kind != EK::Call) { return false; }
    std::string n = lc(static_cast<const Call*>(e)->name);
    return n == "rows" || n == "lines";
  }

  Split split_stages(const std::vector<Call*>& stages, bool array, const Declared& declared)
  {
    Split s;
    bool expanded = false;
    for (Call* st : stages)
    {
      std::string n = lc(st->name);
      bool free = s.rest.empty() && !s.terminal && !(expanded && EXITS.count(n));
      if (free && FUSED.count(n) && ((!array && FIRST_FUSED.count(n)) || stage_inlinable(st, declared)))
      {
        s.fused.push_back(st);
        expanded = expanded || n == "expand";
      }
      else if (free && TERMINAL.count(n) && ((!array && FIRST_TERMINALS.count(n)) || stage_inlinable(st, declared)))
      {
        s.terminal = st;
      }
      else
      {
        s.rest.push_back(st);
      }
    }
    return s;
  }

  int fuse_from(const std::vector<Call*>& stages, const Declared& declared, bool for_effect)
  {
    for (std::size_t i = 0; i < stages.size(); i++)
    {
      std::vector<Call*> from(stages.begin() + static_cast<std::ptrdiff_t>(i), stages.end());
      Split split = split_stages(from, true, declared);
      if (array_chain_fuses(split, for_effect && split.rest.empty())) { return static_cast<int>(i); }
    }
    return -1;
  }

  std::unordered_set<std::string> declared_names(const std::vector<Param*>& params, const Body& body)
  {
    std::unordered_set<std::string> out;
    for (const Param* q : params) { out.insert(lc(q->name)); }
    walk(body, [&](Stmt* s)
    {
      switch (s->kind)
      {
        case SK::Declaration:
          for (const Declarator* d : static_cast<Declaration*>(s)->declarators) { out.insert(lc(d->name)); }
          break;
        case SK::ForStmt:
        {
          auto f = static_cast<ForStmt*>(s);
          if (f->var_local) { out.insert(lc(f->var)); }
          break;
        }
        case SK::ForInStmt:
        {
          auto f = static_cast<ForInStmt*>(s);
          out.insert(lc(f->elem));
          if (f->index) { out.insert(lc(*f->index)); }
          break;
        }
        case SK::IfStmt:
          if (auto d = static_cast<IfStmt*>(s)->header_decl) { out.insert(lc(d->name)); }
          break;
        case SK::WhileStmt:
          if (auto d = static_cast<WhileStmt*>(s)->header_decl) { out.insert(lc(d->name)); }
          break;
        case SK::CaseStmt:
          if (auto d = static_cast<CaseStmt*>(s)->subject_decl) { out.insert(lc(d->name)); }
          break;
        default:
          break;
      }
    });
    return out;
  }

  bool record_misused(const Lambda* l)
  {
    std::string p = lc(l->params[0]);
    std::unordered_set<const Expr*> field_base;
    for (Expr* b : l->body)
    {
      walk_expr(b, [&](Expr* x)
      {
        if (x->kind != EK::Member && x->kind != EK::SafeMember) { return; }
        const Expr* base = static_cast<Member*>(x)->base;
        if (is_name(base) && lc(static_cast<const Name*>(base)->name) == p) { field_base.insert(base); }
      });
    }
    bool misused = false;
    for (Expr* b : l->body)
    {
      walk_expr(b, [&](Expr* x)
      {
        if (x->kind == EK::Name && lc(static_cast<Name*>(x)->name) == p && !field_base.count(x)) { misused = true; }
      });
    }
    return misused;
  }

  std::vector<std::string> chain_problems(const Expr* chain, bool for_effect, const Declared& declared)
  {
    std::vector<std::string> p;
    const Expr* call = source_call(chain);
    std::string kind = source_kind(call);
    std::vector<Call*> stages;
    if (chain->kind == EK::Pipeline) { stages = static_cast<const Pipeline*>(chain)->stages; }
    bool array = chain->kind == EK::Pipeline && !is_source(static_cast<const Pipeline*>(chain)->source);
    Split split = split_stages(stages, array, declared);
    // A Name that is not a variable, where the verb takes a block: a function.
    auto function_name = [&](const std::string& verb, const Expr* e)
    {
      return takes_block(verb) && is_name(e) && !declared(lc(static_cast<const Name*>(e)->name));
    };
    if (kind == "rows")
    {
      std::size_t n = static_cast<const Call*>(call)->args.size();
      if (!(1 <= n && n <= 2)) { p.push_back("'rows()' with no alias, or more than an alias and a key"); }
    }
    if (kind == "lines" && static_cast<const Call*>(call)->args.size() != 1)
    {
      p.push_back("'lines()' with no path, or more than one");
    }
    std::string what = kind == "range" ? "a range" : kind + "()";
    std::vector<const Call*> run(split.fused.begin(), split.fused.end());
    if (split.terminal) { run.push_back(split.terminal); }
    static const Set needs_lambda =
    {
      "filter", "reject", "map", "tap", "takewhile", "dropwhile", "expand", "anyof", "allof", "noneof",
    };
    for (const Call* st : run)
    {
      std::string n = lc(st->name);
      bool needs = needs_lambda.count(n)
                   || ((n == "count" || n == "first" || n == "distinctadjacent") && !st->args.empty());
      bool one = st->args.size() == 1
                 && ((is_lambda(st->args[0]) && static_cast<const Lambda*>(st->args[0])->params.size() == 1)
                     || function_name(n, st->args[0]));
      if (needs && !one) { p.push_back("'" + n + "' over " + what + " without its lambda written in the stage"); }
      if ((n == "take" || n == "drop") && st->args.size() != 1)
      {
        p.push_back("'" + n + "' over " + what + " without a count");
      }
    }
    if (kind == "rows")
    {
      bool mapped = false;
      for (const Call* st : run)
      {
        if (mapped) { break; }
        const Expr* l = st->args.empty() ? nullptr : st->args[0];
        std::string n = lc(st->name);
        if ((is_lambda(l) && static_cast<const Lambda*>(l)->params.size() == 1
             && record_misused(static_cast<const Lambda*>(l)))
            || function_name(n, l))
        {
          p.push_back("over rows() the element is the current record, so it can only name a field");
        }
        if (n == "distinctadjacent" && st->args.empty())
        {
          p.push_back("over rows() 'distinctAdjacent' needs a key: the record is not a value to compare");
        }
        if (n == "scan" || n == "pairwise")
        {
          p.push_back("over rows() '" + n + "' needs a value -- map the record to one first");
        }
        if (n == "map" || n == "expand") { mapped = true; }
      }
      std::string t = split.terminal ? lc(split.terminal->name) : "";
      bool needs_value = (!t.empty() && t != "anyof" && t != "allof" && t != "noneof" && t != "count")
                         || (t.empty() && (!split.rest.empty() || !for_effect));
      if (needs_value && !mapped)
      {
        p.push_back("over rows() nothing to collect before a 'map' makes the record a value");
      }
    }
    return p;
  }
}
