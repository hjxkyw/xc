// xc-cases -- xc's tests as data: each case a source and what xc makes of
// it, compiled as the driver compiles it and compared.
//
//   xc-cases FOLDER...              compares; 1 when a case differs
//   xc-cases --update FOLDER...     writes what xc makes now -- after a change
//                                   that is meant; the diff is the review
//
// A case is NAME.xtpl under a folder -- or NAME.prw, an AdvPL source --
// with beside it:
//
//   NAME.tlpp   the TL++ xc writes for it; none when it writes nothing --
//               for a NAME.prw, NAME.out.prw: the AdvPL xc writes
//   NAME.err    what xc says of it -- warnings, errors, the line it could not
//               parse -- the source named NAME.xtpl; none when it says nothing
//   NAME.args   the options it is compiled with, when it has any: --dict FILE,
//               --dict-strict, --includes=DIRS, the paths from its folder
//
// Include files a case names are beside it, in its folder. CMake runs it as
// a test (ctest), on cpp/tests/cases.

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#include "check.h"
#include "driver.h"
#include "text.h"

namespace fs = std::filesystem;

namespace
{
  void cases_under(const fs::path& dir, std::vector<fs::path>& out)
  {
    std::vector<fs::path> entries;
    for (const fs::directory_entry& d : fs::directory_iterator(dir)) { entries.push_back(d.path()); }
    std::sort(entries.begin(), entries.end());
    for (const fs::path& p : entries)
    {
      std::string name = p.filename().string();
      bool prw = p.extension() == ".prw" && name.size() > 8 && name.substr(name.size() - 8) != ".out.prw";
      if (fs::is_directory(p)) { cases_under(p, out); }
      else if (p.extension() == ".xtpl" || prw) { out.push_back(p); }
    }
  }

  fs::path beside(const fs::path& f, const char* ext)
  {
    fs::path p = f;
    p.replace_extension(ext);
    return p;
  }

  // A case's options, from its NAME.args.
  bool options_of(const fs::path& f, xc::CompileOptions& o, std::map<std::string, xc::Dictionary>& dictionaries,
                  std::string& why)
  {
    std::string text;
    if (!xc::slurp(beside(f, ".args").string(), text)) { return true; }
    std::vector<std::string> args = xc::words(text);
    fs::path dir = f.parent_path();
    for (std::size_t i = 0; i < args.size(); i++)
    {
      const std::string& a = args[i];
      if (a == "--dict" && i + 1 < args.size())
      {
        std::string path = (dir / args[++i]).string();
        auto it = dictionaries.find(path);
        if (it == dictionaries.end())
        {
          try
          {
            it = dictionaries.emplace(path, xc::load_dictionary(path)).first;
          }
          catch (const std::exception& e)
          {
            why = e.what();
            return false;
          }
        }
        o.dictionary = it->second;
      }
      else if (a == "--dict-strict")
      {
        o.strict = true;
      }
      else if (a.rfind("--includes=", 0) == 0)
      {
        std::string list = a.substr(11);
        std::size_t b = 0;
        while (b <= list.size())
        {
          std::size_t e = list.find_first_of(";,", b);
          if (e == std::string::npos) { e = list.size(); }
          if (e > b) { o.includes.push_back((dir / list.substr(b, e - b)).string()); }
          b = e + 1;
        }
      }
      else
      {
        why = "no such option in " + beside(f, ".args").filename().string() + ": " + a;
        return false;
      }
    }
    return true;
  }

  // Where two texts first differ, as a line of the expected one.
  std::string where(const std::string& expect, const std::string& got)
  {
    std::size_t k = 0;
    while (k < expect.size() && k < got.size() && expect[k] == got[k]) { k++; }
    return "line " + std::to_string(1 + std::count(expect.begin(), expect.begin() + static_cast<std::ptrdiff_t>(k), '\n'));
  }

  void put(const fs::path& p, const std::optional<std::string>& text)
  {
    if (text && !text->empty())
    {
      std::ofstream(p, std::ios::binary) << *text;
    }
    else if (fs::exists(p))
    {
      fs::remove(p);
    }
  }
}

int main(int argc, char** argv)
{
  std::vector<std::string> args(argv + 1, argv + argc);
  bool update = !args.empty() && args[0] == "--update";
  if (update) { args.erase(args.begin()); }
  if (args.empty())
  {
    std::cerr << "usage: xc-cases [--update] FOLDER...\n";
    return 2;
  }
  std::map<std::string, xc::Dictionary> dictionaries;
  int ok = 0;
  int total = 0;
  for (const std::string& folder : args)
  {
    std::vector<fs::path> files;
    cases_under(fs::path(folder), files);
    for (const fs::path& f : files)
    {
      total++;
      xc::CompileOptions o;
      std::string why;
      if (!options_of(f, o, dictionaries, why))
      {
        std::cout << "  FAIL  " << f.string() << ": " << why << "\n";
        continue;
      }
      xc::Compiled c = xc::compile(f.string(), f.filename().string(), o);
      const char* made = f.extension() == ".prw" ? ".out.prw" : ".tlpp";
      if (update)
      {
        put(beside(f, made), c.tlpp);
        put(beside(f, ".err"), c.said);
        ok++;
        continue;
      }
      std::string tlpp;
      std::string err;
      bool has_tlpp = xc::slurp(beside(f, made).string(), tlpp);
      xc::slurp(beside(f, ".err").string(), err);
      if (!c.tlpp && has_tlpp) { why = "xc writes no TL++ for it"; }
      else if (c.tlpp && !has_tlpp) { why = "xc writes TL++ for it, and it has no .tlpp"; }
      else if (c.tlpp && *c.tlpp != tlpp) { why = "the TL++ differs at " + where(tlpp, *c.tlpp); }
      if (c.said != err) { why += (why.empty() ? "" : "; ") + std::string("what xc says differs at ") + where(err, c.said); }
      if (why.empty())
      {
        ok++;
      }
      else
      {
        std::cout << "  FAIL  " << f.string() << ": " << why << "\n";
      }
    }
  }
  if (update)
  {
    std::cout << "  " << total << " cases written\n";
    return 0;
  }
  std::cout << "  " << ok << " of " << total << " cases\n";
  return ok == total ? 0 : 1;
}
