// xc -- one source compiled, as the driver compiles it: read, parsed,
// checked and lowered, with what is said of it. xc.cpp writes what comes
// of it; the tests (cases.cpp) compare it.

#pragma once

#include <optional>
#include <string>
#include <vector>

#include "check.h"

namespace xc
{
  // Whether a source is AdvPL's -- a .prw or a .prx -- and what xc makes of
  // it stays AdvPL, in a file of its kind; anything else makes TL++.
  bool is_advpl(const std::string& path);

  struct CompileOptions
  {
    bool strict = false;                 // the dictionary's findings are errors
    bool bytecode = false;               // a .xbc, not TL++ (bytecode.h)
    std::vector<std::string> includes;   // where include files are looked for
    Dictionary dictionary;
  };

  // What compiling a source says -- each line with its "\n", in UTF-8 -- and
  // what it makes, when it makes something: the TL++, or the bytecode.
  struct Compiled
  {
    std::string said;
    std::optional<std::string> output;
  };

  // path: the file; shown: how what is said names it.
  Compiled compile(const std::string& path, const std::string& shown, const CompileOptions& o);

  // The folder a path is in -- at '\' too on Windows; '.' when it has none.
  std::string folder_of(const std::string& p);

  // A file's bytes; false when it cannot be read.
  bool slurp(const std::string& path, std::string& out);
}
