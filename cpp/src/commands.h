// xc -- the commands and translations a source brings with it.
//
// AdvPL's preprocessor takes '#command', '#xcommand', '#translate' and
// '#xtranslate': a pattern, '=>', and what it stands for. TOTVS' own include
// files are compressed, and xc cannot read them -- their commands are a list
// in the grammar. But a library's are plain text, in the source itself or in
// an include file beside it:
//
//     #xcommand Feature <cFeat> TestSuite <cSuite> => Function ___TestSuite_<cSuite>____Feat_<cFeat>()
//     #xtranslate @Not_Eof => ( Self:nPosition <= Self:nSourceSize )
//
// xc reads those, and finds in the source where each is used -- matching the
// patterns as the preprocessor does, against the line -- but does not apply
// them: what is written goes out as written. A use is
//
//   - a command, a whole statement: taken whole, as raw text;
//   - a command that stands for a function's header ('Function', 'Static
//     Function', 'Method ... Class'): a function, its header as written and
//     its body read like any other;
//   - a translation inside an expression: a value nothing here looks into.

#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace xc
{
  // A use of one of the source's own commands: where it ends, and whether
  // it stands for a function's header.
  struct UserCmd
  {
    int end = 0;
    bool header = false;
  };

  struct UserSpans
  {
    std::unordered_map<int, UserCmd> cmd;   // start => the command
    std::unordered_map<int, int> trans;     // start => end
  };

  // Where each use is in a text, in bytes. dir: the source's folder, where
  // its include files are looked for first; dirs: the include folders.
  // Nothing is done for a text that brings no directive.
  UserSpans user_spans(std::string_view text, const std::optional<std::string>& dir,
                       const std::vector<std::string>& dirs);
}
