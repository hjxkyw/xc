// xc -- the statements and the file (see parser.h).
//
// Each routine reads one rule of the Raku grammar, quoted above it. In a
// rule each part is followed by whitespace (<.ws>), as Raku reads a rule;
// a token takes none it does not write. A routine that does not read its
// form gives null (or false) and leaves the cursor where it was.

#include <algorithm>
#include <iterator>
#include <unordered_set>
#include <utility>

#include "chars.h"
#include "parser.h"

namespace xc
{
  namespace
  {
    // The first words of the statements that are not simple ones, and of
    // TOTVS' commands (the grammar's STMT-WORDS).
    const std::unordered_set<std::string> STMT_WORDS =
    {
      "begin", "try", "local", "private", "public", "static", "if", "do", "while", "for", "exec",
      "defer", "using", "with", "raw", "endfunction", "endfunc", "endmethod", "default", "define",
      "activate", "redefine", "set", "menu", "publish", "replace", "add", "prepare", "reset",
      "append", "count", "menuitem", "endmenu", "tcquery", "connect", "disconnect", "send", "get",
      "paramtype", "throw", "vtpause", "vtread", "vtclear", "vtsave", "vtrestore", "beginsql",
      "begincontent",
    };

    const std::unordered_set<std::string> SIMPLE_WORDS = { "return", "exit", "loop", "break", "default" };

    // Names refused where one is declared.
    const std::unordered_set<std::string> RESERVED =
    {
      "function", "static", "return", "if", "else", "elseif", "endif", "for", "next", "while",
      "enddo", "do", "local", "private", "public", "with", "without", "orwith", "given", "when",
      "otherwise", "end", "len", "as",
    };

    bool is_s(int c) { return c >= 0 && (CHAR_CLASS[c] & C_S); }
    bool digits(const std::string& s, std::size_t& i)
    {
      std::size_t k = i;
      while (k < s.size() && is_d(static_cast<unsigned char>(s[k])))
      {
        k++;
      }
      bool any = k > i;
      i = k;
      return any;
    }

    // The type's full name, from what was written (XC::AST's type-of-name).
    std::string type_of_name(const std::string& name)
    {
      std::string n = lc(name);
      if (n == "array" || n == "a") { return "Array"; }
      if (n == "numeric" || n == "n" || n == "integer" || n == "decimal" || n == "double") { return "Numeric"; }
      if (n == "character" || n == "c" || n == "char") { return "Character"; }
      if (n == "logical" || n == "l") { return "Logical"; }
      if (n == "date" || n == "d") { return "Date"; }
      if (n == "object" || n == "o" || n == "variadic") { return "Object"; }
      if (n == "block" || n == "b" || n == "codeblock") { return "Block"; }
      if (n == "json" || n == "j") { return "JSON"; }
      if (n == "variant" || n == "u") { return "Variant"; }
      return "?";
    }

    // The words of a text, as Raku's .words.
    std::vector<std::string> words(std::string_view t)
    {
      std::vector<std::string> out;
      std::size_t i = 0;
      while (i < t.size())
      {
        while (i < t.size() && is_s(static_cast<unsigned char>(t[i])))
        {
          i++;
        }
        std::size_t k = i;
        while (k < t.size() && !is_s(static_cast<unsigned char>(t[k])))
        {
          k++;
        }
        if (k > i)
        {
          out.emplace_back(t.substr(i, k - i));
        }
        i = k;
      }
      return out;
    }

    // The attributes of '<const, contained>': its words, lower case.
    std::vector<std::string> attr_words(std::string_view t)
    {
      std::vector<std::string> out;
      std::size_t i = 0;
      while (i < t.size())
      {
        while (i < t.size() && !is_w(static_cast<unsigned char>(t[i])))
        {
          i++;
        }
        std::size_t k = i;
        while (k < t.size() && is_w(static_cast<unsigned char>(t[k])))
        {
          k++;
        }
        if (k > i)
        {
          out.push_back(lc(t.substr(i, k - i)));
        }
        i = k;
      }
      return out;
    }
  }

  // Names refused where one is declared (the grammar's is-reserved).
  bool is_reserved(const std::string& name)
  {
    return RESERVED.count(lc(name)) > 0;
  }

  // The shape of a name xc generates: '<kind>_<depth>_<index>', or a slot
  // 's_'/'b_' (the grammar's is-generated).
  bool is_generated(const std::string& name)
  {
    std::string n = lc(name);
    static const char* kinds[] =
    {
      "fa", "fal", "far", "fbg", "fbs", "fbv", "fch", "fdf", "fdr", "ffs", "fhd", "fhi", "fi", "fj",
      "fky", "fls", "flm", "flo", "fn", "fok", "fol", "fop", "fo", "fpv", "fpb", "frd", "frc", "fsn",
      "fsp", "fs", "fv", "et", "gt", "ht", "pt",
    };
    for (const char* k : kinds)
    {
      std::string kind = k;
      if (n.size() > kind.size() && n.compare(0, kind.size(), kind) == 0 && n[kind.size()] == '_')
      {
        std::size_t i = kind.size() + 1;
        if (digits(n, i) && i < n.size() && n[i] == '_')
        {
          i++;
          if (digits(n, i) && i == n.size())
          {
            return true;
          }
        }
      }
    }
    if (n.size() > 2 && (n[0] == 's' || n[0] == 'b') && n[1] == '_')
    {
      std::size_t i = 2;
      if (digits(n, i) && i < n.size() && n[i] == '_')
      {
        i++;
        std::size_t k = i;
        while (k < n.size() && is_w(static_cast<unsigned char>(n[k])))
        {
          k++;
        }
        return k > i && k == n.size();
      }
    }
    return false;
  }

  // ---- the small pieces of a line -------------------------------------------
  // The line an offset is on, as XC::Source counts them.
  int Parser::line(int at)
  {
    int row = static_cast<int>(std::upper_bound(rows_.begin(), rows_.end(), at) - rows_.begin()) - 1;
    int last = std::max(1, static_cast<int>(rows_.size()) - 1);
    return std::min(std::max(row, 0) + 1, last);
  }

  // ':i word': the word, letter case aside (word in lower case).
  bool Parser::ilit(std::string_view word)
  {
    if (!iword_at(p_, word))
    {
      return false;
    }
    p_ += static_cast<int>(word.size());
    return true;
  }

  bool Parser::lit(std::string_view s)
  {
    if (src_.substr(p_, s.size()) != s)
    {
      return false;
    }
    p_ += static_cast<int>(s.size());
    return true;
  }

  // '>>': a word ends here.
  bool Parser::word_end() const { return p_ > 0 && is_w(c(p_ - 1)) && !is_w(c(p_)); }

  // '<!ww>': not between two word characters.
  bool Parser::not_within_word() const { return !(p_ > 0 && is_w(c(p_ - 1)) && is_w(c(p_))); }

  // '\v' at p: its length ("\r\n" is one), or 0.
  int Parser::vchar(int p) const
  {
    if (!is_v(c(p)))
    {
      return 0;
    }
    return c(p) == 13 && c(p + 1) == 10 ? 2 : 1;
  }

  // '\n' at p, as Raku takes it: "\n", "\r\n" or "\r" -- its length, or 0.
  int Parser::nlchar(int p) const
  {
    if (c(p) == 13)
    {
      return c(p + 1) == 10 ? 2 : 1;
    }
    return c(p) == 10 ? 1 : 0;
  }

  // <linecomment> at p: '//' or '&&' to the end of the line -- where it
  // ends, or -1.
  int Parser::linecomment(int p) const
  {
    int ch = c(p);
    if ((ch == '/' || ch == '&') && c(p + 1) == ch)
    {
      int q = p + 2;
      while (is_nn(c(q)))
      {
        q++;
      }
      return q;
    }
    return -1;
  }

  // token eol
  // {
  //   \h* [ <?before '//' || '&&'> <.linecomment> || <?before '/*'> <.blockcomment> ]? \h*
  //   [ \v || $ || ';' <!before \h* [ <.linecomment> || <.blockcomment> ]? \h* [ \v || $ ]> ]
  // }
  // The end of a line, or a ';' with more after it on the line. consume:
  // move past it, or only look.
  bool Parser::eol(bool consume)
  {
    int q = p_;
    while (is_h(c(q)))
    {
      q++;
    }
    int k = linecomment(q);
    if (k >= 0)
    {
      q = k;
    }
    else if (c(q) == '/' && c(q + 1) == '*')
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
    if (int v = vchar(q))
    {
      q += v;
    }
    else if (q == n_)
    {
    }
    else if (c(q) == ';')
    {
      int r = q + 1;
      while (is_h(c(r)))
      {
        r++;
      }
      int e = linecomment(r);
      if (e >= 0)
      {
        r = e;
      }
      else if (c(r) == '/' && c(r + 1) == '*')
      {
        int b = block_end(r);
        if (b >= 0)
        {
          r = b;
        }
      }
      while (is_h(c(r)))
      {
        r++;
      }
      if (vchar(r) || r == n_)
      {
        return false;            // a ';' at the end of a line carries it on
      }
      q++;
    }
    else
    {
      return false;
    }
    if (consume)
    {
      p_ = q;
    }
    return true;
  }

  // token gap
  // {
  //   [ ^^ <?before \h* '*'> <.starcomment> || \s || <?[;]> <.linecont>
  //   || <?before '//' || '&&'> <.linecomment> || <?before '/*'> <.blockcomment> ]*
  // }
  // Blank lines, comment lines -- a line starting with '*' too -- and the
  // indentation, before the next statement.
  void Parser::gap()
  {
    for (;;)
    {
      int ch = c(p_);
      if (line_start(p_))
      {
        int q = p_;
        while (is_h(c(q)))
        {
          q++;
        }
        if (c(q) == '*')
        {
          while (is_nn(c(q)))
          {
            q++;
          }
          p_ = q;
          continue;
        }
      }
      if (is_s(ch))
      {
        p_++;
        continue;
      }
      if (ch == ';')
      {
        int q = linecont(p_);
        if (q >= 0)
        {
          p_ = q;
          continue;
        }
        break;
      }
      int k = linecomment(p_);
      if (k >= 0)
      {
        p_ = k;
        continue;
      }
      if (ch == '/' && c(p_ + 1) == '*')
      {
        int e = block_end(p_);
        if (e >= 0)
        {
          p_ = e;
          continue;
        }
      }
      break;
    }
  }

  // token nl { <.eol> <.gap> }: and how far the parse got.
  bool Parser::nl()
  {
    if (!eol(true))
    {
      return false;
    }
    gap();
    furthest_ = std::max(furthest_, p_);
    return true;
  }

  // From p, the lines a ';' at their end carries on to, then the rest of
  // the last: '[ \N*? ';' \h* \v ]* \N*' (nl_only: '\n' for '\v', as the
  // preprocessor's directive has it). Where it ends.
  int Parser::continued_line(int p, bool nl_only) const
  {
    for (;;)
    {
      int e = p;
      while (is_nn(c(e)))
      {
        e++;
      }
      int k = e;
      while (k > p && is_h(c(k - 1)))
      {
        k--;
      }
      int v = nl_only ? nlchar(e) : vchar(e);
      if (k > p && c(k - 1) == ';' && v)
      {
        p = e + v;
        continue;
      }
      return e;
    }
  }

  // A name: its text, and where it ends -- or empty, end -1.
  std::string Parser::name_text(int& end)
  {
    end = name_end(p_);
    return end < 0 ? std::string() : text(p_, end);
  }

  bool Parser::refused(const std::string& name) const
  {
    return !any_name && RESERVED.count(lc(name));
  }

  // ---- the file -------------------------------------------------------------
  // rule TOP { ^ <.gap> <.mark> [ <toplevel> <.gap> <.mark> ]* $ }
  Program* Parser::parse()
  {
    p_ = 0;
    furthest_ = 0;
    in_with_ = false;
    in_block_ = in_dq_ = in_sq_ = in_exp_ = 0;
    past_prologue_ = false;
    top_level_ = false;
    auto prog = make<Program>();
    ws();
    gap();
    ws();
    furthest_ = std::max(furthest_, p_);
    ws();
    for (;;)
    {
      int save = p_;
      if (!toplevel(prog))
      {
        p_ = save;
        break;
      }
      ws();
      gap();
      ws();
      furthest_ = std::max(furthest_, p_);
      ws();
    }
    ws();
    return p_ == n_ ? prog : nullptr;
  }

  // rule toplevel
  // {
  //      <userfunc> || <function> || <classdecl> || <interfacedecl> || <methodimpl> || <wsmethodimpl>
  //   || [ [ <usercmd> || <preproc> || <namespacest> || <externalst> || <filestatic> || <wsblock>
  //        || <cmdst> || <annotation> ] <.eol> ]
  //   || [ <?{ user-active() }> <datadecl> <.eol> ]
  // }
  bool Parser::toplevel(Program* prog)
  {
    int start = p_;
    if (user_on_)
    {
      if (MethodImpl* m = userfunc())
      {
        if (ws())
        {
          prog->methods.push_back(m);
          return true;
        }
        p_ = start;
      }
    }
    if (FunctionDef* f = function())
    {
      if (ws())
      {
        prog->functions.push_back(f);
        return true;
      }
      p_ = start;
    }
    for (bool iface : { false, true })
    {
      if (ClassDef* cls = classdecl(iface))
      {
        if (ws())
        {
          prog->classes.push_back(cls);
          return true;
        }
        p_ = start;
      }
    }
    if (MethodImpl* m = methodimpl())
    {
      if (ws())
      {
        prog->methods.push_back(m);
        return true;
      }
      p_ = start;
    }
    if (MethodImpl* m = wsmethodimpl())
    {
      if (ws())
      {
        prog->methods.push_back(m);
        return true;
      }
      p_ = start;
    }

    // One line: what it makes goes in only once its line has ended.
    Program one;
    bool any = false;
    if (user_on_)
    {
      int e = usercmd(false);
      if (e > 0)
      {
        p_ = e;
        any = ws();
        if (!any)
        {
          p_ = start;
        }
      }
    }
    if (!any)
    {
      int e = preproc();
      if (e >= 0)
      {
        p_ = e;
        if (ws())
        {
          one.directives.push_back(trim(src_.substr(start, e - start)));
          any = true;
        }
        else
        {
          p_ = start;
        }
      }
    }
    if (!any)
    {
      if (namespacest(&one))
      {
        any = ws();
      }
      if (!any)
      {
        p_ = start;
        one.ns.reset();
        one.usings.clear();
      }
    }
    if (!any)
    {
      if (External* x = externalst())
      {
        if (ws())
        {
          one.externals.push_back(x);
          any = true;
        }
        else
        {
          p_ = start;
        }
      }
    }
    if (!any)
    {
      if (Declaration* d = filestatic())
      {
        if (ws())
        {
          one.statics.push_back(d);
          any = true;
        }
        else
        {
          p_ = start;
        }
      }
    }
    if (!any)
    {
      int e = wsblock();
      if (e >= 0)
      {
        p_ = e;
        any = ws();
        if (!any)
        {
          p_ = start;
        }
      }
    }
    if (!any)
    {
      int e = annotationdef();
      if (e >= 0)
      {
        p_ = e;
        any = ws();
        if (!any)
        {
          p_ = start;
        }
      }
    }
    if (!any)
    {
      if (cmdst())
      {
        any = ws();
        if (!any)
        {
          p_ = start;
        }
      }
    }
    if (!any)
    {
      if (Annotation* a = annotation())
      {
        if (ws())
        {
          one.annotations.push_back(a);
          any = true;
        }
        else
        {
          p_ = start;
        }
      }
    }
    if (any && eol(true) && ws())
    {
      if (one.ns)
      {
        prog->ns = one.ns;
      }
      prog->usings.insert(prog->usings.end(), one.usings.begin(), one.usings.end());
      prog->directives.insert(prog->directives.end(), one.directives.begin(), one.directives.end());
      prog->externals.insert(prog->externals.end(), one.externals.begin(), one.externals.end());
      prog->statics.insert(prog->statics.end(), one.statics.begin(), one.statics.end());
      prog->annotations.insert(prog->annotations.end(), one.annotations.begin(), one.annotations.end());
      return true;
    }
    p_ = start;
    if (user_on_)
    {
      std::vector<DataMember*> dropped;
      if (datadecl(&dropped) && eol(true) && ws())
      {
        return true;
      }
      p_ = start;
    }
    return false;
  }

  // rule function
  // {
  //   [ <annotation> <.nl> ]*
  //   <funckind> <name> [ '(' ~ ')' <params> ]? <rettype>? <.nl>
  //   <funcbody>
  // }
  // token funckind { :i [ [ 'user' || 'static' || 'main' ] \s+ ]? 'function' }
  FunctionDef* Parser::function()
  {
    int start = p_;
    auto f = make<FunctionDef>();
    for (;;)
    {
      int save = p_;
      Annotation* a = annotation();
      if (!a || !ws() || !nl() || !ws())
      {
        p_ = save;
        break;
      }
      f->annotations.push_back(a);
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    int kind = p_;
    for (std::string_view w : { "user", "static", "main", "web", "html" })
    {
      int save = p_;
      if (ilit(w) && is_s(c(p_)))
      {
        while (is_s(c(p_)))
        {
          p_++;
        }
        f->type = w;
        break;
      }
      p_ = save;
    }
    if (!ilit("function") || !ws())
    {
      p_ = start;
      return nullptr;
    }
    f->line = line(kind);
    int e = 0;
    f->name = name_text(e);
    if (e < 0)
    {
      p_ = start;
      return nullptr;
    }
    p_ = e;
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    if (c(p_) == '(')
    {
      int save = p_;
      p_++;
      bool ok = false;
      if (ws())
      {
        std::vector<Param*> ps = params();
        if (c(p_) == ')')
        {
          p_++;
          if (ws())
          {
            f->params = std::move(ps);
            ok = true;
          }
        }
      }
      if (!ok)
      {
        p_ = save;
      }
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    {
      int save = p_;
      int from = 0;
      std::string tn;
      if (typespec(from, tn))
      {
        f->rettype_word = tn;
      }
      else
      {
        p_ = save;
      }
    }
    if (!ws() || !nl() || !ws())
    {
      p_ = start;
      return nullptr;
    }
    f->body = funcbody();
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    return f;
  }

  // rule params { <param>? [ ',' <param>? ]* }
  std::vector<Param*> Parser::params()
  {
    std::vector<Param*> out;
    if (Param* p = param())
    {
      out.push_back(p);
    }
    ws();
    for (;;)
    {
      int save = p_;
      if (c(p_) != ',')
      {
        break;
      }
      p_++;
      if (!ws())
      {
        p_ = save;
        break;
      }
      int at = p_;
      if (Param* p = param())
      {
        out.push_back(p);
      }
      else
      {
        p_ = at;
      }
      if (!ws())
      {
        p_ = save;
        break;
      }
    }
    ws();
    return out;
  }

  // rule param { <name> <!{ refused(~$<name>) }> <attrs>? <typespec>? }
  Param* Parser::param()
  {
    int start = p_;
    int e = 0;
    std::string name = name_text(e);
    if (e < 0)
    {
      return nullptr;
    }
    p_ = e;
    if (!ws() || refused(name) || !ws())
    {
      p_ = start;
      return nullptr;
    }
    auto p = make<Param>();
    p->name = name;
    p->declared = "?";
    int ae = attrs(p_);
    if (ae >= 0)
    {
      p->attributes = attr_words(src_.substr(p_, ae - p_));
      p->attrs_from = e;
      p->attrs_to = ae;
      p_ = ae;
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    int save = p_;
    int from = 0;
    std::string tn;
    if (typespec(from, tn))
    {
      p->declared = type_of_name(tn);
      p->type_word = tn;
    }
    else
    {
      p_ = save;
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    return p;
  }

  // rule classdecl
  // {
  //   :i 'class' <cname=name> [ :i [ 'from' || 'inherit' ] <supers=dottedname>+ % ',' ]?
  //      [ :i 'implements' <ifaces=dottedname>+ % ',' ]? <.nl>
  //   [ <classmember> <.nl> ]*
  //   :i [ 'endclass' || 'end' 'class' ]
  // }
  // rule interfacedecl
  // {
  //   :i 'interface' <cname=name> <.nl>
  //   [ <classmember> <.nl> ]*
  //   :i [ 'endinterface' || 'end' 'interface' ]
  // }
  ClassDef* Parser::classdecl(bool iface)
  {
    int start = p_;
    auto fail = [&]() -> ClassDef* { p_ = start; return nullptr; };
    if (!ilit(iface ? "interface" : "class") || !ws())
    {
      return fail();
    }
    auto cls = make<ClassDef>();
    cls->line = line(start);
    cls->iface = iface;
    int e = 0;
    cls->name = name_text(e);
    if (e < 0)
    {
      return fail();
    }
    p_ = e;
    if (!ws())
    {
      return fail();
    }
    // A dotted name, then more after ',' -- each '%' separator with its
    // whitespace, the term without.
    auto dotted = [&](std::vector<std::string>* out) -> bool
    {
      auto one = [&]() -> int
      {
        int q = name_end(p_);
        if (q < 0)
        {
          return -1;
        }
        while (c(q) == '.')
        {
          int r = name_end(q + 1);
          if (r < 0)
          {
            break;
          }
          q = r;
        }
        return q;
      };
      int q = one();
      if (q < 0)
      {
        return false;
      }
      if (out) { out->push_back(text(p_, q)); }
      p_ = q;
      for (;;)
      {
        int save = p_;
        if (c(p_) != ',')
        {
          break;
        }
        p_++;
        if (!ws())
        {
          p_ = save;
          break;
        }
        int r = one();
        if (r < 0)
        {
          p_ = save;
          break;
        }
        if (out) { out->push_back(text(p_, r)); }
        p_ = r;
      }
      return ws();
    };
    if (!iface)
    {
      int save = p_;
      bool ok = false;
      std::vector<std::string> supers;
      if ((ilit("from") && ws()) || (p_ = save, ilit("inherit") && ws()))
      {
        if (ws() && dotted(&supers) && ws())
        {
          ok = true;
        }
      }
      if (ok)
      {
        cls->supers = std::move(supers);
      }
      else
      {
        p_ = save;
      }
      if (!ws())
      {
        return fail();
      }
      save = p_;
      if (!(ilit("implements") && ws() && dotted(nullptr) && ws()))
      {
        p_ = save;
      }
      if (!ws())
      {
        return fail();
      }
    }
    if (!nl() || !ws())
    {
      return fail();
    }
    for (;;)
    {
      int save = p_;
      if (!classmember(cls, iface) || !ws() || !nl() || !ws())
      {
        p_ = save;
        break;
      }
    }
    if (!ws())
    {
      return fail();
    }
    int save = p_;
    bool closed = ilit(iface ? "endinterface" : "endclass") && ws();
    if (!closed)
    {
      p_ = save;
      closed = ilit("end") && ws() && ilit(iface ? "interface" : "class") && ws();
    }
    if (!closed || !ws())
    {
      return fail();
    }
    return cls;
  }

  // rule classmember { [ <annotation> <.nl> ]* [ <datadecl> || <methdecl> ] }
  // rule methdecl { [ <visib> || <mstatic> ]* :i [ 'method' || 'operator' ] <mname=name>
  //                 [ '(' ~ ')' <params> ]? <methtag>* }
  // rule methtag  { :i 'constructor' || [ :i 'as' <ret=name> ] }
  // A class's member, or a method's signature, into cls; an interface keeps
  // only its signatures.
  bool Parser::classmember(ClassDef* cls, bool iface)
  {
    int start = p_;
    for (;;)
    {
      int save = p_;
      if (!annotation() || !ws() || !nl() || !ws())
      {
        p_ = save;
        break;
      }
    }
    if (!ws())
    {
      p_ = start;
      return false;
    }
    int at = p_;
    std::vector<DataMember*> members;
    if (datadecl(&members) && ws())
    {
      if (!iface)
      {
        cls->members.insert(cls->members.end(), members.begin(), members.end());
      }
      if (!ws())
      {
        p_ = start;
        return false;
      }
      return true;
    }
    p_ = at;
    auto m = make<MethodSig>();
    std::vector<std::string> vis;
    for (;;)
    {
      int save = p_;
      int vf = p_;
      OptStr v = visib();
      if (v)
      {
        vis.push_back(text(vf, p_));
        if (ws())
        {
          continue;
        }
        p_ = save;
        break;
      }
      p_ = save;
      if (ilit("static") && word_end() && ws())
      {
        m->is_static = true;
        continue;
      }
      p_ = save;
      break;
    }
    if (!ws())
    {
      p_ = start;
      return false;
    }
    int save = p_;
    if (!((ilit("method") && ws()) || (p_ = save, ilit("operator") && ws())) || !ws())
    {
      p_ = start;
      return false;
    }
    int e = 0;
    m->name = name_text(e);
    if (e < 0)
    {
      p_ = start;
      return false;
    }
    p_ = e;
    if (!ws())
    {
      p_ = start;
      return false;
    }
    // Without parentheses the Raku actions read the parameters of no match:
    // one, undefined.
    m->params = { nullptr };
    if (c(p_) == '(')
    {
      int s2 = p_;
      p_++;
      bool ok = false;
      if (ws())
      {
        std::vector<Param*> ps = params();
        if (c(p_) == ')')
        {
          p_++;
          if (ws())
          {
            m->params = std::move(ps);
            ok = true;
          }
        }
      }
      if (!ok)
      {
        p_ = s2;
      }
    }
    if (!ws())
    {
      p_ = start;
      return false;
    }
    for (;;)
    {
      int s3 = p_;
      if (ilit("constructor") && ws())
      {
        if (ws())
        {
          m->constructor = true;
          continue;
        }
      }
      p_ = s3;
      if (ilit("as") && ws())
      {
        int re = 0;
        std::string ret = name_text(re);
        if (re >= 0)
        {
          p_ = re;
          if (ws() && ws())
          {
            m->returns = ret;
            continue;
          }
        }
      }
      p_ = s3;
      break;
    }
    if (!ws() || !ws())
    {
      p_ = start;
      return false;
    }
    if (!vis.empty())
    {
      std::string all;
      for (std::size_t i = 0; i < vis.size(); i++)
      {
        if (i) { all += ' '; }
        all += vis[i];
      }
      m->visibility = lc(trim(all));
    }
    cls->methods.push_back(m);
    return true;
  }

  // rule visib { :i [ 'public' || 'protected' || 'private' || 'exported' || 'hidden' ] }
  OptStr Parser::visib()
  {
    int start = p_;
    for (std::string_view w : { "public", "protected", "private", "exported", "hidden" })
    {
      if (ilit(w))
      {
        if (ws() && ws())
        {
          return lc(trim(src_.substr(start, p_ - start)));
        }
        break;
      }
    }
    p_ = start;
    return std::nullopt;
  }

  // rule datadecl { <visib>? :i 'data' <datavar>+ % ',' }
  // rule datavar  { <dname=name> [ :i 'as' <dtype=name> ]? [ :i [ 'default' || 'init' ] <datadefault> ]? }
  // token datadefault { <guardexpr> }
  bool Parser::datadecl(std::vector<DataMember*>* out)
  {
    int start = p_;
    OptStr vis = visib();
    if (!ws() || !ilit("data") || !ws())
    {
      p_ = start;
      return false;
    }
    auto datavar = [&]() -> DataMember*
    {
      int s = p_;
      int e = 0;
      std::string name = name_text(e);
      if (e < 0)
      {
        return nullptr;
      }
      p_ = e;
      if (!ws())
      {
        p_ = s;
        return nullptr;
      }
      auto m = make<DataMember>();
      m->name = name;
      m->visibility = vis;
      m->line = line(s);
      int save = p_;
      if (ilit("as") && ws())
      {
        int te = 0;
        std::string t = name_text(te);
        if (te >= 0)
        {
          p_ = te;
          if (ws())
          {
            m->type = t;
          }
          else
          {
            p_ = save;
          }
        }
        else
        {
          p_ = save;
        }
      }
      else
      {
        p_ = save;
      }
      if (!ws())
      {
        p_ = s;
        return nullptr;
      }
      save = p_;
      bool kw = (ilit("default") && ws()) || (p_ = save, ilit("init") && ws());
      Expr* value = kw && ws() ? guardexpr() : nullptr;
      if (value && ws())
      {
        m->init = value;
      }
      else
      {
        p_ = save;
      }
      if (!ws())
      {
        p_ = s;
        return nullptr;
      }
      return m;
    };
    DataMember* first = datavar();
    if (!first)
    {
      p_ = start;
      return false;
    }
    std::vector<DataMember*> all = { first };
    for (;;)
    {
      int save = p_;
      if (c(p_) != ',')
      {
        break;
      }
      p_++;
      DataMember* m = ws() ? datavar() : nullptr;
      if (!m)
      {
        p_ = save;
        break;
      }
      all.push_back(m);
    }
    if (!ws())
    {
      p_ = start;
      return false;
    }
    if (out)
    {
      out->insert(out->end(), all.begin(), all.end());
    }
    return true;
  }

  // rule methodimpl
  // {
  //   [ <annotation> <.nl> ]*
  //   :i [ 'method' || 'operator' ] <mname=name> '(' ~ ')' <params>
  //      [ :i 'as' <ret=name> ]?
  //      :i 'class' <cname=name>
  //      [ :i 'as' <retafter=name> ]? <.nl>
  //   <funcbody>
  // }
  MethodImpl* Parser::methodimpl()
  {
    int start = p_;
    auto fail = [&]() -> MethodImpl* { p_ = start; return nullptr; };
    for (;;)
    {
      int save = p_;
      if (!annotation() || !ws() || !nl() || !ws())
      {
        p_ = save;
        break;
      }
    }
    if (!ws())
    {
      return fail();
    }
    int save = p_;
    if (!((ilit("method") && ws()) || (p_ = save, ilit("operator") && ws())) || !ws())
    {
      return fail();
    }
    auto m = make<MethodImpl>();
    m->line = line(start);
    int e = 0;
    m->name = name_text(e);
    if (e < 0)
    {
      return fail();
    }
    p_ = e;
    if (!ws() || c(p_) != '(')
    {
      return fail();
    }
    p_++;
    if (!ws())
    {
      return fail();
    }
    m->params = params();
    if (c(p_) != ')')
    {
      return fail();
    }
    p_++;
    if (!ws())
    {
      return fail();
    }
    // [ :i 'as' <name> ]?
    auto as_name = [&]() -> OptStr
    {
      int s = p_;
      if (ilit("as") && ws())
      {
        int re = 0;
        std::string r = name_text(re);
        if (re >= 0)
        {
          p_ = re;
          if (ws())
          {
            return r;
          }
        }
      }
      p_ = s;
      return std::nullopt;
    };
    OptStr ret = as_name();
    if (!ws() || !ilit("class") || !ws())
    {
      return fail();
    }
    m->class_name = name_text(e);
    if (e < 0)
    {
      return fail();
    }
    p_ = e;
    if (!ws())
    {
      return fail();
    }
    OptStr after = as_name();
    if (!ws() || !nl() || !ws())
    {
      return fail();
    }
    m->returns = ret ? ret : after;
    m->body = funcbody();
    if (!ws())
    {
      return fail();
    }
    return m;
  }

  // rule wsmethodimpl { <wshead> <.nl> <funcbody> }
  // token wshead
  // {
  //   :i 'wsmethod' <!ww> [ \N*? ';' \h* \v ]* \N*? <!ww> [ 'wsservice' || 'wsrestful' || 'wsrest' ] \h+ <svc=name>
  //   <?before \h* [ <.linecomment> || \v || $ ]>
  // }
  MethodImpl* Parser::wsmethodimpl()
  {
    int start = p_;
    if (!ilit("wsmethod") || !not_within_word())
    {
      p_ = start;
      return nullptr;
    }
    // The lines a ';' carries the header on to; on the last one, the first
    // place the service is named, at the end of the line.
    int p = p_;
    for (;;)
    {
      int e = p;
      while (is_nn(c(e)))
      {
        e++;
      }
      int k = e;
      while (k > p && is_h(c(k - 1)))
      {
        k--;
      }
      if (k > p && c(k - 1) == ';' && vchar(e))
      {
        p = e + vchar(e);
        continue;
      }
      break;
    }
    // On the last line, the first place where the service is named and the
    // line ends -- '\N*?' takes no more than it must.
    int svc_from = -1;
    int svc_to = -1;
    for (int q = p; svc_from < 0; q++)
    {
      p_ = q;
      if (not_within_word())
      {
        int k = -1;
        for (std::string_view w : { "wsservice", "wsrestful", "wsrest" })
        {
          if (iword_at(q, w))
          {
            k = q + static_cast<int>(w.size());
            break;
          }
        }
        if (k >= 0 && is_h(c(k)))
        {
          while (is_h(c(k)))
          {
            k++;
          }
          int ne = name_end(k);
          if (ne >= 0)
          {
            int r = ne;
            while (is_h(c(r)))
            {
              r++;
            }
            if (linecomment(r) >= 0 || vchar(r) || r == n_)
            {
              svc_from = k;
              svc_to = ne;
              p_ = ne;
              break;
            }
          }
        }
      }
      if (!is_nn(c(q)))
      {
        break;
      }
    }
    int head_end = p_;
    if (!ws() || !nl() || !ws())
    {
      p_ = start;
      return nullptr;
    }
    auto m = make<MethodImpl>();
    m->line = line(start);
    m->class_name = text(svc_from, svc_to);
    m->ws = true;
    std::vector<std::string> w = words(src_.substr(start, head_end - start));
    m->name = w.size() > 1 ? w[1] : "wsmethod";
    m->body = funcbody();
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    return m;
  }

  // rule userfunc { <userhead> <.nl> <funcbody> }
  MethodImpl* Parser::userfunc()
  {
    int start = p_;
    int e = usercmd(true);
    if (e <= 0)
    {
      return nullptr;
    }
    p_ = e;
    if (!ws() || !nl() || !ws())
    {
      p_ = start;
      return nullptr;
    }
    auto m = make<MethodImpl>();
    m->line = line(start);
    std::vector<std::string> w = words(src_.substr(start, e - start));
    m->name = w.empty() ? "command" : w[0];
    m->body = funcbody();
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    return m;
  }

  // token usercmd / userhead: a use of the source's own commands at the
  // cursor, of the kind asked -- where it ends, or 0.
  int Parser::usercmd(bool header)
  {
    if (!user_on_)
    {
      return 0;
    }
    auto it = cmd_.find(p_);
    if (it == cmd_.end() || it->second.header != header || it->second.end <= p_)
    {
      return 0;
    }
    return it->second.end;
  }

  // token preproc { '#' [ \N*? ';' \h* \n ]* \N* }: where it ends, or -1.
  int Parser::preproc()
  {
    if (c(p_) != '#')
    {
      return -1;
    }
    return continued_line(p_ + 1, true);
  }

  // rule namespacest { :i [ 'using' 'namespace' || 'namespace' ] <dottedname> }
  bool Parser::namespacest(Program* prog)
  {
    int start = p_;
    bool used = ilit("using") && ws() && ilit("namespace") && ws();
    if (!used)
    {
      p_ = start;
      if (!(ilit("namespace") && ws()))
      {
        p_ = start;
        return false;
      }
    }
    if (!ws())
    {
      p_ = start;
      return false;
    }
    int q = name_end(p_);
    if (q < 0)
    {
      p_ = start;
      return false;
    }
    while (c(q) == '.')
    {
      int r = name_end(q + 1);
      if (r < 0)
      {
        break;
      }
      q = r;
    }
    std::string name = text(p_, q);
    p_ = q;
    if (!ws())
    {
      p_ = start;
      return false;
    }
    if (used)
    {
      prog->usings.push_back(name);
    }
    else
    {
      prog->ns = name;
    }
    return true;
  }

  // rule externalst { :i 'external' [ <isalias=kwalias> ]? <xname> [ ',' <xname> ]* }
  // token kwalias   { :i 'alias' >> }
  // token xname     { <!before <.kwalias>> <name> }
  External* Parser::externalst()
  {
    int start = p_;
    if (!ilit("external") || !ws())
    {
      p_ = start;
      return nullptr;
    }
    auto x = make<External>();
    x->line = line(start);
    auto kwalias = [&](int p) { return iword_at(p, "alias") && !is_w(c(p + 5)); };
    int save = p_;
    if (kwalias(p_))
    {
      p_ += 5;
      if (ws())
      {
        x->alias = true;
      }
      else
      {
        p_ = save;
      }
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    auto xname = [&]() -> bool
    {
      if (kwalias(p_))
      {
        return false;
      }
      int e = name_end(p_);
      if (e < 0)
      {
        return false;
      }
      x->names.push_back(text(p_, e));
      p_ = e;
      return true;
    };
    if (!xname() || !ws())
    {
      p_ = start;
      return nullptr;
    }
    for (;;)
    {
      int s = p_;
      std::size_t had = x->names.size();
      if (c(p_) == ',' && (p_++, ws()) && xname() && ws())
      {
        continue;
      }
      x->names.resize(had);
      p_ = s;
      break;
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    x->from = start;
    x->to = p_;
    return x;
  }

  // rule filestatic { :i 'static'>> <!before \s+ <.kwfunction> > <declarator>+ % ',' }
  Declaration* Parser::filestatic()
  {
    int start = p_;
    if (!ilit("static") || !word_end() || !ws())
    {
      p_ = start;
      return nullptr;
    }
    {
      int q = p_;
      if (is_s(c(q)))
      {
        while (is_s(c(q)))
        {
          q++;
        }
        if (iword_at(q, "function") && !is_w(c(q + 8)))
        {
          p_ = start;
          return nullptr;
        }
      }
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    auto d = make<Declaration>();
    d->scope = "static";
    d->line = line(start);
    Declarator* first = declarator(false);
    if (!first)
    {
      p_ = start;
      return nullptr;
    }
    d->declarators.push_back(first);
    for (;;)
    {
      int s = p_;
      if (c(p_) != ',')
      {
        break;
      }
      p_++;
      Declarator* x = ws() ? declarator(false) : nullptr;
      if (!x)
      {
        p_ = s;
        break;
      }
      d->declarators.push_back(x);
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    return d;
  }

  // token wsblock
  // {
  //   :i [ 'wsrestful' || 'wsservice' || 'wsstruct' || 'wsclient' ] <!ww> \N* \v
  //   [ <!before \h* <.wsend> > \N* \v ]*
  //   \h* <.wsend> \N*
  // }
  // token wsend { :i 'end' \h* [ 'wsrestful' || 'wsservice' || 'wsstruct' || 'wsclient' ] <!ww> }
  // Where it ends, or -1.
  int Parser::wsblock()
  {
    static const std::string_view kinds[] = { "wsrestful", "wsservice", "wsstruct", "wsclient" };
    int start = p_;
    auto kind_at = [&](int p) -> int
    {
      for (std::string_view k : kinds)
      {
        if (iword_at(p, k))
        {
          int q = p + static_cast<int>(k.size());
          if (!(is_w(c(q - 1)) && is_w(c(q))))
          {
            return q;
          }
          return -1;
        }
      }
      return -1;
    };
    auto wsend = [&](int p) -> int
    {
      if (!iword_at(p, "end"))
      {
        return -1;
      }
      int q = p + 3;
      while (is_h(c(q)))
      {
        q++;
      }
      return kind_at(q);
    };
    int q = kind_at(start);
    if (q < 0)
    {
      return -1;
    }
    auto line_rest = [&](int p) -> int
    {
      while (is_nn(c(p)))
      {
        p++;
      }
      return p;
    };
    q = line_rest(q);
    int v = vchar(q);
    if (!v)
    {
      return -1;
    }
    q += v;
    for (;;)
    {
      int h = q;
      while (is_h(c(h)))
      {
        h++;
      }
      int e = wsend(h);
      if (e >= 0)
      {
        return line_rest(e);
      }
      int r = line_rest(q);
      int rv = vchar(r);
      if (!rv)
      {
        return -1;
      }
      q = r + rv;
    }
  }

  // TL++'s annotation of the file's own, taken whole, as written:
  //   '@' :i 'annotation' <!ww> \N* \v [ <!before \h* '@' :i 'end' <!ww>> \N* \v ]*
  //   \h* '@' :i 'end' <!ww> \N*
  // Where it ends, or -1.
  int Parser::annotationdef()
  {
    auto at_word = [&](int p, std::string_view w) -> int
    {
      if (c(p) != '@' || !iword_at(p + 1, w))
      {
        return -1;
      }
      int q = p + 1 + static_cast<int>(w.size());
      return is_w(c(q)) ? -1 : q;
    };
    auto line_rest = [&](int p) -> int
    {
      while (is_nn(c(p)))
      {
        p++;
      }
      return p;
    };
    int q = at_word(p_, "annotation");
    if (q < 0)
    {
      return -1;
    }
    q = line_rest(q);
    for (;;)
    {
      int v = vchar(q);
      if (!v)
      {
        return -1;
      }
      q += v;
      int h = q;
      while (is_h(c(h)))
      {
        h++;
      }
      int e = at_word(h, "end");
      if (e >= 0)
      {
        return line_rest(e);
      }
      q = line_rest(q);
    }
  }

  // rule annotation { '@' <name> [ '(' ~ ')' <arglist> ]? }
  Annotation* Parser::annotation()
  {
    int start = p_;
    if (c(p_) != '@')
    {
      return nullptr;
    }
    p_++;
    int e = 0;
    std::string name;
    if (!ws() || (name = name_text(e), e < 0))
    {
      p_ = start;
      return nullptr;
    }
    p_ = e;
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    auto a = make<Annotation>();
    a->name = name;
    a->line = line(start);
    if (c(p_) == '(')
    {
      int save = p_;
      p_++;
      bool ok = false;
      if (ws())
      {
        std::vector<Expr*> args = arglist();
        if (c(p_) == ')')
        {
          p_++;
          if (ws())
          {
            a->args = std::move(args);
            ok = true;
          }
        }
      }
      if (!ok)
      {
        p_ = save;
      }
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    return a;
  }

  // ---- bodies ---------------------------------------------------------------
  // rule funcbody   { prologue open,  top level: [ <statement> <.nl> ]* }
  // rule body       { prologue open,  a block's: [ <statement> <.nl> ]* }
  // rule closedbody { prologue closed:           [ <statement> <.nl> ]* }
  // rule withbody   { as body, with the subject in reach }
  Body Parser::funcbody()
  {
    bool past = past_prologue_;
    bool top = top_level_;
    past_prologue_ = false;
    top_level_ = true;
    Body out;
    for (;;)
    {
      int save = p_;
      Stmt* s = statement();
      if (!s || !ws() || !nl() || !ws())
      {
        p_ = save;
        break;
      }
      out.push_back(s);
    }
    ws();
    past_prologue_ = past;
    top_level_ = top;
    return out;
  }

  Body Parser::body(bool closed, bool with)
  {
    bool past = past_prologue_;
    bool top = top_level_;
    bool was_with = in_with_;
    past_prologue_ = closed;
    top_level_ = false;
    if (with)
    {
      in_with_ = true;
    }
    Body out;
    for (;;)
    {
      int save = p_;
      Stmt* s = statement();
      if (!s || !ws() || !nl() || !ws())
      {
        p_ = save;
        break;
      }
      out.push_back(s);
    }
    ws();
    past_prologue_ = past;
    top_level_ = top;
    in_with_ = was_with;
    return out;
  }

  // ---- statements -----------------------------------------------------------
  // rule statement
  // {
  //   [
  //      [<?{ $user-on }><usercmd>]
  //   || [ <?before <.stmtstart>>
  //        [ <cmdst> || <dirst> || [ <annotation> <?before <.eol>> ] || <seqst> || <tryst> || <transst>
  //        || [ <.declsoon> <declaration> ] || <ifcallst> || <ifst> || <whilest> || <forst> || <forinst>
  //        || <fortimesst> || <docasest> || <execst> || <deferst> || <usingst> || <withst> || <rawst>
  //        || <noopst> ] ]
  //   || [ <simple> [<?[iIwW]><modifier>]? ]
  //   ]
  //   { $*PAST-PROLOGUE = True unless $<declaration> }
  // }
  Stmt* Parser::statement()
  {
    int start = p_;
    Stmt* node = nullptr;
    bool decl = false;
    if (user_on_)
    {
      int e = usercmd(false);
      if (e > 0)
      {
        p_ = e;
        if (ws())
        {
          auto r = make<RawStmt>();
          r->lines.push_back(text(start, e));
          r->line = line(start);
          node = r;
        }
        else
        {
          p_ = start;
        }
      }
    }
    if (!node && stmtstart())
    {
      using Rule = Stmt* (Parser::*)();
      static const Rule rules[] =
      {
        &Parser::cmdst, &Parser::dirst, nullptr, &Parser::seqst, &Parser::tryst, &Parser::transst,
        nullptr, &Parser::ifcallst, &Parser::ifst, &Parser::whilest, &Parser::forst, &Parser::forinst,
        &Parser::fortimesst, &Parser::docasest, &Parser::execst, &Parser::deferst, &Parser::usingst,
        &Parser::withst, &Parser::rawst, &Parser::noopst,
      };
      for (std::size_t i = 0; i < std::size(rules) && !node; i++)
      {
        Stmt* s = nullptr;
        if (i == 2)
        {
          // An annotation is the whole line: '@oJSON := x' is an assignment.
          if (Annotation* a = annotation())
          {
            if (eol(false) && ws())
            {
              s = a;
            }
          }
        }
        else if (i == 6)
        {
          if (declsoon())
          {
            s = declaration();
            decl = s != nullptr;
          }
        }
        else
        {
          s = (this->*rules[i])();
        }
        if (s && ws() && ws())
        {
          node = s;
        }
        else
        {
          decl = false;
          p_ = start;
        }
      }
    }
    if (!node)
    {
      Stmt* s = simple();
      if (s && ws())
      {
        // The inner statement of a modifier has a span of its own.
        s->from = start;
        s->to = p_;
        node = s;
        int at = p_;
        int ch = lower(c(p_));
        std::string op;
        Expr* cond = nullptr;
        if ((ch == 'i' || ch == 'w') && modifier(op, cond))
        {
          auto m = make<Modified>();
          m->stmt = s;
          m->op = op;
          m->cond = cond;
          m->line = line(start);
          node = m;
        }
        else
        {
          p_ = at;
        }
        if (!ws())
        {
          node = nullptr;
          p_ = start;
        }
      }
      else
      {
        p_ = start;
      }
    }
    if (!node || !ws() || !ws())
    {
      p_ = start;
      return nullptr;
    }
    if (!decl)
    {
      past_prologue_ = true;
    }
    node->from = start;
    node->to = p_;
    return node;
  }

  // token stmtstart { [ (<[A..Za..z_]> \w*) <?{ STMT-WORDS{(~$0).lc}:exists }> ] || <[@#]> }
  bool Parser::stmtstart() const
  {
    int e = name_end(p_);
    if (e >= 0 && STMT_WORDS.count(lc(src_.substr(p_, e - p_))))
    {
      return true;
    }
    return c(p_) == '@' || c(p_) == '#';
  }

  // token simpleword { (<[A..Za..z_]> \w*) <?{ SIMPLE-WORDS{(~$0).lc}:exists }> }
  bool Parser::simpleword() const
  {
    int e = name_end(p_);
    return e >= 0 && SIMPLE_WORDS.count(lc(src_.substr(p_, e - p_)));
  }

  // token declsoon: the prologue is not over, or what follows is a
  // 'private', 'public' or 'static' -- a declaration that may come after it.
  bool Parser::declsoon() const
  {
    if (!past_prologue_)
    {
      return true;
    }
    int q = p_;
    while (c(q) == ' ' || c(q) == '\t')
    {
      q++;
    }
    for (std::string_view w : { "private", "public", "static" })
    {
      if (iword_at(q, w))
      {
        int k = c(q + static_cast<int>(w.size()));
        return !((k >= '0' && k <= '9') || is_alpha(k));
      }
    }
    return false;
  }

  // rule simple
  // {
  //      [ <?before <.simpleword>> [ <returnst> || <exitst> || <loopst> || <breakst> || <defaultst> ] ]
  //   || [ <.sees('assign')> [ <assignment> || <nilassign> ] ]
  //   || [ <.sees('pipe')> <pipest> ]
  //   || <incst>
  //   || <callst>
  // }
  Stmt* Parser::simple()
  {
    int start = p_;
    if (simpleword())
    {
      if (Stmt* s = returnst())
      {
        if (ws()) { return s; }
        p_ = start;
      }
      int sl = p_;
      if (ilit("exit") && ws())
      {
        if (ws())
        {
          auto x = make<ExitStmt>();
          x->line = line(sl);
          return x;
        }
      }
      p_ = start;
      if (ilit("loop") && ws())
      {
        if (ws())
        {
          auto x = make<LoopStmt>();
          x->line = line(sl);
          return x;
        }
      }
      p_ = start;
      if (Stmt* s = breakst())
      {
        if (ws()) { return s; }
        p_ = start;
      }
      if (Stmt* s = defaultst())
      {
        if (ws()) { return s; }
        p_ = start;
      }
    }
    if (sees(Ahead::Assign, false))
    {
      if (Stmt* s = assign_stmt())
      {
        if (ws()) { return s; }
        p_ = start;
      }
      if (Stmt* s = nilassign())
      {
        if (ws()) { return s; }
        p_ = start;
      }
    }
    if (sees(Ahead::Pipe, false))
    {
      if (Expr* e = pipest())
      {
        auto cs = make<CallStmt>();
        cs->call = e;
        cs->line = line(start);
        if (ws()) { return cs; }
        p_ = start;
      }
    }
    if (Stmt* s = incst())
    {
      if (ws()) { return s; }
      p_ = start;
    }
    if (Expr* e = callst())
    {
      auto cs = make<CallStmt>();
      cs->call = e;
      cs->line = line(start);
      if (ws()) { return cs; }
      p_ = start;
    }
    p_ = start;
    return nullptr;
  }

  // rule assignment, as a statement.
  Stmt* Parser::assign_stmt()
  {
    int start = p_;
    Assign a;
    if (!assignment(a))
    {
      return nullptr;
    }
    auto s = make<Assignment>();
    s->target = a.target;
    s->op = a.op;
    s->value = a.value;
    s->line = line(start);
    return s;
  }

  // rule modifier { <kw=modkw> <cond> }
  // token modkw   { :i [ 'if' || 'while' ] >> }
  int Parser::modkw(int p) const
  {
    if (iword_at(p, "if") && !is_w(c(p + 2)))
    {
      return p + 2;
    }
    if (iword_at(p, "while") && !is_w(c(p + 5)))
    {
      return p + 5;
    }
    return -1;
  }

  // Whether 'if' at p is AdvPL's If(), called -- 'Return If(lOk, 1, 2)': its
  // parentheses hold a comma of their own -- and not the modifier, 'return
  // if lSkip', which a condition follows.
  bool Parser::if_call(int p) const
  {
    if (!iword_at(p, "if") || is_w(c(p + 2)))
    {
      return false;
    }
    int q = p + 2;
    while (is_h(c(q)))
    {
      q++;
    }
    if (c(q) != '(')
    {
      return false;
    }
    int depth = 0;
    for (; q < n_; q++)
    {
      int ch = c(q);
      if (ch == '"' || ch == '\'')
      {
        int e = q + 1;
        while (e < n_ && c(e) != ch && c(e) != '\n')
        {
          e++;
        }
        if (c(e) != ch)
        {
          return false;
        }
        q = e;
      }
      else if (ch == '(' || ch == '[' || ch == '{')
      {
        depth++;
      }
      else if (ch == ')' || ch == ']' || ch == '}')
      {
        if (--depth == 0)
        {
          return false;
        }
      }
      else if (ch == ',' && depth == 1)
      {
        return true;
      }
      else if (ch == '\n')
      {
        int b = q - 1;
        while (b > p && (c(b) == ' ' || c(b) == '\t' || c(b) == '\r'))
        {
          b--;
        }
        if (c(b) != ';')
        {
          return false;
        }
      }
    }
    return false;
  }

  bool Parser::modifier(std::string& op, Expr*& cnd)
  {
    int start = p_;
    int e = modkw(p_);
    if (e < 0)
    {
      return false;
    }
    op = lc(src_.substr(p_, e - p_));
    p_ = e;
    if (!ws())
    {
      p_ = start;
      return false;
    }
    cnd = cond();
    if (!cnd || !ws())
    {
      p_ = start;
      return false;
    }
    return true;
  }

  // The closing words: [ <one> || 'end' [ <two> ]? ] -- 'endif', 'end', 'end
  // if' -- each with its whitespace. word_end_two: '>>' after the second.
  bool Parser::closer(std::string_view one, std::string_view two, bool word_end_two)
  {
    int start = p_;
    if (ilit(one) && ws())
    {
      return true;
    }
    p_ = start;
    if (!ilit("end") || !ws())
    {
      p_ = start;
      return false;
    }
    int save = p_;
    if (!(ilit(two) && (!word_end_two || word_end()) && ws()))
    {
      p_ = save;
    }
    if (!ws())
    {
      p_ = start;
      return false;
    }
    return true;
  }

  // rule ifcallst { :i 'if' '(' <slot> ',' <slot> ',' <slot> ')' <?before <.eol> > }
  Stmt* Parser::ifcallst()
  {
    int start = p_;
    if (!ilit("if") || !ws() || c(p_) != '(')
    {
      p_ = start;
      return nullptr;
    }
    p_++;
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    auto call = make<Call>();
    call->name = "If";
    for (int i = 0; i < 3; i++)
    {
      if (i)
      {
        if (c(p_) != ',')
        {
          p_ = start;
          return nullptr;
        }
        p_++;
        if (!ws())
        {
          p_ = start;
          return nullptr;
        }
      }
      int at = p_;
      Expr* a = arg();
      if (!a)
      {
        p_ = at;
      }
      if (!ws() || !ws())
      {
        p_ = start;
        return nullptr;
      }
      call->args.push_back(a ? a : make<Omitted>());
    }
    if (c(p_) != ')')
    {
      p_ = start;
      return nullptr;
    }
    p_++;
    if (!ws() || !eol(false) || !ws())
    {
      p_ = start;
      return nullptr;
    }
    call->from = start;
    call->to = p_;
    auto cs = make<CallStmt>();
    cs->call = call;
    cs->line = line(start);
    return cs;
  }

  // rule hdrdecl { <name> <!{ refused(~$<name>) }> ':=' <expr> <typespec>? }
  // rule declarator
  // {
  //   <name> <!{ refused }> <!{ a generated name at top level }> <dims>? <attrs>?
  //   [    [ ':=' [ <chained> || <guardexpr> ] <typespec>? ]
  //     || [ <typespec> ':=' <guardexpr> ]
  //     || [ <typespec> ]
  //     || <?> ]
  //   <!{ a '<const>' without a <guardexpr> }>
  // }
  Declarator* Parser::declarator(bool hdr)
  {
    int start = p_;
    auto fail = [&]() -> Declarator* { p_ = start; return nullptr; };
    int e = 0;
    if (memvar_ok_ && lower(c(p_)) == 'm' && c(p_ + 1) == '-' && c(p_ + 2) == '>')
    {
      p_ += 3;                       // 'Private M->nX': nX, as the AppServer has it
    }
    std::string name = name_text(e);
    if (e < 0)
    {
      p_ = start;
      return nullptr;
    }
    p_ = e;
    if (!ws() || refused(name) || !ws())
    {
      return fail();
    }
    auto d = make<Declarator>();
    d->name = name;
    d->line = line(start);
    d->declared = "?";
    std::string type_word;
    bool typed = false;
    if (hdr)
    {
      if (!lit(":=") || !ws())
      {
        return fail();
      }
      d->init = expr();
      if (!d->init || !ws())
      {
        return fail();
      }
      int save = p_;
      int from = 0;
      if (typespec(from, type_word))
      {
        typed = true;
        d->typespec_text = trim(src_.substr(from, p_ - from));
      }
      else
      {
        p_ = save;
      }
      if (!ws())
      {
        return fail();
      }
    }
    else
    {
      if (!any_name && top_level_ && is_generated(name) && !generated_ok)
      {
        return fail();
      }
      if (!ws())
      {
        return fail();
      }
      int save = p_;
      if (!dims(d->dims))
      {
        p_ = save;
        d->dims.clear();
      }
      if (!ws())
      {
        return fail();
      }
      int ae = attrs(p_);
      bool is_const = false;
      if (ae >= 0)
      {
        d->attributes = attr_words(src_.substr(p_, ae - p_));
        is_const = lc(src_.substr(p_, ae - p_)).find("const") != std::string::npos;
        p_ = ae;
      }
      if (!ws())
      {
        return fail();
      }
      bool guarded = false;
      int at = p_;
      int from = 0;
      // [ ':=' [ <chained> || <guardexpr> ] <typespec>? ]
      if (lit(":=") && ws())
      {
        int vat = p_;
        Expr* v = chained();
        if (!v)
        {
          p_ = vat;
          v = guardexpr();
          guarded = v != nullptr;
        }
        if (v && ws())
        {
          d->init = v;
          int s2 = p_;
          if (typespec(from, type_word))
          {
            typed = true;
            d->typespec_text = trim(src_.substr(from, p_ - from));
          }
          else
          {
            p_ = s2;
          }
          if (!ws())
          {
            return fail();
          }
        }
        else
        {
          guarded = false;
          p_ = at;
        }
      }
      else
      {
        p_ = at;
      }
      if (!d->init)
      {
        // [ <typespec> ':=' <guardexpr> ] || [ <typespec> ] || <?>
        if (typespec(from, type_word))
        {
          int after = p_;
          if (lit(":=") && ws())
          {
            if (Expr* v = guardexpr())
            {
              if (ws())
              {
                d->init = v;
                guarded = true;
                d->type_first = true;
              }
            }
          }
          if (!d->init)
          {
            p_ = after;
            if (!ws())
            {
              return fail();
            }
          }
          typed = true;
          d->typespec_text = trim(src_.substr(from, after - from));
        }
        else
        {
          p_ = at;
        }
      }
      if (!ws())
      {
        return fail();
      }
      if (ae >= 0 && is_const && !guarded)
      {
        return fail();
      }
    }
    if (!ws())
    {
      return fail();
    }
    if (typed)
    {
      d->declared = type_of_name(type_word);
    }
    else if (!d->dims.empty())
    {
      d->declared = "Array";
    }
    return d;
  }

  // rule dims { [ '[' ~ ']' <expr> ]+ }
  bool Parser::dims(std::vector<Expr*>& out)
  {
    int start = p_;
    for (;;)
    {
      int save = p_;
      if (c(p_) != '[')
      {
        break;
      }
      p_++;
      Expr* e = ws() ? expr() : nullptr;
      if (!e || c(p_) != ']')
      {
        p_ = save;
        break;
      }
      p_++;
      if (!ws())
      {
        p_ = save;
        break;
      }
      out.push_back(e);
    }
    if (out.empty() || !ws())
    {
      p_ = start;
      return false;
    }
    return true;
  }

  // token attrs { '<' \s* <attr>+ % [ \s* ',' \s* ] \s* '>' }
  // token attr  { :i [ 'const' || 'contained' ] >> }
  // Where it ends, or -1.
  int Parser::attrs(int p) const
  {
    if (c(p) != '<')
    {
      return -1;
    }
    int q = p + 1;
    auto skip = [&]() { while (is_s(c(q))) { q++; } };
    auto attr = [&]() -> bool
    {
      for (std::string_view w : { "const", "contained" })
      {
        int len = static_cast<int>(w.size());
        if (iword_at(q, w) && !is_w(c(q + len)))
        {
          q += len;
          return true;
        }
      }
      return false;
    };
    skip();
    if (!attr())
    {
      return -1;
    }
    for (;;)
    {
      int save = q;
      skip();
      if (c(q) != ',')
      {
        q = save;
        break;
      }
      q++;
      skip();
      if (!attr())
      {
        q = save;
        break;
      }
    }
    skip();
    return c(q) == '>' ? q + 1 : -1;
  }

  // rule typespec { :i 'as' <typename> }: where it starts, and the type's
  // word as written.
  bool Parser::typespec(int& from, std::string& typename_text)
  {
    int start = p_;
    if (!ilit("as") || !ws())
    {
      p_ = start;
      return false;
    }
    int e = type_name_end(p_);
    if (e < 0)
    {
      p_ = start;
      return false;
    }
    typename_text = text(p_, e);
    p_ = e;
    if (!ws())
    {
      p_ = start;
      return false;
    }
    from = start;
    return true;
  }

  // token typename: the full names, and the abbreviations as words.
  int Parser::type_name_end(int p) const
  {
    struct Word { std::string_view w; bool boundary; };
    static const Word names[] =
    {
      { "integer", false }, { "decimal", false }, { "codeblock", false }, { "variadic", true },
      { "double", true }, { "array", false }, { "a", true }, { "numeric", false }, { "n", true },
      { "character", false }, { "c", true }, { "char", true }, { "logical", false }, { "l", true },
      { "date", false }, { "d", true }, { "object", false }, { "o", true }, { "block", false },
      { "b", true }, { "json", false }, { "j", true }, { "variant", false }, { "u", true },
    };
    for (const Word& n : names)
    {
      int len = static_cast<int>(n.w.size());
      if (iword_at(p, n.w) && (!n.boundary || !is_w(c(p + len))))
      {
        return p + len;
      }
    }
    return -1;
  }

  Declaration* Parser::read_declaration()
  {
    p_ = 0;
    in_with_ = false;
    in_block_ = in_dq_ = in_sq_ = in_exp_ = 0;
    past_prologue_ = false;
    top_level_ = false;
    Declaration* d = declaration();
    return d && p_ == n_ ? d : nullptr;
  }

  // rule declaration { <declkind> <declarator>+ % ',' }
  // rule declkind { :i [ 'local' || 'private' || 'public' || 'static' ] }
  Declaration* Parser::declaration()
  {
    int start = p_;
    std::string scope;
    for (std::string_view w : { "local", "private", "public", "static" })
    {
      if (ilit(w))
      {
        scope = w;
        break;
      }
    }
    if (scope.empty() || !ws() || !ws())
    {
      p_ = start;
      return nullptr;
    }
    auto d = make<Declaration>();
    d->scope = scope;
    d->line = line(start);
    struct Reset
    {
      bool& on;
      ~Reset() { on = false; }
    } reset{ memvar_ok_ };
    memvar_ok_ = scope == "private";
    Declarator* first = declarator(false);
    if (!first)
    {
      p_ = start;
      return nullptr;
    }
    d->declarators.push_back(first);
    for (;;)
    {
      int s = p_;
      if (c(p_) != ',')
      {
        break;
      }
      p_++;
      Declarator* x = ws() ? declarator(false) : nullptr;
      if (!x)
      {
        p_ = s;
        break;
      }
      d->declarators.push_back(x);
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    return d;
  }

  // rule ifst
  // {
  //   :i 'if' [ :i <hdrlocal=kwlocal> <hdrdecl> ',' ]? <cond> <.nl>
  //      <then>
  //   [ :i 'elseif' <cond> <.nl> <thenc> ]*
  //   [ :i 'else' <.nl> <else> ]?
  //   :i [ 'endif' || 'end' [ 'if' ]? ]
  // }
  Stmt* Parser::ifst()
  {
    int start = p_;
    auto fail = [&]() -> Stmt* { p_ = start; return nullptr; };
    if (!ilit("if") || !ws())
    {
      return fail();
    }
    auto s = make<IfStmt>();
    s->line = line(start);
    {
      int save = p_;
      Declarator* d = nullptr;
      if (ilit("local") && ws())
      {
        d = declarator(true);
      }
      if (d && ws() && c(p_) == ',')
      {
        p_++;
        if (ws())
        {
          s->header_decl = d;
        }
      }
      if (!s->header_decl)
      {
        p_ = save;
      }
    }
    if (!ws())
    {
      return fail();
    }
    Expr* first = cond();
    if (!first || !ws() || !nl() || !ws())
    {
      return fail();
    }
    auto b = make<Branch>();
    b->cond = first;
    b->body = body(false, false);
    s->branches.push_back(b);
    if (!ws())
    {
      return fail();
    }
    for (;;)
    {
      int save = p_;
      Expr* e = nullptr;
      if (ilit("elseif") && ws() && (e = cond()) && ws() && nl() && ws())
      {
        auto br = make<Branch>();
        br->cond = e;
        br->body = body(true, false);
        if (ws())
        {
          s->branches.push_back(br);
          continue;
        }
      }
      p_ = save;
      break;
    }
    if (!ws())
    {
      return fail();
    }
    {
      int save = p_;
      bool ok = false;
      if (ilit("else") && ws() && nl() && ws())
      {
        Body other = body(true, false);
        if (ws())
        {
          s->otherwise = std::move(other);
          ok = true;
        }
      }
      if (!ok)
      {
        p_ = save;
      }
    }
    if (!ws() || !closer("endif", "if", false) || !ws())
    {
      return fail();
    }
    return s;
  }

  // rule whilest
  // {
  //   :i [ 'do' <.ws> ]? 'while' [ :i <hdrlocal=kwlocal> <hdrdecl> ',' ]? <cond> <.nl>
  //      <block>
  //   :i [ 'enddo' || 'end' [ :i 'do' >> ]? ]
  // }
  Stmt* Parser::whilest()
  {
    int start = p_;
    auto fail = [&]() -> Stmt* { p_ = start; return nullptr; };
    {
      int save = p_;
      if (!(ilit("do") && ws() && ws()))
      {
        p_ = save;
      }
    }
    if (!ws() || !ilit("while") || !ws())
    {
      return fail();
    }
    auto s = make<WhileStmt>();
    s->line = line(start);
    {
      int save = p_;
      Declarator* d = nullptr;
      if (ilit("local") && ws())
      {
        d = declarator(true);
      }
      if (d && ws() && c(p_) == ',')
      {
        p_++;
        if (ws())
        {
          s->header_decl = d;
        }
      }
      if (!s->header_decl)
      {
        p_ = save;
      }
    }
    if (!ws())
    {
      return fail();
    }
    s->cond = cond();
    if (!s->cond || !ws() || !nl() || !ws())
    {
      return fail();
    }
    s->body = body(false, false);
    if (!ws() || !closer("enddo", "do", true) || !ws())
    {
      return fail();
    }
    return s;
  }

  // rule forst
  // {
  //   :i 'for' [ :i <varlocal=kwlocal> ]? <var=name>
  //      <!{ refused(~$<var>) }> [ ':=' || '=' ] <from=expr>
  //      :i 'to' <to=expr> [ :i 'step' <step=expr> ]? <.nl>
  //      <block>
  //   [ :i 'next' [ <endname=name> || [ '(' <endname=name> ')' ] ]?
  //   || :i 'end' 'for' >> ]
  // }
  //
  // A quantified group followed by a blank in a rule is one Raku goes back
  // into: when what follows 'local' does not read, the loop is read again
  // without it -- 'for local := 1 to 3' is over a variable named 'local',
  // refused as a reserved word (which the driver then says, reading the
  // file with any name allowed).
  Stmt* Parser::forst()
  {
    bool took = false;
    if (Stmt* s = forst_with(true, took))
    {
      return s;
    }
    return took ? forst_with(false, took) : nullptr;
  }

  Stmt* Parser::forst_with(bool local, bool& took)
  {
    int start = p_;
    auto fail = [&]() -> Stmt* { p_ = start; return nullptr; };
    if (!ilit("for") || !ws())
    {
      return fail();
    }
    auto s = make<ForStmt>();
    s->line = line(start);
    if (local)
    {
      int save = p_;
      if (ilit("local") && ws())
      {
        s->var_local = true;
        took = true;
      }
      else
      {
        p_ = save;
      }
    }
    if (!ws())
    {
      return fail();
    }
    int e = 0;
    s->var = name_text(e);
    if (e < 0)
    {
      return fail();
    }
    p_ = e;
    if (!ws() || refused(s->var) || !ws())
    {
      return fail();
    }
    if (!((lit(":=") && ws()) || lit("=")) || !ws() || !ws())
    {
      return fail();
    }
    s->from_ = expr();
    if (!s->from_ || !ws() || !ilit("to") || !ws())
    {
      return fail();
    }
    s->to_ = expr();
    if (!s->to_ || !ws())
    {
      return fail();
    }
    {
      int save = p_;
      Expr* st = nullptr;
      if (ilit("step") && ws() && (st = expr()) && ws())
      {
        s->step = st;
      }
      else
      {
        p_ = save;
      }
    }
    if (!ws() || !nl() || !ws())
    {
      return fail();
    }
    s->body = body(false, false);
    if (!ws())
    {
      return fail();
    }
    int save = p_;
    if (ilit("next") && ws() && next_name(s->endname_from, s->endname_to) && ws())
    {
      return s;
    }
    p_ = save;
    s->endname_from = s->endname_to = -1;
    if (ilit("end") && ws() && ilit("for") && word_end() && ws() && ws())
    {
      return s;
    }
    return fail();
  }

  // rule forinst
  // {
  //   :i 'for' <elem=name> <!{ refused(~$<elem>) }>
  //      [ ',' <idx=name> <!{ refused(~$<idx>) }> ]?
  //      :i 'in' [ <srange=forrange> || <source> ] <.nl>
  //      <block>
  //   :i 'next' [ <endname=name> || [ '(' <endname=name> ')' ] ]?
  // }
  // rule forrange  { <lo> '..' <hi> }
  Stmt* Parser::forinst()
  {
    int start = p_;
    auto fail = [&]() -> Stmt* { p_ = start; return nullptr; };
    if (!ilit("for") || !ws())
    {
      return fail();
    }
    auto s = make<ForInStmt>();
    s->line = line(start);
    int e = 0;
    s->elem = name_text(e);
    if (e < 0)
    {
      return fail();
    }
    p_ = e;
    if (!ws() || refused(s->elem) || !ws())
    {
      return fail();
    }
    {
      int save = p_;
      bool ok = false;
      if (c(p_) == ',')
      {
        p_++;
        int ie = 0;
        std::string idx;
        if (ws() && (idx = name_text(ie), ie >= 0))
        {
          p_ = ie;
          if (ws() && !refused(idx) && ws() && ws())
          {
            s->index = idx;
            ok = true;
          }
        }
      }
      if (!ok)
      {
        p_ = save;
      }
    }
    if (!ws() || !ilit("in") || !ws())
    {
      return fail();
    }
    {
      int at = p_;
      bool ok = false;
      if (Expr* lo = addexpr())
      {
        if (ws() && lit("..") && ws())
        {
          if (Expr* hi = addexpr())
          {
            if (ws())
            {
              auto iv = make<Interval>();
              iv->lo = lo;
              iv->hi = hi;
              iv->from = at;
              iv->to = p_;
              s->source = iv;
              ok = ws();
            }
          }
        }
      }
      if (!ok)
      {
        p_ = at;
        s->source = expr();
        if (!s->source || !ws())
        {
          return fail();
        }
      }
    }
    if (!ws() || !nl() || !ws())
    {
      return fail();
    }
    s->body = body(false, false);
    if (!ws() || !ilit("next") || !ws() || !next_name(s->endname_from, s->endname_to) || !ws())
    {
      return fail();
    }
    return s;
  }

  // After 'next': [ <endname=name> || [ '(' <endname=name> ')' ] ]?, and
  // the whitespace after -- the name's span, or -1 when none.
  bool Parser::next_name(int& from, int& to)
  {
    from = to = -1;
    int ns = p_;
    int ne = name_end(p_);
    if (ne >= 0)
    {
      p_ = ne;
      if (ws())
      {
        from = ns;
        to = ne;
      }
      else
      {
        p_ = ns;
      }
    }
    if (from < 0 && c(p_) == '(')
    {
      p_++;
      if (ws())
      {
        int nf = p_;
        ne = name_end(p_);
        if (ne >= 0)
        {
          p_ = ne;
          if (ws() && c(p_) == ')')
          {
            p_++;
            if (ws())
            {
              from = nf;
              to = ne;
            }
          }
        }
      }
      if (from < 0)
      {
        p_ = ns;
      }
    }
    if (from >= 0 && !ws())
    {
      from = to = -1;
      p_ = ns;
    }
    return ws();
  }

  // rule fortimesst { :i 'for' <count=expr> :i 'times' <.nl> <block> :i 'next' }
  Stmt* Parser::fortimesst()
  {
    int start = p_;
    auto fail = [&]() -> Stmt* { p_ = start; return nullptr; };
    if (!ilit("for") || !ws())
    {
      return fail();
    }
    auto s = make<ForTimesStmt>();
    s->line = line(start);
    s->count = expr();
    if (!s->count || !ws() || !ilit("times") || !ws() || !nl() || !ws())
    {
      return fail();
    }
    s->body = body(false, false);
    if (!ws() || !ilit("next") || !ws())
    {
      return fail();
    }
    return s;
  }

  // rule docasest
  // {
  //   :i 'do' 'case' [ :i 'with' <subject> ]? <.nl>
  //   [ :i 'case' <cond> <.nl> <thenc> ]+
  //   [ :i 'otherwise' <.nl> <else> ]?
  //   :i [ 'endcase' || 'end' [ 'case' ]? ]
  // }
  // rule subject { [ :i <subjlocal=kwlocal> <hdrdecl> ] || <assignment> }
  Stmt* Parser::docasest()
  {
    int start = p_;
    auto fail = [&]() -> Stmt* { p_ = start; return nullptr; };
    if (!ilit("do") || !ws() || !ilit("case") || !ws())
    {
      return fail();
    }
    auto s = make<CaseStmt>();
    s->line = line(start);
    {
      int save = p_;
      bool ok = false;
      if (ilit("with") && ws())
      {
        int at = p_;
        if (ilit("local") && ws())
        {
          if (Declarator* d = declarator(true))
          {
            if (ws() && ws())
            {
              s->subject_decl = d;
              ok = true;
            }
          }
        }
        if (!ok)
        {
          p_ = at;
          if (Stmt* a = assign_stmt())
          {
            if (ws() && ws())
            {
              s->subject_assign = static_cast<Assignment*>(a);
              ok = true;
            }
          }
        }
        if (ok && !ws())
        {
          ok = false;
        }
      }
      if (!ok)
      {
        s->subject_decl = nullptr;
        s->subject_assign = nullptr;
        p_ = save;
      }
    }
    if (!ws() || !nl() || !ws())
    {
      return fail();
    }
    for (;;)
    {
      int save = p_;
      Expr* e = nullptr;
      if (ilit("case") && ws() && (e = cond()) && ws() && nl() && ws())
      {
        auto br = make<Branch>();
        br->cond = e;
        br->body = body(true, false);
        if (ws())
        {
          s->branches.push_back(br);
          continue;
        }
      }
      p_ = save;
      break;
    }
    if (s->branches.empty() || !ws())
    {
      return fail();
    }
    {
      int save = p_;
      bool ok = false;
      if (ilit("otherwise") && ws() && nl() && ws())
      {
        Body other = body(true, false);
        if (ws())
        {
          s->otherwise = std::move(other);
          ok = true;
        }
      }
      if (!ok)
      {
        p_ = save;
      }
    }
    if (!ws() || !closer("endcase", "case", false) || !ws())
    {
      return fail();
    }
    return s;
  }

  // rule seqst
  // {
  //   :i 'begin' 'sequence' <.nl>
  //      <seqblock>
  //   [ :i 'recover' [ :i 'using' <errvar=name> ]? <.nl> <recover> ]?
  //   :i 'end' [ :i 'sequence' ]?
  // }
  Stmt* Parser::seqst()
  {
    int start = p_;
    auto fail = [&]() -> Stmt* { p_ = start; return nullptr; };
    if (!ilit("begin") || !ws() || !ilit("sequence") || !ws() || !nl() || !ws())
    {
      return fail();
    }
    auto s = make<SequenceStmt>();
    s->line = line(start);
    s->body = body(true, false);
    if (!ws())
    {
      return fail();
    }
    {
      int save = p_;
      bool ok = false;
      OptStr var;
      if (ilit("recover") && ws())
      {
        int us = p_;
        int e = 0;
        std::string v;
        if (ilit("using") && ws() && (v = name_text(e), e >= 0))
        {
          p_ = e;
          if (ws() && ws())
          {
            var = v;
          }
          else
          {
            p_ = us;
          }
        }
        else
        {
          p_ = us;
        }
        if (ws() && nl() && ws())
        {
          Body rec = body(true, false);
          if (ws())
          {
            s->recover = std::move(rec);
            s->error_var = var;
            s->has_recover = true;
            ok = true;
          }
        }
      }
      if (!ok)
      {
        p_ = save;
      }
    }
    if (!ws() || !ilit("end") || !ws())
    {
      return fail();
    }
    {
      int save = p_;
      if (!(ilit("sequence") && ws()))
      {
        p_ = save;
      }
    }
    if (!ws())
    {
      return fail();
    }
    return s;
  }

  // rule tryst
  // {
  //   :i 'try' <.nl>
  //      <seqblock>
  //   [ :i 'catch' <errvar=name>? <.nl> <recover> ]?
  //   [ :i 'finally' <.nl> <finblock> ]?
  //   :i 'endtry'
  // }
  Stmt* Parser::tryst()
  {
    int start = p_;
    auto fail = [&]() -> Stmt* { p_ = start; return nullptr; };
    if (!ilit("try") || !ws() || !nl() || !ws())
    {
      return fail();
    }
    auto s = make<TryStmt>();
    s->line = line(start);
    s->body = body(true, false);
    if (!ws())
    {
      return fail();
    }
    {
      int save = p_;
      bool ok = false;
      if (ilit("catch") && ws())
      {
        OptStr var;
        int e = name_end(p_);
        if (e >= 0)
        {
          var = text(p_, e);
          p_ = e;
        }
        if (ws() && nl() && ws())
        {
          Body h = body(true, false);
          if (ws())
          {
            s->handler = std::move(h);
            s->error_var = var;
            ok = true;
          }
        }
      }
      if (!ok)
      {
        p_ = save;
      }
    }
    if (!ws())
    {
      return fail();
    }
    {
      int save = p_;
      bool ok = false;
      if (ilit("finally") && ws() && nl() && ws())
      {
        Body f = body(true, false);
        if (ws())
        {
          s->finally = std::move(f);
          ok = true;
        }
      }
      if (!ok)
      {
        p_ = save;
      }
    }
    if (!ws() || !ilit("endtry") || !ws())
    {
      return fail();
    }
    return s;
  }

  // rule transst { :i 'begin' 'transaction' <.nl> <seqblock> :i 'end' 'transaction' }
  Stmt* Parser::transst()
  {
    int start = p_;
    if (!ilit("begin") || !ws() || !ilit("transaction") || !ws() || !nl() || !ws())
    {
      p_ = start;
      return nullptr;
    }
    auto s = make<TransactionStmt>();
    s->line = line(start);
    s->body = body(true, false);
    if (!ws() || !ilit("end") || !ws() || !ilit("transaction") || !ws())
    {
      p_ = start;
      return nullptr;
    }
    return s;
  }

  // rule usingst
  // {
  //   :i 'using' 'alias' <area=name> [ :i 'order' <order=expr> ]? :i 'do' <.nl>
  //      <block>
  //   :i 'end' 'using'
  // }
  Stmt* Parser::usingst()
  {
    int start = p_;
    auto fail = [&]() -> Stmt* { p_ = start; return nullptr; };
    if (!ilit("using") || !ws() || !ilit("alias") || !ws())
    {
      return fail();
    }
    auto s = make<UsingAlias>();
    s->line = line(start);
    int e = 0;
    s->area = name_text(e);
    if (e < 0)
    {
      return fail();
    }
    p_ = e;
    if (!ws())
    {
      return fail();
    }
    {
      int save = p_;
      Expr* o = nullptr;
      if (ilit("order") && ws() && (o = expr()) && ws())
      {
        s->order = o;
      }
      else
      {
        p_ = save;
      }
    }
    if (!ws() || !ilit("do") || !ws() || !nl() || !ws())
    {
      return fail();
    }
    s->body = body(false, false);
    if (!ws() || !ilit("end") || !ws() || !ilit("using") || !ws())
    {
      return fail();
    }
    return s;
  }

  // rule withst
  // {
  //   :i 'with' 'object' <subject=expr> <.nl>
  //      <withblock>
  //   :i 'end' 'with'
  // }
  Stmt* Parser::withst()
  {
    int start = p_;
    auto fail = [&]() -> Stmt* { p_ = start; return nullptr; };
    if (!ilit("with") || !ws() || !ilit("object") || !ws())
    {
      return fail();
    }
    auto s = make<WithObject>();
    s->line = line(start);
    s->subject = expr();
    if (!s->subject || !ws() || !nl() || !ws())
    {
      return fail();
    }
    s->body = body(false, true);
    if (!ws() || !ilit("end") || !ws() || !ilit("with") || !ws())
    {
      return fail();
    }
    return s;
  }

  // rule deferst { :i 'defer' [ [ <.sees('assign')> <assignment> ] || [ <.sees('pipe')> <pipest> ] || <callst> ] }
  Stmt* Parser::deferst()
  {
    int start = p_;
    if (!ilit("defer") || !ws())
    {
      p_ = start;
      return nullptr;
    }
    int at = p_;
    Stmt* inner = nullptr;
    if (sees(Ahead::Assign, false))
    {
      inner = assign_stmt();
      if (inner && !ws())
      {
        inner = nullptr;
        p_ = at;
      }
    }
    if (!inner && sees(Ahead::Pipe, false))
    {
      if (Expr* e = pipest())
      {
        auto cs = make<CallStmt>();
        cs->call = e;
        cs->line = line(at);
        inner = cs;
        if (!ws())
        {
          inner = nullptr;
          p_ = at;
        }
      }
    }
    if (!inner)
    {
      if (Expr* e = callst())
      {
        auto cs = make<CallStmt>();
        cs->call = e;
        cs->line = line(at);
        inner = cs;
        if (!ws())
        {
          inner = nullptr;
          p_ = at;
        }
      }
    }
    if (!inner)
    {
      p_ = start;
      return nullptr;
    }
    // The deferred statement's own span.
    inner->from = at;
    inner->to = p_;
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    auto d = make<Deferred>();
    d->stmt = inner;
    d->line = line(start);
    return d;
  }

  // rule execst { :i 'exec' <expr> <modifier> }
  Stmt* Parser::execst()
  {
    int start = p_;
    if (!ilit("exec") || !ws())
    {
      p_ = start;
      return nullptr;
    }
    int at = p_;
    Expr* e = expr();
    if (!e)
    {
      p_ = start;
      return nullptr;
    }
    int end = p_;
    std::string op;
    Expr* cnd = nullptr;
    if (!ws() || !modifier(op, cnd) || !ws())
    {
      p_ = start;
      return nullptr;
    }
    auto cs = make<CallStmt>();
    cs->call = e;
    cs->line = line(start);
    cs->from = at;
    cs->to = end;
    auto m = make<Modified>();
    m->stmt = cs;
    m->op = op;
    m->cond = cnd;
    m->line = line(start);
    return m;
  }

  // token rawline { [ \N*? ';' \h* \v ]* \N* }: where it ends.
  int Parser::rawline(int p) const { return continued_line(p, false); }

  // token rawst { <rawblock> || <rawone> }
  // token rawblock
  // {
  //   :i 'raw' \h* <.linecomment>? <.rawnl>
  //   [ <!before \h* :i 'end' \h+ 'raw' <!ww> > <rawline> <.rawnl> ]*
  //   \h* :i 'end' \h+ 'raw' >>
  // }
  // token rawone { :i 'raw' \h+ <!before [ <assignop> || '?=' ]> <rawline> }
  Stmt* Parser::rawst()
  {
    int start = p_;
    if (!iword_at(start, "raw"))
    {
      return nullptr;
    }
    // 'end' \h+ 'raw', and what may follow it: where it ends, or -1.
    auto end_raw = [&](int q, bool boundary) -> int
    {
      while (is_h(c(q)))
      {
        q++;
      }
      if (!iword_at(q, "end"))
      {
        return -1;
      }
      q += 3;
      if (!is_h(c(q)))
      {
        return -1;
      }
      while (is_h(c(q)))
      {
        q++;
      }
      if (!iword_at(q, "raw"))
      {
        return -1;
      }
      q += 3;
      if (boundary ? !(is_w(c(q - 1)) && !is_w(c(q))) : (is_w(c(q - 1)) && is_w(c(q))))
      {
        return -1;
      }
      return q;
    };
    // rawblock
    {
      int q = start + 3;
      while (is_h(c(q)))
      {
        q++;
      }
      int k = linecomment(q);
      if (k >= 0)
      {
        q = k;
      }
      int v = vchar(q);
      if (v)
      {
        q += v;
        std::vector<std::string> lines;
        bool ok = false;
        for (;;)
        {
          if (end_raw(q, false) >= 0)
          {
            int e = end_raw(q, true);
            if (e >= 0)
            {
              p_ = e;
              ok = true;
            }
            break;
          }
          int e = rawline(q);
          int rv = vchar(e);
          if (!rv)
          {
            // the last line, with no line end: 'end raw' then
            int z = end_raw(q, true);
            if (z >= 0)
            {
              p_ = z;
              ok = true;
            }
            break;
          }
          lines.push_back(text(q, e));
          q = e + rv;
        }
        if (ok)
        {
          auto r = make<RawStmt>();
          r->block = true;
          r->lines = std::move(lines);
          r->line = line(start);
          return r;
        }
      }
    }
    // rawone
    {
      int q = start + 3;
      if (!is_h(c(q)))
      {
        p_ = start;
        return nullptr;
      }
      while (is_h(c(q)))
      {
        q++;
      }
      int ch = c(q);
      int d = c(q + 1);
      bool op = (d == '=' && (ch == ':' || ch == '+' || ch == '-' || ch == '*' || ch == '/' || ch == '?'))
                || ch == '=';
      if (op)
      {
        p_ = start;
        return nullptr;
      }
      int e = rawline(q);
      p_ = e;
      auto r = make<RawStmt>();
      r->lines.push_back(text(q, e));
      r->line = line(start);
      return r;
    }
  }

  // token cmdst { <cmdblock> || <cmdone> }
  // token cmdone { <.cmdword> <rawline> }
  // token cmdblock { <sqlblock> || <contentblock> }
  Stmt* Parser::cmdst()
  {
    int start = p_;
    int e = textblock(start, "beginsql", "endsql");
    if (e < 0)
    {
      e = textblock(start, "begincontent", "endcontent");
    }
    if (e < 0)
    {
      int w = cmdword(start);
      if (w < 0)
      {
        return nullptr;
      }
      e = rawline(w);
    }
    p_ = e;
    auto r = make<RawStmt>();
    r->lines.push_back(text(start, e));
    r->line = line(start);
    return r;
  }

  // token sqlblock
  // {
  //   :i 'beginsql' <!ww> \N* \v
  //   [ <!before \h* :i 'endsql' <!ww> > \N* \v ]*
  //   \h* :i 'endsql' <!ww> \N*
  // }
  // (contentblock likewise.) Where it ends, or -1.
  int Parser::textblock(int p, std::string_view open, std::string_view close) const
  {
    auto word_at = [&](int q, std::string_view w) -> int
    {
      if (!iword_at(q, w))
      {
        return -1;
      }
      int e = q + static_cast<int>(w.size());
      return is_w(c(e - 1)) && is_w(c(e)) ? -1 : e;
    };
    auto rest = [&](int q) { while (is_nn(c(q))) { q++; } return q; };
    int q = word_at(p, open);
    if (q < 0)
    {
      return -1;
    }
    q = rest(q);
    int v = vchar(q);
    if (!v)
    {
      return -1;
    }
    q += v;
    for (;;)
    {
      int h = q;
      while (is_h(c(h)))
      {
        h++;
      }
      int e = word_at(h, close);
      if (e >= 0)
      {
        return rest(e);
      }
      int r = rest(q);
      int rv = vchar(r);
      if (!rv)
      {
        return -1;
      }
      q = r + rv;
    }
  }

  // token cmdword: the first words of TOTVS' commands, and '@ row, col'.
  // Where they end, or -1.
  int Parser::cmdword(int p) const
  {
    auto boundary = [&](int q) { return !(is_w(c(q - 1)) && is_w(c(q))); };
    auto hws = [&](int q) { int k = q; while (is_h(c(k))) { k++; } return k > q ? k : -1; };
    // [ 'define' || ... ] \h+ <[A..Za..z_]>
    for (std::string_view w : { "define", "activate", "redefine", "set", "menu", "publish", "replace" })
    {
      if (iword_at(p, w))
      {
        int q = hws(p + static_cast<int>(w.size()));
        if (q >= 0 && is_alpha(c(q)))
        {
          return q + 1;
        }
        break;
      }
    }
    // the words of two, and the words alone -- '<!ww>' after them
    struct Two { std::string_view a; std::string_view b; std::string_view c3; };
    static const Two words2[] =
    {
      { "add", "option", "" }, { "prepare", "environment", "" }, { "reset", "environment", "" },
      { "append", "blank", "" }, { "count", "to", "" }, { "menuitem", "", "" }, { "endmenu", "", "" },
      { "tcquery", "", "" }, { "connect", "smtp", "" }, { "disconnect", "smtp", "" },
      { "send", "mail", "" }, { "get", "mail", "error" }, { "paramtype", "", "" }, { "throw", "", "" },
      { "vtpause", "", "" }, { "vtread", "", "" }, { "vtclear", "", "" }, { "vtsave", "", "" },
      { "vtrestore", "", "" },
    };
    for (const Two& t : words2)
    {
      if (!iword_at(p, t.a))
      {
        continue;
      }
      int q = p + static_cast<int>(t.a.size());
      if (!t.b.empty())
      {
        q = hws(q);
        if (q < 0 || !iword_at(q, t.b))
        {
          continue;
        }
        q += static_cast<int>(t.b.size());
        if (!t.c3.empty())
        {
          q = hws(q);
          if (q < 0 || !iword_at(q, t.c3))
          {
            continue;
          }
          q += static_cast<int>(t.c3.size());
        }
      }
      if (boundary(q))
      {
        return q;
      }
      return -1;
    }
    // '@' [ \h+ || <?before \d> ]
    if (c(p) == '@')
    {
      if (is_h(c(p + 1)))
      {
        int q = p + 1;
        while (is_h(c(q)))
        {
          q++;
        }
        return q;
      }
      if (is_d(c(p + 1)))
      {
        return p + 1;
      }
    }
    return -1;
  }

  // token dirst { <preproc> }
  Stmt* Parser::dirst()
  {
    int start = p_;
    int e = preproc();
    if (e < 0)
    {
      return nullptr;
    }
    p_ = e;
    auto r = make<RawStmt>();
    r->lines.push_back(trim(src_.substr(start, e - start)));
    r->line = line(start);
    return r;
  }

  // token noopst
  // {
  //   :i [ 'endfunction' || 'endfunc' || 'endmethod' || 'default' <?before \h* [ <.linecomment> || \v || $ ]> ] <!ww>
  // }
  Stmt* Parser::noopst()
  {
    int start = p_;
    int e = -1;
    for (std::string_view w : { "endfunction", "endfunc", "endmethod" })
    {
      if (iword_at(start, w))
      {
        e = start + static_cast<int>(w.size());
        break;
      }
    }
    if (e < 0 && iword_at(start, "default"))
    {
      int q = start + 7;
      while (is_h(c(q)))
      {
        q++;
      }
      if (linecomment(q) >= 0 || vchar(q) || q == n_)
      {
        e = start + 7;
      }
    }
    if (e < 0 || (is_w(c(e - 1)) && is_w(c(e))))
    {
      return nullptr;
    }
    p_ = e;
    auto s = make<NoOpStmt>();
    s->word = text(start, e);
    s->line = line(start);
    return s;
  }

  // rule returnst
  // {
  //   :i 'return' [ [ '(' ')' ] || [ [ <?before <.usertrans>> || <!modkw> ] <guardexpr> ] ]?
  // }
  Stmt* Parser::returnst()
  {
    int start = p_;
    if (!ilit("return") || !ws())
    {
      p_ = start;
      return nullptr;
    }
    auto r = make<ReturnStmt>();
    r->line = line(start);
    int save = p_;
    bool done = false;
    if (c(p_) == '(')
    {
      p_++;
      if (ws() && c(p_) == ')')
      {
        p_++;
        if (ws() && ws())
        {
          done = true;
        }
      }
      if (!done)
      {
        p_ = save;
      }
    }
    if (!done)
    {
      bool trans = false;
      if (user_on_)
      {
        auto it = trans_.find(p_);
        trans = it != trans_.end() && it->second > p_;
      }
      if (trans || modkw(p_) < 0 || if_call(p_))
      {
        if (Expr* g = guardexpr())
        {
          if (ws())
          {
            r->value = g;
          }
          else
          {
            p_ = save;
          }
        }
        else
        {
          p_ = save;
        }
      }
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    return r;
  }

  // rule breakst { :i 'break'>> <guardexpr>? }
  Stmt* Parser::breakst()
  {
    int start = p_;
    if (!ilit("break") || !word_end() || !ws())
    {
      p_ = start;
      return nullptr;
    }
    auto b = make<BreakStmt>();
    b->line = line(start);
    int save = p_;
    b->value = guardexpr();
    if (!b->value)
    {
      p_ = save;
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    return b;
  }

  // rule defaultst { :i 'default'>> <defpair>+ % ',' }
  // rule defpair   { <lvalue> ':=' <guardexpr> }
  Stmt* Parser::defaultst()
  {
    int start = p_;
    if (!ilit("default") || !word_end() || !ws())
    {
      p_ = start;
      return nullptr;
    }
    auto d = make<DefaultStmt>();
    d->line = line(start);
    auto defpair = [&]() -> Assignment*
    {
      int s = p_;
      Expr* t = lvalue();
      if (!t || !ws() || !lit(":=") || !ws())
      {
        p_ = s;
        return nullptr;
      }
      Expr* v = guardexpr();
      if (!v || !ws())
      {
        p_ = s;
        return nullptr;
      }
      auto a = make<Assignment>();
      a->target = t;
      a->op = ":=";
      a->value = v;
      a->line = line(s);
      return a;
    };
    Assignment* first = defpair();
    if (!first)
    {
      p_ = start;
      return nullptr;
    }
    d->pairs.push_back(first);
    for (;;)
    {
      int s = p_;
      if (c(p_) != ',')
      {
        break;
      }
      p_++;
      Assignment* a = ws() ? defpair() : nullptr;
      if (!a)
      {
        p_ = s;
        break;
      }
      d->pairs.push_back(a);
    }
    if (!ws())
    {
      p_ = start;
      return nullptr;
    }
    return d;
  }

  // rule incst  { [ <incop> <lvalue> ] || [ <.incsoon> <lvalue> <incop> ] }
  Stmt* Parser::incst()
  {
    int start = p_;
    auto inc = [&]() -> int
    {
      int ch = c(p_);
      if ((ch == '+' || ch == '-') && c(p_ + 1) == ch)
      {
        p_ += 2;
        return ch;
      }
      return 0;
    };
    auto made = [&](Expr* t, int op) -> Stmt*
    {
      auto one = make<Literal>();
      one->type = "Numeric";
      one->text = "1";
      auto a = make<Assignment>();
      a->target = t;
      a->op = op == '+' ? "+=" : "-=";
      a->value = one;
      a->line = line(start);
      return a;
    };
    int op = inc();
    if (op && ws())
    {
      if (Expr* t = lvalue())
      {
        if (ws() && ws())
        {
          return made(t, op);
        }
      }
    }
    p_ = start;
    if (incsoon())
    {
      if (Expr* t = lvalue())
      {
        if (ws() && (op = inc()) != 0 && ws() && ws())
        {
          return made(t, op);
        }
      }
    }
    p_ = start;
    return nullptr;
  }

  // token incsoon: the rest of the line, and the lines a ';' carries it on
  // to, has a '++' or a '--'.
  bool Parser::incsoon() const
  {
    int p = p_;
    for (;;)
    {
      int e = p;
      while (is_nn(c(e)))
      {
        e++;
      }
      std::string_view part = src_.substr(p, e - p);
      if (part.find("++") != std::string_view::npos || part.find("--") != std::string_view::npos)
      {
        return true;
      }
      // Carried on: a ';' with only blanks, and a '//' or '&&' comment,
      // after it.
      int v = vchar(e);
      bool carried = false;
      for (int q = p; v && q < e && !carried; q++)
      {
        if (c(q) != ';')
        {
          continue;
        }
        int r = q + 1;
        while (r < e && is_h(c(r)))
        {
          r++;
        }
        carried = r == e || linecomment(r) >= 0;
      }
      if (!carried)
      {
        return false;
      }
      p = e + v;
    }
  }

  // rule nilassign { <!stmtword> <lvalue> '?=' <expr> }
  Stmt* Parser::nilassign()
  {
    int start = p_;
    if (stmtword_at(start) || !ws())
    {
      p_ = start;
      return nullptr;
    }
    Expr* t = lvalue();
    if (!t || !ws() || !lit("?=") || !ws())
    {
      p_ = start;
      return nullptr;
    }
    Expr* v = expr();
    if (!v || !ws())
    {
      p_ = start;
      return nullptr;
    }
    auto a = make<Assignment>();
    a->target = t;
    a->op = "?=";
    a->value = v;
    a->line = line(start);
    return a;
  }
}
