// xc -- one source compiled, as the driver compiles it (see driver.h).

#include "driver.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <memory>
#include <sstream>
#include <unordered_map>
#include <unordered_set>

#include "bytecode.h"
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

    // What is said of a source quotes it: windows-1252, said in UTF-8.
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

    // ---- headers ------------------------------------------------------------
    // A header (.xth) a file includes: read, parsed and checked as a file of
    // its own, the headers it includes first; its types are the file's too.
    struct Header
    {
      std::string name;                    // as the '#include' names it
      std::string text;
      Tree tree;
      Program* prog = nullptr;
      std::vector<TypeDef*> own;           // its own types, not its headers'
      std::vector<const Header*> uses;     // the headers it includes
    };

    struct Headers
    {
      std::vector<std::unique_ptr<Header>> all;
      std::unordered_map<std::string, const Header*> by_path;   // null while one is read
    };

    bool header_name(const std::string& n)
    {
      return n.size() > 4 && lc(n.substr(n.size() - 4)) == ".xth";
    }

    // Where an include file is: the folder of the file that includes it,
    // then the include folders; '' when it is in none.
    std::string find_include(const std::string& name, const std::string& dir, const std::vector<std::string>& dirs)
    {
      std::vector<std::string> places{ dir };
      places.insert(places.end(), dirs.begin(), dirs.end());
      for (const std::string& d : places)
      {
        std::string p = file_in(d, name);
        if (!p.empty()) { return p; }
      }
      return "";
    }

    // What a header holds that is no type and no directive: each source that
    // includes it would have its own.
    std::vector<Finding> not_header(const Program* p)
    {
      std::vector<Finding> out;
      auto no = [&](int line, const std::string& what)
      {
        out.push_back({ line, what + ": a header (.xth) holds types and directives, nothing else." });
      };
      for (const FunctionDef* f : p->functions)
      {
        if (f->of_type.empty()) { no(f->line, "'" + f->name + "' is a function"); }
      }
      for (const ClassDef* c : p->classes) { no(c->line, "'" + c->name + "' is a class"); }
      for (const MethodImpl* m : p->methods) { no(m->line, "'" + m->name + "' is a method of a class"); }
      for (const Declaration* d : p->statics) { no(d->line, "a Static"); }
      std::stable_sort(out.begin(), out.end(), [](const Finding& a, const Finding& b) { return a.line < b.line; });
      return out;
    }

    // The types of the headers given, and of theirs, each once -- those of
    // the headers a header includes before its own.
    void types_of(const std::vector<const Header*>& uses, std::vector<TypeDef*>& out,
                  std::unordered_set<const Header*>& seen)
    {
      for (const Header* u : uses)
      {
        if (!seen.insert(u).second) { continue; }
        types_of(u->uses, out, seen);
        out.insert(out.end(), u->own.begin(), u->own.end());
      }
    }

    // The headers' types put before a file's own: false, with what is said,
    // when two of them have the same name.
    bool with_headers(Program* p, const std::vector<const Header*>& uses, const std::string& in, std::string& out)
    {
      std::vector<TypeDef*> more;
      std::unordered_set<const Header*> seen;
      types_of(uses, more, seen);
      std::unordered_map<std::string, const TypeDef*> names;
      for (const TypeDef* t : more)
      {
        auto [was, fresh] = names.emplace(lc(t->name), t);
        if (!fresh)
        {
          out += in + ": '" + said(t->name) + "' is a type of " + said(was->second->header) + " and of "
                 + said(t->header) + "\n";
          return false;
        }
      }
      p->types.insert(p->types.begin(), more.begin(), more.end());
      return true;
    }

    const Header* load_header(const std::string& name, const std::string& dir, const CompileOptions& o,
                              Headers& hs, std::string& out);

    // The headers a text includes, each loaded: false, with what is said,
    // when one cannot be.
    bool load_uses(const std::string& text, const std::string& dir, const CompileOptions& o, Headers& hs,
                   std::vector<const Header*>& uses, std::string& out)
    {
      for (const std::string& n : include_names(text))
      {
        if (!header_name(n)) { continue; }
        const Header* h = load_header(n, dir, o, hs, out);
        if (!h) { return false; }
        uses.push_back(h);
      }
      return true;
    }

    // A header read and checked as a file of its own -- what is wrong with
    // it said of it, as compiling it says it --, then its types marked as
    // its, for the files that include it.
    const Header* load_header(const std::string& name, const std::string& dir, const CompileOptions& o,
                              Headers& hs, std::string& out)
    {
      std::string path = find_include(name, dir, o.includes);
      if (path.empty())
      {
        out += said(name) + ": no such header, in the folder of the file that includes it or in the include folders\n";
        return nullptr;
      }
      std::string key = lc(std::filesystem::path(path).lexically_normal().string());
      if (auto was = hs.by_path.find(key); was != hs.by_path.end())
      {
        if (!was->second) { out += said(name) + ": it includes itself, through the headers it includes\n"; }
        return was->second;
      }
      hs.by_path[key] = nullptr;
      auto h = std::make_unique<Header>();
      h->name = name;
      if (!slurp(path, h->text))
      {
        out += said(name) + ": cannot be read\n";
        return nullptr;
      }
      if (auto why = utf8_reason(h->text))
      {
        out += said(name) + ": " + *why + "\n";
        return nullptr;
      }
      std::string hdir = folder_of(path);
      if (!load_uses(h->text, hdir, o, hs, h->uses, out)) { return nullptr; }
      UserSpans spans = user_spans(h->text, hdir, o.includes);
      Parser parser(h->text, spans.trans, h->tree, spans.cmd);
      h->prog = parser.parse();
      if (!h->prog)
      {
        out += not_parsed(h->text, name, spans, parser.furthest());
        return nullptr;
      }
      h->own = h->prog->types;
      if (!with_headers(h->prog, h->uses, name, out)) { return nullptr; }
      std::vector<Finding> wrong = not_header(h->prog);
      Checked c = check_all(h->prog, static_cast<int>(lines_of(h->text).size()), o.dictionary, o.strict,
                            std::string_view(h->text), false, o.bytecode, include_defines(h->text, hdir, o.includes));
      wrong.insert(wrong.end(), c.errors.begin(), c.errors.end());
      std::stable_sort(wrong.begin(), wrong.end(), [](const Finding& a, const Finding& b) { return a.line < b.line; });
      for (const Finding& f : wrong) { out += said(name) + ":" + std::to_string(f.line) + ": " + said(f.message) + "\n"; }
      if (!wrong.empty()) { return nullptr; }
      if (!o.bytecode) { header_defaults(h->prog, h->text); }
      for (TypeDef* t : h->own) { t->header = name; }
      const Header* done = h.get();
      hs.by_path[key] = done;
      hs.all.push_back(std::move(h));
      return done;
    }

    // A header's '#ifndef' in its .th: XTH_ and its name, 'XTH_ITEM'.
    std::string guard_of(const std::string& path)
    {
      std::string stem = std::filesystem::path(path).stem().string();
      std::string g = "XTH_";
      for (char ch : stem) { g += is_w(static_cast<unsigned char>(ch)) && static_cast<unsigned char>(ch) < 128
                                  ? static_cast<char>(std::toupper(static_cast<unsigned char>(ch))) : '_'; }
      return g;
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

  bool is_header(const std::string& path)
  {
    return header_name(path) && path.find_first_of("/\\", path.size() - 4) == std::string::npos;
  }

  bool is_advpl(const std::string& path)
  {
    std::size_t dot = path.rfind('.');
    if (dot == std::string::npos || path.find_first_of("/\\", dot) != std::string::npos) { return false; }
    std::string ext = lc(path.substr(dot + 1));
    return ext == "prw" || ext == "prx";
  }

  Compiled compile(const std::string& path, const std::string& in, const CompileOptions& o)
  {
    bool advpl = is_advpl(path);
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
    bool header = is_header(path);
    if (header && o.bytecode)
    {
      c.said = in + ": a header (.xth) is made no bytecode: each source that includes it has its types\n";
      return c;
    }
    UserSpans spans = user_spans(src, folder_of(path), o.includes);
    Tree tree;
    Parser parser(src, spans.trans, tree, spans.cmd);
    parser.advpl = advpl;
    Program* prog = parser.parse();
    if (!prog)
    {
      c.said = not_parsed(src, in, spans, parser.furthest());
      return c;
    }

    // The types of the headers it includes (.xth), each read and checked as
    // a file of its own, are its own too.
    Headers headers;
    std::vector<const Header*> uses;
    if (!load_uses(src, folder_of(path), o, headers, uses, c.said) || !with_headers(prog, uses, in, c.said))
    {
      return c;
    }

    // What xtpl refuses although it parses, and what it warns about.
    int nlines = static_cast<int>(lines_of(src).size());
    std::vector<std::string> defines = include_defines(src, folder_of(path), o.includes);
    Checked checked = check_all(prog, nlines, o.dictionary, o.strict, std::string_view(src), advpl, o.bytecode,
                                defines);
    if (header)
    {
      std::vector<Finding> wrong = not_header(prog);
      wrong.insert(wrong.end(), checked.errors.begin(), checked.errors.end());
      std::stable_sort(wrong.begin(), wrong.end(), [](const Finding& a, const Finding& b) { return a.line < b.line; });
      checked.errors = wrong;
    }
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
      if (o.bytecode)
      {
        std::size_t cut = path.find_last_of(WINDOWS ? "\\/:" : "/");
        c.output = bytecode(prog, src, advpl, cut == std::string::npos ? path : path.substr(cut + 1), defines);
      }
      else
      {
        c.output = emit(prog, src, advpl, header ? guard_of(path) : "");
      }
    }
    catch (const NotLowered& e)
    {
      for (const Finding& f : e.problems)
      {
        c.said += in + ":" + std::to_string(f.line) + ": " + said(f.message) + " is not lowered yet\n";
      }
    }
    catch (const NotBytecode& e)
    {
      for (const Finding& f : e.problems)
      {
        c.said += in + ":" + std::to_string(f.line) + ": " + said(f.message) + " cannot become bytecode yet\n";
      }
    }
    catch (const std::exception& e)
    {
      c.said += in + ": " + said(e.what()) + "\n";
    }
    return c;
  }
}
