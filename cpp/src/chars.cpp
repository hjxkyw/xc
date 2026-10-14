// xc -- the characters of a source (see chars.h).

#include "chars.h"

#include <utility>

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

  // And raises them so: 'ÿ' (0xFF) is 'Ÿ' (0x9F), 'ß' is "SS"; 'µ' has no
  // capital windows-1252 holds, and stays.
  std::string uc(std::string_view s)
  {
    std::string out;
    out.reserve(s.size());
    for (char ch : s)
    {
      unsigned c = static_cast<unsigned char>(ch);
      if ((c >= 'a' && c <= 'z') || (c >= 0xE0 && c <= 0xFE && c != 0xF7))
      {
        out += static_cast<char>(c - 32);
      }
      else if (c == 0x9A || c == 0x9C || c == 0x9E)
      {
        out += static_cast<char>(c - 16);
      }
      else if (c == 0xFF)
      {
        out += static_cast<char>(0x9F);
      }
      else if (c == 0xDF)
      {
        out += "SS";
      }
      else
      {
        out += ch;
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

  bool utf8_to_cp1252(const std::string& in, std::string& out)
  {
    static const std::pair<unsigned, unsigned char> high[] =
    {
      { 0x20AC, 0x80 }, { 0x201A, 0x82 }, { 0x0192, 0x83 }, { 0x201E, 0x84 }, { 0x2026, 0x85 },
      { 0x2020, 0x86 }, { 0x2021, 0x87 }, { 0x02C6, 0x88 }, { 0x2030, 0x89 }, { 0x0160, 0x8A },
      { 0x2039, 0x8B }, { 0x0152, 0x8C }, { 0x017D, 0x8E }, { 0x2018, 0x91 }, { 0x2019, 0x92 },
      { 0x201C, 0x93 }, { 0x201D, 0x94 }, { 0x2022, 0x95 }, { 0x2013, 0x96 }, { 0x2014, 0x97 },
      { 0x02DC, 0x98 }, { 0x2122, 0x99 }, { 0x0161, 0x9A }, { 0x203A, 0x9B }, { 0x0153, 0x9C },
      { 0x017E, 0x9E }, { 0x0178, 0x9F },
    };
    out.clear();
    std::size_t i = 0;
    while (i < in.size())
    {
      unsigned char b = static_cast<unsigned char>(in[i]);
      unsigned cp = 0;
      int n = 0;
      if (b < 0x80) { cp = b; n = 0; }
      else if ((b & 0xE0) == 0xC0) { cp = b & 0x1F; n = 1; }
      else if ((b & 0xF0) == 0xE0) { cp = b & 0x0F; n = 2; }
      else if ((b & 0xF8) == 0xF0) { cp = b & 0x07; n = 3; }
      else { return false; }
      for (int k = 1; k <= n; k++)
      {
        if (i + k >= in.size())
        {
          return false;
        }
        unsigned char c = static_cast<unsigned char>(in[i + k]);
        if ((c & 0xC0) != 0x80)
        {
          return false;
        }
        cp = (cp << 6) | (c & 0x3F);
      }
      if ((n == 1 && cp < 0x80) || (n == 2 && cp < 0x800) || (n == 3 && cp < 0x10000) || cp > 0x10FFFF
          || (cp >= 0xD800 && cp <= 0xDFFF))
      {
        return false;
      }
      if (cp < 0x100)
      {
        out += static_cast<char>(cp);
      }
      else
      {
        char c = '?';
        for (auto [u, w] : high)
        {
          if (u == cp)
          {
            c = static_cast<char>(w);
            break;
          }
        }
        out += c;
      }
      i += n + 1;
    }
    return true;
  }
}
