// xc -- pieces of source text (see text.h).

#include "text.h"

#include "chars.h"

namespace xc
{
  namespace
  {
    int at(std::string_view t, std::size_t i)
    {
      return i < t.size() ? static_cast<unsigned char>(t[i]) : -1;
    }

    bool is_space(int c) { return c >= 0 && (CHAR_CLASS[c] & C_S); }
    bool is_break(int c) { return c == '\r' || c == '\n'; }

    bool starts(std::string_view t, std::size_t i, std::string_view w)
    {
      return t.size() >= i + w.size() && t.compare(i, w.size(), w) == 0;
    }

    // The same, in any case (w in lower case).
    bool istarts(std::string_view t, std::size_t i, std::string_view w)
    {
      if (t.size() < i + w.size()) { return false; }
      for (std::size_t k = 0; k < w.size(); k++)
      {
        if (lower(static_cast<unsigned char>(t[i + k])) != static_cast<unsigned char>(w[k])) { return false; }
      }
      return true;
    }

    // The line break at or before p: where it starts, and where what follows
    // it starts -- a "\r\n" whole. False when there is none.
    bool break_before(std::string_view t, long p, std::size_t& start, std::size_t& after)
    {
      long k = p;
      while (k >= 0 && !is_break(at(t, static_cast<std::size_t>(k)))) { k--; }
      if (k < 0) { return false; }
      std::size_t u = static_cast<std::size_t>(k);
      if (t[u] == '\n' && u > 0 && t[u - 1] == '\r')
      {
        start = u - 1;
        after = u + 1;
      }
      else
      {
        start = u;
        after = u + char_len(t, u);
      }
      return true;
    }

    // After a ';': does the line end there, a comment aside? (/ ^ \h* [ [ '//'
    // || '&&' ] \N* || '/*' .*? '*/' \h* ]? \v /)
    bool line_ends_after(std::string_view t, std::size_t j)
    {
      std::size_t k = j;
      while (is_h(at(t, k))) { k++; }
      if (starts(t, k, "//") || starts(t, k, "&&"))
      {
        std::size_t m = k + 2;
        while (is_nn(at(t, m))) { m++; }
        if (is_v(at(t, m))) { return true; }
      }
      else if (starts(t, k, "/*"))
      {
        std::size_t e = k + 2;
        while ((e = t.find("*/", e)) != std::string_view::npos)
        {
          std::size_t m = e + 2;
          while (is_h(at(t, m))) { m++; }
          if (is_v(at(t, m))) { return true; }
          e++;
        }
      }
      return is_v(at(t, k));
    }

    // '#include "name"' at a line's start, any case (name in lower case).
    bool includes(std::string_view l, std::string_view name)
    {
      std::size_t k = 0;
      while (is_h(at(l, k))) { k++; }
      if (at(l, k) != '#') { return false; }
      k++;
      while (is_h(at(l, k))) { k++; }
      if (!istarts(l, k, "include")) { return false; }
      k += 7;
      while (is_h(at(l, k))) { k++; }
      if (at(l, k) != '"') { return false; }
      k++;
      if (name.empty())
      {
        // Any '.ch': <-["]>* '.ch"'
        std::size_t q = l.find('"', k);
        return q != std::string_view::npos && q >= k + 3 && istarts(l, q - 3, ".ch");
      }
      return istarts(l, k, name) && at(l, k + name.size()) == '"';
    }
  }

  std::vector<std::string> lines_of(std::string_view t, bool keep)
  {
    std::vector<std::string> out;
    std::size_t b = 0;
    std::size_t i = 0;
    while (i < t.size())
    {
      if (is_break(static_cast<unsigned char>(t[i])))
      {
        std::size_t e = i + char_len(t, i);
        out.emplace_back(t.substr(b, (keep ? e : i) - b));
        i = e;
        b = i;
      }
      else
      {
        i++;
      }
    }
    if (b < t.size()) { out.emplace_back(t.substr(b)); }
    return out;
  }

  std::vector<std::string> words(std::string_view s)
  {
    std::vector<std::string> out;
    std::size_t i = 0;
    while (i < s.size())
    {
      while (i < s.size() && is_space(static_cast<unsigned char>(s[i]))) { i++; }
      std::size_t b = i;
      while (i < s.size() && !is_space(static_cast<unsigned char>(s[i]))) { i++; }
      if (i > b) { out.emplace_back(s.substr(b, i - b)); }
    }
    return out;
  }

  std::string trim_trailing(std::string_view s)
  {
    std::size_t e = s.size();
    while (e > 0 && is_trim(static_cast<unsigned char>(s[e - 1]))) { e--; }
    return std::string(s.substr(0, e));
  }

  std::string join(const std::vector<std::string>& v, std::string_view sep)
  {
    std::string out;
    for (std::size_t i = 0; i < v.size(); i++)
    {
      if (i) { out += sep; }
      out += v[i];
    }
    return out;
  }

  std::size_t eol_from(std::string_view t, std::size_t i)
  {
    while (i < t.size() && !is_break(static_cast<unsigned char>(t[i]))) { i++; }
    return i;
  }

  bool star_comment(std::string_view t, std::size_t i)
  {
    if (!(i > 0 && at(t, i) == '*')) { return false; }
    std::size_t start = 0;
    std::size_t after = 0;
    if (!break_before(t, static_cast<long>(i) - 1, start, after)) { return false; }
    for (std::size_t k = after; k < i; k++)
    {
      if (!is_space(static_cast<unsigned char>(t[k]))) { return false; }
    }
    // The line before, its comment aside: does it end in a ';'?
    std::size_t from = 0;
    if (start > 0)
    {
      std::size_t s2 = 0;
      std::size_t a2 = 0;
      if (break_before(t, static_cast<long>(start) - 1, s2, a2)) { from = a2; }
    }
    std::string_view line = t.substr(from, start - from);
    std::size_t cut = line.size();
    for (std::size_t k = 0; k + 1 < line.size(); k++)
    {
      if ((line[k] == '/' && line[k + 1] == '/') || (line[k] == '&' && line[k + 1] == '&'))
      {
        cut = k;
        break;
      }
    }
    line = line.substr(0, cut);
    std::size_t e = line.size();
    while (e > 0 && is_h(static_cast<unsigned char>(line[e - 1]))) { e--; }
    return !(e > 0 && line[e - 1] == ';');
  }

  bool is_separator(std::string_view t, std::size_t i)
  {
    if (!(i > 0 && i + 1 < t.size())) { return false; }
    return t[i - 1] >= '0' && t[i - 1] <= '9' && t[i + 1] >= '0' && t[i + 1] <= '9';
  }

  std::pair<std::string, std::string> split_comment(std::string_view t)
  {
    std::string code;
    std::vector<std::string> comments;
    std::size_t i = 0;
    std::size_t n = t.size();
    char quote = 0;
    while (i < n)
    {
      std::size_t len = char_len(t, i);
      char c = t[i];
      if (quote)
      {
        // A string ends at its quote, or at the end of its line.
        if (c == quote || is_break(static_cast<unsigned char>(c))) { quote = 0; }
        code.append(t.substr(i, len));
        i += len;
      }
      else if (c == '"' || (c == '\'' && !is_separator(t, i)))
      {
        quote = c;
        code += c;
        i++;
      }
      else if (starts(t, i, "//") || starts(t, i, "&&") || star_comment(t, i))
      {
        std::size_t end = eol_from(t, i);
        comments.push_back(end >= i + 2 ? trim(t.substr(i + 2, end - i - 2)) : std::string());
        i = end;
      }
      else if (starts(t, i, "/*"))
      {
        std::size_t end = t.find("*/", i + 2);
        if (end == std::string_view::npos) { end = n - 2; }
        comments.push_back(end >= i + 2 ? join(words(t.substr(i + 2, end - i - 2)), " ") : std::string());
        code += ' ';
        i = end + 2;
      }
      else
      {
        code.append(t.substr(i, len));
        i += len;
      }
    }
    std::string comment;
    for (const std::string& c : comments)
    {
      if (c.empty()) { continue; }
      if (!comment.empty()) { comment += ' '; }
      comment += "// " + c;
    }
    return { trim_trailing(code), comment };
  }

  long comment_at(std::string_view t)
  {
    std::size_t i = 0;
    char quote = 0;
    while (i < t.size())
    {
      char c = t[i];
      if (quote)
      {
        if (c == quote || is_break(static_cast<unsigned char>(c))) { quote = 0; }
      }
      else if (c == '"' || (c == '\'' && !is_separator(t, i)))
      {
        quote = c;
      }
      else if (starts(t, i, "//") || starts(t, i, "&&") || starts(t, i, "/*") || star_comment(t, i))
      {
        return static_cast<long>(i);
      }
      i += char_len(t, i);
    }
    return -1;
  }

  std::size_t code_end(std::string_view t)
  {
    std::size_t i = 0;
    std::size_t n = t.size();
    std::size_t end = 0;
    char quote = 0;
    while (i < n)
    {
      char c = t[i];
      if (quote)
      {
        if (c == quote || is_break(static_cast<unsigned char>(c))) { quote = 0; }
        i += char_len(t, i);
        end = i;
      }
      else if (c == '"' || (c == '\'' && !is_separator(t, i)))
      {
        quote = c;
        end = ++i;
      }
      else if (starts(t, i, "//") || starts(t, i, "&&") || star_comment(t, i))
      {
        i = eol_from(t, i);
      }
      else if (starts(t, i, "/*"))
      {
        std::size_t e = t.find("*/", i + 2);
        i = (e == std::string_view::npos ? n - 2 : e) + 2;
      }
      else if (is_space(static_cast<unsigned char>(c)))
      {
        i += char_len(t, i);
      }
      else if (c == ';' && line_ends_after(t, i + 1))
      {
        // A ';' continuation: the rest of its line is not code.
        i++;
      }
      else
      {
        end = ++i;
      }
    }
    return end;
  }

  std::size_t last_from(std::string_view t, std::string_view word)
  {
    std::string l = lc(t);
    std::size_t found = std::string::npos;
    for (std::size_t k = 0; k + 3 <= l.size(); k++)
    {
      if (l.compare(k, 3, "end") != 0) { continue; }
      std::size_t m = k + 3;
      if (!is_space(at(l, m))) { continue; }
      while (is_space(at(l, m))) { m++; }
      if (l.compare(m, word.size(), word) == 0 && m + word.size() <= l.size()) { found = k; }
    }
    return found;
  }

  std::string add_includes(const std::string& out, const std::string& nl, bool advpl)
  {
    std::vector<std::string> all = lines_of(out);
    auto included = [&](std::string_view h)
    {
      for (const std::string& l : all)
      {
        if (includes(l, h)) { return true; }
      }
      return false;
    };
    std::vector<std::string> top;
    if (!included("totvs.ch")) { top.push_back("totvs.ch"); }
    std::string text = out;
    if (!advpl && !included("tlpp-core.th"))
    {
      std::vector<std::string> lines = lines_of(out, true);
      long last = -1;
      for (std::size_t i = 0; i < lines.size(); i++)
      {
        if (includes(lines[i], "")) { last = static_cast<long>(i); }
      }
      if (last >= 0)
      {
        std::string& l = lines[static_cast<std::size_t>(last)];
        if (l.empty() || !is_break(static_cast<unsigned char>(l.back()))) { l += nl; }
        lines.insert(lines.begin() + last + 1, "#include \"tlpp-core.th\"" + nl);
        text = join(lines, "");
      }
      else
      {
        top.push_back("tlpp-core.th");
      }
    }
    if (top.empty()) { return text; }
    std::vector<std::string> inc;
    for (const std::string& h : top) { inc.push_back("#include \"" + h + "\""); }
    return join(inc, nl) + nl + nl + text;
  }
}
