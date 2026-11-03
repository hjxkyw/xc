// xc-ast -- the tree xc reads a source into, as text (dump.h): what the
// parser written in xtpl (selfhost/) is held to.
//
//   xc-ast [--includes=DIRS] [--bare] file.xtpl [out.txt]
//
// A source xc cannot parse gives 'not parsed at N', N the byte xc got
// furthest to. --bare: the source's own commands and translations are not
// looked for -- as the parser written in xtpl reads it.

#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "commands.h"
#include "driver.h"
#include "dump.h"
#include "parser.h"

int main(int argc, char** argv)
{
  std::vector<std::string> files;
  std::vector<std::string> includes;
  bool bare = false;
  for (int i = 1; i < argc; i++)
  {
    std::string a = argv[i];
    if (a == "--bare") { bare = true; }
    else if (a.rfind("--includes=", 0) == 0)
    {
      std::string list = a.substr(11);
      std::size_t b = 0;
      while (b <= list.size())
      {
        std::size_t e = list.find_first_of(";,", b);
        if (e == std::string::npos) { e = list.size(); }
        if (e > b) { includes.push_back(list.substr(b, e - b)); }
        b = e + 1;
      }
    }
    else { files.push_back(a); }
  }
  if (files.empty() || files.size() > 2)
  {
    std::cerr << "usage: xc-ast [--includes=DIRS] [--bare] file.xtpl [out.txt]\n";
    return 2;
  }
  std::string src;
  if (!xc::slurp(files[0], src))
  {
    std::cerr << files[0] << ": cannot be read\n";
    return 2;
  }
  xc::UserSpans spans = bare ? xc::UserSpans{} : xc::user_spans(src, xc::folder_of(files[0]), includes);
  xc::Tree tree;
  xc::Parser parser(src, spans.trans, tree, spans.cmd);
  xc::Program* prog = parser.parse();
  std::string text = prog ? xc::dump(prog) : "not parsed at " + std::to_string(parser.furthest()) + "\n";
  if (files.size() == 2)
  {
    std::ofstream out(files[1], std::ios::binary);
    out << text;
    return out ? 0 : 1;
  }
  std::cout << text;
  return 0;
}
