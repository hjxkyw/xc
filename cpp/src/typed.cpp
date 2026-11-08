// xc -- typed arrays and hashes: what goes into one (see typed.h).

#include "typed.h"

#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>

#include "chars.h"
#include "text.h"
#include "walk.h"

namespace xc
{
  namespace
  {
    bool is(const Expr* e, EK k) { return e && e->kind == k; }

    // ---- types --------------------------------------------------------------
    // As ast.h writes them: 'N', 'C', 'L', 'D', 'A', 'H', 'O', 'B', 'J', 'F',
    // 'A<T>', 'H<K,V>', a set's 'S<K>', a bag's 'M<K>', '!' before a fixed
    // one; an object of a class of the file, 'O:Depot:Stock' -- the class,
    // then those it inherits from there --; and here, NIL (fits every
    // type), UNKNOWN, '!?' -- what xc cannot tell, read from a fixed one, so
    // fixed if it is an array or a hash -- and NONE -- nothing known yet,
    // while the types of the names are worked out.
    const std::string NIL;
    const std::string UNKNOWN = "?";
    const std::string NONE = "_";

    bool fixed(const std::string& t) { return !t.empty() && t[0] == '!'; }
    std::string bare(const std::string& t) { return fixed(t) ? t.substr(1) : t; }
    char kind(const std::string& t) { return fixed(t) ? t[1] : t.empty() ? '\0' : t[0]; }

    bool generic(const std::string& t)
    {
      std::size_t at = fixed(t) ? 1 : 0;
      return t.size() > at + 2 && t[at + 1] == '<';
    }

    // An array, a hash, a set or a bag: what holds others.
    bool box(char k) { return k == 'A' || k == 'H' || k == 'S' || k == 'M'; }
    // A hash, a set or a bag: what is read by its keys.
    bool keyed(char k) { return k == 'H' || k == 'S' || k == 'M'; }

    // An object of a class of the file: 'O:Depot:Stock'.
    bool classed(const std::string& t)
    {
      return t.size() > 2 && t[0] == 'O' && t[1] == ':';
    }

    // A value of a type of the file: 'T:item' -- its name in lower case, as
    // the parser writes it in a typed array's type (and words_ has how the
    // file declares it).
    bool typed_value(const std::string& t)
    {
      return t.size() > 2 && t[0] == 'T' && t[1] == ':';
    }

    // What Self is written as in a type's method's TL++ (emit.cpp).
    const std::string SELF_TLPP = "aSelf";

    // What xc checks goes in: an object of a class, a type's value.
    bool checked_slot(const std::string& t) { return classed(t) || typed_value(t); }

    // The names of the file's types, as declared, by their lower case.
    thread_local const std::unordered_map<std::string, std::string>* type_words = nullptr;

    // The type each of the file's types is from, by their names in lower
    // case: 'order' -> 'item'.
    thread_local const std::unordered_map<std::string, std::string>* type_bases = nullptr;

    // Whether a type's value is one of another type: of the same, or of one
    // that is from it.
    bool type_is(std::string v, const std::string& slot)
    {
      for (int depth = 0; depth < 64 && typed_value(v); depth++)
      {
        if (v == slot) { return true; }
        if (!type_bases) { return false; }
        auto b = type_bases->find(v.substr(2));
        if (b == type_bases->end()) { return false; }
        v = "T:" + b->second;
      }
      return false;
    }

    std::string type_word(const std::string& t)
    {
      std::string k = t.substr(2);
      if (type_words)
      {
        auto it = type_words->find(k);
        if (it != type_words->end()) { return it->second; }
      }
      return k;
    }

    // Its class, and those it inherits from: 'Depot', 'Stock'.
    std::vector<std::string> lineage(const std::string& t)
    {
      std::vector<std::string> out;
      if (!classed(t)) { return out; }
      std::size_t from = 2;
      for (std::size_t i = 2; i <= t.size(); i++)
      {
        if (i == t.size() || t[i] == ':')
        {
          out.push_back(t.substr(from, i - from));
          from = i + 1;
        }
      }
      return out;
    }

    // Whether an object of type t is one of that class -- or of one that
    // inherits from it.
    bool is_a(const std::string& t, const std::string& cls)
    {
      for (const std::string& c : lineage(t))
      {
        if (lc(c) == lc(cls)) { return true; }
      }
      return false;
    }

    // Fixed, if it holds others, or is what xc cannot tell: what is read from
    // a fixed one.
    std::string fix(const std::string& t)
    {
      return fixed(t) || !(box(kind(t)) || t == UNKNOWN) ? t : "!" + t;
    }

    // Nothing fixed in it: what AClone() gives.
    std::string unfixed(const std::string& t)
    {
      std::string out;
      for (char c : t)
      {
        if (c != '!') { out += c; }
      }
      return out;
    }

    // The types between the '<' and the '>' of 'A<T>' or 'H<K,V>'.
    std::vector<std::string> args_of(const std::string& t0)
    {
      std::vector<std::string> out;
      if (!generic(t0)) { return out; }
      std::string t = bare(t0);
      int depth = 0;
      std::size_t from = 2;
      for (std::size_t i = 2; i + 1 < t.size(); i++)
      {
        char c = t[i];
        if (c == '<') { depth++; }
        else if (c == '>') { depth--; }
        else if (c == ',' && depth == 0)
        {
          out.push_back(t.substr(from, i - from));
          from = i + 1;
        }
      }
      out.push_back(t.substr(from, t.size() - 1 - from));
      return out;
    }

    // What an element of an array of type t is; a key, a value of a hash --
    // fixed, read from a fixed one.
    std::string part_of(const std::string& t, char k, std::size_t n)
    {
      if (t == NONE) { return NONE; }
      if (kind(t) != k) { return UNKNOWN; }
      std::string r = generic(t) ? args_of(t).at(n) : UNKNOWN;
      return fixed(t) ? fix(r) : r;
    }
    std::string elem_of(const std::string& t) { return part_of(t, 'A', 0); }
    // A set's or a bag's keys are its one type; what one reads at a key, a
    // Logical and a Numeric.
    std::string key_of(const std::string& t)
    {
      char k = kind(t);
      return k == 'S' || k == 'M' ? part_of(t, k, 0) : part_of(t, 'H', 0);
    }
    std::string value_of(const std::string& t)
    {
      if (t == NONE) { return NONE; }
      if (kind(t) == 'S') { return "L"; }
      if (kind(t) == 'M') { return "N"; }
      return part_of(t, 'H', 1);
    }

    // A set or a bag of what each of two holds -- 'S<K>' or 'M<K>'.
    std::string keys_of(char k, const std::string& a, const std::string& b);

    std::string array_of(const std::string& t)
    {
      if (t == NONE) { return NONE; }
      return t.empty() || bare(t) == UNKNOWN ? "A" : "A<" + t + ">";
    }

    // A type as xtpl writes it: 'Numeric', 'Array<n>', 'Hash<c, Array<n>>',
    // 'Array<fixed n>'.
    std::string show(const std::string& t);

    std::string inner(const std::string& t)
    {
      return generic(t) || fixed(t) || classed(t) || typed_value(t) ? show(t) : lc(t);
    }

    std::string show(const std::string& t)
    {
      std::string f = fixed(t) ? "fixed" : "";
      static const std::unordered_map<char, std::string> boxes =
      {
        { 'A', "Array" }, { 'H', "Hash" }, { 'S', "Set" }, { 'M', "Bag" },
      };
      if (generic(t))
      {
        std::vector<std::string> a = args_of(t);
        std::string pre = f.empty() ? "" : f + " ";
        std::string w = boxes.at(kind(t));
        if (a.size() > 1) { return w + "<" + pre + inner(a[0]) + ", " + inner(a[1]) + ">"; }
        return w + "<" + pre + inner(a[0]) + ">";
      }
      if (!f.empty()) { return box(kind(t)) ? boxes.at(kind(t)) + "<fixed>" : "?"; }
      if (classed(t)) { return lineage(t).front(); }
      if (typed_value(t)) { return type_word(t); }
      static const std::unordered_map<std::string, std::string> names =
      {
        { "N", "Numeric" }, { "C", "Character" }, { "L", "Logical" }, { "D", "Date" }, { "A", "Array" },
        { "H", "Hash" }, { "S", "Set" }, { "M", "Bag" }, { "O", "Object" }, { "B", "CodeBlock" }, { "J", "JSON" },
        { "F", "Decimal" },
      };
      auto n = names.find(t);
      return n != names.end() ? n->second : t;
    }

    // With its article, for an array or a hash: 'an Array<n>', 'Character'.
    std::string shown(const std::string& t)
    {
      if (kind(t) == 'A') { return "an " + show(t); }
      if (keyed(kind(t))) { return "a " + show(t); }
      if (classed(t) || typed_value(t))
      {
        std::string n = show(t);
        return (std::string("aeiouAEIOU").find(n[0]) != std::string::npos ? "an " : "a ") + n;
      }
      return show(t);
    }

    // A type TL++ declares, as its word: 'Numeric' is 'N'.
    std::string letter_of(const std::string& declared)
    {
      static const std::unordered_map<std::string, std::string> letters =
      {
        { "numeric", "N" }, { "integer", "N" }, { "double", "N" }, { "character", "C" }, { "logical", "L" },
        { "date", "D" }, { "array", "A" }, { "object", "O" }, { "codeblock", "B" }, { "json", "J" },
        { "decimal", "F" },
      };
      auto l = letters.find(lc(declared));
      return l != letters.end() ? l->second : UNKNOWN;
    }

    enum class Fit { Ok, Wrong, Unknown };

    // Whether a value of type v goes where slot is wanted. A fixed array or
    // hash goes where a fixed one is, or where nothing is said: anywhere
    // else, it could be written into.
    Fit fits(const std::string& v, const std::string& slot)
    {
      if (slot.empty() || slot == UNKNOWN || v.empty()) { return Fit::Ok; }
      if (typed_value(slot))
      {
        // A type's value is an array: one xc cannot tell is taken for one --
        // what TOTVS' functions give --, an array known to hold this or that
        // is not.
        if (bare(v) == UNKNOWN || v == NONE || bare(v) == "A") { return Fit::Ok; }
        return type_is(bare(v), slot) ? Fit::Ok : Fit::Wrong;
      }
      if (bare(v) == UNKNOWN || v == NONE) { return Fit::Unknown; }
      // And goes where an array does.
      if (typed_value(v)) { return kind(slot) == 'A' && !generic(slot) ? Fit::Ok : Fit::Wrong; }
      char vk = kind(v);
      char sk = kind(slot);
      if (box(vk) && box(sk) && fixed(v) && !fixed(slot)) { return Fit::Wrong; }
      if (bare(v) == bare(slot)) { return Fit::Ok; }
      if (classed(slot))
      {
        // An object of that class, or of one that inherits from it.
        if (vk != 'O') { return Fit::Wrong; }
        if (!classed(v)) { return Fit::Unknown; }
        return is_a(v, lineage(slot).front()) ? Fit::Ok : Fit::Wrong;
      }
      if (sk == 'O' && keyed(vk)) { return Fit::Ok; }          // a THashMap is an object
      if (vk == 'O' && keyed(sk)) { return Fit::Unknown; }     // and an object may be one
      if ((vk == 'S' || vk == 'M') && sk == 'H')
      {
        // A set is a hash of Logicals, a bag one of Numerics.
        if (!generic(slot)) { return Fit::Ok; }
        Fit k = fits(key_of(v), key_of(slot));
        Fit x = fits(value_of(v), value_of(slot));
        return k == Fit::Wrong || x == Fit::Wrong ? Fit::Wrong : k == Fit::Unknown || x == Fit::Unknown ? Fit::Unknown
                                                                                                        : Fit::Ok;
      }
      if (vk != sk) { return Fit::Wrong; }
      if (!generic(slot)) { return Fit::Ok; }                  // an array, whatever it holds
      if (!generic(v)) { return Fit::Unknown; }                // what it holds, not known
      std::vector<std::string> va = args_of(v);
      std::vector<std::string> sa = args_of(slot);
      Fit worst = Fit::Ok;
      for (std::size_t i = 0; i < sa.size(); i++)
      {
        Fit f = fits(fixed(v) ? fix(va[i]) : va[i], sa[i]);
        if (f == Fit::Wrong) { return Fit::Wrong; }
        if (f == Fit::Unknown) { worst = Fit::Unknown; }
      }
      return worst;
    }

    // What a name holds, given two of its values -- fixed, if one is.
    std::string join(const std::string& a, const std::string& b)
    {
      if (a == NONE || a.empty()) { return b; }
      if (b == NONE || b.empty()) { return a; }
      if (a == b) { return a; }
      std::string x = bare(a);
      std::string y = bare(b);
      std::string r = UNKNOWN;
      if (x == y) { r = x; }
      else if (x != UNKNOWN && y != UNKNOWN && x[0] == y[0] && box(x[0]))
      {
        r = std::string(1, x[0]);
      }
      else if (x[0] == 'O' && y[0] == 'O')
      {
        // Two objects: of the nearest class both are of, or just objects.
        r = "O";
        std::vector<std::string> lx = lineage(x);
        for (std::size_t i = 0; i < lx.size() && r == "O"; i++)
        {
          if (!is_a(y, lx[i])) { continue; }
          r = "O";
          for (std::size_t j = i; j < lx.size(); j++) { r += ":" + lx[j]; }
        }
      }
      return fixed(a) || fixed(b) ? fix(r) : r;
    }

    const std::unordered_set<std::string> LOGICAL =
    {
      "==", "=", "!=", "<>", "#", "<", ">", "<=", ">=", "$", ".and.", ".or.", "!", "in", "has", "%%",
      "(elem)", "(cont)", "(<=)", "(<)", "(>=)", "(>)", "(==)",
    };

    // What a set built from t has for keys: an array's elements, a hash's,
    // a set's or a bag's keys, a value itself.
    std::string member_of(const std::string& t)
    {
      if (t == NONE || t.empty()) { return t; }
      char k = kind(t);
      std::string m = k == 'A' ? elem_of(t) : keyed(k) ? key_of(t) : bare(t);
      return bare(m);
    }

    std::string keys_of(char k, const std::string& a, const std::string& b)
    {
      std::string x = member_of(a);
      std::string y = b == "-" ? x : member_of(b);
      if (x == NONE || y == NONE) { return NONE; }
      std::string m = x.empty() ? y : y.empty() || x == y ? x : UNKNOWN;
      return m.empty() || m == UNKNOWN ? std::string(1, k) : std::string(1, k) + "<" + m + ">";
    }

    // What a set operation gives: a bag where a bag goes in, else a set; a
    // bag always from '(+)' and '(.)'.
    std::string set_op(const std::string& op, const std::string& a, const std::string& b)
    {
      if (LOGICAL.count(op)) { return "L"; }
      bool bag = op == "(+)" || op == "(.)" || kind(a) == 'M' || kind(b) == 'M';
      return keys_of(bag ? 'M' : 'S', a, b);
    }

    // An operator's result, given its operands'.
    std::string binop(const std::string& op, const std::string& l0, const std::string& r0)
    {
      if (LOGICAL.count(op)) { return "L"; }
      if (op == "?:")
      {
        if (l0 == NONE || r0 == NONE) { return NONE; }
        return l0 == r0 || r0.empty() ? l0 : l0.empty() ? r0 : join(l0, r0) == l0 ? l0 : UNKNOWN;
      }
      std::string l = bare(l0);
      std::string r = bare(r0);
      if (op == "neg")
      {
        return r == NONE ? NONE : r == "N" || r == "F" ? r : UNKNOWN;
      }
      if (l == NONE || r == NONE) { return NONE; }
      bool num = (l == "N" || l == "F") && (r == "N" || r == "F");
      if (num) { return l == "F" || r == "F" ? "F" : "N"; }
      if (op == "+" || op == "-")
      {
        // A string and something xc cannot tell: a string, or an error.
        if ((l == "C" && (r == "C" || r == UNKNOWN)) || (r == "C" && l == UNKNOWN)) { return "C"; }
      }
      if (op == "+")
      {
        if (l == "C" && r == "C") { return "C"; }
        if ((l == "D" && r == "N") || (l == "N" && r == "D")) { return "D"; }
      }
      if (op == "-")
      {
        if (l == "C" && r == "C") { return "C"; }
        if (l == "D" && r == "N") { return "D"; }
        if (l == "D" && r == "D") { return "N"; }
      }
      return UNKNOWN;
    }

    std::string chop(const std::string& s) { return s.empty() ? s : s.substr(0, s.size() - 1); }

    // TL++'s functions, and what each gives.
    const std::unordered_map<std::string, std::string> RETURNS =
    {
      { "len", "N" }, { "val", "N" }, { "at", "N" }, { "rat", "N" }, { "asc", "N" }, { "mod", "N" },
      { "sqrt", "N" }, { "exp", "N" }, { "log", "N" }, { "year", "N" }, { "month", "N" }, { "day", "N" },
      { "dow", "N" }, { "seconds", "N" }, { "ascan", "N" }, { "recno", "N" }, { "reccount", "N" },
      { "lastrec", "N" }, { "fcount", "N" }, { "randomize", "N" },
      { "str", "C" }, { "strzero", "C" }, { "alltrim", "C" }, { "trim", "C" }, { "rtrim", "C" }, { "ltrim", "C" },
      { "upper", "C" }, { "lower", "C" }, { "substr", "C" }, { "left", "C" }, { "right", "C" }, { "padl", "C" },
      { "padr", "C" }, { "padc", "C" }, { "replicate", "C" }, { "space", "C" }, { "chr", "C" },
      { "strtran", "C" }, { "stuff", "C" }, { "transform", "C" }, { "dtos", "C" }, { "dtoc", "C" },
      { "time", "C" }, { "cvaltochar", "C" }, { "valtype", "C" }, { "capital", "C" }, { "cmonth", "C" },
      { "cdow", "C" }, { "elaptime", "C" }, { "procname", "C" }, { "alias", "C" }, { "encodeutf8", "C" },
      { "decodeutf8", "C" }, { "memoline", "C" },
      { "empty", "L" }, { "file", "L" }, { "isdigit", "L" }, { "isalpha", "L" }, { "isupper", "L" },
      { "islower", "L" }, { "eof", "L" }, { "bof", "L" }, { "found", "L" }, { "deleted", "L" },
      { "dbseek", "L" },
      { "date", "D" }, { "ctod", "D" }, { "stod", "D" }, { "msdate", "D" }, { "lastday", "D" },
      { "firstday", "D" }, { "daysum", "D" }, { "daysub", "D" }, { "monthsum", "D" }, { "monthsub", "D" },
      { "yearsum", "D" }, { "yearsub", "D" },
      { "array", "A" }, { "directory", "A" }, { "strtokarr", "A<C>" }, { "strtokarr2", "A<C>" },
      { "separa", "A<C>" },
    };

    // The runtime's verbs that give an array of what they walk, as they walk
    // it: some of it, or in another order.
    const std::unordered_set<std::string> KEEPS =
    {
      "filter", "reject", "tap", "take", "drop", "takewhile", "dropwhile", "distinct", "distinctadjacent",
      "sort", "sortby", "reverse", "apick", "aroll",
    };

    // How a function of the file is called: a user function with its 'u_'.
    std::string called_as(const FunctionDef* f)
    {
      std::string t = lc(f->type);
      if (t == "user") { return "u_" + lc(f->name); }
      if (t.empty() || t == "static") { return lc(f->name); }
      return "";
    }

    // ---- the pass -----------------------------------------------------------
    struct Var
    {
      std::string name;
      bool pinned = false;           // its type declared, or one xc does not work out
      std::string type = NONE;       // what it holds
      std::string container;         // the typed array or hash it is declared as
      int line = 0;                  // where it is declared
      bool block = false;            // a lambda's or a code block's parameter
    };

    struct Event
    {
      enum Kind { Decl, Assign, Counter, ForIn, Unknown, Ref, CallE, MethodE, Return } kind = Decl;
      int line = 0;
      Var* var = nullptr;
      Var* index = nullptr;
      const Declarator* decl = nullptr;
      const Expr* target = nullptr;
      std::string op;
      std::string incdec;
      const Expr* value = nullptr;
      const Call* call = nullptr;
      const Pipeline* chain = nullptr;   // a stage's chain, and the stage
      std::size_t stage = 0;
      const MethodCall* method = nullptr;
    };

    struct Function
    {
      std::vector<const Param*> params;
      std::string name;
    };

    // A function's events -- the file's statics' too --, and what it returns
    // if that is a typed array or hash.
    struct Unit
    {
      std::vector<Event> events;
      std::string ret;
      std::string name;
      std::string cls;               // a method's class, in lower case
      bool ctor = false;             // a constructor
    };

    // A class of the file: its Data -- typed or not --, its methods'
    // signatures and implementations, and those it inherits from.
    struct ClassData
    {
      std::string type;              // what it holds: its container, or its type's letter
      std::string container;         // a typed array's, hash's -- or a class's
      std::string name;
      int line = 0;
    };

    struct ClassInfo
    {
      std::string name;
      std::vector<std::string> supers;
      std::unordered_map<std::string, ClassData> data;
      std::unordered_map<std::string, const MethodSig*> sigs;
      std::unordered_map<std::string, const MethodImpl*> impls;
    };

    // A type of the file: its fields, at their positions from 1, and its
    // methods.
    struct TypeData
    {
      std::string name;
      std::string owner;             // the type that declares it, as written
      std::string type;              // what it holds: its container, or its type
      std::string slot;              // what xc checks goes in, or ''
      bool constant = false;         // '<const>': given only where one is made
      int pos = 0;
      const Declarator* decl = nullptr;
    };

    struct TypeInfo
    {
      std::string name;
      const TypeDef* def = nullptr;
      std::vector<TypeData> fields;
      std::unordered_map<std::string, std::size_t> by_name;
      std::unordered_map<std::string, const FunctionDef*> methods;
      std::size_t inherited = 0;     // the fields of the type it is from, first
    };

    using Scope = std::unordered_map<std::string, Var*>;

    class Typer
    {
    public:
      Typer(const Program* p, const Dictionary& dictionary) : p_(p), dictionary_(dictionary) {}

      void run();

      std::vector<Finding> errors;
      std::vector<Finding> warnings;

    private:
      const Program* p_;
      const Dictionary& dictionary_;
      std::vector<std::unique_ptr<Var>> vars_;
      std::vector<Scope> scopes_;
      std::unordered_map<const Expr*, Var*> names_;  // what each name is
      std::unordered_map<const Expr*, std::vector<Var*>> block_params_;
      std::vector<std::pair<HashIndex*, std::string>> hashes_;   // every 'h{k}', and its class
      std::vector<std::pair<ForInStmt*, std::string>> walks_;    // every 'for ... in'
      std::unordered_map<std::string, ClassInfo> classes_;       // the file's, by name
      std::unordered_map<std::string, TypeInfo> types_;          // and its types
      std::unordered_map<std::string, std::string> type_words_;
      std::unordered_map<std::string, std::string> type_bases_;
      std::string typ_;              // the type of the method walked, in lower case
      // Each 'x.f', 'x.m()' -- the class and the type where it is, its line
      // --, each value of a type made, each verb that walks with a lambda.
      struct At
      {
        Expr* e;
        std::string cls;
        std::string typ;
        int line;
      };
      std::vector<At> dots_;
      std::vector<At> safes_;          // each 'x?.f', 'x?.m()'
      std::vector<At> withs_;          // each 'with object''s subject
      std::vector<At> makes_;
      std::vector<At> verbs_;
      std::string cls_;              // the class of the method walked, checked
      std::vector<Unit> units_;
      std::unordered_map<std::string, std::string> returns_;    // the file's functions
      std::unordered_map<std::string, Function> functions_;
      std::string ret_;              // what the function returns, if it is a typed array or hash
      std::string ret_name_;
      int line_ = 0;

      bool any_typed() const;
      Var* declare(const std::string& name, bool pinned, const std::string& type, const std::string& container);
      Var* find(const std::string& name) const;
      void function(const std::vector<Param*>& params, const Body& body, const std::string& ret,
                    const std::string& name, int line);
      void body(const Body& b);
      void stmt(Stmt* s);
      void expr(Expr* e);
      void declarator(Declarator* d, const std::string& scope);
      void event(Event e)
      {
        e.line = line_;
        units_.back().events.push_back(std::move(e));
      }
      void infer();
      void check(const Unit& u);

      std::string type(const Expr* e);
      std::string call_type(const std::string& name, const std::vector<Expr*>& args, const std::string* fed);
      std::string chain_type(const Pipeline* p, std::size_t stages);
      std::string field_type(const AliasField* f) const;
      std::string elem_in(const Expr* source);
      const ClassData* data_of(const std::string& cls, const std::string& name, int depth = 0) const;
      const TypeInfo* type_of(const std::string& t) const;
      const TypeData* field_of(const std::string& t, const std::string& name) const;
      std::string dot_name(const Expr* e) const;
      std::string field_who(const Dot* d);
      void types();
      void lambdas();
      void resolve();
      void made(const Call* c);
      void dot_args(const DotCall* d);
      const ClassInfo* class_of_method(const std::string& cls, const std::string& name, int depth = 0) const;
      bool self(const Expr* e) const;
      std::string class_type(const std::string& cls) const;
      std::string word_type(const std::string& word) const;
      std::string decl_type(const Declarator* d) const;
      std::string slot_of(const Param* q) const;
      std::string obj_class(const Expr* e);
      std::string method_type(const std::string& cls, const std::string& name) const;
      std::vector<const Param*> method_params(const std::string& cls, const std::string& name) const;
      std::string member_name(const Member* m);
      std::string member_who(const Member* m);
      std::string method_who(const MethodCall* m, const std::string& cls);

      void into(const Expr* e, const std::string& slot, const std::string& who, bool key = false);
      void put(const Expr* e, const std::string& slot, const std::string& who);
      std::string who_of(const Expr* base);
      std::string fixed_who(const Expr* written);
      std::string declared_as(const Var* v) const;
      void writes(const Expr* into, const std::string& how, const std::string* fed = nullptr);
      void call_check(const std::string& name, const std::vector<Expr*>& args, const Expr* fed_expr,
                      const std::string* fed);
    };

    // ---- what the file has --------------------------------------------------
    bool Typer::any_typed() const
    {
      if (!p_->types.empty()) { return true; }
      // A class of the file named as a type.
      auto named = [&](const OptStr& w) { return w && classes_.count(lc(*w)) > 0; };
      auto param = [&](const Param* q) { return q && (!q->container.empty() || named(q->type_word)); };
      for (const ClassDef* c : p_->classes)
      {
        for (const DataMember* d : c->members)
        {
          if (!d->container.empty() || named(d->type)) { return true; }
        }
        for (const MethodSig* m : c->methods)
        {
          if (!m->ret_container.empty() || named(m->returns)) { return true; }
          for (const Param* q : m->params)
          {
            if (param(q)) { return true; }
          }
        }
      }
      for (const MethodImpl* m : p_->methods)
      {
        if (!m->ret_container.empty() || named(m->returns)) { return true; }
        for (const Param* q : m->params)
        {
          if (param(q)) { return true; }
        }
      }
      for (const Declaration* d : p_->statics)
      {
        for (const Declarator* v : d->declarators)
        {
          if (!v->container.empty() || classed(decl_type(v))) { return true; }
        }
      }
      for (const FunctionDef* f : p_->functions)
      {
        if (!f->ret_container.empty() || named(f->rettype_word)) { return true; }
        for (const Param* q : f->params)
        {
          if (param(q)) { return true; }
        }
      }
      bool found = false;
      auto look = [&](Expr* e)
      {
        walk_expr(e, [&](Expr* x)
        {
          if (is(x, EK::ArrayLit) && !static_cast<ArrayLit*>(x)->elem.empty()) { found = true; }
          if (is(x, EK::HashLit) && !static_cast<HashLit*>(x)->key_type.empty()) { found = true; }
          if (is(x, EK::Binary) && static_cast<Binary*>(x)->op[0] == '(') { found = true; }
          if (is(x, EK::Call))
          {
            std::string n = lc(static_cast<Call*>(x)->name);
            if (n == "setof" || n == "bagof") { found = true; }
          }
        });
      };
      auto in_body = [&](const Body& b)
      {
        walk(b, [&](Stmt* s)
        {
          if (found) { return; }
          if (s->kind == SK::Declaration)
          {
            for (const Declarator* v : static_cast<Declaration*>(s)->declarators)
            {
              if (!v->container.empty() || classed(decl_type(v))) { found = true; }
            }
          }
          for (Expr* e : exprs_of(s)) { look(e); }
        });
      };
      for (const Declaration* d : p_->statics)
      {
        for (Declarator* v : d->declarators) { look(v->init); }
      }
      for (const FunctionDef* f : p_->functions) { in_body(f->body); }
      for (const MethodImpl* m : p_->methods) { in_body(m->body); }
      return found;
    }

    // ---- names --------------------------------------------------------------
    Var* Typer::declare(const std::string& name, bool pinned, const std::string& type, const std::string& container)
    {
      vars_.push_back(std::make_unique<Var>());
      Var* v = vars_.back().get();
      v->name = name;
      v->pinned = pinned;
      v->type = pinned ? type : NONE;
      v->container = container;
      v->line = line_;
      scopes_.back()[lc(name)] = v;
      return v;
    }

    Var* Typer::find(const std::string& name) const
    {
      std::string k = lc(name);
      for (auto s = scopes_.rbegin(); s != scopes_.rend(); ++s)
      {
        if (auto it = s->find(k); it != s->end()) { return it->second; }
      }
      return nullptr;
    }

    // A declarator's name: declared as a typed array or hash -- by its type,
    // or by its value, '{ <n> }' --, with a type, or worked out from what it
    // is given (a Local's, a Static's).
    void Typer::declarator(Declarator* d, const std::string& scope)
    {
      expr(d->init);
      for (Expr* x : d->dims) { expr(x); }
      std::string container = d->container;
      if (container.empty() && d->init && (scope == "local" || scope == "static"))
      {
        if (is(d->init, EK::ArrayLit) && !static_cast<ArrayLit*>(d->init)->elem.empty())
        {
          container = type(d->init);
        }
        else if (is(d->init, EK::HashLit) && !static_cast<HashLit*>(d->init)->key_type.empty())
        {
          container = type(d->init);
        }
      }
      Var* v = nullptr;
      if (!container.empty()) { v = declare(d->name, true, container, container); }
      else if (scope != "local" && scope != "static") { v = declare(d->name, true, UNKNOWN, ""); }
      else if (d->declared != "?")
      {
        // 'as Order': an Order goes in, as into a typed array.
        std::string t = decl_type(d);
        v = declare(d->name, true, t, checked_slot(t) ? t : "");
      }
      else { v = declare(d->name, false, NONE, ""); }
      Event e;
      e.kind = Event::Decl;
      e.var = v;
      e.decl = d;
      event(e);
    }

    // ---- the walk -----------------------------------------------------------
    // Every file: what a 'for ... in' walks and a 'h{k}' reads is worked out
    // anyway; what is wrong is said of a file that types an array or a hash.
    void Typer::run()
    {
      types();
      // The file's classes: their names first -- a Data's type may be one
      // declared further on --, then their Data and their methods.
      for (const ClassDef* c : p_->classes)
      {
        ClassInfo& ci = classes_[lc(c->name)];
        ci.name = c->name;
        // An object of a class is one of the interfaces it implements too.
        for (const std::string& x : c->supers) { ci.supers.push_back(lc(x)); }
        for (const std::string& x : c->ifaces) { ci.supers.push_back(lc(x)); }
      }
      for (const ClassDef* c : p_->classes)
      {
        ClassInfo& ci = classes_[lc(c->name)];
        for (const DataMember* d : c->members)
        {
          ClassData cd;
          std::string t = d->type ? word_type(*d->type) : UNKNOWN;
          cd.container = !d->container.empty() ? d->container : checked_slot(t) ? t : "";
          cd.type = !d->container.empty() ? d->container : t;
          cd.name = d->name;
          cd.line = d->line;
          ci.data[lc(d->name)] = cd;
        }
        for (const MethodSig* m : c->methods) { ci.sigs[lc(m->name)] = m; }
      }
      bool typed = any_typed();
      for (const FunctionDef* f : p_->functions)
      {
        std::string name = called_as(f);
        if (name.empty()) { continue; }
        if (!f->ret_container.empty()) { returns_[name] = f->ret_container; }
        else if (f->rettype_word) { returns_[name] = word_type(*f->rettype_word); }
        Function fn;
        fn.name = f->name;
        for (const Param* q : f->params) { fn.params.push_back(q); }
        functions_[name] = fn;
      }
      for (const MethodImpl* m : p_->methods)
      {
        auto it = classes_.find(lc(m->class_name));
        if (it != classes_.end()) { it->second.impls[lc(m->name)] = m; }
      }
      // The file's statics -- only its functions give them anything, so what
      // they hold is worked out over all of them.
      scopes_.assign(1, Scope{});
      units_.emplace_back();
      for (const Declaration* d : p_->statics)
      {
        for (Declarator* v : d->declarators)
        {
          line_ = v->line;
          declarator(v, "static");
        }
      }
      Scope file = scopes_.front();
      for (const FunctionDef* f : p_->functions)
      {
        scopes_.assign(1, file);
        std::string ret = f->ret_container;
        std::string word = f->rettype_word ? word_type(*f->rettype_word) : "";
        if (ret.empty() && checked_slot(word)) { ret = word; }
        typ_ = lc(f->of_type);
        function(f->params, f->body, ret, f->name, f->line);
        typ_.clear();
      }
      for (const MethodImpl* m : p_->methods)
      {
        scopes_.assign(1, file);
        cls_ = lc(m->class_name);
        std::string ret = m->ret_container;
        const MethodSig* sig = nullptr;
        if (auto c = classes_.find(cls_); c != classes_.end())
        {
          if (auto g = c->second.sigs.find(lc(m->name)); g != c->second.sigs.end()) { sig = g->second; }
        }
        if (ret.empty() && sig) { ret = sig->ret_container; }
        if (ret.empty() && checked_slot(method_type(cls_, m->name))) { ret = method_type(cls_, m->name); }
        function(m->params, m->body, ret, "::" + m->name, m->line);
        units_.back().cls = cls_;
        units_.back().ctor = sig ? sig->constructor : lc(m->name) == "new";
        cls_.clear();
      }
      infer();
      // What each 'x.f' and 'x.m()' is of -- for the back ends, in every
      // file.
      lambdas();
      resolve();
      // A set's or a bag's 'h{k}': Raku's reads and writes (lower.cpp).
      for (auto& [h, c] : hashes_)
      {
        cls_ = c;
        char k = kind(type(h->base));
        if (k == 'S' || k == 'M') { h->set_kind = k; }
      }
      // 'for k in h', 'for k, v in h': its keys, and what each holds.
      for (auto& [f, c] : walks_)
      {
        cls_ = c;
        char k = kind(type(f->source));
        f->keyed = keyed(k) || k == 'J';
      }
      cls_.clear();
      if (!typed) { return; }
      for (const Unit& u : units_) { check(u); }
      for (const At& m : makes_)
      {
        cls_ = m.cls;
        line_ = m.line;
        made(static_cast<const Call*>(m.e));
      }
      for (const At& d : dots_)
      {
        cls_ = d.cls;
        line_ = d.line;
        if (is(d.e, EK::DotCall)) { dot_args(static_cast<const DotCall*>(d.e)); }
      }
      cls_.clear();
      // A fixed Data is given its value by the constructor: one the file
      // implements, that never does, is refused.
      for (const auto& [k, ci] : classes_)
      {
        for (const auto& [dk, cd] : ci.data)
        {
          if (!fixed(cd.container)) { continue; }
          for (const Unit& u : units_)
          {
            if (u.cls != k || !u.ctor) { continue; }
            cls_ = u.cls;
            bool given = false;
            for (const Event& e : u.events)
            {
              if (e.kind == Event::Assign && is(e.target, EK::Member) && self(static_cast<const Member*>(e.target)->base)
                  && lc(static_cast<const Member*>(e.target)->name) == dk)
              {
                given = true;
              }
            }
            if (!given)
            {
              errors.push_back({ cd.line, "'::" + cd.name + "' is " + shown(cd.container) + ": " + u.name.substr(2)
                                          + "(), the constructor, gives it its value." });
            }
          }
        }
      }
    }

    // ---- types --------------------------------------------------------------
    // The file's types: each field's position and what it holds, each
    // method -- and what is wrong with them.
    void Typer::types()
    {
      for (const TypeDef* t : p_->types)
      {
        std::string k = lc(t->name);
        if (types_.count(k))
        {
          const TypeDef* was = types_[k].def;
          errors.push_back({ t->line, was->header.empty()
                                      ? "'" + t->name + "' is declared twice, on line " + std::to_string(was->line)
                                        + " and here."
                                      : "'" + t->name + "' is a type of " + was->header + " too: give it another name." });
          continue;
        }
        types_[k].name = t->name;
        types_[k].def = t;
        type_words_[k] = t->name;
      }
      type_words = &type_words_;
      type_bases = &type_bases_;
      std::unordered_set<std::string> functions;
      for (const FunctionDef* f : p_->functions)
      {
        if (f->of_type.empty()) { functions.insert(lc(f->name)); }
      }
      for (const TypeDef* t : p_->types)
      {
        // What is wrong with a header's type was said of the header.
        std::size_t before = errors.size();
        TypeInfo& ti = types_[lc(t->name)];
        if (ti.def != t) { continue; }
        bool cls = false;
        for (const ClassDef* c : p_->classes) { cls = cls || lc(c->name) == lc(t->name); }
        if (functions.count(lc(t->name)) || cls)
        {
          errors.push_back({ t->line, "'" + t->name + "' is a type of the file and a " + (cls ? "class" : "function")
                                      + " of it: '" + t->name + "(...)' makes a value of the type." });
        }
        // 'type B from A': A's fields first, at their places, and its
        // methods -- A declared before B, so that its own are worked out.
        if (!t->base.empty())
        {
          std::string b = lc(t->base);
          auto bi = types_.find(b);
          if (b == lc(t->name))
          {
            errors.push_back({ t->line, "'" + t->name + "' cannot be from itself." });
          }
          else if (bi == types_.end())
          {
            errors.push_back({ t->line, "'" + t->name + "' is from '" + t->base + "', which is no type of the file." });
          }
          else if (bi->second.def->header.empty() && bi->second.def->from > t->from)
          {
            errors.push_back({ t->line, "'" + t->name + "' is from " + bi->second.name + ", declared further on, on line "
                                        + std::to_string(bi->second.def->line) + ": declare " + bi->second.name
                                        + " first." });
          }
          else
          {
            const TypeInfo& bt = bi->second;
            ti.fields = bt.fields;
            ti.by_name = bt.by_name;
            ti.methods = bt.methods;
            ti.inherited = bt.fields.size();
            type_bases_[lc(t->name)] = b;
          }
        }
        for (const TypeField* f : t->fields)
        {
          const Declarator* d = f->decl;
          TypeData td;
          td.name = d->name;
          td.owner = t->name;
          td.decl = d;
          std::string w = type_word_of(d->typespec_text.value_or(""));
          td.type = !d->container.empty() ? d->container : !w.empty() ? word_type(w) : UNKNOWN;
          td.slot = td.type == UNKNOWN ? "" : td.type;
          td.pos = static_cast<int>(ti.fields.size()) + 1;
          for (const std::string& a : d->attributes)
          {
            if (a == "const") { td.constant = true; }
            else
            {
              errors.push_back({ d->line, "the field '" + d->name + "' of " + t->name + " is <" + a
                                          + ">: a field takes <const>, nothing else." });
            }
          }
          std::string n = lc(d->name);
          if (n == "and" || n == "or" || n == "not" || n == "t" || n == "f" || n == "y" || n == "n")
          {
            errors.push_back({ d->line, "a field cannot be called '" + d->name + "': '." + d->name
                                        + ".' is TL++'s own." });
          }
          if (ti.by_name.count(n))
          {
            const TypeData& was = ti.fields[ti.by_name[n]];
            errors.push_back({ d->line, was.owner == t->name
                                        ? "'" + d->name + "' is a field of " + t->name + " twice."
                                        : "'" + d->name + "' is a field of " + was.owner + ", which " + t->name
                                          + " is from: " + t->name + " has it already." });
            continue;
          }
          if (functions.count(lc(t->name + "_" + d->name)))
          {
            errors.push_back({ d->line, "'" + t->name + "_" + d->name + "' is the position of " + t->name + "'s field '"
                                        + d->name + "', and a function of the file." });
          }
          // Its default is made where a value is: no variable is there.
          if (d->init && !d->init_made)
          {
            walk_expr(d->init, [&](Expr* x)
            {
              if (is(x, EK::Name))
              {
                errors.push_back({ d->line, "the field '" + d->name + "' of " + t->name
                                            + " starts at a value made where one is: it cannot read '"
                                            + static_cast<Name*>(x)->name + "'." });
              }
            });
          }
          ti.by_name[n] = ti.fields.size();
          ti.fields.push_back(td);
        }
        for (const FunctionDef* m : t->methods)
        {
          // Self is TL++'s aSelf, the function's first parameter.
          auto own = [&](const std::string& name, int line)
          {
            if (lc(name) == "self" || lc(name) == "aself")
            {
              errors.push_back({ line, "'" + name + "' is the value " + m->method + "() is called on -- '" + SELF_TLPP
                                       + "' in TL++: a type's method declares no other." });
            }
          };
          for (std::size_t i = 1; i < m->params.size(); i++) { own(m->params[i]->name, m->line); }
          walk(m->body, [&](Stmt* x)
          {
            if (x->kind != SK::Declaration) { return; }
            for (const Declarator* v : static_cast<Declaration*>(x)->declarators) { own(v->name, v->line); }
          });
          if (functions.count(lc(m->name)))
          {
            errors.push_back({ m->line, "'" + m->name + "' is the function " + t->name + "'s method " + m->method
                                        + "() is, and a function of the file." });
          }
          std::string n = lc(m->method);
          if (ti.methods.count(n) || ti.by_name.count(n))
          {
            bool method = ti.methods.count(n) > 0;
            std::string owner = method ? ti.methods[n]->of_type : ti.fields[ti.by_name[n]].owner;
            errors.push_back({ m->line, "'" + m->method + "' is " + (method ? "a method" : "a field") + " of "
                                        + (owner == t->name ? t->name + " already."
                                                            : owner + ", which " + t->name + " is from: " + t->name
                                                              + " has it already.") });
            continue;
          }
          ti.methods[n] = m;
        }
        if (!t->header.empty()) { errors.resize(before); }
      }
    }

    // The type of the file a value of type t is of, if it is one.
    const TypeInfo* Typer::type_of(const std::string& t) const
    {
      if (!typed_value(t)) { return nullptr; }
      auto it = types_.find(t.substr(2));
      return it != types_.end() ? &it->second : nullptr;
    }

    const TypeData* Typer::field_of(const std::string& t, const std::string& name) const
    {
      const TypeInfo* ti = type_of(t);
      if (!ti) { return nullptr; }
      auto f = ti->by_name.find(lc(name));
      return f != ti->by_name.end() ? &ti->fields[f->second] : nullptr;
    }

    // 'x.f' as a message names it: 'aIt', 'aOrd.oCli', 'Self'; '' for what
    // has no name.
    std::string Typer::dot_name(const Expr* e) const
    {
      if (is(e, EK::Name)) { return static_cast<const Name*>(e)->name; }
      if (is(e, EK::Dot))
      {
        auto d = static_cast<const Dot*>(e);
        std::string b = dot_name(d->base);
        return b.empty() ? "" : b + "." + d->name;
      }
      return "";
    }

    // A field written to, said so: "'aIt.nQtd' is Numeric".
    std::string Typer::field_who(const Dot* d)
    {
      const TypeData* f = field_of(type(d->base), d->name);
      std::string n = dot_name(d);
      return "'" + (n.empty() ? "." + d->name : n) + "' is " + shown(f ? f->type : UNKNOWN);
    }

    // A lambda a verb walks a type's values with: its parameter is one --
    // what xc knows of the array, worked out.
    void Typer::lambdas()
    {
      static const std::unordered_set<std::string> walkers =
      {
        "map", "filter", "reject", "tap", "takewhile", "dropwhile", "expand", "distinctadjacent", "sort", "sortby",
        "chunkby", "scan", "reduce", "fold", "count", "first", "anyof", "allof", "noneof", "maxby", "minby",
        "heapof",
      };
      // TL++'s own: ASort()'s block takes two elements, AEval()'s and
      // AScan()'s one.
      static const std::unordered_set<std::string> natives = { "asort", "aeval", "ascan" };
      auto give = [&](const Call* c, const std::string& fed, std::size_t from)
      {
        std::string n = lc(c->name);
        std::string el = elem_of(fed);
        if (!(walkers.count(n) || (natives.count(n) && from == 1)) || !typed_value(bare(el))) { return; }
        if (n == "asort") { n = "sort"; }
        std::size_t k = n == "reduce" || n == "fold" || n == "scan" ? 1 : 0;
        for (std::size_t i = from; i < c->args.size(); i++)
        {
          auto ps = block_params_.find(c->args[i]);
          if (ps == block_params_.end()) { continue; }
          for (std::size_t j = 0; j < ps->second.size(); j++)
          {
            if ((j == k || n == "sort") && ps->second[j]->type == UNKNOWN) { ps->second[j]->type = bare(el); }
          }
        }
      };
      for (const At& v : verbs_)
      {
        cls_ = v.cls;
        if (is(v.e, EK::Pipeline))
        {
          auto p = static_cast<const Pipeline*>(v.e);
          for (std::size_t i = 0; i < p->stages.size(); i++) { give(p->stages[i], chain_type(p, i), 0); }
        }
        else
        {
          auto c = static_cast<const Call*>(v.e);
          if (!c->args.empty()) { give(c, type(c->args[0]), 1); }
        }
      }
      cls_.clear();
    }

    // Each 'x.f', 'x.m()': the type x is of, the field's position -- or why
    // xc cannot tell.
    void Typer::resolve()
    {
      // The innermost first: what one cannot tell is not said again of the
      // field read from it -- the messages then go in the order found.
      std::vector<std::vector<Finding>> said(dots_.size());
      for (std::size_t i = dots_.size(); i-- > 0;)
      {
        const At& a = dots_[i];
        cls_ = a.cls;
        line_ = a.line;
        bool call = is(a.e, EK::DotCall);
        Expr* base = call ? static_cast<DotCall*>(a.e)->base : static_cast<Dot*>(a.e)->base;
        const std::string& name = call ? static_cast<DotCall*>(a.e)->name : static_cast<Dot*>(a.e)->name;
        std::string what = "'." + name + (call ? "()'" : "'");
        std::string t = type(base);
        const TypeInfo* ti = type_of(t);
        if (!ti)
        {
          // Read from a field xc could not work out: said of that one.
          if ((is(base, EK::Dot) && static_cast<Dot*>(base)->of_type.empty())
              || (is(base, EK::DotCall) && static_cast<DotCall*>(base)->of_type.empty()))
          {
            continue;
          }
          std::string who = dot_name(base);
          who = who.empty() ? "this" : "'" + who + "'";
          if (bare(t) != UNKNOWN && t != NONE && !t.empty())
          {
            said[i].push_back({ line_, who + " is " + shown(t) + ", no type's value: " + what + " is a type's "
                                      + (call ? "method." : "field.")
                                      + (classed(t) ? " Its class's are read with ':'." : "") });
            continue;
          }
          // The types that have it: one, and its name says how to declare it.
          std::vector<std::string> have;
          for (const TypeDef* d : p_->types)
          {
            const TypeInfo& x = types_.at(lc(d->name));
            bool has = call ? x.methods.count(lc(name)) > 0 : x.by_name.count(lc(name)) > 0;
            if (x.def == d && has) { have.push_back(d->name); }
          }
          // A name the function declares can say so; a block's parameter
          // cannot.
          bool can = false;
          if (is(base, EK::Name))
          {
            auto v = names_.find(base);
            can = v != names_.end() && !v->second->block;
          }
          std::string hint = have.size() == 1 && can ? " -- '" + who.substr(1, who.size() - 2) + " as " + have[0]
                                                       + "' says it is one." : "";
          said[i].push_back({ line_, what + ": xc cannot tell that " + who + " is a type's value"
                                    + (hint.empty() ? "." : hint) });
          continue;
        }
        if (call)
        {
          auto m = ti->methods.find(lc(name));
          if (m == ti->methods.end())
          {
            said[i].push_back({ line_, "'" + ti->name + "' has no method '" + name + "()'." });
            continue;
          }
          static_cast<DotCall*>(a.e)->of_type = ti->name;
          continue;
        }
        auto f = ti->by_name.find(lc(name));
        if (f == ti->by_name.end())
        {
          said[i].push_back({ line_, "'" + ti->name + "' has no field '" + name + "'." });
          continue;
        }
        // Its position is a #define of the type's: there only after it.
        if (ti->def->header.empty() && a.e->from >= 0 && a.e->from < ti->def->from)
        {
          said[i].push_back({ line_, "'" + ti->name + "' is declared on line " + std::to_string(ti->def->line)
                                    + ": its fields are read after it." });
          continue;
        }
        static_cast<Dot*>(a.e)->of_type = ti->name;
        static_cast<Dot*>(a.e)->pos = ti->fields[f->second].pos;
      }
      for (std::vector<Finding>& f : said) { errors.insert(errors.end(), f.begin(), f.end()); }
      // 'with object' takes an object: a type's value has its fields.
      for (const At& a : withs_)
      {
        cls_ = a.cls;
        line_ = a.line;
        std::string t = type(a.e);
        if (!typed_value(t)) { continue; }
        std::string who = dot_name(a.e);
        errors.push_back({ line_, "'with object' takes an object, and " + (who.empty() ? "this" : "'" + who + "'")
                                  + " is " + shown(t) + ": its fields are '" + (who.empty() ? "x" : who) + ".x'." });
      }
      // 'x?.f', 'x?.m()' of a type's value: Nil if x is, else its field, its
      // method -- of an object, what they always were.
      for (const At& a : safes_)
      {
        cls_ = a.cls;
        line_ = a.line;
        bool call = is(a.e, EK::SafeCall);
        const Expr* base = call ? static_cast<MethodCall*>(a.e)->base : static_cast<Member*>(a.e)->base;
        const std::string& name = call ? static_cast<MethodCall*>(a.e)->name : static_cast<Member*>(a.e)->name;
        const TypeInfo* ti = type_of(type(base));
        if (!ti) { continue; }
        if (call)
        {
          if (!ti->methods.count(lc(name)))
          {
            errors.push_back({ line_, "'" + ti->name + "' has no method '" + name + "()'." });
            continue;
          }
          static_cast<MethodCall*>(a.e)->of_type = ti->name;
          continue;
        }
        auto f = ti->by_name.find(lc(name));
        if (f == ti->by_name.end())
        {
          errors.push_back({ line_, "'" + ti->name + "' has no field '" + name + "'." });
          continue;
        }
        if (ti->def->header.empty() && a.e->from >= 0 && a.e->from < ti->def->from)
        {
          errors.push_back({ line_, "'" + ti->name + "' is declared on line " + std::to_string(ti->def->line)
                                    + ": its fields are read after it." });
          continue;
        }
        static_cast<Member*>(a.e)->of_type = ti->name;
        static_cast<Member*>(a.e)->pos = ti->fields[f->second].pos;
      }
      cls_.clear();
    }

    // A type's value made: the fields, by their places and by their names.
    void Typer::made(const Call* c)
    {
      const TypeInfo* ti = type_of("T:" + lc(c->name));
      if (!ti) { return; }
      std::vector<bool> given(ti->fields.size(), false);
      bool by_name = false;
      std::size_t at = 0;
      auto who = [&](const TypeData& f)
      {
        return "the field '" + f.name + "' of " + ti->name + "() is " + shown(f.type);
      };
      for (const Expr* a : c->args)
      {
        if (is(a, EK::Named))
        {
          by_name = true;
          auto n = static_cast<const Named*>(a);
          auto f = ti->by_name.find(lc(n->name));
          if (f == ti->by_name.end())
          {
            errors.push_back({ line_, "'" + ti->name + "' has no field '" + n->name + "'." });
            continue;
          }
          if (given[f->second])
          {
            errors.push_back({ line_, ti->name + "(): '" + n->name + "' is given twice." });
            continue;
          }
          given[f->second] = true;
          put(n->value, ti->fields[f->second].slot, who(ti->fields[f->second]));
          continue;
        }
        if (by_name)
        {
          errors.push_back({ line_, ti->name + "(): the values by their places come before those by their names." });
          return;
        }
        if (at >= ti->fields.size())
        {
          errors.push_back({ line_, ti->name + "() has " + std::to_string(ti->fields.size()) + " field"
                                    + (ti->fields.size() == 1 ? "" : "s") + ": this gives it more." });
          return;
        }
        given[at] = true;
        if (!is(a, EK::Omitted)) { put(a, ti->fields[at].slot, who(ti->fields[at])); }
        at++;
      }
    }

    // 'x.m(...)': what its parameters are declared as -- Self aside.
    void Typer::dot_args(const DotCall* d)
    {
      const TypeInfo* ti = type_of(type(d->base));
      if (!ti) { return; }
      auto m = ti->methods.find(lc(d->name));
      if (m == ti->methods.end()) { return; }
      const std::vector<Param*>& ps = m->second->params;
      for (std::size_t i = 0; i + 1 < ps.size() && i < d->args.size(); i++)
      {
        std::string slot = slot_of(ps[i + 1]);
        if (slot.empty()) { continue; }
        into(d->args[i], slot, "the parameter '" + ps[i + 1]->name + "' of " + ti->name + "." + m->second->method
                               + "() is " + shown(slot));
      }
    }

    // ---- classes ------------------------------------------------------------
    // A Data of a class of the file, or of one it inherits from there.
    const ClassData* Typer::data_of(const std::string& cls, const std::string& name, int depth) const
    {
      auto c = classes_.find(cls);
      if (c == classes_.end() || depth > 20) { return nullptr; }
      if (auto d = c->second.data.find(lc(name)); d != c->second.data.end()) { return &d->second; }
      for (const std::string& up : c->second.supers)
      {
        if (const ClassData* d = data_of(up, name, depth + 1)) { return d; }
      }
      return nullptr;
    }

    // The class of the file -- cls or one it inherits from -- that has a
    // method by that name.
    const ClassInfo* Typer::class_of_method(const std::string& cls, const std::string& name, int depth) const
    {
      auto c = classes_.find(cls);
      if (c == classes_.end() || depth > 20) { return nullptr; }
      std::string n = lc(name);
      if (c->second.sigs.count(n) || c->second.impls.count(n)) { return &c->second; }
      for (const std::string& up : c->second.supers)
      {
        if (const ClassInfo* x = class_of_method(up, name, depth + 1)) { return x; }
      }
      return nullptr;
    }

    // '::' -- or Self, by name -- in a method.
    bool Typer::self(const Expr* e) const
    {
      return !cls_.empty() && (is(e, EK::SelfRef) || (is(e, EK::Name) && lc(static_cast<const Name*>(e)->name) == "self"));
    }

    // An object of a class of the file: 'O:Depot:Stock' -- the class, then
    // those it inherits from there, by the names they are declared with.
    std::string Typer::class_type(const std::string& cls) const
    {
      std::string out = "O";
      std::unordered_set<std::string> seen;
      std::vector<std::string> todo{ cls };
      while (!todo.empty() && seen.size() < 20)
      {
        std::string k = todo.front();
        todo.erase(todo.begin());
        auto c = classes_.find(k);
        if (c == classes_.end() || !seen.insert(k).second) { continue; }
        out += ":" + c->second.name;
        todo.insert(todo.end(), c->second.supers.begin(), c->second.supers.end());
      }
      return out;
    }

    // A type as declared: TL++'s word, or a class of the file's name.
    std::string Typer::word_type(const std::string& word) const
    {
      std::string t = letter_of(word);
      if (t == UNKNOWN && classes_.count(lc(word))) { return class_type(lc(word)); }
      if (t == UNKNOWN && types_.count(lc(word))) { return "T:" + lc(word); }
      return t;
    }

    // What a declarator is declared as, if it is: 'Local nX as Numeric' is
    // 'N', 'Local oX as Order' an Order, 'Local aX[10]' an array.
    std::string Typer::decl_type(const Declarator* d) const
    {
      std::string w = type_word_of(d->typespec_text.value_or(""));
      if (!w.empty()) { return word_type(w); }
      return d->declared == "Array" ? "A" : UNKNOWN;
    }

    // What a parameter takes, if xc checks it: a typed array or hash, or an
    // object of a class of the file.
    std::string Typer::slot_of(const Param* q) const
    {
      if (!q) { return ""; }
      if (!q->container.empty()) { return q->container; }
      std::string t = q->type_word ? word_type(*q->type_word) : UNKNOWN;
      return checked_slot(t) ? t : "";
    }

    // The class of the file an object is of, in lower case: '::' in a method,
    // or a value known to be one -- or ''.
    std::string Typer::obj_class(const Expr* e)
    {
      if (self(e)) { return cls_; }
      std::string t = type(e);
      return classed(t) ? lc(lineage(t).front()) : "";
    }

    // What 'o:m()' gives: its return type, as declared.
    std::string Typer::method_type(const std::string& cls, const std::string& name) const
    {
      const ClassInfo* c = class_of_method(cls, name);
      if (!c) { return UNKNOWN; }
      std::string n = lc(name);
      auto i = c->impls.find(n);
      if (i != c->impls.end() && !i->second->ret_container.empty()) { return i->second->ret_container; }
      auto g = c->sigs.find(n);
      if (g != c->sigs.end() && !g->second->ret_container.empty()) { return g->second->ret_container; }
      if (i != c->impls.end() && i->second->returns) { return word_type(*i->second->returns); }
      if (g != c->sigs.end() && g->second->returns) { return word_type(*g->second->returns); }
      return UNKNOWN;
    }

    // Its parameters: the implementation's, or the signature's.
    std::vector<const Param*> Typer::method_params(const std::string& cls, const std::string& name) const
    {
      std::vector<const Param*> out;
      const ClassInfo* c = class_of_method(cls, name);
      if (!c) { return out; }
      std::string n = lc(name);
      auto i = c->impls.find(n);
      auto g = c->sigs.find(n);
      const std::vector<Param*>* ps = i != c->impls.end() ? &i->second->params : g != c->sigs.end() ? &g->second->params
                                                                                                    : nullptr;
      if (ps) { out.assign(ps->begin(), ps->end()); }
      return out;
    }

    // A Data as a message names it: '::aItems', 'oOrder:aItems',
    // '::oCust:aTags' -- 'Order:aItems', read from anything else.
    std::string Typer::member_name(const Member* m)
    {
      std::string c = obj_class(m->base);
      const ClassData* d = data_of(c, m->name);
      std::string n = d ? d->name : m->name;
      if (self(m->base)) { return "::" + n; }
      if (is(m->base, EK::Name)) { return static_cast<const Name*>(m->base)->name + ":" + n; }
      if (is(m->base, EK::Member)) { return member_name(static_cast<const Member*>(m->base)) + ":" + n; }
      auto ci = classes_.find(c);
      return (ci != classes_.end() ? ci->second.name : std::string("?")) + ":" + n;
    }

    // A Data, said so: "'::aItems' is an Array<n>".
    std::string Typer::member_who(const Member* m)
    {
      const ClassData* d = data_of(obj_class(m->base), m->name);
      return "'" + member_name(m) + "' is " + shown(d ? d->type : UNKNOWN);
    }

    // A method, as a message names it: '::Add()', 'Order:Add()'.
    std::string Typer::method_who(const MethodCall* m, const std::string& cls)
    {
      if (self(m->base)) { return "::" + m->name + "()"; }
      auto ci = classes_.find(cls);
      return (ci != classes_.end() ? ci->second.name : std::string("?")) + ":" + m->name + "()";
    }

    void Typer::function(const std::vector<Param*>& params, const Body& b, const std::string& ret,
                         const std::string& name, int line)
    {
      line_ = line;
      units_.emplace_back();
      units_.back().ret = ret;
      units_.back().name = name;
      scopes_.emplace_back();
      for (const Param* q : params)
      {
        if (!q) { continue; }
        std::string t = !q->container.empty() ? q->container : q->type_word ? word_type(*q->type_word) : UNKNOWN;
        declare(q->name, true, t, slot_of(q));
      }
      body(b);
      scopes_.pop_back();
    }

    void Typer::body(const Body& b)
    {
      scopes_.emplace_back();
      for (Stmt* s : b) { stmt(s); }
      scopes_.pop_back();
    }

    void Typer::stmt(Stmt* s)
    {
      if (!s) { return; }
      if (s->line > 0) { line_ = s->line; }
      switch (s->kind)
      {
        case SK::Declaration:
        {
          auto d = static_cast<Declaration*>(s);
          for (Declarator* v : d->declarators) { declarator(v, lc(d->scope)); }
          break;
        }
        case SK::Assignment:
        {
          auto a = static_cast<Assignment*>(s);
          expr(a->target);
          expr(a->value);
          Event e;
          e.kind = Event::Assign;
          e.target = a->target;
          e.op = a->op;
          e.value = a->value;
          event(e);
          break;
        }
        case SK::CallStmt:
          expr(static_cast<CallStmt*>(s)->call);
          break;
        case SK::ReturnStmt:
        {
          auto r = static_cast<ReturnStmt*>(s);
          expr(r->value);
          Event e;
          e.kind = Event::Return;
          e.value = r->value;
          event(e);
          break;
        }
        case SK::IfStmt:
        {
          auto i = static_cast<IfStmt*>(s);
          scopes_.emplace_back();
          if (i->header_decl) { declarator(i->header_decl, "local"); }
          for (Branch* br : i->branches)
          {
            line_ = s->line;
            expr(br->cond);
            body(br->body);
          }
          body(i->otherwise);
          scopes_.pop_back();
          break;
        }
        case SK::CaseStmt:
        {
          auto c = static_cast<CaseStmt*>(s);
          scopes_.emplace_back();
          if (c->subject_decl) { declarator(c->subject_decl, "local"); }
          if (c->subject_assign) { stmt(c->subject_assign); }
          for (Branch* br : c->branches)
          {
            expr(br->cond);
            body(br->body);
          }
          body(c->otherwise);
          scopes_.pop_back();
          break;
        }
        case SK::WhileStmt:
        {
          auto w = static_cast<WhileStmt*>(s);
          scopes_.emplace_back();
          if (w->header_decl) { declarator(w->header_decl, "local"); }
          expr(w->cond);
          body(w->body);
          scopes_.pop_back();
          break;
        }
        case SK::ForStmt:
        {
          auto f = static_cast<ForStmt*>(s);
          expr(f->from_);
          expr(f->to_);
          expr(f->step);
          scopes_.emplace_back();
          Var* v = f->var_local ? declare(f->var, false, NONE, "") : find(f->var);
          if (v)
          {
            Event e;
            e.kind = Event::Counter;
            e.var = v;
            event(e);
          }
          body(f->body);
          scopes_.pop_back();
          break;
        }
        case SK::ForInStmt:
        {
          auto f = static_cast<ForInStmt*>(s);
          walks_.emplace_back(f, cls_);
          expr(f->source);
          scopes_.emplace_back();
          Event e;
          e.kind = Event::ForIn;
          e.var = declare(f->elem, false, NONE, "");
          if (f->index) { e.index = declare(*f->index, false, NONE, ""); }
          e.value = f->source;
          event(e);
          body(f->body);
          scopes_.pop_back();
          break;
        }
        case SK::ForTimesStmt:
        {
          auto f = static_cast<ForTimesStmt*>(s);
          expr(f->count);
          body(f->body);
          break;
        }
        case SK::Modified:
        {
          auto m = static_cast<Modified*>(s);
          expr(m->cond);
          stmt(m->stmt);
          break;
        }
        case SK::Deferred:
          stmt(static_cast<Deferred*>(s)->stmt);
          break;
        case SK::UsingAlias:
        {
          auto u = static_cast<UsingAlias*>(s);
          expr(u->order);
          body(u->body);
          break;
        }
        case SK::WithObject:
        {
          auto w = static_cast<WithObject*>(s);
          withs_.push_back({ w->subject, cls_, typ_, line_ });
          expr(w->subject);
          body(w->body);
          break;
        }
        case SK::RawStmt:
        {
          // TL++ as written: a name in it may be given anything.
          for (const std::string& l : static_cast<RawStmt*>(s)->lines)
          {
            std::string w;
            for (std::size_t i = 0; i <= l.size(); i++)
            {
              int c = i < l.size() ? static_cast<unsigned char>(l[i]) : ' ';
              if (is_w(c))
              {
                w += static_cast<char>(c);
                continue;
              }
              if (Var* v = w.empty() ? nullptr : find(w))
              {
                Event e;
                e.kind = Event::Unknown;
                e.var = v;
                event(e);
              }
              w.clear();
            }
          }
          break;
        }
        case SK::TryStmt:
        {
          auto t = static_cast<TryStmt*>(s);
          body(t->body);
          if (t->error_var)
          {
            if (Var* v = find(*t->error_var))
            {
              Event e;
              e.kind = Event::Unknown;
              e.var = v;
              event(e);
            }
          }
          body(t->handler);
          body(t->finally);
          break;
        }
        case SK::TransactionStmt:
          body(static_cast<TransactionStmt*>(s)->body);
          break;
        case SK::SequenceStmt:
        {
          auto q = static_cast<SequenceStmt*>(s);
          body(q->body);
          if (q->error_var)
          {
            if (Var* v = find(*q->error_var))
            {
              Event e;
              e.kind = Event::Unknown;
              e.var = v;
              event(e);
            }
          }
          body(q->recover);
          break;
        }
        case SK::DefaultStmt:
          for (Assignment* a : static_cast<DefaultStmt*>(s)->pairs) { stmt(a); }
          break;
        default:
          for (Expr* e : exprs_of(s)) { expr(e); }
          break;
      }
    }

    void Typer::expr(Expr* e)
    {
      if (!e) { return; }
      switch (e->kind)
      {
        case EK::Name:
          if (Var* v = find(static_cast<Name*>(e)->name)) { names_[e] = v; }
          return;
        case EK::Lambda:
        case EK::CodeBlock:
        {
          auto b = static_cast<CodeBlock*>(e);
          scopes_.emplace_back();
          std::vector<Var*> ps;
          for (const std::string& n : b->params)
          {
            ps.push_back(declare(n, true, UNKNOWN, ""));
            ps.back()->block = true;
          }
          block_params_[e] = ps;
          for (Expr* x : b->body) { expr(x); }
          scopes_.pop_back();
          return;
        }
        case EK::AssignExpr:
        {
          auto a = static_cast<AssignExpr*>(e);
          expr(a->target);
          expr(a->value);
          Event ev;
          ev.kind = Event::Assign;
          ev.target = a->target;
          ev.op = a->op;
          ev.incdec = a->incdec;
          ev.value = a->value;
          event(ev);
          return;
        }
        case EK::Ref:
        {
          auto r = static_cast<Ref*>(e);
          expr(r->target);
          if (is(r->target, EK::Name))
          {
            if (Var* v = find(static_cast<Name*>(r->target)->name))
            {
              Event ev;
              ev.kind = Event::Ref;
              ev.var = v;
              event(ev);
            }
          }
          return;
        }
        case EK::Call:
        {
          auto c = static_cast<Call*>(e);
          std::string n = lc(c->name);
          bool make = types_.count(n) && !functions_.count(n);
          if (make) { makes_.push_back({ e, cls_, typ_, line_ }); }
          for (Expr* a : c->args)
          {
            if (is(a, EK::Lambda) || is(a, EK::CodeBlock))
            {
              verbs_.push_back({ e, cls_, typ_, line_ });
              break;
            }
          }
          for (Expr* a : c->args)
          {
            if (!make && is(a, EK::Named))
            {
              errors.push_back({ line_, "'" + static_cast<Named*>(a)->name + " =>': a field by its name, and "
                                        + c->name + "() makes no type's value." });
            }
            expr(a);
          }
          Event ev;
          ev.kind = Event::CallE;
          ev.call = c;
          event(ev);
          return;
        }
        case EK::Dot:
        case EK::DotCall:
          dots_.push_back({ e, cls_, typ_, line_ });
          for (Expr* x : subexprs(e)) { expr(x); }
          return;
        case EK::Member:
        case EK::SafeMember:
          if (is(e, EK::SafeMember)) { safes_.push_back({ e, cls_, typ_, line_ }); }
          if (!typ_.empty() && is(static_cast<Member*>(e)->base, EK::SelfRef))
          {
            errors.push_back({ line_, "'::" + static_cast<Member*>(e)->name + "' is a class's: in a type's method, a "
                                      + "field is '." + static_cast<Member*>(e)->name + "'." });
          }
          for (Expr* x : subexprs(e)) { expr(x); }
          return;
        case EK::MethodCall:
        case EK::SafeCall:
        {
          auto m = static_cast<MethodCall*>(e);
          if (is(e, EK::SafeCall)) { safes_.push_back({ e, cls_, typ_, line_ }); }
          if (!typ_.empty() && is(m->base, EK::SelfRef))
          {
            errors.push_back({ line_, "'::" + m->name + "()' is a class's: in a type's method, a method is '." + m->name
                                      + "()'." });
          }
          expr(m->base);
          for (Expr* a : m->args) { expr(a); }
          Event ev;
          ev.kind = Event::MethodE;
          ev.method = m;
          event(ev);
          return;
        }
        case EK::HashIndex:
          hashes_.emplace_back(static_cast<HashIndex*>(e), cls_);
          for (Expr* x : subexprs(e)) { expr(x); }
          return;
        case EK::Pipeline:
        {
          auto p = static_cast<Pipeline*>(e);
          verbs_.push_back({ e, cls_, typ_, line_ });
          expr(p->source);
          for (std::size_t i = 0; i < p->stages.size(); i++)
          {
            for (Expr* a : p->stages[i]->args) { expr(a); }
            Event ev;
            ev.kind = Event::CallE;
            ev.call = p->stages[i];
            ev.chain = p;
            ev.stage = i;
            event(ev);
          }
          return;
        }
        default:
          for (Expr* x : subexprs(e)) { expr(x); }
          return;
      }
    }

    // ---- what each name holds -----------------------------------------------
    // Every value a Local or a Static is given, over and over until nothing
    // changes: what it holds, when they agree.
    void Typer::infer()
    {
      bool changed = true;
      auto give = [&](Var* v, const std::string& t)
      {
        if (!v || v->pinned) { return; }
        std::string n = join(v->type, t);
        if (n != v->type)
        {
          v->type = n;
          changed = true;
        }
      };
      for (int round = 0; changed && round < 20; round++)
      {
        changed = false;
        for (const Unit& u : units_)
        {
          cls_ = u.cls;
          for (const Event& e : u.events)
          {
            switch (e.kind)
            {
              case Event::Decl:
                if (e.decl->init) { give(e.var, type(e.decl->init)); }
                break;
              case Event::Assign:
              {
                if (!is(e.target, EK::Name)) { break; }
                auto it = names_.find(e.target);
                if (it == names_.end()) { break; }
                Var* v = it->second;
                if (!e.incdec.empty()) { give(v, binop("+", v->type, "N")); }
                else if (e.op == ":=" || e.op == "=" || e.op == "?=") { give(v, type(e.value)); }
                else { give(v, binop(chop(e.op), v->type, type(e.value))); }
                break;
              }
              case Event::Counter:
                give(e.var, "N");
                break;
              case Event::ForIn:
              {
                // Over a hash, a set, a bag, a JSON object: each key, and
                // what it holds there.
                std::string t = type(e.value);
                char k = kind(t);
                if (keyed(k) || k == 'J')
                {
                  give(e.var, k == 'J' ? "C" : bare(key_of(t)));
                  give(e.index, k == 'J' ? UNKNOWN : value_of(t));
                  break;
                }
                give(e.var, elem_in(e.value));
                give(e.index, "N");
                break;
              }
              case Event::Unknown:
              case Event::Ref:
                give(e.var, UNKNOWN);
                break;
              default:
                break;
            }
          }
        }
      }
      cls_.clear();
      for (const std::unique_ptr<Var>& v : vars_)
      {
        if (!v->pinned && v->type == NONE) { v->type = UNKNOWN; }
      }
    }

    // What a 'for ... in' gives its name, walking source.
    std::string Typer::elem_in(const Expr* source)
    {
      if (is(source, EK::Interval)) { return "N"; }
      std::string t = type(source);
      if (t == NONE) { return NONE; }
      if (t == "C") { return "C"; }
      return elem_of(t);
    }

    // ---- what an expression is ----------------------------------------------
    std::string Typer::type(const Expr* e)
    {
      if (!e) { return UNKNOWN; }
      switch (e->kind)
      {
        case EK::Literal:
        {
          auto l = static_cast<const Literal*>(e);
          if (l->type == "Numeric") { return "N"; }
          if (l->type == "Character") { return "C"; }
          if (l->type == "Logical") { return "L"; }
          if (l->type == "Variant" && lc(l->text) == "nil") { return NIL; }
          return UNKNOWN;
        }
        case EK::Interp:
          return "C";
        case EK::ArrayLit:
        {
          auto a = static_cast<const ArrayLit*>(e);
          return a->elem.empty() ? "A" : "A<" + a->elem + ">";
        }
        case EK::HashLit:
        {
          auto h = static_cast<const HashLit*>(e);
          if (h->set_kind)
          {
            std::string k(1, h->set_kind);
            return h->key_type.empty() ? k : k + "<" + h->key_type + ">";
          }
          return h->key_type.empty() ? "H" : "H<" + h->key_type + "," + h->value_type + ">";
        }
        case EK::JsonLit:
          return "J";
        case EK::CodeBlock:
        case EK::Lambda:
          return "B";
        case EK::Name:
        {
          auto it = names_.find(e);
          if (it != names_.end()) { return it->second->type; }
          return self(e) ? class_type(cls_) : UNKNOWN;
        }
        case EK::SelfRef:
          return cls_.empty() ? UNKNOWN : class_type(cls_);
        case EK::Index:
        {
          auto x = static_cast<const Index*>(e);
          std::string t = type(x->base);
          for (std::size_t i = 0; i < x->indices.size(); i++) { t = elem_of(t); }
          return t;
        }
        case EK::HashIndex:
          return value_of(type(static_cast<const HashIndex*>(e)->base));
        case EK::Binary:
        {
          auto b = static_cast<const Binary*>(e);
          if (LOGICAL.count(b->op)) { return "L"; }
          if (b->op[0] == '(') { return set_op(b->op, type(b->left), type(b->right)); }
          return binop(b->op, b->left ? type(b->left) : UNKNOWN, type(b->right));
        }
        case EK::AssignExpr:
        {
          auto a = static_cast<const AssignExpr*>(e);
          if (!a->incdec.empty()) { return binop("+", type(a->target), "N"); }
          if (a->op == ":=" || a->op == "=") { return type(a->value); }
          return binop(chop(a->op), type(a->target), type(a->value));
        }
        case EK::Dot:
        {
          auto d = static_cast<const Dot*>(e);
          std::string b = type(d->base);
          if (b == NONE) { return NONE; }
          const TypeData* f = field_of(b, d->name);
          return f ? f->type : UNKNOWN;
        }
        case EK::DotCall:
        {
          auto d = static_cast<const DotCall*>(e);
          std::string b = type(d->base);
          if (b == NONE) { return NONE; }
          const TypeInfo* ti = type_of(b);
          if (!ti) { return UNKNOWN; }
          auto m = ti->methods.find(lc(d->name));
          if (m == ti->methods.end()) { return UNKNOWN; }
          const FunctionDef* f = m->second;
          if (!f->ret_container.empty()) { return f->ret_container; }
          return f->rettype_word ? word_type(*f->rettype_word) : UNKNOWN;
        }
        case EK::Named:
          return type(static_cast<const Named*>(e)->value);
        case EK::Call:
        {
          // 'Order()', a class of the file's: the object New() is then
          // called on. 'Item(...)', a type's: a value of it.
          auto c = static_cast<const Call*>(e);
          std::string n = lc(c->name);
          if (types_.count(n) && !functions_.count(n)) { return "T:" + n; }
          if (c->args.empty() && classes_.count(n) && !functions_.count(n)) { return class_type(n); }
          return call_type(n, c->args, nullptr);
        }
        case EK::Pipeline:
        {
          auto p = static_cast<const Pipeline*>(e);
          return chain_type(p, p->stages.size());
        }
        case EK::Guard:
        {
          auto g = static_cast<const Guard*>(e);
          return binop("?:", type(g->expr), type(g->fallback));
        }
        case EK::SafeMember:
        {
          auto m = static_cast<const Member*>(e);
          std::string b = type(m->base);
          if (typed_value(b))
          {
            const TypeData* f = field_of(b, m->name);
            return f ? f->type : UNKNOWN;
          }
          return UNKNOWN;
        }
        case EK::SafeCall:
        {
          auto m = static_cast<const MethodCall*>(e);
          const TypeInfo* ti = type_of(type(m->base));
          if (!ti) { return UNKNOWN; }
          auto f = ti->methods.find(lc(m->name));
          if (f == ti->methods.end()) { return UNKNOWN; }
          if (!f->second->ret_container.empty()) { return f->second->ret_container; }
          return f->second->rettype_word ? word_type(*f->second->rettype_word) : UNKNOWN;
        }
        case EK::Member:
        {
          // '::x' in a method, 'o:x' of an object of a class of the file: the
          // Data, as its class declares it.
          auto m = static_cast<const Member*>(e);
          const ClassData* d = data_of(obj_class(m->base), m->name);
          return d ? d->type : UNKNOWN;
        }
        case EK::MethodCall:
        {
          // 'Name():New()': THashMap's a hash, JsonObject's a JSON, a class of
          // the file's an object of it, any other an object. '::m()', 'o:m()'
          // of an object of a class of the file: what m is declared to give.
          auto m = static_cast<const MethodCall*>(e);
          if (lc(m->name) == "new" && is(m->base, EK::Call))
          {
            auto b = static_cast<const Call*>(m->base);
            std::string c = lc(b->name);
            if (b->args.empty() && classes_.count(c) && !functions_.count(c)) { return class_type(c); }
            return c == "thashmap" ? "H" : c == "jsonobject" ? "J" : "O";
          }
          std::string c = obj_class(m->base);
          return c.empty() ? UNKNOWN : method_type(c, m->name);
        }
        case EK::ExprList:
        {
          auto l = static_cast<const ExprList*>(e);
          return l->items.empty() ? UNKNOWN : type(l->items.back());
        }
        case EK::AliasField:
          return field_type(static_cast<const AliasField*>(e));
        default:
          return UNKNOWN;
      }
    }

    // A field's type, from the dictionary.
    std::string Typer::field_type(const AliasField* f) const
    {
      if (!f->alias || f->field.empty() || f->base) { return UNKNOWN; }
      auto a = dictionary_.find(uc(*f->alias));
      if (a == dictionary_.end()) { return UNKNOWN; }
      auto x = a->second.find(uc(f->field));
      if (x == a->second.end()) { return UNKNOWN; }
      const std::string& t = x->second.type;
      if (t == "C" || t == "M") { return "C"; }
      if (t == "N" || t == "D" || t == "L") { return t; }
      return UNKNOWN;
    }

    // What a call gives -- 'fed' the type of what a chain feeds it, its first
    // argument then.
    std::string Typer::call_type(const std::string& name, const std::vector<Expr*>& args, const std::string* fed)
    {
      std::size_t off = fed ? 1 : 0;
      auto arg = [&](std::size_t i) -> std::string
      {
        if (fed && i == 0) { return *fed; }
        return i - off < args.size() ? type(args[i - off]) : UNKNOWN;
      };
      auto arg_expr = [&](std::size_t i) -> const Expr*
      {
        return i >= off && i - off < args.size() ? args[i - off] : nullptr;
      };
      if (auto r = RETURNS.find(name); r != RETURNS.end()) { return r->second; }
      if (name == "round" || name == "noround" || name == "int" || name == "abs")
      {
        std::string a = arg(0);
        return a == NONE ? NONE : a == "F" ? "F" : "N";
      }
      if (name == "max" || name == "min" || name == "if" || name == "iif")
      {
        std::size_t i = name[0] == 'm' ? 0 : 1;
        return binop("?:", arg(i), arg(i + 1));
      }
      if (name == "aclone") { return unfixed(arg(0)); }
      if (name == "asort" || name == "asize" || name == "adel" || name == "ains" || name == "afill") { return arg(0); }
      if (name == "aadd" || name == "acopy") { return arg(1); }
      if (name == "atail") { return elem_of(arg(0)); }
      // The runtime's verbs: sets and bags.
      if (name == "setof" || name == "bagof")
      {
        char k = name[0] == 's' ? 'S' : 'M';
        if (args.size() + off == 1) { return keys_of(k, arg(0), "-"); }
        std::string m = NIL;
        for (std::size_t i = 0; i < args.size() + off; i++)
        {
          std::string t = bare(arg(i));
          if (t == NONE) { return NONE; }
          m = m.empty() ? t : t.empty() || t == m ? m : UNKNOWN;
        }
        return m.empty() || m == UNKNOWN || box(kind(m)) ? std::string(1, k) : std::string(1, k) + "<" + m + ">";
      }
      static const std::unordered_map<std::string, std::string> set_ops =
      {
        { "union", "(|)" }, { "intersect", "(&)" }, { "minus", "(-)" }, { "symdiff", "(^)" }, { "bagsum", "(+)" },
        { "bagprod", "(.)" }, { "subset", "(<=)" }, { "psubset", "(<)" }, { "superset", "(>=)" },
        { "psuperset", "(>)" }, { "sameset", "(==)" },
      };
      if (auto o = set_ops.find(name); o != set_ops.end()) { return set_op(o->second, arg(0), arg(1)); }
      if (name == "elems" || name == "totalof") { return "N"; }
      if (name == "heap" || name == "heapof" || name == "queue") { return "O"; }
      if (name == "kxxv") { return array_of(member_of(arg(0))); }
      if (name == "minpairs" || name == "maxpairs") { return "A<A>"; }
      // The runtime's verbs.
      std::string s = arg(0);
      // A copy: fixed no more, but for what it holds.
      if (KEEPS.count(name)) { return s == NONE ? NONE : kind(s) != 'A' ? "A" : fixed(s) ? array_of(elem_of(s)) : s; }
      if (name == "map")
      {
        const Expr* f = arg_expr(1);
        if (is(f, EK::Lambda) || is(f, EK::CodeBlock))
        {
          auto b = static_cast<const CodeBlock*>(f);
          auto ps = block_params_.find(f);
          if (b->body.empty() || ps == block_params_.end()) { return "A"; }
          std::string t = elem_of(s);
          std::vector<std::string> was;
          for (Var* v : ps->second) { was.push_back(v->type); }
          if (!ps->second.empty()) { ps->second[0]->type = t == NONE ? UNKNOWN : t; }
          std::string r = type(b->body.back());
          for (std::size_t i = 0; i < ps->second.size(); i++) { ps->second[i]->type = was[i]; }
          return s == NONE ? NONE : array_of(r);
        }
        if (is(f, EK::Name) && !names_.count(f))
        {
          std::string n = lc(static_cast<const Name*>(f)->name);
          if (auto r = RETURNS.find(n); r != RETURNS.end()) { return array_of(r->second); }
          if (auto r = returns_.find(n); r != returns_.end()) { return array_of(r->second); }
        }
        return "A";
      }
      if (name == "count") { return "N"; }
      if (name == "asum" || name == "aprod") { return elem_of(s) == "F" ? "F" : "N"; }
      if (name == "amax" || name == "amin" || name == "first" || name == "maxby" || name == "minby")
      {
        return elem_of(s);
      }
      if (name == "anyof" || name == "allof" || name == "noneof") { return "L"; }
      if (name == "chunks" || name == "chunkby" || name == "pairwise")
      {
        return s == NONE ? NONE : generic(s) && kind(s) == 'A' ? "A<" + s + ">" : "A<A>";
      }
      if (name == "enumerate" || name == "zip" || name == "pairs") { return "A<A>"; }
      if (name == "flatten" || name == "expand") { return "A"; }
      if (name == "keys") { return s == NONE ? NONE : array_of(key_of(s)); }
      if (name == "values") { return s == NONE ? NONE : array_of(value_of(s)); }
      if (name == "split") { return "A<C>"; }
      if (name == "join") { return "C"; }
      if (name == "starts" || name == "ends" || name == "contains") { return "L"; }
      if (auto r = returns_.find(name); r != returns_.end()) { return r->second; }
      return UNKNOWN;
    }

    // What a chain gives after its first n stages.
    std::string Typer::chain_type(const Pipeline* p, std::size_t stages)
    {
      std::string t = type(p->source);
      for (std::size_t i = 0; i < stages && i < p->stages.size(); i++)
      {
        const Call* c = p->stages[i];
        t = call_type(lc(c->name), c->args, &t);
      }
      return t;
    }

    // ---- what goes in -------------------------------------------------------
    // A value that goes where slot is wanted -- who: what it goes into, said
    // so; a literal array or hash, each of what it holds.
    void Typer::into(const Expr* e, const std::string& slot, const std::string& who, bool key)
    {
      if (!e || slot.empty() || slot == UNKNOWN || is(e, EK::Ref) || is(e, EK::Omitted)) { return; }
      if (typed_value(slot) && is(e, EK::ArrayLit))
      {
        errors.push_back({ line_, who + ": an array written out is none -- " + show(slot) + "(...) makes one." });
        return;
      }
      // setOf(), bagOf(): an empty set or bag, of whatever is wanted.
      if (is(e, EK::Call) && static_cast<const Call*>(e)->args.empty())
      {
        std::string n = lc(static_cast<const Call*>(e)->name);
        if ((n == "setof" && kind(slot) == 'S') || (n == "bagof" && kind(slot) == 'M')) { return; }
      }
      if (is(e, EK::ArrayLit) && static_cast<const ArrayLit*>(e)->elem.empty() && generic(slot) && kind(slot) == 'A')
      {
        std::string t = elem_of(slot);
        for (const Expr* x : static_cast<const ArrayLit*>(e)->items) { into(x, t, who); }
        return;
      }
      if (is(e, EK::HashLit) && static_cast<const HashLit*>(e)->key_type.empty() && generic(slot) && kind(slot) == 'H')
      {
        for (const KeyValue* kv : static_cast<const HashLit*>(e)->pairs)
        {
          into(kv->key, key_of(slot), who, true);
          into(kv->value, value_of(slot), who);
        }
        return;
      }
      std::string t = type(e);
      std::string what = key ? "this key" : "this";
      switch (fits(t, slot))
      {
        case Fit::Wrong:
          errors.push_back({ line_, who + ": " + what + " is " + shown(t) + ", not " + shown(slot) + "." });
          break;
        case Fit::Unknown:
          warnings.push_back({ line_, who + ": xc cannot tell that " + what + " is " + shown(slot) + "." });
          break;
        case Fit::Ok:
          break;
      }
    }

    // A value that goes into a field: into() for what xc checks of arrays,
    // hashes, objects and types; for TL++'s types, what is known to be
    // another -- a Decimal aside (decimal.cpp).
    void Typer::put(const Expr* e, const std::string& slot, const std::string& who)
    {
      if (!e || slot.empty()) { return; }
      if (box(kind(slot)) || checked_slot(slot) || fixed(slot))
      {
        into(e, slot, who);
        return;
      }
      std::string t = type(e);
      if (bare(t) == "F" || slot == "F" || is(e, EK::Ref) || is(e, EK::Omitted)) { return; }
      if (fits(t, slot) == Fit::Wrong) { errors.push_back({ line_, who + ": this is " + shown(t) + "." }); }
    }

    // What an element written to belongs to, said so: the name it is read
    // from, and what that is.
    std::string Typer::who_of(const Expr* base)
    {
      const Expr* root = base;
      while (is(root, EK::Index) || is(root, EK::HashIndex))
      {
        root = is(root, EK::Index) ? static_cast<const Index*>(root)->base : static_cast<const HashIndex*>(root)->base;
      }
      if (is(root, EK::Name)) { return "'" + static_cast<const Name*>(root)->name + "' is " + shown(type(root)); }
      if (is(root, EK::Member) && !obj_class(static_cast<const Member*>(root)->base).empty())
      {
        return member_who(static_cast<const Member*>(root));
      }
      std::string t = type(base);
      return std::string(kind(t) == 'H' ? "the hash" : "the array") + " is " + shown(t);
    }

    // A fixed array or hash written into, said so: the name it is, or the one
    // it is read from.
    std::string Typer::fixed_who(const Expr* written)
    {
      std::string t = type(written);
      std::string what = bare(t) == UNKNOWN ? "a fixed array or hash" : shown(t);
      if (is(written, EK::Name))
      {
        // Declared so, or given one somewhere.
        auto it = names_.find(written);
        bool declared = it != names_.end() && fixed(it->second->container);
        return "'" + static_cast<const Name*>(written)->name + (declared ? "' is " : "' may hold ") + what;
      }
      if (is(written, EK::Member) && !obj_class(static_cast<const Member*>(written)->base).empty())
      {
        return member_who(static_cast<const Member*>(written));
      }
      const Expr* root = written;
      while (is(root, EK::Index) || is(root, EK::HashIndex))
      {
        root = is(root, EK::Index) ? static_cast<const Index*>(root)->base : static_cast<const HashIndex*>(root)->base;
      }
      if (is(root, EK::Name)) { return "'" + static_cast<const Name*>(root)->name + "' holds " + what + " here"; }
      if (is(root, EK::Member) && !obj_class(static_cast<const Member*>(root)->base).empty())
      {
        return "'" + member_name(static_cast<const Member*>(root)) + "' holds " + what + " here";
      }
      return "this is " + what;
    }

    // A fixed name, as its declaration says: "'aX' is an Array<fixed n>
    // (declared on line 3)".
    std::string Typer::declared_as(const Var* v) const
    {
      return "'" + v->name + "' is " + shown(v->container) + " (declared on line " + std::to_string(v->line) + ")";
    }

    // A function that writes into what it is given -- how: its name --, given
    // a fixed array or hash. fed: the type of what a chain feeds it.
    void Typer::writes(const Expr* into_, const std::string& how, const std::string* fed)
    {
      std::string t = fed ? *fed : type(into_);
      if (!fixed(t)) { return; }
      std::string who = into_ ? fixed_who(into_)
                              : "this is " + (bare(t) == UNKNOWN ? std::string("a fixed array or hash") : shown(t));
      errors.push_back({ line_, who + ": " + how + "() would write into it." });
    }

    // AAdd(), AFill(), ACopy(), and a function of the file whose parameters
    // are typed arrays or hashes: what each puts in, or is given.
    void Typer::call_check(const std::string& name, const std::vector<Expr*>& args, const Expr* fed_expr,
                           const std::string* fed)
    {
      std::size_t off = fed ? 1 : 0;
      auto arg = [&](std::size_t i) -> const Expr*
      {
        if (fed && i == 0) { return fed_expr; }
        return i - off < args.size() ? args[i - off] : nullptr;
      };
      auto arg_type = [&](std::size_t i) -> std::string
      {
        if (fed && i == 0) { return *fed; }
        return type(arg(i));
      };
      // TL++'s functions that change the array they are given.
      static const std::unordered_map<std::string, std::string> writers =
      {
        { "aadd", "AAdd" }, { "adel", "ADel" }, { "ains", "AIns" }, { "asize", "ASize" }, { "afill", "AFill" },
        { "asort", "ASort" },
      };
      if (auto w = writers.find(name); w != writers.end())
      {
        std::string t = arg_type(0);
        if (fixed(t))
        {
          writes(arg(0), w->second, fed && !fed_expr ? fed : nullptr);
          return;
        }
        // A hash, a set, a bag, a value known to be no array.
        if (!t.empty() && t != UNKNOWN && t != NONE && kind(t) != 'A' && kind(t) != 'O')
        {
          std::string who = arg(0) && is(arg(0), EK::Name) ? "'" + static_cast<const Name*>(arg(0))->name + "' is "
                                                            : "this is ";
          errors.push_back({ line_, who + shown(t) + ": " + w->second + "() takes an array." });
          return;
        }
        if ((name == "aadd" || name == "afill") && generic(t) && kind(t) == 'A' && arg(1))
        {
          into(arg(1), elem_of(t), fed && !fed_expr ? "the array is " + shown(t) : who_of(arg(0)));
        }
        return;
      }
      if (name == "acopy")
      {
        std::string t = type(arg(1));
        if (fixed(t))
        {
          writes(arg(1), "ACopy");
          return;
        }
        if (generic(t) && kind(t) == 'A' && arg(0)) { into(arg(0), t, who_of(arg(1))); }
        return;
      }
      auto f = functions_.find(name);
      if (f == functions_.end()) { return; }
      const std::vector<const Param*>& ps = f->second.params;
      for (std::size_t i = 0; i < ps.size(); i++)
      {
        std::string slot = slot_of(ps[i]);
        if (slot.empty() || !arg(i)) { continue; }
        std::string who = "the parameter '" + ps[i]->name + "' of " + f->second.name + "() is " + shown(slot);
        if (fed && i == 0)
        {
          switch (fits(*fed, slot))
          {
            case Fit::Wrong:
              errors.push_back({ line_, who + ": this is " + shown(*fed) + ", not " + shown(slot) + "." });
              break;
            case Fit::Unknown:
              warnings.push_back({ line_, who + ": xc cannot tell that this is " + shown(slot) + "." });
              break;
            case Fit::Ok:
              break;
          }
          continue;
        }
        into(arg(i), slot, who);
      }
    }

    void Typer::check(const Unit& u)
    {
      ret_ = u.ret;
      ret_name_ = u.name;
      cls_ = u.cls;
      for (const Event& e : u.events)
      {
        line_ = e.line;
        switch (e.kind)
        {
          case Event::Decl:
            if (fixed(e.var->container) && (!e.decl->init || e.decl->init_made))
            {
              errors.push_back({ line_, "'" + e.var->name + "' is " + shown(e.var->container)
                                        + ": it takes its value where it is declared." });
            }
            else if (!e.var->container.empty() && e.decl->init && !e.decl->init_made)
            {
              into(e.decl->init, e.var->container, "'" + e.var->name + "' is " + shown(e.var->container));
            }
            break;
          case Event::Counter:
            if (fixed(e.var->container))
            {
              errors.push_back({ line_, declared_as(e.var) + " and cannot be assigned." });
            }
            break;
          case Event::Ref:
            if (fixed(e.var->container))
            {
              errors.push_back({ line_, declared_as(e.var) + " and cannot be passed by reference." });
            }
            break;
          case Event::Assign:
          {
            if (is(e.target, EK::Name))
            {
              auto it = names_.find(e.target);
              Var* v = it != names_.end() ? it->second : nullptr;
              if (v && fixed(v->container))
              {
                errors.push_back({ line_, declared_as(v) + " and cannot be assigned." });
                break;
              }
              if (v && !v->container.empty() && e.incdec.empty() && (e.op == ":=" || e.op == "=" || e.op == "?="))
              {
                into(e.value, v->container, "'" + v->name + "' is " + shown(v->container));
              }
              break;
            }
            if (is(e.target, EK::Dot))
            {
              // 'x.f := v': as the type declares it -- a '<const>' one only
              // where a value is made.
              auto d = static_cast<const Dot*>(e.target);
              const TypeInfo* ti = type_of(type(d->base));
              const TypeData* f = field_of(type(d->base), d->name);
              if (!f) { break; }
              if (f->constant)
              {
                std::string n = dot_name(d);
                errors.push_back({ line_, "'" + (n.empty() ? "." + d->name : n) + "' is <const>: it takes its value "
                                          + "where " + shown(ti ? "T:" + lc(ti->name) : UNKNOWN) + " is made." });
                break;
              }
              if (e.incdec.empty() && (e.op == ":=" || e.op == "=" || e.op == "?="))
              {
                put(e.value, f->slot, field_who(d));
              }
              break;
            }
            if (is(e.target, EK::Member))
            {
              // '::x := v', 'o:x := v': as the class declares it -- a fixed
              // one only in the constructor, its own.
              auto m = static_cast<const Member*>(e.target);
              const ClassData* d = data_of(obj_class(m->base), m->name);
              if (!d || d->container.empty()) { break; }
              bool own = self(m->base) && u.ctor;
              if (fixed(d->container) && !(own && e.incdec.empty() && (e.op == ":=" || e.op == "=")))
              {
                errors.push_back({ line_, "'" + member_name(m) + "' is " + shown(d->container) + " (declared on line "
                                          + std::to_string(d->line) + "): only the constructor gives it its value." });
                break;
              }
              if (e.incdec.empty() && (e.op == ":=" || e.op == "=" || e.op == "?="))
              {
                into(e.value, d->container, member_who(m));
              }
              break;
            }
            const Expr* base = is(e.target, EK::Index) ? static_cast<const Index*>(e.target)->base
                               : is(e.target, EK::HashIndex) ? static_cast<const HashIndex*>(e.target)->base
                                                             : nullptr;
            if (!base) { break; }
            if (fixed(type(base)))
            {
              errors.push_back({ line_, fixed_who(base) + ": nothing in it may be written." });
              break;
            }
            std::string slot = type(e.target);
            if (slot == UNKNOWN || slot == NONE) { break; }
            std::string who = who_of(base);
            if (is(e.target, EK::HashIndex))
            {
              into(static_cast<const HashIndex*>(e.target)->key, key_of(type(base)), who, true);
            }
            if (!e.incdec.empty()) { break; }
            if (e.op == ":=" || e.op == "=" || e.op == "?=")
            {
              into(e.value, slot, who);
              break;
            }
            // 'a[i] += v': what the operator makes of the two.
            std::string v = type(e.value);
            std::string r = binop(chop(e.op), slot, v);
            if (v == UNKNOWN || v == NONE)
            {
              warnings.push_back({ line_, who + ": xc cannot tell that this is " + shown(slot) + "." });
            }
            else if (r == UNKNOWN || fits(r, slot) == Fit::Wrong)
            {
              errors.push_back({ line_, who + ": this is " + shown(v) + ", and '" + e.op + "' makes no " + shown(slot)
                                        + " of it." });
            }
            break;
          }
          case Event::CallE:
          {
            if (e.chain)
            {
              std::string fed = chain_type(e.chain, e.stage);
              const Expr* fed_expr = e.stage == 0 ? e.chain->source : nullptr;
              call_check(lc(e.call->name), e.call->args, fed_expr, &fed);
            }
            else
            {
              call_check(lc(e.call->name), e.call->args, nullptr, nullptr);
            }
            break;
          }
          case Event::MethodE:
          {
            const MethodCall* m = e.method;
            std::string t = type(m->base);
            // THashMap's methods that change it.
            static const std::unordered_map<std::string, std::string> writers =
            {
              { "set", "Set" }, { "del", "Del" }, { "clean", "Clean" }, { "clear", "Clear" }, { "remove", "Remove" },
            };
            auto w = writers.find(lc(m->name));
            if (w != writers.end() && fixed(t))
            {
              writes(m->base, w->second);
              break;
            }
            if (lc(m->name) == "set" && m->args.size() >= 2 && generic(t) && keyed(kind(t)))
            {
              std::string who = who_of(m->base);
              into(m->args[0], key_of(t), who, true);
              into(m->args[1], value_of(t), who);
            }
            // '::m(...)', 'o:m(...)' of an object of a class of the file:
            // what its parameters are declared as.
            std::string c = obj_class(m->base);
            if (!c.empty())
            {
              std::vector<const Param*> ps = method_params(c, m->name);
              for (std::size_t i = 0; i < ps.size() && i < m->args.size(); i++)
              {
                std::string slot = slot_of(ps[i]);
                if (slot.empty()) { continue; }
                into(m->args[i], slot, "the parameter '" + ps[i]->name + "' of " + method_who(m, c) + " is "
                                         + shown(slot));
              }
            }
            break;
          }
          case Event::Return:
            if (!ret_.empty() && e.value) { into(e.value, ret_, ret_name_ + "() returns " + shown(ret_)); }
            break;
          default:
            break;
        }
      }
    }
  }

  Checked typed_problems(const Program* p, const Dictionary& dictionary)
  {
    Typer t(p, dictionary);
    t.run();
    type_words = nullptr;
    type_bases = nullptr;
    return Checked{ std::move(t.errors), std::move(t.warnings) };
  }
}
