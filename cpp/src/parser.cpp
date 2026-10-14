// xc -- a source read into a tree (see parser.h).
//
// Each routine reads one form of the Raku grammar, whose rule is quoted
// above it, and leaves the cursor after it -- or, when the form is not
// there, gives null and leaves the cursor where it was.

#include "parser.h"

#include <algorithm>
#include <unordered_set>

#include "chars.h"

namespace xc
{
  namespace
  {
    // The words a statement starts with, which a value cannot (the grammar's
    // 'stmtword').
    const std::unordered_set<std::string> STMT_KEYWORDS =
    {
      "return", "local", "private", "public", "static", "if", "elseif", "else", "endif", "while",
      "enddo", "for", "next", "exit", "loop", "do", "case", "endcase", "otherwise", "begin",
      "recover", "end", "namespace", "using",
    };

    // What a line holds that sees() looks for.
    enum : unsigned char { L_EQ = 1, L_BAR = 2, L_DIV = 4, L_SEMI = 8 };

    // The levels of the operators, loosest first (see climb).
    enum { L_ELVIS = 1, L_OR, L_AND, L_NOT, L_CMP, L_RANGE, L_ADD, L_MUL, L_POW };

    // A trailer's kind.
    enum TK { T_TRANS, T_HASH, T_SCALL, T_SMEM, T_METHOD, T_MEMBER, T_INDEX, T_INALS, T_FIELD };
  }

  // What follows a value -- ':m()', '[i]', '->f', ... --, read before the
  // node it makes: a base, then each trailer around it.
  struct Parser::Trailer
  {
    int kind = 0;
    int end = 0;                 // where it ends, its whitespace taken
    std::string name;            // a member's, a method's, a field's; a translation's text
    Expr* x = nullptr;           // a hash key, an alias's expression, a field's macro
    std::vector<Expr*> list;     // the arguments, the indices
  };

  Parser::Parser(std::string_view src, std::unordered_map<int, int> trans, Tree& tree,
                 std::unordered_map<int, UserCmd> cmd)
    : src_(src), trans_(std::move(trans)), cmd_(std::move(cmd)), tree_(tree), n_(static_cast<int>(src.size())),
      user_on_(!trans_.empty() || !cmd_.empty())
  {
    // The lines as Raku's .lines splits them -- at "\n", "\r\n" and "\r" --
    // for the line a node is on.
    rows_.push_back(0);
    for (int i = 0; i < n_; i++)
    {
      int ch = c(i);
      if (ch == 13 && c(i + 1) == 10)
      {
        i++;
        rows_.push_back(i + 1);
      }
      else if (ch == 10 || ch == 13)
      {
        rows_.push_back(i + 1);
      }
    }
    if (rows_.back() != n_)
    {
      rows_.push_back(n_);       // the end of the text: a row of its own
    }

    // The lines, and what each holds that sees() looks for. A "\r\n" is one
    // line end.
    ls_.push_back(0);
    unsigned char f = 0;
    for (int i = 0; i < n_; i++)
    {
      int ch = c(i);
      if (ch >= 10 && ch <= 13)
      {
        le_.push_back(i);
        lf_.push_back(f);
        if (ch == 13 && c(i + 1) == 10)
        {
          i++;
        }
        ls_.push_back(i + 1);
        f = 0;
      }
      else if (ch == '=') { f |= L_EQ; }
      else if (ch == '|') { f |= L_BAR; }
      else if (ch == '/') { f |= L_DIV; }
      else if (ch == ';') { f |= L_SEMI; }
    }
    le_.push_back(n_);
    lf_.push_back(f);
    lq_.assign(ls_.size(), -2);
  }

  Expr* Parser::read(Form form, int at, bool in_with, int& end)
  {
    in_with_ = in_with;
    in_block_ = in_dq_ = in_sq_ = in_exp_ = 0;
    p_ = at;
    Expr* node = nullptr;
    switch (form)
    {
      case Form::Value:     node = value(); break;
      case Form::GuardExpr: node = guardexpr(); break;
      case Form::Cond:      node = cond(); break;
      case Form::Expr:      node = expr(); break;
      case Form::LValue:    node = lvalue(); break;
      case Form::CallSt:    node = callst(); break;
      case Form::PipeSt:    node = pipest(); break;
    }
    end = p_;
    return node;
  }

  // ---- nodes, as the Raku actions make them ---------------------------------
  // A folded operator spans from its left operand to its right one.
  Expr* Parser::joined(Binary* b)
  {
    if (b->left && b->left->from >= 0 && b->right->to >= 0)
    {
      b->from = b->left->from;
      b->to = b->right->to;
    }
    return b;
  }

  Expr* Parser::interval(Expr* lo, Expr* hi)
  {
    auto i = make<Interval>();
    i->lo = lo;
    i->hi = hi;
    if (lo->from >= 0 && hi->to >= 0)
    {
      i->from = lo->from;
      i->to = hi->to;
    }
    return i;
  }

  // 'n++' is '+= 1' that gives the value before; '++n', the one after.
  Expr* Parser::incdec(Expr* target, bool plus, const char* where)
  {
    auto one = make<Literal>();
    one->type = "Numeric";
    one->text = "1";
    auto a = make<AssignExpr>();
    a->target = target;
    a->op = plus ? "+=" : "-=";
    a->value = one;
    a->incdec = where;
    return a;
  }

  Expr* Parser::assign_expr(Expr* target, const std::string& op, Expr* value)
  {
    auto a = make<AssignExpr>();
    a->target = target;
    a->op = op;
    a->value = value;
    return a;
  }

  Expr* Parser::applied(Expr* b, const Trailer& t)
  {
    switch (t.kind)
    {
      case T_MEMBER:
      {
        auto m = make<Member>();
        m->base = b;
        m->name = t.name;
        return m;
      }
      case T_METHOD:
      {
        auto m = make<MethodCall>();
        m->base = b;
        m->name = t.name;
        m->args = t.list;
        return m;
      }
      case T_INDEX:
      {
        auto x = make<Index>();
        x->base = b;
        x->indices = t.list;
        return x;
      }
      case T_FIELD:
      {
        auto a = make<AliasField>();
        a->base = b;
        a->field = t.name;
        a->macro = t.x;
        return a;
      }
      case T_HASH:
      {
        auto h = make<HashIndex>();
        h->base = b;
        h->key = t.x;
        return h;
      }
      case T_SMEM:
      {
        auto m = make<SafeMember>();
        m->base = b;
        m->name = t.name;
        return m;
      }
      case T_SCALL:
      {
        auto m = make<SafeCall>();
        m->base = b;
        m->name = t.name;
        m->args = t.list;
        return m;
      }
      case T_INALS:
      {
        auto a = make<InAlias>();
        a->base = b;
        a->expr = t.x;
        return a;
      }
      default:
      {
        auto u = make<UserTrans>();
        u->base = b;
        u->text = t.name;
        return u;
      }
    }
  }

  // A base and the trailers after it, each step spanning from the start of
  // the whole to the end of its trailer (outer: the caller spans a base with
  // no trailer itself).
  Expr* Parser::trailed(Expr* base, int bf, int bt, const std::vector<Trailer>& trailers, int from, bool outer)
  {
    if (base->from < 0 && !(outer && trailers.empty()))
    {
      span(base, bf, bt);
    }
    Expr* e = base;
    for (const Trailer& t : trailers)
    {
      e = applied(e, t);
      e->from = from;
      e->to = t.end;
    }
    return e;
  }

  // ---- whitespace -----------------------------------------------------------
  // <.ws>: blanks, comments, and a ';' that carries the line on. Not between
  // two word characters: there it does not match, and what wants it fails.
  bool Parser::ws()
  {
    int p = p_;
    int ch = c(p);
    if (!(ch == ' ' || ch == '\t' || ch == ';' || ch == '/' || ch == '&' || is_h(ch)))
    {
      return !(p > 0 && is_w(ch) && is_w(c(p - 1)));
    }
    for (;;)
    {
      ch = c(p);
      if (is_h(ch))
      {
        p++;
      }
      else if (ch == ';')
      {
        int q = linecont(p);
        if (q < 0)
        {
          break;
        }
        p = q;
      }
      else if ((ch == '/' || ch == '&') && c(p + 1) == ch)
      {
        p = line_end(p + 2);
      }
      else if (ch == '/' && c(p + 1) == '*')
      {
        int q = block_end(p);
        if (q < 0)
        {
          break;
        }
        p = q;
      }
      else
      {
        break;
      }
    }
    p_ = p;
    return true;
  }

  // '\N*' from p: where the line ends.
  int Parser::line_end(int p) { return le_[line_of(p)]; }

  // The line p is on: the one found last, the next, or a search.
  int Parser::line_of(int p)
  {
    int k = lk_;
    if (ls_[k] <= p && p <= le_[k])
    {
      return k;
    }
    k++;
    if (k < static_cast<int>(ls_.size()) && ls_[k] <= p && p <= le_[k])
    {
      lk_ = k;
      return k;
    }
    k = static_cast<int>(std::upper_bound(ls_.begin(), ls_.end(), p) - ls_.begin()) - 1;
    lk_ = std::max(k, 0);
    return lk_;
  }

  // '/*' .*? '*/' at p: where it ends, or -1.
  int Parser::block_end(int p) const
  {
    std::size_t close = src_.find("*/", static_cast<std::size_t>(p) + 2);
    return close == std::string_view::npos ? -1 : static_cast<int>(close) + 2;
  }

  // ';' \h* [ <linecomment> || <blockcomment> ]? \h* \v at p: where it ends,
  // or -1.
  int Parser::linecont(int p)
  {
    int q = p + 1;
    while (is_h(c(q)))
    {
      q++;
    }
    int ch = c(q);
    if ((ch == '/' || ch == '&') && c(q + 1) == ch)
    {
      q = line_end(q + 2);
    }
    else if (ch == '/' && c(q + 1) == '*')
    {
      int e = block_end(q);
      if (e >= 0)
      {
        q = e;
      }
    }
    while (is_h(c(q)))
    {
      q++;
    }
    if (!is_v(c(q)))
    {
      return -1;
    }
    return c(q) == 13 && c(q + 1) == 10 ? q + 2 : q + 1;
  }

  // ---- small pieces ---------------------------------------------------------
  // Where a name starting at p ends ('<[A..Za..z_]> \w*'), or -1.
  int Parser::name_end(int p) const
  {
    if (!is_alpha(c(p)))
    {
      return -1;
    }
    int q = p + 1;
    while (is_w(c(q)))
    {
      q++;
    }
    return q;
  }

  // Whether the text at p is word (lower case), letter case aside.
  bool Parser::iword_at(int p, std::string_view word) const
  {
    for (std::size_t i = 0; i < word.size(); i++)
    {
      if (lower(c(p + static_cast<int>(i))) != static_cast<unsigned char>(word[i]))
      {
        return false;
      }
    }
    return true;
  }

  bool Parser::stmtword_at(int p) const
  {
    int e = name_end(p);
    return e >= 0 && STMT_KEYWORDS.count(lc(src_.substr(p, e - p)));
  }

  // <sees>: the rest of the line, and the lines a ';' carries it on to, as
  // the grammar's look-ahead took it, given to ahead(). Without a '=' (a '|'
  // for a chain) nor a '/' in its lines, ahead() would say no before reading
  // it: so does this.
  bool Parser::sees(Ahead what, bool item)
  {
    int p = p_;
    int k = line_of(p);
    unsigned char mark = (what == Ahead::Pipe ? L_BAR : L_EQ) | L_DIV;
    bool any = false;
    for (;;)
    {
      int e = le_[k];
      unsigned char f = lf_[k];
      if (f & mark)
      {
        any = true;
      }
      if (e < n_ && (f & L_SEMI) && continued(p, e))
      {
        k++;
        p = ls_[k];
        continue;
      }
      if (!any)
      {
        return false;
      }
      return ahead(src_.substr(p_, e - p_), what, item);
    }
  }

  // Whether a ';' in [p, e) has only blanks, and a '//' or '&&' comment,
  // after it.
  bool Parser::continued(int p, int e)
  {
    int k = line_of(p);
    if (lq_[k] == -2)
    {
      lq_[k] = last_semi(ls_[k], e);
    }
    return lq_[k] >= p;
  }

  // The last ';' in [p, e) with only blanks, and a '//' or '&&' comment,
  // after it -- or -1.
  int Parser::last_semi(int p, int e) const
  {
    int last = -1;
    for (int k = p; k < e; k++)
    {
      if (c(k) != ';')
      {
        continue;
      }
      int q = k + 1;
      while (q < e && is_h(c(q)))
      {
        q++;
      }
      int ch = c(q);
      if (q == e || ((ch == '/' || ch == '&') && c(q + 1) == ch))
      {
        last = k;
      }
    }
    return last;
  }

  // <opnext>: an operator's first character, or 'in' or 'has' as a word.
  bool Parser::opnext() const
  {
    int ch = c(p_);
    switch (ch)
    {
      case '*': case '/': case '%': case '+': case '-': case '.': case '<': case '>':
      case '=': case '!': case '$': case '#': case '?': case '|': case '^':
        return true;
      default:
        break;
    }
    int d = lower(c(p_ + 1));
    if (lower(ch) == 'i' && d == 'n' && !is_w(c(p_ + 2)))
    {
      return true;
    }
    return lower(ch) == 'h' && d == 'a' && lower(c(p_ + 2)) == 's' && !is_w(c(p_ + 3));
  }

  // ---- values, conditions, guards -------------------------------------------
  // [ <chained> || <guardexpr> ]: a declaration's or an assignment's value.
  Expr* Parser::value()
  {
    int start = p_;
    if (Expr* x = chained())
    {
      return x;
    }
    p_ = start;
    return guardexpr();
  }

  // token chained { <.sees('bind')> <assignment> }
  Expr* Parser::chained()
  {
    int start = p_;
    if (!sees(Ahead::Bind, false))
    {
      return nullptr;
    }
    Assign a;
    if (!assignment(a))
    {
      return back(start);
    }
    return span(assign_expr(a.target, a.op, a.value), start, p_);
  }

  // token passign { <.sees('bind item')> <assignment> }
  Expr* Parser::passign()
  {
    int start = p_;
    if (!sees(Ahead::Bind, true))
    {
      return nullptr;
    }
    Assign a;
    if (!assignment(a))
    {
      return back(start);
    }
    return span(assign_expr(a.target, a.op, a.value), start, p_);
  }

  // token cond { [ <.sees('bind item')> <assignment> ] || <expr> }
  Expr* Parser::cond()
  {
    int start = p_;
    if (sees(Ahead::Bind, true))
    {
      Assign a;
      if (assignment(a))
      {
        return span(assign_expr(a.target, a.op, a.value), start, p_);
      }
      p_ = start;
    }
    return expr();
  }

  // token listitem { <passign> || <guardexpr> }
  Expr* Parser::listitem()
  {
    int start = p_;
    if (Expr* a = passign())
    {
      return a;
    }
    p_ = start;
    return guardexpr();
  }

  // rule guardexpr { <guarded> [ <?[fF]> <!{ in a block }> <fbkw> <fallback> ]? }
  Expr* Parser::guardexpr()
  {
    int start = p_;
    Expr* g = expr();
    if (!g)
    {
      return nullptr;
    }
    Expr* fb = nullptr;
    if (lower(c(p_)) == 'f' && !in_block_ && iword_at(p_, "fallback") && !is_w(c(p_ + 8)))
    {
      int save = p_;
      p_ += 8;
      if (ws())
      {
        fb = expr();
      }
      if (!fb)
      {
        p_ = save;
      }
    }
    if (fb)
    {
      auto guard = make<Guard>();
      guard->expr = g;
      guard->fallback = fb;
      return span(guard, start, p_);
    }
    return span(g, start, p_);
  }

  // ---- expressions ----------------------------------------------------------
  // token expr { [ <unary> <!before <.opnext>> ] || [ <elvis> <feed>* ] }
  //
  // The value read alone first is the operators' first operand too: they
  // would read it again the same, so they are given it.
  Expr* Parser::expr()
  {
    int start = p_;
    Expr* u = unary();
    if (u)
    {
      if (!opnext())
      {
        return span(u, start, p_);
      }
    }
    else
    {
      p_ = start;
    }
    Expr* source = climb(L_ELVIS, u, false);
    if (!source)
    {
      return back(start);
    }
    int elvis_end = p_;
    std::vector<Call*> stages;
    while (c(p_) == '|' && c(p_ + 1) == '>' && !in_block_)
    {
      int save = p_;
      Call* st = feed();
      if (!st)
      {
        p_ = save;
        break;
      }
      stages.push_back(st);
    }
    if (!stages.empty())
    {
      span(source, start, elvis_end);
      auto pipe = make<Pipeline>();
      pipe->source = source;
      pipe->stages = std::move(stages);
      return span(pipe, start, p_);
    }
    return span(source, start, p_);
  }

  // rule feed { <?[|]> <!{ in a block }> '|>' <stage> }
  // rule stage { <nscall> || <call> || <name> }
  Call* Parser::feed()
  {
    p_ += 2;
    if (!ws())
    {
      return nullptr;
    }
    int start = p_;
    int e = name_end(start);
    if (e < 0)
    {
      return nullptr;
    }
    if (Call* st = nscall())
    {
      return st;
    }
    p_ = start;
    if (Call* st = call())
    {
      return st;
    }
    p_ = e;
    if (!ws())
    {
      return nullptr;
    }
    auto st = make<Call>();
    st->name = text(start, e);
    return st;
  }

  // The level of the operator at the cursor, or 0; the operator in op_.
  //
  //   rule elvis     { <orexpr> [ <?[?]> <elvisop> <orexpr> ]* }       '?:', from the right
  //   rule orexpr    { <andexpr> [ <?[.]> <orop> <andexpr> ]* }        '.or.'
  //   rule andexpr   { <notexpr> [ <?[.]> <andop> <notexpr> ]* }       '.and.'
  //   rule notexpr   { [ <?[!.]> <negate> ]? <cmpexpr> }               '!' '.not.', before one
  //   rule cmpexpr   { <rangeexpr> [ <?[=!<>$#iIhH]> <cmptail> ]* }
  //   rule cmptail   { [ <op=inop> <inrhs> ] || [ <op=cmpop> <rangeexpr> ] }
  //   rule rangeexpr { <lo> [ '..' <hi> <?before <.ws> '|>'> ]? }      once; 'in': no '|>'
  //   rule addexpr   { <mulexpr> [ <?[+\-]> <addop> <mulexpr> ]* }
  //   rule mulexpr   { <powexpr> [ <?[*/%]> <mulop> <powexpr> ]* }
  //   rule powexpr   { <unary> [ <?[*^]> <powop> <unary> ]* }
  int Parser::op_at()
  {
    int p = p_;
    int ch = c(p);
    int d = c(p + 1);
    auto found = [&](const char* op, int level) { op_ = op; oplen_ = static_cast<int>(op_.size()); return level; };
    switch (ch)
    {
      case '+': return found("+", L_ADD);
      case '-': return found("-", L_ADD);
      case '*': return d == '*' ? found("**", L_POW) : found("*", L_MUL);
      case '/': return found("/", L_MUL);
      case '%':
        if (d == '%') { return found("%%", L_MUL); }
        return in_exp_ ? 0 : found("%", L_MUL);
      case '^': return found("^", L_POW);
      case '.':
        if (d == '.') { return found("..", L_RANGE); }
        if (lower(d) == 'o' && lower(c(p + 2)) == 'r' && c(p + 3) == '.') { return found(".or.", L_OR); }
        if (lower(d) == 'a' && lower(c(p + 2)) == 'n' && lower(c(p + 3)) == 'd' && c(p + 4) == '.')
        {
          return found(".and.", L_AND);
        }
        return 0;
      case '?': return d == ':' ? found("?:", L_ELVIS) : 0;
      // inop: 'in' >> (letter case aside); cmpop: '==' '!=' '<>' '>=' '<='
      // '>' '<' '$' '#' '=' (not before '>') 'has' >>.
      case '=':
        if (d == '=') { return found("==", L_CMP); }
        return d == '>' ? 0 : found("=", L_CMP);
      case '<':
        if (d == '>') { return found("<>", L_CMP); }
        return d == '=' ? found("<=", L_CMP) : found("<", L_CMP);
      case '>': return d == '=' ? found(">=", L_CMP) : found(">", L_CMP);
      case '!': return d == '=' ? found("!=", L_CMP) : 0;
      case '$': return found("$", L_CMP);
      case '#': return found("#", L_CMP);
      default: break;
    }
    if (lower(ch) == 'i' && lower(d) == 'n' && !is_w(c(p + 2)))
    {
      return found("in", L_CMP);
    }
    if (lower(ch) == 'h' && lower(d) == 'a' && lower(c(p + 2)) == 's' && !is_w(c(p + 3)))
    {
      return found("has", L_CMP);
    }
    return 0;
  }

  // The operators from level min on, first the first operand when it has
  // been read; in: a range needs no '|>' after it (the right of 'in').
  //
  // The tree is the grammar's: left to right at each level, '?:' from the
  // right, and a level's operand made of the tighter ones. An operator whose
  // operand does not read is not taken, and the cursor goes back before it.
  // cap: the tightest operator that may still come -- the tighter ones were
  // read by the operand before, or failed there.
  Expr* Parser::climb(int min, Expr* first, bool in)
  {
    int start = p_;
    Expr* x = first;
    int cap = 99;
    if (!x)
    {
      int ch = c(p_);
      if (min <= L_NOT && (ch == '!' || (ch == '.' && iword_at(p_, ".not."))))
      {
        p_ += ch == '!' ? 1 : 5;
        if (!ws())
        {
          return back(start);
        }
        Expr* r = climb(L_CMP, nullptr, false);
        if (!r)
        {
          return back(start);
        }
        auto neg = make<Binary>();
        neg->op = "!";
        neg->right = r;
        x = span(neg, start, p_);
        cap = L_NOT;
      }
      else
      {
        x = unary();
        if (!x)
        {
          return back(start);
        }
      }
    }
    for (;;)
    {
      int level = op_at();
      if (level == 0 || level < min || level > cap)
      {
        break;
      }
      int save = p_;
      if (level == L_RANGE)
      {
        p_ += 2;
        Expr* hi = ws() ? climb(L_ADD, nullptr, false) : nullptr;
        if (hi && (in || (c(p_) == '|' && c(p_ + 1) == '>')))
        {
          x = interval(x, hi);
          cap = L_CMP;
          continue;
        }
        p_ = save;
        break;
      }
      std::string op = op_;
      p_ += oplen_;
      Expr* r = nullptr;
      if (ws())
      {
        if (level == L_ELVIS)    { r = climb(L_ELVIS, nullptr, false); }
        else if (level == L_CMP) { r = climb(L_RANGE, nullptr, op == "in"); }
        else                     { r = climb(level + 1, nullptr, false); }
      }
      if (!r)
      {
        p_ = save;
        break;
      }
      auto b = make<Binary>();
      b->op = op;
      b->left = x;
      b->right = r;
      x = joined(b);
      cap = level == L_ELVIS ? 0 : level;
    }
    return x;
  }

  // rule addexpr { <mulexpr> [ <?[+\-]> <addop> <mulexpr> ]* }
  Expr* Parser::addexpr() { return climb(L_ADD, nullptr, false); }

  // token unary
  // {
  //      [ <?[+\-]> <incop> <.ws> <!before <.ws><.ws><literal>> <postfix> ]
  //   || [ [ <?[+\-]> <sign> <.ws> ]? <.ws> <postfix> ]
  // }
  Expr* Parser::unary()
  {
    int start = p_;
    int ch = c(start);
    if (ch == '+' || ch == '-')
    {
      if (c(start + 1) == ch)
      {
        p_ += 2;
        if (ws())
        {
          int at = p_;
          Expr* lit = literal();
          p_ = at;
          if (!lit)
          {
            if (Expr* x = postfix())
            {
              return span(incdec(x, ch == '+', "pre"), start, p_);
            }
          }
        }
        p_ = start;
      }
      p_++;
      bool neg = false;
      if (ws())
      {
        neg = ch == '-';
      }
      else
      {
        p_ = start;
      }
      if (!ws())
      {
        return back(start);
      }
      Expr* x = postfix();
      if (!x)
      {
        return back(start);
      }
      if (neg)
      {
        auto b = make<Binary>();
        b->op = "neg";
        b->right = x;
        return span(b, start, p_);
      }
      return x;
    }
    if (!ws())
    {
      return back(start);
    }
    Expr* x = postfix();
    if (!x)
    {
      return back(start);
    }
    return x;
  }

  // token postfix
  // {
  //      [ <?litstart> <literal> <.ws> ]
  //   || [ <primary> [ [ <?{ $user-on }> || <?[{?:\[\-]> ] <trailer> ]* [ <?[+\-]> <incop> <.ws> ]? ]
  // }
  Expr* Parser::postfix()
  {
    int start = p_;
    int ch = c(start);
    if ((ch >= '0' && ch <= '9') || ch == '.' || ch == '"' || ch == '\''
        || (lower(ch) == 'n' && lower(c(start + 1)) == 'i' && lower(c(start + 2)) == 'l' && !is_w(c(start + 3))))
    {
      Expr* lit = literal();
      if (lit && ws())
      {
        return span(lit, start, p_);
      }
      p_ = start;
    }
    Expr* base = primary();
    if (!base)
    {
      return back(start);
    }
    int base_end = p_;
    std::vector<Trailer> tr;
    for (;;)
    {
      Trailer t;
      if (!trailer(t))
      {
        break;
      }
      tr.push_back(std::move(t));
    }
    int d = c(p_);
    if ((d == '+' || d == '-') && c(p_ + 1) == d)
    {
      int save = p_;
      p_ += 2;
      if (ws())
      {
        Expr* operand = trailed(base, start, base_end, tr, start, false);
        return span(incdec(operand, d == '+', "post"), start, p_);
      }
      p_ = save;
    }
    if (tr.empty())
    {
      return span(base, start, p_);
    }
    return span(trailed(base, start, base_end, tr, start, true), start, p_);
  }

  // rule trailer
  // {
  //      [<?{ $user-on }><ttrans>]
  //   || <?[{]><thash> || <?[?]><tsafe> || <?[:]>[ <tmethod> || <tmember> ]
  //   || <?[\[]><tindex> || <?[\-]>[ <tinalias> || <tfield> ]
  // }
  bool Parser::trailer(Trailer& t)
  {
    int start = p_;
    int ch = c(start);
    if (user_on_)
    {
      auto it = trans_.find(start);
      if (it != trans_.end() && it->second > start)
      {
        t.kind = T_TRANS;
        t.name = text(start, it->second);
        p_ = it->second;
        if (ws())
        {
          t.end = p_;
          return true;
        }
        p_ = start;
      }
    }
    if (ch == ':')
    {
      // rule tmethod { [ '::' || ':' ] <member> '(' ~ ')' <arglist> }
      // rule tmember { [ '::' || ':' ] <member> }
      p_ += c(start + 1) == ':' ? 2 : 1;
      if (!ws())
      {
        back(start);
        return false;
      }
      int me = name_end(p_);
      if (me < 0)
      {
        back(start);
        return false;
      }
      t.name = text(p_, me);
      p_ = me;
      if (!ws())
      {
        back(start);
        return false;
      }
      t.kind = call_args(t.list) ? T_METHOD : T_MEMBER;
      t.end = p_;
      return true;
    }
    if (ch == '[')
    {
      // rule tindex { '[' ~ ']' [ <expr> [ ',' <expr> ]* ] }
      p_++;
      if (!ws())
      {
        back(start);
        return false;
      }
      Expr* x = expr();
      if (!x)
      {
        back(start);
        return false;
      }
      t.list.push_back(x);
      while (c(p_) == ',')
      {
        int save = p_;
        p_++;
        Expr* y = ws() ? expr() : nullptr;
        if (!y)
        {
          p_ = save;
          break;
        }
        t.list.push_back(y);
      }
      if (c(p_) != ']')
      {
        back(start);
        return false;
      }
      p_++;
      if (!ws())
      {
        back(start);
        return false;
      }
      t.kind = T_INDEX;
      t.end = p_;
      return true;
    }
    if (ch == '-')
    {
      if (c(start + 1) != '>')
      {
        return false;
      }
      return tinalias(t) || tfield(t);
    }
    if (ch == '{')
    {
      return thash(t);
    }
    if (ch == '?')
    {
      return tsafe(t);
    }
    return false;
  }

  // rule thash { <?after <[\w)\]}]>> '{' ~ '}' <key> }
  bool Parser::thash(Trailer& t)
  {
    int start = p_;
    int b = start > 0 ? c(start - 1) : -1;
    if (!(is_w(b) || b == ')' || b == ']' || b == '}'))
    {
      return false;
    }
    p_++;
    if (!ws())
    {
      back(start);
      return false;
    }
    Expr* key = expr();
    if (!key || c(p_) != '}')
    {
      back(start);
      return false;
    }
    p_++;
    if (!ws())
    {
      back(start);
      return false;
    }
    t.kind = T_HASH;
    t.x = key;
    t.end = p_;
    return true;
  }

  // rule tsafe { '?.' <member> [ '(' ~ ')' <arglist> ]? }
  bool Parser::tsafe(Trailer& t)
  {
    int start = p_;
    if (c(start + 1) != '.')
    {
      return false;
    }
    p_ += 2;
    if (!ws())
    {
      back(start);
      return false;
    }
    int me = name_end(p_);
    if (me < 0)
    {
      back(start);
      return false;
    }
    t.name = text(p_, me);
    p_ = me;
    if (!ws())
    {
      back(start);
      return false;
    }
    t.kind = call_args(t.list) ? T_SCALL : T_SMEM;
    t.end = p_;
    return true;
  }

  // '(' ~ ')' <arglist> in a rule: the arguments, past the whitespace after
  // the ')' -- or false, the cursor where it was.
  bool Parser::call_args(std::vector<Expr*>& args)
  {
    int start = p_;
    if (c(start) != '(')
    {
      return false;
    }
    p_++;
    if (!ws())
    {
      back(start);
      return false;
    }
    std::vector<Expr*> list = arglist();
    if (c(p_) != ')')
    {
      back(start);
      return false;
    }
    p_++;
    if (!ws())
    {
      back(start);
      return false;
    }
    args = std::move(list);
    return true;
  }

  // rule tinalias { '->' '(' ~ ')' <expr> }
  bool Parser::tinalias(Trailer& t)
  {
    int start = p_;
    p_ += 2;
    if (!ws() || c(p_) != '(')
    {
      back(start);
      return false;
    }
    p_++;
    if (!ws())
    {
      back(start);
      return false;
    }
    Expr* e = expr();
    if (!e || c(p_) != ')')
    {
      back(start);
      return false;
    }
    p_++;
    if (!ws())
    {
      back(start);
      return false;
    }
    t.kind = T_INALS;
    t.x = e;
    t.end = p_;
    return true;
  }

  // rule tfield { '->' [ <fieldmacro> || <member> ] }
  bool Parser::tfield(Trailer& t)
  {
    int start = p_;
    p_ += 2;
    if (!ws())
    {
      back(start);
      return false;
    }
    if (c(p_) == '&')
    {
      int at = p_;
      if (Macro* m = macro())
      {
        t.kind = T_FIELD;
        t.name = "";
        t.x = m;
        t.end = p_;
        return true;
      }
      p_ = at;
    }
    int me = name_end(p_);
    if (me < 0)
    {
      back(start);
      return false;
    }
    t.name = text(p_, me);
    p_ = me;
    if (!ws())
    {
      back(start);
      return false;
    }
    t.kind = T_FIELD;
    t.x = nullptr;
    t.end = p_;
    return true;
  }

  // ---- primaries ------------------------------------------------------------
  // token primary: each form behind the character it starts with,
  // whitespace after it.
  Expr* Parser::primary()
  {
    int start = p_;
    if (user_on_)
    {
      auto it = trans_.find(start);
      if (it != trans_.end() && it->second > start)
      {
        int end = it->second;
        p_ = end;
        auto u = make<UserTrans>();
        u->text = text(start, end);
        span(u, start, end);
        if (ws())
        {
          return u;
        }
        p_ = start;
      }
    }
    int ch = c(start);
    Expr* x = nullptr;
    if (is_alpha(ch))
    {
      int we = name_end(start);
      if (c(we) == '.' && is_w(c(we + 1)))
      {
        x = nscall();
      }
      if (!x)
      {
        p_ = we;
        if (ws())
        {
          int k = c(p_);
          if (k == '(')
          {
            p_ = start;
            x = call();
          }
          else if (k == '-' && c(p_ + 1) == '>')
          {
            p_ = start;
            x = aliasfield();
          }
        }
        if (!x)
        {
          p_ = we;
          auto nm = make<Name>();
          nm->name = text(start, we);
          x = nm;
        }
      }
    }
    else if (ch == '(')
    {
      return parens();
    }
    else if (ch == ':')
    {
      x = selfacc();
      if (!x)
      {
        x = subjacc();
      }
    }
    else if (ch == '{')
    {
      x = codeblock();
      if (!x) { x = pairs(false); }
      if (!x) { x = pairs(true); }
      if (!x) { x = arrayliteral(); }
    }
    else if (ch == '[')
    {
      x = lambda();
    }
    else if (ch == '&')
    {
      x = macro();
    }
    else if (ch == '%')
    {
      if (Expr* e = sqlexp())
      {
        auto list = make<ExprList>();
        list->items.push_back(e);
        x = span(list, start, p_);
      }
    }
    if (!x || !ws())
    {
      return back(start);
    }
    return x;
  }

  // [:s '(' ~ ')' [ [ <passign> || <guardexpr> ] [ ',' <listitem> ]* ] ]
  Expr* Parser::parens()
  {
    int start = p_;
    p_++;
    if (!ws())
    {
      return back(start);
    }
    Expr* first = passign();
    if (!first)
    {
      first = guardexpr();
    }
    if (!first)
    {
      return back(start);
    }
    std::vector<Expr*> more;
    while (c(p_) == ',')
    {
      int save = p_;
      p_++;
      Expr* y = ws() ? listitem() : nullptr;
      if (!y)
      {
        p_ = save;
        break;
      }
      more.push_back(y);
    }
    if (c(p_) != ')')
    {
      return back(start);
    }
    p_++;
    if (!ws())
    {
      return back(start);
    }
    if (more.empty())
    {
      return first;
    }
    auto list = make<ExprList>();
    list->items.push_back(first);
    list->items.insert(list->items.end(), more.begin(), more.end());
    return span(list, start, p_);
  }

  // rule selfacc { '::' <member> [ '(' ~ ')' <arglist> ]? }
  Expr* Parser::selfacc()
  {
    int start = p_;
    if (c(start + 1) != ':')
    {
      return nullptr;
    }
    p_ += 2;
    return member_call(make<SelfRef>(), start);
  }

  // rule subjacc { <?{ in 'with object' }> ':' <member> [ '(' ~ ')' <arglist> ]? }
  Expr* Parser::subjacc()
  {
    int start = p_;
    if (!in_with_)
    {
      return nullptr;
    }
    p_++;
    return member_call(make<SubjectRef>(), start);
  }

  Expr* Parser::member_call(Expr* base, int start)
  {
    if (!ws())
    {
      return back(start);
    }
    int me = name_end(p_);
    if (me < 0)
    {
      return back(start);
    }
    std::string name = text(p_, me);
    p_ = me;
    if (!ws())
    {
      return back(start);
    }
    std::vector<Expr*> args;
    if (call_args(args))
    {
      auto m = make<MethodCall>();
      m->base = base;
      m->name = std::move(name);
      m->args = std::move(args);
      return m;
    }
    auto m = make<Member>();
    m->base = base;
    m->name = std::move(name);
    return m;
  }

  // rule call { <name> '(' ~ ')' <arglist> }
  Call* Parser::call()
  {
    int start = p_;
    int e = name_end(start);
    if (e < 0)
    {
      return nullptr;
    }
    p_ = e;
    std::vector<Expr*> args;
    if (!ws() || !call_args(args))
    {
      back(start);
      return nullptr;
    }
    auto cl = make<Call>();
    cl->name = text(start, e);
    cl->args = std::move(args);
    span(cl, start, p_);
    return cl;
  }

  // rule nscall { <qname> '(' ~ ')' <arglist> }
  // token qname { <[A..Za..z_]> \w* [ '.' <!logword> <[A..Za..z_]> \w* ]+ }
  // token logword { :i [ 'and' || 'or' || 'not' ] <![\w]> }
  Call* Parser::nscall()
  {
    int start = p_;
    int e = name_end(start);
    if (e < 0)
    {
      return nullptr;
    }
    int segments = 0;
    while (c(e) == '.')
    {
      int s = e + 1;
      int se = name_end(s);
      if (se < 0)
      {
        break;
      }
      std::string seg = lc(src_.substr(s, se - s));
      if (seg == "and" || seg == "or" || seg == "not")
      {
        break;
      }
      e = se;
      segments++;
    }
    if (!segments)
    {
      return nullptr;
    }
    std::string name = text(start, e);
    p_ = e;
    std::vector<Expr*> args;
    if (!ws() || !call_args(args))
    {
      back(start);
      return nullptr;
    }
    auto cl = make<Call>();
    cl->name = std::move(name);
    cl->args = std::move(args);
    span(cl, start, p_);
    return cl;
  }

  // rule arglist { <slot> [ ',' <slot> ]* }   rule slot { <arg>? }
  // Omitted for an empty position; none at all for '()'.
  std::vector<Expr*> Parser::arglist()
  {
    std::vector<Expr*> s;
    Expr* a = arg();
    s.push_back(a ? a : make<Omitted>());
    while (c(p_) == ',')
    {
      int save = p_;
      p_++;
      if (!ws())
      {
        p_ = save;
        break;
      }
      Expr* b = arg();
      s.push_back(b ? b : make<Omitted>());
    }
    if (s.size() == 1 && s[0]->kind == EK::Omitted)
    {
      s.clear();
    }
    return s;
  }

  // rule arg { [<?[@]><byref>] || [ <.sees('assign item')> <assignment> ] || <expr> }
  Expr* Parser::arg()
  {
    int start = p_;
    if (c(start) == '@')
    {
      if (Expr* r = byref())
      {
        return span(r, start, p_);
      }
      p_ = start;
    }
    if (sees(Ahead::Assign, true))
    {
      Assign a;
      if (assignment(a))
      {
        return span(assign_expr(a.target, a.op, a.value), start, p_);
      }
      p_ = start;
    }
    Expr* e = expr();
    if (!e)
    {
      return back(start);
    }
    return span(e, start, p_);
  }

  // rule byref { '@' [ <selfacc> || [ <name> <trailer>* ] ] }
  Expr* Parser::byref()
  {
    int start = p_;
    p_++;
    if (!ws())
    {
      return back(start);
    }
    int at = p_;
    if (c(at) == ':')
    {
      if (Expr* s = selfacc())
      {
        auto r = make<Ref>();
        r->target = s;
        return r;
      }
      p_ = at;
    }
    int e = name_end(at);
    if (e < 0)
    {
      return back(start);
    }
    auto name = make<Name>();
    name->name = text(at, e);
    p_ = e;
    if (!ws())
    {
      return back(start);
    }
    std::vector<Trailer> tr = trailers();
    auto r = make<Ref>();
    r->target = tr.empty() ? span(name, at, e) : trailed(name, at, e, tr, start, false);
    return r;
  }

  // rule macro { '&' [ [ '(' ~ ')' <expr> ] || [ <name> '.'? ] ] <mcall>? }
  // token mcall { '(' ~ ')' <arglist> }
  Macro* Parser::macro()
  {
    int start = p_;
    p_++;
    if (!ws())
    {
      back(start);
      return nullptr;
    }
    Expr* target = nullptr;
    if (c(p_) == '(')
    {
      int at = p_;
      p_++;
      if (ws())
      {
        Expr* e = expr();
        if (e && c(p_) == ')')
        {
          p_++;
          if (ws())
          {
            target = e;
          }
        }
      }
      if (!target)
      {
        p_ = at;
      }
    }
    if (!target)
    {
      int e = name_end(p_);
      if (e < 0)
      {
        back(start);
        return nullptr;
      }
      auto nm = make<Name>();
      nm->name = text(p_, e);
      target = nm;
      p_ = e;
      if (!ws())
      {
        back(start);
        return nullptr;
      }
      if (c(p_) == '.')
      {
        p_++;
        if (!ws())
        {
          back(start);
          return nullptr;
        }
      }
    }
    auto m = make<Macro>();
    m->target = target;
    if (c(p_) == '(')
    {
      int at = p_;
      p_++;
      std::vector<Expr*> a = arglist();
      if (c(p_) == ')')
      {
        p_++;
        if (ws())
        {
          m->called = true;
          m->args = std::move(a);
        }
        else
        {
          p_ = at;
        }
      }
      else
      {
        p_ = at;
      }
    }
    return m;
  }

  // token sqlexp { '%' :i 'exp' ':' <.ws> [ <expr> ] <.ws> '%' } -- a '%'
  // inside is its end
  Expr* Parser::sqlexp()
  {
    int start = p_;
    if (!iword_at(start + 1, "exp") || c(start + 4) != ':')
    {
      return nullptr;
    }
    p_ += 5;
    if (!ws())
    {
      return back(start);
    }
    in_exp_++;
    Expr* e = expr();
    in_exp_--;
    if (!e || !ws() || c(p_) != '%')
    {
      return back(start);
    }
    p_++;
    return e;
  }

  // rule aliasfield
  // {
  //   <alias=name> '->' [ [ '(' ~ ')' [ <expr> [ ',' <listitem> ]* ] ] || <fieldmacro> || <field=member> ]
  // }
  Expr* Parser::aliasfield()
  {
    int start = p_;
    int e = name_end(start);
    if (e < 0)
    {
      return nullptr;
    }
    std::string alias = text(start, e);
    p_ = e;
    if (!ws() || c(p_) != '-' || c(p_ + 1) != '>')
    {
      return back(start);
    }
    p_ += 2;
    if (!ws())
    {
      return back(start);
    }
    if (c(p_) == '(')
    {
      int at = p_;
      p_++;
      if (ws())
      {
        if (Expr* x = expr())
        {
          std::vector<Expr*> more;
          while (c(p_) == ',')
          {
            int save = p_;
            p_++;
            Expr* y = ws() ? listitem() : nullptr;
            if (!y)
            {
              p_ = save;
              break;
            }
            more.push_back(y);
          }
          if (c(p_) == ')')
          {
            p_++;
            if (ws())
            {
              auto in = make<InAlias>();
              in->alias = alias;
              if (more.empty())
              {
                in->expr = x;
              }
              else
              {
                auto list = make<ExprList>();
                list->items.push_back(x);
                list->items.insert(list->items.end(), more.begin(), more.end());
                in->expr = list;
              }
              return in;
            }
          }
        }
      }
      p_ = at;
    }
    if (c(p_) == '&')
    {
      int at = p_;
      if (Macro* m = macro())
      {
        auto a = make<AliasField>();
        a->alias = alias;
        a->field = "";
        a->macro = m;
        return a;
      }
      p_ = at;
    }
    int fe = name_end(p_);
    if (fe < 0)
    {
      return back(start);
    }
    std::string field = text(p_, fe);
    p_ = fe;
    if (!ws())
    {
      return back(start);
    }
    auto a = make<AliasField>();
    a->alias = alias;
    a->field = std::move(field);
    return a;
  }

  // rule lambda
  // {
  //   '[' <lparam=name> [ ',' <lparam=name> ] ** 0..5 ']' <lbody> <!before \h* '|>'>
  // }
  Expr* Parser::lambda()
  {
    int start = p_;
    p_++;
    if (!ws())
    {
      return back(start);
    }
    std::vector<std::string> params;
    int e = name_end(p_);
    if (e < 0)
    {
      return back(start);
    }
    params.push_back(text(p_, e));
    p_ = e;
    if (!ws())
    {
      return back(start);
    }
    while (params.size() < 6 && c(p_) == ',')
    {
      int save = p_;
      p_++;
      bool ok = false;
      if (ws())
      {
        int pe = name_end(p_);
        if (pe >= 0)
        {
          std::string p = text(p_, pe);
          p_ = pe;
          if (ws())
          {
            params.push_back(std::move(p));
            ok = true;
          }
        }
      }
      if (!ok)
      {
        p_ = save;
        break;
      }
    }
    if (c(p_) != ']')
    {
      return back(start);
    }
    p_++;
    if (!ws())
    {
      return back(start);
    }
    in_block_++;
    Expr* body = blockexpr();
    in_block_--;
    if (!body)
    {
      return back(start);
    }
    int q = p_;
    while (is_h(c(q)))
    {
      q++;
    }
    if (c(q) == '|' && c(q + 1) == '>')
    {
      return back(start);
    }
    auto l = make<Lambda>();
    l->type = "Block";
    l->text = trim(src_.substr(start, p_ - start));
    l->params = std::move(params);
    l->body.push_back(body);
    return l;
  }

  // rule codeblock
  // {
  //   '{' [ '||' || [ '|' <name>* % ',' '|' ] ] <blockexpr>* % ',' '}'
  // }
  Expr* Parser::codeblock()
  {
    int start = p_;
    p_++;
    if (!ws())
    {
      return back(start);
    }
    std::vector<std::string> params;
    if (c(p_) == '|' && c(p_ + 1) == '|')
    {
      p_ += 2;
      if (!ws())
      {
        return back(start);
      }
    }
    else if (c(p_) == '|')
    {
      p_++;
      if (!ws())
      {
        return back(start);
      }
      int e = name_end(p_);
      if (e >= 0)
      {
        params.push_back(text(p_, e));
        p_ = e;
        while (c(p_) == ',')
        {
          int save = p_;
          p_++;
          bool ok = false;
          if (ws())
          {
            int pe = name_end(p_);
            if (pe >= 0)
            {
              params.push_back(text(p_, pe));
              p_ = pe;
              ok = true;
            }
          }
          if (!ok)
          {
            p_ = save;
            break;
          }
        }
      }
      if (!ws() || c(p_) != '|')
      {
        return back(start);
      }
      p_++;
      if (!ws())
      {
        return back(start);
      }
    }
    else
    {
      return back(start);
    }
    in_block_++;
    std::vector<Expr*> body;
    if (Expr* b = blockexpr())
    {
      body.push_back(b);
      while (c(p_) == ',')
      {
        int save = p_;
        p_++;
        Expr* y = ws() ? blockexpr() : nullptr;
        if (!y)
        {
          p_ = save;
          break;
        }
        body.push_back(y);
      }
    }
    in_block_--;
    if (!ws() || c(p_) != '}')
    {
      return back(start);
    }
    p_++;
    if (!ws())
    {
      return back(start);
    }
    auto cb = make<CodeBlock>();
    cb->type = "Block";
    cb->text = trim(src_.substr(start, p_ - start));
    cb->params = std::move(params);
    cb->body = std::move(body);
    return cb;
  }

  // rule blockexpr { [ <.sees('assign item')> <assignment> ] || <expr> }
  Expr* Parser::blockexpr()
  {
    int start = p_;
    if (sees(Ahead::Assign, true))
    {
      Assign a;
      if (assignment(a))
      {
        return span(assign_expr(a.target, a.op, a.value), start, p_);
      }
      p_ = start;
    }
    Expr* e = expr();
    if (!e)
    {
      return back(start);
    }
    return span(e, start, p_);
  }

  // rule jsonliteral { '{' ~ '}' [ ':' || [ <pair>+ % ',' ] ] }
  // rule hashliteral { '{' ~ '}' [ '=>' || [ <hashpair>+ % ',' ] ] }
  Expr* Parser::pairs(bool hash)
  {
    int start = p_;
    p_++;
    if (!ws())
    {
      return back(start);
    }
    std::vector<KeyValue*> list;
    if (hash ? (c(p_) == '=' && c(p_ + 1) == '>') : c(p_) == ':')
    {
      p_ += hash ? 2 : 1;
      if (!ws())
      {
        return back(start);
      }
    }
    else
    {
      KeyValue* p = kv_pair(hash);
      if (!p)
      {
        return back(start);
      }
      list.push_back(p);
      while (c(p_) == ',')
      {
        int save = p_;
        p_++;
        KeyValue* q = ws() ? kv_pair(hash) : nullptr;
        if (!q)
        {
          p_ = save;
          break;
        }
        list.push_back(q);
      }
    }
    if (c(p_) != '}')
    {
      return back(start);
    }
    p_++;
    if (!ws())
    {
      return back(start);
    }
    if (hash)
    {
      auto h = make<HashLit>();
      h->type = "Object";
      h->text = trim(src_.substr(start, p_ - start));
      h->pairs = std::move(list);
      return h;
    }
    auto j = make<JsonLit>();
    j->type = "JSON";
    j->text = trim(src_.substr(start, p_ - start));
    j->pairs = std::move(list);
    return j;
  }

  // rule pair { <expr> ':' <expr> }   rule hashpair { <expr> '=>' <expr> }
  KeyValue* Parser::kv_pair(bool hash)
  {
    int start = p_;
    Expr* k = expr();
    if (!k)
    {
      back(start);
      return nullptr;
    }
    if (hash)
    {
      if (c(p_) != '=' || c(p_ + 1) != '>')
      {
        back(start);
        return nullptr;
      }
      p_ += 2;
    }
    else
    {
      if (c(p_) != ':')
      {
        back(start);
        return nullptr;
      }
      p_++;
    }
    Expr* v = ws() ? expr() : nullptr;
    if (!v)
    {
      back(start);
      return nullptr;
    }
    auto kv = make<KeyValue>();
    kv->key = k;
    kv->value = v;
    return kv;
  }

  // rule arrayliteral { '{' ~ '}' [ <aitem> [ ',' <aitem> ]* ] }   rule aitem { <expr>? }
  Expr* Parser::arrayliteral()
  {
    int start = p_;
    p_++;
    if (!ws())
    {
      return back(start);
    }
    std::vector<Expr*> items;
    Expr* x = expr();
    items.push_back(x ? x : make<Omitted>());
    while (c(p_) == ',')
    {
      int save = p_;
      p_++;
      if (!ws())
      {
        p_ = save;
        break;
      }
      Expr* y = expr();
      items.push_back(y ? y : make<Omitted>());
    }
    if (c(p_) != '}')
    {
      return back(start);
    }
    p_++;
    if (!ws())
    {
      return back(start);
    }
    if (items.size() == 1 && items[0]->kind == EK::Omitted)
    {
      items.clear();
    }
    auto a = make<ArrayLit>();
    a->type = "Array";
    a->text = trim(src_.substr(start, p_ - start));
    a->items = std::move(items);
    return a;
  }

  // ---- literals -------------------------------------------------------------
  // token literal { <number> || <string> || <logical> || <nildef> }: the
  // node, the cursor at its end (no whitespace taken), or null.
  Expr* Parser::literal()
  {
    int start = p_;
    int ch = c(start);
    int d = c(start + 1);
    if (is_d(ch) || (ch == '.' && is_d(d)))
    {
      int e = number_end(start);
      p_ = e;
      auto l = make<Literal>();
      l->type = "Numeric";
      l->text = text(start, e);
      return l;
    }
    if (ch == '"' || ch == '\'')
    {
      return string();
    }
    if (ch == '.' && (lower(d) == 't' || lower(d) == 'f') && c(start + 2) == '.')
    {
      p_ = start + 3;
      auto l = make<Literal>();
      l->type = "Logical";
      l->text = text(start, start + 3);
      return l;
    }
    if (lower(ch) == 'n' && lower(d) == 'i' && lower(c(start + 2)) == 'l' && !is_w(c(start + 3)))
    {
      p_ = start + 3;
      auto l = make<Literal>();
      l->type = "Variant";
      l->text = text(start, start + 3);
      return l;
    }
    return nullptr;
  }

  // token number { [ \d+ [ "'" \d+ ]* [ '.' \d+ [ "'" \d+ ]* ]? ] || [ '.' \d+ ] }
  int Parser::number_end(int p) const
  {
    int q = p;
    if (c(q) == '.')
    {
      q++;
      while (is_d(c(q)))
      {
        q++;
      }
      return q;
    }
    while (is_d(c(q)))
    {
      q++;
    }
    q = groups(q);
    if (c(q) == '.' && is_d(c(q + 1)))
    {
      q++;
      while (is_d(c(q)))
      {
        q++;
      }
      q = groups(q);
    }
    return q;
  }

  int Parser::groups(int p) const
  {
    while (c(p) == '\'' && is_d(c(p + 1)))
    {
      p++;
      while (is_d(c(p)))
      {
        p++;
      }
    }
    return p;
  }

  // token string { '"' ... || "'" ... }, with xtpl's '${ }': a Literal, or
  // an Interp when it holds an expression. A string inside a '${ }' cannot
  // use the quote of one around it.
  Expr* Parser::string()
  {
    int q = c(p_);
    if ((q == '"' && in_dq_) || (q == '\'' && in_sq_))
    {
      return nullptr;
    }
    int& depth = q == '"' ? in_dq_ : in_sq_;
    depth++;
    Expr* s = string_in(q);
    depth--;
    return s;
  }

  Expr* Parser::string_in(int q)
  {
    int start = p_;
    p_++;
    std::vector<Part> parts;
    bool exprs = false;
    for (;;)
    {
      if (c(p_) == '$' && c(p_ + 1) == '{')
      {
        int at = p_;
        p_ += 2;
        if (ws())
        {
          Expr* e = expr();
          if (e && ws() && c(p_) == '}')
          {
            p_++;
            parts.emplace_back(e);
            exprs = true;
            continue;
          }
        }
        p_ = at;
        break;
      }
      int t = p_;
      for (;;)
      {
        int d = c(t);
        if (d == q || d < 0 || is_nl(d) || (d == '$' && c(t + 1) == '{'))
        {
          break;
        }
        t++;
      }
      if (t == p_)
      {
        break;
      }
      parts.emplace_back(text(p_, t));
      p_ = t;
    }
    if (c(p_) == q)
    {
      p_++;
    }
    else if (!(c(p_) < 0 || !is_nn(c(p_))))
    {
      return back(start);
    }
    std::string txt = text(start, p_);
    if (exprs)
    {
      auto s = make<Interp>();
      s->type = "Character";
      s->text = std::move(txt);
      s->parts = std::move(parts);
      return s;
    }
    auto l = make<Literal>();
    l->type = "Character";
    l->text = std::move(txt);
    return l;
  }

  // ---- assignments, targets, statements made of a call ----------------------
  // rule assignment { <!stmtword> <lvalue> <assignop> [ <chained> || <guardexpr> ] }
  bool Parser::assignment(Assign& a)
  {
    int start = p_;
    if (stmtword_at(start))
    {
      return false;
    }
    if (!ws())
    {
      back(start);
      return false;
    }
    Expr* t = lvalue();
    const char* op = t ? assignop() : nullptr;
    if (!op || !ws())
    {
      back(start);
      return false;
    }
    Expr* v = value();
    if (!v)
    {
      back(start);
      return false;
    }
    a.target = t;
    a.op = op;
    a.value = v;
    return true;
  }

  // token assignop { ':=' || '+=' || '-=' || '*=' || '/=' || '=' }
  const char* Parser::assignop()
  {
    int ch = c(p_);
    if (c(p_ + 1) == '=')
    {
      const char* op = ch == ':' ? ":=" : ch == '+' ? "+=" : ch == '-' ? "-=" : ch == '*' ? "*=" : ch == '/' ? "/=" : nullptr;
      if (op)
      {
        p_ += 2;
        return op;
      }
    }
    if (ch == '=')
    {
      p_++;
      return "=";
    }
    return nullptr;
  }

  // rule lvalue
  // {
  //      [ '(' ~ ')' <pexpr> <trailer>+ ] || [ <call> <trailer>+ ] || <atail>
  //   || [ <macro> <trailer>* ]
  //   || [ '@'? [ <selfacc> || <subjacc> || <name> ] <trailer>* ]
  // }
  Expr* Parser::lvalue()
  {
    int start = p_;
    int ch = c(start);
    if (ch == '(')
    {
      p_++;
      if (ws())
      {
        int bf = p_;
        Expr* e = expr();
        if (e && c(p_) == ')')
        {
          int bt = p_;
          p_++;
          if (ws())
          {
            std::vector<Trailer> tr = trailers();
            if (!tr.empty())
            {
              return span(trailed(e, bf, bt, tr, start, true), start, p_);
            }
          }
        }
      }
      p_ = start;
    }
    if (is_alpha(ch))
    {
      if (Call* cl = call())
      {
        int bt = p_;
        std::vector<Trailer> tr = trailers();
        if (!tr.empty())
        {
          return span(trailed(cl, start, bt, tr, start, true), start, p_);
        }
      }
      p_ = start;
      if (iword_at(start, "atail"))
      {
        int q = start + 5;
        while (is_h(c(q)))
        {
          q++;
        }
        if (c(q) == '(')
        {
          if (Call* a = call())
          {
            return span(a, start, p_);
          }
          p_ = start;
        }
      }
    }
    if (ch == '&')
    {
      if (Macro* m = macro())
      {
        int bt = p_;
        std::vector<Trailer> tr = trailers();
        return span(trailed(m, start, bt, tr, start, true), start, p_);
      }
      p_ = start;
    }
    if (ch == '@')
    {
      p_++;
      if (!ws())
      {
        return back(start);
      }
    }
    int bf = p_;
    Expr* base = nullptr;
    int bt = p_;
    if (c(bf) == ':')
    {
      base = selfacc();
      if (!base)
      {
        base = subjacc();
      }
      bt = p_;
    }
    if (!base)
    {
      int e = name_end(bf);
      if (e < 0)
      {
        return back(start);
      }
      auto nm = make<Name>();
      nm->name = text(bf, e);
      base = nm;
      p_ = e;
      bt = e;
      if (!ws())
      {
        return back(start);
      }
    }
    std::vector<Trailer> tr = trailers();
    return span(trailed(base, bf, bt, tr, start, true), start, p_);
  }

  std::vector<Parser::Trailer> Parser::trailers()
  {
    std::vector<Trailer> tr;
    for (;;)
    {
      Trailer t;
      if (!trailer(t))
      {
        break;
      }
      tr.push_back(std::move(t));
    }
    return tr;
  }

  // rule callst
  // {
  //   <!stmtword> [ [ <call> <trailer>* ] || [ <name> <trailer>+ ] || [ <subjacc> <trailer>* ]
  //              || [ <selfacc> <trailer>* ] || [ <macrocall> <trailer>* ] || [ <nscall> <trailer>* ]
  //              || [ <macro> ] || [ <inalias> ] || [ '(' ~ ')' <pexpr> <trailer>* ] ]
  // }
  // The call the statement makes, spanned as the statement's.
  Expr* Parser::callst()
  {
    int start = p_;
    if (stmtword_at(start))
    {
      return nullptr;
    }
    if (!ws())
    {
      return back(start);
    }
    int at = p_;
    int ch = c(at);
    if (is_alpha(ch))
    {
      if (Call* cl = call())
      {
        int bt = p_;
        std::vector<Trailer> tr = trailers();
        return span(trailed(cl, at, bt, tr, start, true), start, p_);
      }
      p_ = at;
      int e = name_end(at);
      p_ = e;
      if (ws())
      {
        std::vector<Trailer> tr = trailers();
        if (!tr.empty())
        {
          auto nm = make<Name>();
          nm->name = text(at, e);
          return span(trailed(nm, at, e, tr, start, true), start, p_);
        }
      }
      p_ = at;
    }
    if (ch == ':')
    {
      Expr* s = subjacc();
      if (!s)
      {
        s = selfacc();
      }
      if (s)
      {
        int bt = p_;
        std::vector<Trailer> tr = trailers();
        return span(trailed(s, at, bt, tr, start, true), start, p_);
      }
      p_ = at;
    }
    if (ch == '&')
    {
      Macro* m = macro();
      if (m && m->called)
      {
        int bt = p_;
        std::vector<Trailer> tr = trailers();
        return span(trailed(m, at, bt, tr, start, true), start, p_);
      }
      p_ = at;
    }
    if (is_alpha(ch))
    {
      if (Call* ns = nscall())
      {
        int bt = p_;
        std::vector<Trailer> tr = trailers();
        return span(trailed(ns, at, bt, tr, start, true), start, p_);
      }
      p_ = at;
    }
    if (ch == '&')
    {
      if (Macro* m = macro())
      {
        return span(trailed(m, at, p_, {}, start, true), start, p_);
      }
      p_ = at;
    }
    if (is_alpha(ch))
    {
      Expr* a = aliasfield();
      if (a && a->kind == EK::InAlias)
      {
        return span(trailed(a, at, p_, {}, start, true), start, p_);
      }
      p_ = at;
    }
    if (ch == '(')
    {
      p_++;
      if (ws())
      {
        int bf = p_;
        Expr* e = expr();
        if (e && c(p_) == ')')
        {
          int bt = p_;
          p_++;
          if (ws())
          {
            std::vector<Trailer> tr = trailers();
            return span(trailed(e, bf, bt, tr, start, true), start, p_);
          }
        }
      }
    }
    return back(start);
  }

  // rule pipest { <!stmtword> <elvis> <feed>+ }
  Expr* Parser::pipest()
  {
    int start = p_;
    if (stmtword_at(start))
    {
      return nullptr;
    }
    if (!ws())
    {
      return back(start);
    }
    int at = p_;
    Expr* source = climb(L_ELVIS, nullptr, false);
    if (!source)
    {
      return back(start);
    }
    int elvis_end = p_;
    std::vector<Call*> stages;
    while (c(p_) == '|' && c(p_ + 1) == '>' && !in_block_)
    {
      int save = p_;
      Call* st = feed();
      if (!st)
      {
        p_ = save;
        break;
      }
      stages.push_back(st);
    }
    if (stages.empty())
    {
      return back(start);
    }
    span(source, at, elvis_end);
    auto pipe = make<Pipeline>();
    pipe->source = source;
    pipe->stages = std::move(stages);
    return span(pipe, start, p_);
  }
}
