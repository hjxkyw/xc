// xc-outputs -- the TL++ xc writes for xtpl's sources, kept beside them: each
// .xtpl of xtpl/tests/ and xtpl/examples/ has its .tlpp, the output byte for
// byte as xc writes it. They replaced the .tlpp files xtpl made, so what a
// reader finds beside a source is what xc does with it.
//
//   xc-outputs FOLDER...            compares; 1 when one differs
//   xc-outputs --update FOLDER...   writes them again -- after a change to
//                                   the output that is meant
//
// CMake runs it as a test (ctest), on xtpl/tests and xtpl/examples.
//
// A source in UTF-8 -- a few of xtpl's are, and xc takes windows-1252 only --
// is compiled as its windows-1252 copy, as run-protheus.raku compiles it. A
// source xc refuses (51_legacy: a 'local' after a statement) has no .tlpp.

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
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
  bool slurp(const fs::path& p, std::string& out)
  {
    std::ifstream in(p, std::ios::binary);
    if (!in) { return false; }
    std::ostringstream s;
    s << in.rdbuf();
    out = s.str();
    return true;
  }

  void sources_under(const fs::path& dir, std::vector<fs::path>& out)
  {
    std::vector<fs::path> entries;
    for (const fs::directory_entry& d : fs::directory_iterator(dir)) { entries.push_back(d.path()); }
    std::sort(entries.begin(), entries.end());
    for (const fs::path& p : entries)
    {
      if (fs::is_directory(p)) { sources_under(p, out); }
      else if (p.extension() == ".xtpl") { out.push_back(p); }
    }
  }

  // What xc writes for a source, or nothing when it writes nothing.
  std::optional<std::string> compiled(const fs::path& file)
  {
    std::string src;
    if (!slurp(file, src)) { return std::nullopt; }
    bool high = std::any_of(src.begin(), src.end(), [](char c) { return static_cast<unsigned char>(c) >= 0x80; });
    std::string cp1252;
    if (high && xc::utf8_to_cp1252(src, cp1252)) { src = cp1252; }
    xc::UserSpans spans = xc::user_spans(src, file.parent_path().string(), {});
    xc::Tree tree;
    xc::Parser parser(src, spans.trans, tree, spans.cmd);
    xc::Program* prog = parser.parse();
    if (!prog) { return std::nullopt; }
    int lines = static_cast<int>(xc::lines_of(src).size());
    if (!xc::check_all(prog, lines, {}, false, std::string_view(src)).errors.empty()) { return std::nullopt; }
    try
    {
      return xc::emit(prog, src);
    }
    catch (const std::exception&)
    {
      return std::nullopt;
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
    std::cerr << "usage: xc-outputs [--update] FOLDER...\n";
    return 2;
  }
  int ok = 0;
  int total = 0;
  for (const std::string& folder : args)
  {
    std::vector<fs::path> files;
    sources_under(fs::path(folder), files);
    for (const fs::path& f : files)
    {
      fs::path t = f;
      t.replace_extension(".tlpp");
      std::optional<std::string> out = compiled(f);
      if (update)
      {
        if (out)
        {
          std::ofstream(t, std::ios::binary) << *out;
          std::cout << "  " << t.string() << "\n";
        }
        else if (fs::exists(t))
        {
          fs::remove(t);
          std::cout << "  " << t.string() << ": removed -- xc writes nothing for it\n";
        }
        continue;
      }
      total++;
      std::string expect;
      bool has = slurp(t, expect);
      std::string why;
      if (!out && has) { why = "xc writes nothing for it, and it has a .tlpp"; }
      else if (out && !has) { why = "it has no .tlpp"; }
      else if (out && *out != expect)
      {
        std::size_t k = 0;
        while (k < out->size() && k < expect.size() && (*out)[k] == expect[k]) { k++; }
        why = "differs at byte " + std::to_string(k);
      }
      if (why.empty())
      {
        ok++;
        std::cout << "  ok    " << f.string() << "\n";
      }
      else
      {
        std::cout << "  FAIL  " << f.string() << ": " << why << "\n";
      }
    }
  }
  if (update) { return 0; }
  std::cout << "\n  " << ok << " of " << total << "\n";
  return ok == total ? 0 : 1;
}
