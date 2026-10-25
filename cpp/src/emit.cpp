// xc -- from the tree back to TL++: the file, the functions, the statements
// (see emit.h; the expressions and the chains are in lower.cpp).

#include "emit.h"

#include <algorithm>
#include <unordered_set>

#include "chains.h"
#include "chars.h"
#include "emitter.h"
#include "text.h"
#include "walk.h"

namespace xc
{
  namespace
  {
    std::string what_of(const std::vector<Finding>& found)
    {
      std::string m;
      for (const Finding& f : found)
      {
        if (!m.empty()) { m += "\n"; }
        m += "line " + std::to_string(f.line) + ": " + f.message + " is not lowered yet";
      }
      return m;
    }

    const Declaration* as_decl(const Stmt* s)
    {
      return s->kind == SK::Declaration ? static_cast<const Declaration*>(s) : nullptr;
    }

    // The locals a statement declares in its header: 'if local x := ...',
    // 'for local i := ...', 'for x, i in ...', 'do case with local x := ...'.
    std::vector<std::string> header_names(const Stmt* s)
    {
      switch (s->kind)
      {
        case SK::IfStmt:
          if (auto d = static_cast<const IfStmt*>(s)->header_decl) { return { d->name }; }
          return {};
        case SK::WhileStmt:
          if (auto d = static_cast<const WhileStmt*>(s)->header_decl) { return { d->name }; }
          return {};
        case SK::ForStmt:
        {
          auto f = static_cast<const ForStmt*>(s);
          if (f->var_local) { return { f->var }; }
          return {};
        }
        case SK::ForInStmt:
        {
          auto f = static_cast<const ForInStmt*>(s);
          if (f->index) { return { f->elem, *f->index }; }
          return { f->elem };
        }
        case SK::CaseStmt:
          if (auto d = static_cast<const CaseStmt*>(s)->subject_decl) { return { d->name }; }
          return {};
        default:
          return {};
      }
    }

    // A whole word of a line, in lower case: << k >>.
    bool has_word(const std::string& line, const std::string& k)
    {
      if (k.empty()) { return false; }
      std::string l = lc(line);
      for (std::size_t p = l.find(k); p != std::string::npos; p = l.find(k, p + 1))
      {
        bool left = is_w(static_cast<unsigned char>(k.front()))
                    && (p == 0 || !is_w(static_cast<unsigned char>(l[p - 1])));
        std::size_t e = p + k.size();
        bool right = is_w(static_cast<unsigned char>(k.back()))
                     && (e == l.size() || !is_w(static_cast<unsigned char>(l[e])));
        if (left && right) { return true; }
      }
      return false;
    }

    // Whether the variable name can be reached after its block -- in stmts,
    // its block, or in exprs, its header (XC::Emit's escapes).
    bool escapes(const std::string& name, const Body& stmts, const std::vector<Expr*>& exprs)
    {
      std::string k = lc(name);
      bool found = false;
      std::function<void(const Expr*, bool, const std::unordered_set<std::string>&)> scan =
        [&](const Expr* e, bool captured, const std::unordered_set<std::string>& shadow)
      {
        if (found || !e) { return; }
        if (e->kind == EK::CodeBlock || e->kind == EK::Lambda)
        {
          auto c = static_cast<const CodeBlock*>(e);
          std::unordered_set<std::string> s = shadow;
          for (const std::string& p : c->params) { s.insert(lc(p)); }
          for (const Expr* b : c->body) { scan(b, true, s); }
          return;
        }
        if (e->kind == EK::Ref)
        {
          const Expr* t = static_cast<const Ref*>(e)->target;
          if (is_expr(t, EK::Name) && lc(static_cast<const Name*>(t)->name) == k && !shadow.count(k)) { found = true; }
        }
        else if (e->kind == EK::Name)
        {
          if (captured && lc(static_cast<const Name*>(e)->name) == k && !shadow.count(k)) { found = true; }
        }
        for (const Expr* x : subexprs(e)) { scan(x, captured, shadow); }
      };
      const std::unordered_set<std::string> none;
      for (const Expr* e : exprs) { scan(e, false, none); }
      walk(stmts, [&](Stmt* s)
      {
        if (s->kind == SK::RawStmt)
        {
          for (const std::string& l : static_cast<RawStmt*>(s)->lines)
          {
            if (has_word(l, k))
            {
              found = true;
              break;
            }
          }
        }
        else if (s->kind == SK::Deferred)
        {
          walk(Body{ static_cast<Deferred*>(s)->stmt }, [&](Stmt* d)
          {
            for (const Expr* e : exprs_of(d)) { scan(e, true, none); }
          });
        }
        else
        {
          for (const Expr* e : exprs_of(s)) { scan(e, false, none); }
        }
      });
      return found;
    }

    // A body's prologue: its first declarations of locals and statics.
    std::vector<const Declaration*> prologue_of(const Body& body)
    {
      std::vector<const Declaration*> p;
      for (const Stmt* s : body)
      {
        auto d = as_decl(s);
        if (!d || !(d->scope == "local" || d->scope == "static")) { break; }
        p.push_back(d);
      }
      return p;
    }
  }

  // ---- shared ---------------------------------------------------------------
  std::string attrs_text(const std::vector<std::string>& a) { return "[" + join(a, ", ") + "]"; }

  // What a declarator was, for a comment where xc writes it.
  std::string note_of(const Declarator* d, const std::string& shown)
  {
    Lines w;
    if (lc(shown) != lc(d->name)) { w.push_back(d->name); }
    if (!d->attributes.empty()) { w.push_back(attrs_text(d->attributes)); }
    return join(w, " ");
  }

  // The same for a declaration kept where it is.
  std::string notes_of(const Declaration* d)
  {
    std::vector<const Declarator*> with;
    for (const Declarator* v : d->declarators)
    {
      if (!v->attributes.empty()) { with.push_back(v); }
    }
    if (with.empty()) { return ""; }
    if (d->declarators.size() == 1) { return attrs_text(with[0]->attributes); }
    Lines out;
    for (const Declarator* v : with) { out.push_back(v->name + " " + attrs_text(v->attributes)); }
    return join(out, ", ");
  }

  // The comment of a block local's Local.
  std::string block_local_comment(const Declarator* d, const std::string& shown)
  {
    return (lc(shown) != lc(d->name) ? "the block local '" + d->name + "'" : std::string("a block local"))
           + (d->attributes.empty() ? "" : " " + attrs_text(d->attributes));
  }

  // 'kw a, b as T' -- a declaration's keyword and names, its values gone.
  std::string names_line(const std::string& kw, const Declaration* d)
  {
    Lines n;
    for (const Declarator* v : d->declarators)
    {
      n.push_back(v->name + (v->typespec_text ? " " + *v->typespec_text : ""));
    }
    return kw + " " + join(n, ", ");
  }

  bool is_expr(const Expr* e, EK k) { return e && e->kind == k; }

  bool is_literal_kind(const Expr* e)
  {
    if (!e) { return false; }
    switch (e->kind)
    {
      case EK::Literal: case EK::ArrayLit: case EK::Interp: case EK::JsonLit: case EK::HashLit:
      case EK::CodeBlock: case EK::Lambda:
        return true;
      default:
        return false;
    }
  }

  std::string call_name(const std::string& name)
  {
    return is_runtime_verb(name) ? "u_xtpl_" + lc(name) : name;
  }

  // 'x := h{k}': a hash read that is a statement's whole value, to a name.
  bool hash_read_whole(const Stmt* s)
  {
    if (s->kind != SK::Assignment) { return false; }
    auto a = static_cast<const Assignment*>(s);
    return (a->op == ":=" || a->op == "=") && is_expr(a->target, EK::Name) && is_expr(a->value, EK::HashIndex);
  }

  bool needs_lowering(const Stmt* s)
  {
    if (s->oneline) { return true; }
    switch (s->kind)
    {
      case SK::Modified:
        return true;
      case SK::Assignment:
      {
        auto a = static_cast<const Assignment*>(s);
        return a->op == "?=" || is_expr(a->target, EK::HashIndex) || hash_read_whole(s);
      }
      case SK::Declaration:
        for (const Declarator* d : static_cast<const Declaration*>(s)->declarators)
        {
          if (d->type_first || !d->attributes.empty() || !d->container.empty()) { return true; }
        }
        return false;
      default:
        return false;
    }
  }

  std::string chop(const std::string& s) { return s.empty() ? s : s.substr(0, s.size() - 1); }

  NotLowered::NotLowered(std::vector<Finding> found) : std::runtime_error(what_of(found)), problems(std::move(found)) {}

  std::string emit(const Program* p, const std::string& src, bool advpl)
  {
    return Emitter(src, advpl).emit(p);
  }

  // ---- the emitter ----------------------------------------------------------
  Emitter::Emitter(std::string src, bool advpl) : src_(std::move(src)), advpl_(advpl)
  {
    nl_ = src_.find("\r\n") != std::string::npos ? "\r\n" : "\n";
    std::string l = lc(src_);
    chains_ = l.find("|>") != std::string::npos || l.find("then") != std::string::npos
              || l.find("..") != std::string::npos
              || l.find("rows") != std::string::npos || l.find("lines") != std::string::npos;
  }

  // ---- lines ----------------------------------------------------------------
  int Emitter::line_start(int p) const
  {
    int k = p - 1;
    while (k >= 0 && src_[static_cast<std::size_t>(k)] != '\n' && src_[static_cast<std::size_t>(k)] != '\r') { k--; }
    return k + 1;
  }

  int Emitter::line_end(int p) const
  {
    return static_cast<int>(eol_from(src_, static_cast<std::size_t>(std::max(p, 0))));
  }

  int Emitter::after_break(int e) const
  {
    return e < static_cast<int>(src_.size()) ? e + static_cast<int>(char_len(src_, static_cast<std::size_t>(e))) : e;
  }

  // The indentation of the line p is on, up to p -- spaces for anything else
  // -- less what a 'with object' around it takes off.
  std::string Emitter::indent_at(int p) const
  {
    std::string s = text(line_start(p), p);
    for (char c : s)
    {
      if (!(CHAR_CLASS[static_cast<unsigned char>(c)] & C_S))
      {
        s = std::string(s.size(), ' ');
        break;
      }
    }
    std::size_t d = static_cast<std::size_t>(dedent_at(p));
    return s.substr(0, s.size() > d ? s.size() - d : 0);
  }

  int Emitter::dedent_at(int p) const
  {
    int l = line_start(p);
    int d = 0;
    for (const Dedent& x : dedents_)
    {
      if (x.from <= l && l < x.to) { d += x.by; }
    }
    return d;
  }

  // Each line of a 'with object''s body loses its level: an edit taking off
  // the start of its indentation -- but on a line an edit already rewrites
  // from its start, which writes the indentation itself (indent_at()).
  void Emitter::dedent_edits()
  {
    std::vector<int> starts;
    for (const Dedent& x : dedents_)
    {
      for (int l = x.from; l < x.to; l = after_break(line_end(l)))
      {
        starts.push_back(l);
        if (line_end(l) >= static_cast<int>(src_.size())) { break; }
      }
    }
    std::sort(starts.begin(), starts.end());
    starts.erase(std::unique(starts.begin(), starts.end()), starts.end());
    for (int l : starts)
    {
      bool covered = false;
      for (const Edit& e : edits_)
      {
        if (e.from <= l && l < e.to) { covered = true; }
      }
      if (covered) { continue; }
      int n = 0;
      int d = dedent_at(l);
      while (n < d && l + n < static_cast<int>(src_.size())
             && (src_[static_cast<std::size_t>(l + n)] == ' ' || src_[static_cast<std::size_t>(l + n)] == '\t'))
      {
        n++;
      }
      if (n > 0) { edit(l, l + n, ""); }
    }
  }

  std::string Emitter::join_at(int p, const Lines& lines) const
  {
    std::string indent = indent_at(p);
    std::string out;
    for (std::size_t i = 0; i < lines.size(); i++)
    {
      if (i) { out += nl_ + indent; }
      out += lines[i];
    }
    return out;
  }

  // ---- what is not lowered yet ----------------------------------------------
  std::vector<Finding> Emitter::not_lowered(const Program* p)
  {
    std::vector<Finding> found;
    auto one = [&](const std::vector<Param*>& params, const Body& body)
    {
      declare_names(params, body);
      if (chains_)
      {
        walk(body, [&](Stmt* s)
        {
          if (s->kind == SK::ForInStmt)
          {
            const Expr* c = source_call(static_cast<ForInStmt*>(s)->source);
            if (c && source_kind(c) == "rows") { found.push_back({ s->line, "'for ... in' over rows()" }); }
          }
          // A source only reads at the head of a chain in a statement that
          // can run the loop first, or as the source of a 'for'.
          std::vector<const Expr*> tops = stream_values(s);
          const Expr* for_ = nullptr;
          if (s->kind == SK::ForInStmt && is_source(static_cast<ForInStmt*>(s)->source))
          {
            for_ = static_cast<ForInStmt*>(s)->source;
          }
          std::unordered_set<const Expr*> heads;
          std::unordered_set<const Expr*> in_range;
          std::vector<const Expr*> sources;
          for (Expr* e : exprs_of(s))
          {
            walk_expr(e, [&](Expr* x)
            {
              if (x->kind == EK::Pipeline)
              {
                const Expr* h = static_cast<Pipeline*>(x)->source;
                if (is_source(h)) { heads.insert(h); }
              }
              else if (x->kind == EK::Binary)
              {
                auto b = static_cast<Binary*>(x);
                if (b->op == "in" && is_expr(b->right, EK::Interval)) { in_range.insert(b->right); }
              }
              if (is_source(x)) { sources.push_back(x); }
            });
          }
          for (const Expr* x : sources)
          {
            bool ok = (for_ && for_ == x) || in_range.count(x);
            for (const Expr* t : tops) { ok = ok || source_call(t) == x; }
            if (ok) { continue; }
            std::string what = x->kind == EK::Interval ? "a range" : lc(static_cast<const Call*>(x)->name) + "()";
            found.push_back({ s->line, heads.count(x)
              ? "a chain from " + what + " where it cannot run as a loop first "
                + "(it goes in 'x := ...', 'return ...' or a statement of its own)"
              : x->kind == EK::Interval ? std::string("a range outside 'in' and the head of a chain")
                                        : "'" + lc(static_cast<const Call*>(x)->name)
                                          + "()' outside the head of a chain (it is a source)" });
          }
          for (const Expr* t : tops)
          {
            for (Finding& f : chain_problems(t, s)) { found.push_back(std::move(f)); }
          }
        });
      }
      // A defer's statement is written before the subjects of 'with object'
      // have their Locals: one that reads ':x' cannot be.
      walk(body, [&](Stmt* s)
      {
        if (s->kind != SK::Deferred) { return; }
        bool subject = false;
        walk(Body{ static_cast<Deferred*>(s)->stmt }, [&](Stmt* d)
        {
          for (Expr* e : exprs_of(d))
          {
            walk_expr(e, [&](Expr* x) { subject = subject || x->kind == EK::SubjectRef; });
          }
        });
        if (subject) { found.push_back({ s->line, "a 'defer' that reads ':x' of 'with object'" }); }
      });
      for (Finding& f : scope_problems(body)) { found.push_back(std::move(f)); }
    };
    for (const FunctionDef* f : p->functions) { one(f->params, f->body); }
    for (const MethodImpl* m : p->methods) { one(m->params, m->body); }
    std::vector<Finding> out;
    std::unordered_set<std::string> seen;
    for (Finding& f : found)
    {
      if (seen.insert(std::to_string(f.line) + '\0' + f.message).second) { out.push_back(std::move(f)); }
    }
    std::stable_sort(out.begin(), out.end(), [](const Finding& a, const Finding& b) { return a.line < b.line; });
    return out;
  }

  // A block local a defer reads, declared in more than one block.
  std::vector<Finding> Emitter::scope_problems(const Body& body)
  {
    std::vector<Finding> found;
    std::unordered_map<std::string, int> blocks;
    walk(body, [&](Stmt* s)
    {
      switch (s->kind)
      {
        case SK::Declaration:
        {
          auto d = static_cast<Declaration*>(s);
          if (d->scope == "local" && std::find(body.begin(), body.end(), s) == body.end())
          {
            for (const Declarator* v : d->declarators) { blocks[lc(v->name)]++; }
          }
          break;
        }
        case SK::ForInStmt:
        {
          auto f = static_cast<ForInStmt*>(s);
          blocks[lc(f->elem)]++;
          if (f->index) { blocks[lc(*f->index)]++; }
          break;
        }
        case SK::ForStmt:
        {
          auto f = static_cast<ForStmt*>(s);
          if (f->var_local) { blocks[lc(f->var)]++; }
          break;
        }
        case SK::IfStmt:
          if (auto d = static_cast<IfStmt*>(s)->header_decl) { blocks[lc(d->name)]++; }
          break;
        case SK::WhileStmt:
          if (auto d = static_cast<WhileStmt*>(s)->header_decl) { blocks[lc(d->name)]++; }
          break;
        case SK::CaseStmt:
          if (auto d = static_cast<CaseStmt*>(s)->subject_decl) { blocks[lc(d->name)]++; }
          break;
        default:
          break;
      }
    });
    walk(body, [&](Stmt* s)
    {
      if (s->kind != SK::Deferred) { return; }
      for (Expr* e : exprs_of(static_cast<Deferred*>(s)->stmt))
      {
        walk_expr(e, [&](Expr* x)
        {
          if (x->kind != EK::Name) { return; }
          auto it = blocks.find(lc(static_cast<Name*>(x)->name));
          if (it != blocks.end() && it->second > 1)
          {
            found.push_back({ s->line, "block local '" + static_cast<Name*>(x)->name
                                       + "', read by a defer and declared in more than one block," });
          }
        });
      }
    });
    return found;
  }

  // A verb written as a call is the chain it stands for: 'filter(map(a, f),
  // g)' is 'a |> map(f) |> filter(g)', and as a statement's whole value it is
  // lowered as one -- a loop where the chain would be. Anything else is
  // itself.
  const Expr* Emitter::as_chain(const Expr* e) const
  {
    if (!is_expr(e, EK::Call) || !is_runtime_verb(static_cast<const Call*>(e)->name)) { return e; }
    if (auto it = chains_made_.find(e); it != chains_made_.end()) { return it->second; }
    std::vector<const Call*> outer;
    const Expr* x = e;
    while (is_expr(x, EK::Call) && is_runtime_verb(static_cast<const Call*>(x)->name)
           && !static_cast<const Call*>(x)->args.empty())
    {
      outer.push_back(static_cast<const Call*>(x));
      x = outer.back()->args[0];
    }
    const Expr* made = e;
    if (!outer.empty() && x && x->kind != EK::Omitted && !is_source(x) && !is_expr(x, EK::Pipeline))
    {
      Pipeline* p = made_.make<Pipeline>();
      p->line = e->line;
      p->from = e->from;
      p->to = e->to;
      p->source = const_cast<Expr*>(x);
      for (auto c = outer.rbegin(); c != outer.rend(); ++c)
      {
        Call* st = made_.make<Call>();
        st->name = (*c)->name;
        st->args.assign((*c)->args.begin() + 1, (*c)->args.end());
        st->line = (*c)->line;
        st->from = (*c)->from;
        st->to = (*c)->to;
        p->stages.push_back(st);
      }
      made = p;
    }
    chains_made_[e] = made;
    return made;
  }

  bool Emitter::fusable_array(const Expr* e, bool for_effect) const
  {
    if (!is_expr(e, EK::Pipeline) || is_source(static_cast<const Pipeline*>(e)->source)) { return false; }
    return fuse_from(static_cast<const Pipeline*>(e)->stages, declared_fn(), for_effect) >= 0;
  }

  const Expr* Emitter::fused_value(const Stmt* s) const
  {
    if (!chains_) { return nullptr; }
    if (const Expr* c = stream_value(s)) { return c; }
    switch (s->kind)
    {
      case SK::Assignment:
      {
        auto a = static_cast<const Assignment*>(s);
        if (a->op == ":=" && fusable_array(as_chain(a->value), false)) { return as_chain(a->value); }
        break;
      }
      case SK::ReturnStmt:
      {
        auto r = static_cast<const ReturnStmt*>(s);
        if (r->value && fusable_array(as_chain(r->value), false)) { return as_chain(r->value); }
        break;
      }
      case SK::CallStmt:
      {
        auto c = static_cast<const CallStmt*>(s);
        if (fusable_array(as_chain(c->call), true)) { return as_chain(c->call); }
        break;
      }
      default:
        break;
    }
    return nullptr;
  }

  // A value that runs as statements: a chain as a loop, a guard as a Begin
  // Sequence.
  bool Emitter::loop_value(const Expr* e) const
  {
    if (is_expr(e, EK::Guard)) { return true; }
    if (!chains_) { return false; }
    return e && (source_call(e) || fusable_array(as_chain(e), false));
  }

  const Expr* Emitter::stream_value(const Stmt* s) const
  {
    switch (s->kind)
    {
      case SK::Assignment:
      {
        auto a = static_cast<const Assignment*>(s);
        if (a->op == ":=" && source_call(a->value)) { return a->value; }
        break;
      }
      case SK::ReturnStmt:
      {
        auto r = static_cast<const ReturnStmt*>(s);
        if (r->value && source_call(r->value)) { return r->value; }
        break;
      }
      case SK::CallStmt:
      {
        auto c = static_cast<const CallStmt*>(s);
        if (is_expr(c->call, EK::Pipeline) && source_call(c->call)) { return c->call; }
        break;
      }
      default:
        break;
    }
    return nullptr;
  }

  std::vector<const Expr*> Emitter::stream_values(const Stmt* s) const
  {
    if (const Expr* c = stream_value(s)) { return { c }; }
    std::vector<const Expr*> out;
    if (auto d = as_decl(s); d && (d->scope == "local" || d->scope == "private" || d->scope == "public"))
    {
      for (const Declarator* v : d->declarators)
      {
        if (v->init && source_call(v->init)) { out.push_back(v->init); }
      }
    }
    return out;
  }

  // What stops a chain from a source from being lowered (chains.cpp).
  std::vector<Finding> Emitter::chain_problems(const Expr* chain, const Stmt* s)
  {
    std::vector<Finding> out;
    for (std::string& m : xc::chain_problems(chain, s->kind == SK::CallStmt, declared_fn()))
    {
      out.push_back({ s->line, std::move(m) });
    }
    return out;
  }

  bool Emitter::is_lambda(const Expr* e) const
  {
    return is_expr(e, EK::Lambda) && static_cast<const Lambda*>(e)->params.size() == 1;
  }

  bool Emitter::is_function_name(const std::string& verb, const Expr* e) const
  {
    return takes_block(verb) && is_expr(e, EK::Name) && !declared(lc(static_cast<const Name*>(e)->name));
  }

  // ---- the whole file -------------------------------------------------------
  std::string Emitter::emit(const Program* p)
  {
    // A verb written as a call may be a loop too (as_chain).
    if (!chains_)
    {
      auto verb = [&](const Body& body)
      {
        walk(body, [&](Stmt* s)
        {
          for (Expr* e : exprs_of(s))
          {
            walk_expr(e, [&](Expr* x)
            {
              if (x->kind == EK::Call && is_runtime_verb(static_cast<Call*>(x)->name)) { chains_ = true; }
            });
          }
        });
      };
      for (const FunctionDef* f : p->functions) { verb(f->body); }
      for (const MethodImpl* m : p->methods) { verb(m->body); }
    }
    std::vector<Finding> problems = not_lowered(p);
    if (!problems.empty()) { throw NotLowered(std::move(problems)); }

    // 'external' emits nothing: its line goes, but for its comment.
    for (const External* x : p->externals)
    {
      if (x->from < 0) { continue; }
      std::string raw = slice(x);
      int from = line_start(x->from);
      int end = line_end(x->from + static_cast<int>(code_end(raw)));
      std::string comment = split_comment(raw).second;
      if (!comment.empty())
      {
        edit(from, end, comment);
      }
      else
      {
        edit(from, after_break(end), "");
      }
    }

    // A file static declared 'as Decimal': its literal value made one. In
    // TL++: a .prw has no Decimal. One that needs it -- a typed array or
    // hash, 'as T' first, attributes -- written again, as a Local is. The
    // values of the rest: what is xtpl's in them lowered.
    if (!advpl_) { dec_.file(p); }
    dec_.function({}, {});
    for (const Declaration* d : p->statics)
    {
      std::vector<Expr*> values;
      for (const Declarator* v : d->declarators)
      {
        if (v->init && decimal_word(v->typespec_text)) { into_decimal_.insert(v->init); }
        if (v->init) { values.push_back(v->init); }
      }
      no_temps_++;
      if (needs_lowering(d) && d->from >= 0)
      {
        int end = d->from + static_cast<int>(code_end(slice(d)));
        std::string notes = notes_of(d);
        // The attributes as a comment: in the line's own, if it has one.
        int from = line_start(d->from);
        std::string line = text(from, line_end(d->from));
        long at = comment_at(line);
        bool own = at >= 0 && from + at >= end && (line.compare(static_cast<std::size_t>(at), 2, "//") == 0
                                                   || line.compare(static_cast<std::size_t>(at), 2, "&&") == 0);
        if (!notes.empty() && own)
        {
          edit(from + static_cast<int>(at), from + static_cast<int>(at) + 2, "// " + notes + " --");
          notes.clear();
        }
        edit(d->from, end, lower(d).lines.at(0) + (notes.empty() ? "" : "  // " + notes));
      }
      else
      {
        expressions(values);
      }
      no_temps_--;
    }

    for (const FunctionDef* f : p->functions)
    {
      ret_decimal_ = decimal_word(f->rettype_word);
      ret_numeric_ = numeric_word(f->rettype_word);
      // 'as Array<n>' is TL++'s 'as Array', 'as Hash<c, n>' its 'as Object'.
      if (!f->ret_container.empty()) { edit(f->ret_from, f->ret_to, f->ret_tlpp); }
      for (const Param* q : f->params)
      {
        if (q && !q->container.empty()) { edit(q->type_from, q->type_to, q->type_tlpp); }
      }
      function(f->params, f->body);
    }
    for (const MethodImpl* m : p->methods)
    {
      ret_decimal_ = decimal_word(m->returns);
      ret_numeric_ = numeric_word(m->returns);
      function(m->params, m->body);
    }

    // Two edits over the same text would garble it without a word.
    std::vector<Edit> sorted = edits_;
    std::stable_sort(sorted.begin(), sorted.end(), [](const Edit& a, const Edit& b)
    {
      return a.from != b.from ? a.from < b.from : a.to < b.to;
    });
    // Offsets in the message as the Raku xc counts them: a "\r\n" is one.
    auto chars = [&](int b)
    {
      int n = b;
      for (int i = 0; i + 1 < b; i++)
      {
        if (src_[static_cast<std::size_t>(i)] == '\r' && src_[static_cast<std::size_t>(i) + 1] == '\n') { n--; }
      }
      return n;
    };
    for (std::size_t i = 1; i < sorted.size(); i++)
    {
      const Edit& a = sorted[i - 1];
      const Edit& b = sorted[i];
      if (b.from < a.to && b.to > b.from)
      {
        throw std::runtime_error("internal: overlapping edits at offsets " + std::to_string(chars(a.from)) + ".."
                                 + std::to_string(chars(a.to)) + " and " + std::to_string(chars(b.from)) + ".."
                                 + std::to_string(chars(b.to)));
      }
    }

    // The edits spliced in from the end of the source. An insertion inside a
    // removal loses what the removal reaches into, as splicing does -- in
    // characters, a "\r\n" one, as the Raku xc counts them.
    auto rchars = [](std::string_view t)
    {
      std::size_t n = 0;
      for (std::size_t i = 0; i < t.size(); i += char_len(t, i)) { n++; }
      return n;
    };
    auto rdrop = [](std::string_view t, std::size_t n)
    {
      std::size_t i = 0;
      for (std::size_t k = 0; k < n && i < t.size(); k++) { i += char_len(t, i); }
      return std::string(t.substr(i));
    };
    std::stable_sort(edits_.begin(), edits_.end(), [](const Edit& a, const Edit& b)
    {
      return a.from != b.from ? a.from > b.from : a.to > b.to;
    });
    Lines rev;
    int before = static_cast<int>(src_.size());
    for (const Edit& e : edits_)
    {
      if (e.to <= before)
      {
        if (before > e.to) { rev.push_back(text(e.to, before)); }
      }
      else
      {
        std::size_t drop = rchars(std::string_view(src_).substr(static_cast<std::size_t>(before),
                                                                 static_cast<std::size_t>(e.to - before)));
        while (drop > 0 && !rev.empty())
        {
          std::string piece = std::move(rev.back());
          rev.pop_back();
          std::size_t n = rchars(piece);
          if (n <= drop)
          {
            drop -= n;
          }
          else
          {
            rev.push_back(rdrop(piece, drop));
            drop = 0;
          }
        }
      }
      rev.push_back(e.text);
      before = e.from;
    }
    rev.push_back(text(0, before));
    std::string spliced;
    for (auto it = rev.rbegin(); it != rev.rend(); ++it) { spliced += *it; }

    // The marks before the comments written again, blanks: up to the column
    // the comment had, when that leaves two after the code, else two.
    std::string out;
    out.reserve(spliced.size());
    int col = 0;
    for (std::size_t i = 0; i < spliced.size(); i++)
    {
      char c = spliced[i];
      if (c == '\x01')
      {
        std::size_t e = spliced.find('\x02', i);
        int want = std::stoi(spliced.substr(i + 1, e - i - 1));
        int n = want - col >= 2 ? want - col : 2;
        out.append(static_cast<std::size_t>(n), ' ');
        col += n;
        i = e;
        continue;
      }
      out += c;
      col = c == '\n' || c == '\r' ? 0 : col + 1;
    }
    return add_includes(out, nl_, advpl_);
  }

  // The values that go into a Decimal, and those that go into a Numeric
  // (decimal.h).
  void Emitter::decimal_values(const Body& body)
  {
    DecimalValues v = xc::decimal_values(dec_, body, Returns{ ret_decimal_, ret_numeric_ });
    into_decimal_ = std::move(v.into_decimal);
    into_numeric_ = std::move(v.into_numeric);
  }

  // A parameter's '<const>' or '<contained>' leaves the header, and a comment
  // at the end of the line says it.
  void Emitter::param_attributes(const std::vector<Param*>& params)
  {
    std::vector<const Param*> with;
    for (const Param* q : params)
    {
      if (q && !q->attributes.empty()) { with.push_back(q); }
    }
    if (with.empty()) { return; }
    for (const Param* q : with) { edit(q->attrs_from, q->attrs_to, ""); }
    Lines notes;
    for (const Param* q : with) { notes.push_back(q->name + " " + attrs_text(q->attributes)); }
    std::string note = join(notes, ", ");
    int from = line_start(with.back()->attrs_to);
    int end = line_end(with.back()->attrs_to);
    std::string line = text(from, end);
    std::string comment = split_comment(line).second;
    long at = comment_at(line);
    if (!comment.empty() && at >= 0 && (line.compare(static_cast<std::size_t>(at), 2, "//") == 0
                                        || line.compare(static_cast<std::size_t>(at), 2, "&&") == 0))
    {
      edit(from + static_cast<int>(at), from + static_cast<int>(at) + 2, "// " + note + " --");
    }
    else
    {
      edit(end, end, "  // " + note);
    }
  }

  void Emitter::function(const std::vector<Param*>& params, const Body& body)
  {
    used_.clear();
    hoist_.clear();
    hoisted_.clear();
    early_.clear();
    early_at_ = -1;
    early_names_.clear();
    pool_.clear();
    busy_.clear();
    typed_.clear();
    dedents_.clear();
    body_indent_ = !body.empty() && !(body.size() == 1 && body[0]->kind == SK::ReturnStmt) ? indent_at(body[0]->from)
                                                                                         : "  ";
    for (const Param* q : params)
    {
      if (q && q->type_word) { typed_.insert(lc(q->name)); }
    }
    walk(body, [&](Stmt* s)
    {
      if (s->kind != SK::Declaration) { return; }
      for (const Declarator* d : static_cast<Declaration*>(s)->declarators)
      {
        if (d->typespec_text) { typed_.insert(lc(d->name)); }
      }
    });
    dec_.function(params, body);
    decimal_values(body);
    param_attributes(params);
    for (const Param* q : params) { used_.insert(lc(q->name)); }
    walk(body, [&](Stmt* s)
    {
      switch (s->kind)
      {
        case SK::Declaration:
          for (const Declarator* d : static_cast<Declaration*>(s)->declarators) { used_.insert(lc(d->name)); }
          break;
        case SK::ForStmt:
          used_.insert(lc(static_cast<ForStmt*>(s)->var));
          break;
        case SK::ForInStmt:
        {
          auto f = static_cast<ForInStmt*>(s);
          used_.insert(lc(f->elem));
          if (f->index) { used_.insert(lc(*f->index)); }
          break;
        }
        default:
          break;
      }
      for (Expr* e : exprs_of(s))
      {
        walk_expr(e, [&](Expr* x)
        {
          if (x->kind == EK::Name) { used_.insert(lc(static_cast<Name*>(x)->name)); }
        });
      }
    });

    declare_names(params, body);
    plan_renames(params, body);

    // The defers, lowered once each, with their comment on their last line.
    place_statements(body);
    defers_.clear();
    walk(body, [&](Stmt* s)
    {
      if (s->kind != SK::Deferred) { return; }
      busy_.clear();
      Lines lines = stmt_lines(static_cast<Deferred*>(s)->stmt);
      auto [code, comment] = split_comment(slice(s));
      if (!comment.empty() && !lines.empty()) { lines.back() += "  " + comment; }
      std::string t = join(words(trim(code)), " ");
      defers_.push_back(Defer{ s->from, lines, &paths_[s], "", t });
    });
    // A defer runs at an exit only if its line was reached; where that is not
    // certain, a flag set where it is written says whether it ran.
    std::vector<const Stmt*> returns;
    walk(body, [&](Stmt* s)
    {
      if (s->kind == SK::ReturnStmt) { returns.push_back(s); }
    });
    bool natural = !body.empty() && body.back()->kind != SK::ReturnStmt;
    for (Defer& d : defers_)
    {
      bool maybe = false;
      for (const Stmt* r : returns) { maybe = maybe || defer_at(d, r) == "maybe"; }
      if (!(maybe || (natural && d.at->path.size() > 1))) { continue; }
      std::string what = d.text.size() > 43 ? d.text.substr(0, 40) + "..." : d.text;
      d.flag = gen("fdf", "whether '" + what + "' was reached", ".F.");
    }

    // The prologue keeps its values where they are written: a chain over an
    // array, a guard, a verb written as a call, there, stay expressions. A
    // chain from a source has no expression to be -- rows(), lines() and
    // 'lo..hi' are walked by a loop, which is a statement: from the first
    // such declaration on, the 'local' declarations keep their names, and
    // their values become assignments after the prologue, in the order
    // written.
    done_.clear();
    std::vector<const Declaration*> prologue = prologue_of(body);
    long first = -1;
    for (std::size_t i = 0; i < prologue.size() && first < 0; i++)
    {
      if (prologue[i]->scope != "local") { continue; }
      for (const Declarator* d : prologue[i]->declarators)
      {
        if (chains_ && d->init && source_call(d->init))
        {
          first = static_cast<long>(i);
          break;
        }
      }
    }
    Lines inits;
    if (first >= 0)
    {
      for (std::size_t i = static_cast<std::size_t>(first); i < prologue.size(); i++)
      {
        const Declaration* d = prologue[i];
        if (d->scope != "local") { continue; }
        done_.insert(d);
        std::string kw = words(trim(split_comment(slice(d)).first)).at(0);
        replace(d, false, { names_line(kw, d) }, { notes_of(d) });
        for (const Declarator* v : d->declarators)
        {
          if (!v->init) { continue; }
          busy_.clear();
          for (std::string& l : init_lines(v->name, v->init)) { inits.push_back(std::move(l)); }
        }
      }
    }

    collect(body, true);

    // The natural end: unless the body ends in a 'return', every defer runs
    // after its last statement -- one in a block only if it was reached.
    const Stmt* last = body.empty() ? nullptr : body.back();
    if (!defers_.empty() && last && last->kind != SK::ReturnStmt)
    {
      int at = line_end(last->from + static_cast<int>(code_end(slice(last))));
      std::string indent = body_indent_;
      std::string t;
      for (auto it = defers_.rbegin(); it != defers_.rend(); ++it)
      {
        Lines l = it->at->path.size() == 1 ? it->lines : guarded(*it);
        for (const std::string& x : l) { t += nl_ + indent + x; }
      }
      edit(at, at, t);
    }
    // Inserted at the end of the prologue, after the hoisted Locals and before
    // any defer there.
    if (!inits.empty())
    {
      const Declaration* lastd = prologue.back();
      int at = line_end(lastd->from + static_cast<int>(code_end(slice(lastd))));
      std::string indent = body_indent_;
      std::string t;
      for (const std::string& x : inits) { t += nl_ + indent + x; }
      edit(at, at, t);
    }
    if (!hoist_.empty()) { hoist_edit(body); }
    if (!dedents_.empty()) { dedent_edits(); }
    align_comments(body);
    // The temps of a prologue declaration, just before it.
    for (const auto& [from, lines] : early_)
    {
      std::string indent = indent_at(from);
      std::string t;
      for (const std::string& l : lines) { t += indent + l + nl_; }
      int at = line_start(from);
      edit(at, at, t);
    }
  }

  // The names the function declares, anywhere in it.
  void Emitter::declare_names(const std::vector<Param*>& params, const Body& body)
  {
    declared_ = declared_names(params, body);
  }


  // Block locals: slots, recycled -- each the lowest no local of an enclosing
  // block holds. One that can still be reached after its block keeps a
  // Local of its own.
  void Emitter::plan_renames(const std::vector<Param*>& params, const Body& body)
  {
    renames_.clear();
    slots_.clear();
    slot_users_.clear();
    std::unordered_map<std::string, int> count;
    for (const Param* q : params) { count[lc(q->name)]++; }
    walk(body, [&](Stmt* s)
    {
      if (s->kind == SK::Declaration)
      {
        for (const Declarator* d : static_cast<Declaration*>(s)->declarators) { count[lc(d->name)]++; }
      }
      else
      {
        for (const std::string& n : header_names(s)) { count[lc(n)]++; }
      }
    });
    int pins = 0;

    auto slot = [&](const Lines& held)
    {
      int k = 0;
      auto taken = [&](const std::string& n)
      {
        return std::find(held.begin(), held.end(), n) != held.end() || (used_.count(n) && !slots_.count(n));
      };
      while (taken("s_0_" + std::to_string(k))) { k++; }
      std::string n = "s_0_" + std::to_string(k);
      used_.insert(n);
      slots_.insert(n);
      return n;
    };
    auto own = [&](const std::string& n)
    {
      auto c = count.find(lc(n));
      if (c == count.end() || c->second <= 1) { return n; }
      for (;;)
      {
        pins++;
        std::string fresh = "b_" + std::to_string(pins) + "_" + n;
        if (used_.count(lc(fresh))) { continue; }
        used_.insert(lc(fresh));
        return fresh;
      }
    };
    // Who used a slot: the names, in the order met, and how its comment says them.
    std::unordered_map<std::string, Lines> names;
    auto user = [&](const std::string& s, const std::string& name, const std::string& who)
    {
      Lines& u = slot_users_[s];
      if (std::find(u.begin(), u.end(), who) == u.end()) { u.push_back(who); }
      Lines& n = names[s];
      bool known = false;
      for (const std::string& x : n) { known = known || lc(x) == lc(name); }
      if (!known) { n.push_back(name); }
    };

    std::function<void(const Body&, const Lines&)> visit = [&](const Body& b, const Lines& held)
    {
      for (const Stmt* s : b)
      {
        if (s->kind == SK::Modified || s->kind == SK::Deferred) { continue; }
        std::vector<Body> bodies = bodies_of(s);
        if (bodies.empty()) { continue; }
        Map head;
        Lines h = held;
        Body all;
        for (const Body& x : bodies) { all.insert(all.end(), x.begin(), x.end()); }
        for (const std::string& n : header_names(s))
        {
          if (escapes(n, all, exprs_of(s)))
          {
            std::string fresh = own(n);
            if (fresh != n) { head[lc(n)] = fresh; }
          }
          else
          {
            std::string k = slot(h);
            head[lc(n)] = k;
            h.push_back(k);
            user(k, n, "'" + n + "'");
          }
        }
        // Each body's own, apart: the bodies of one statement never run at
        // once, so they share slots too.
        std::vector<Map> maps;
        for (const Body& x : bodies)
        {
          Map bm;
          Lines hb = h;
          for (const Stmt* t : x)
          {
            auto d = as_decl(t);
            if (!d || d->scope != "local") { continue; }
            for (const Declarator* dc : d->declarators)
            {
              const std::string& n = dc->name;
              if (bm.count(lc(n))) { continue; }
              if (escapes(n, x, {}))
              {
                std::string fresh = own(n);
                if (fresh != n) { bm[lc(n)] = fresh; }
              }
              else
              {
                std::string k = slot(hb);
                bm[lc(n)] = k;
                hb.push_back(k);
                user(k, n, "'" + n + "'" + (dc->attributes.empty() ? "" : " " + attrs_text(dc->attributes)));
              }
            }
          }
          maps.push_back(bm);
          visit(x, hb);
        }
        renames_[s] = Renames{ head, maps };
      }
    };
    visit(body, {});

    // A slot with one name in it goes by that name: the first such slot of a
    // name, when the function itself does not have it; the others by
    // s_<slot>_<name>.
    std::unordered_set<std::string> fn;
    for (const Param* q : params) { fn.insert(lc(q->name)); }
    for (const Declaration* d : prologue_of(body))
    {
      for (const Declarator* v : d->declarators) { fn.insert(lc(v->name)); }
    }
    std::vector<std::string> keys;
    for (const auto& [k, v] : names) { keys.push_back(k); }
    std::sort(keys.begin(), keys.end(), [](const std::string& a, const std::string& b)
    {
      return std::stoi(a.substr(4)) < std::stoi(b.substr(4));
    });
    Map first;
    for (const std::string& s : keys)
    {
      const Lines& n = names[s];
      if (n.size() != 1) { continue; }
      if (!fn.count(lc(n[0])) && !first.count(lc(n[0]))) { first[lc(n[0])] = s; }
    }
    for (const std::string& s : keys)
    {
      const Lines& n = names[s];
      if (n.size() != 1) { continue; }
      const std::string& name = n[0];
      auto f = first.find(lc(name));
      std::string fresh = (f != first.end() && f->second == s) ? name : "s_" + s.substr(4) + "_" + name;
      for (auto& [stmt, r] : renames_)
      {
        std::vector<Map*> ms{ &r.head };
        for (Map& m : r.bodies) { ms.push_back(&m); }
        for (Map* m : ms)
        {
          Lines hit;
          for (const auto& [k, v] : *m)
          {
            if (v == s) { hit.push_back(k); }
          }
          for (const std::string& k : hit)
          {
            if (fresh == name) { m->erase(k); } else { (*m)[k] = fresh; }
          }
        }
      }
      used_.insert(lc(fresh));
      slots_.erase(s);
      slot_users_.erase(s);
    }
  }

  std::string Emitter::nm(const Stmt* s, const std::string& name) const
  {
    auto r = renames_.find(s);
    if (r == renames_.end()) { return name; }
    auto h = r->second.head.find(lc(name));
    return h != r->second.head.end() ? h->second : name;
  }

  std::string Emitter::local(const std::string& name) const
  {
    auto it = subst_.find(lc(name));
    return it != subst_.end() ? it->second : name;
  }

  void Emitter::collect_bodies(const Stmt* s)
  {
    Map saved = subst_;
    const Renames* r = nullptr;
    if (auto it = renames_.find(s); it != renames_.end()) { r = &it->second; }
    std::vector<Body> bodies = bodies_of(s);
    for (std::size_t i = 0; i < bodies.size(); i++)
    {
      subst_ = saved;
      if (r)
      {
        for (const auto& [k, v] : r->head) { subst_[k] = v; }
        if (i < r->bodies.size())
        {
          for (const auto& [k, v] : r->bodies[i]) { subst_[k] = v; }
        }
      }
      collect(bodies[i], false);
    }
    subst_ = saved;
  }

  void Emitter::hoist(const std::string& name, const std::string& comment, const std::string& value)
  {
    if (!hoisted_.insert(lc(name)).second) { return; }
    hoist_.push_back(Hoist{ name, comment, value });
  }

  std::string Emitter::gen(const std::string& kind, const std::string& comment, const std::string& value)
  {
    int n = 0;
    while (used_.count(kind + "_0_" + std::to_string(n))) { n++; }
    std::string name = kind + "_0_" + std::to_string(n);
    used_.insert(name);
    if (early_at_ >= 0)
    {
      early_[early_at_].push_back("Local " + name + (value.empty() ? "" : " := " + value) + "  // " + comment);
    }
    else
    {
      hoist(name, comment, value);
    }
    return name;
  }

  // A temp for a value read twice. An 'et' (a '?:') is read right after it
  // is set, with nothing evaluated between: one serves the whole function,
  // its blocks too. An 'fbv' (a '?.', an 'in lo..hi') has more evaluated
  // between: one for each use in a statement, free again at the next; a
  // block has its own. A declaration of the prologue takes only a temp
  // declared before it.
  std::string Emitter::temp(const std::string& kind, const std::string& comment)
  {
    bool once = kind == "et";
    if (!once && in_block_ > 0) { return gen(kind, comment); }
    for (const std::string& t : pool_[kind])
    {
      if ((once || !busy_.count(t)) && (early_at_ < 0 || early_names_.count(t)))
      {
        busy_.insert(t);
        return t;
      }
    }
    std::string t = gen(kind, comment);
    pool_[kind].push_back(t);
    busy_.insert(t);
    if (early_at_ >= 0) { early_names_.insert(t); }
    return t;
  }

  // ---- trailing comments ----------------------------------------------------
  // A trailing comment keeps its column when the code before it still leaves
  // two blanks, and goes two blanks after the code otherwise. Where it goes
  // is known only once the edits are spliced in: what goes before it is a
  // mark, '\x01' COLUMN '\x02', that emit() makes blanks of.

  // The column of the last comment on the lines from..to, in the source; -1
  // when there is none.
  int Emitter::comment_col(int from, int to) const
  {
    int col = -1;
    for (int l = line_start(from); l < to; l = after_break(line_end(l)))
    {
      int end = std::min(line_end(l), to);
      long k = comment_at(text(l, end));
      if (k >= 0 && l + k >= from) { col = static_cast<int>(k); }
      if (line_end(l) >= to || line_end(l) >= static_cast<int>(src_.size())) { break; }
    }
    return col;
  }

  // What goes before a comment written again after new code: the mark of
  // the column it had, or two blanks.
  std::string Emitter::before_comment(int from, int to) const
  {
    int col = comment_col(from, to);
    return col >= 0 ? "\x01" + std::to_string(col) + "\x02" : "  ";
  }

  // A comment after code that an edit changed, on a line nothing rewrites
  // from the code to the comment: the blanks before it a mark.
  void Emitter::align_comments(const Body& body)
  {
    if (body.empty()) { return; }
    std::vector<const Edit*> sorted;
    for (const Edit& e : edits_) { sorted.push_back(&e); }
    std::sort(sorted.begin(), sorted.end(), [](const Edit* a, const Edit* b) { return a->from < b->from; });
    int end = body.back()->to;
    for (int l = line_start(body.front()->from); l < end; l = after_break(line_end(l)))
    {
      int le = line_end(l);
      long k = comment_at(text(l, le));
      int cs = l + static_cast<int>(k);
      int ws = cs;
      auto blank = [&](int p)
      {
        char c = src_[static_cast<std::size_t>(p)];
        return c == ' ' || c == '\t';
      };
      while (k > 0 && ws > l && blank(ws - 1)) { ws--; }
      if (k > 0 && ws > l)
      {
        // The edits from this line's start up to the comment change its code;
        // one that runs over the blanks before the comment -- the last that
        // starts before them, edits not overlapping -- rewrites the comment.
        auto first = std::lower_bound(sorted.begin(), sorted.end(), l,
                                      [](const Edit* e, int p) { return e->from < p; });
        bool changed = false;
        bool covered = false;
        for (auto e = first; e != sorted.end() && (*e)->from < cs; ++e)
        {
          if ((*e)->to > ws) { covered = true; }
          if ((*e)->to <= ws) { changed = true; }
        }
        for (auto e = first; e != sorted.begin();)
        {
          --e;
          if ((*e)->to == (*e)->from) { continue; }
          if ((*e)->to > l) { covered = true; }
          break;
        }
        if (changed && !covered) { edit(ws, cs, "\x01" + std::to_string(k) + "\x02"); }
      }
      if (le >= end || le >= static_cast<int>(src_.size())) { break; }
    }
  }

  // A name that may be compared with Nil: one declared with no type.
  bool Emitter::plain_name(const Expr* e) const
  {
    return is_expr(e, EK::Name) && !typed_.count(lc(static_cast<const Name*>(e)->name));
  }

  // The hoisted Locals go after the last declaration of the function's
  // prologue, or before its first statement when it has none.
  void Emitter::hoist_edit(const Body& body)
  {
    std::string indent = body_indent_;
    std::vector<const Declaration*> decls = prologue_of(body);
    Lines lines;
    for (const Hoist& h : hoist_)
    {
      std::string c = h.comment;
      if (auto u = slot_users_.find(lc(h.name)); u != slot_users_.end() && !u->second.empty())
      {
        c = u->second.size() == 1 ? "a slot: the block local " + u->second[0]
                                  : "a slot: the block locals " + join(u->second, ", ");
      }
      lines.push_back(indent + "Local " + h.name + (h.value.empty() ? "" : " := " + h.value) + "  // " + c);
    }
    std::string t;
    if (!decls.empty())
    {
      const Declaration* last = decls.back();
      int at = line_end(last->from + static_cast<int>(code_end(slice(last))));
      for (const std::string& l : lines) { t += nl_ + l; }
      edit(at, at, t);
    }
    else if (!body.empty())
    {
      int at = line_start(body[0]->from);
      for (const std::string& l : lines) { t += l + nl_; }
      edit(at, at, t);
    }
  }
}
