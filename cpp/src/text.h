// xc -- pieces of source text: lines, words, comments, where code ends.
//
// The Raku xc works in characters, and "\r\n" is one character to it; here a
// text is its bytes (windows-1252), and a "\r\n" two of them. Each routine
// steps over a "\r\n" whole where the Raku one sees a character, so the two
// give the same answers -- offsets in bytes here, in characters there.

#pragma once

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace xc
{
  // The length of the character at i: 2 for a "\r\n", else 1.
  inline std::size_t char_len(std::string_view t, std::size_t i)
  {
    return t[i] == '\r' && i + 1 < t.size() && t[i + 1] == '\n' ? 2 : 1;
  }

  // Raku's .lines: split at "\r\n", "\n" and "\r"; no empty last line.
  // keep: each line with its line end (':!chomp').
  std::vector<std::string> lines_of(std::string_view t, bool keep = false);

  // Raku's .words: the runs of what is not whitespace.
  std::vector<std::string> words(std::string_view s);

  // Raku's .trim-trailing.
  std::string trim_trailing(std::string_view s);

  // The strings joined with a separator.
  std::string join(const std::vector<std::string>& v, std::string_view sep);

  // Where the line holding offset i ends: the first line end at or after it,
  // or the text's end.
  std::size_t eol_from(std::string_view t, std::size_t i);

  // A '*' that starts a Clipper comment line (XC::Emit's star-comment).
  bool star_comment(std::string_view t, std::size_t i);

  // A "'" between two digits: a separator ('12'345), no string.
  bool is_separator(std::string_view t, std::size_t i);

  // A piece of source split into its code and its comments, outside strings;
  // the comments joined on one line, each as '// text'.
  std::pair<std::string, std::string> split_comment(std::string_view t);

  // Where the first comment of a piece of source starts, or -1.
  long comment_at(std::string_view t);

  // Where the code of a piece of source ends: before its trailing blanks and
  // comments, and a ';' that carries it on to the next line.
  std::size_t code_end(std::string_view t);

  // Where the last 'end' + blanks + word starts in a text, in lower case.
  std::size_t last_from(std::string_view t, std::string_view word);

  // The two includes every output gets, when missing.
  // The include files the output needs and does not name: totvs.ch, and for
  // TL++ tlpp-core.th -- not for AdvPL ('advpl'), whose output stays a .prw.
  std::string add_includes(const std::string& out, const std::string& nl, bool advpl = false);
}
