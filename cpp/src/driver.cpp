// xc -- one source compiled, as the driver compiles it (see driver.h).

#include "driver.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <sstream>

#include "chars.h"
#include "commands.h"
#include "emit.h"
#include "parser.h"
#include "text.h"

namespace xc
{
  namespace
  {
#ifdef _WIN32
    constexpr bool WINDOWS = true;
#else
    constexpr bool WINDOWS = false;
#endif

    // What is said of a source quotes it: windows-1252, said in UTF-8, as
    // bin/xc says it.
    std::string said(std::string_view t) { return cp1252_to_utf8(t); }

    // Why a source's bytes are UTF-8, not windows-1252 -- or nothing when
    // they are windows-1252: they start with UTF-8's byte-order mark, or what
    // is beyond ASCII in them is valid UTF-8.
    std::optional<std::string> utf8_reason(const std::string& b)
    {
      std::string fix = "Protheus' sources are windows-1252 (cp1252): save it so";
      if (b.size() >= 3 && static_cast<unsigned char>(b[0]) == 0xEF && static_cast<unsigned char>(b[1]) == 0xBB
          && static_cast<unsigned char>(b[2]) == 0xBF)
      {
        return "it starts with UTF-8's byte-order mark. " + fix;
      }
      std::size_t first = 0;
      while (first < b.size() && static_cast<unsigned char>(b[first]) < 0x80) { first++; }
      if (first == b.size()) { return std::nullopt; }
      std::string ignored;
      if (!utf8_to_cp1252(b, ignored)) { return std::nullopt; }
      std::ptrdiff_t line = 1 + std::count(b.begin(), b.begin() + static_cast<std::ptrdiff_t>(first), '\n');
      return "it is UTF-8 -- the first character beyond ASCII is on line " + std::to_string(line) + ". " + fix;
    }

    // The line (from 1) an offset is on, as XC::Source counts them.
    int line_at(const std::string& src, int o)
    {
      std::vector<std::size_t> starts;
      std::size_t b = 0;
      std::size_t i = 0;
      while (i < src.size())
      {
        if (src[i] == '\n' || src[i] == '\r')
        {
          starts.push_back(b);
          i += char_len(src, i);
          b = i;
        }
        else
        {
          i++;
        }
      }
      if (b < src.size()) { starts.push_back(b); }
      int lines = static_cast<int>(starts.size());
      starts.push_back(src.size());
      int row = 0;
      for (std::size_t r = 0; r < starts.size(); r++)
      {
        if (starts[r] <= static_cast<std::size_t>(o)) { row = static_cast<int>(r); }
      }
      return std::min(row + 1, std::max(1, lines));
    }

    // Whether a line is a 'local' declaration whole, its comment aside.
    bool late_declaration(const std::string& t)
    {
      if (!(t.size() >= 5 && lc(t.substr(0, 5)) == "local" && !(t.size() > 5 && is_w(static_cast<unsigned char>(t[5])))))
      {
        return false;
      }
      std::string code = trim(split_comment(t).first);
      Tree tree;
      Parser parser(code, {}, tree);
      return parser.read_declaration() != nullptr;
    }

    // What is said when a source does not parse: the line it stopped at, and
    // why, as far as can be told.
    std::string not_parsed(const std::string& src, const std::string& in, const UserSpans& spans, int furthest)
    {
      // Everything up to the end parsed, and the file still did not match: a
      // block was left open.
      if (trim(std::string_view(src).substr(std::min(static_cast<std::size_t>(furthest), src.size()))).empty())
      {
        return in + ": the file ends inside a block that was never closed\n";
      }
      int line = line_at(src, furthest);
      std::vector<std::string> lines = lines_of(src);
      std::string text = line - 1 < static_cast<int>(lines.size()) ? trim(lines[static_cast<std::size_t>(line - 1)]) : "";
      // A name xc keeps for itself is refused by the grammar, which can only
      // say the line does not parse. Read again with any name allowed, the
      // checks say which name and why.
      std::vector<Finding> names;
      {
        Tree tree;
        Parser again(src, spans.trans, tree, spans.cmd);
        again.any_name = true;
        if (Program* p = again.parse())
        {
          names = check_names(p);
        }
        else
        {
          Tree dt;
          Parser dp(text, {}, dt);
          dp.any_name = true;
          if (Declaration* d = dp.read_declaration())
          {
            for (Finding& f : check_declared_names(d)) { names.push_back({ line, f.message }); }
          }
        }
      }
      std::string out;
      if (!names.empty())
      {
        for (const Finding& f : names) { out += in + ":" + std::to_string(f.line) + ": " + said(f.message) + "\n"; }
        return out;
      }
      if (late_declaration(text))
      {
        return in + ":" + std::to_string(line) + ": 'local' cannot be declared here: every local comes before the "
               + "first statement of its function or its block -- '" + said(text) + "'\n";
      }
      return in + ":" + std::to_string(line) + ": cannot parse this line: " + said(text) + "\n";
    }
  }

  bool slurp(const std::string& path, std::string& out)
  {
    std::ifstream in(std::filesystem::path(path), std::ios::binary);
    if (!in) { return false; }
    std::ostringstream s;
    s << in.rdbuf();
    out = s.str();
    return true;
  }

  std::string folder_of(const std::string& p)
  {
    std::size_t cut = p.rfind('/');
    if constexpr (WINDOWS)
    {
      std::size_t b = p.rfind('\\');
      if (b != std::string::npos && (cut == std::string::npos || b > cut)) { cut = b; }
    }
    return cut != std::string::npos ? p.substr(0, cut) : ".";
  }

  Compiled compile(const std::string& path, const std::string& in, const CompileOptions& o)
  {
    Compiled c;
    std::string src;
    if (!slurp(path, src))
    {
      c.said = in + ": cannot be read\n";
      return c;
    }
    if (auto why = utf8_reason(src))
    {
      c.said = in + ": " + *why + "\n";
      return c;
    }
    UserSpans spans = user_spans(src, folder_of(path), o.includes);
    Tree tree;
    Parser parser(src, spans.trans, tree, spans.cmd);
    Program* prog = parser.parse();
    if (!prog)
    {
      c.said = not_parsed(src, in, spans, parser.furthest());
      return c;
    }

    // What xtpl refuses although it parses, and what it warns about.
    int nlines = static_cast<int>(lines_of(src).size());
    Checked checked = check_all(prog, nlines, o.dictionary, o.strict, std::string_view(src));
    for (const Finding& f : checked.warnings)
    {
      c.said += in + ":" + std::to_string(f.line) + ": warning: " + said(f.message) + "\n";
    }
    if (!checked.errors.empty())
    {
      for (const Finding& f : checked.errors) { c.said += in + ":" + std::to_string(f.line) + ": " + said(f.message) + "\n"; }
      return c;
    }

    // What xc cannot lower yet stops the compile, with --check too.
    try
    {
      c.tlpp = emit(prog, src);
    }
    catch (const NotLowered& e)
    {
      for (const Finding& f : e.problems)
      {
        c.said += in + ":" + std::to_string(f.line) + ": " + said(f.message) + " is not lowered yet\n";
      }
    }
    catch (const std::exception& e)
    {
      c.said += in + ": " + said(e.what()) + "\n";
    }
    return c;
  }
}
