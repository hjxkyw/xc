// xc-vm -- runs the bytecode 'xc --bytecode' writes: what docs/bytecode.md
// says each instruction does, as a program, and what the tests run the .xbc
// files they compile with (cpp/tests/bytecode).
//
//   xc-vm [--run=NAME] module.xbc ...
//
// Each module's __INIT runs, in the order given -- what a program needs, xtpl's
// runtime among them, first, the program last --; then NAME -- when it is not
// given, U_MAIN if there is one, else the first user function of the last
// module -- with no arguments. What ConOut() is given goes to the output; an
// error nothing catches goes to the errors, and the exit code is 1.
//
// The AppServer's functions are a few of their namesakes, enough for the
// tests and for xtpl's runtime, compiled to bytecode as any program: the
// strings', the numbers', the dates', the arrays', Eval(), Break(),
// ErrorBlock(), Random() -- the same numbers on every run --; File() and the
// FT_ functions, for a text file; THashMap and JsonObject; Decimals and the
// DEC_ functions, exact, on digits. A work area is a name: it can be selected
// and put back, and it has no records. A macro is a variable's name.

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <variant>
#include <vector>

namespace
{
  // ---- values ---------------------------------------------------------------
  struct Value;
  struct Closure;
  struct Object;
  using Array = std::vector<Value>;
  using ArrayP = std::shared_ptr<Array>;
  using Cell = std::shared_ptr<Value>;

  // Days from 1 January 1970; the empty date is EMPTY_DAY.
  struct Date
  {
    long day;
  };
  constexpr long EMPTY_DAY = -999999999L;

  // A variable passed by reference: where it is, and the cell that keeps it
  // when it is one.
  struct Ref
  {
    Value* to;
    Cell keep;
  };

  // A Decimal, TL++'s 'F': a sign, its digits -- no leading zeros, "0" for
  // zero -- and how many of them are decimals. Exact, as DEC_ is: its
  // arithmetic is on the digits.
  struct Dec
  {
    bool neg = false;
    std::string digits = "0";
    int scale = 0;
  };

  struct Value
  {
    std::variant<std::monostate, bool, double, std::string, Date, ArrayP, std::shared_ptr<Closure>,
                 std::shared_ptr<Object>, Cell, Ref, Dec>
      v;
  };

  Value L(bool b)
  {
    Value x;
    x.v = b;
    return x;
  }
  Value N(double d)
  {
    Value x;
    x.v = d;
    return x;
  }
  Value S(std::string s)
  {
    Value x;
    x.v = std::move(s);
    return x;
  }
  Value A(ArrayP a)
  {
    Value x;
    x.v = std::move(a);
    return x;
  }

  struct Function;
  struct Module;

  // A code block: its function, the cells it shares, the Self of the frame
  // that made it.
  struct Closure
  {
    const Function* fn;
    std::vector<Cell> cells;
    Value self;
  };

  // A class of a module: the classes above it, its data, the function that
  // gives them their values, its methods -> their functions, those of them
  // that are static.
  struct Class
  {
    std::string name;
    const Module* mod = nullptr;
    std::vector<std::string> supers;
    std::vector<std::string> data;
    std::string init;
    std::unordered_map<std::string, std::string> methods;
    std::unordered_set<std::string> statics;
  };

  // THashMap, JsonObject, an error, an object of a module's class.
  struct Object
  {
    enum Kind { Hash, Json, Error, Instance } kind;
    std::vector<std::pair<std::string, Value>> props;      // JSON's, an error's, an object's data, in order
    std::map<std::string, std::pair<Value, Value>> hash;   // a key's text -> the key, the value
    const Class* cls = nullptr;
  };

  bool is_nil(const Value& x) { return std::holds_alternative<std::monostate>(x.v); }

  const Value& deref(const Value& x)
  {
    if (auto r = std::get_if<Ref>(&x.v)) { return *r->to; }
    return x;
  }

  char type_of(const Value& x)
  {
    switch (x.v.index())
    {
      case 0: return 'U';
      case 1: return 'L';
      case 2: return 'N';
      case 3: return 'C';
      case 4: return 'D';
      case 5: return 'A';
      case 6: return 'B';
      case 7: return std::get<std::shared_ptr<Object>>(x.v)->kind == Object::Json ? 'J' : 'O';
      case 10: return 'F';
      default: return 'U';
    }
  }

  std::string upper(std::string s)
  {
    for (char& c : s)
    {
      if (c >= 'a' && c <= 'z') { c = static_cast<char>(c - 32); }
    }
    return s;
  }

  std::string lower(std::string s)
  {
    for (char& c : s)
    {
      if (c >= 'A' && c <= 'Z') { c = static_cast<char>(c + 32); }
    }
    return s;
  }

  std::string num_text(double d)
  {
    char b[64];
    if (d == std::floor(d) && std::fabs(d) < 1e15)
    {
      std::snprintf(b, sizeof b, "%.0f", d == 0 ? 0.0 : d);
      return b;
    }
    std::snprintf(b, sizeof b, "%.15g", d);
    return b;
  }

  // Howard Hinnant's days from a civil date, and back.
  long days_from_civil(long y, long m, long d)
  {
    y -= m <= 2;
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;
    long doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
  }

  void civil_from_days(long z, long& y, long& m, long& d)
  {
    z += 719468;
    long era = (z >= 0 ? z : z - 146096) / 146097;
    long doe = z - era * 146097;
    long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    y = yoe + era * 400;
    long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    long mp = (5 * doy + 2) / 153;
    d = doy - (153 * mp + 2) / 5 + 1;
    m = mp + (mp < 10 ? 3 : -9);
    y += m <= 2;
  }

  std::string dtos(const Date& dt)
  {
    if (dt.day == EMPTY_DAY) { return "        "; }
    long y = 0;
    long m = 0;
    long d = 0;
    civil_from_days(dt.day, y, m, d);
    char b[64];
    std::snprintf(b, sizeof b, "%04ld%02ld%02ld", y, m, d);
    return b;
  }

  Date date_of(const std::string& s)
  {
    if (s.size() < 8 || s.find_first_not_of("0123456789", 0) < 8) { return Date{ EMPTY_DAY }; }
    return Date{ days_from_civil(std::stol(s.substr(0, 4)), std::stol(s.substr(4, 2)), std::stol(s.substr(6, 2))) };
  }

  // ---- Decimals: arithmetic on digits ---------------------------------------
  std::string strip(std::string d)
  {
    std::size_t nz = d.find_first_not_of('0');
    return nz == std::string::npos ? "0" : d.substr(nz);
  }

  int cmp_mag(const std::string& a, const std::string& b)
  {
    if (a.size() != b.size()) { return a.size() < b.size() ? -1 : 1; }
    int c = a.compare(b);
    return c < 0 ? -1 : c > 0 ? 1 : 0;
  }

  std::string add_mag(const std::string& a, const std::string& b)
  {
    std::string out;
    int carry = 0;
    for (std::size_t i = 0; i < std::max(a.size(), b.size()) || carry; i++)
    {
      int d = carry;
      if (i < a.size()) { d += a[a.size() - 1 - i] - '0'; }
      if (i < b.size()) { d += b[b.size() - 1 - i] - '0'; }
      out += static_cast<char>('0' + d % 10);
      carry = d / 10;
    }
    return strip(std::string(out.rbegin(), out.rend()));
  }

  // a - b, a not smaller than b.
  std::string sub_mag(const std::string& a, const std::string& b)
  {
    std::string out;
    int borrow = 0;
    for (std::size_t i = 0; i < a.size(); i++)
    {
      int d = (a[a.size() - 1 - i] - '0') - borrow - (i < b.size() ? b[b.size() - 1 - i] - '0' : 0);
      borrow = d < 0 ? 1 : 0;
      out += static_cast<char>('0' + (d + 10) % 10);
    }
    return strip(std::string(out.rbegin(), out.rend()));
  }

  std::string mul_mag(const std::string& a, const std::string& b)
  {
    std::vector<int> r(a.size() + b.size(), 0);
    for (std::size_t i = a.size(); i-- > 0;)
    {
      for (std::size_t j = b.size(); j-- > 0;)
      {
        r[i + j + 1] += (a[i] - '0') * (b[j] - '0');
      }
    }
    for (std::size_t k = r.size(); k-- > 1;)
    {
      r[k - 1] += r[k] / 10;
      r[k] %= 10;
    }
    std::string out;
    for (int d : r) { out += static_cast<char>('0' + d); }
    return strip(out);
  }

  // a / b and a % b, b not zero: long division, a digit at a time.
  std::pair<std::string, std::string> divmod_mag(const std::string& a, const std::string& b)
  {
    std::string q;
    std::string rem = "0";
    for (char c : a)
    {
      rem = strip(rem + c);
      int d = 0;
      while (cmp_mag(rem, b) >= 0)
      {
        rem = sub_mag(rem, b);
        d++;
      }
      q += static_cast<char>('0' + d);
    }
    return { strip(q), rem };
  }

  Dec dec_norm(Dec d)
  {
    d.digits = strip(d.digits);
    if (d.digits == "0") { d.neg = false; }
    return d;
  }

  // The same value with more decimals.
  Dec dec_align(Dec d, int scale)
  {
    if (scale > d.scale)
    {
      d.digits = strip(d.digits + std::string(static_cast<std::size_t>(scale - d.scale), '0'));
      d.scale = scale;
    }
    return d;
  }

  Dec dec_neg(Dec d)
  {
    d.neg = !d.neg;
    return dec_norm(d);
  }

  Dec dec_add(const Dec& x, const Dec& y)
  {
    int s = std::max(x.scale, y.scale);
    Dec a = dec_align(x, s);
    Dec b = dec_align(y, s);
    Dec r;
    r.scale = s;
    if (a.neg == b.neg)
    {
      r.digits = add_mag(a.digits, b.digits);
      r.neg = a.neg;
    }
    else if (cmp_mag(a.digits, b.digits) >= 0)
    {
      r.digits = sub_mag(a.digits, b.digits);
      r.neg = a.neg;
    }
    else
    {
      r.digits = sub_mag(b.digits, a.digits);
      r.neg = b.neg;
    }
    return dec_norm(r);
  }

  Dec dec_mul(const Dec& a, const Dec& b)
  {
    return dec_norm(Dec{ a.neg != b.neg, mul_mag(a.digits, b.digits), a.scale + b.scale });
  }

  // a / b to 'scale' decimals, the rest cut.
  Dec dec_div(const Dec& a, const Dec& b, int scale)
  {
    std::string num = a.digits + std::string(static_cast<std::size_t>(b.scale + scale), '0');
    std::string den = b.digits + std::string(static_cast<std::size_t>(a.scale), '0');
    return dec_norm(Dec{ a.neg != b.neg, divmod_mag(strip(num), strip(den)).first, scale });
  }

  // What is left of a / b, the sign a's, as '%' has it.
  Dec dec_mod(const Dec& x, const Dec& y)
  {
    int s = std::max(x.scale, y.scale);
    Dec a = dec_align(x, s);
    Dec b = dec_align(y, s);
    return dec_norm(Dec{ a.neg, divmod_mag(a.digits, b.digits).second, s });
  }

  // To 'scale' decimals: mode 0 half away from zero, 2 cut.
  Dec dec_rescale(const Dec& d, int scale, int mode)
  {
    if (scale >= d.scale) { return dec_align(d, scale); }
    std::size_t cut = static_cast<std::size_t>(d.scale - scale);
    std::string all = std::string(cut + 1 > d.digits.size() ? cut + 1 - d.digits.size() : 0, '0') + d.digits;
    std::string kept = all.substr(0, all.size() - cut);
    bool up = mode != 2 && all[all.size() - cut] >= '5';
    Dec r{ d.neg, up ? add_mag(kept, "1") : strip(kept), scale };
    return dec_norm(r);
  }

  int dec_cmp(const Dec& x, const Dec& y)
  {
    if (x.neg != y.neg) { return x.neg ? -1 : 1; }
    int s = std::max(x.scale, y.scale);
    int c = cmp_mag(dec_align(x, s).digits, dec_align(y, s).digits);
    return x.neg ? -c : c;
  }

  std::string dec_text(const Dec& d)
  {
    std::string t = d.digits;
    if (d.scale > 0)
    {
      if (static_cast<int>(t.size()) <= d.scale) { t = std::string(static_cast<std::size_t>(d.scale + 1) - t.size(), '0') + t; }
      t.insert(t.size() - static_cast<std::size_t>(d.scale), ".");
    }
    return (d.neg ? "-" : "") + t;
  }

  // A number's text as a Decimal: '-' and digits, a '.' and decimals.
  bool dec_parse(const std::string& t0, Dec& out)
  {
    std::string t = t0;
    std::size_t b = t.find_first_not_of(' ');
    std::size_t e = t.find_last_not_of(' ');
    t = b == std::string::npos ? "" : t.substr(b, e - b + 1);
    Dec d;
    std::size_t i = 0;
    if (i < t.size() && (t[i] == '-' || t[i] == '+')) { d.neg = t[i++] == '-'; }
    std::string whole;
    std::string decimals;
    while (i < t.size() && t[i] >= '0' && t[i] <= '9') { whole += t[i++]; }
    if (i < t.size() && t[i] == '.')
    {
      i++;
      while (i < t.size() && t[i] >= '0' && t[i] <= '9') { decimals += t[i++]; }
    }
    if (i != t.size() || (whole.empty() && decimals.empty())) { return false; }
    d.digits = whole + decimals;
    d.scale = static_cast<int>(decimals.size());
    out = dec_norm(d);
    return true;
  }

  // cValToChar().
  std::string text(const Value& x0)
  {
    const Value& x = deref(x0);
    switch (type_of(x))
    {
      case 'N': return num_text(std::get<double>(x.v));
      case 'C': return std::get<std::string>(x.v);
      case 'L': return std::get<bool>(x.v) ? ".T." : ".F.";
      case 'F': return dec_text(std::get<Dec>(x.v));
      case 'D':
      {
        std::string s = dtos(std::get<Date>(x.v));
        return s == "        " ? "  /  /    " : s.substr(6, 2) + "/" + s.substr(4, 2) + "/" + s.substr(0, 4);
      }
      default: return "";
    }
  }

  // ---- the program ----------------------------------------------------------
  enum class Op
  {
    Nil, True, False, Num, Str,
    Local, SetLocal, Box, CellOp, SetCell, Upval, SetUpval, Static, SetStatic, Memvar, SetMemvar, Private, Public,
    Field, SetField, FieldX, SetFieldX,
    RefLocal, RefCell, RefUpval, RefStatic, RefMemvar,
    Pop, Dup, Dup2, ArrayOp, Index, SetIndex, Member, SetMember, Self,
    Add, Sub, Mul, Div, Mod, Pow, Neg, Not, Eq, Exact, Ne, Lt, Gt, Le, Ge, Contains, IsNil,
    Jump, JumpF, JumpT, AndJump, OrJump,
    Call, CallX, Method, Super, New, Ret, Block, Macro, SetMacro, Line,
    Seq, Try, EndSeq, Defer, RunDefers, EndDefer, Area, EndArea,
  };

  enum class Shape { None, Int, Word, Number, String, IntWord, WordWord, WordInt, IntInt, IntWordWord };

  struct OpInfo
  {
    const char* name;
    Op op;
    Shape shape;
  };

  const OpInfo OPS[] = {
    { "nil", Op::Nil, Shape::None }, { "true", Op::True, Shape::None }, { "false", Op::False, Shape::None },
    { "num", Op::Num, Shape::Number }, { "str", Op::Str, Shape::String },
    { "local", Op::Local, Shape::Int }, { "setlocal", Op::SetLocal, Shape::Int }, { "box", Op::Box, Shape::Int },
    { "cell", Op::CellOp, Shape::Int }, { "setcell", Op::SetCell, Shape::Int }, { "upval", Op::Upval, Shape::Int },
    { "setupval", Op::SetUpval, Shape::Int }, { "static", Op::Static, Shape::Int },
    { "setstatic", Op::SetStatic, Shape::Int }, { "memvar", Op::Memvar, Shape::Word },
    { "setmemvar", Op::SetMemvar, Shape::Word }, { "private", Op::Private, Shape::Word },
    { "public", Op::Public, Shape::Word }, { "field", Op::Field, Shape::WordWord },
    { "setfield", Op::SetField, Shape::WordWord }, { "fieldx", Op::FieldX, Shape::Word },
    { "setfieldx", Op::SetFieldX, Shape::Word }, { "reflocal", Op::RefLocal, Shape::Int },
    { "refcell", Op::RefCell, Shape::Int }, { "refupval", Op::RefUpval, Shape::Int },
    { "refstatic", Op::RefStatic, Shape::Int }, { "refmemvar", Op::RefMemvar, Shape::Word },
    { "pop", Op::Pop, Shape::None }, { "dup", Op::Dup, Shape::None }, { "dup2", Op::Dup2, Shape::None },
    { "array", Op::ArrayOp, Shape::Int }, { "index", Op::Index, Shape::None },
    { "setindex", Op::SetIndex, Shape::None }, { "member", Op::Member, Shape::Word },
    { "setmember", Op::SetMember, Shape::Word }, { "self", Op::Self, Shape::None },
    { "add", Op::Add, Shape::None }, { "sub", Op::Sub, Shape::None }, { "mul", Op::Mul, Shape::None },
    { "div", Op::Div, Shape::None }, { "mod", Op::Mod, Shape::None }, { "pow", Op::Pow, Shape::None },
    { "neg", Op::Neg, Shape::None }, { "not", Op::Not, Shape::None }, { "eq", Op::Eq, Shape::None },
    { "exact", Op::Exact, Shape::None }, { "ne", Op::Ne, Shape::None }, { "lt", Op::Lt, Shape::None },
    { "gt", Op::Gt, Shape::None }, { "le", Op::Le, Shape::None }, { "ge", Op::Ge, Shape::None },
    { "contains", Op::Contains, Shape::None }, { "isnil", Op::IsNil, Shape::None },
    { "jump", Op::Jump, Shape::Int }, { "jumpf", Op::JumpF, Shape::Int }, { "jumpt", Op::JumpT, Shape::Int },
    { "andjump", Op::AndJump, Shape::Int }, { "orjump", Op::OrJump, Shape::Int },
    { "call", Op::Call, Shape::IntWord }, { "callx", Op::CallX, Shape::Int },
    { "method", Op::Method, Shape::IntWord }, { "super", Op::Super, Shape::IntWord },
    { "new", Op::New, Shape::IntWordWord }, { "ret", Op::Ret, Shape::None },
    { "block", Op::Block, Shape::WordInt }, { "macro", Op::Macro, Shape::None },
    { "setmacro", Op::SetMacro, Shape::None }, { "line", Op::Line, Shape::Int },
    { "seq", Op::Seq, Shape::Int }, { "try", Op::Try, Shape::Int }, { "endseq", Op::EndSeq, Shape::None },
    { "defer", Op::Defer, Shape::IntInt }, { "rundefers", Op::RunDefers, Shape::None },
    { "enddefer", Op::EndDefer, Shape::None }, { "area", Op::Area, Shape::None },
    { "endarea", Op::EndArea, Shape::None },
  };

  struct Ins
  {
    Op op = Op::Nil;
    long a = 0;
    long b = 0;
    double n = 0;
    std::string s;
    std::string s2;
  };

  struct Function
  {
    std::string name;
    std::string kind;
    long params = 0;
    long nlocals = 0;
    std::vector<Ins> code;
    Module* mod = nullptr;
  };

  struct Module
  {
    std::string source;
    std::string ns;                       // its namespace, or ""
    std::vector<std::string> usings;
    std::vector<Value> statics;
    std::vector<std::unique_ptr<Function>> fns;
    std::unordered_map<std::string, Function*> by_name;
    std::vector<std::unique_ptr<Class>> classes;
  };

  // ---- a call ---------------------------------------------------------------
  struct Frame
  {
    const Function* fn = nullptr;
    std::vector<Value> locals;
    std::vector<Value> stack;
    std::size_t pc = 0;
    long line = 0;
    std::size_t argc = 0;
    std::shared_ptr<Closure> closure;
    Value self;
    std::vector<std::pair<std::size_t, Ref>> byref;
    struct Region
    {
      bool tries;
      std::size_t target;
      std::size_t depth;
      std::size_t areas;
    };
    std::vector<Region> regions;
    std::vector<std::size_t> areas;       // what each 'area' found selected
    std::map<long, std::size_t> defers;   // reached, by their number
    std::size_t defer_back = 0;
    std::vector<std::string> privates;
    bool constructs = false;              // 'Name():M()': the caller gets Self
  };

  // A Break, or an error, on its way to the region that takes it.
  struct Unwind
  {
    Value v;
    bool error;
  };

  using Args = std::vector<Value>;
  using Native = std::function<Value(Args&)>;

  // ---- the machine ----------------------------------------------------------
  class VM
  {
  public:
    VM() { natives(); }
    void load(const std::string& path);
    int start(const std::string& entry);

  private:
    std::vector<std::unique_ptr<Module>> modules_;
    std::unordered_map<std::string, const Function*> globals_;
    std::unordered_map<std::string, const Function*> every_;   // every function of every module, by name
    std::unordered_map<std::string, const Class*> classes_;
    std::unordered_map<std::string, Native> natives_;
    std::vector<std::unique_ptr<Frame>> frames_;
    std::unordered_map<std::string, std::vector<std::pair<std::size_t, Cell>>> privates_;
    std::unordered_map<std::string, Cell> publics_;
    Value error_block_;
    bool in_error_block_ = false;
    std::vector<std::string> areas_{ "" };
    std::size_t area_ = 0;
    // The text file FT_FUse() opened -- one at a time, as AdvPL's --: its
    // lines, and the one it is on.
    std::vector<std::string> ft_lines_;
    std::size_t ft_at_ = 0;
    // Random()'s numbers: the same on every run, for the tests.
    std::mt19937 random_{ 1 };
    std::string where_;

    // ---- errors -------------------------------------------------------------
    [[noreturn]] void fail(const std::string& description);
    Value error_object(const std::string& description);

    // ---- calls --------------------------------------------------------------
    void push_frame(const Function* fn, Args& args, std::shared_ptr<Closure> closure, Value self);
    void end_frame(Frame& f);
    Value run(std::size_t base);
    bool unwind(std::size_t base, const Unwind& u);
    bool exec(std::size_t base, Value& result);
    const Function* function_named(const Module* from, const std::string& name, bool macro = false) const;
    const Class* class_named(const Module* from, const std::string& name) const;
    void invoke(const Module* from, const std::string& name, Args& args, bool macro = false);
    Value call_value(const Value& block, Args args);
    Value instance(const Class* c);
    const Function* method_of(const Class* c, const std::string& name, bool* is_static = nullptr) const;
    Value method(const Value& o, const std::string& name, Args& args);

    // ---- variables ----------------------------------------------------------
    Cell* memvar(const std::string& name);
    Cell private_var(const std::string& name);

    // ---- operators ----------------------------------------------------------
    Value arith(Op op, const Value& a, const Value& b);
    bool equal(const Value& a, const Value& b, bool exact, const char* op);
    int order(const Value& a, const Value& b, const char* op);
    Value index(const Value& a, const Value& i);
    void set_index(const Value& a, const Value& i, const Value& x);
    Value member(const Value& o, const std::string& name);
    void set_member(const Value& o, const std::string& name, const Value& x);
    bool logical(const Value& x, const char* what);

    // ---- the AppServer's ----------------------------------------------------
    void natives();
    double num_arg(const Args& a, std::size_t i, const char* fn);
    std::string str_arg(const Args& a, std::size_t i, const char* fn);
    ArrayP array_arg(const Args& a, std::size_t i, const char* fn);
    std::string key_text(const Value& k);
    std::string json_text(const Value& x);
    bool evals_true(const Value& block, Args args, const char* fn);
  };

  const Value& at(const Args& a, std::size_t i)
  {
    static const Value nil;
    return i < a.size() ? deref(a[i]) : nil;
  }

  // ---- loading --------------------------------------------------------------
  std::vector<std::string> words_of(const std::string& s)
  {
    std::vector<std::string> out;
    std::istringstream in(s);
    std::string w;
    while (in >> w) { out.push_back(w); }
    return out;
  }

  long to_long(const std::string& w, const std::string& where)
  {
    char* end = nullptr;
    long n = std::strtol(w.c_str(), &end, 10);
    if (w.empty() || *end) { throw std::runtime_error(where + ": '" + w + "' is no number"); }
    return n;
  }

  void VM::load(const std::string& path)
  {
    std::ifstream in(path, std::ios::binary);
    if (!in) { throw std::runtime_error(path + ": cannot be read"); }
    auto mod = std::make_unique<Module>();
    std::vector<std::string> lines;
    std::string l;
    while (std::getline(in, l))
    {
      if (!l.empty() && l.back() == '\r') { l.pop_back(); }
      std::size_t b = l.find_first_not_of(" \t");
      lines.push_back(b == std::string::npos ? "" : l.substr(b));
    }
    std::size_t i = 0;
    auto where = [&](std::size_t k) { return path + ":" + std::to_string(k + 1); };
    auto next = [&]() -> std::string
    {
      while (i < lines.size() && lines[i].empty()) { i++; }
      return i < lines.size() ? lines[i] : "";
    };
    if (next() != "xbc 1") { throw std::runtime_error(path + ": not a .xbc of version 1"); }
    i++;
    std::vector<std::string> w = words_of(next());
    if (w.size() < 2 || w[0] != "source") { throw std::runtime_error(where(i) + ": 'source' expected"); }
    mod->source = w[1];
    i++;
    w = words_of(next());
    if (w.size() != 2 || w[0] != "statics") { throw std::runtime_error(where(i) + ": 'statics' expected"); }
    mod->statics.resize(static_cast<std::size_t>(to_long(w[1], where(i))));
    i++;
    while (!next().empty())
    {
      w = words_of(lines[i]);
      if (w.size() == 2 && (w[0] == "namespace" || w[0] == "using"))
      {
        if (w[0] == "namespace") { mod->ns = w[1]; }
        else { mod->usings.push_back(w[1]); }
        i++;
        continue;
      }
      if (w.size() == 2 && w[0] == "class")
      {
        auto c = std::make_unique<Class>();
        c->name = w[1];
        c->mod = mod.get();
        i++;
        for (;;)
        {
          std::string t = next();
          if (t.empty()) { throw std::runtime_error(path + ": class " + c->name + " has no 'end'"); }
          std::size_t k = i++;
          std::vector<std::string> cw = words_of(t);
          if (cw[0] == "end") { break; }
          if (cw[0] == "from") { c->supers.assign(cw.begin() + 1, cw.end()); }
          else if (cw[0] == "data") { c->data.insert(c->data.end(), cw.begin() + 1, cw.end()); }
          else if (cw[0] == "init" && cw.size() == 2) { c->init = cw[1]; }
          else if ((cw[0] == "method" || cw[0] == "static") && cw.size() == 3)
          {
            c->methods[cw[1]] = cw[2];
            if (cw[0] == "static") { c->statics.insert(cw[1]); }
          }
          else { throw std::runtime_error(where(k) + ": no line '" + cw[0] + "' in a class"); }
        }
        classes_[c->name] = c.get();
        mod->classes.push_back(std::move(c));
        continue;
      }
      if (w.size() != 5 || w[0] != "function") { throw std::runtime_error(where(i) + ": 'function' expected"); }
      auto fn = std::make_unique<Function>();
      fn->name = w[1];
      fn->kind = w[2];
      fn->params = to_long(w[3], where(i));
      fn->nlocals = to_long(w[4], where(i));
      fn->mod = mod.get();
      i++;
      for (;;)
      {
        std::string t = next();
        if (t.empty()) { throw std::runtime_error(path + ": " + fn->name + " has no 'end'"); }
        std::size_t k = i++;
        if (t == "end") { break; }
        std::string opw = t.substr(0, t.find(' '));
        if (opw == "locals" || opw == "upvals") { continue; }
        const OpInfo* info = nullptr;
        for (const OpInfo& o : OPS)
        {
          if (opw == o.name) { info = &o; }
        }
        if (!info) { throw std::runtime_error(where(k) + ": no instruction '" + opw + "'"); }
        Ins ins;
        ins.op = info->op;
        if (info->shape == Shape::String)
        {
          std::size_t q = t.find('"');
          if (q == std::string::npos || t.back() != '"' || t.size() - q < 2)
          {
            throw std::runtime_error(where(k) + ": a string in quotes expected");
          }
          ins.s = t.substr(q + 1, t.size() - q - 2);
        }
        else
        {
          std::vector<std::string> a = words_of(t);
          std::size_t want = info->shape == Shape::None ? 1 : (info->shape == Shape::Int || info->shape == Shape::Word
                                                               || info->shape == Shape::Number) ? 2
                             : info->shape == Shape::IntWordWord ? 4 : 3;
          if (a.size() != want) { throw std::runtime_error(where(k) + ": '" + opw + "' takes " + std::to_string(want - 1)); }
          switch (info->shape)
          {
            case Shape::Int: ins.a = to_long(a[1], where(k)); break;
            case Shape::Word: ins.s = a[1]; break;
            case Shape::Number: ins.n = std::strtod(a[1].c_str(), nullptr); break;
            case Shape::IntWord:
              ins.a = to_long(a[1], where(k));
              ins.s = a[2];
              break;
            case Shape::WordWord:
              ins.s = a[1];
              ins.s2 = a[2];
              break;
            case Shape::WordInt:
              ins.s = a[1];
              ins.b = to_long(a[2], where(k));
              break;
            case Shape::IntInt:
              ins.a = to_long(a[1], where(k));
              ins.b = to_long(a[2], where(k));
              break;
            case Shape::IntWordWord:
              ins.a = to_long(a[1], where(k));
              ins.s = a[2];
              ins.s2 = a[3];
              break;
            default: break;
          }
        }
        fn->code.push_back(std::move(ins));
      }
      // What an instruction names is there: a local, a static, a target.
      long n = static_cast<long>(fn->code.size());
      for (const Ins& x : fn->code)
      {
        bool jumps = x.op == Op::Jump || x.op == Op::JumpF || x.op == Op::JumpT || x.op == Op::AndJump
                     || x.op == Op::OrJump || x.op == Op::Seq || x.op == Op::Try;
        if ((jumps && (x.a < 1 || x.a > n)) || (x.op == Op::Defer && (x.b < 1 || x.b > n)))
        {
          throw std::runtime_error(path + ": " + fn->name + " jumps outside itself");
        }
        bool local = x.op == Op::Local || x.op == Op::SetLocal || x.op == Op::Box || x.op == Op::CellOp
                     || x.op == Op::SetCell || x.op == Op::RefLocal || x.op == Op::RefCell;
        if (local && (x.a < 1 || x.a > fn->nlocals)) { throw std::runtime_error(path + ": " + fn->name + " has no local " + std::to_string(x.a)); }
        bool stat = x.op == Op::Static || x.op == Op::SetStatic || x.op == Op::RefStatic;
        if (stat && (x.a < 1 || x.a > static_cast<long>(mod->statics.size())))
        {
          throw std::runtime_error(path + ": no static " + std::to_string(x.a));
        }
      }
      mod->by_name[upper(fn->name)] = fn.get();
      every_[upper(fn->name)] = fn.get();
      if (fn->kind == "user" || fn->kind == "function" || fn->kind == "main") { globals_[upper(fn->name)] = fn.get(); }
      mod->fns.push_back(std::move(fn));
    }
    modules_.push_back(std::move(mod));
  }

  // ---- errors ---------------------------------------------------------------
  Value VM::error_object(const std::string& description)
  {
    auto o = std::make_shared<Object>();
    o->kind = Object::Error;
    o->props = { { "Description", S(description) }, { "GenCode", N(0) }, { "Operation", S("") },
                 { "SubSystem", S("XC-VM") } };
    Value x;
    x.v = o;
    return x;
  }

  // An error: the ErrorBlock() the program set has it first -- a Break there
  // goes to the innermost region --; else it goes to the innermost 'try'.
  void VM::fail(const std::string& description)
  {
    if (!frames_.empty())
    {
      where_ = frames_.back()->fn->name + ", line " + std::to_string(frames_.back()->line);
    }
    Value e = error_object(description);
    if (!is_nil(error_block_) && !in_error_block_)
    {
      Value b = error_block_;
      in_error_block_ = true;
      try
      {
        call_value(b, { e });
      }
      catch (...)
      {
        in_error_block_ = false;
        throw;
      }
      in_error_block_ = false;
    }
    throw Unwind{ e, true };
  }

  bool VM::logical(const Value& x, const char* what)
  {
    if (auto b = std::get_if<bool>(&deref(x).v)) { return *b; }
    fail(std::string("not a logical value in ") + what);
  }

  // ---- calls ----------------------------------------------------------------
  void VM::push_frame(const Function* fn, Args& args, std::shared_ptr<Closure> closure, Value self)
  {
    if (frames_.size() > 4000) { fail("stack overflow"); }
    auto f = std::make_unique<Frame>();
    f->fn = fn;
    f->locals.resize(static_cast<std::size_t>(fn->nlocals));
    f->argc = args.size();
    f->closure = std::move(closure);
    f->self = std::move(self);
    std::size_t n = std::min(args.size(), static_cast<std::size_t>(fn->params));
    for (std::size_t i = 0; i < n; i++)
    {
      if (auto r = std::get_if<Ref>(&args[i].v))
      {
        f->locals[i] = *r->to;
        f->byref.push_back({ i, *r });
      }
      else
      {
        f->locals[i] = args[i];
      }
    }
    frames_.push_back(std::move(f));
  }

  // A frame's end: what its parameters passed by reference hold written
  // back, its privates gone.
  void VM::end_frame(Frame& f)
  {
    for (auto& [i, r] : f.byref)
    {
      const Value& x = f.locals[i];
      if (auto c = std::get_if<Cell>(&x.v)) { *r.to = **c; }
      else { *r.to = x; }
    }
    for (const std::string& p : f.privates)
    {
      auto& list = privates_[p];
      if (!list.empty()) { list.pop_back(); }
    }
  }

  // Runs until the frame at base returns, and gives what it returned.
  Value VM::run(std::size_t base)
  {
    for (;;)
    {
      try
      {
        Value r;
        if (exec(base, r)) { return r; }
      }
      catch (const Unwind& u)
      {
        if (!unwind(base, u)) { throw; }
      }
    }
  }

  // A Break or an error to the innermost region that takes it -- a Break any,
  // an error a 'try' --, in this run: the frames above it go, its stack is cut
  // back, and the value is pushed. False when no region here takes it: then
  // this run's frames go, and it goes on to the run that called.
  bool VM::unwind(std::size_t base, const Unwind& u)
  {
    for (std::size_t k = frames_.size(); k-- > base;)
    {
      Frame& f = *frames_[k];
      for (std::size_t r = f.regions.size(); r-- > 0;)
      {
        if (u.error && !f.regions[r].tries) { continue; }
        while (frames_.size() > k + 1)
        {
          end_frame(*frames_.back());
          frames_.pop_back();
        }
        Frame::Region reg = f.regions[r];
        f.regions.resize(r);
        f.stack.resize(reg.depth);
        f.areas.resize(reg.areas);
        f.stack.push_back(u.v);
        f.pc = reg.target;
        return true;
      }
    }
    while (frames_.size() > base)
    {
      end_frame(*frames_.back());
      frames_.pop_back();
    }
    return false;
  }

  // A function by name, from a module: its own, then -- a name with no
  // namespace -- its namespace's, then those it uses, then one of no
  // namespace, as the AppServer finds them (tried on 24.3.1.9). A macro's
  // name is not looked for in the namespaces.
  const Function* VM::function_named(const Module* from, const std::string& name, bool macro) const
  {
    std::string u = upper(name);
    auto global = [&](const std::string& n) -> const Function*
    {
      auto g = globals_.find(n);
      return g == globals_.end() ? nullptr : g->second;
    };
    if (from)
    {
      auto it = from->by_name.find(u);
      std::string k = it == from->by_name.end() ? "" : it->second->kind;
      if (k == "user" || k == "static" || k == "function" || k == "main") { return it->second; }
      if (!macro && u.find('.') == std::string::npos)
      {
        if (!from->ns.empty())
        {
          if (const Function* f = global(from->ns + "." + u)) { return f; }
        }
        for (const std::string& n : from->usings)
        {
          if (const Function* f = global(n + "." + u)) { return f; }
        }
      }
    }
    return global(u);
  }

  // A class by name, from a module: as a function is found.
  const Class* VM::class_named(const Module* from, const std::string& name) const
  {
    std::string u = upper(name);
    auto one = [&](const std::string& n) -> const Class*
    {
      auto c = classes_.find(n);
      return c == classes_.end() ? nullptr : c->second;
    };
    if (from && u.find('.') == std::string::npos)
    {
      if (!from->ns.empty())
      {
        if (const Class* c = one(from->ns + "." + u)) { return c; }
      }
      for (const std::string& n : from->usings)
      {
        if (const Class* c = one(n + "." + u)) { return c; }
      }
    }
    return one(u);
  }

  // A call by name: a function of the module, a user function of any, or the
  // AppServer's -- a class is none. A function of a module pushes its frame;
  // the AppServer's leaves its result.
  void VM::invoke(const Module* from, const std::string& name, Args& args, bool macro)
  {
    if (const Function* fn = function_named(from, name, macro))
    {
      push_frame(fn, args, nullptr, Value());
      return;
    }
    auto it = natives_.find(upper(name));
    if (it == natives_.end()) { fail("function " + name + " does not exist"); }
    Value r = it->second(args);
    frames_.back()->stack.push_back(std::move(r));
  }

  // A new object of a module's class: the data of the classes above it and
  // its own, Nil, then the values each class gives them, the topmost first.
  Value VM::instance(const Class* c)
  {
    std::vector<const Class*> chain;
    std::function<void(const Class*)> above = [&](const Class* k)
    {
      for (const std::string& s : k->supers)
      {
        if (const Class* up = class_named(k->mod, s)) { above(up); }
      }
      chain.push_back(k);
    };
    above(c);
    auto o = std::make_shared<Object>();
    o->kind = Object::Instance;
    o->cls = c;
    for (const Class* k : chain)
    {
      for (const std::string& d : k->data)
      {
        bool there = false;
        for (const auto& p : o->props) { there = there || p.first == d; }
        if (!there) { o->props.push_back({ d, Value() }); }
      }
    }
    Value self;
    self.v = o;
    for (const Class* k : chain)
    {
      if (k->init.empty()) { continue; }
      auto f = every_.find(k->init);
      if (f == every_.end()) { fail("no function " + k->init + " for the data of " + k->name); }
      Args none;
      push_frame(f->second, none, nullptr, self);
      run(frames_.size() - 1);
    }
    return self;
  }

  // A method, of the class or of one above it.
  const Function* VM::method_of(const Class* c, const std::string& name, bool* is_static) const
  {
    if (auto m = c->methods.find(name); m != c->methods.end())
    {
      auto f = every_.find(m->second);
      if (f != every_.end())
      {
        if (is_static) { *is_static = c->statics.count(name) > 0; }
        return f->second;
      }
    }
    for (const std::string& s : c->supers)
    {
      const Class* up = class_named(c->mod, s);
      if (!up) { continue; }
      if (const Function* f = method_of(up, name, is_static)) { return f; }
    }
    return nullptr;
  }

  Value VM::call_value(const Value& block, Args args)
  {
    auto c = std::get_if<std::shared_ptr<Closure>>(&deref(block).v);
    if (!c) { fail("Eval: not a code block"); }
    push_frame((*c)->fn, args, *c, (*c)->self);
    return run(frames_.size() - 1);
  }

  bool VM::evals_true(const Value& block, Args args, const char* fn)
  {
    Value r = call_value(block, std::move(args));
    return logical(r, fn);
  }

  // ---- variables ------------------------------------------------------------
  Cell* VM::memvar(const std::string& name)
  {
    auto p = privates_.find(name);
    if (p != privates_.end() && !p->second.empty()) { return &p->second.back().second; }
    auto g = publics_.find(name);
    return g == publics_.end() ? nullptr : &g->second;
  }

  // A private of the frame running: one it has already is given Nil again.
  Cell VM::private_var(const std::string& name)
  {
    auto& list = privates_[name];
    std::size_t depth = frames_.size();
    if (!list.empty() && list.back().first == depth)
    {
      *list.back().second = Value();
      return list.back().second;
    }
    list.push_back({ depth, std::make_shared<Value>() });
    frames_.back()->privates.push_back(name);
    return list.back().second;
  }

  // ---- operators ------------------------------------------------------------
  Value VM::arith(Op op, const Value& a0, const Value& b0)
  {
    const Value& a = deref(a0);
    const Value& b = deref(b0);
    char ta = type_of(a);
    char tb = type_of(b);
    const char* sign = op == Op::Add ? "+" : op == Op::Sub ? "-" : op == Op::Mul ? "*" : op == Op::Div ? "/"
                       : op == Op::Mod ? "%" : "**";
    if (ta == 'N' && tb == 'N')
    {
      double x = std::get<double>(a.v);
      double y = std::get<double>(b.v);
      switch (op)
      {
        case Op::Add: return N(x + y);
        case Op::Sub: return N(x - y);
        case Op::Mul: return N(x * y);
        case Op::Div:
          if (y == 0) { fail("zero division"); }
          return N(x / y);
        case Op::Mod:
          if (y == 0) { fail("zero division"); }
          return N(std::fmod(x, y));
        default: return N(std::pow(x, y));
      }
    }
    if (op == Op::Add && ta == 'C' && tb == 'C') { return S(std::get<std::string>(a.v) + std::get<std::string>(b.v)); }
    if (op == Op::Sub && ta == 'C' && tb == 'C')
    {
      // Clipper's: the left's trailing blanks go to the end.
      std::string x = std::get<std::string>(a.v);
      std::size_t e = x.find_last_not_of(' ');
      std::string kept = e == std::string::npos ? "" : x.substr(0, e + 1);
      return S(kept + std::get<std::string>(b.v) + std::string(x.size() - kept.size(), ' '));
    }
    if ((op == Op::Add || op == Op::Sub) && ta == 'D' && tb == 'N')
    {
      double y = std::get<double>(b.v);
      Value r;
      r.v = Date{ std::get<Date>(a.v).day + static_cast<long>(op == Op::Add ? y : -y) };
      return r;
    }
    if (op == Op::Add && ta == 'N' && tb == 'D') { return arith(op, b, a); }
    if (op == Op::Sub && ta == 'D' && tb == 'D')
    {
      return N(static_cast<double>(std::get<Date>(a.v).day - std::get<Date>(b.v).day));
    }
    fail(std::string("type mismatch on ") + sign + ": " + ta + " and " + tb);
  }

  bool VM::equal(const Value& a0, const Value& b0, bool exact, const char* op)
  {
    const Value& a = deref(a0);
    const Value& b = deref(b0);
    char ta = type_of(a);
    char tb = type_of(b);
    if (ta == 'U' || tb == 'U') { return ta == tb; }
    if (ta != tb) { fail(std::string("type mismatch on ") + op + ": " + ta + " and " + tb); }
    switch (ta)
    {
      case 'N': return std::get<double>(a.v) == std::get<double>(b.v);
      case 'L': return std::get<bool>(a.v) == std::get<bool>(b.v);
      case 'F': return dec_cmp(std::get<Dec>(a.v), std::get<Dec>(b.v)) == 0;
      case 'D': return std::get<Date>(a.v).day == std::get<Date>(b.v).day;
      case 'C':
      {
        // '=' is SET EXACT OFF's: the left starts with the right.
        const std::string& x = std::get<std::string>(a.v);
        const std::string& y = std::get<std::string>(b.v);
        if (exact) { return x == y; }
        return x.size() >= y.size() && x.compare(0, y.size(), y) == 0;
      }
      case 'A': return std::get<ArrayP>(a.v) == std::get<ArrayP>(b.v);
      case 'B': return std::get<std::shared_ptr<Closure>>(a.v) == std::get<std::shared_ptr<Closure>>(b.v);
      default: return std::get<std::shared_ptr<Object>>(a.v) == std::get<std::shared_ptr<Object>>(b.v);
    }
  }

  int VM::order(const Value& a0, const Value& b0, const char* op)
  {
    const Value& a = deref(a0);
    const Value& b = deref(b0);
    char ta = type_of(a);
    char tb = type_of(b);
    if (ta == tb)
    {
      switch (ta)
      {
        case 'N':
        {
          double x = std::get<double>(a.v);
          double y = std::get<double>(b.v);
          return x < y ? -1 : x > y ? 1 : 0;
        }
        case 'C':
        {
          int c = std::get<std::string>(a.v).compare(std::get<std::string>(b.v));
          return c < 0 ? -1 : c > 0 ? 1 : 0;
        }
        case 'D':
        {
          long x = std::get<Date>(a.v).day;
          long y = std::get<Date>(b.v).day;
          return x < y ? -1 : x > y ? 1 : 0;
        }
        case 'L': return static_cast<int>(std::get<bool>(a.v)) - static_cast<int>(std::get<bool>(b.v));
        case 'F': return dec_cmp(std::get<Dec>(a.v), std::get<Dec>(b.v));
        default: break;
      }
    }
    fail(std::string("type mismatch on ") + op + ": " + ta + " and " + tb);
  }

  Value VM::index(const Value& a0, const Value& i0)
  {
    const Value& a = deref(a0);
    const Value& i = deref(i0);
    if (auto arr = std::get_if<ArrayP>(&a.v))
    {
      auto n = std::get_if<double>(&i.v);
      if (!n) { fail("array index is not a number"); }
      long k = static_cast<long>(*n);
      if (k < 1 || k > static_cast<long>((*arr)->size())) { fail("array out of bounds [" + num_text(*n) + "]"); }
      return (**arr)[static_cast<std::size_t>(k - 1)];
    }
    if (type_of(a) == 'J') { return member(a, text(i)); }
    fail(std::string("index of what is no array: ") + type_of(a));
  }

  void VM::set_index(const Value& a0, const Value& i0, const Value& x)
  {
    const Value& a = deref(a0);
    const Value& i = deref(i0);
    if (auto arr = std::get_if<ArrayP>(&a.v))
    {
      auto n = std::get_if<double>(&i.v);
      if (!n) { fail("array index is not a number"); }
      long k = static_cast<long>(*n);
      if (k < 1 || k > static_cast<long>((*arr)->size())) { fail("array out of bounds [" + num_text(*n) + "]"); }
      (**arr)[static_cast<std::size_t>(k - 1)] = deref(x);
      return;
    }
    if (type_of(a) == 'J')
    {
      set_member(a, text(i), x);
      return;
    }
    fail(std::string("index of what is no array: ") + type_of(a));
  }

  Value VM::member(const Value& o0, const std::string& name)
  {
    const Value& o = deref(o0);
    auto obj = std::get_if<std::shared_ptr<Object>>(&o.v);
    if (!obj || (*obj)->kind == Object::Hash) { fail("no member " + name + " of " + std::string(1, type_of(o))); }
    if ((*obj)->kind == Object::Instance)
    {
      std::string u = upper(name);
      for (auto& [k, v] : (*obj)->props)
      {
        if (k == u) { return v; }
      }
      fail("no data " + name + " of " + (*obj)->cls->name);
    }
    for (auto& [k, v] : (*obj)->props)
    {
      if (k == name) { return v; }
    }
    for (auto& [k, v] : (*obj)->props)
    {
      if (upper(k) == upper(name)) { return v; }
    }
    if ((*obj)->kind == Object::Json) { return Value(); }
    fail("no member " + name + " of an error");
  }

  void VM::set_member(const Value& o0, const std::string& name, const Value& x)
  {
    const Value& o = deref(o0);
    auto obj = std::get_if<std::shared_ptr<Object>>(&o.v);
    if (!obj || (*obj)->kind == Object::Hash) { fail("no member " + name + " of " + std::string(1, type_of(o))); }
    if ((*obj)->kind == Object::Instance)
    {
      std::string u = upper(name);
      for (auto& [k, v] : (*obj)->props)
      {
        if (k == u)
        {
          v = deref(x);
          return;
        }
      }
      fail("no data " + name + " of " + (*obj)->cls->name);
    }
    for (auto& [k, v] : (*obj)->props)
    {
      if (k == name || ((*obj)->kind == Object::Error && upper(k) == upper(name)))
      {
        v = deref(x);
        return;
      }
    }
    (*obj)->props.push_back({ name, deref(x) });
  }

  std::string VM::key_text(const Value& k0)
  {
    const Value& k = deref(k0);
    char t = type_of(k);
    if (t == 'N' || t == 'C' || t == 'L' || t == 'D') { return std::string(1, t) + text(k); }
    fail(std::string("a hash's key is ") + t);
  }

  // A value as JSON's text, as JsonObject:toJson() writes it.
  std::string VM::json_text(const Value& x0)
  {
    const Value& x = deref(x0);
    switch (type_of(x))
    {
      case 'N': return num_text(std::get<double>(x.v));
      case 'F': return dec_text(std::get<Dec>(x.v));
      case 'L': return std::get<bool>(x.v) ? "true" : "false";
      case 'C':
      {
        std::string out = "\"";
        for (char c : std::get<std::string>(x.v))
        {
          if (c == '"' || c == '\\') { out += '\\'; }
          if (c == '\n') { out += "\\n"; }
          else if (c == '\r') { out += "\\r"; }
          else if (c == '\t') { out += "\\t"; }
          else { out += c; }
        }
        return out + "\"";
      }
      case 'A':
      {
        std::string out = "[";
        for (const Value& y : *std::get<ArrayP>(x.v)) { out += (out.size() > 1 ? "," : "") + json_text(y); }
        return out + "]";
      }
      case 'J':
      {
        std::string out = "{";
        for (const auto& [k, v] : std::get<std::shared_ptr<Object>>(x.v)->props)
        {
          out += (out.size() > 1 ? "," : "") + json_text(S(k)) + ":" + json_text(v);
        }
        return out + "}";
      }
      default: return "null";
    }
  }

  Value VM::method(const Value& o0, const std::string& name, Args& args)
  {
    const Value& o = deref(o0);
    auto obj = std::get_if<std::shared_ptr<Object>>(&o.v);
    std::string m = upper(name);
    if (obj && m == "NEW") { return o; }
    if (obj && (*obj)->kind == Object::Hash)
    {
      auto& h = (*obj)->hash;
      if (m == "SET")
      {
        h[key_text(at(args, 0))] = { at(args, 0), at(args, 1) };
        return L(true);
      }
      if (m == "GET")
      {
        auto it = h.find(key_text(at(args, 0)));
        if (it == h.end()) { return L(false); }
        if (args.size() > 1)
        {
          if (auto r = std::get_if<Ref>(&args[1].v)) { *r->to = it->second.second; }
        }
        return L(true);
      }
      if (m == "DEL") { return L(h.erase(key_text(at(args, 0))) > 0); }
      if (m == "LIST")
      {
        auto list = std::make_shared<Array>();
        for (auto& [k, kv] : h)
        {
          auto pair = std::make_shared<Array>(Array{ kv.first, kv.second });
          list->push_back(A(pair));
        }
        if (!args.empty())
        {
          if (auto r = std::get_if<Ref>(&args[0].v)) { *r->to = A(list); }
        }
        return L(true);
      }
    }
    if (obj && (*obj)->kind == Object::Json)
    {
      if (m == "GETNAMES")
      {
        auto list = std::make_shared<Array>();
        for (auto& [k, v] : (*obj)->props) { list->push_back(S(k)); }
        return A(list);
      }
      if (m == "TOJSON") { return S(json_text(o)); }
      if (m == "GETJSONTEXT" || m == "GETJSONOBJECT")
      {
        std::string k = text(at(args, 0));
        for (auto& p : (*obj)->props)
        {
          if (p.first != k) { continue; }
          if (m == "GETJSONOBJECT") { return type_of(p.second) == 'J' ? p.second : Value(); }
          return S(type_of(p.second) == 'C' ? std::get<std::string>(p.second.v) : json_text(p.second));
        }
        return m == "GETJSONOBJECT" ? Value() : S("null");
      }
      if (m == "HASPROPERTY")
      {
        std::string k = text(at(args, 0));
        for (auto& p : (*obj)->props)
        {
          if (p.first == k) { return L(true); }
        }
        return L(false);
      }
    }
    fail("no method " + name + " of " + std::string(1, type_of(o)));
  }

  // ---- the instructions -----------------------------------------------------
  bool VM::exec(std::size_t base, Value& result)
  {
    for (;;)
    {
      Frame& f = *frames_.back();
      if (f.pc >= f.fn->code.size()) { fail(f.fn->name + " runs past its end"); }
      const Ins& in = f.fn->code[f.pc++];
      std::vector<Value>& st = f.stack;
      auto pop = [&]() -> Value
      {
        if (st.empty()) { fail(f.fn->name + ": the stack is empty"); }
        Value v = std::move(st.back());
        st.pop_back();
        return v;
      };
      auto take = [&](std::size_t n) -> Args
      {
        if (st.size() < n) { fail(f.fn->name + ": the stack is empty"); }
        Args a(st.end() - static_cast<std::ptrdiff_t>(n), st.end());
        st.resize(st.size() - n);
        return a;
      };
      auto local = [&](long n) -> Value& { return f.locals[static_cast<std::size_t>(n - 1)]; };
      auto cell = [&](long n) -> Cell
      {
        auto c = std::get_if<Cell>(&local(n).v);
        if (!c) { fail(f.fn->name + ": local " + std::to_string(n) + " is no cell"); }
        return *c;
      };
      auto upval = [&](long n) -> Cell
      {
        if (!f.closure || n < 1 || n > static_cast<long>(f.closure->cells.size()))
        {
          fail(f.fn->name + ": no cell " + std::to_string(n));
        }
        return f.closure->cells[static_cast<std::size_t>(n - 1)];
      };
      auto statics = [&]() -> std::vector<Value>& { return f.fn->mod->statics; };
      switch (in.op)
      {
        case Op::Nil: st.push_back(Value()); break;
        case Op::True: st.push_back(L(true)); break;
        case Op::False: st.push_back(L(false)); break;
        case Op::Num: st.push_back(N(in.n)); break;
        case Op::Str: st.push_back(S(in.s)); break;
        case Op::Local:
        {
          Value& x = local(in.a);
          if (auto c = std::get_if<Cell>(&x.v)) { st.push_back(**c); }
          else { st.push_back(x); }
          break;
        }
        case Op::SetLocal: local(in.a) = deref(pop()); break;
        case Op::Box:
        {
          Value x;
          x.v = std::make_shared<Value>(local(in.a));
          local(in.a) = x;
          break;
        }
        case Op::CellOp: st.push_back(*cell(in.a)); break;
        case Op::SetCell:
        {
          Cell c = cell(in.a);
          *c = deref(pop());
          break;
        }
        case Op::Upval: st.push_back(*upval(in.a)); break;
        case Op::SetUpval:
        {
          Cell c = upval(in.a);
          *c = deref(pop());
          break;
        }
        case Op::Static: st.push_back(statics()[static_cast<std::size_t>(in.a - 1)]); break;
        case Op::SetStatic: statics()[static_cast<std::size_t>(in.a - 1)] = deref(pop()); break;
        case Op::Memvar:
        {
          Cell* c = memvar(in.s);
          if (!c) { fail("variable does not exist: " + in.s); }
          st.push_back(**c);
          break;
        }
        case Op::SetMemvar:
        {
          Value x = deref(pop());
          Cell* c = memvar(in.s);
          if (c) { **c = x; }
          else { *private_var(in.s) = x; }
          break;
        }
        case Op::Private: private_var(in.s); break;
        case Op::Public:
          if (!publics_.count(in.s)) { publics_[in.s] = std::make_shared<Value>(); }
          break;
        case Op::Field:
        case Op::SetField:
          fail("xc-vm has no fields: " + in.s + "->" + in.s2);
        case Op::FieldX:
        case Op::SetFieldX:
          fail("xc-vm has no fields: " + in.s);
        case Op::RefLocal:
        {
          Value r;
          r.v = Ref{ &local(in.a), nullptr };
          st.push_back(r);
          break;
        }
        case Op::RefCell:
        {
          Cell c = cell(in.a);
          Value r;
          r.v = Ref{ c.get(), c };
          st.push_back(r);
          break;
        }
        case Op::RefUpval:
        {
          Cell c = upval(in.a);
          Value r;
          r.v = Ref{ c.get(), c };
          st.push_back(r);
          break;
        }
        case Op::RefStatic:
        {
          Value r;
          r.v = Ref{ &statics()[static_cast<std::size_t>(in.a - 1)], nullptr };
          st.push_back(r);
          break;
        }
        case Op::RefMemvar:
        {
          Cell* c = memvar(in.s);
          Cell v = c ? *c : private_var(in.s);
          Value r;
          r.v = Ref{ v.get(), v };
          st.push_back(r);
          break;
        }
        case Op::Pop: pop(); break;
        case Op::Dup:
        {
          Value x = pop();
          st.push_back(x);
          st.push_back(x);
          break;
        }
        case Op::Dup2:
        {
          Args a = take(2);
          st.push_back(a[0]);
          st.push_back(a[1]);
          st.push_back(a[0]);
          st.push_back(a[1]);
          break;
        }
        case Op::ArrayOp:
        {
          Args a = take(static_cast<std::size_t>(in.a));
          for (Value& x : a) { x = deref(x); }
          st.push_back(A(std::make_shared<Array>(std::move(a))));
          break;
        }
        case Op::Index:
        {
          Args a = take(2);
          st.push_back(index(a[0], a[1]));
          break;
        }
        case Op::SetIndex:
        {
          Args a = take(3);
          set_index(a[0], a[1], a[2]);
          break;
        }
        case Op::Member:
        {
          Value o = pop();
          st.push_back(member(o, in.s));
          break;
        }
        case Op::SetMember:
        {
          Args a = take(2);
          set_member(a[0], in.s, a[1]);
          break;
        }
        case Op::Self: st.push_back(f.self); break;
        case Op::Add: case Op::Sub: case Op::Mul: case Op::Div: case Op::Mod: case Op::Pow:
        {
          Args a = take(2);
          st.push_back(arith(in.op, a[0], a[1]));
          break;
        }
        case Op::Neg:
        {
          Value x = deref(pop());
          if (auto fd = std::get_if<Dec>(&x.v))
          {
            Value r;
            r.v = dec_neg(*fd);
            st.push_back(r);
            break;
          }
          auto d = std::get_if<double>(&x.v);
          if (!d) { fail(std::string("type mismatch on -: ") + type_of(x)); }
          st.push_back(N(-*d));
          break;
        }
        case Op::Not: st.push_back(L(!logical(pop(), "!"))); break;
        case Op::Eq: case Op::Exact: case Op::Ne:
        {
          Args a = take(2);
          bool e = equal(a[0], a[1], in.op == Op::Exact, in.op == Op::Exact ? "==" : in.op == Op::Eq ? "=" : "!=");
          st.push_back(L(in.op == Op::Ne ? !e : e));
          break;
        }
        case Op::Lt: case Op::Gt: case Op::Le: case Op::Ge:
        {
          Args a = take(2);
          const char* sign = in.op == Op::Lt ? "<" : in.op == Op::Gt ? ">" : in.op == Op::Le ? "<=" : ">=";
          int c = order(a[0], a[1], sign);
          bool r = in.op == Op::Lt ? c < 0 : in.op == Op::Gt ? c > 0 : in.op == Op::Le ? c <= 0 : c >= 0;
          st.push_back(L(r));
          break;
        }
        case Op::Contains:
        {
          Args a = take(2);
          const Value& x = deref(a[0]);
          const Value& y = deref(a[1]);
          if (type_of(x) != 'C' || type_of(y) != 'C')
          {
            fail(std::string("type mismatch on $: ") + type_of(x) + " and " + type_of(y));
          }
          st.push_back(L(std::get<std::string>(y.v).find(std::get<std::string>(x.v)) != std::string::npos));
          break;
        }
        case Op::IsNil: st.push_back(L(is_nil(deref(pop())))); break;
        case Op::Jump: f.pc = static_cast<std::size_t>(in.a - 1); break;
        case Op::JumpF:
          if (!logical(pop(), "a condition")) { f.pc = static_cast<std::size_t>(in.a - 1); }
          break;
        case Op::JumpT:
          if (logical(pop(), "a condition")) { f.pc = static_cast<std::size_t>(in.a - 1); }
          break;
        case Op::AndJump:
        case Op::OrJump:
        {
          if (st.empty()) { fail(f.fn->name + ": the stack is empty"); }
          bool l = logical(st.back(), in.op == Op::AndJump ? ".And." : ".Or.");
          if (l == (in.op == Op::OrJump)) { f.pc = static_cast<std::size_t>(in.a - 1); }
          else { st.pop_back(); }
          break;
        }
        case Op::Call:
        {
          Args a = take(static_cast<std::size_t>(in.a));
          invoke(f.fn->mod, in.s, a);
          break;
        }
        case Op::CallX:
        {
          Args a = take(static_cast<std::size_t>(in.a));
          Value name = deref(pop());
          if (type_of(name) != 'C') { fail("&name.(): the name is no string"); }
          invoke(f.fn->mod, std::get<std::string>(name.v), a, true);
          break;
        }
        case Op::Method:
        {
          Args a = take(static_cast<std::size_t>(in.a));
          Value o = deref(pop());
          if (auto obj = std::get_if<std::shared_ptr<Object>>(&o.v); obj && (*obj)->kind == Object::Instance)
          {
            const Function* fn = method_of((*obj)->cls, upper(in.s));
            if (!fn) { fail("no method " + in.s + " of " + (*obj)->cls->name); }
            push_frame(fn, a, nullptr, o);
            break;
          }
          Value r = method(o, in.s, a);
          frames_.back()->stack.push_back(std::move(r));
          break;
        }
        case Op::Super:
        {
          // The method of a class above the one the running method is of.
          Args a = take(static_cast<std::size_t>(in.a));
          std::string fn = upper(f.fn->name);
          fn = fn.substr(0, fn.find('#'));
          std::size_t colon = fn.find(':');
          auto c = colon == std::string::npos ? classes_.end() : classes_.find(fn.substr(0, colon));
          if (c == classes_.end()) { fail("_Super outside a method"); }
          const Function* m = nullptr;
          for (const std::string& sup : c->second->supers)
          {
            const Class* up = class_named(c->second->mod, sup);
            if (!m && up) { m = method_of(up, upper(in.s)); }
          }
          if (m)
          {
            Value self = f.self;
            push_frame(m, a, nullptr, self);
            break;
          }
          // A class above that is the AppServer's: its constructor is Self.
          if (upper(in.s) != "NEW") { fail("no method " + in.s + " above " + c->second->name); }
          st.push_back(f.self);
          break;
        }
        case Op::New:
        {
          // 'Name():M(...)': an object of the class, M run on it; the object
          // is what the caller gets, whatever M returns.
          Args a = take(static_cast<std::size_t>(in.a));
          std::string cls = upper(in.s);
          if (const Class* c = class_named(f.fn->mod, cls))
          {
            // A static method is called, no object made: the caller gets
            // what it returns (tried on 24.3.1.9).
            bool is_static = false;
            const Function* m = method_of(c, upper(in.s2), &is_static);
            if (!m) { fail("Cannot find method " + c->name + ":" + upper(in.s2)); }
            if (is_static)
            {
              push_frame(m, a, nullptr, Value());
              break;
            }
            Value o = instance(c);
            push_frame(m, a, nullptr, o);
            frames_.back()->constructs = true;
            break;
          }
          // One of the AppServer's: its object, and what the method gives.
          auto it = natives_.find(cls);
          if (it == natives_.end()) { fail("invalid class " + cls); }
          Args none;
          Value o = it->second(none);
          st.push_back(method(o, in.s2, a));
          break;
        }
        case Op::Ret:
        {
          Value v = deref(pop());
          if (f.constructs) { v = f.self; }
          end_frame(f);
          bool last = frames_.size() - 1 == base;
          frames_.pop_back();
          if (last)
          {
            result = std::move(v);
            return true;
          }
          frames_.back()->stack.push_back(std::move(v));
          break;
        }
        case Op::Block:
        {
          auto it = f.fn->mod->by_name.find(upper(in.s));
          if (it == f.fn->mod->by_name.end() || it->second->kind != "block") { fail("no block function " + in.s); }
          Args cells = take(static_cast<std::size_t>(in.b));
          auto c = std::make_shared<Closure>();
          c->fn = it->second;
          c->self = f.self;
          for (const Value& x : cells)
          {
            auto r = std::get_if<Ref>(&x.v);
            if (!r || !r->keep) { fail("a block's cell is no cell"); }
            c->cells.push_back(r->keep);
          }
          Value b;
          b.v = c;
          st.push_back(b);
          break;
        }
        case Op::Macro:
        case Op::SetMacro:
        {
          Value x;
          if (in.op == Op::SetMacro) { x = deref(pop()); }
          Value t = deref(pop());
          std::string name = upper(text(t));
          std::size_t b = name.find_first_not_of(' ');
          std::size_t e = name.find_last_not_of(' ');
          name = b == std::string::npos ? "" : name.substr(b, e - b + 1);
          bool plain = !name.empty() && name.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") == std::string::npos
                       && !(name[0] >= '0' && name[0] <= '9');
          if (!plain) { fail("xc-vm runs no macro but a variable's name: &(" + text(t) + ")"); }
          Cell* c = memvar(name);
          if (in.op == Op::SetMacro)
          {
            if (c) { **c = x; }
            else { *private_var(name) = x; }
            break;
          }
          if (!c) { fail("variable does not exist: " + name); }
          st.push_back(**c);
          break;
        }
        case Op::Line: f.line = in.a; break;
        case Op::Seq:
        case Op::Try:
          f.regions.push_back(Frame::Region{ in.op == Op::Try, static_cast<std::size_t>(in.a - 1), st.size(),
                                             f.areas.size() });
          break;
        case Op::EndSeq:
          if (f.regions.empty()) { fail(f.fn->name + ": 'endseq' with no region"); }
          f.regions.pop_back();
          break;
        case Op::Defer:
          f.defers.emplace(in.a, static_cast<std::size_t>(in.b - 1));
          break;
        case Op::RunDefers:
          if (!f.defers.empty())
          {
            auto last = std::prev(f.defers.end());
            f.defer_back = f.pc - 1;
            f.pc = last->second;
            f.defers.erase(last);
          }
          break;
        case Op::EndDefer: f.pc = f.defer_back; break;
        case Op::Area:
        {
          Args a = take(1);
          f.areas.push_back(area_);
          natives_["DBSELECTAREA"](a);
          break;
        }
        case Op::EndArea:
          if (f.areas.empty()) { fail(f.fn->name + ": 'endarea' with no area"); }
          area_ = f.areas.back();
          f.areas.pop_back();
          break;
      }
    }
  }

  // ---- the AppServer's ------------------------------------------------------
  double VM::num_arg(const Args& a, std::size_t i, const char* fn)
  {
    if (auto d = std::get_if<double>(&at(a, i).v)) { return *d; }
    fail(std::string(fn) + ": argument " + std::to_string(i + 1) + " is no number");
  }

  std::string VM::str_arg(const Args& a, std::size_t i, const char* fn)
  {
    if (auto s = std::get_if<std::string>(&at(a, i).v)) { return *s; }
    fail(std::string(fn) + ": argument " + std::to_string(i + 1) + " is no string");
  }

  ArrayP VM::array_arg(const Args& a, std::size_t i, const char* fn)
  {
    if (auto x = std::get_if<ArrayP>(&at(a, i).v)) { return *x; }
    fail(std::string(fn) + ": argument " + std::to_string(i + 1) + " is no array");
  }

  void VM::natives()
  {
    auto& n = natives_;
    auto opt_num = [this](const Args& a, std::size_t i, double d, const char* fn)
    {
      return is_nil(at(a, i)) ? d : num_arg(a, i, fn);
    };
    auto new_object = [](Object::Kind k)
    {
      auto o = std::make_shared<Object>();
      o->kind = k;
      Value x;
      x.v = o;
      return x;
    };

    // Output, types.
    n["CONOUT"] = [](Args& a)
    {
      for (const Value& x : a) { std::cout << text(x) << "\n"; }
      return Value();
    };
    n["QOUT"] = n["CONOUT"];
    n["CVALTOCHAR"] = [](Args& a) { return S(text(at(a, 0))); };
    n["VALTYPE"] = [](Args& a) { return S(std::string(1, type_of(at(a, 0)))); };
    n["EMPTY"] = [this](Args& a)
    {
      const Value& x = at(a, 0);
      switch (type_of(x))
      {
        case 'U': return L(true);
        case 'N': return L(std::get<double>(x.v) == 0);
        case 'C': return L(std::get<std::string>(x.v).find_first_not_of(" \t\r\n") == std::string::npos);
        case 'L': return L(!std::get<bool>(x.v));
        case 'D': return L(std::get<Date>(x.v).day == EMPTY_DAY);
        case 'A': return L(std::get<ArrayP>(x.v)->empty());
        case 'F': fail("Empty: unknown variable type");
        default: return L(false);
      }
    };
    n["LEN"] = [this](Args& a)
    {
      const Value& x = at(a, 0);
      if (auto s = std::get_if<std::string>(&x.v)) { return N(static_cast<double>(s->size())); }
      if (auto arr = std::get_if<ArrayP>(&x.v)) { return N(static_cast<double>((*arr)->size())); }
      if (type_of(x) == 'J') { return N(static_cast<double>(std::get<std::shared_ptr<Object>>(x.v)->props.size())); }
      fail(std::string("Len: argument is ") + type_of(x));
    };

    // Code blocks, errors.
    n["EVAL"] = [this](Args& a)
    {
      Args rest(a.size() > 1 ? a.begin() + 1 : a.end(), a.end());
      return call_value(at(a, 0), rest);
    };
    n["BREAK"] = [](Args& a) -> Value { throw Unwind{ at(a, 0), false }; };
    n["ERRORBLOCK"] = [this](Args& a)
    {
      Value old = error_block_;
      if (!a.empty()) { error_block_ = at(a, 0); }
      return old;
    };
    n["PCOUNT"] = [this](Args&) { return N(static_cast<double>(frames_.back()->argc)); };

    // Arrays.
    n["ARRAY"] = [this](Args& a)
    {
      std::function<Value(std::size_t)> make = [&](std::size_t d) -> Value
      {
        if (d >= a.size()) { return Value(); }
        auto arr = std::make_shared<Array>();
        long k = static_cast<long>(num_arg(a, d, "Array"));
        for (long i = 0; i < k; i++) { arr->push_back(make(d + 1)); }
        return A(arr);
      };
      return make(0);
    };
    n["AADD"] = [this](Args& a)
    {
      array_arg(a, 0, "AAdd")->push_back(at(a, 1));
      return at(a, 1);
    };
    n["ASIZE"] = [this](Args& a)
    {
      ArrayP arr = array_arg(a, 0, "aSize");
      arr->resize(static_cast<std::size_t>(std::max(0.0, num_arg(a, 1, "aSize"))));
      return A(arr);
    };
    n["ADEL"] = [this](Args& a)
    {
      ArrayP arr = array_arg(a, 0, "aDel");
      std::size_t k = static_cast<std::size_t>(num_arg(a, 1, "aDel"));
      if (k >= 1 && k <= arr->size())
      {
        arr->erase(arr->begin() + static_cast<std::ptrdiff_t>(k - 1));
        arr->push_back(Value());
      }
      return A(arr);
    };
    n["AINS"] = [this](Args& a)
    {
      ArrayP arr = array_arg(a, 0, "aIns");
      std::size_t k = static_cast<std::size_t>(num_arg(a, 1, "aIns"));
      if (k >= 1 && k <= arr->size())
      {
        arr->insert(arr->begin() + static_cast<std::ptrdiff_t>(k - 1), Value());
        arr->pop_back();
      }
      return A(arr);
    };
    n["ATAIL"] = [this](Args& a)
    {
      ArrayP arr = array_arg(a, 0, "aTail");
      return arr->empty() ? Value() : arr->back();
    };
    n["ACLONE"] = [this](Args& a)
    {
      std::function<Value(const Value&)> clone = [&](const Value& x) -> Value
      {
        if (auto arr = std::get_if<ArrayP>(&x.v))
        {
          auto c = std::make_shared<Array>();
          for (const Value& y : **arr) { c->push_back(clone(y)); }
          return A(c);
        }
        return x;
      };
      return clone(A(array_arg(a, 0, "aClone")));
    };
    n["ASCAN"] = [this](Args& a)
    {
      ArrayP arr = array_arg(a, 0, "aScan");
      const Value& x = at(a, 1);
      std::size_t from = static_cast<std::size_t>(is_nil(at(a, 2)) ? 1 : num_arg(a, 2, "aScan"));
      for (std::size_t i = from; i <= arr->size(); i++)
      {
        const Value& y = (*arr)[i - 1];
        if (type_of(x) == 'B')
        {
          if (evals_true(x, { y }, "aScan")) { return N(static_cast<double>(i)); }
        }
        else if (type_of(x) == type_of(y) && equal(y, x, false, "aScan"))
        {
          return N(static_cast<double>(i));
        }
      }
      return N(0);
    };
    n["ASORT"] = [this](Args& a)
    {
      ArrayP arr = array_arg(a, 0, "aSort");
      const Value& b = at(a, 3);
      if (type_of(b) == 'B')
      {
        std::stable_sort(arr->begin(), arr->end(), [&](const Value& x, const Value& y)
        {
          return evals_true(b, { x, y }, "aSort");
        });
      }
      else
      {
        std::stable_sort(arr->begin(), arr->end(), [&](const Value& x, const Value& y)
        {
          if (type_of(x) != type_of(y)) { return type_of(x) < type_of(y); }
          return order(x, y, "aSort") < 0;
        });
      }
      return A(arr);
    };
    n["AEVAL"] = [this](Args& a)
    {
      ArrayP arr = array_arg(a, 0, "aEval");
      for (std::size_t i = 0; i < arr->size(); i++) { call_value(at(a, 1), { (*arr)[i], N(static_cast<double>(i + 1)) }); }
      return A(arr);
    };

    // Strings.
    n["UPPER"] = [this](Args& a) { return S(upper(str_arg(a, 0, "Upper"))); };
    n["LOWER"] = [this](Args& a) { return S(lower(str_arg(a, 0, "Lower"))); };
    auto trim = [](const std::string& s, bool left, bool right)
    {
      std::size_t b = left ? s.find_first_not_of(' ') : 0;
      if (b == std::string::npos) { return std::string(); }
      std::size_t e = right ? s.find_last_not_of(' ') : s.size() - 1;
      return s.substr(b, e - b + 1);
    };
    n["ALLTRIM"] = [this, trim](Args& a) { return S(trim(str_arg(a, 0, "AllTrim"), true, true)); };
    n["LTRIM"] = [this, trim](Args& a) { return S(trim(str_arg(a, 0, "LTrim"), true, false)); };
    n["RTRIM"] = [this, trim](Args& a) { return S(trim(str_arg(a, 0, "RTrim"), false, true)); };
    n["TRIM"] = n["RTRIM"];
    n["SUBSTR"] = [this, opt_num](Args& a)
    {
      std::string s = str_arg(a, 0, "SubStr");
      long len = static_cast<long>(s.size());
      long from = static_cast<long>(num_arg(a, 1, "SubStr"));
      if (from < 0) { from = std::max(1L, len + from + 1); }
      if (from == 0) { from = 1; }
      if (from > len) { return S(""); }
      long count = static_cast<long>(opt_num(a, 2, static_cast<double>(len), "SubStr"));
      if (count <= 0) { return S(""); }
      return S(s.substr(static_cast<std::size_t>(from - 1), static_cast<std::size_t>(count)));
    };
    n["LEFT"] = [this](Args& a)
    {
      std::string s = str_arg(a, 0, "Left");
      return S(s.substr(0, static_cast<std::size_t>(std::max(0.0, num_arg(a, 1, "Left")))));
    };
    n["RIGHT"] = [this](Args& a)
    {
      std::string s = str_arg(a, 0, "Right");
      std::size_t k = std::min(s.size(), static_cast<std::size_t>(std::max(0.0, num_arg(a, 1, "Right"))));
      return S(s.substr(s.size() - k));
    };
    n["AT"] = [this, opt_num](Args& a)
    {
      std::string sub = str_arg(a, 0, "At");
      std::string s = str_arg(a, 1, "At");
      std::size_t from = static_cast<std::size_t>(std::max(1.0, opt_num(a, 2, 1, "At")));
      if (sub.empty() || from > s.size()) { return N(0); }
      std::size_t p = s.find(sub, from - 1);
      return N(p == std::string::npos ? 0 : static_cast<double>(p + 1));
    };
    n["RAT"] = [this](Args& a)
    {
      std::string sub = str_arg(a, 0, "Rat");
      std::string s = str_arg(a, 1, "Rat");
      std::size_t p = sub.empty() ? std::string::npos : s.rfind(sub);
      return N(p == std::string::npos ? 0 : static_cast<double>(p + 1));
    };
    n["STRTRAN"] = [this](Args& a)
    {
      std::string s = str_arg(a, 0, "StrTran");
      std::string from = str_arg(a, 1, "StrTran");
      std::string to = is_nil(at(a, 2)) ? "" : str_arg(a, 2, "StrTran");
      if (from.empty()) { return S(s); }
      std::string out;
      std::size_t i = 0;
      for (std::size_t p; (p = s.find(from, i)) != std::string::npos; i = p + from.size()) { out += s.substr(i, p - i) + to; }
      return S(out + s.substr(i));
    };
    n["REPLICATE"] = [this](Args& a)
    {
      std::string s = str_arg(a, 0, "Replicate");
      std::string out;
      for (long i = 0; i < static_cast<long>(num_arg(a, 1, "Replicate")); i++) { out += s; }
      return S(out);
    };
    n["SPACE"] = [this](Args& a) { return S(std::string(static_cast<std::size_t>(std::max(0.0, num_arg(a, 0, "Space"))), ' ')); };
    auto pad = [this](Args& a, int where, const char* fn)
    {
      std::string s = text(at(a, 0));
      std::size_t w = static_cast<std::size_t>(std::max(0.0, num_arg(a, 1, fn)));
      char c = is_nil(at(a, 2)) ? ' ' : (str_arg(a, 2, fn) + " ")[0];
      if (s.size() >= w) { return S(s.substr(0, w)); }
      std::size_t fill = w - s.size();
      std::size_t left = where == 0 ? 0 : where == 2 ? fill : fill / 2;
      return S(std::string(left, c) + s + std::string(fill - left, c));
    };
    n["PADR"] = [pad](Args& a) { return pad(a, 0, "PadR"); };
    n["PADC"] = [pad](Args& a) { return pad(a, 1, "PadC"); };
    n["PADL"] = [pad](Args& a) { return pad(a, 2, "PadL"); };
    n["VAL"] = [this](Args& a) { return N(std::strtod(str_arg(a, 0, "Val").c_str(), nullptr)); };
    n["STR"] = [this, opt_num](Args& a)
    {
      double d = num_arg(a, 0, "Str");
      int w = static_cast<int>(opt_num(a, 1, 10, "Str"));
      int dec = static_cast<int>(opt_num(a, 2, 0, "Str"));
      char b[128];
      std::snprintf(b, sizeof b, "%*.*f", w, dec, d);
      std::string s = b;
      return S(static_cast<int>(s.size()) > w ? std::string(static_cast<std::size_t>(w), '*') : s);
    };
    n["STRZERO"] = [this, opt_num](Args& a)
    {
      double d = num_arg(a, 0, "StrZero");
      int w = static_cast<int>(num_arg(a, 1, "StrZero"));
      int dec = static_cast<int>(opt_num(a, 2, 0, "StrZero"));
      char b[128];
      std::snprintf(b, sizeof b, "%0*.*f", w, dec, d);
      return S(b);
    };
    n["CHR"] = [this](Args& a) { return S(std::string(1, static_cast<char>(static_cast<int>(num_arg(a, 0, "Chr"))))); };
    n["ASC"] = [this](Args& a)
    {
      std::string s = str_arg(a, 0, "Asc");
      return N(s.empty() ? 0 : static_cast<double>(static_cast<unsigned char>(s[0])));
    };

    auto first_is = [this](Args& a, int (*test)(int), const char* fn)
    {
      std::string t = str_arg(a, 0, fn);
      return L(!t.empty() && test(static_cast<unsigned char>(t[0])) != 0);
    };
    n["ISDIGIT"] = [first_is](Args& a) { return first_is(a, [](int c) { return c >= '0' && c <= '9' ? 1 : 0; }, "IsDigit"); };
    n["ISALPHA"] = [first_is](Args& a)
    {
      return first_is(a, [](int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ? 1 : 0; }, "IsAlpha");
    };
    n["ISUPPER"] = [first_is](Args& a) { return first_is(a, [](int c) { return c >= 'A' && c <= 'Z' ? 1 : 0; }, "IsUpper"); };
    n["ISLOWER"] = [first_is](Args& a) { return first_is(a, [](int c) { return c >= 'a' && c <= 'z' ? 1 : 0; }, "IsLower"); };

    // Numbers.
    n["INT"] = [this](Args& a) { return N(std::trunc(num_arg(a, 0, "Int"))); };
    n["ROUND"] = [this](Args& a)
    {
      double p = std::pow(10.0, num_arg(a, 1, "Round"));
      double x = num_arg(a, 0, "Round") * p;
      return N(std::round(x + (x >= 0 ? 1e-9 : -1e-9)) / p);
    };
    n["ABS"] = [this](Args& a) { return N(std::fabs(num_arg(a, 0, "Abs"))); };
    n["MAX"] = [this](Args& a) { return order(at(a, 0), at(a, 1), "Max") >= 0 ? at(a, 0) : at(a, 1); };
    n["MIN"] = [this](Args& a) { return order(at(a, 0), at(a, 1), "Min") <= 0 ? at(a, 0) : at(a, 1); };
    n["MOD"] = [this](Args& a)
    {
      double x = num_arg(a, 0, "Mod");
      double y = num_arg(a, 1, "Mod");
      if (y == 0) { fail("zero division"); }
      double r = std::fmod(x, y);
      return N(r != 0 && ((r < 0) != (y < 0)) ? r + y : r);
    };
    n["SQRT"] = [this](Args& a) { return N(std::sqrt(num_arg(a, 0, "Sqrt"))); };
    n["RANDOM"] = [this](Args& a)
    {
      long lo = static_cast<long>(num_arg(a, 0, "Random"));
      long hi = static_cast<long>(num_arg(a, 1, "Random"));
      if (hi < lo) { std::swap(lo, hi); }
      return N(static_cast<double>(std::uniform_int_distribution<long>(lo, hi)(random_)));
    };
    n["RANDOMIZE"] = n["RANDOM"];

    // Dates.
    n["DTOS"] = [this](Args& a)
    {
      auto d = std::get_if<Date>(&at(a, 0).v);
      if (!d) { fail("DtoS: argument is no date"); }
      return S(dtos(*d));
    };
    n["STOD"] = [this](Args& a)
    {
      Value x;
      x.v = date_of(str_arg(a, 0, "StoD"));
      return x;
    };

    // Work areas: names, and no records.
    n["SELECT"] = [this](Args& a)
    {
      if (a.empty()) { return N(static_cast<double>(area_)); }
      std::string al = upper(str_arg(a, 0, "Select"));
      for (std::size_t i = 1; i < areas_.size(); i++)
      {
        if (areas_[i] == al) { return N(static_cast<double>(i)); }
      }
      return N(0);
    };
    n["ALIAS"] = [this](Args& a)
    {
      std::size_t k = a.empty() ? area_ : static_cast<std::size_t>(num_arg(a, 0, "Alias"));
      return S(k < areas_.size() ? areas_[k] : "");
    };
    n["DBSELECTAREA"] = [this](Args& a)
    {
      const Value& x = at(a, 0);
      if (auto d = std::get_if<double>(&x.v))
      {
        std::size_t k = static_cast<std::size_t>(*d);
        area_ = k < areas_.size() ? k : 0;
        return Value();
      }
      std::string al = upper(str_arg(a, 0, "DbSelectArea"));
      for (std::size_t i = 1; i < areas_.size(); i++)
      {
        if (areas_[i] == al)
        {
          area_ = i;
          return Value();
        }
      }
      areas_.push_back(al);
      area_ = areas_.size() - 1;
      return Value();
    };
    n["RECNO"] = [](Args&) { return N(1); };
    n["INDEXORD"] = [](Args&) { return N(1); };
    n["EOF"] = [](Args&) { return L(true); };
    n["BOF"] = [](Args&) { return L(true); };
    for (const char* f : { "DBSETORDER", "DBGOTO", "DBGOTOP", "DBSKIP", "BEGINTRAN", "ENDTRAN" })
    {
      n[f] = [](Args&) { return Value(); };
    }

    // Decimals: the DEC_ functions TL++ has (probes xdf, xdg, on 24.3.1.9);
    // DEC_DIV and DEC_POW give 120 decimals, as there.
    auto dec_arg = [this](const Args& a, std::size_t i, const char* fn) -> Dec
    {
      if (auto d = std::get_if<Dec>(&at(a, i).v)) { return *d; }
      fail(std::string(fn) + ": argument " + std::to_string(i + 1) + " is no Decimal");
    };
    auto decimal = [](Dec d)
    {
      Value x;
      x.v = std::move(d);
      return x;
    };
    n["DEC_CREATE"] = [this, decimal](Args& a)
    {
      const Value& x = at(a, 0);
      std::string t = type_of(x) == 'N' ? num_text(std::get<double>(x.v)) : type_of(x) == 'F' ? text(x) : str_arg(a, 0, "DEC_CREATE");
      int precision = static_cast<int>(num_arg(a, 1, "DEC_CREATE"));
      int scale = static_cast<int>(num_arg(a, 2, "DEC_CREATE"));
      if (precision < 1 || precision > 64 || scale < 0 || scale > precision) { fail("DEC_CREATE: precision or scale out of range"); }
      Dec d;
      if (!dec_parse(t, d)) { fail("DEC_CREATE: '" + t + "' is no number"); }
      d = dec_rescale(d, scale, 2);
      if (static_cast<int>(d.digits.size()) > precision) { fail("Decimal number overflow"); }
      return decimal(d);
    };
    n["DEC_ADD"] = [dec_arg, decimal](Args& a) { return decimal(dec_add(dec_arg(a, 0, "DEC_ADD"), dec_arg(a, 1, "DEC_ADD"))); };
    n["DEC_SUB"] = [dec_arg, decimal](Args& a)
    {
      return decimal(dec_add(dec_arg(a, 0, "DEC_SUB"), dec_neg(dec_arg(a, 1, "DEC_SUB"))));
    };
    n["DEC_MUL"] = [dec_arg, decimal](Args& a) { return decimal(dec_mul(dec_arg(a, 0, "DEC_MUL"), dec_arg(a, 1, "DEC_MUL"))); };
    n["DEC_DIV"] = [this, dec_arg, decimal](Args& a)
    {
      Dec b = dec_arg(a, 1, "DEC_DIV");
      if (b.digits == "0") { fail("zero division"); }
      return decimal(dec_div(dec_arg(a, 0, "DEC_DIV"), b, 120));
    };
    n["DEC_MOD"] = [this, dec_arg, decimal](Args& a)
    {
      Dec b = dec_arg(a, 1, "DEC_MOD");
      if (b.digits == "0") { fail("zero division"); }
      return decimal(dec_mod(dec_arg(a, 0, "DEC_MOD"), b));
    };
    n["DEC_POW"] = [this, dec_arg, decimal](Args& a)
    {
      // A whole exponent multiplies; any other goes by the numbers.
      Dec x = dec_arg(a, 0, "DEC_POW");
      Dec e = dec_arg(a, 1, "DEC_POW");
      Dec whole = dec_rescale(e, 0, 2);
      if (dec_cmp(whole, e) == 0 && whole.digits.size() < 6)
      {
        long k = std::stol(whole.digits);
        Dec r{ false, "1", 0 };
        for (long i = 0; i < k; i++) { r = dec_mul(r, x); }
        if (whole.neg)
        {
          if (r.digits == "0") { fail("zero division"); }
          r = dec_div(Dec{ false, "1", 0 }, r, 120);
        }
        return decimal(dec_align(r, 120));
      }
      Dec r;
      dec_parse(num_text(std::pow(std::strtod(dec_text(x).c_str(), nullptr), std::strtod(dec_text(e).c_str(), nullptr))), r);
      return decimal(dec_align(r, 120));
    };
    n["DEC_RESCALE"] = [this, dec_arg, decimal](Args& a)
    {
      int mode = is_nil(at(a, 2)) ? 0 : static_cast<int>(num_arg(a, 2, "DEC_RESCALE"));
      return decimal(dec_rescale(dec_arg(a, 0, "DEC_RESCALE"), static_cast<int>(num_arg(a, 1, "DEC_RESCALE")), mode));
    };
    n["DEC_ROUND"] = [this, dec_arg, decimal](Args& a)
    {
      // Rounded, and as many decimals as it had: DEC_ROUND(1.25, 1) is 1.30.
      Dec d = dec_arg(a, 0, "DEC_ROUND");
      return decimal(dec_align(dec_rescale(d, static_cast<int>(num_arg(a, 1, "DEC_ROUND")), 0), d.scale));
    };
    n["DEC_TO_DBL"] = [dec_arg](Args& a) { return N(std::strtod(dec_text(dec_arg(a, 0, "DEC_TO_DBL")).c_str(), nullptr)); };

    // Files: File(), and the FT_ functions' text file, line by line.
    n["FILE"] = [this](Args& a)
    {
      std::ifstream f(str_arg(a, 0, "File"), std::ios::binary);
      return L(static_cast<bool>(f));
    };
    n["FT_FUSE"] = [this](Args& a)
    {
      ft_lines_.clear();
      ft_at_ = 0;
      if (is_nil(at(a, 0))) { return N(0); }
      std::ifstream f(str_arg(a, 0, "FT_FUse"), std::ios::binary);
      if (!f) { return N(-1); }
      std::string l;
      while (std::getline(f, l))
      {
        if (!l.empty() && l.back() == '\r') { l.pop_back(); }
        ft_lines_.push_back(l);
      }
      return N(1);
    };
    n["FT_FGOTOP"] = [this](Args&)
    {
      ft_at_ = 0;
      return Value();
    };
    n["FT_FEOF"] = [this](Args&) { return L(ft_at_ >= ft_lines_.size()); };
    n["FT_FREADLN"] = [this](Args&) { return S(ft_at_ < ft_lines_.size() ? ft_lines_[ft_at_] : ""); };
    n["FT_FSKIP"] = [this](Args& a)
    {
      ft_at_ += static_cast<std::size_t>(is_nil(at(a, 0)) ? 1 : num_arg(a, 0, "FT_FSkip"));
      return Value();
    };

    // THashMap and JsonObject: Class():New().
    n["THASHMAP"] = [new_object](Args&) { return new_object(Object::Hash); };
    n["JSONOBJECT"] = [new_object](Args&) { return new_object(Object::Json); };
  }

  // ---- the program's run ----------------------------------------------------
  int VM::start(const std::string& entry)
  {
    auto report = [&](const Unwind& u)
    {
      if (u.error)
      {
        std::cerr << "xc-vm: error: " << text(member(u.v, "Description")) << " (" << where_ << ")\n";
      }
      else
      {
        std::cerr << "xc-vm: a Break with no Begin Sequence to take it\n";
      }
      return 1;
    };
    try
    {
      for (const auto& m : modules_)
      {
        auto it = m->by_name.find("__INIT");
        if (it == m->by_name.end()) { continue; }
        Args none;
        push_frame(it->second, none, nullptr, Value());
        run(frames_.size() - 1);
      }
      const Function* fn = nullptr;
      if (!entry.empty()) { fn = function_named(nullptr, entry); }
      else if (auto g = globals_.find("U_MAIN"); g != globals_.end()) { fn = g->second; }
      else if (!modules_.empty())
      {
        for (const auto& f : modules_.back()->fns)
        {
          if (!fn && f->kind == "user") { fn = f.get(); }
        }
      }
      if (!fn)
      {
        std::cerr << "xc-vm: no function " << (entry.empty() ? "to run" : entry) << "\n";
        return 2;
      }
      Args none;
      push_frame(fn, none, nullptr, Value());
      run(frames_.size() - 1);
    }
    catch (const Unwind& u)
    {
      std::cout.flush();
      return report(u);
    }
    std::cout.flush();
    return 0;
  }
}

int main(int argc, char** argv)
{
  std::vector<std::string> files;
  std::string entry;
  for (int i = 1; i < argc; i++)
  {
    std::string a = argv[i];
    if (a.rfind("--run=", 0) == 0) { entry = a.substr(6); }
    else if (a.rfind("--", 0) == 0)
    {
      std::cerr << "usage: xc-vm [--run=NAME] module.xbc ...\n";
      return 2;
    }
    else { files.push_back(a); }
  }
  if (files.empty())
  {
    std::cerr << "usage: xc-vm [--run=NAME] module.xbc ...\n";
    return 2;
  }
  VM vm;
  try
  {
    for (const std::string& f : files) { vm.load(f); }
  }
  catch (const std::exception& e)
  {
    std::cerr << "xc-vm: " << e.what() << "\n";
    return 2;
  }
  return vm.start(entry);
}
