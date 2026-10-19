// xc-doc -- docs/language.md says every example in it was compiled by xc,
// and shows what came out; this keeps it so (ctest's doc), as the Raku xc's
// t/45-language-doc.raku did.
//
//   xc-doc DOC WORK      DOC: docs/language.md; WORK: a folder for the
//                        sources it compiles, made if it is not there
//
// Each ```xtpl block is compiled, and the ```tlpp block right after it is
// what has to come out; a ```text block right after those is the messages
// xc has to give, the file named as the message names it. An example with
// nothing after it has to compile. And in the tables headed
// '| xtpl | TL++ |', each row's xtpl, assigned in a function, has to come
// out as the TL++ beside it.
//
// A block that starts no function, class or file of its own -- no header,
// no include -- is a fragment of a function body: it is compiled inside
// 'User Function Doc()' ... 'Return nil', and what comes out between the two
// is compared. When an example has no include lines, the two xc adds are left
// out of what it shows. CMake runs it as a test (ctest).

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

#include "chars.h"
#include "driver.h"
#include "text.h"

namespace fs = std::filesystem;

namespace
{
  struct Block
  {
    std::string info;
    std::string text;
    int open;                        // the line of the opening fence, from 1
    int close;                       // and of the closing one
  };

  bool is_h(char c) { return c == ' ' || c == '\t'; }

  bool is_word(char c)
  {
    unsigned char u = static_cast<unsigned char>(c);
    return std::isalnum(u) || c == '_';
  }

  std::string trim_leading(const std::string& s)
  {
    std::size_t i = 0;
    while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) { i++; }
    return s.substr(i);
  }

  bool blank(const std::string& s) { return trim_leading(s).empty(); }

  // A fence: its indentation and info string; none when the line is not one.
  // The closing fence has no info string.
  std::optional<std::pair<std::string, std::string>> fence(const std::string& l)
  {
    std::size_t i = 0;
    while (i < l.size() && is_h(l[i])) { i++; }
    if (l.compare(i, 3, "```") != 0) { return std::nullopt; }
    std::size_t w = i + 3;
    std::size_t e = w;
    while (e < l.size() && is_word(l[e])) { e++; }
    for (std::size_t k = e; k < l.size(); k++)
    {
      if (!is_h(l[k])) { return std::nullopt; }
    }
    return std::make_pair(l.substr(0, i), l.substr(w, e - w));
  }

  // A word at s[i], whole: no word character after it.
  bool word_at(const std::string& s, std::size_t i, const std::string& w)
  {
    return s.compare(i, w.size(), w) == 0 && (i + w.size() == s.size() || !is_word(s[i + w.size()]));
  }

  // A header of its own: the block is a whole file, not a fragment.
  bool whole(const std::string& text)
  {
    for (const std::string& line : xc::lines_of(text))
    {
      std::size_t i = 0;
      while (i < line.size() && is_h(line[i])) { i++; }
      std::string l = xc::lc(line.substr(i));
      if (l.compare(0, 8, "#include") == 0) { return true; }
      for (const char* kw : { "user", "static", "main" })
      {
        std::string k = kw;
        if (l.compare(0, k.size(), k) == 0 && l.size() > k.size()
            && std::isspace(static_cast<unsigned char>(l[k.size()])))
        {
          std::size_t j = k.size();
          while (j < l.size() && std::isspace(static_cast<unsigned char>(l[j]))) { j++; }
          if (word_at(l, j, "function")) { return true; }
        }
      }
      for (const char* kw : { "function", "class", "interface", "method", "wsrestful", "wsmethod" })
      {
        if (word_at(l, 0, kw)) { return true; }
      }
    }
    return false;
  }

  std::string replace_first(std::string s, const std::string& from, const std::string& to)
  {
    std::size_t at = s.find(from);
    if (at != std::string::npos) { s.replace(at, from.size(), to); }
    return s;
  }

  // The lines trimmed at the end, joined with "\n".
  std::string trimmed(const std::vector<std::string>& lines)
  {
    std::vector<std::string> t;
    for (const std::string& l : lines) { t.push_back(xc::trim_trailing(l)); }
    return xc::join(t, "\n");
  }

  // The output without the includes xc adds to a source that has none, and a
  // fragment's without the function around it.
  std::string shown(const std::string& out, const std::string& text, bool is_whole)
  {
    std::string o = out;
    if (text.find("#include") == std::string::npos)
    {
      o = replace_first(o, "#include \"totvs.ch\"\n", "");
      o = replace_first(o, "#include \"tlpp-core.th\"\n", "");
      o.erase(0, o.find_first_not_of('\n') == std::string::npos ? o.size() : o.find_first_not_of('\n'));
    }
    std::vector<std::string> lines = xc::lines_of(o);
    if (!is_whole)
    {
      lines = lines.size() >= 2 ? std::vector<std::string>(lines.begin() + 1, lines.end() - 1)
                                : std::vector<std::string>();
    }
    return trimmed(lines);
  }

  bool same_text(const std::string& a, const std::string& b)
  {
    return trimmed(xc::lines_of(a)) == trimmed(xc::lines_of(b));
  }

  class Doc
  {
  public:
    explicit Doc(fs::path work) : work_(std::move(work)) {}

    int ok = 0;
    int total = 0;

    void check(const std::string& what, bool v, const std::vector<std::string>& notes = {})
    {
      total++;
      if (v)
      {
        ok++;
        return;
      }
      std::cout << "  FAIL  " << what << "\n";
      for (const std::string& n : notes) { std::cout << "    " << n << "\n"; }
    }

    // What xc says of a source, and the TL++ it makes, if any.
    xc::Compiled compile(const std::string& name, const std::string& src)
    {
      std::string bytes;
      if (!xc::utf8_to_cp1252(src, bytes)) { bytes = src; }  // xc takes cp1252 only
      fs::path p = work_ / (name + ".xtpl");
      std::ofstream(p, std::ios::binary) << bytes;
      xc::Compiled c = xc::compile(p.string(), name + ".xtpl", xc::CompileOptions{});
      fs::remove(p);
      if (c.tlpp) { c.tlpp = xc::cp1252_to_utf8(*c.tlpp); }
      return c;
    }

    // The messages of a ```text block, each one given by xc.
    void says(int line, const std::string& msgs, const std::string& src)
    {
      std::string name = "ex" + std::to_string(line);
      std::size_t w = 0;
      while (w < msgs.size() && is_word(msgs[w])) { w++; }
      if (w > 0 && msgs.compare(w, 6, ".xtpl:") == 0) { name = msgs.substr(0, w); }
      xc::Compiled c = compile(name, src);
      std::vector<std::string> said;
      for (const std::string& l : xc::lines_of(c.said)) { said.push_back(xc::trim(l)); }
      if (c.tlpp) { said.push_back(name + ".xtpl: ok"); }
      for (const std::string& m : xc::lines_of(msgs))
      {
        if (blank(m)) { continue; }
        bool found = false;
        for (const std::string& s : said) { found = found || s == xc::trim(m); }
        std::vector<std::string> notes;
        if (!found)
        {
          notes.push_back("what xc said:");
          for (const std::string& s : said) { notes.push_back("  " + s); }
        }
        check("line " + std::to_string(line) + ": says " + m.substr(0, 60) + "...", found, notes);
      }
    }

  private:
    fs::path work_;
  };
}

int main(int argc, char** argv)
{
  if (argc != 3)
  {
    std::cerr << "usage: xc-doc DOC WORK\n";
    return 2;
  }
  std::string doc;
  if (!xc::slurp(argv[1], doc))
  {
    std::cerr << "xc-doc: cannot read " << argv[1] << "\n";
    return 2;
  }
  fs::create_directories(argv[2]);
  Doc d{ fs::path(argv[2]) };
  std::vector<std::string> lines = xc::lines_of(doc);

  // The fenced blocks, in order: info string, text (its fence's indentation
  // taken off), the line of the opening fence and of the closing one.
  std::vector<Block> blocks;
  for (std::size_t i = 0; i < lines.size(); i++)
  {
    auto f = fence(lines[i]);
    if (!f) { continue; }
    auto [indent, info] = *f;
    int open = static_cast<int>(i) + 1;
    std::vector<std::string> body;
    i++;
    while (i < lines.size() && !(fence(lines[i]) && fence(lines[i])->second.empty()))
    {
      const std::string& l = lines[i];
      body.push_back(l.compare(0, indent.size(), indent) == 0 ? l.substr(indent.size()) : trim_leading(l));
      i++;
    }
    blocks.push_back(Block{ info, xc::join(body, "\n"), open, static_cast<int>(i) + 1 });
  }

  // Whether only blank lines stand between two blocks.
  auto adjacent = [&](const Block& a, const Block& b)
  {
    for (int k = a.close; k < b.open - 1; k++)
    {
      if (!blank(lines[static_cast<std::size_t>(k)])) { return false; }
    }
    return true;
  };

  for (std::size_t k = 0; k < blocks.size(); k++)
  {
    const Block& b = blocks[k];
    if (b.info != "xtpl") { continue; }
    std::optional<std::string> expect;
    std::optional<std::string> msgs;
    const Block* next = k + 1 < blocks.size() ? &blocks[k + 1] : nullptr;
    const Block* after = k + 2 < blocks.size() ? &blocks[k + 2] : nullptr;
    if (next && adjacent(b, *next) && next->info == "tlpp")
    {
      expect = next->text;
      if (after && adjacent(*next, *after) && after->info == "text") { msgs = after->text; }
    }
    else if (next && adjacent(b, *next) && next->info == "text")
    {
      msgs = next->text;
    }
    bool w = whole(b.text);
    std::string src = w ? b.text + "\n" : "User Function Doc()\n" + b.text + "\nReturn nil\n";
    int line = b.open;

    // Refused on purpose, with nothing shown to come out: the messages tell.
    if (msgs && !expect)
    {
      d.says(line, *msgs, src);
      continue;
    }
    xc::Compiled c = d.compile("doc" + std::to_string(line), src);
    std::vector<std::string> notes;
    bool good = c.tlpp.has_value();
    if (!good)
    {
      notes.push_back("it does not compile:");
      for (const std::string& l : xc::lines_of(c.said)) { notes.push_back("  " + l); }
    }
    else if (expect)
    {
      std::string s = shown(*c.tlpp, b.text, w);
      if (!same_text(s, *expect))
      {
        good = false;
        notes.push_back("what came out:");
        for (const std::string& l : xc::lines_of(s)) { notes.push_back("  " + l); }
      }
    }
    d.check("line " + std::to_string(line) + ": " + (expect ? "what comes out" : "compiles")
              + (w ? "" : " (a fragment)"),
            good, notes);
    if (msgs && c.tlpp) { d.says(line, *msgs, src); }
  }

  // The tables of expressions, '| xtpl | TL++ |': each row's xtpl, assigned in
  // a function, has to come out as the row's TL++.
  bool in_table = false;
  int rows = 0;
  for (std::size_t n = 0; n < lines.size(); n++)
  {
    const std::string& l = lines[n];
    std::vector<std::string> cells;
    std::string bare;
    for (char c : l)
    {
      if (!is_h(c)) { bare += c; }
    }
    if (bare == "|xtpl|TL++|")
    {
      in_table = true;
      continue;
    }
    if (l.empty() || l[0] != '|') { in_table = false; }
    if (!in_table) { continue; }
    if (bare.find_first_not_of("|-") == std::string::npos) { continue; }
    // Two code spans; '\|' is a '|' inside one.
    for (std::size_t i = 0; i < l.size(); i++)
    {
      if (l[i] != '`') { continue; }
      std::size_t e = l.find('`', i + 1);
      if (e == std::string::npos) { break; }
      if (e == i + 1) { continue; }               // '``' starts no span: the second may
      std::string cell = l.substr(i + 1, e - i - 1);
      std::string un;
      for (std::size_t j = 0; j < cell.size(); j++)
      {
        if (cell[j] == '\\' && j + 1 < cell.size() && cell[j + 1] == '|') { continue; }
        un += cell[j];
      }
      cells.push_back(un);
      i = e;
    }
    if (cells.size() != 2) { continue; }
    rows++;
    std::string src = "User Function Doc()\n  xDoc := " + cells[0] + "\nReturn nil\n";
    xc::Compiled c = d.compile("row" + std::to_string(n + 1), src);
    std::string s = c.tlpp ? shown(*c.tlpp, "", false) : "";
    bool good = c.tlpp && same_text(s, "  xDoc := " + cells[1]);
    std::vector<std::string> notes;
    if (!good) { notes.push_back(c.tlpp ? "came out: " + s : "it does not compile: " + c.said); }
    d.check("line " + std::to_string(n + 1) + ": " + cells[0], good, notes);
  }
  d.check("the tables of expressions were found (" + std::to_string(rows) + " rows)", rows >= 15);

  // No example lost: the count is the document's, and a block that went
  // missing from it -- a fence broken by an edit -- shows here.
  std::ptrdiff_t examples = std::count_if(blocks.begin(), blocks.end(), [](const Block& b) { return b.info == "xtpl"; });
  d.check("the examples were all found (" + std::to_string(examples) + ")", examples >= 20);

  std::cout << "  " << d.ok << " of " << d.total << " doc checks\n";
  return d.ok == d.total ? 0 : 1;
}
