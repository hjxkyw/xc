// xc -- what xtpl refuses although it parses (XC::Check, with XC::Types).
//
// Between the parse and the emitter: names and their scopes, '<const>' and
// '<contained>', 'external', the calls to this file's own functions, a
// declaration's value against its type, and a few shapes of chain. The
// rules and messages began as the Raku xc's, word for word; its
// lib/XC/Check.rakumod (README.md, History) says why each of those is what
// it is.
//
// A name nothing declares is a warning, not an error, as are a variable never
// read, a function that returns a value on one path and nothing on another,
// a field of an area nothing in the function opened, and two of xtpl's
// warnings about chains. Given an exported SX3, the fields used are checked
// against it: warnings, or errors when strict.

#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include "ast.h"

namespace xc
{
  // A line, and what is wrong there.
  struct Finding
  {
    int line = 0;
    std::string message;
  };

  struct Checked
  {
    std::vector<Finding> errors;
    std::vector<Finding> warnings;
  };

  // An exported SX3: ALIAS => FIELD => (type letter, size), in upper case.
  struct Field
  {
    std::string type;
    int size = 0;
  };
  using Dictionary = std::unordered_map<std::string, std::unordered_map<std::string, Field>>;

  // Everything the checks find in a program, each list in the order of its
  // lines, a message said once per line. lines: the file's length (where the
  // last function ends); source: the text, for what a warning quotes of it.
  // 'advpl': the source is AdvPL's (.prw), and what it makes stays AdvPL --
  // TL++'s own rules do not hold. 'bytecode': it becomes bytecode, which xc's
  // machines run, not the AppServer -- what the AppServer gets wrong at run
  // time is not said.
  Checked check_all(const Program* p, int lines, const Dictionary& dictionary, bool strict,
                    std::optional<std::string_view> source, bool advpl = false, bool bytecode = false);

  // The names a program declares that xc keeps for itself -- for a file
  // read again with any name allowed.
  std::vector<Finding> check_names(const Program* p);

  // The same for one declaration on its own.
  std::vector<Finding> check_declared_names(const Declaration* d);

  // An exported SX3 (a CSV). Throws std::runtime_error when it is empty or
  // cannot be read.
  Dictionary load_dictionary(const std::string& path);
}
