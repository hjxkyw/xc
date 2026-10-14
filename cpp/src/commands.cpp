// xc -- the commands and translations a source brings with it (see
// commands.h). XC::Commands, the same spans for every source.

#include "commands.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <unordered_set>

#include "chars.h"

namespace xc
{
  namespace
  {
    bool is_s(int c) { return c >= 0 && (CHAR_CLASS[c] & C_S); }
    bool ascii_letter(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
    int at(std::string_view s, std::size_t i) { return i < s.size() ? static_cast<unsigned char>(s[i]) : -1; }

    // One element of a pattern: a word or a sign ('lit'), a match marker, or
    // an optional clause ('[ ... ]') with the elements inside it.
    enum class EKind { Lit, Regular, List, Restricted, Wild, Opt };

    struct Elem
    {
      EKind kind = EKind::Lit;
      std::string text;                   // a lit's text, lower case
      std::vector<std::string> words;     // a restricted marker's words, lower case
      std::vector<Elem> inner;            // an optional clause's elements
    };

    struct Rule
    {
      bool command = false;               // a command, or a translation
      bool exact = false;                 // 'x': every word in full; else four letters do
      std::vector<Elem> pattern;
      bool header = false;                // it stands for a function's header

      // The first word, lower case -- or none when the pattern starts with a
      // marker.
      const std::string* first() const
      {
        return !pattern.empty() && pattern[0].kind == EKind::Lit ? &pattern[0].text : nullptr;
      }
    };

    struct Tok
    {
      std::string text;
      int from = 0;
      int to = 0;
    };

    // ---- tokens -------------------------------------------------------------
    // Where a token at i ends, or 0 when there is none (a blank): strings
    // (closed or not), '.and.'-like words, numbers, names, two-sign
    // operators, and single signs.
    //
    //   '"' <-["]>* '"'? || "'" <-[']>* "'"? || '.' <[A..Za..z]>+ '.' || \d+ [ '.' \d+ ]?
    //   || '.' \d+ || <[A..Za..z_]> \w* || ':=' || ... || '=>' || \S
    std::size_t token_end(std::string_view s, std::size_t i)
    {
      int ch = at(s, i);
      if (ch == '"' || ch == '\'')
      {
        std::size_t close = s.find(static_cast<char>(ch), i + 1);
        return close == std::string_view::npos ? s.size() : close + 1;
      }
      if (ch == '.' && ascii_letter(at(s, i + 1)))
      {
        std::size_t k = i + 1;
        while (ascii_letter(at(s, k)))
        {
          k++;
        }
        if (at(s, k) == '.')
        {
          return k + 1;
        }
      }
      if (is_d(ch))
      {
        std::size_t k = i;
        while (is_d(at(s, k)))
        {
          k++;
        }
        if (at(s, k) == '.' && is_d(at(s, k + 1)))
        {
          k++;
          while (is_d(at(s, k)))
          {
            k++;
          }
        }
        return k;
      }
      if (ch == '.' && is_d(at(s, i + 1)))
      {
        std::size_t k = i + 1;
        while (is_d(at(s, k)))
        {
          k++;
        }
        return k;
      }
      if (is_alpha(ch))
      {
        std::size_t k = i + 1;
        while (is_w(at(s, k)))
        {
          k++;
        }
        return k;
      }
      static const std::string_view twos[] =
      {
        ":=", "+=", "-=", "*=", "/=", "==", "!=", "<>", "<=", ">=", "->", "::", "++", "--", "**", "=>",
      };
      for (std::string_view t : twos)
      {
        if (s.substr(i, 2) == t)
        {
          return i + 2;
        }
      }
      if (ch >= 0 && !is_s(ch))
      {
        return i + 1;
      }
      return 0;
    }

    // The tokens of one line, the offsets from base.
    void tokens_of(std::string_view line, int base, std::vector<Tok>& out)
    {
      std::size_t i = 0;
      while (i < line.size())
      {
        std::size_t e = token_end(line, i);
        if (e == 0)
        {
          i++;
          continue;
        }
        out.push_back(Tok{ std::string(line.substr(i, e - i)), base + static_cast<int>(i), base + static_cast<int>(e) });
        i = e;
      }
    }

    // ---- lines --------------------------------------------------------------
    // The lines of a text as Raku's .lines splits them -- at "\r\n", "\n" and
    // "\r" --, each with its break (chomp: without).
    std::vector<std::string_view> lines_of(std::string_view t, bool chomp)
    {
      std::vector<std::string_view> out;
      std::size_t i = 0;
      std::size_t start = 0;
      while (i < t.size())
      {
        char ch = t[i];
        if (ch == '\r' || ch == '\n')
        {
          std::size_t brk = ch == '\r' && i + 1 < t.size() && t[i + 1] == '\n' ? 2 : 1;
          out.push_back(t.substr(start, (chomp ? i : i + brk) - start));
          i += brk;
          start = i;
          continue;
        }
        i++;
      }
      if (start < t.size())
      {
        out.push_back(t.substr(start));
      }
      return out;
    }

    bool ends_with_semi(std::string_view s)
    {
      std::size_t k = s.size();
      while (k > 0 && is_h(static_cast<unsigned char>(s[k - 1])))
      {
        k--;
      }
      return k > 0 && s[k - 1] == ';';
    }

    std::string_view without_semi(std::string_view s)
    {
      std::size_t k = s.size();
      while (k > 0 && is_h(static_cast<unsigned char>(s[k - 1])))
      {
        k--;
      }
      return s.substr(0, k - 1);
    }

    bool iprefix(std::string_view s, std::size_t i, std::string_view w)
    {
      if (i + w.size() > s.size())
      {
        return false;
      }
      for (std::size_t k = 0; k < w.size(); k++)
      {
        if (lower(static_cast<unsigned char>(s[i + k])) != static_cast<unsigned char>(w[k]))
        {
          return false;
        }
      }
      return true;
    }

    // ---- the directives -----------------------------------------------------
    struct Directive
    {
      bool command = false;
      bool exact = false;
      std::string text;
    };

    // A directive with its continuation lines -- each ending in ';' -- as one:
    // m:i/ ^ \h* '#' \h* (x?) (command || translate) >> \h* (.*) $ /
    std::vector<Directive> directives_of(std::string_view text)
    {
      std::vector<Directive> out;
      std::vector<std::string_view> lines = lines_of(text, true);
      for (std::size_t i = 0; i < lines.size(); i++)
      {
        std::string_view l = lines[i];
        std::size_t k = 0;
        while (is_h(at(l, k)))
        {
          k++;
        }
        if (at(l, k) != '#')
        {
          continue;
        }
        k++;
        while (is_h(at(l, k)))
        {
          k++;
        }
        Directive d;
        if (lower(at(l, k)) == 'x')
        {
          // 'x?' -- given back when what follows is no directive
          if (iprefix(l, k + 1, "command") || iprefix(l, k + 1, "translate"))
          {
            d.exact = true;
            k++;
          }
        }
        std::size_t len = 0;
        if (iprefix(l, k, "command"))
        {
          d.command = true;
          len = 7;
        }
        else if (iprefix(l, k, "translate"))
        {
          len = 9;
        }
        else
        {
          continue;
        }
        k += len;
        if (is_w(at(l, k)))
        {
          continue;              // '>>'
        }
        while (is_h(at(l, k)))
        {
          k++;
        }
        std::string rest(l.substr(k));
        while (ends_with_semi(rest) && i + 1 < lines.size())
        {
          rest = std::string(without_semi(rest)) + " " + std::string(lines[++i]);
        }
        d.text = std::move(rest);
        out.push_back(std::move(d));
      }
      return out;
    }

    // The pattern's elements, from its text: '<x>', '<x,...>', '<x: a, b>',
    // '<*x*>', '<(x)>', '<!x!>', '[ ... ]', and the rest word by word.
    //
    //   '<' \s* ( '*' \s* \w+ \s* '*' || '(' \s* \w+ \s* ')' || '!' \s* \w+ \s* '!' || '"' \s* \w+ \s* '"'
    //            || '#'? \w+ \s* [ ',' \s* '...' || ':' <-[>]>+ ]? ) \s* '>'
    // The marker's inside, and where the marker ends -- or 0.
    std::size_t marker_end(std::string_view s, std::size_t i, std::string& inside)
    {
      if (at(s, i) != '<')
      {
        return 0;
      }
      std::size_t k = i + 1;
      auto skip = [&]() { while (is_s(at(s, k))) { k++; } };
      auto word = [&]() -> bool
      {
        std::size_t b = k;
        while (is_w(at(s, k)))
        {
          k++;
        }
        return k > b;
      };
      skip();
      std::size_t from = k;
      bool ok = false;
      int ch = at(s, k);
      // the bracketed forms: '*' x '*', '(' x ')', '!' x '!', '"' x '"'
      static const std::pair<char, char> pairs[] = { { '*', '*' }, { '(', ')' }, { '!', '!' }, { '"', '"' } };
      for (auto [open, close] : pairs)
      {
        if (ch != open)
        {
          continue;
        }
        std::size_t save = k;
        k++;
        skip();
        if (word())
        {
          skip();
          if (at(s, k) == close)
          {
            k++;
            ok = true;
          }
        }
        if (!ok)
        {
          k = save;
        }
        break;
      }
      if (!ok)
      {
        k = from;
        if (at(s, k) == '#')
        {
          k++;
        }
        if (!word())
        {
          return 0;
        }
        std::size_t after = k;
        skip();
        if (at(s, k) == ',')
        {
          std::size_t c = k + 1;
          k = c;
          skip();
          if (s.substr(k, 3) == "...")
          {
            k += 3;
          }
          else
          {
            k = after;
          }
        }
        else if (at(s, k) == ':' && at(s, k + 1) >= 0 && at(s, k + 1) != '>')
        {
          k++;
          while (at(s, k) >= 0 && at(s, k) != '>')
          {
            k++;
          }
        }
        else
        {
          k = after;
        }
      }
      std::size_t to = k;
      skip();
      if (at(s, k) != '>')
      {
        return 0;
      }
      inside = std::string(s.substr(from, to - from));
      return k + 1;
    }

    std::vector<Elem> elements_of(std::string_view s)
    {
      std::vector<std::vector<Elem>> stack(1);
      std::size_t pos = 0;
      while (pos < s.size())
      {
        int ch = at(s, pos);
        if (is_s(ch))
        {
          while (is_s(at(s, pos)))
          {
            pos++;
          }
          continue;
        }
        if (ch == '\\' && at(s, pos + 1) >= 0 && !is_s(at(s, pos + 1)))
        {
          Elem e;
          e.text = lc(s.substr(pos + 1, 1));
          stack.back().push_back(std::move(e));
          pos += 2;
          continue;
        }
        std::string m;
        if (std::size_t e = marker_end(s, pos, m))
        {
          Elem el;
          if (!m.empty() && m[0] == '*')
          {
            el.kind = EKind::Wild;
          }
          else if (m.find("...") != std::string::npos)
          {
            el.kind = EKind::List;
          }
          else if (m.find(':') != std::string::npos)
          {
            el.kind = EKind::Restricted;
            std::string_view rest = std::string_view(m).substr(m.find(':') + 1);
            std::size_t b = 0;
            while (b <= rest.size())
            {
              std::size_t comma = rest.find(',', b);
              std::string w = lc(trim(rest.substr(b, comma == std::string_view::npos ? std::string_view::npos : comma - b)));
              if (!w.empty())
              {
                el.words.push_back(w);
              }
              if (comma == std::string_view::npos)
              {
                break;
              }
              b = comma + 1;
            }
          }
          else
          {
            el.kind = EKind::Regular;
          }
          stack.back().push_back(std::move(el));
          pos = e;
          continue;
        }
        if (ch == '[')
        {
          stack.emplace_back();
          pos++;
          continue;
        }
        if (ch == ']' && stack.size() > 1)
        {
          Elem el;
          el.kind = EKind::Opt;
          el.inner = std::move(stack.back());
          stack.pop_back();
          stack.back().push_back(std::move(el));
          pos++;
          continue;
        }
        std::size_t e = token_end(s, pos);
        if (e == 0)
        {
          break;
        }
        Elem el;
        el.text = lc(s.substr(pos, e - pos));
        stack.back().push_back(std::move(el));
        pos = e;
      }
      return std::move(stack[0]);
    }

    // Whether what a rule stands for opens a function: its first statement
    // (up to ';;') starts as a function's header does.
    bool is_header(std::string_view result)
    {
      std::size_t cut = result.find(";;");
      std::string first = lc(trim(result.substr(0, cut)));
      std::string_view f = first;
      auto word_at = [&](std::size_t i, std::string_view w) { return f.substr(i, w.size()) == w && !is_w(at(f, i + w.size())); };
      std::size_t i = 0;
      for (std::string_view w : { "user", "static", "main" })
      {
        if (f.substr(0, w.size()) == w && is_s(at(f, w.size())))
        {
          std::size_t k = w.size();
          while (is_s(at(f, k)))
          {
            k++;
          }
          if (word_at(k, "function"))
          {
            return true;
          }
          break;
        }
      }
      if (word_at(i, "function"))
      {
        return true;
      }
      if (word_at(0, "method"))
      {
        for (std::size_t k = 0; k + 6 <= f.size(); k++)
        {
          if (is_s(at(f, k)) && word_at(k + 1, "class"))
          {
            return true;
          }
        }
      }
      return word_at(0, "wsmethod");
    }

    std::vector<Rule> rules_of(std::string_view text)
    {
      std::vector<Rule> out;
      for (const Directive& d : directives_of(text))
      {
        std::string_view t = d.text;
        std::size_t arrow = t.find("=>");
        std::string_view pattern = t.substr(0, arrow);
        std::string_view result = arrow == std::string_view::npos ? std::string_view() : t.substr(arrow + 2);
        Rule r;
        r.command = d.command;
        r.exact = d.exact;
        r.pattern = elements_of(pattern);
        r.header = is_header(result);
        if (!r.pattern.empty())
        {
          out.push_back(std::move(r));
        }
      }
      return out;
    }

    // ---- the include files --------------------------------------------------
    // The names a text includes: '#include "x.ch"', "'x.ch'", '<x.ch>'.
    std::vector<std::string> includes_of(std::string_view text)
    {
      std::vector<std::string> out;
      for (std::string_view l : lines_of(text, true))
      {
        std::size_t k = 0;
        while (is_h(at(l, k)))
        {
          k++;
        }
        if (at(l, k) != '#')
        {
          continue;
        }
        k++;
        while (is_h(at(l, k)))
        {
          k++;
        }
        if (!iprefix(l, k, "include"))
        {
          continue;
        }
        k += 7;
        while (is_h(at(l, k)))
        {
          k++;
        }
        int q = at(l, k);
        if (q != '"' && q != '\'' && q != '<')
        {
          continue;
        }
        k++;
        std::size_t b = k;
        while (at(l, k) >= 0 && at(l, k) != '"' && at(l, k) != '\'' && at(l, k) != '>')
        {
          k++;
        }
        if (k == b || at(l, k) < 0)
        {
          continue;
        }
        out.push_back(trim(l.substr(b, k - b)));
      }
      return out;
    }

    // UTF-8 as windows-1252, when it is UTF-8 at all.
    bool utf8_to_cp1252(const std::string& in, std::string& out)
    {
      static const std::pair<unsigned, unsigned char> high[] =
      {
        { 0x20AC, 0x80 }, { 0x201A, 0x82 }, { 0x0192, 0x83 }, { 0x201E, 0x84 }, { 0x2026, 0x85 },
        { 0x2020, 0x86 }, { 0x2021, 0x87 }, { 0x02C6, 0x88 }, { 0x2030, 0x89 }, { 0x0160, 0x8A },
        { 0x2039, 0x8B }, { 0x0152, 0x8C }, { 0x017D, 0x8E }, { 0x2018, 0x91 }, { 0x2019, 0x92 },
        { 0x201C, 0x93 }, { 0x201D, 0x94 }, { 0x2022, 0x95 }, { 0x2013, 0x96 }, { 0x2014, 0x97 },
        { 0x02DC, 0x98 }, { 0x2122, 0x99 }, { 0x0161, 0x9A }, { 0x203A, 0x9B }, { 0x0153, 0x9C },
        { 0x017E, 0x9E }, { 0x0178, 0x9F },
      };
      out.clear();
      std::size_t i = 0;
      while (i < in.size())
      {
        unsigned char b = static_cast<unsigned char>(in[i]);
        unsigned cp = 0;
        int n = 0;
        if (b < 0x80) { cp = b; n = 0; }
        else if ((b & 0xE0) == 0xC0) { cp = b & 0x1F; n = 1; }
        else if ((b & 0xF0) == 0xE0) { cp = b & 0x0F; n = 2; }
        else if ((b & 0xF8) == 0xF0) { cp = b & 0x07; n = 3; }
        else { return false; }
        for (int k = 1; k <= n; k++)
        {
          if (i + k >= in.size())
          {
            return false;
          }
          unsigned char c = static_cast<unsigned char>(in[i + k]);
          if ((c & 0xC0) != 0x80)
          {
            return false;
          }
          cp = (cp << 6) | (c & 0x3F);
        }
        if ((n == 1 && cp < 0x80) || (n == 2 && cp < 0x800) || (n == 3 && cp < 0x10000) || cp > 0x10FFFF
            || (cp >= 0xD800 && cp <= 0xDFFF))
        {
          return false;
        }
        if (cp < 0x100)
        {
          out += static_cast<char>(cp);
        }
        else
        {
          char c = '?';
          for (auto [u, w] : high)
          {
            if (u == cp)
            {
              c = static_cast<char>(w);
              break;
            }
          }
          out += c;
        }
        i += n + 1;
      }
      return true;
    }

    // A file's text, when it is text: TOTVS' include files start '#zip' and
    // are compressed; those are skipped.
    bool text_of(const std::filesystem::path& p, std::string& out)
    {
      std::ifstream in(p, std::ios::binary);
      if (!in)
      {
        return false;
      }
      std::ostringstream s;
      s << in.rdbuf();
      std::string bytes = s.str();
      if (bytes.size() >= 4 && bytes.compare(0, 4, "#zip") == 0)
      {
        return false;
      }
      std::string t;
      out = utf8_to_cp1252(bytes, t) ? t : bytes;
      return true;
    }

    // The rules of a text and of every include file found -- beside the
    // source, then in each include folder -- each file once.
    std::vector<Rule> rules_with_includes(std::string_view text, const std::optional<std::string>& dir,
                                          const std::vector<std::string>& dirs)
    {
      std::vector<Rule> rules = rules_of(text);
      std::unordered_set<std::string> seen;
      std::vector<std::string> todo = includes_of(text);
      std::size_t next = 0;
      while (next < todo.size())
      {
        std::string name = todo[next++];
        if (!seen.insert(lc(name)).second)
        {
          continue;
        }
        std::vector<std::filesystem::path> places;
        if (dir)
        {
          places.emplace_back(*dir);
        }
        for (const std::string& d : dirs)
        {
          places.emplace_back(d);
        }
        for (const auto& d : places)
        {
          std::filesystem::path p = d / name;
          std::error_code ec;
          if (!std::filesystem::is_regular_file(p, ec))
          {
            continue;
          }
          std::string t;
          if (text_of(p, t))
          {
            std::vector<Rule> more = rules_of(t);
            rules.insert(rules.end(), more.begin(), more.end());
            std::vector<std::string> inc = includes_of(t);
            todo.insert(todo.end(), inc.begin(), inc.end());
          }
          break;
        }
      }
      return rules;
    }

    // ---- matching -----------------------------------------------------------
    class Matcher
    {
    public:
      // The translations, by their first word, for a translation inside a
      // marker's expression.
      std::unordered_map<std::string, std::vector<const Rule*>> by_first;

      // A word of the pattern against a word of the source: the same, any
      // case; for '#command', the first four letters or more of it.
      static bool same_word(const std::string& pat, const std::string& src, bool exact)
      {
        std::string s = lc(src);
        if (s == pat)
        {
          return true;
        }
        if (exact || s.size() < 4 || s.size() >= pat.size() || pat.compare(0, s.size(), s) != 0)
        {
          return false;
        }
        return std::all_of(pat.begin(), pat.end(), [](char c) { return is_w(static_cast<unsigned char>(c)); });
      }

      // The words that can come after element k: where a marker before them
      // stops.
      static void stops_after(const std::vector<Elem>& elems, std::size_t k, std::vector<std::string>& out)
      {
        for (std::size_t j = k + 1; j < elems.size(); j++)
        {
          const Elem& e = elems[j];
          if (e.kind == EKind::Lit)
          {
            out.push_back(e.text);
            return;
          }
          if (e.kind == EKind::Opt)
          {
            firsts_of(e, out);
            continue;
          }
          return;
        }
      }

      // stops-after([Elem.new(kind => 'lit', text => ''), |inner], 0), the
      // empty ones left out.
      static void firsts_of(const Elem& opt, std::vector<std::string>& out)
      {
        // (From the element before the first: -1, which wraps to 0 as the
        // first one looked at.)
        std::vector<std::string> got;
        stops_after(opt.inner, static_cast<std::size_t>(-1), got);
        for (std::string& w : got)
        {
          if (!w.empty())
          {
            out.push_back(std::move(w));
          }
        }
      }

      static bool ends_operand(const std::string& t)
      {
        int c = at(t, 0);
        return is_w(c) || c == '"' || c == '\'' || c == ')' || c == ']' || c == '}' || dot_logical(t);
      }

      static bool starts_operand(const std::string& t)
      {
        int c = at(t, 0);
        return is_w(c) || c == '"' || c == '\'' || c == '{' || dot_logical(t);
      }

      static bool dot_logical(const std::string& t)
      {
        return t.size() >= 3 && t[0] == '.' && (lower(static_cast<unsigned char>(t[1])) == 't'
                                                || lower(static_cast<unsigned char>(t[1])) == 'f') && t[2] == '.';
      }

      // An expression's tokens from i: brackets balanced, to a stop word at
      // depth zero, a comma -- unless commas -- or where a second expression
      // starts. Where it ends, or -1.
      int expression_end(const std::vector<Tok>& toks, int i, const std::vector<std::string>& stops, bool commas,
                         bool exact) const
      {
        int start = i;
        int depth = 0;
        int n = static_cast<int>(toks.size());
        while (i < n)
        {
          const std::string& t = toks[i].text;
          if (depth == 0 && i > start)
          {
            if (!commas && t == ",")
            {
              break;
            }
            bool stop = false;
            for (const std::string& s : stops)
            {
              if (same_word(s, t, exact))
              {
                stop = true;
                break;
              }
            }
            if (stop)
            {
              break;
            }
            if (ends_operand(toks[i - 1].text) && starts_operand(t))
            {
              break;
            }
          }
          // A translation inside it is one piece.
          int inner = translation_end(toks, i);
          if (inner > i)
          {
            i = inner;
            continue;
          }
          if (t == "(" || t == "[" || t == "{")
          {
            depth++;
          }
          else if (t == ")" || t == "]" || t == "}")
          {
            if (depth == 0)
            {
              break;
            }
            depth--;
          }
          i++;
        }
        return i > start ? i : -1;
      }

      // Where a translation of the source's that starts at token i ends, or
      // -1.
      int translation_end(const std::vector<Tok>& toks, int i) const
      {
        auto it = by_first.find(lc(toks[i].text));
        if (it == by_first.end())
        {
          return -1;
        }
        for (const Rule* r : it->second)
        {
          int end = match_elems(r->pattern, toks, i, r->exact, {});
          if (end > i)
          {
            return end;
          }
        }
        return -1;
      }

      // The elements against the tokens from i: where the match ends, or -1.
      int match_elems(const std::vector<Elem>& elems, const std::vector<Tok>& toks, int i, bool exact,
                      const std::vector<std::string>& outer) const
      {
        std::size_t k = 0;
        int n = static_cast<int>(toks.size());
        while (k < elems.size())
        {
          const Elem& e = elems[k];
          if (e.kind == EKind::Opt)
          {
            // A run of optional clauses, in any order, each at most once.
            std::size_t last = k;
            while (last + 1 < elems.size() && elems[last + 1].kind == EKind::Opt)
            {
              last++;
            }
            std::vector<std::string> after;
            stops_after(elems, last, after);
            after.insert(after.end(), outer.begin(), outer.end());
            std::vector<std::string> stops;
            for (std::size_t r = k; r <= last; r++)
            {
              firsts_of(elems[r], stops);
            }
            stops.insert(stops.end(), after.begin(), after.end());
            std::vector<bool> done(last - k + 1, false);
            for (;;)
            {
              bool moved = false;
              for (std::size_t r = k; r <= last; r++)
              {
                if (done[r - k])
                {
                  continue;
                }
                int end = match_elems(elems[r].inner, toks, i, exact, stops);
                if (end > i)
                {
                  i = end;
                  done[r - k] = true;
                  moved = true;
                }
              }
              if (!moved)
              {
                break;
              }
            }
            k = last + 1;
            continue;
          }
          if (i >= n)
          {
            return -1;
          }
          switch (e.kind)
          {
            case EKind::Lit:
              if (!same_word(e.text, toks[i].text, exact))
              {
                return -1;
              }
              i++;
              break;
            case EKind::Restricted:
            {
              bool any = false;
              for (const std::string& w : e.words)
              {
                if (same_word(w, toks[i].text, exact))
                {
                  any = true;
                  break;
                }
              }
              if (!any)
              {
                return -1;
              }
              i++;
              break;
            }
            case EKind::Wild:
              i = n;
              break;
            default:
            {
              std::vector<std::string> stops;
              stops_after(elems, k, stops);
              stops.insert(stops.end(), outer.begin(), outer.end());
              int end = expression_end(toks, i, stops, e.kind == EKind::List, exact);
              if (end < 0)
              {
                return -1;
              }
              i = end;
              break;
            }
          }
          k++;
        }
        return i;
      }
    };

    // ---- the uses in a source -----------------------------------------------
    // Where the line at from ends: the first "\r" or "\n".
    std::size_t line_end(const std::string& t, std::size_t from)
    {
      std::size_t e = t.find_first_of("\r\n", from);
      return e == std::string::npos ? t.size() : e;
    }

    // Clipper's comment lines, '*' first on the line, blanked too -- not a
    // line a ';' carries the one before on to, where a '*' multiplies.
    std::string star_lines_blank(const std::string& text)
    {
      std::string out;
      out.reserve(text.size());
      std::size_t pos = 0;
      std::size_t n = text.size();
      bool continued = false;
      while (pos < n)
      {
        std::size_t end = line_end(text, pos);
        std::string_view line = std::string_view(text).substr(pos, end - pos);
        std::size_t k = 0;
        while (is_h(at(line, k)))
        {
          k++;
        }
        if (!continued && at(line, k) == '*')
        {
          out.append(line.size(), ' ');
        }
        else
        {
          out += line;
          continued = ends_with_semi(line);
        }
        std::size_t brk = end >= n ? 0 : (text[end] == '\r' && end + 1 < n && text[end + 1] == '\n' ? 2 : 1);
        out.append(text, end, brk);
        pos = end + brk;
        if (brk == 0)
        {
          break;
        }
      }
      return out;
    }

    // Comments blanked to spaces, the line ends kept: what is left is code
    // and strings, at the same offsets.
    std::string without_comments(std::string_view src)
    {
      std::string text(src);
      std::string out;
      out.reserve(text.size());
      std::size_t n = text.size();
      std::size_t pos = 0;
      while (pos < n)
      {
        // the first of '"', "'", '//', '/*', '&&' from pos
        std::size_t best = n;
        int kind = -1;
        static const std::string_view marks[] = { "\"", "'", "//", "/*", "&&" };
        for (int k = 0; k < 5; k++)
        {
          std::size_t f = text.find(marks[k], pos);
          if (f != std::string::npos && f < best)
          {
            best = f;
            kind = k;
          }
        }
        out.append(text, pos, best - pos);
        if (best >= n)
        {
          break;
        }
        std::size_t end;
        if (kind < 2)
        {
          // A string: to its quote, or to the end of its line.
          std::size_t close = text.find(marks[kind][0], best + 1);
          if (close == std::string::npos)
          {
            close = n;
          }
          std::size_t eol = line_end(text, best + 1);
          end = close < eol ? close + 1 : eol;
          out.append(text, best, end - best);
        }
        else if (kind == 2 || kind == 4)
        {
          end = line_end(text, best);
          out.append(end - best, ' ');
        }
        else
        {
          std::size_t close = text.find("*/", best + 2);
          end = close == std::string::npos ? n : close + 2;
          for (std::size_t k = best; k < end; k++)
          {
            out += is_nn(static_cast<unsigned char>(text[k])) ? ' ' : text[k];
          }
        }
        pos = end;
      }
      return star_lines_blank(out);
    }

    // m:i/ '#' \h* [ 'x'? [ 'command' || 'translate' ] || 'include' ] /
    bool mentions_directive(std::string_view text)
    {
      for (std::size_t i = text.find('#'); i != std::string_view::npos; i = text.find('#', i + 1))
      {
        std::size_t k = i + 1;
        while (is_h(at(text, k)))
        {
          k++;
        }
        std::size_t x = lower(at(text, k)) == 'x' ? k + 1 : k;
        if (iprefix(text, x, "command") || iprefix(text, x, "translate") || iprefix(text, k, "command")
            || iprefix(text, k, "translate") || iprefix(text, k, "include"))
        {
          return true;
        }
      }
      return false;
    }
  }

  UserSpans user_spans(std::string_view text, const std::optional<std::string>& dir,
                       const std::vector<std::string>& dirs)
  {
    UserSpans spans;
    if (!mentions_directive(text))
    {
      return spans;
    }
    std::vector<Rule> rules = rules_with_includes(text, dir, dirs);
    if (rules.empty())
    {
      return spans;
    }
    // The last defined first.
    std::vector<const Rule*> commands;
    std::vector<const Rule*> translates;
    for (auto it = rules.rbegin(); it != rules.rend(); ++it)
    {
      if (it->command)
      {
        commands.push_back(&*it);
      }
      else if (it->first())
      {
        translates.push_back(&*it);
      }
    }
    Matcher m;
    for (const Rule* r : translates)
    {
      m.by_first[*r->first()].push_back(r);
    }

    std::string code = without_comments(text);
    std::vector<std::string_view> lines = lines_of(code, false);
    int offset = 0;
    std::size_t n = 0;
    while (n < lines.size())
    {
      // A logical line: on through the lines that end in ';'.
      std::vector<Tok> toks;
      for (;;)
      {
        std::string_view l = lines[n];
        std::size_t b = l.size();
        while (b > 0 && is_v(static_cast<unsigned char>(l[b - 1])))
        {
          b--;
        }
        std::string_view body = l.substr(0, b);
        tokens_of(body, offset, toks);
        offset += static_cast<int>(l.size());
        n++;
        if (!(ends_with_semi(body) && n < lines.size()))
        {
          break;
        }
        if (!toks.empty() && toks.back().text == ";")
        {
          toks.pop_back();
        }
      }
      if (toks.empty() || toks[0].text == "#")
      {
        continue;
      }
      bool done = false;
      for (const Rule* r : commands)
      {
        const std::string* first = r->first();
        if (!first || !Matcher::same_word(*first, toks[0].text, r->exact))
        {
          continue;
        }
        if (m.match_elems(r->pattern, toks, 0, r->exact, {}) == static_cast<int>(toks.size()))
        {
          spans.cmd[toks[0].from] = UserCmd{ toks.back().to, r->header };
          done = true;
          break;
        }
      }
      if (done)
      {
        continue;
      }
      int i = 0;
      int count = static_cast<int>(toks.size());
      while (i < count)
      {
        int end = -1;
        for (const Rule* r : translates)
        {
          if (!Matcher::same_word(*r->first(), toks[i].text, r->exact))
          {
            continue;
          }
          end = m.match_elems(r->pattern, toks, i, r->exact, {});
          if (end > i)
          {
            break;
          }
        }
        if (end > i)
        {
          // A translation that starts the statement takes it whole.
          if (i == 0)
          {
            spans.cmd[toks[0].from] = UserCmd{ toks.back().to, false };
            break;
          }
          spans.trans[toks[i].from] = toks[end - 1].to;
          i = end;
        }
        else
        {
          i++;
        }
      }
    }
    return spans;
  }
}
