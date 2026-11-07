// xc-ast -- the tree xc reads a source into, as text (dump.h): what the
// parser written in xtpl (selfhost/) is held to.
//
//   xc-ast [--includes=DIRS] [--bare] [--values] [--facts] [--checks] file.xtpl [out.txt]
//   xc-ast [--includes=DIRS] --list=LIST
//
// A source xc cannot parse gives 'not parsed at N', N the byte xc got
// furthest to. --bare: the source's own commands and translations are not
// looked for -- as the parser written in xtpl reads it. --values: each
// line is read in each form a statement holds an expression as (its
// blanks before it aside; a blank line, or one that starts with '//', is
// none) -- a value, a guarded one, a condition, an expression, a target, a
// call made a statement, a chain run for its effect --, where it starts in
// the whole text: '@START form F end END', then the node, or 'nil'.
// --facts: the tree marked by typed_problems() -- a set's 'h{k}', a 'for
// ... in' over a hash --, then what facts.h writes of it. --checks: what
// check_all() finds, for TL++ and then for bytecode -- 'checks tlpp',
// 'checks bytecode', and below each 'W LINE what' for each warning, then
// 'E LINE what' for each error --, with no dictionary, the include files'
// #defines found beside the source and in DIRS.
//
// --list: for selfhost.cmake, each line of LIST a source and where its
// files go -- PREFIX --, a tab between, all in one run (a process for each
// is slow where starting one is: Windows, a virus scanner). PREFIX.ast is
// what --values writes of a .val, or --bare --facts of any other source;
// of those, PREFIX.chk is what --bare --checks writes, PREFIX.said what
// 'xc --bytecode' says compiling it -- but where the .xbc went --, and
// PREFIX.xbc the .xbc it writes, when it writes one.

#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "chars.h"
#include "commands.h"
#include "driver.h"
#include "check.h"
#include "dump.h"
#include "facts.h"
#include "parser.h"
#include "text.h"
#include "typed.h"

namespace
{
  struct Mode
  {
    bool bare = false;
    bool values = false;
    bool facts = false;
    bool checks = false;
  };

  // What xc-ast writes of a source; false when it cannot be read.
  bool text_of(const std::string& file, const Mode& m, const std::vector<std::string>& includes, std::string& text)
  {
    std::string src;
    if (!xc::slurp(file, src)) { return false; }
    xc::UserSpans spans = m.bare || m.values ? xc::UserSpans{} : xc::user_spans(src, xc::folder_of(file), includes);
    xc::Tree tree;
    xc::Parser parser(src, spans.trans, tree, spans.cmd);
    text.clear();
    if (m.values)
    {
      std::size_t at = 0;
      while (at < src.size())
      {
        std::size_t eol = src.find('\n', at);
        std::size_t next = eol == std::string::npos ? src.size() : eol + 1;
        std::size_t k = at;
        while (k < next && (src[k] == ' ' || src[k] == '\t')) { k++; }
        bool none = k >= src.size() || src[k] == '\n' || src[k] == '\r' || src.compare(k, 2, "//") == 0;
        if (!none)
        {
          static const xc::Form forms[] =
          {
            xc::Form::Value, xc::Form::GuardExpr, xc::Form::Cond, xc::Form::Expr, xc::Form::LValue,
            xc::Form::CallSt, xc::Form::PipeSt,
          };
          for (int f = 0; f < 7; f++)
          {
            int end = 0;
            xc::Expr* e = parser.read(forms[f], static_cast<int>(k), false, end);
            text += "@" + std::to_string(k) + " form " + std::to_string(f + 1) + " end " + std::to_string(end) + "\n"
                    + xc::dump_expr(e);
          }
        }
        at = next;
      }
      return true;
    }
    xc::Program* prog = parser.parse();
    if (prog && m.checks)
    {
      int nlines = static_cast<int>(xc::lines_of(src).size());
      std::vector<std::string> defines = xc::include_defines(src, xc::folder_of(file), includes);
      for (bool bytecode : { false, true })
      {
        xc::Checked c = xc::check_all(prog, nlines, xc::Dictionary{}, false, std::string_view(src),
                                      xc::is_advpl(file), bytecode, defines);
        text += bytecode ? "checks bytecode\n" : "checks tlpp\n";
        for (const xc::Finding& f : c.warnings) { text += "W " + std::to_string(f.line) + " " + f.message + "\n"; }
        for (const xc::Finding& f : c.errors) { text += "E " + std::to_string(f.line) + " " + f.message + "\n"; }
      }
    }
    else if (prog && m.facts)
    {
      xc::typed_problems(prog, xc::Dictionary{});
      text = xc::dump(prog) + xc::facts(prog, xc::is_advpl(file));
    }
    else
    {
      text = prog ? xc::dump(prog) : "not parsed at " + std::to_string(parser.furthest()) + "\n";
    }
    return true;
  }

  bool write(const std::string& path, const std::string& text)
  {
    std::ofstream out(path, std::ios::binary);
    out << text;
    return static_cast<bool>(out);
  }

  // --list: each source's files, as selfhost.cmake has them.
  int list(const std::string& path, const std::vector<std::string>& includes)
  {
    std::string all;
    if (!xc::slurp(path, all))
    {
      std::cerr << path << ": cannot be read\n";
      return 2;
    }
    for (const std::string& line : xc::lines_of(all))
    {
      std::size_t tab = line.find('\t');
      if (tab == std::string::npos) { continue; }
      std::string src = line.substr(0, tab);
      std::string to = line.substr(tab + 1);
      bool val = src.size() > 4 && xc::lc(src.substr(src.size() - 4)) == ".val";
      Mode m;
      m.values = val;
      m.bare = !val;
      m.facts = !val;
      std::string text;
      if (!text_of(src, m, includes, text))
      {
        std::cerr << src << ": cannot be read\n";
        return 2;
      }
      bool ok = write(to + ".ast", text);
      if (!val)
      {
        Mode c;
        c.bare = true;
        c.checks = true;
        text_of(src, c, includes, text);
        ok = ok && write(to + ".chk", text);
        // What 'xc --bytecode SOURCE OUT' says and writes (xc.cpp's run()).
        xc::CompileOptions o;
        o.bytecode = true;
        o.includes = includes;
        xc::Compiled made = xc::compile(src, src, o);
        ok = ok && write(to + ".said", made.said);
        if (made.output) { ok = ok && write(to + ".xbc", *made.output); }
      }
      if (!ok)
      {
        std::cerr << to << ": cannot be written\n";
        return 1;
      }
    }
    return 0;
  }
}

int main(int argc, char** argv)
{
  std::vector<std::string> files;
  std::vector<std::string> includes;
  Mode m;
  std::string listed;
  for (int i = 1; i < argc; i++)
  {
    std::string a = argv[i];
    if (a == "--bare") { m.bare = true; }
    else if (a == "--values") { m.values = true; }
    else if (a == "--facts") { m.facts = true; }
    else if (a == "--checks") { m.checks = true; }
    else if (a.rfind("--list=", 0) == 0) { listed = a.substr(7); }
    else if (a.rfind("--includes=", 0) == 0)
    {
      std::string dirs = a.substr(11);
      std::size_t b = 0;
      while (b <= dirs.size())
      {
        std::size_t e = dirs.find_first_of(";,", b);
        if (e == std::string::npos) { e = dirs.size(); }
        if (e > b) { includes.push_back(dirs.substr(b, e - b)); }
        b = e + 1;
      }
    }
    else { files.push_back(a); }
  }
  if (!listed.empty() && files.empty()) { return list(listed, includes); }
  if (files.empty() || files.size() > 2)
  {
    std::cerr << "usage: xc-ast [--includes=DIRS] [--bare] [--values] [--facts] [--checks] file.xtpl [out.txt]\n"
                 "       xc-ast [--includes=DIRS] --list=LIST\n";
    return 2;
  }
  std::string text;
  if (!text_of(files[0], m, includes, text))
  {
    std::cerr << files[0] << ": cannot be read\n";
    return 2;
  }
  if (files.size() == 2) { return write(files[1], text) ? 0 : 1; }
  std::cout << text;
  return 0;
}
