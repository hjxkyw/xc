// xc -- the characters of a source.
//
// A source is windows-1252: one byte, one character. What Raku's classes say
// of each one -- \w, \h, \v, \N, \d, '\n' in a character class, \s, and what
// .trim takes -- worked out by Raku itself for every byte, decoded, so that
// the parser reads them as the Raku grammar did. (tools/ast-json.raku is the
// reference: the trees are compared.)
//
// A "\r\n" is one character to Raku and two bytes here: wherever one line
// end is taken, both are.

#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace xc
{
  enum : std::uint8_t
  {
    C_W    = 1,      // \w
    C_H    = 2,      // \h
    C_V    = 4,      // \v
    C_NN   = 8,      // \N: not a line end
    C_D    = 16,     // \d
    C_NL   = 32,     // <[\n]>
    C_S    = 64,     // \s
    C_TRIM = 128,    // what .trim takes
  };

  extern const std::uint8_t CHAR_CLASS[256];

  // c: a byte, or -1 past the end.
  inline bool is_w(int c)     { return c >= 0 && (CHAR_CLASS[c] & C_W); }
  inline bool is_h(int c)     { return c >= 0 && (CHAR_CLASS[c] & C_H); }
  inline bool is_v(int c)     { return c >= 0 && (CHAR_CLASS[c] & C_V); }
  inline bool is_nn(int c)    { return c >= 0 && (CHAR_CLASS[c] & C_NN); }
  inline bool is_d(int c)     { return c >= 0 && (CHAR_CLASS[c] & C_D); }
  inline bool is_nl(int c)    { return c >= 0 && (CHAR_CLASS[c] & C_NL); }
  inline bool is_trim(int c)  { return c >= 0 && (CHAR_CLASS[c] & C_TRIM); }
  inline bool is_alpha(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
  inline int  lower(int c)    { return c >= 'A' && c <= 'Z' ? c + 32 : c; }

  // Raku's .lc, .uc and .trim, for the bytes of a source.
  std::string lc(std::string_view s);
  std::string uc(std::string_view s);
  std::string trim(std::string_view s);

  // UTF-8 as windows-1252, when it is UTF-8 at all: false when it is not. A
  // character windows-1252 does not have is '?'.
  bool utf8_to_cp1252(const std::string& in, std::string& out);

  // Windows-1252 as UTF-8, as Raku decodes it: the five bytes it leaves
  // undefined (81 8D 8F 90 9D) as the characters of the same number.
  std::string cp1252_to_utf8(std::string_view in);
}
