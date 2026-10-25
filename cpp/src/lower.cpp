// xc -- from the tree back to TL++: the statements as they are rewritten,
// the chains as loops, and the expressions (see emit.h).

#include <algorithm>
#include <stdexcept>

#include "chains.h"
#include "chars.h"
#include "emitter.h"
#include "parser.h"
#include "text.h"
#include "walk.h"

namespace xc
{
  namespace
  {
    std::string unquoted(const std::string& t)
    {
      return t.size() >= 2 ? t.substr(1, t.size() - 2) : std::string();
    }

    bool is_numeric_literal(const Expr* e)
    {
      return is_literal_kind(e) && static_cast<const Literal*>(e)->type == "Numeric";
    }

    bool name_or_literal(const Expr* e)
    {
      return is_expr(e, EK::Name) || is_literal_kind(e);
    }

    const std::string& name_of(const Expr* e) { return static_cast<const Name*>(e)->name; }

    // THashMap:Get(k, @x) leaves x as it was when k is not there (tried on
    // 24.3.1.9: it returns .F. and x keeps its value), so 'x := h{k}' sets x
    // to Nil first, as a key not there reads.
    constexpr bool GET_LEAVES_A_MISS = true;

    // The Decimal 1, for '++' and '--'.
    const std::string DEC_ONE = "DEC_CREATE(\"1\", 1, 0)";

    bool compound(const std::string& op) { return op == "+=" || op == "-=" || op == "*=" || op == "/=" || op == "%="; }

    bool is_nil(const Expr* e)
    {
      return is_expr(e, EK::Literal) && lc(static_cast<const Literal*>(e)->text) == "nil";
    }

    // Whether a value is not Nil, asked of ValType(): TL++ will not compare
    // with Nil a value whose type it knows -- a literal, a name declared with
    // a type, what is assigned from one -- and ValType() takes any.
    std::string not_nil(const std::string& v) { return "ValType(" + v + ") != \"U\""; }

    void append(Lines& to, const Lines& more) { to.insert(to.end(), more.begin(), more.end()); }

    // What an 'fbv' temp holds, as its Local's comment says.
    const char* const HELD = "a value read twice by '?.' or 'in lo..hi', evaluated once";

    // A count raised for a scope.
    class Scoped
    {
    public:
      Scoped(int& count, int by) : n_(count), by_(by) { n_ += by_; }
      ~Scoped() { n_ -= by_; }
      Scoped(const Scoped&) = delete;
      Scoped& operator=(const Scoped&) = delete;

    private:
      int& n_;
      int by_;
    };

    // A value set for a scope, and put back.
    class Early
    {
    public:
      Early(int& at, int v) : at_(at), saved_(at) { at_ = v; }
      ~Early() { at_ = saved_; }
      Early(const Early&) = delete;
      Early& operator=(const Early&) = delete;

    private:
      int& at_;
      int saved_;
    };

    // The line end of a statement's span: where its code ends.
    template <class N> int code_stop(const N* n, const std::string& src)
    {
      std::string_view s(src);
      return n->from + static_cast<int>(code_end(s.substr(static_cast<std::size_t>(n->from),
                                                          static_cast<std::size_t>(n->to - n->from))));
    }
  }

  // ---- statements -----------------------------------------------------------
  void Emitter::collect(const Body& body, bool top)
  {
    for (const Stmt* s : body)
    {
      if (done_.count(s)) { continue; }
      busy_.clear();
      bool walked = false;
      SK k = s->kind;
      auto decl = k == SK::Declaration ? static_cast<const Declaration*>(s) : nullptr;
      Lines exits;
      // A declaration of the prologue keeps its place: its temps go before
      // it. A 'static' takes its value before any Local is there.
      bool prologue = decl && top && decl->scope == "local";
      Scoped no_temps(no_temps_, decl && decl->scope == "static" ? 1 : 0);
      if ((k == SK::CallStmt || k == SK::Assignment || prologue) && !fused_value(s) && !lowering(s)
          && !guard_value(s))
      {
        // The most common statements: their expressions, and nothing else.
        Early early(early_at_, prologue ? s->from : -1);
        expressions(exprs_of(s));
      }
      else if (const Guard* g = guard_value(s))
      {
        // A guard that is the statement's whole value: the statement inside a
        // Begin Sequence, the alternative in Recover.
        replace(s, false, guard_stmt(s, g));
      }
      else if (decl && !top && decl->scope == "local")
      {
        // A block local: an assignment where it was, a Local at the top. One
        // with no value is reset to Nil, so each entry starts fresh.
        Lines lines;
        Lines notes;
        for (const Declarator* dc : decl->declarators)
        {
          std::string n = local(dc->name);
          hoist(n, block_local_comment(dc, n));
          Lines l;
          if (dc->init)
          {
            l = init_lines(n, dc->init);
          }
          else if (!dc->dims.empty())
          {
            Lines dims;
            for (const Expr* d : dc->dims) { dims.push_back(expr(d)); }
            l = { n + " := Array(" + join(dims, ", ") + ")" };
          }
          else
          {
            l = { n + " := Nil" };
          }
          for (std::size_t i = 1; i < l.size(); i++) { notes.push_back(""); }
          notes.push_back(note_of(dc, n));
          append(lines, l);
        }
        replace(s, false, lines, notes);
      }
      else if (k == SK::Deferred)
      {
        // A 'defer' leaves where it is written; its body runs at the exits.
        const Defer* d = nullptr;
        for (const Defer& x : defers_)
        {
          if (x.from == s->from)
          {
            d = &x;
            break;
          }
        }
        int from = line_start(s->from);
        int end = line_end(code_stop(s, src_));
        if (d && !d->flag.empty())
        {
          edit(from, end, indent_at(s->from) + d->flag + " := .T.");
        }
        else
        {
          edit(from, after_break(end), "");
        }
        walked = true;
      }
      else if (k == SK::ReturnStmt && !fused_value(s) && !(exits = return_exits(s)).empty())
      {
        // A 'return' runs the pending defers and closes what is open.
        exits.push_back(with_edits(s, exprs_of(s)));
        replace(s, false, exits);
      }
      else if ((k == SK::ExitStmt || k == SK::LoopStmt) && !(exits = jump_exits()).empty())
      {
        exits.push_back(with_edits(s, {}));
        replace(s, false, exits);
      }
      else if (k == SK::UsingAlias)
      {
        // The area selected, and put back at 'end using' and on every way
        // out of the block.
        auto u = static_cast<const UsingAlias*>(s);
        Lines setup;
        Lines restore;
        std::string select;
        std::string prefix;
        if (declared(lc(u->area)))
        {
          std::string fal = gen("fal", "the alias of a 'using alias', from a variable");
          setup.push_back(fal + " := " + u->area);
          select = fal;
          prefix = "(" + fal + ")->";
        }
        else
        {
          select = "\"" + u->area + "\"";
          prefix = u->area + "->";
        }
        std::string far = gen("far", "the area selected before a 'using alias'");
        std::string frc = gen("frc", "the record the area was on before a 'using alias'");
        std::size_t at = setup.size() + 1;
        append(setup, { far + " := Alias()", "DbSelectArea(" + select + ")", frc + " := " + prefix + "(RecNo())" });
        if (u->order)
        {
          std::string fol = gen("fol", "the index order before a 'using alias'");
          append(setup, { fol + " := " + prefix + "(IndexOrd())", prefix + "(DbSetOrder(" + expr(u->order) + "))" });
          restore.push_back(prefix + "(DbSetOrder(" + fol + "))");
        }
        append(restore, { prefix + "(DbGoto(" + frc + "))", "If !Empty(" + far + ")", "  DbSelectArea(" + far + ")",
                          "EndIf" });
        header_to(s, line_end(s->from), at, setup);
        std::string raw = slice(s);
        std::size_t ce = code_end(raw);
        int start = s->from + static_cast<int>(last_from(std::string_view(raw).substr(0, ce), "using"));
        edit(start, s->from + static_cast<int>(ce), join_at(start, restore));
        closers_.push_back(Closer{ "using", restore });
        collect_bodies(s);
        closers_.pop_back();
        walked = true;
      }
      else if (const Expr* chain = fused_value(s))
      {
        // A chain from a source: the loop first, then the statement with its
        // result -- or the loop alone, for a chain run for its effects.
        bool statement = k == SK::CallStmt;
        Stream st = stream(chain, !statement);
        if (k == SK::ReturnStmt)
        {
          // What a 'return' runs first, then its value, as for any other.
          Lines lines = return_exits(s);
          append(lines, st.lines);
          lines.push_back("return " + st.result);
          st.lines = lines;
        }
        else if (!statement)
        {
          st.lines.push_back(expr(static_cast<const Assignment*>(s)->target) + " := " + st.result);
        }
        replace(s, false, st.lines);
      }
      else if (decl && (decl->scope == "private" || decl->scope == "public")
               && std::any_of(decl->declarators.begin(), decl->declarators.end(),
                              [&](const Declarator* d) { return loop_value(d->init); }))
      {
        // Declared where it was, and given its value after the loop.
        std::string kw = words(trim(split_comment(slice(s)).first)).at(0);
        Lines lines{ names_line(kw, decl) };
        for (const Declarator* d : decl->declarators)
        {
          if (d->init) { append(lines, init_lines(d->name, d->init)); }
        }
        replace(s, true, lines);
      }
      else if (lowering(s))
      {
        Early early(early_at_, prologue ? s->from : -1);
        Lowered l = lower(s);
        Lines notes;
        if (decl)
        {
          for (std::size_t i = 1; i < l.lines.size(); i++) { notes.push_back(""); }
          notes.push_back(notes_of(decl));
        }
        replace(s, l.block, l.lines, notes);
      }
      else if (k == SK::IfStmt && static_cast<const IfStmt*>(s)->header_decl)
      {
        auto i = static_cast<const IfStmt*>(s);
        const Declarator* d = i->header_decl;
        std::string x = nm(s, d->name);
        hoist(x, "a block local");
        std::string init = expr(d->init);
        Map saved = subst_;
        if (auto r = renames_.find(s); r != renames_.end())
        {
          for (const auto& [a, b] : r->second.head) { subst_[a] = b; }
        }
        header(s, i->branches[0]->cond, 1, { x + " := " + init, "If " + expr(i->branches[0]->cond) });
        std::vector<Expr*> conds;
        for (std::size_t b = 1; b < i->branches.size(); b++) { conds.push_back(i->branches[b]->cond); }
        expressions(conds);
        subst_ = saved;
      }
      else if (k == SK::WhileStmt && static_cast<const WhileStmt*>(s)->header_decl)
      {
        // Bound and tested on every round, 'loop' included.
        auto w = static_cast<const WhileStmt*>(s);
        const Declarator* d = w->header_decl;
        std::string x = nm(s, d->name);
        hoist(x, "a block local");
        std::string init = expr(d->init);
        Map saved = subst_;
        if (auto r = renames_.find(s); r != renames_.end())
        {
          for (const auto& [a, b] : r->second.head) { subst_[a] = b; }
        }
        std::string cond = expr(w->cond);
        subst_ = saved;
        header(s, w->cond, 0, { "While .T.", "  " + x + " := " + init, "  If !(" + cond + ")", "    Exit", "  EndIf" });
      }
      else if (k == SK::ForStmt && (static_cast<const ForStmt*>(s)->var_local
                                    || subst_.count(lc(static_cast<const ForStmt*>(s)->var))))
      {
        // The header written out, and a 'next i' loses the name, which is no
        // longer the counter's.
        auto f = static_cast<const ForStmt*>(s);
        std::string x = f->var_local ? nm(s, f->var) : local(f->var);
        if (f->var_local) { hoist(x, "a block local"); }
        header(s, f->step ? f->step : f->to_, 0,
               { "For " + x + " := " + expr(f->from_) + " To " + expr(f->to_)
                 + (f->step ? " Step " + expr(f->step) : "") });
        if (f->endname_from >= 0 && x != f->var) { drop_endname(f->endname_from, f->endname_to); }
      }
      else if (k == SK::ForInStmt && is_expr(static_cast<const ForInStmt*>(s)->source, EK::Interval))
      {
        // 'for x [, i] in lo..hi': a count, the element a copy of it.
        auto f = static_cast<const ForInStmt*>(s);
        auto r = static_cast<const Interval*>(f->source);
        std::string el = nm(s, f->elem);
        std::optional<std::string> ix;
        if (f->index) { ix = nm(s, *f->index); }
        hoist(el, "a block local");
        if (ix) { hoist(*ix, "a block local"); }
        Lines h;
        std::string lo = range_end(r->lo, "flo", "the low end of a range", h);
        std::string hi = range_end(r->hi, "fhi", "the high end of a range", h);
        std::string fi = gen("fi", "the counter of a 'for ... in'");
        if (ix) { h.push_back(*ix + " := 0"); }
        std::size_t at = h.size();
        append(h, { "For " + fi + " := " + lo + " To " + hi, "  " + el + " := " + fi });
        if (ix) { h.push_back("  " + *ix + "++"); }
        header(s, r->hi, at, h);
        if (f->endname_from >= 0) { drop_endname(f->endname_from, f->endname_to); }
      }
      else if (k == SK::ForInStmt && is_expr(static_cast<const ForInStmt*>(s)->source, EK::Call)
               && source_kind(static_cast<const ForInStmt*>(s)->source) == "lines")
      {
        // 'for x in lines(p)': opened only if it exists, advanced at the top,
        // and closed on every way out.
        auto f = static_cast<const ForInStmt*>(s);
        std::string el = nm(s, f->elem);
        std::optional<std::string> ix;
        if (f->index) { ix = nm(s, *f->index); }
        hoist(el, "a block local");
        if (ix) { hoist(*ix, "a block local"); }
        std::string fs = gen("fs", "the path of the file walked");
        std::string fok = gen("fok", "whether the file opened");
        Lines h{ fs + " := " + expr(static_cast<const Call*>(f->source)->args[0]), fok + " := File(" + fs + ")",
                 "If " + fok, "  FT_FUse(" + fs + ")", "  FT_FGoTop()", "EndIf" };
        if (ix) { h.push_back(*ix + " := 0"); }
        std::size_t at = h.size();
        h.push_back("While " + fok + " .And. !FT_FEof()");
        if (ix) { h.push_back("  " + *ix + "++"); }
        append(h, { "  " + el + " := FT_FReadLn()", "  FT_FSkip()" });
        header(s, f->source, at, h);
        // 'next' becomes the end of the walk.
        std::string raw = slice(s);
        std::size_t ce = code_end(raw);
        int nx = s->from + static_cast<int>(lc(raw.substr(0, ce)).rfind("next"));
        edit(nx, s->from + static_cast<int>(ce), join_at(nx, { "EndDo", "If " + fok, "  FT_FUse()", "EndIf" }));
        closers_.push_back(Closer{ "lines", { "If " + fok, "  FT_FUse()", "EndIf" } });
        closers_.push_back(Closer{ "loop", {} });
        collect_bodies(s);
        closers_.pop_back();
        closers_.pop_back();
        walked = true;
      }
      else if (k == SK::ForInStmt)
      {
        // The source evaluated once; the index, when named, is the counter.
        auto f = static_cast<const ForInStmt*>(s);
        std::string el = nm(s, f->elem);
        std::optional<std::string> ix;
        if (f->index) { ix = nm(s, *f->index); }
        hoist(el, "a block local");
        if (ix) { hoist(*ix, "a block local"); }
        std::string src = gen("fs", "the source of a 'for ... in'");
        std::string ctr = ix ? *ix : gen("fi", "the counter of a 'for ... in'");
        header(s, f->source, 1, { src + " := " + expr(f->source), "For " + ctr + " := 1 To Len(" + src + ")",
                                  "  " + el + " := " + src + "[" + ctr + "]" });
        if (f->endname_from >= 0) { drop_endname(f->endname_from, f->endname_to); }
      }
      else if (k == SK::ForTimesStmt)
      {
        // The count evaluated once, unless it is a number already.
        auto f = static_cast<const ForTimesStmt*>(s);
        std::string ctr = gen("fi", "the counter of a 'for ... times'");
        if (is_numeric_literal(f->count))
        {
          header(s, f->count, 0, { "For " + ctr + " := 1 To " + expr(f->count) });
        }
        else
        {
          std::string n = gen("fn", "the count of a 'for ... times'");
          header(s, f->count, 1, { n + " := " + expr(f->count), "For " + ctr + " := 1 To " + n });
        }
      }
      else if (k == SK::CaseStmt && (static_cast<const CaseStmt*>(s)->subject_decl
                                     || static_cast<const CaseStmt*>(s)->subject_assign))
      {
        // The subject evaluated once, before the 'case's read it.
        auto c = static_cast<const CaseStmt*>(s);
        std::string bind;
        const Expr* last = nullptr;
        if (const Declarator* d = c->subject_decl)
        {
          std::string x = nm(c, d->name);
          hoist(x, "a block local");
          bind = x + " := " + expr(d->init);
          last = d->init;
        }
        else
        {
          const Assignment* a = c->subject_assign;
          bind = expr(a->target) + " := " + expr(a->value);
          last = a->value;
        }
        header(s, last, 1, { bind, "Do Case" });
        Map saved = subst_;
        if (auto r = renames_.find(s); r != renames_.end())
        {
          for (const auto& [a, b] : r->second.head) { subst_[a] = b; }
        }
        std::vector<Expr*> conds;
        for (const Branch* b : c->branches) { conds.push_back(b->cond); }
        expressions(conds);
        subst_ = saved;
      }
      else if (k == SK::WithObject)
      {
        // The subject bound once, ':x' its 'x', and the 'end with' line gone.
        auto w = static_cast<const WithObject*>(s);
        std::string t = gen("fbs", "the subject of a 'with object'");
        header(s, w->subject, 0, { t + " := " + expr(w->subject) });
        drop_closer(s, "with");
        // Its body a level less deep: the lines that made the level are gone.
        if (!w->body.empty())
        {
          std::string raw = slice(s);
          std::size_t ce = code_end(raw);
          int from = after_break(line_end(code_stop(w->subject, src_)));
          int to = line_start(s->from + static_cast<int>(last_from(std::string_view(raw).substr(0, ce), "with")));
          std::string outer = text(line_start(s->from), s->from);
          std::string inner = text(line_start(w->body[0]->from), w->body[0]->from);
          bool blank = inner.find_first_not_of(" \t") == std::string::npos;
          if (blank && inner.size() > outer.size() && inner.compare(0, outer.size(), outer) == 0 && from < to)
          {
            dedents_.push_back(Dedent{ from, to, static_cast<int>(inner.size() - outer.size()) });
          }
        }
        subjects_.push_back(t);
        collect_bodies(s);
        subjects_.pop_back();
        walked = true;
      }
      else if (k == SK::RawStmt)
      {
        // The text for the preprocessor, as written -- but with its strings
        // interpolated and its renamed block locals renamed.
        auto r = static_cast<const RawStmt*>(s);
        std::string raw = slice(s);
        if (r->block)
        {
          std::size_t ce = code_end(raw);
          int from = line_start(s->from);
          int last = s->from + static_cast<int>(last_from(std::string_view(raw).substr(0, ce), "raw"));
          int end = line_end(s->from + static_cast<int>(ce));
          Lines out;
          std::string open = split_comment(text(s->from, line_end(s->from))).second;
          if (!open.empty()) { out.push_back(indent_at(s->from) + open); }
          for (const std::string& l : r->lines) { out.push_back(raw_text(l)); }
          std::string shut = split_comment(text(last, end)).second;
          if (!shut.empty()) { out.push_back(indent_at(last) + shut); }
          std::string t;
          for (const std::string& l : out) { t += l + nl_; }
          edit(from, after_break(end), t);
        }
        else if (!r->lines.empty())
        {
          std::size_t at = raw.find(r->lines[0]);
          if (at == std::string::npos) { at = 0; }
          edit(s->from, s->from + static_cast<int>(at + r->lines[0].size()), raw_text(r->lines[0]));
        }
      }
      else
      {
        expressions(exprs_of(s));
      }
      // A Modified is lowered whole, with what it holds, and so is a one-line
      // form. A loop's body is marked, so an 'exit' in it knows what it leaves.
      if (!bodies_of(s).empty() && !(k == SK::Modified || s->oneline || walked))
      {
        bool loop = k == SK::WhileStmt || k == SK::ForStmt || k == SK::ForInStmt || k == SK::ForTimesStmt;
        if (loop) { closers_.push_back(Closer{ "loop", {} }); }
        collect_bodies(s);
        if (loop) { closers_.pop_back(); }
      }
    }
  }

  // 'next oItem': the name after 'next' goes, with the blanks before it.
  void Emitter::drop_endname(int from, int to)
  {
    while (from > 0 && (src_[static_cast<std::size_t>(from) - 1] == ' ' || src_[static_cast<std::size_t>(from) - 1] == '\t'))
    {
      from--;
    }
    edit(from, to, "");
  }

  // What a 'return' at s does first: the defers that ran before it, the last
  // written first, then everything open, innermost first.
  Lines Emitter::return_exits(const Stmt* s)
  {
    Lines lines;
    for (auto it = defers_.rbegin(); it != defers_.rend(); ++it)
    {
      std::string at = defer_at(*it, s);
      if (at == "yes") { append(lines, it->lines); }
      else if (at == "maybe") { append(lines, guarded(*it)); }
    }
    for (auto it = closers_.rbegin(); it != closers_.rend(); ++it)
    {
      if (it->key != "loop") { append(lines, it->lines); }
    }
    return lines;
  }

  // Whether a defer has run when the 'return' r runs: 'yes', 'no', or
  // 'maybe' -- then its flag says.
  std::string Emitter::defer_at(const Defer& d, const Stmt* r)
  {
    const std::vector<Step>& dp = d.at->path;
    const Place& rplace = paths_[r];
    const std::vector<Step>& rp = rplace.path;
    if (d.from < r->from)
    {
      std::size_t n = dp.size();
      if (rp.size() >= n && n >= 1)
      {
        bool same = true;
        for (std::size_t i = 0; i + 1 < n; i++)
        {
          same = same && rp[i].parent == dp[i].parent && rp[i].body == dp[i].body && rp[i].index == dp[i].index;
        }
        if (same && rp[n - 1].parent == dp[n - 1].parent && rp[n - 1].body == dp[n - 1].body
            && rp[n - 1].index > dp[n - 1].index)
        {
          return "yes";
        }
      }
      return "maybe";
    }
    for (const Stmt* l : rplace.loops)
    {
      if (std::find(d.at->loops.begin(), d.at->loops.end(), l) != d.at->loops.end()) { return "maybe"; }
    }
    return "no";
  }

  Lines Emitter::guarded(const Defer& d) const
  {
    Lines out{ "If " + d.flag };
    for (const std::string& l : d.lines) { out.push_back("  " + l); }
    out.push_back("EndIf");
    return out;
  }

  void Emitter::place_statements(const Body& body)
  {
    paths_.clear();
    std::function<void(const Body&, const Stmt*, int, const std::vector<Step>&, const std::vector<const Stmt*>&)>
      visit = [&](const Body& b, const Stmt* parent, int k, const std::vector<Step>& above,
                  const std::vector<const Stmt*>& loops)
    {
      for (std::size_t i = 0; i < b.size(); i++)
      {
        const Stmt* s = b[i];
        std::vector<Step> here = above;
        here.push_back(Step{ parent, k, static_cast<int>(i) });
        paths_[s] = Place{ here, loops };
        bool loop = s->kind == SK::WhileStmt || s->kind == SK::ForStmt || s->kind == SK::ForInStmt
                    || s->kind == SK::ForTimesStmt;
        std::vector<const Stmt*> inner = loops;
        if (loop) { inner.push_back(s); }
        int j = 0;
        for (const Body& x : bodies_of(s)) { visit(x, s, j++, here, inner); }
      }
    };
    visit(body, nullptr, -1, {}, {});
  }

  Lines Emitter::jump_exits() const
  {
    Lines lines;
    for (auto it = closers_.rbegin(); it != closers_.rend(); ++it)
    {
      if (it->key == "loop") { break; }
      append(lines, it->lines);
    }
    return lines;
  }

  // A statement as the lines it becomes where it is spliced (a defer's body).
  Lines Emitter::stmt_lines(const Stmt* s)
  {
    if (const Guard* g = guard_value(s)) { return guard_stmt(s, g); }
    if (const Expr* chain = fused_value(s))
    {
      bool statement = s->kind == SK::CallStmt;
      Stream st = stream(chain, !statement);
      if (s->kind == SK::Assignment)
      {
        st.lines.push_back(expr(static_cast<const Assignment*>(s)->target) + " := " + st.result);
      }
      return st.lines;
    }
    if (lowering(s)) { return lower(s).lines; }
    return lines_of(with_edits(s, exprs_of(s)));
  }

  // ---- chains ---------------------------------------------------------------
  Emitter::Stream Emitter::stream(const Expr* chain, bool collect)
  {
    const Expr* call = source_call(chain);
    std::vector<Call*> stages;
    if (is_expr(chain, EK::Pipeline)) { stages = static_cast<const Pipeline*>(chain)->stages; }
    if (call) { return walk_chain(call, std::nullopt, stages, collect); }
    // An array: the loop starts where fuse_from says, and the stages before
    // it apply as calls. A name is walked as it is; anything else is bound
    // once.
    const Expr* src = static_cast<const Pipeline*>(chain)->source;
    int from = fuse_from(stages, declared_fn(), !collect);
    if (from < 0) { from = 0; }
    if (from == 0 && is_expr(src, EK::Name)) { return walk_chain(nullptr, expr(src), stages, collect); }
    std::string fs = gen("fs", "the array walked");
    std::vector<Call*> before(stages.begin(), stages.begin() + from);
    std::vector<Call*> after(stages.begin() + from, stages.end());
    std::string bind = fs + " := " + calls(expr(src), before);
    Stream st = walk_chain(nullptr, fs, after, collect);
    st.lines.insert(st.lines.begin(), bind);
    return st;
  }

  // Stages applied to the text of an array as calls, each one around the one
  // before.
  std::string Emitter::calls(const std::string& t, const std::vector<Call*>& stages)
  {
    std::string acc = t;
    for (const Call* st : stages)
    {
      Lines args{ acc };
      for (const Expr* a : st->args) { args.push_back(block_arg(st->name, a)); }
      acc = call_name(st->name) + "(" + join(args, ", ") + ")";
    }
    return acc;
  }

  // The loop of a chain: over a source (call), or over the array whose text
  // is over. The stages go inside it in order, and the terminal, or an AAdd
  // when there is none, collects; the stages after that are a chain over what
  // was collected.
  Emitter::Stream Emitter::walk_chain(const Expr* call, const std::optional<std::string>& over,
                                      const std::vector<Call*>& stages, bool collect)
  {
    Split split = split_stages(stages, call == nullptr, declared_fn());
    Lines setup;
    Lines ahead;
    Lines body;
    Lines close;
    Lines teardown;
    Lines finish;
    std::string head;
    std::optional<std::string> advance;
    std::optional<std::string> read;
    std::optional<std::string> elem;
    std::optional<std::string> prefix;
    std::optional<std::string> fv;
    std::string end = "EndDo";

    if (is_expr(call, EK::Interval))
    {
      // A range counts; the element is a copy of the counter.
      auto r = static_cast<const Interval*>(call);
      std::string lo = range_end(r->lo, "flo", "the low end of a range", setup);
      std::string hi = range_end(r->hi, "fhi", "the high end of a range", setup);
      std::string fi = gen("fi", "the counter of a range");
      fv = gen("fv", "the element walked");
      head = "For " + fi + " := " + lo + " To " + hi;
      read = *fv + " := " + fi;
      end = "Next";
      elem = fv;
    }
    else if (!call)
    {
      // An array, bound already: a name, or the array walked.
      std::string fi = gen("fi", "the position in the array walked");
      fv = gen("fv", "the element walked");
      head = "For " + fi + " := 1 To Len(" + *over + ")";
      read = *fv + " := " + *over + "[" + fi + "]";
      end = "Next";
      elem = fv;
    }
    else if (lc(static_cast<const Call*>(call)->name) == "rows")
    {
      // A literal alias is written out ('SA1->A1_COD'); anything else is
      // bound once and reached as '(alias)->'.
      auto c = static_cast<const Call*>(call);
      const Expr* a = c->args[0];
      std::string select;
      if (is_literal_kind(a) && !is_expr(a, EK::Interp) && static_cast<const Literal*>(a)->type == "Character")
      {
        select = static_cast<const Literal*>(a)->text;
        prefix = unquoted(select) + "->";
      }
      else
      {
        std::string fal = gen("fal", "the alias of the area walked");
        setup.push_back(fal + " := " + expr(a));
        select = fal;
        prefix = "(" + fal + ")->";
      }
      std::string far = gen("far", "the area selected before the walk");
      std::string frc = gen("frc", "the record the area was on before the walk");
      append(setup, { far + " := Alias()", "DbSelectArea(" + select + ")", frc + " := " + *prefix + "(RecNo())",
                      c->args.size() > 1 ? *prefix + "(DbSeek(" + expr(c->args[1]) + "))" : *prefix + "(DbGoTop())" });
      head = "While !" + *prefix + "(Eof())";
      advance = *prefix + "(DbSkip())";
      teardown = { *prefix + "(DbGoto(" + frc + "))", "If !Empty(" + far + ")", "  DbSelectArea(" + far + ")", "EndIf" };
    }
    else
    {
      // A path held in a variable is used as it is; anything else is bound
      // once.
      const Expr* path = static_cast<const Call*>(call)->args[0];
      std::string fs;
      if (is_expr(path, EK::Name))
      {
        fs = expr(path);
      }
      else
      {
        fs = gen("fs", "the path of the file walked");
        setup.push_back(fs + " := " + expr(path));
      }
      std::string fok = gen("fok", "whether the file opened");
      fv = gen("fv", "the element walked");
      append(setup, { fok + " := File(" + fs + ")", "If " + fok, "  FT_FUse(" + fs + ")", "  FT_FGoTop()", "EndIf" });
      head = "While " + fok + " .And. !FT_FEof()";
      read = *fv + " := FT_FReadLn()";
      advance = "FT_FSkip()";
      teardown = { "If " + fok, "  FT_FUse()", "EndIf" };
      elem = fv;
    }

    std::string ind;
    auto lambda = [&](const Call* st)
    {
      const Expr* a = st->args[0];
      if (is_expr(a, EK::Lambda)) { return bound(static_cast<const Lambda*>(a), elem, prefix); }
      return name_of(a) + "(" + elem.value_or("") + ")";   // a function name
    };
    auto el = [&] { return elem.value_or(""); };
    for (const Call* st : split.fused)
    {
      std::string n = lc(st->name);
      if (n == "filter")
      {
        body.push_back(ind + "If " + lambda(st));
        close.insert(close.begin(), ind + "EndIf");
        ind += "  ";
      }
      else if (n == "reject")
      {
        body.push_back(ind + "If !(" + lambda(st) + ")");
        close.insert(close.begin(), ind + "EndIf");
        ind += "  ";
      }
      else if (n == "map")
      {
        if (!fv) { fv = gen("fv", "the element walked"); }
        body.push_back(ind + *fv + " := " + lambda(st));
        elem = fv;
      }
      else if (n == "tap")
      {
        body.push_back(ind + lambda(st));
      }
      else if (n == "take" || n == "drop")
      {
        // A number is the limit as it is; anything else is bound once.
        const Expr* x = st->args[0];
        std::string limit;
        std::string fn = gen("fn", "how many elements have passed");
        if (is_numeric_literal(x))
        {
          limit = expr(x);
        }
        else
        {
          limit = gen("flm", n == "take" ? "the limit of a take" : "the limit of a drop");
          ahead.push_back(limit + " := " + expr(x));
        }
        ahead.push_back(fn + " := 0");
        if (n == "take")
        {
          append(body, { ind + "If " + fn + " >= " + limit, ind + "  Exit", ind + "EndIf", ind + fn + "++" });
        }
        else
        {
          // The rest of the chain in the Else: the first n pass by.
          append(body, { ind + "If " + fn + " < " + limit, ind + "  " + fn + "++", ind + "Else" });
          close.insert(close.begin(), ind + "EndIf");
          ind += "  ";
        }
      }
      else if (n == "takewhile")
      {
        append(body, { ind + "If !(" + lambda(st) + ")", ind + "  Exit", ind + "EndIf" });
      }
      else if (n == "dropwhile")
      {
        // A flag, not a test: once the leading run is over, an element that
        // would have matched still passes.
        std::string flag = gen("fdr", "whether the leading run of a dropwhile is still on");
        ahead.push_back(flag + " := .T.");
        append(body, { ind + "If !(" + flag + " .And. (" + lambda(st) + "))", ind + "  " + flag + " := .F." });
        close.insert(close.begin(), ind + "EndIf");
        ind += "  ";
      }
      else if (n == "expand")
      {
        // A loop inside the loop: the rest runs once per inner element.
        std::string bag = gen("fbg", "the inner array of an expand");
        std::string j = gen("fj", "the position in the inner array of an expand");
        if (!fv) { fv = gen("fv", "the element walked"); }
        append(body, { ind + bag + " := " + lambda(st), ind + "For " + j + " := 1 To Len(" + bag + ")",
                       ind + "  " + *fv + " := " + bag + "[" + j + "]" });
        close.insert(close.begin(), ind + "Next");
        elem = fv;
        ind += "  ";
      }
      else if (n == "scan")
      {
        // A running value, carried from element to element.
        std::string fa = gen("fa", "the running value of a scan");
        ahead.push_back(fa + " := " + expr(st->args[1]));
        if (!fv) { fv = gen("fv", "the element walked"); }
        append(body, { ind + fa + " := " + bound2(static_cast<const Lambda*>(st->args[0]), fa, el()),
                       ind + *fv + " := " + fa });
        elem = fv;
      }
      else if (n == "pairwise")
      {
        // Each element with the one before it, from the second on.
        std::string fpv = gen("fpv", "the element pairwise saw last");
        std::string fhd = gen("fhd", "whether pairwise has seen an element");
        std::string fol = gen("fol", "the element before, for pairwise");
        std::string frd = gen("frd", "whether pairwise has a pair");
        append(ahead, { fpv + " := Nil", fhd + " := .F." });
        if (!fv) { fv = gen("fv", "the element walked"); }
        append(body, { ind + fol + " := " + fpv, ind + frd + " := " + fhd, ind + fpv + " := " + el(),
                       ind + fhd + " := .T.", ind + "If " + frd, ind + "  " + *fv + " := {" + fol + ", " + el() + "}" });
        close.insert(close.begin(), ind + "EndIf");
        elem = fv;
        ind += "  ";
      }
      else if (n == "distinct")
      {
        // An element seen before is skipped: what distinct() asks of each, the
        // runtime's record of the values seen asks here.
        std::string seen = gen("ffs", "the values distinct has seen");
        ahead.push_back(seen + " := THashMap():New()");
        body.push_back(ind + "If !u_xtpl_seen(" + seen + ", " + el() + ")");
        close.insert(close.begin(), ind + "EndIf");
        ind += "  ";
      }
      else if (n == "distinctadjacent")
      {
        // A key equal to the one before is skipped; the first always passes.
        std::string op = gen("fop", "whether distinctAdjacent has seen an element");
        std::string ls = gen("fls", "the key distinctAdjacent saw last");
        std::string pb = gen("fpb", "the key of the element distinctAdjacent looks at");
        append(ahead, { op + " := .F.", ls + " := Nil", pb + " := Nil" });
        append(body, { ind + pb + " := " + (st->args.empty() ? el() : lambda(st)),
                       ind + "If !(" + op + " .And. (" + pb + " == " + ls + "))", ind + "  " + op + " := .T.",
                       ind + "  " + ls + " := " + pb });
        close.insert(close.begin(), ind + "EndIf");
        ind += "  ";
      }
    }

    std::optional<std::string> fo;
    const Call* terminal = split.terminal;
    std::string t = terminal ? lc(terminal->name) : "";
    if (!t.empty() || collect || !split.rest.empty())
    {
      fo = gen("fo", !split.rest.empty() ? "what a loop collected, for the stages after it" : "the result of the chain");
      const std::string& o = *fo;
      std::optional<std::string> cond;
      if (terminal && !terminal->args.empty() && t != "reduce" && t != "fold" && t != "join") { cond = lambda(terminal); }
      std::string c = cond.value_or("");
      if (t == "asum")
      {
        ahead.push_back(o + " := 0");
        body.push_back(ind + o + " := " + o + " + " + el());
      }
      else if (t == "count")
      {
        ahead.push_back(o + " := 0");
        if (cond) { append(body, { ind + "If " + c, ind + "  " + o + "++", ind + "EndIf" }); }
        else { body.push_back(ind + o + "++"); }
      }
      else if (t == "anyof")
      {
        ahead.push_back(o + " := .F.");
        append(body, { ind + "If " + c, ind + "  " + o + " := .T.", ind + "  Exit", ind + "EndIf" });
      }
      else if (t == "allof")
      {
        ahead.push_back(o + " := .T.");
        append(body, { ind + "If !(" + c + ")", ind + "  " + o + " := .F.", ind + "  Exit", ind + "EndIf" });
      }
      else if (t == "noneof")
      {
        ahead.push_back(o + " := .T.");
        append(body, { ind + "If " + c, ind + "  " + o + " := .F.", ind + "  Exit", ind + "EndIf" });
      }
      else if (t == "first")
      {
        ahead.push_back(o + " := Nil");
        if (cond) { append(body, { ind + "If " + c, ind + "  " + o + " := " + el(), ind + "  Exit", ind + "EndIf" }); }
        else { append(body, { ind + o + " := " + el(), ind + "Exit" }); }
      }
      else if (t == "aprod")
      {
        ahead.push_back(o + " := 1");
        body.push_back(ind + o + " := " + o + " * " + el());
      }
      else if (t == "amax" || t == "amin")
      {
        ahead.push_back(o + " := Nil");
        append(body, { ind + "If " + o + " == Nil", ind + "  " + o + " := " + el(), ind + "Else",
                       ind + "  " + o + " := " + (t == "amax" ? "Max" : "Min") + "(" + o + ", " + el() + ")",
                       ind + "EndIf" });
      }
      else if (t == "join")
      {
        // The elements collected, and joined once, after the loop, by the
        // runtime. The separator: a literal as it is, anything else bound
        // once, before the loop.
        std::string sep;
        if (!terminal->args.empty())
        {
          const Expr* x = terminal->args[0];
          if (is_literal_kind(x) && !is_expr(x, EK::Interp))
          {
            sep = ", " + expr(x);
          }
          else
          {
            std::string fsp = gen("fsp", "the separator of a join");
            ahead.push_back(fsp + " := " + expr(x));
            sep = ", " + fsp;
          }
        }
        ahead.push_back(o + " := {}");
        body.push_back(ind + "AAdd(" + o + ", " + el() + ")");
        finish.push_back(o + " := u_xtpl_join(" + o + sep + ")");
      }
      else if (t == "reduce")
      {
        // The seed once, before the loop; the step with its parameters
        // written as the result so far and the element.
        ahead.push_back(o + " := " + expr(terminal->args[1]));
        body.push_back(ind + o + " := " + bound2(static_cast<const Lambda*>(terminal->args[0]), o, el()));
      }
      else if (t == "fold")
      {
        // No seed: the first element is the start.
        ahead.push_back(o + " := Nil");
        append(body, { ind + "If " + o + " == Nil", ind + "  " + o + " := " + el(), ind + "Else",
                       ind + "  " + o + " := " + bound2(static_cast<const Lambda*>(terminal->args[0]), o, el()),
                       ind + "EndIf" });
      }
      else if (t == "chunkby")
      {
        // The runs of elements whose key is equal, each an array.
        std::string fch = gen("fch", "the chunk chunkby is filling");
        std::string fky = gen("fky", "the key of the chunk chunkby is filling");
        std::string fop = gen("fop", "whether chunkby has seen an element");
        std::string fsn = gen("fsn", "the key of the element chunkby looks at");
        append(ahead, { fch + " := {}", fky + " := Nil", fop + " := .F.", fsn + " := Nil", o + " := {}" });
        append(body, { ind + fsn + " := " + c, ind + "If !" + fop, ind + "  " + fop + " := .T.",
                       ind + "  " + fky + " := " + fsn, ind + "ElseIf !(" + fsn + " == " + fky + ")",
                       ind + "  AAdd(" + o + ", " + fch + ")", ind + "  " + fch + " := {}", ind + "  " + fky + " := " + fsn,
                       ind + "EndIf", ind + "AAdd(" + fch + ", " + el() + ")" });
        append(finish, { "If " + fop, "  AAdd(" + o + ", " + fch + ")", "EndIf" });
      }
      else if (t == "maxby" || t == "minby")
      {
        // The element whose key is the greatest (least): the first of them.
        std::string fbs = gen("fbs", "the best key maxby/minby has seen");
        std::string fop = gen("fop", "whether maxby/minby has seen an element");
        std::string fpb = gen("fpb", "the key of the element maxby/minby looks at");
        append(ahead, { fbs + " := Nil", fop + " := .F.", fpb + " := Nil", o + " := Nil" });
        append(body, { ind + fpb + " := " + c,
                       ind + "If !" + fop + " .Or. " + fpb + " " + (t == "maxby" ? ">" : "<") + " " + fbs,
                       ind + "  " + fop + " := .T.", ind + "  " + fbs + " := " + fpb, ind + "  " + o + " := " + el(),
                       ind + "EndIf" });
      }
      else
      {
        ahead.push_back(o + " := {}");
        body.push_back(ind + "AAdd(" + o + ", " + el() + ")");
      }
    }

    Lines loop{ head };
    if (read) { loop.push_back("  " + *read); }
    for (const std::string& l : body) { loop.push_back("  " + l); }
    for (const std::string& l : close) { loop.push_back("  " + l); }
    if (advance) { loop.push_back("  " + *advance); }
    loop.push_back(end);
    Lines lines = setup;
    append(lines, ahead);
    append(lines, loop);
    append(lines, finish);
    append(lines, teardown);
    if (split.rest.empty()) { return Stream{ fo.value_or("Nil"), lines }; }

    // The stages after the loop, over what it collected.
    const std::vector<Call*>& after = split.rest;
    int from = fuse_from(after, declared_fn(), !collect);
    if (from < 0)
    {
      std::string c = calls(*fo, after);
      if (collect) { return Stream{ c, lines }; }
      lines.push_back(c);
      return Stream{ "Nil", lines };
    }
    std::string arr = *fo;
    if (from > 0)
    {
      arr = gen("fs", "the array walked");
      lines.push_back(arr + " := " + calls(*fo, std::vector<Call*>(after.begin(), after.begin() + from)));
    }
    Stream more = walk_chain(nullptr, arr, std::vector<Call*>(after.begin() + from, after.end()), collect);
    append(lines, more.lines);
    return Stream{ more.result, lines };
  }

  // An end of a range: a number or a name as it is, anything else bound once
  // before the loop.
  std::string Emitter::range_end(const Expr* e, const std::string& kind, const std::string& comment, Lines& setup)
  {
    if (is_numeric_literal(e) || is_expr(e, EK::Name)) { return expr(e); }
    std::string t = gen(kind, comment);
    setup.push_back(t + " := " + expr(e));
    return t;
  }

  // A stage's lambda body, its parameter bound to the element: the value's
  // text, or -- over a record, before a map -- the area prefix for its fields.
  std::string Emitter::bound(const Lambda* l, const std::optional<std::string>& elem,
                             const std::optional<std::string>& prefix)
  {
    std::string p = lc(l->params.at(0));
    Map s = subst_;
    Map f = field_;
    if (elem)
    {
      subst_[p] = *elem;
      field_.erase(p);
    }
    else
    {
      field_[p] = prefix.value_or("");
      subst_.erase(p);
    }
    std::string t = l->body.empty() ? std::string() : expr(l->body[0]);
    subst_ = s;
    field_ = f;
    return t;
  }

  std::string Emitter::bound2(const Lambda* l, const std::string& carried, const std::string& element)
  {
    std::string a = lc(l->params.at(0));
    std::string b = lc(l->params.at(1));
    Map s = subst_;
    Map f = field_;
    subst_[a] = carried;
    subst_[b] = element;
    field_.erase(a);
    field_.erase(b);
    std::string t = l->body.empty() ? std::string() : expr(l->body[0]);
    subst_ = s;
    field_ = f;
    return t;
  }

  // 'name := value' as lines: the loop first when the value is a chain, a
  // Begin Sequence when it is a guard.
  Lines Emitter::init_lines(const std::string& name, const Expr* value)
  {
    if (!loop_value(value)) { return { name + " := " + expr(value) }; }
    if (is_expr(value, EK::Guard)) { return sequence_lines(name, static_cast<const Guard*>(value)); }
    Stream st = stream(as_chain(value), true);
    st.lines.push_back(name + " := " + st.result);
    return st.lines;
  }

  // A guard that is a statement's whole value -- 'x := ...', 'return ...';
  // a declaration's goes by init_lines() -- runs as statements. One inside an
  // expression stays an expression, a call to u_xtpl_safe_pipe().
  const Guard* Emitter::guard_value(const Stmt* s) const
  {
    const Expr* v = nullptr;
    if (s->kind == SK::Assignment && static_cast<const Assignment*>(s)->op == ":=" && !lowering(s))
    {
      v = static_cast<const Assignment*>(s)->value;
    }
    else if (s->kind == SK::ReturnStmt)
    {
      v = static_cast<const ReturnStmt*>(s)->value;
    }
    return is_expr(v, EK::Guard) ? static_cast<const Guard*>(v) : nullptr;
  }

  // The statement a guard is the whole value of, as lines: assigned in the
  // Begin Sequence -- a name itself, anything else from a temp after it -- or
  // returned from a temp, after what a 'return' runs first.
  Lines Emitter::guard_stmt(const Stmt* s, const Guard* g)
  {
    if (s->kind == SK::ReturnStmt)
    {
      Lines lines = return_exits(s);
      std::string h = temp("ht", "the value a 'return ... fallback' returns");
      append(lines, sequence_lines(h, g));
      lines.push_back("return " + h);
      return lines;
    }
    auto a = static_cast<const Assignment*>(s);
    if (is_expr(a->target, EK::Name)) { return sequence_lines(expr(a->target), g); }
    std::string h = temp("ht", "the value of a 'fallback', before it is assigned");
    Lines lines = sequence_lines(h, g);
    lines.push_back(expr(a->target) + " := " + h);
    return lines;
  }

  // 'x := E fallback F' as statements -- what u_xtpl_safe_pipe() does, in
  // place, with no block and no call, and a chain in E a loop:
  //
  //   gt_0_0 := ErrorBlock({|e| Break(e)})
  //   Begin Sequence
  //     x := E
  //   Recover
  //     x := F
  //   End Sequence
  //   ErrorBlock(gt_0_0)
  Lines Emitter::sequence_lines(const std::string& target, const Guard* g)
  {
    std::string eb = temp("gt", "the error block a 'fallback' sets aside");
    Lines out{ eb + " := ErrorBlock({|e| Break(e)})", "Begin Sequence" };
    for (const std::string& l : init_lines(target, g->expr)) { out.push_back("  " + l); }
    out.push_back("Recover");
    for (const std::string& l : init_lines(target, g->fallback)) { out.push_back("  " + l); }
    append(out, { "End Sequence", "ErrorBlock(" + eb + ")" });
    return out;
  }

  // A block's closing line ('end with') dropped: the whole line, unless a
  // comment follows the keyword, which stays where it was.
  void Emitter::drop_closer(const Stmt* s, std::string_view word)
  {
    std::string raw = slice(s);
    std::size_t ce = code_end(raw);
    int at = s->from + static_cast<int>(last_from(std::string_view(raw).substr(0, ce), word));
    int end = line_end(s->from + static_cast<int>(ce));
    std::string comment = split_comment(text(at, end)).second;
    int from = line_start(at);
    if (!comment.empty())
    {
      edit(from, end, indent_at(at) + comment);
    }
    else
    {
      edit(from, after_break(end), "");
    }
  }

  // A raw line, for the preprocessor: as written, but a string holding '${'
  // interpolated and a renamed block local renamed.
  std::string Emitter::raw_text(const std::string& t)
  {
    std::string out;
    std::size_t i = 0;
    std::size_t n = t.size();
    while (i < n)
    {
      char c = t[i];
      if (t.compare(i, 2, "//") == 0 || t.compare(i, 2, "&&") == 0)
      {
        out += t.substr(i);
        break;
      }
      if (c == '"' || (c == '\'' && !is_separator(t, i)))
      {
        std::size_t close = t.find(c, i + 1);
        if (close == std::string::npos) { close = n - 1; }
        std::string str = t.substr(i, close - i + 1);
        out += str.find("${") != std::string::npos ? raw_string(str) : str;
        i = close + 1;
      }
      else if (is_alpha(static_cast<unsigned char>(c)))
      {
        std::size_t e = i + 1;
        while (e < n && is_w(static_cast<unsigned char>(t[e]))) { e++; }
        std::string word = t.substr(i, e - i);
        char before = out.empty() ? '\0' : out.back();
        std::size_t k = e;
        while (k < n && is_h(static_cast<unsigned char>(t[k]))) { k++; }
        bool call = k < n && t[k] == '(';
        auto sub = subst_.find(lc(word));
        out += sub != subst_.end() && before != ':' && before != '>' && !call ? sub->second : word;
        i = e;
      }
      else
      {
        out += c;
        i++;
      }
    }
    return out;
  }

  // A string with interpolation, from a raw line: parsed on its own, and
  // rendered with the renames in effect here. If it is not valid, as written.
  std::string Emitter::raw_string(const std::string& str)
  {
    Tree tree;
    Parser parser(str, {}, tree);
    int end = 0;
    Expr* e = parser.read(Form::Expr, 0, false, end);
    if (!e || end != static_cast<int>(str.size())) { return str; }
    Emitter sub(str);
    return sub.render_snippet(e, subst_);
  }

  std::string Emitter::render_snippet(const Expr* e, const Map& subst)
  {
    subst_ = subst;
    snippet_ = true;
    return expr(e);
  }

  // A whole statement replaced by lines; the comment goes back on the header
  // line of a block, on the last line otherwise. notes: a word per line, or
  // '' -- what a declaration was.
  void Emitter::replace(const Stmt* s, bool block, Lines lines, const Lines& notes)
  {
    std::string comment = split_comment(slice(s)).second;
    if (lines.empty()) { lines.push_back(""); }
    std::size_t at = block ? 0 : lines.size() - 1;
    for (std::size_t i = 0; i < notes.size() && i < lines.size(); i++)
    {
      if (!notes[i].empty() && !(i == at && !comment.empty())) { lines[i] += "  // " + notes[i]; }
    }
    if (!comment.empty())
    {
      std::string n = at < notes.size() ? notes[at] : "";
      std::string sp = before_comment(s->from, s->to);
      lines[at] += n.empty()                           ? sp + comment
                   : comment.compare(0, 2, "//") == 0 ? sp + "// " + n + " -- " + trim(comment.substr(2))
                                                       : sp + "// " + n + "  " + comment;
    }
    // The lines before a 'return' at the function's own level -- what it runs
    // first, a loop for its value -- go with the body's lines when the
    // 'return' is less deep than they are, as xtpl writes the last one.
    std::string ind = indent_at(s->from);
    auto p = paths_.find(s);
    if (s->kind == SK::ReturnStmt && lines.size() > 1 && p != paths_.end() && p->second.path.size() == 1
        && body_indent_.size() > ind.size())
    {
      std::string t = std::string(body_indent_.size() - ind.size(), ' ');
      for (std::size_t i = 0; i < lines.size(); i++)
      {
        if (i) { t += nl_ + (i + 1 < lines.size() ? body_indent_ : ind); }
        t += lines[i];
      }
      edit(s->from, s->to, t);
      return;
    }
    edit(s->from, s->to, join_at(s->from, lines));
  }

  // A block's header replaced by lines, up to the end of the line where the
  // expression last ends. The header's comment goes back on line at.
  void Emitter::header(const Stmt* s, const Expr* last, std::size_t at, Lines lines)
  {
    header_to(s, line_end(code_stop(last, src_)), at, std::move(lines));
  }

  void Emitter::header_to(const Stmt* s, int end, std::size_t at, Lines lines)
  {
    std::string comment = split_comment(text(s->from, end)).second;
    if (!comment.empty() && at < lines.size()) { lines[at] += before_comment(s->from, end) + comment; }
    edit(s->from, end, join_at(s->from, lines));
  }

  // Expression edits in a statement that keeps its shape; a comment inside a
  // rewritten expression moves to the end of its line.
  void Emitter::expressions(const std::vector<Expr*>& exprs)
  {
    for (ExprEdit& e : expr_edits(exprs))
    {
      edit(e.from, e.to, e.text);
      if (!e.comment.empty())
      {
        int at = line_end(e.to);
        edit(at, at, before_comment(e.from, e.to) + e.comment);
      }
    }
  }

  // Edits for the outermost expressions that hold something to lower.
  std::vector<Emitter::ExprEdit> Emitter::expr_edits(const std::vector<Expr*>& exprs)
  {
    std::vector<ExprEdit> out;
    for (const Expr* e : exprs)
    {
      if (!e || !contains_lowering(e)) { continue; }
      if (e->from >= 0)
      {
        std::string raw = slice(e);
        int to = e->from + static_cast<int>(code_end(raw));
        std::string comment = split_comment(raw.substr(0, static_cast<std::size_t>(to - e->from))).second;
        std::string t = expr(e);
        out.push_back(ExprEdit{ e->from, to, t, comment });
      }
      else
      {
        for (ExprEdit& x : expr_edits(subexprs(e))) { out.push_back(std::move(x)); }
      }
    }
    return out;
  }

  // The lowered lines of a statement, and whether they open a block.
  Emitter::Lowered Emitter::lower(const Stmt* s)
  {
    if (s->oneline) { return Lowered{ true, oneline_lines(s) }; }
    switch (s->kind)
    {
      case SK::Modified:
      {
        auto m = static_cast<const Modified*>(s);
        Lines inner = lower_inner(m->stmt);
        bool w = m->op == "while";
        Lines out{ (w ? "While " : "If ") + expr(m->cond) };
        for (const std::string& l : inner) { out.push_back("  " + l); }
        out.push_back(w ? "EndDo" : "EndIf");
        return Lowered{ true, out };
      }
      case SK::Assignment:
      {
        auto a = static_cast<const Assignment*>(s);
        if (decimal_stmt(s))
        {
          // 'fD += x' -> 'fD := DEC_ADD(fD, x)': a Decimal takes no operator.
          std::string t = expr(a->target);
          return Lowered{ false, { t + " := " + dec_function(chop(a->op)) + "(" + t + ", " + as_decimal(a->value) + ")" } };
        }
        if (is_expr(a->target, EK::HashIndex)) { return hash_set(a); }
        if (hash_read_whole(s))
        {
          // 'x := h{k}' -> 'h:Get(k, @x)': THashMap's own read, no call to
          // the runtime.
          auto h = static_cast<const HashIndex*>(a->value);
          std::string x = expr(a->target);
          // A name declared with a type is given no Nil as written: TL++
          // would not take it.
          if (GET_LEAVES_A_MISS && !plain_name(a->target)) { return Lowered{ false, { x + " := " + expr(a->value) } }; }
          Lines out;
          if (GET_LEAVES_A_MISS) { out.push_back(x + " := Nil"); }
          out.push_back(expr(h->base) + ":Get(" + expr(h->key) + ", @" + x + ")");
          return Lowered{ false, out };
        }
        // '?=': assign only when the target is Nil -- asked of ValType() but
        // for a name declared with no type.
        std::string t = expr(a->target);
        std::string nil = plain_name(a->target) ? t + " == Nil" : "ValType(" + t + ") == \"U\"";
        return Lowered{ true, { "If " + nil, "  " + t + " := " + expr(a->value), "EndIf" } };
      }
      case SK::Declaration:
      {
        // xtpl's order ('as T' first) swapped back, and the attributes dropped.
        auto d = static_cast<const Declaration*>(s);
        std::string kw = words(trim(split_comment(slice(s)).first)).at(0);
        Lines ds;
        for (const Declarator* v : d->declarators)
        {
          std::string x = v->name;
          for (const Expr* dim : v->dims) { x += "[" + expr(dim) + "]"; }
          if (v->init) { x += " := " + expr(v->init); }
          if (v->typespec_text) { x += " " + *v->typespec_text; }
          ds.push_back(x);
        }
        return Lowered{ false, { kw + " " + join(ds, ", ") } };
      }
      case SK::CallStmt:
      {
        // 'fD++', 'fD += x' as a statement: the assignment alone.
        auto a = static_cast<const AssignExpr*>(static_cast<const CallStmt*>(s)->call);
        std::string t = expr(a->target);
        std::string v = a->incdec.empty() ? as_decimal(a->value) : DEC_ONE;
        return Lowered{ false, { t + " := " + dec_function(chop(a->op)) + "(" + t + ", " + v + ")" } };
      }
      default:
        return Lowered{ false, {} };
    }
  }

  // An assignment with an operator to a Decimal: 'fD += x', 'fD++'.
  bool Emitter::decimal_stmt(const Stmt* s) const
  {
    if (s->kind == SK::Assignment)
    {
      auto a = static_cast<const Assignment*>(s);
      return compound(a->op) && is_expr(a->target, EK::Name) && dec_.decimal(a->target);
    }
    if (s->kind == SK::CallStmt && is_expr(static_cast<const CallStmt*>(s)->call, EK::AssignExpr))
    {
      auto a = static_cast<const AssignExpr*>(static_cast<const CallStmt*>(s)->call);
      return compound(a->op) && is_expr(a->target, EK::Name) && dec_.decimal(a->target);
    }
    return false;
  }

  // A statement inside a rewrite: lowered if it needs it, else its code as
  // written.
  Lines Emitter::lower_inner(const Stmt* s)
  {
    if (lowering(s)) { return lower(s).lines; }
    if (const Guard* g = guard_value(s)) { return guard_stmt(s, g); }
    if (const Expr* chain = fused_value(s))
    {
      Stream st = stream(chain, s->kind != SK::CallStmt);
      if (s->kind == SK::ReturnStmt)
      {
        Lines lines = return_exits(s);
        append(lines, st.lines);
        lines.push_back("return " + st.result);
        return lines;
      }
      if (s->kind == SK::Assignment)
      {
        st.lines.push_back(expr(static_cast<const Assignment*>(s)->target) + " := " + st.result);
      }
      return st.lines;
    }
    Lines out;
    if (s->kind == SK::ReturnStmt) { out = return_exits(s); }
    else if (s->kind == SK::ExitStmt || s->kind == SK::LoopStmt) { out = jump_exits(); }
    append(out, lines_of(with_edits(s, exprs_of(s))));
    return out;
  }

  // A one-line form as the block it is: its header as the block's, then each
  // statement of its bodies as lower_inner() has it -- a one-line form in
  // one as this --, with the block locals of its header renamed in them.
  Lines Emitter::oneline_lines(const Stmt* s)
  {
    Lines out;
    Map saved = subst_;
    const Renames* r = nullptr;
    if (auto it = renames_.find(s); it != renames_.end()) { r = &it->second; }
    auto body = [&](const Body& b, std::size_t i, bool loop)
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
      if (loop) { closers_.push_back(Closer{ "loop", {} }); }
      for (const Stmt* x : b)
      {
        for (const std::string& l : x->oneline ? oneline_lines(x) : lower_inner(x)) { out.push_back("  " + l); }
      }
      if (loop) { closers_.pop_back(); }
      subst_ = saved;
    };
    switch (s->kind)
    {
      case SK::IfStmt:
      {
        auto i = static_cast<const IfStmt*>(s);
        out.push_back("If " + expr(i->branches[0]->cond));
        body(i->branches[0]->body, 0, false);
        if (!i->otherwise.empty())
        {
          out.push_back("Else");
          body(i->otherwise, 1, false);
        }
        out.push_back("EndIf");
        break;
      }
      case SK::WhileStmt:
      {
        out.push_back("While " + expr(static_cast<const WhileStmt*>(s)->cond));
        body(static_cast<const WhileStmt*>(s)->body, 0, true);
        out.push_back("EndDo");
        break;
      }
      case SK::ForStmt:
      {
        // TL++'s own: a block local counter renamed, and declared.
        auto f = static_cast<const ForStmt*>(s);
        std::string x = f->var_local ? nm(s, f->var) : local(f->var);
        if (f->var_local) { hoist(x, "a block local"); }
        out.push_back("For " + x + " := " + expr(f->from_) + " To " + expr(f->to_)
                      + (f->step ? " Step " + expr(f->step) : ""));
        body(f->body, 0, true);
        out.push_back("Next");
        break;
      }
      case SK::ForTimesStmt:
      {
        auto f = static_cast<const ForTimesStmt*>(s);
        std::string ctr = gen("fi", "the counter of a 'for ... times'");
        if (is_numeric_literal(f->count))
        {
          out.push_back("For " + ctr + " := 1 To " + expr(f->count));
        }
        else
        {
          std::string n = gen("fn", "the count of a 'for ... times'");
          append(out, { n + " := " + expr(f->count), "For " + ctr + " := 1 To " + n });
        }
        body(f->body, 0, true);
        out.push_back("Next");
        break;
      }
      case SK::ForInStmt:
      {
        // As the block's: a count over a range, else the source read once.
        auto f = static_cast<const ForInStmt*>(s);
        std::string el = nm(s, f->elem);
        std::optional<std::string> ix;
        if (f->index) { ix = nm(s, *f->index); }
        hoist(el, "a block local");
        if (ix) { hoist(*ix, "a block local"); }
        Lines tail;
        if (is_expr(f->source, EK::Interval))
        {
          auto iv = static_cast<const Interval*>(f->source);
          std::string lo = range_end(iv->lo, "flo", "the low end of a range", out);
          std::string hi = range_end(iv->hi, "fhi", "the high end of a range", out);
          std::string fi = gen("fi", "the counter of a 'for ... in'");
          if (ix) { out.push_back(*ix + " := 0"); }
          append(out, { "For " + fi + " := " + lo + " To " + hi, "  " + el + " := " + fi });
          if (ix) { out.push_back("  " + *ix + "++"); }
        }
        else
        {
          std::string src = gen("fs", "the source of a 'for ... in'");
          std::string ctr = ix ? *ix : gen("fi", "the counter of a 'for ... in'");
          append(out, { src + " := " + expr(f->source), "For " + ctr + " := 1 To Len(" + src + ")",
                        "  " + el + " := " + src + "[" + ctr + "]" });
        }
        body(f->body, 0, true);
        out.push_back("Next");
        break;
      }
      default:
        break;
    }
    return out;
  }

  // ---- expressions ----------------------------------------------------------
  // An expression as TL++ code: built from its parts when it lowers itself,
  // else its source with the lowered expressions inside it replaced.
  std::string Emitter::expr(const Expr* e)
  {
    if (!e) { return ""; }
    if (lowered_decimal(e)) { return decimal_expr(e); }
    EK k = e->kind;
    if (k == EK::Lambda)
    {
      // Its own parameters are not the element of an enclosing stage.
      auto l = static_cast<const Lambda*>(e);
      Scoped block(in_block_, 1);
      Map s = subst_;
      Map f = field_;
      for (const std::string& p : l->params)
      {
        subst_.erase(lc(p));
        field_.erase(lc(p));
      }
      Lines body;
      for (const Expr* b : l->body) { body.push_back(expr(b)); }
      std::string t = "{|" + join(l->params, ", ") + "| " + join(body, ", ") + "}";
      subst_ = s;
      field_ = f;
      return t;
    }
    // ':x' / ':m(...)' inside 'with object': the innermost subject's.
    if ((k == EK::Member || k == EK::SafeMember) && is_expr(static_cast<const Member*>(e)->base, EK::SubjectRef))
    {
      return subjects_.back() + ":" + static_cast<const Member*>(e)->name;
    }
    if ((k == EK::MethodCall || k == EK::SafeCall) && is_expr(static_cast<const MethodCall*>(e)->base, EK::SubjectRef))
    {
      auto m = static_cast<const MethodCall*>(e);
      Lines args;
      for (const Expr* a : m->args) { args.push_back(part(a)); }
      return subjects_.back() + ":" + m->name + "(" + join(args, ", ") + ")";
    }
    if (k == EK::AssignExpr && is_expr(static_cast<const AssignExpr*>(e)->target, EK::HashIndex))
    {
      // 'h{k} := v' inside an expression: a call that sets and gives back the
      // value written.
      auto a = static_cast<const AssignExpr*>(e);
      auto t = static_cast<const HashIndex*>(a->target);
      std::string h = expr(t->base);
      std::string key = expr(t->key);
      std::string v = expr(a->value);
      std::string written;
      if (a->op == ":=" || a->op == "=")
      {
        written = "u_xtpl_hset(" + h + ", " + key + ", " + v + ")";
      }
      else if (is_expr(t->base, EK::Name) && name_or_literal(t->key))
      {
        written = "u_xtpl_hset(" + h + ", " + key + ", u_xtpl_hget(" + h + ", " + key + ") " + chop(a->op) + " (" + v + "))";
      }
      else
      {
        written = "Eval({|__h, __k, __v| u_xtpl_hset(__h, __k, u_xtpl_hget(__h, __k) " + chop(a->op) + " __v)}, "
                  + h + ", " + key + ", " + v + ")";
      }
      // 'h{k}++' gives the value before.
      return a->incdec == "post" ? "(" + written + ") " + (a->op == "+=" ? "-" : "+") + " 1" : written;
    }
    switch (k)
    {
      case EK::HashIndex:
      {
        auto h = static_cast<const HashIndex*>(e);
        return "u_xtpl_hget(" + expr(h->base) + ", " + expr(h->key) + ")";
      }
      case EK::HashLit:
      case EK::JsonLit:
      {
        // TL++'s own JSON object: as written, what is in it lowered.
        if (native_json(e)) { return with_edits(e, subexprs(e)); }
        const std::vector<KeyValue*>& pairs = k == EK::HashLit ? static_cast<const HashLit*>(e)->pairs
                                                               : static_cast<const JsonLit*>(e)->pairs;
        if (pairs.empty()) { return k == EK::HashLit ? "THashMap():New()" : "JsonObject():New()"; }
        Lines ps;
        for (const KeyValue* kv : pairs) { ps.push_back("{" + expr(kv->key) + ", " + expr(kv->value) + "}"); }
        return std::string(k == EK::HashLit ? "u_xtpl_hnew({" : "u_xtpl_jnew({") + join(ps, ", ") + "})";
      }
      case EK::Guard:
      {
        auto g = static_cast<const Guard*>(e);
        return "u_xtpl_safe_pipe({|| " + expr(g->expr) + "}, {|| " + expr(g->fallback) + "})";
      }
      case EK::Interp:
        return interpolated(static_cast<const Interp*>(e));
      case EK::SafeCall:
      {
        if (temps_ok()) { return safe_chain(e); }
        auto m = static_cast<const MethodCall*>(e);
        Lines args;
        for (const Expr* a : m->args) { args.push_back(part(a)); }
        return safe(m->base, ":" + m->name + "(" + join(args, ", ") + ")");
      }
      case EK::SafeMember:
      {
        if (temps_ok()) { return safe_chain(e); }
        auto m = static_cast<const Member*>(e);
        return safe(m->base, ":" + m->name);
      }
      default:
        break;
    }
    if (k == EK::Binary)
    {
      auto b = static_cast<const Binary*>(e);
      if (b->op == "in" || b->op == "has" || b->op == "%%" || b->op == "?:")
      {
        std::string l = expr(b->left);
        if (b->op == "in")
        {
          // 'x in lo..hi' is a range test, with x read once.
          if (is_expr(b->right, EK::Interval))
          {
            auto r = static_cast<const Interval*>(b->right);
            if (name_or_literal(b->left))
            {
              return "(" + l + " >= " + expr(r->lo) + " .And. " + l + " <= " + expr(r->hi) + ")";
            }
            if (temps_ok())
            {
              std::string t = temp("fbv", HELD);
              return "((" + t + " := " + l + ") >= " + expr(r->lo) + " .And. " + t + " <= " + expr(r->hi) + ")";
            }
            std::string lo = expr(r->lo);
            std::string hi = expr(r->hi);
            return "Eval({|fbv_0_0| fbv_0_0 >= " + lo + " .And. fbv_0_0 <= " + hi + "}, " + l + ")";
          }
          return "u_xtpl_in(" + l + ", " + expr(b->right) + ")";
        }
        if (b->op == "has") { return "u_xtpl_hhas(" + l + ", " + expr(b->right) + ")"; }
        if (b->op == "%%")
        {
          std::string ll = name_or_literal(b->left) ? l : "(" + l + ")";
          std::string rr = name_or_literal(b->right) ? expr(b->right) : "(" + expr(b->right) + ")";
          return "((" + ll + " % " + rr + ") == 0)";
        }
        // A literal is Nil or never is: the side it picks, as it is.
        if (is_literal_kind(b->left))
        {
          if (!is_nil(b->left)) { return l; }
          std::string r = expr(b->right);
          return name_or_literal(b->right) ? r : "(" + r + ")";
        }
        // The right side only when the left is Nil -- If() evaluates only the
        // branch it takes -- and the left read once: a name as it is, the rest
        // held in a temp.
        if (plain_name(b->left)) { return "If(" + l + " != Nil, " + l + ", " + expr(b->right) + ")"; }
        if (is_expr(b->left, EK::Name)) { return "If(" + not_nil(l) + ", " + l + ", " + expr(b->right) + ")"; }
        if (temps_ok())
        {
          std::string t = temp("et", "the left side of a '?:', evaluated once");
          return "If(" + not_nil(t + " := " + l) + ", " + t + ", " + expr(b->right) + ")";
        }
        return "u_xtpl_elvis(" + l + ", {|| " + expr(b->right) + "})";
      }
    }
    if (k == EK::Name)
    {
      auto it = subst_.find(lc(name_of(e)));
      return it != subst_.end() ? it->second : with_edits(e, {});
    }
    if (k == EK::Member)
    {
      auto m = static_cast<const Member*>(e);
      if (is_expr(m->base, EK::Name))
      {
        auto it = field_.find(lc(name_of(m->base)));
        if (it != field_.end()) { return it->second + m->name; }
      }
      return with_edits(e, subexprs(e));
    }
    if (k == EK::Pipeline)
    {
      auto p = static_cast<const Pipeline*>(e);
      return calls(expr(p->source), p->stages);
    }
    if (k == EK::Call)
    {
      // A verb: the first argument is the data, any after it may be a bare
      // function name standing for a block.
      auto c = static_cast<const Call*>(e);
      if (!lowers_itself(c)) { return with_edits(e, subexprs(e)); }
      Lines args;
      for (std::size_t i = 0; i < c->args.size(); i++)
      {
        args.push_back(i == 0 ? part(c->args[i]) : block_arg(c->name, c->args[i]));
      }
      return call_name(c->name) + "(" + join(args, ", ") + ")";
    }
    if (k == EK::CodeBlock)
    {
      Scoped block(in_block_, 1);
      return with_edits(e, subexprs(e));
    }
    // '12'345'678': TL++ has no digit separators.
    if (is_numeric_literal(e))
    {
      std::string t = static_cast<const Literal*>(e)->text;
      t.erase(std::remove(t.begin(), t.end(), '\''), t.end());
      return t;
    }
    return with_edits(e, subexprs(e));
  }

  // An expression that is rewritten itself, not just for what it holds.
  bool Emitter::lowers_itself(const Expr* e) const
  {
    if (lowered_decimal(e)) { return true; }
    switch (e->kind)
    {
      case EK::Index: case EK::SelfRef: case EK::SubjectRef: case EK::Interval: case EK::AliasField:
      case EK::InAlias: case EK::ExprList: case EK::Macro: case EK::Ref: case EK::Omitted: case EK::UserTrans:
        return false;
      case EK::Lambda: case EK::Pipeline: case EK::HashIndex: case EK::HashLit: case EK::Guard: case EK::Interp:
      case EK::SafeMember: case EK::SafeCall:
        return true;
      case EK::JsonLit:
        return !native_json(e);
      case EK::Call:
        return is_runtime_verb(static_cast<const Call*>(e)->name);
      case EK::Name:
        return subst_.count(lc(name_of(e))) > 0;
      case EK::Member:
      {
        const Expr* b = static_cast<const Member*>(e)->base;
        return (is_expr(b, EK::Name) && field_.count(lc(name_of(b)))) || is_expr(b, EK::SubjectRef);
      }
      case EK::MethodCall:
        return is_expr(static_cast<const MethodCall*>(e)->base, EK::SubjectRef);
      case EK::AssignExpr:
        return is_expr(static_cast<const AssignExpr*>(e)->target, EK::HashIndex);
      case EK::Literal: case EK::ArrayLit: case EK::CodeBlock:
      {
        auto l = static_cast<const Literal*>(e);
        return l->type == "Numeric" && l->text.find('\'') != std::string::npos;
      }
      case EK::Binary:
      {
        const std::string& op = static_cast<const Binary*>(e)->op;
        return op == "in" || op == "has" || op == "%%" || op == "?:";
      }
    }
    return false;
  }

  // A JSON object TL++ takes as written: in TL++ (not a .prw: "Invalid use of
  // Json Syntax in ADVPL source file"), with a pair at least ('{ : }' is
  // refused), each key a string in double quotes ('{ cKey : 1 }' is
  // refused). It makes a JsonObject (all tried on 24.3.1.9).
  bool Emitter::native_json(const Expr* e) const
  {
    if (advpl_ || !is_expr(e, EK::JsonLit)) { return false; }
    const std::vector<KeyValue*>& pairs = static_cast<const JsonLit*>(e)->pairs;
    if (pairs.empty()) { return false; }
    for (const KeyValue* kv : pairs)
    {
      if (!is_expr(kv->key, EK::Literal)) { return false; }
      auto l = static_cast<const Literal*>(kv->key);
      if (l->type != "Character" || l->text.empty() || l->text[0] != '"') { return false; }
    }
    return true;
  }

  // ---- Decimals -------------------------------------------------------------
  // What is rewritten for a Decimal: one that goes into a Numeric, a literal
  // that goes into one, an operator with one on a side -- a comparison only
  // when a literal is on the other --, Round(), NoRound() or Empty() of one,
  // an assignment with an operator to one.
  bool Emitter::lowered_decimal(const Expr* e) const
  {
    if (!e || advpl_) { return false; }
    if (into_numeric_.count(e) && e != unwrapped_ && dec_.decimal(e)) { return true; }
    if (into_decimal_.count(e) && dec_.constant(e) && !dec_.decimal(e)) { return true; }
    switch (e->kind)
    {
      case EK::Binary:
      {
        auto b = static_cast<const Binary*>(e);
        if (arithmetic(b->op)) { return dec_.decimal(e); }
        if (!comparison(b->op)) { return false; }
        bool l = dec_.decimal(b->left);
        bool r = dec_.decimal(b->right);
        return (l && !r && dec_.constant(b->right)) || (r && !l && dec_.constant(b->left));
      }
      case EK::Call:
      {
        auto c = static_cast<const Call*>(e);
        std::string n = lc(c->name);
        if (n == "round" || n == "noround") { return c->args.size() == 2 && dec_.decimal(c->args[0]); }
        return n == "empty" && c->args.size() == 1 && dec_.decimal(c->args[0]);
      }
      case EK::AssignExpr:
      {
        auto a = static_cast<const AssignExpr*>(e);
        return compound(a->op) && is_expr(a->target, EK::Name) && dec_.decimal(a->target);
      }
      default:
        return false;
    }
  }

  // What is lowered_decimal(), written with the DEC_ functions: 'nX := fA'
  // -> 'nX := DEC_TO_DBL(fA)' -- a Numeric takes a Decimal, and holds a
  // Decimal then --, 'fA + 1' -> 'DEC_ADD(fA, DEC_CREATE("1", 1, 0))',
  // 'fA ** 2' -> 'DEC_POW(fA, DEC_CREATE("2", 1, 0))', 'fA > 0' -> 'fA >
  // DEC_CREATE("0", 1, 0)', 'Round(fA, 2)' -> 'DEC_RESCALE(fA, 2, 0)' (half
  // away from zero), 'NoRound(fA, 2)' -> 'DEC_RESCALE(fA, 2, 2)' (cut),
  // 'Empty(fA)' -> '(fA == DEC_CREATE("0", 1, 0))' (Empty() of a Decimal
  // stops the thread: "Empty: unknown variable type"), '(fA += x)' ->
  // '(fA := DEC_ADD(fA, x))'; 'fA++' gives the value before.
  std::string Emitter::decimal_expr(const Expr* e)
  {
    if (into_numeric_.count(e) && e != unwrapped_ && dec_.decimal(e))
    {
      const Expr* was = unwrapped_;
      unwrapped_ = e;
      std::string inner = expr(e);
      unwrapped_ = was;
      return "DEC_TO_DBL(" + inner + ")";
    }
    if (into_decimal_.count(e) && dec_.constant(e) && !dec_.decimal(e)) { return as_decimal(e); }
    if (e->kind == EK::Binary)
    {
      auto b = static_cast<const Binary*>(e);
      if (arithmetic(b->op))
      {
        return dec_function(b->op) + "(" + as_decimal(b->left) + ", " + as_decimal(b->right) + ")";
      }
      auto side = [&](const Expr* x) { return dec_.decimal(x) ? expr(x) : as_decimal(x); };
      return side(b->left) + " " + b->op + " " + side(b->right);
    }
    if (e->kind == EK::Call)
    {
      auto c = static_cast<const Call*>(e);
      std::string n = lc(c->name);
      if (n == "empty") { return "(" + expr(c->args[0]) + " == DEC_CREATE(\"0\", 1, 0))"; }
      return "DEC_RESCALE(" + expr(c->args[0]) + ", " + expr(c->args[1]) + (n == "round" ? ", 0)" : ", 2)");
    }
    auto a = static_cast<const AssignExpr*>(e);
    std::string t = expr(a->target);
    std::string v = a->incdec.empty() ? as_decimal(a->value) : DEC_ONE;
    std::string inner = t + " := " + dec_function(chop(a->op)) + "(" + t + ", " + v + ")";
    if (a->incdec == "post") { return dec_function(a->op == "+=" ? "-" : "+") + "((" + inner + "), " + DEC_ONE + ")"; }
    return "(" + inner + ")";
  }

  // An expression as a Decimal's operand: a Decimal as it is, a literal made
  // one from its text, arithmetic of literals with the DEC_ functions,
  // anything else as it is -- it has to hold a Decimal when it runs.
  std::string Emitter::as_decimal(const Expr* e)
  {
    if (!e) { return ""; }
    if (dec_.decimal(e)) { return expr(e); }
    if (number_literal(e)) { return dec_create(static_cast<const Literal*>(e)->text); }
    if (e->kind == EK::Binary && dec_.constant(e))
    {
      auto b = static_cast<const Binary*>(e);
      if (b->op == "neg") { return "-" + as_decimal(b->right); }
      return dec_function(b->op) + "(" + as_decimal(b->left) + ", " + as_decimal(b->right) + ")";
    }
    return expr(e);
  }

  bool Emitter::contains_lowering(const Expr* e) const
  {
    if (lowers_itself(e)) { return true; }
    for (const Expr* x : subexprs(e))
    {
      if (contains_lowering(x)) { return true; }
    }
    return false;
  }

  // '"total ${n} items"' -> '("total " + cValToChar(n) + " items")', in the
  // string's own quote; one part alone needs no parentheses.
  std::string Emitter::interpolated(const Interp* i)
  {
    std::string q = i->text.substr(0, 1);
    Lines parts;
    for (const Part& p : i->parts)
    {
      if (auto x = std::get_if<Expr*>(&p))
      {
        parts.push_back("cValToChar(" + expr(*x) + ")");
      }
      else if (!std::get<std::string>(p).empty())
      {
        parts.push_back(q + std::get<std::string>(p) + q);
      }
    }
    return parts.size() == 1 ? parts[0] : "(" + join(parts, " + ") + ")";
  }

  // 'o?.x' / 'o?.M(...)': Nil when the base is Nil -- a chain of them one
  // test, each value it goes on from read once:
  // 'o?.a?.b' -> 'If(o != Nil .And. ValType(fbv_0_0 := o:a) != "U", fbv_0_0:b,
  // Nil)'.
  std::string Emitter::safe_chain(const Expr* e)
  {
    Lines conds;
    std::string value;
    safe_steps(e, conds, value);
    return "If(" + join(conds, " .And. ") + ", " + value + ", Nil)";
  }

  namespace
  {
    // A '?.' that is one: on ':x' inside 'with object' it is a plain ':'.
    bool is_safe_step(const Expr* e)
    {
      return (is_expr(e, EK::SafeMember) && !is_expr(static_cast<const Member*>(e)->base, EK::SubjectRef))
             || (is_expr(e, EK::SafeCall) && !is_expr(static_cast<const MethodCall*>(e)->base, EK::SubjectRef));
    }
  }

  void Emitter::safe_steps(const Expr* e, Lines& conds, std::string& value)
  {
    const Expr* base = e->kind == EK::SafeCall ? static_cast<const MethodCall*>(e)->base
                                               : static_cast<const Member*>(e)->base;
    std::string from;
    if (is_safe_step(base))
    {
      std::string v;
      safe_steps(base, conds, v);
      from = temp("fbv", HELD);
      conds.push_back(not_nil(from + " := " + v));
    }
    else if (is_expr(base, EK::Name))
    {
      from = expr(base);
      conds.push_back(plain_name(base) ? from + " != Nil" : not_nil(from));
    }
    else
    {
      std::string b = expr(base);
      from = temp("fbv", HELD);
      conds.push_back(not_nil(from + " := " + b));
    }
    if (e->kind == EK::SafeCall)
    {
      auto m = static_cast<const MethodCall*>(e);
      Lines args;
      for (const Expr* a : m->args) { args.push_back(part(a)); }
      value = from + ":" + m->name + "(" + join(args, ", ") + ")";
    }
    else
    {
      value = from + ":" + static_cast<const Member*>(e)->name;
    }
  }

  // The same where no temp can be: a block binds the base.
  std::string Emitter::safe(const Expr* base, const std::string& tail)
  {
    std::string b = expr(base);
    if (is_expr(base, EK::Name))
    {
      return "If(" + (plain_name(base) ? b + " != Nil" : not_nil(b)) + ", " + b + tail + ", Nil)";
    }
    return "Eval({|fbv_0_0| If(fbv_0_0 != Nil, fbv_0_0" + tail + ", Nil)}, " + b + ")";
  }

  // 'h{k} := v' -> 'h:Set(k, v)'. One that also reads holds anything but a
  // name (and, for the key, a literal) first, to be evaluated once.
  Emitter::Lowered Emitter::hash_set(const Assignment* a)
  {
    auto t = static_cast<const HashIndex*>(a->target);
    std::string h = expr(t->base);
    std::string key = expr(t->key);
    Lines pre;
    bool plain = a->op == ":=" || a->op == "=";
    if (!plain)
    {
      if (!is_expr(t->base, EK::Name))
      {
        std::string n = gen("fhd", "a hash that is read and written back");
        pre.push_back(n + " := " + h);
        h = n;
      }
      if (!name_or_literal(t->key))
      {
        std::string n = gen("fky", "a key that is read and written back");
        pre.push_back(n + " := " + key);
        key = n;
      }
    }
    std::string v = expr(a->value);
    Lines out = pre;
    if (plain)
    {
      out.push_back(h + ":Set(" + key + ", " + v + ")");
      return Lowered{ false, out };
    }
    if (a->op == "?=")
    {
      append(out, { "If u_xtpl_hget(" + h + ", " + key + ") == Nil", "  " + h + ":Set(" + key + ", " + v + ")", "EndIf" });
      return Lowered{ pre.empty(), out };
    }
    out.push_back(h + ":Set(" + key + ", u_xtpl_hget(" + h + ", " + key + ") " + chop(a->op) + " (" + v + "))");
    return Lowered{ false, out };
  }

  // An argument of a verb that takes a block: a bare function name becomes
  // the block that calls it.
  std::string Emitter::block_arg(const std::string& verb, const Expr* e)
  {
    return is_function_name(lc(verb), e) ? "{|__it| " + name_of(e) + "(__it)}" : part(e);
  }

  std::string Emitter::part(const Expr* e)
  {
    return !e || e->kind == EK::Omitted ? "" : expr(e);
  }

  // A node's source, with the edits for the given expressions inside it, up
  // to where its code ends and without the comments inside.
  template <class N> std::string Emitter::with_edits(const N* node, const std::vector<Expr*>& exprs)
  {
    if (node->from < 0) { throw std::runtime_error("internal: no source span for a node"); }
    std::string raw = slice(node);
    std::vector<ExprEdit> es = expr_edits(exprs);
    std::stable_sort(es.begin(), es.end(), [](const ExprEdit& a, const ExprEdit& b) { return a.from > b.from; });
    for (const ExprEdit& x : es)
    {
      raw = raw.substr(0, static_cast<std::size_t>(x.from - node->from)) + x.text
            + raw.substr(static_cast<std::size_t>(x.to - node->from));
    }
    return trim(split_comment(std::string_view(raw).substr(0, code_end(raw))).first);
  }

  template std::string Emitter::with_edits<Stmt>(const Stmt*, const std::vector<Expr*>&);
  template std::string Emitter::with_edits<Expr>(const Expr*, const std::vector<Expr*>&);
}
