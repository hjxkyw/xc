// xc -- a program as the instructions of a stack machine: 'xc --bytecode'
// writes them, a .xbc, instead of the TL++ (docs/bytecode.md says what each
// instruction does).
//
// The tree is the one the TL++ is made from, checked the same; what xtpl
// adds becomes what it stands for in TL++ -- a hash the runtime's calls, a
// lambda a code block, a 'defer' code run before each return. A call is by
// name: a function of the module, or the AppServer's.

#pragma once

#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "ast.h"
#include "check.h"

namespace xc
{
  // What cannot become bytecode yet, each with its line: the whole file
  // stops, and no .xbc is written.
  struct NotBytecode : std::runtime_error
  {
    explicit NotBytecode(std::vector<Finding> found);
    std::vector<Finding> problems;
  };

  // The .xbc of a program: its tree, its source, whether it is AdvPL's (a
  // .prw: no Decimal, nothing starts at its type's value), and the name of
  // its source, for the 'source' line. Throws NotBytecode.
  std::string bytecode(const Program* p, std::string_view src, bool advpl, const std::string& source_name);
}
