// xc -- the characters of a source (see chars.h).

#include "chars.h"

namespace xc
{
  // Made by Raku (rakupp 5.3.0 and Rakudo 2026.09 agree): for each byte b,
  // Blob.new(b).decode('windows-1252') matched against each class.
  const std::uint8_t CHAR_CLASS[256] =
  {
      8,   8,   8,   8,   8,   8,   8,   8,   8, 202, 228, 228, 228, 228,   8,   8,
      8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   8,
    202,   8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   8,
     25,  25,  25,  25,  25,  25,  25,  25,  25,  25,   8,   8,   8,   8,   8,   8,
      8,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,
      9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   8,   8,   8,   8,   9,
      8,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,
      9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   8,   8,   8,   8,   8,
      8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   9,   8,   9,   8,   9,   8,
      8,   8,   8,   8,   8,   8,   8,   8,   8,   8,   9,   8,   9,   8,   9,   9,
    202,   8,   8,   8,   8,   8,   8,   8,   8,   8,   9,   8,   8,   8,   8,   8,
      8,   8,   8,   8,   8,   9,   8,   8,   8,   8,   9,   8,   8,   8,   8,   8,
      9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,
      9,   9,   9,   9,   9,   9,   9,   8,   9,   9,   9,   9,   9,   9,   9,   9,
      9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,   9,
      9,   9,   9,   9,   9,   9,   9,   8,   9,   9,   9,   9,   9,   9,   9,   9,
  };

  // Raku lowers the letters beyond ASCII too: 'À' (0xC0) is 'à' (0xE0), and
  // so on, as windows-1252 places them -- 'Š' 0x8A, 'Œ' 0x8C, 'Ž' 0x8E,
  // 'Ÿ' 0x9F; '×' (0xD7) has no lower case.
  std::string lc(std::string_view s)
  {
    std::string out(s);
    for (char& ch : out)
    {
      unsigned c = static_cast<unsigned char>(ch);
      if ((c >= 'A' && c <= 'Z') || (c >= 0xC0 && c <= 0xDE && c != 0xD7))
      {
        ch = static_cast<char>(c + 32);
      }
      else if (c == 0x8A || c == 0x8C || c == 0x8E)
      {
        ch = static_cast<char>(c + 16);
      }
      else if (c == 0x9F)
      {
        ch = static_cast<char>(0xFF);
      }
    }
    return out;
  }

  std::string trim(std::string_view s)
  {
    std::size_t a = 0;
    std::size_t b = s.size();
    while (a < b && is_trim(static_cast<unsigned char>(s[a])))
    {
      a++;
    }
    while (b > a && is_trim(static_cast<unsigned char>(s[b - 1])))
    {
      b--;
    }
    return std::string(s.substr(a, b - a));
  }
}
