// xc -- TL++'s Decimal ('F'): what is one, and how one is written.
//
// A Decimal takes no number the compiler can see, and no operator but the
// comparisons and '-' before it: its arithmetic is the DEC_ functions'
// (probes xcz, xdd and xde, on 24.3.1.9). So xc writes a literal that goes
// into one as DEC_CREATE of the literal's own text, an operator with one on
// a side as the DEC_ function of the operator, and one that goes into a
// Numeric as DEC_TO_DBL of it (lower.cpp); and it refuses a value known to
// be Numeric where it meets one (check.cpp). The DEC_ functions there are
// (probes xdf and xdg): DEC_CREATE, DEC_ADD, DEC_SUB, DEC_MUL, DEC_DIV,
// DEC_MOD, DEC_POW, DEC_RESIZE, DEC_RESCALE, DEC_ROUND and DEC_TO_DBL.

#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "ast.h"
#include "check.h"

namespace xc
{
  // The most digits a Decimal holds: DEC_CREATE takes a precision "greater
  // than 0 and smaller than 64".
  constexpr int DECIMAL_DIGITS = 63;

  // A type as written -- 'Decimal', or 'as Decimal' -- that is TL++'s
  // Decimal; one that is a number: Numeric, Integer or Double.
  bool decimal_word(const std::optional<std::string>& written);
  bool numeric_word(const std::optional<std::string>& written);

  // '+' '-' '*' '/' '%' '**' '^', whose Decimal form is a DEC_ function.
  bool arithmetic(const std::string& op);
  bool comparison(const std::string& op);
  std::string dec_function(const std::string& op);

  bool number_literal(const Expr* e);
  // How many digits a number literal has: its whole part (at least one) and
  // its decimals.
  int literal_digits(const std::string& text);
  // The literal made a Decimal, from its own text: '1.25' is
  // 'DEC_CREATE("1.25", 3, 2)' -- its digits and its decimals, exactly.
  std::string dec_create(const std::string& text);

  // What is a Decimal in a file: the names a function declares so -- and the
  // file's statics --, the file's functions declared so, and the parameters
  // of its functions that are; with the names declared as numbers. Nothing
  // is one until file() is called: a .prw has no Decimal -- AdvPL does not
  // check its types, and its 'as Decimal' leaves a number a number.
  class Decimals
  {
  public:
    void file(const Program* p);
    void function(const std::vector<Param*>& params, const Body& body);

    // A name declared 'as Decimal', a DEC_ call, a function of the file
    // declared so, Round() or NoRound() of one, If() with one in a branch,
    // '-' before one, an operator with one on a side, an assignment to one.
    bool decimal(const Expr* e) const;
    // A name declared as a number, a function of the file declared so,
    // DEC_TO_DBL(), or arithmetic with one and no Decimal.
    bool numeric(const Expr* e) const;
    // A number literal, '-' before one, or arithmetic of those and of
    // Decimals: what goes into a Decimal as one.
    bool constant(const Expr* e) const;
    // For a call of a function of the file, which of its parameters are
    // Decimals, or numbers; null for any other call.
    const std::vector<bool>* params_of(const Expr* call) const;
    const std::vector<bool>* numeric_params_of(const Expr* call) const;

  private:
    bool on_ = false;
    std::unordered_set<std::string> statics_;
    std::unordered_set<std::string> static_numerics_;
    std::unordered_set<std::string> names_;
    std::unordered_set<std::string> numerics_;
    std::unordered_set<std::string> functions_;
    std::unordered_set<std::string> numeric_functions_;
    std::unordered_map<std::string, std::vector<bool>> params_;
    std::unordered_map<std::string, std::vector<bool>> numeric_params_;
  };

  // The values known to be Numeric that meet a Decimal, a Decimal added to
  // a Numeric with '+=' and the like, and the literals with more digits than
  // a Decimal holds -- in TL++.
  std::vector<Finding> decimal_problems(const Program* p, std::optional<std::string_view> source, bool advpl);
}
