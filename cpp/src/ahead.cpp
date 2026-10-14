// xc -- looking ahead, cheaply (see ahead.h). XC::Grammar's ahead(), the
// same answer for every text.

#include "ahead.h"

#include <string>

#include "chars.h"

namespace xc
{
  namespace
  {
    bool has(std::string_view s, std::string_view what) { return s.find(what) != std::string_view::npos; }

    // Strings and comments, which ahead() reads past -- the grammar's
    // 'noise': a '"' string or a "'" one (a "'" between two digits groups
    // them, '12'345', and is no string), to its quote or the line's end; a
    // '//' or '&&' comment; a closed '/* */'. The text without them.
    std::string without_noise(std::string_view t)
    {
      std::string out;
      out.reserve(t.size());
      std::size_t n = t.size();
      std::size_t i = 0;
      auto at = [&](std::size_t k) -> int { return k < n ? static_cast<unsigned char>(t[k]) : -1; };
      while (i < n)
      {
        int c = at(i);
        if (c == '"' || (c == '\'' && (!(i > 0 && is_d(at(i - 1))) || !is_d(at(i + 1)))))
        {
          // '"' <-["\n]>* '"'? -- "'" likewise: up to the quote or a line end
          std::size_t k = i + 1;
          while (k < n && at(k) != c && !is_nl(at(k)))
          {
            k++;
          }
          if (k < n && at(k) == c)
          {
            k++;
          }
          i = k;
          continue;
        }
        if ((c == '/' || c == '&') && at(i + 1) == c)
        {
          std::size_t k = i + 2;
          while (k < n && is_nn(at(k)))
          {
            k++;
          }
          i = k;
          continue;
        }
        if (c == '/' && at(i + 1) == '*')
        {
          std::size_t close = t.find("*/", i + 2);
          if (close != std::string_view::npos)
          {
            i = close + 2;
            continue;
          }
        }
        out += static_cast<char>(c);
        i++;
      }
      return out;
    }

    // <!after <[<>!=:+\-*/?]>> '=' <!before '='>
    bool lone_equals(const std::string& code)
    {
      for (std::size_t i = 0; i < code.size(); i++)
      {
        if (code[i] != '=')
        {
          continue;
        }
        if (i > 0)
        {
          char b = code[i - 1];
          if (b == '<' || b == '>' || b == '!' || b == '=' || b == ':' || b == '+' || b == '-' || b == '*'
              || b == '/' || b == '?')
          {
            continue;
          }
        }
        if (i + 1 < code.size() && code[i + 1] == '=')
        {
          continue;
        }
        return true;
      }
      return false;
    }
  }

  bool ahead(std::string_view text, Ahead what, bool item)
  {
    // Not a sign of what is looked for anywhere, nor a '/*' that may hide
    // one: no, before reading anything.
    std::string_view sign = what == Ahead::Pipe ? "|>" : "=";
    if (!has(text, sign) && !has(text, "/*"))
    {
      return false;
    }
    // The code alone, without strings and comments, unless a ';' or an
    // unclosed '/*' leaves it unsure.
    std::string code = without_noise(text);
    if (!has(code, ";") && !has(code, "/*"))
    {
      if (!has(code, sign))
      {
        return false;
      }
      if (what != Ahead::Pipe)
      {
        bool bind = false;
        for (std::string_view b : { ":=", "+=", "-=", "*=", "/=", "?=" })
        {
          if (has(code, b))
          {
            bind = true;
            break;
          }
        }
        if (!bind)
        {
          if (what == Ahead::Bind && item)
          {
            return false;
          }
          if (!lone_equals(code))
          {
            return false;
          }
        }
      }
    }
    std::size_t n = text.size();
    auto at = [&](std::size_t k) -> int { return k < n ? static_cast<unsigned char>(text[k]) : -1; };
    int depth = 0;
    int last = 0;                // the last code character: ';' continues the line
    std::size_t i = 0;
    while (i < n)
    {
      int c = at(i);
      int next = i + 1 < n ? at(i + 1) : 0;
      if (c == '"' || (c == '\'' && !(i > 0 && at(i - 1) >= '0' && at(i - 1) <= '9' && next >= '0' && next <= '9')))
      {
        // A string, to its closing quote or the end of the line.
        i++;
        while (i < n && at(i) != c && at(i) != 10)
        {
          i++;
        }
        last = c;
        i++;
        continue;
      }
      if ((c == '/' && next == '/') || (c == '&' && next == '&'))
      {
        while (i < n && at(i) != 10)
        {
          i++;
        }
        continue;
      }
      if (c == '/' && next == '*')
      {
        i += 2;
        while (i + 1 < n && !(at(i) == '*' && at(i + 1) == '/'))
        {
          i++;
        }
        if (i + 1 >= n)
        {
          return true;           // it goes on past what was read: cannot tell
        }
        i += 2;
        continue;
      }
      if (c == 10)
      {
        if (last != ';')
        {
          return false;          // the end of the statement, unless ';' goes on
        }
        last = 0;
        i++;
        continue;
      }
      if (c == '(' || c == '[' || c == '{')
      {
        depth++;
      }
      else if (c == ')' || c == ']' || c == '}')
      {
        if (--depth < 0)
        {
          return !item;          // an item ends here; a statement cannot tell
        }
      }
      else if (depth == 0)
      {
        if (item && c == ',')
        {
          return false;          // ',' ends an item
        }
        if (what == Ahead::Assign || what == Ahead::Bind)
        {
          // ':=', '+=', '-=', '*=', '/=', '?=', or '=' on its own -- not
          // '==', '<=', '>=', '!='. 'bind': not '=' on its own.
          if (next == '=' && (c == ':' || c == '+' || c == '-' || c == '*' || c == '/' || c == '?'))
          {
            return true;
          }
          if (c == '=' && what == Ahead::Assign)
          {
            if (next == '=')
            {
              i += 2;
              last = '=';
              continue;
            }
            int prev = i > 0 ? at(i - 1) : 0;
            if (!(prev == '<' || prev == '>' || prev == '!'))
            {
              return true;
            }
          }
        }
        else if (c == '|' && next == '>')
        {
          return true;
        }
      }
      if (!(c == ' ' || c == '\t' || c == 13))
      {
        last = c;
      }
      i++;
    }
    // The end of the text: of the statement, unless a ';' carries it on.
    return last == ';';
  }
}
