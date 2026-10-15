// xc -- compiles xtpl sources to TL++ (bin/xc, in C++).
//
//   xc file.xtpl                writes file.tlpp next to it
//   xc file.xtpl out.tlpp       writes out.tlpp
//   xc a.xtpl b.xtpl src/       each one next to itself -- a folder stands
//                               for every .xtpl under it
//
//   --check             checks, and writes nothing: everything that would stop
//                       the compile is reported, the warnings too
//   --outdir=DIR        each .tlpp into DIR, not next to its source
//   --includes=DIRS     where to look for the include files a source names,
//                       after its own folder ('a;b', as the AppServer's
//                       -includes)
//   --dict sx3.csv      checks the fields used against an exported SX3
//   --dict-strict       and what it finds is an error, not a warning
//
// A source is windows-1252 (cp1252), as Protheus' are, and so is its .tlpp;
// a file in UTF-8 is refused. A file that does not parse, that the checks
// refuse, or that uses what xc cannot lower yet gets no .tlpp, and the others
// go on; the exit code is 1 if any failed. What it says, it says as bin/xc
// does.

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "chars.h"
#include "check.h"
#include "commands.h"
#include "emit.h"
#include "parser.h"
#include "text.h"

namespace fs = std::filesystem;

namespace
{
#ifdef _WIN32
  const bool WINDOWS = true;
#else
  const bool WINDOWS = false;
#endif

  const std::string USAGE =
    "usage: xc [--check] [--includes=DIRS] [--dict sx3.csv [--dict-strict]] file.xtpl [out.tlpp]\n"
    "       xc [--check] [--outdir=DIR] [--includes=DIRS] [--dict sx3.csv [--dict-strict]] file-or-folder ...";

  // What is said of a source quotes it: windows-1252, said in UTF-8, as
  // bin/xc says it.
  std::string said(std::string_view t) { return xc::cp1252_to_utf8(t); }

  [[noreturn]] void usage_error(const std::string& message)
  {
    std::cerr << message << "\n";
    std::exit(2);
  }

  bool slurp(const std::string& path, std::string& out)
  {
    std::ifstream in(fs::path(path), std::ios::binary);
    if (!in) { return false; }
    std::ostringstream s;
    s << in.rdbuf();
    out = s.str();
    return true;
  }

  bool is_dir(const std::string& p)
  {
    std::error_code e;
    return fs::is_directory(fs::path(p), e);
  }

  bool is_file(const std::string& p)
  {
    std::error_code e;
    return fs::is_regular_file(fs::path(p), e);
  }

  bool ends_with_ci(const std::string& s, const std::string& tail)
  {
    return s.size() >= tail.size() && xc::lc(s.substr(s.size() - tail.size())) == tail;
  }

  // Every .xtpl under a folder, sorted, its subfolders' in their place.
  void sources_under(const std::string& dir, std::vector<std::string>& out)
  {
    std::vector<std::string> entries;
    std::error_code e;
    for (const fs::directory_entry& d : fs::directory_iterator(fs::path(dir), e))
    {
      std::string name = d.path().filename().string();
      entries.push_back((!dir.empty() && dir.back() == '/' ? dir : dir + "/") + name);
    }
    std::sort(entries.begin(), entries.end());
    for (const std::string& p : entries)
    {
      if (is_dir(p))
      {
        sources_under(p, out);
        continue;
      }
      std::string name = fs::path(p).filename().string();
      std::size_t dot = name.rfind('.');
      if (dot != std::string::npos && dot > 0 && xc::lc(name.substr(dot + 1)) == "xtpl") { out.push_back(p); }
    }
  }

  // The folder a path is in -- at '\' too on Windows.
  std::string folder_of(const std::string& p)
  {
    std::size_t cut = p.rfind('/');
    if (WINDOWS)
    {
      std::size_t b = p.rfind('\\');
      if (b != std::string::npos && (cut == std::string::npos || b > cut)) { cut = b; }
    }
    return cut != std::string::npos ? p.substr(0, cut) : ".";
  }

  // Why a source's bytes are UTF-8, not windows-1252 -- or nothing when they
  // are windows-1252: they start with UTF-8's byte-order mark, or what is
  // beyond ASCII in them is valid UTF-8.
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
    if (!xc::utf8_to_cp1252(b, ignored)) { return std::nullopt; }
    long line = 1 + std::count(b.begin(), b.begin() + static_cast<std::ptrdiff_t>(first), '\n');
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
        i += xc::char_len(src, i);
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
    if (!(t.size() >= 5 && xc::lc(t.substr(0, 5)) == "local"
          && !(t.size() > 5 && xc::is_w(static_cast<unsigned char>(t[5])))))
    {
      return false;
    }
    std::string code = xc::trim(xc::split_comment(t).first);
    xc::Tree tree;
    xc::Parser parser(code, {}, tree);
    return parser.read_declaration() != nullptr;
  }

  struct Options
  {
    bool check = false;
    bool strict = false;
    std::vector<std::string> includes;
    xc::Dictionary dictionary;
  };

  // One source: read, parsed, checked, lowered, and -- but with --check --
  // written. What stops it is reported, and it returns false.
  bool compile(const std::string& in, const std::string& out, const Options& o)
  {
    std::string src;
    if (!slurp(in, src))
    {
      std::cerr << in << ": cannot be read\n";
      return false;
    }
    if (auto why = utf8_reason(src))
    {
      std::cerr << in << ": " << *why << "\n";
      return false;
    }
    std::string dir = folder_of(in);
    xc::UserSpans spans = xc::user_spans(src, dir, o.includes);
    xc::Tree tree;
    xc::Parser parser(src, spans.trans, tree, spans.cmd);
    xc::Program* prog = parser.parse();
    if (!prog)
    {
      int furthest = parser.furthest();
      // Everything up to the end parsed, and the file still did not match: a
      // block was left open.
      if (xc::trim(std::string_view(src).substr(std::min(static_cast<std::size_t>(furthest), src.size()))).empty())
      {
        std::cerr << in << ": the file ends inside a block that was never closed\n";
        return false;
      }
      int line = line_at(src, furthest);
      std::vector<std::string> lines = xc::lines_of(src);
      std::string text = line - 1 < static_cast<int>(lines.size()) ? xc::trim(lines[static_cast<std::size_t>(line - 1)]) : "";
      // A name xc keeps for itself is refused by the grammar, which can only
      // say the line does not parse. Read again with any name allowed, the
      // checks say which name and why.
      std::vector<xc::Finding> names;
      {
        xc::Tree again_tree;
        xc::Parser again(src, spans.trans, again_tree, spans.cmd);
        again.any_name = true;
        if (xc::Program* p = again.parse())
        {
          names = xc::check_names(p);
        }
        else
        {
          xc::Tree dt;
          xc::Parser dp(text, {}, dt);
          dp.any_name = true;
          if (xc::Declaration* d = dp.read_declaration())
          {
            for (xc::Finding& f : xc::check_declared_names(d)) { names.push_back({ line, f.message }); }
          }
        }
      }
      if (!names.empty())
      {
        for (const xc::Finding& f : names) { std::cerr << in << ":" << f.line << ": " << said(f.message) << "\n"; }
        return false;
      }
      if (late_declaration(text))
      {
        std::cerr << in << ":" << line << ": 'local' cannot be declared here: every local comes before the first "
                  << "statement of its function or its block -- '" << said(text) << "'\n";
        return false;
      }
      std::cerr << in << ":" << line << ": cannot parse this line: " << said(text) << "\n";
      return false;
    }

    // What xtpl refuses although it parses, and what it warns about.
    int nlines = static_cast<int>(xc::lines_of(src).size());
    xc::Checked checked = xc::check_all(prog, nlines, o.dictionary, o.strict, std::string_view(src));
    for (const xc::Finding& f : checked.warnings)
    {
      std::cerr << in << ":" << f.line << ": warning: " << said(f.message) << "\n";
    }
    if (!checked.errors.empty())
    {
      for (const xc::Finding& f : checked.errors) { std::cerr << in << ":" << f.line << ": " << said(f.message) << "\n"; }
      return false;
    }

    // Lowered with --check too: what xc cannot lower yet would stop the compile.
    std::string tlpp;
    try
    {
      tlpp = xc::emit(prog, src);
    }
    catch (const xc::NotLowered& e)
    {
      for (const xc::Finding& f : e.problems)
      {
        std::cerr << in << ":" << f.line << ": " << said(f.message) << " is not lowered yet\n";
      }
      return false;
    }
    catch (const std::exception& e)
    {
      std::cerr << in << ": " << said(e.what()) << "\n";
      return false;
    }

    if (o.check)
    {
      std::cout << in << ": ok\n";
    }
    else
    {
      std::ofstream f(fs::path(out), std::ios::binary);
      f << tlpp;
      if (!f)
      {
        std::cerr << in << ": " << out << " cannot be written\n";
        return false;
      }
      std::cout << in << " -> " << out << "\n";
    }
    return true;
  }

  // The file a path names, the same however the path is written: absolute,
  // with no '.' in it; on Windows with '/' throughout and in lower case.
  std::string file_key(const std::string& p)
  {
    std::string s = p;
    if (WINDOWS)
    {
      std::replace(s.begin(), s.end(), '\\', '/');
      bool absolute = (s.size() >= 3 && xc::is_alpha(static_cast<unsigned char>(s[0])) && s[1] == ':' && s[2] == '/')
                      || (!s.empty() && s[0] == '/');
      if (!absolute)
      {
        std::string cwd = fs::current_path().string();
        std::replace(cwd.begin(), cwd.end(), '\\', '/');
        while (!cwd.empty() && cwd.back() == '/') { cwd.pop_back(); }
        s = cwd + "/" + s;
      }
      std::string out;
      for (std::size_t i = 0; i < s.size(); i++)
      {
        out += s[i];
        if (s[i] == '/')
        {
          while (s.compare(i + 1, 2, "./") == 0) { i += 2; }
        }
      }
      return xc::lc(out);
    }
    if (s.empty() || s[0] != '/') { s = fs::current_path().string() + "/" + s; }
    // $*SPEC.canonpath: no '//', no '.' segment, no trailing '/'.
    std::vector<std::string> parts;
    std::size_t b = 1;
    while (b <= s.size())
    {
      std::size_t e = s.find('/', b);
      if (e == std::string::npos) { e = s.size(); }
      std::string seg = s.substr(b, e - b);
      if (!seg.empty() && seg != ".") { parts.push_back(seg); }
      b = e + 1;
    }
    return "/" + xc::join(parts, "/");
  }

  // A source's name without its folder and its extension.
  std::string stem(const std::string& in)
  {
    std::size_t cut = in.find_last_of(WINDOWS ? "\\/:" : "/");
    std::string name = cut == std::string::npos ? in : in.substr(cut + 1);
    std::size_t dot = name.rfind('.');
    return dot == std::string::npos ? name : name.substr(0, dot);
  }
}

int main(int argc, char** argv)
{
  std::vector<std::string> args(argv + 1, argv + argc);
  Options o;
  std::optional<std::string> dict_path;
  std::optional<std::string> outdir;
  std::vector<std::string> given;
  for (std::size_t i = 0; i < args.size(); i++)
  {
    const std::string& a = args[i];
    if (a == "--dict")
    {
      if (i + 1 >= args.size()) { usage_error(USAGE); }
      dict_path = args[++i];
    }
    else if (a == "--dict-strict") { o.strict = true; }
    else if (a == "--check") { o.check = true; }
    else if (a.rfind("--outdir=", 0) == 0 && a.size() > 9) { outdir = a.substr(9); }
    else if (a.rfind("--includes=", 0) == 0 && a.size() > 11)
    {
      std::string list = a.substr(11);
      std::size_t b = 0;
      while (b <= list.size())
      {
        std::size_t e = list.find_first_of(";,", b);
        if (e == std::string::npos) { e = list.size(); }
        if (e > b) { o.includes.push_back(list.substr(b, e - b)); }
        b = e + 1;
      }
    }
    else if (a.rfind("--", 0) == 0) { usage_error(a + ": no such option\n" + USAGE); }
    else { given.push_back(a); }
  }
  if (given.empty()) { usage_error(USAGE); }
  if (o.strict && !dict_path) { usage_error("--dict-strict needs --dict"); }
  if (dict_path && !is_file(*dict_path)) { usage_error(*dict_path + ": no such file"); }

  // 'file.xtpl out.tlpp': the one form with an output named.
  std::optional<std::string> named_out;
  if (given.size() == 2 && ends_with_ci(given[1], ".tlpp") && !is_dir(given[1]))
  {
    named_out = given.back();
    given.pop_back();
  }
  if (o.check && named_out) { usage_error("--check writes nothing: no output to name"); }
  if (outdir && named_out) { usage_error("--outdir with an output named: one or the other"); }
  if (named_out && is_dir(given[0])) { usage_error(*named_out + ": a .tlpp is named only for a single source"); }

  if (dict_path)
  {
    try
    {
      o.dictionary = xc::load_dictionary(*dict_path);
    }
    catch (const std::exception& e)
    {
      std::cerr << e.what() << "\n";
      return 1;
    }
  }

  std::vector<std::string> sources;
  int missing = 0;
  for (const std::string& g : given)
  {
    if (is_dir(g))
    {
      std::vector<std::string> found;
      sources_under(g, found);
      if (!found.empty()) { sources.insert(sources.end(), found.begin(), found.end()); }
      else
      {
        std::cerr << g << ": no .xtpl files in it\n";
        missing++;
      }
    }
    else if (is_file(g)) { sources.push_back(g); }
    else
    {
      std::cerr << g << ": no such file\n";
      missing++;
    }
  }

  // A source given twice -- itself and in its folder -- is compiled once.
  {
    std::unordered_set<std::string> seen;
    std::vector<std::string> once;
    for (const std::string& s : sources)
    {
      if (seen.insert(file_key(s)).second) { once.push_back(s); }
    }
    sources = once;
  }

  // --outdir: every .tlpp into one folder, named for its source.
  const std::string sep = WINDOWS ? "\\" : "/";
  if (outdir)
  {
    std::unordered_map<std::string, std::string> seen;
    for (const std::string& in : sources)
    {
      std::string k = xc::lc(stem(in));
      if (auto it = seen.find(k); it != seen.end())
      {
        usage_error(in + " and " + it->second + ": both would be " + stem(in) + ".tlpp in " + *outdir);
      }
      seen[k] = in;
    }
    if (!o.check)
    {
      std::error_code e;
      fs::create_directories(fs::path(*outdir), e);
    }
  }

  int failed = missing;
  for (const std::string& in : sources)
  {
    std::string out;
    if (named_out)
    {
      out = *named_out;
    }
    else if (outdir)
    {
      std::string d = *outdir;
      while (!d.empty() && (d.back() == '/' || d.back() == '\\')) { d.pop_back(); }
      out = d + sep + stem(in) + ".tlpp";
    }
    else
    {
      // The extension goes: the last '.' with no '.', '/' or '\' after it.
      std::size_t dot = in.rfind('.');
      bool ext = dot != std::string::npos && in.find_first_of("/\\", dot) == std::string::npos;
      out = (ext ? in.substr(0, dot) : in) + ".tlpp";
    }
    if (!compile(in, out, o)) { failed++; }
  }

  // A word at the end when there was more than one.
  int total = static_cast<int>(sources.size()) + missing;
  if (total > 1)
  {
    int done = total - failed;
    std::cout << "xc: " << total << " files, " << done << (o.check ? " checked ok" : " compiled")
              << (failed ? ", " + std::to_string(failed) + " failed" : "") << "\n";
  }
  return failed ? 1 : 0;
}
