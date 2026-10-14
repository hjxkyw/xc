// xc -- the driver.
//
// For now: comparing what the C++ parser reads with what the Raku xc read
// (tools/ast-json.raku).
//
//   xc --roots FILE.roots...     each expression of the file read again at
//                                its offset, as its form; the trees compared
//   xc --tree N.tree...          the whole source -- named by N.roots beside
//                                it --, its tree compared
//   xc --check N.check...        what the checks say of it, compared
//   xc --emit N.out...           the TL++ it becomes, compared
//   ... --dict sx3.csv [--strict]  with a dictionary
//   ... --time                   and how long the reading took

#include <chrono>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "check.h"
#include "emit.h"
#include "json.h"
#include "parser.h"

namespace
{
  bool slurp(const std::string& path, std::string& out)
  {
    std::ifstream in(path, std::ios::binary);
    if (!in)
    {
      return false;
    }
    std::ostringstream s;
    s << in.rdbuf();
    out = s.str();
    return true;
  }

  bool form_of(const std::string& name, xc::Form& f)
  {
    static const std::unordered_map<std::string, xc::Form> forms =
    {
      { "value", xc::Form::Value }, { "guardexpr", xc::Form::GuardExpr }, { "cond", xc::Form::Cond },
      { "expr", xc::Form::Expr }, { "lvalue", xc::Form::LValue }, { "callst", xc::Form::CallSt },
      { "pipest", xc::Form::PipeSt },
    };
    auto it = forms.find(name);
    if (it == forms.end())
    {
      return false;
    }
    f = it->second;
    return true;
  }

  struct Totals
  {
    long roots = 0;
    long differ = 0;
    long files = 0;
    double seconds = 0;
  };

  // One .roots file: false when one of its expressions differs.
  bool compare_roots(const std::string& path, bool time, Totals& totals)
  {
    std::ifstream in(path, std::ios::binary);
    if (!in)
    {
      std::cerr << path << ": cannot read it\n";
      return false;
    }
    std::string line;
    std::getline(in, line);
    if (line.rfind("file ", 0) != 0)
    {
      std::cerr << path << ": no 'file' line\n";
      return false;
    }
    std::string file = line.substr(5);
    std::getline(in, line);
    if (line == "none")
    {
      return true;               // the Raku xc does not read it
    }
    std::unordered_map<int, int> trans;
    {
      std::istringstream t(line.substr(5));
      int from = 0;
      int to = 0;
      while (t >> from >> to)
      {
        trans[from] = to;
      }
    }
    std::string src;
    if (!slurp(file, src))
    {
      std::cerr << file << ": cannot read it\n";
      return false;
    }
    struct Root
    {
      xc::Form form;
      int at;
      bool with;
      std::string expect;
    };
    std::vector<Root> roots;
    while (std::getline(in, line))
    {
      if (line.empty())
      {
        continue;
      }
      std::istringstream l(line);
      std::string form;
      int at = 0;
      int with = 0;
      l >> form >> at >> with;
      Root r;
      if (!form_of(form, r.form))
      {
        std::cerr << path << ": no form '" << form << "'\n";
        return false;
      }
      r.at = at;
      r.with = with != 0;
      std::size_t json = line.find('{');
      r.expect = json == std::string::npos ? "" : line.substr(json);
      roots.push_back(std::move(r));
    }
    totals.files++;
    xc::Tree tree;
    xc::Parser parser(src, trans, tree);
    int differ = 0;
    auto t0 = std::chrono::steady_clock::now();
    std::vector<xc::Expr*> got;
    got.reserve(roots.size());
    for (const Root& r : roots)
    {
      int end = 0;
      got.push_back(parser.read(r.form, r.at, r.with, end));
    }
    totals.seconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    for (std::size_t i = 0; i < roots.size(); i++)
    {
      totals.roots++;
      std::string json = xc::to_json(got[i]);
      if (json == roots[i].expect)
      {
        continue;
      }
      totals.differ++;
      if (differ++ < 3)
      {
        const std::string& a = roots[i].expect;
        std::size_t k = 0;
        while (k < a.size() && k < json.size() && a[k] == json[k])
        {
          k++;
        }
        std::size_t from = k > 80 ? k - 80 : 0;
        std::cout << file << " at " << roots[i].at << ":\n"
                  << "  raku: ..." << a.substr(from, 200) << "\n"
                  << "  c++:  ..." << json.substr(from, 200) << "\n";
      }
    }
    if (differ)
    {
      std::cout << file << ": " << differ << " of " << roots.size() << " differ\n";
    }
    else if (time)
    {
      std::cout << file << ": " << roots.size() << " expressions\n";
    }
    return differ == 0;
  }
}

namespace
{
  // One .tree file: false when the trees differ.
  bool compare_tree(const std::string& path, bool time, Totals& totals)
  {
    std::string roots = path.substr(0, path.size() - 5) + ".roots";
    std::ifstream rin(roots, std::ios::binary);
    std::string line;
    std::getline(rin, line);
    if (line.rfind("file ", 0) != 0)
    {
      std::cerr << roots << ": no 'file' line\n";
      return false;
    }
    std::string file = line.substr(5);
    std::ifstream in(path, std::ios::binary);
    std::string cmd_line;
    std::string trans_line;
    std::string expect;
    std::getline(in, cmd_line);
    if (cmd_line != "null")
    {
      std::getline(in, trans_line);
      std::getline(in, expect);
    }
    std::unordered_map<int, int> trans;
    std::unordered_map<int, xc::UserCmd> cmd;
    if (!trans_line.empty())
    {
      std::istringstream t(trans_line.substr(5));
      int from = 0;
      int to = 0;
      while (t >> from >> to)
      {
        trans[from] = to;
      }
      std::istringstream c(cmd_line.substr(3));
      std::string kind;
      while (c >> from >> to >> kind)
      {
        cmd[from] = xc::UserCmd{ to, kind == "header" };
      }
    }
    std::string src;
    if (!slurp(file, src))
    {
      std::cerr << file << ": cannot read it\n";
      return false;
    }
    totals.files++;
    // The source's own commands, found here: as the Raku xc found them?
    xc::UserSpans spans = xc::user_spans(src, std::nullopt, {});
    bool same_spans = spans.trans == trans && spans.cmd.size() == cmd.size();
    for (const auto& [from, c] : spans.cmd)
    {
      auto it = cmd.find(from);
      same_spans = same_spans && it != cmd.end() && it->second.end == c.end && it->second.header == c.header;
    }
    if (!same_spans && cmd_line != "null")
    {
      totals.differ++;
      std::cout << file << ": the source's own commands differ: " << spans.cmd.size() << " commands, "
                << spans.trans.size() << " translations here; " << cmd.size() << " and " << trans.size() << " there\n";
      return false;
    }
    xc::Tree tree;
    xc::Parser parser(src, spans.trans, tree, spans.cmd);
    auto t0 = std::chrono::steady_clock::now();
    xc::Program* prog = parser.parse();
    totals.seconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    std::string json = prog ? xc::to_json(prog) : "null";
    if (cmd_line == "null")
    {
      expect = "null";
    }
    if (json == expect)
    {
      if (time)
      {
        std::cout << file << ": the same\n";
      }
      return true;
    }
    totals.differ++;
    std::size_t k = 0;
    while (k < expect.size() && k < json.size() && expect[k] == json[k])
    {
      k++;
    }
    std::size_t from = k > 150 ? k - 150 : 0;
    std::cout << file << (prog ? "" : " (no parse, furthest " + std::to_string(parser.furthest()) + ")") << ":\n"
              << "  raku: ..." << expect.substr(from, 300) << "\n"
              << "  c++:  ..." << json.substr(from, 300) << "\n";
    return false;
  }
}

namespace
{
  // The file N.roots beside a golden file names.
  bool source_of(const std::string& path, std::size_t ext, std::string& file)
  {
    std::string roots = path.substr(0, path.size() - ext) + ".roots";
    std::ifstream rin(roots, std::ios::binary);
    std::string line;
    std::getline(rin, line);
    if (line.rfind("file ", 0) != 0)
    {
      std::cerr << roots << ": no 'file' line\n";
      return false;
    }
    file = line.substr(5);
    return true;
  }

  // Raku's .lines.elems: "\r\n", "\n" and "\r" end a line; no empty last
  // one.
  int lines_in(const std::string& t)
  {
    int n = 0;
    std::size_t i = 0;
    std::size_t b = 0;
    while (i < t.size())
    {
      if (t[i] == '\n' || t[i] == '\r')
      {
        n++;
        i += (t[i] == '\r' && i + 1 < t.size() && t[i + 1] == '\n') ? 2 : 1;
        b = i;
      }
      else
      {
        i++;
      }
    }
    return n + (b < t.size() ? 1 : 0);
  }

  // One .check file: false when the checks say something else.
  bool compare_check(const std::string& path, bool time, const xc::Dictionary& dictionary, bool strict,
                     Totals& totals)
  {
    std::string file;
    if (!source_of(path, 6, file))
    {
      return false;
    }
    std::string expect;
    if (!slurp(path, expect))
    {
      std::cerr << path << ": cannot read it\n";
      return false;
    }
    while (!expect.empty() && expect.back() == '\n')
    {
      expect.pop_back();
    }
    std::string src;
    if (!slurp(file, src))
    {
      std::cerr << file << ": cannot read it\n";
      return false;
    }
    totals.files++;
    xc::UserSpans spans = xc::user_spans(src, std::nullopt, {});
    xc::Tree tree;
    xc::Parser parser(src, spans.trans, tree, spans.cmd);
    auto t0 = std::chrono::steady_clock::now();
    xc::Program* prog = parser.parse();
    std::string got;
    if (!prog)
    {
      got = "null";
    }
    else
    {
      xc::Checked c = xc::check_all(prog, lines_in(src), dictionary, strict, src);
      for (const xc::Finding& f : c.errors)
      {
        got += "error " + std::to_string(f.line) + " " + xc::json_string(f.message) + "\n";
      }
      for (const xc::Finding& f : c.warnings)
      {
        got += "warning " + std::to_string(f.line) + " " + xc::json_string(f.message) + "\n";
      }
      if (got.empty())
      {
        got = "none";
      }
      else
      {
        got.pop_back();
      }
    }
    totals.seconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (got == expect)
    {
      if (time)
      {
        std::cout << file << ": the same\n";
      }
      return true;
    }
    totals.differ++;
    std::cout << file << ":\n";
    std::istringstream a(expect);
    std::istringstream b(got);
    std::string la;
    std::string lb;
    int shown = 0;
    while (shown < 6)
    {
      bool ha = static_cast<bool>(std::getline(a, la));
      bool hb = static_cast<bool>(std::getline(b, lb));
      if (!ha && !hb)
      {
        break;
      }
      if (ha && hb && la == lb)
      {
        continue;
      }
      std::cout << "  raku: " << (ha ? la : "-") << "\n  c++:  " << (hb ? lb : "-") << "\n";
      shown++;
    }
    return false;
  }
}

namespace
{
  // One .out file: false when the TL++ is not the same.
  bool compare_emit(const std::string& path, bool time, Totals& totals)
  {
    std::string file;
    if (!source_of(path, 4, file))
    {
      return false;
    }
    std::string expect;
    if (!slurp(path, expect))
    {
      std::cerr << path << ": cannot read it\n";
      return false;
    }
    std::string src;
    if (!slurp(file, src))
    {
      std::cerr << file << ": cannot read it\n";
      return false;
    }
    totals.files++;
    xc::UserSpans spans = xc::user_spans(src, std::nullopt, {});
    xc::Tree tree;
    xc::Parser parser(src, spans.trans, tree, spans.cmd);
    auto t0 = std::chrono::steady_clock::now();
    xc::Program* prog = parser.parse();
    std::string got;
    if (!prog)
    {
      got = "null\n";
    }
    else
    {
      try
      {
        got = "ok\n" + xc::emit(prog, src);
      }
      catch (const xc::NotLowered& e)
      {
        got = "not-lowered\n";
        for (const xc::Finding& f : e.problems)
        {
          got += std::to_string(f.line) + " " + xc::json_string(f.message) + "\n";
        }
      }
      catch (const std::exception& e)
      {
        got = "died " + xc::json_string(e.what()) + "\n";
      }
    }
    totals.seconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (got == expect)
    {
      if (time)
      {
        std::cout << file << ": the same\n";
      }
      return true;
    }
    totals.differ++;
    std::size_t k = 0;
    while (k < expect.size() && k < got.size() && expect[k] == got[k])
    {
      k++;
    }
    std::size_t from = expect.rfind('\n', k > 0 ? k - 1 : 0);
    from = from == std::string::npos ? 0 : from + 1;
    for (int n = 0; n < 2 && from > 0; n++)
    {
      std::size_t p = expect.rfind('\n', from - 2);
      from = p == std::string::npos ? 0 : p + 1;
    }
    std::cout << file << ": differs at byte " << k << "\n"
              << "  raku: " << xc::json_string(expect.substr(from, k - from + 160)) << "\n"
              << "  c++:  " << xc::json_string(got.substr(from, k - from + 160)) << "\n";
    return false;
  }
}

int main(int argc, char** argv)
{
  std::vector<std::string> args(argv + 1, argv + argc);
  if (args.empty() || (args[0] != "--roots" && args[0] != "--tree" && args[0] != "--check" && args[0] != "--emit"))
  {
    std::cerr << "usage: xc --roots|--tree|--check|--emit [--time] FILE...\n";
    return 2;
  }
  bool emits = args[0] == "--emit";
  bool trees = args[0] == "--tree";
  bool checks = args[0] == "--check";
  bool time = false;
  bool strict = false;
  xc::Dictionary dictionary;
  Totals totals;
  bool ok = true;
  for (std::size_t i = 1; i < args.size(); i++)
  {
    if (args[i] == "--time")
    {
      time = true;
      continue;
    }
    if (args[i] == "--strict")
    {
      strict = true;
      continue;
    }
    if (args[i] == "--dict" && i + 1 < args.size())
    {
      try
      {
        dictionary = xc::load_dictionary(args[++i]);
      }
      catch (const std::exception& e)
      {
        std::cerr << e.what() << "\n";
        return 2;
      }
      continue;
    }
    ok = (emits   ? compare_emit(args[i], time, totals)
          : checks  ? compare_check(args[i], time, dictionary, strict, totals)
          : trees ? compare_tree(args[i], time, totals)
                  : compare_roots(args[i], time, totals)) && ok;
  }
  if (trees || checks || emits)
  {
    std::cout << totals.files << " files, " << totals.differ << " differ";
  }
  else
  {
    std::cout << totals.files << " files, " << totals.roots << " expressions, " << totals.differ << " differ";
  }
  if (time)
  {
    std::cout << ", read in " << totals.seconds << " s";
  }
  std::cout << "\n";
  return ok ? 0 : 1;
}
