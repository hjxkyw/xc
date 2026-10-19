// xc -- from the tree back to TL++ (XC::Emit).
//
// The output is the source, copied through, with the extension constructs
// replaced where they are: what needs no lowering keeps its comments, blank
// lines and layout exactly as written. A rewritten statement loses its
// trailing comment to the rewrite and gets it back, two spaces after the new
// code: on the header line when the rewrite opens a block, on the last line
// otherwise. It began as the Raku xc's output, byte for byte; its
// lib/XC/Emit.rakumod (README.md, History) says why each rewrite the two
// share is what it is.

#pragma once

#include <stdexcept>
#include <string>
#include <vector>

#include "ast.h"
#include "check.h"

namespace xc
{
  // What the emitter cannot lower yet, each with its line: the whole file
  // stops, so xtpl syntax never passes silently into a .tlpp.
  struct NotLowered : std::runtime_error
  {
    explicit NotLowered(std::vector<Finding> found);
    std::vector<Finding> problems;
  };

  // The TL++ a program becomes, from its tree and its source. Throws
  // NotLowered, or std::runtime_error when something inside went wrong.
  // 'advpl': the source is AdvPL's, and so is what comes out (no tlpp-core.th).
  std::string emit(const Program* p, const std::string& src, bool advpl = false);
}
