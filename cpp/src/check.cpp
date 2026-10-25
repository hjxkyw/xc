// xc -- what xtpl refuses although it parses (see check.h).
//
// A port of the Raku xc's lib/XC/Check.rakumod and lib/XC/Types.rakumod
// (README.md, History), routine for routine and in the same order: the
// comments there say why each rule they share is what it is, and are not
// repeated here. What two findings on one line come
// out in is the order they are found in, so the walk is the Raku one.

#include "check.h"

#include <algorithm>
#include <deque>
#include <fstream>
#include <functional>
#include <initializer_list>
#include <sstream>
#include <stdexcept>
#include <unordered_set>

#include "chains.h"
#include "chars.h"
#include "decimal.h"
#include "parser.h"
#include "typed.h"
#include "walk.h"

namespace xc
{
  namespace
  {
    using Set = std::unordered_set<std::string>;

    // The comparisons a field and a literal are checked in.
    const Set COMPARE = { "==", "!=", "<>", ">=", "<=", "#", "=", ">", "<", "$" };

    // The calls that open a work area, when given its name as a string.
    const Set OPENERS = { "dbselectarea", "dbusearea", "chkfile" };

    // Words that are never a variable (xtpl's 'known_words').
    const Set KNOWN =
    {
      "nil", "to", "step", "exit", "loop", "self", "super", "iif", "in", "and", "or", "not", "t", "f",
      "class", "data", "method", "endclass", "begin", "sequence", "recover", "always", "endsequence",
      "try", "catch", "endtry", "case", "endcase", "switch", "default", "parameters", "then", "as",
      "from", "of", "nonempty", "_super",
    };

    // What a chain cannot walk: a type that holds one value.
    const Set SCALAR_TYPES = { "numeric", "character", "logical", "date", "json" };

    std::string num(int n) { return std::to_string(n); }

    bool has(const std::vector<std::string>& v, const char* w)
    {
      return std::find(v.begin(), v.end(), w) != v.end();
    }

    bool starts_with(const std::string& s, const char* p)
    {
      return s.rfind(p, 0) == 0;
    }

    // A literal of any kind: XC::AST's Literal and the classes made from it.
    bool is_literal(const Expr* e)
    {
      if (!e) { return false; }
      switch (e->kind)
      {
        case EK::Literal: case EK::ArrayLit: case EK::Interp: case EK::JsonLit: case EK::HashLit:
        case EK::CodeBlock: case EK::Lambda:
          return true;
        default:
          return false;
      }
    }

    bool is(const Expr* e, EK k) { return e && e->kind == k; }
    bool is_code_block(const Expr* e) { return is(e, EK::CodeBlock) || is(e, EK::Lambda); }
    bool is_member(const Expr* e) { return is(e, EK::Member) || is(e, EK::SafeMember); }

    const std::string& name_of(const Expr* e) { return static_cast<const Name*>(e)->name; }

    // A literal's text without its quotes ('substr(1, *-1)').
    std::string unquoted(const std::string& t)
    {
      return t.size() >= 2 ? t.substr(1, t.size() - 2) : std::string();
    }

    // Raku's .words.
    std::vector<std::string> words(const std::string& s)
    {
      std::vector<std::string> out;
      std::size_t i = 0;
      while (i < s.size())
      {
        while (i < s.size() && (CHAR_CLASS[static_cast<unsigned char>(s[i])] & C_S)) { i++; }
        std::size_t b = i;
        while (i < s.size() && !(CHAR_CLASS[static_cast<unsigned char>(s[i])] & C_S)) { i++; }
        if (i > b) { out.push_back(s.substr(b, i - b)); }
      }
      return out;
    }

    // The first n characters of a text: a "\r\n" is one.
    std::string first_chars(const std::string& t, std::size_t n)
    {
      std::size_t i = 0;
      std::size_t k = 0;
      while (i < t.size() && k < n)
      {
        i += (t[i] == '\r' && i + 1 < t.size() && t[i + 1] == '\n') ? 2 : 1;
        k++;
      }
      return t.substr(0, i);
    }

    // ---- types (XC::Types) --------------------------------------------------
    const Set LOGICAL_OPS =
    {
      "==", "=", "!=", "<>", "#", "<", ">", "<=", ">=", "$", ".and.", ".or.", "!", "in", "has", "%%",
    };
    const Set NUMERIC_OPS = { "*", "/", "%", "**", "^", "neg" };

    // The type of an expression, or '?' when it cannot be told from here.
    std::string type_of(const Expr* e)
    {
      if (!e) { return "?"; }
      if (is_literal(e)) { return static_cast<const Literal*>(e)->type; }
      if (e->kind != EK::Binary) { return "?"; }
      auto b = static_cast<const Binary*>(e);
      if (LOGICAL_OPS.count(b->op)) { return "Logical"; }
      if (NUMERIC_OPS.count(b->op)) { return "Numeric"; }
      if (b->op == "+" || b->op == "-")
      {
        std::string l = type_of(b->left);
        std::string r = type_of(b->right);
        if (l == r && (l == "Numeric" || l == "Character")) { return l; }
      }
      return "?";
    }

    // What is wrong with a declarator's value for its type, if anything. A
    // Decimal -- a Numeric in the tree, as the Raku xc has it -- is a type of
    // its own to TL++, 'F': a number that goes into one is decimal.cpp's to
    // judge -- xc makes a literal one, and refuses a Numeric.
    std::optional<std::string> type_problem(const Declarator* v, bool advpl)
    {
      // A typed array's or hash's value: typed.cpp's to say.
      if (v->declared == "?" || !v->init || !v->container.empty()) { return std::nullopt; }
      std::string found = type_of(v->init);
      if (found == "?" || v->declared == "Variant") { return std::nullopt; }
      if (is_literal(v->init) && lc(static_cast<const Literal*>(v->init)->text) == "nil") { return std::nullopt; }
      std::vector<std::string> w = words(v->typespec_text.value_or(""));
      bool decimal = !advpl && w.size() > 1 && lc(w[1]) == "decimal";
      std::string declared = decimal ? "Decimal" : v->declared;
      if (found == declared) { return std::nullopt; }
      if (decimal && found == "Numeric") { return std::nullopt; }
      return "'" + v->name + "' is declared as " + declared + ", but its initial value is " + found + ".";
    }

    // ---- small subs ---------------------------------------------------------
    // A literal that holds one value: not an array, a hash, a JSON or a block.
    bool is_scalar(const Expr* l)
    {
      return !(is(l, EK::ArrayLit) || is(l, EK::HashLit) || is(l, EK::JsonLit) || is_code_block(l));
    }

    bool is_rows_or_lines(const Expr* e)
    {
      if (!is(e, EK::Call)) { return false; }
      std::string n = lc(static_cast<const Call*>(e)->name);
      return n == "rows" || n == "lines";
    }

    // The rows()/lines() call a chain walks, if it walks one.
    const Call* source_of(const Expr* e)
    {
      if (is(e, EK::Pipeline) && is_rows_or_lines(static_cast<const Pipeline*>(e)->source))
      {
        return static_cast<const Call*>(static_cast<const Pipeline*>(e)->source);
      }
      if (is_rows_or_lines(e)) { return static_cast<const Call*>(e); }
      return nullptr;
    }

    // A literal's type letter and, for a string, its text -- or nothing: not
    // a literal, or Nil, which is ordinary to assign.
    struct Kind
    {
      std::string letter;
      std::string text;
    };

    std::optional<Kind> literal_kind(const Expr* e)
    {
      if (!e) { return std::nullopt; }
      if (is(e, EK::Binary))
      {
        auto b = static_cast<const Binary*>(e);
        if (b->op == "neg" && is_literal(b->right) && static_cast<const Literal*>(b->right)->type == "Numeric")
        {
          return Kind{ "N", "-" + static_cast<const Literal*>(b->right)->text };
        }
      }
      if (!is_literal(e) || is(e, EK::Interp)) { return std::nullopt; }
      auto l = static_cast<const Literal*>(e);
      if (l->type == "Character") { return Kind{ "C", unquoted(l->text) }; }
      if (l->type == "Numeric") { return Kind{ "N", l->text }; }
      if (l->type == "Logical") { return Kind{ "L", l->text }; }
      return std::nullopt;
    }

    // difflib's ratio, as xtpl's hint uses it: twice the characters in the
    // matching blocks over the two lengths together.
    std::size_t matching(const std::string& a, const std::string& b)
    {
      if (a.empty() || b.empty()) { return 0; }
      std::size_t best = 0;
      std::size_t ai = 0;
      std::size_t bj = 0;
      for (std::size_t i = 0; i < a.size(); i++)
      {
        for (std::size_t j = 0; j < b.size(); j++)
        {
          std::size_t k = 0;
          while (i + k < a.size() && j + k < b.size() && a[i + k] == b[j + k]) { k++; }
          if (k > best)
          {
            best = k;
            ai = i;
            bj = j;
          }
        }
      }
      if (!best) { return 0; }
      return best + matching(a.substr(0, ai), b.substr(0, bj)) + matching(a.substr(ai + best), b.substr(bj + best));
    }

    // The field most like f, at 0.7 or more: the highest ratio, the greater
    // name on a tie.
    std::optional<std::string> closest(const std::string& f, const std::unordered_map<std::string, Field>& fields)
    {
      bool any = false;
      std::size_t best_m = 0;
      std::size_t best_len = 1;
      std::string best;
      for (const auto& [name, field] : fields)
      {
        std::size_t m = 2 * matching(f, name);
        std::size_t len = f.size() + name.size();
        if (m * 10 < len * 7) { continue; }
        // m / len against best_m / best_len, exactly.
        bool better = !any || m * best_len > best_m * len || (m * best_len == best_m * len && name > best);
        if (better)
        {
          any = true;
          best_m = m;
          best_len = len;
          best = name;
        }
      }
      if (!any) { return std::nullopt; }
      return best;
    }

    // One CSV line: commas, and double quotes around a value that holds one.
    std::vector<std::string> csv_row(const std::string& line)
    {
      std::vector<std::string> out;
      std::string cell;
      bool quoted = false;
      for (std::size_t i = 0; i < line.size(); i++)
      {
        char c = line[i];
        if (quoted)
        {
          if (c == '"' && i + 1 < line.size() && line[i + 1] == '"')
          {
            cell += '"';
            i++;
          }
          else if (c == '"') { quoted = false; }
          else { cell += c; }
        }
        else if (c == '"') { quoted = true; }
        else if (c == ',')
        {
          out.push_back(cell);
          cell.clear();
        }
        else { cell += c; }
      }
      out.push_back(cell);
      return out;
    }

    // Raku's .lines: split at "\r\n", "\n" and "\r"; no empty last line.
    std::vector<std::string> lines_of(const std::string& t)
    {
      std::vector<std::string> out;
      std::size_t b = 0;
      std::size_t i = 0;
      while (i < t.size())
      {
        if (t[i] == '\n' || t[i] == '\r')
        {
          out.push_back(t.substr(b, i - b));
          i += (t[i] == '\r' && i + 1 < t.size() && t[i + 1] == '\n') ? 2 : 1;
          b = i;
        }
        else
        {
          i++;
        }
      }
      if (b < t.size()) { out.push_back(t.substr(b)); }
      return out;
    }

    // Each finding once -- the first of a line and message -- in the order of
    // the lines.
    std::vector<Finding> tidy(const std::vector<Finding>& v)
    {
      std::vector<Finding> out;
      std::unordered_set<std::string> seen;
      for (const Finding& f : v)
      {
        if (seen.insert(num(f.line) + '\0' + f.message).second) { out.push_back(f); }
      }
      std::stable_sort(out.begin(), out.end(), [](const Finding& a, const Finding& b) { return a.line < b.line; });
      return out;
    }

    // ---- the checker --------------------------------------------------------
    // A variable: where it is declared, what it is, how it is used.
    struct Var
    {
      std::string name;
      int line = 0;
      std::string kind;              // local, param, loop, block-param
      int reads = 0;
      int writes = 0;
      bool is_const = false;
      bool contained = false;
      // Declared with a type and no value, one TL++ does not start at Nil:
      // the type, and what it starts at ('' for every other).
      std::string type = {};
      std::string start = {};
    };

    // The types TL++ starts a variable declared with no value at something
    // else than Nil (tried on 24.3.1.9): the type as shown, and the value.
    // Array, Object, CodeBlock, JSON, Variant and Decimal start at Nil.
    const std::unordered_map<std::string, std::pair<std::string, std::string>> TYPED_START =
    {
      { "numeric", { "Numeric", "0" } },
      { "integer", { "Integer", "0" } },
      { "double", { "Double", "0" } },
      { "character", { "Character", "\"\"" } },
      { "logical", { "Logical", ".F." } },
      { "date", { "Date", "the date 1899-12-31" } },
    };

    // The keywords the AppServer reads written short: a name of 4 letters or
    // more that begins one is the keyword to it, wherever it is -- a method,
    // a Data, a Local, a function (tried on 24.3.1.9). SEQUENCE, MEMVAR,
    // FIELD and REQUEST it does not read so.
    const std::vector<std::string> SHORT_KEYWORDS =
    {
      "announce", "begin", "declare", "endcase", "enddo", "endif", "external", "function", "local", "otherwise",
      "parameters", "private", "procedure", "public", "recover", "return", "static", "while",
    };

    // The keyword NAME begins, written short, or "".
    std::string short_keyword(const std::string& name)
    {
      std::string n = lc(name);
      if (n.size() < 4) { return ""; }
      for (const std::string& k : SHORT_KEYWORDS)
      {
        if (n.size() <= k.size() && k.compare(0, n.size(), n) == 0) { return k; }
      }
      return "";
    }

    // A scope: the names it declares, and the one around it. A closure scope
    // is a lambda's or a code block's: a name found beyond it is captured.
    struct Scope
    {
      Scope* outer = nullptr;
      bool closure = false;
      std::unordered_map<std::string, Var*> names;
    };

    // A name's declaration, and whether a closure lies between here and it.
    struct Found
    {
      Var* v = nullptr;
      bool captured = false;
      explicit operator bool() const { return v != nullptr; }
    };

    struct Func
    {
      std::string name;
      std::string kind;
      std::size_t params = 0;
      int line = 0;
    };

    struct StaticUse
    {
      std::string name;
      int reads = 0;
      int writes = 0;
      bool is_const = false;
    };

    class Checker
    {
    public:
      Checker(int lines, const Dictionary& dictionary, bool strict, std::optional<std::string_view> source, bool advpl,
              bool bytecode)
        : lines_(lines), dictionary_(dictionary), strict_(strict), source_(source), advpl_(advpl), bytecode_(bytecode)
      {
      }

      std::vector<Finding> found;
      std::vector<Finding> warned;

      void program(const Program* p);

    private:
      int lines_;
      const Dictionary& dictionary_;
      bool strict_;
      std::optional<std::string_view> source_;
      bool advpl_;                   // an AdvPL source (.prw): TL++'s own rules do not hold
      bool bytecode_;                // it becomes bytecode: xc's machines run it, not the AppServer

      Set warned_names_;
      Set implicit_;
      std::unordered_map<std::string, Func> funcs_;
      std::unordered_map<std::string, int> externals_;
      std::unordered_map<std::string, int> statics_;
      std::unordered_set<const Stmt*> static_decls_;
      std::unordered_map<std::string, StaticUse> static_uses_;
      std::vector<std::string> static_order_;      // static_uses_' keys, as they came
      Set defines_;
      Set privates_;
      Set classes_;
      std::unordered_set<const Expr*> made_;   // the 'Name()' of each 'Name():M(...)'
      Set includes_;                 // the include files the file names, their names in lower case
      bool tcquery_ok_ = true;       // the file says where TCQUERY comes from, or might
      std::unordered_map<std::string, int> retired_;
      std::unordered_map<std::string, std::string> scalar_;
      Set json_;                     // the function's names declared as a JsonObject
      std::unordered_set<const Expr*> sources_ok_;
      std::unordered_set<const Expr*> chains_ok_;
      Scope* scope_ = nullptr;
      int line_ = 0;
      bool in_defer_ = false;
      bool in_static_ = false;       // in a static's value, where a local is Nil
      std::vector<Var*> records_;
      Set opened_;
      Set warned_alias_;
      Set external_alias_;
      Set dict_seen_;
      std::unordered_map<const Expr*, std::string> chain_at_;
      std::unordered_set<const Expr*> guarded_;
      std::unordered_set<const Expr*> stmt_guards_;
      std::vector<int> ends_;

      std::deque<Scope> scopes_;
      std::deque<Var> vars_;

      void problem(const std::string& m) { found.push_back({ line_, m }); }
      void warning(const std::string& m) { warned.push_back({ line_, m }); }
      void then_cond(const Expr* cond, const std::string& where);
      void keyword_name(const std::string& name, int line);
      std::unordered_set<std::string> keyword_seen_;   // line and name, said once

      void agrees(const Declarator* d)
      {
        if (auto p = type_problem(d, advpl_)) { found.push_back({ d->line, *p }); }
      }

      Scope* new_scope(Scope* outer, bool closure)
      {
        scopes_.push_back(Scope{ outer, closure, {} });
        return &scopes_.back();
      }

      void raw_reads(const std::string& text);
      void unclosed(const Literal* e);
      void type_word(const OptStr& word, int line);
      void function(const std::vector<Param*>& params, const Body& body, int line);
      void never_read();
      void returns(const Body& body, int fline);
      void declare(const std::string& name, int line, const std::vector<std::string>& attributes,
                   const std::string& kind = "local", bool written = false);
      template <class F> void in_block(F code);
      Found find(const std::string& k) const;
      bool exempt(const std::string& name) const;
      void leaves(const Var* v, const std::string& name, bool how);
      void read(const std::string& name);
      void write(const std::string& name, bool reads = false);
      void by_ref(const std::string& name);
      void block_arg(const std::string& verb, Expr* e);
      void body(const Body& stmts);
      void file_statics(const Body& stmts, std::vector<Declarator*>& statics);
      void file_static(const Declarator* d);
      void static_value(const Declarator* d);
      void static_never_read();
      void stmt(Stmt* s);
      void target(Expr* t, const std::string& op = ":=");
      void note_scalar(const Declarator* d);
      void json_member(const Member* m);
      void never_nil(const Expr* e, const std::string& op);
      void expr(Expr* e);
      void call(const Call* c);
      void constructor(const MethodCall* m);
      void constructed(const Expr* base, const std::string& after);
      void field(const AliasField* f);
      std::optional<std::string> alias_word(const AliasField* f) const;
      void dict(const std::string& m) { strict_ ? problem(m) : warning(m); }
      void dict_field(const std::string& alias, const std::string& fieldname);
      void dict_type(const AliasField* ref, const Expr* lit, bool assigned);
      void alias_base(Expr* b);
      void fusion(const Pipeline* p);
      void loose_left(const Pipeline* p);
      void chain(const Pipeline* p);
      void scalar_source(const std::string& shown, const std::string& why);
    };

    // Break() with no value, a statement or in a block: probe xdr, on
    // 24.3.1.9.
    const std::string BREAK_EMPTY = "Break(): the AppServer refuses it with no value -- \"C2003 Syntax Error\" in TL++, "
                                    "\"Use of reserved language word (BREAK)\" in AdvPL. Write Break, or Break(Nil)";

    // ---- the file -----------------------------------------------------------
    // What the AppServer says of a regular function.
    const std::string REGULAR = "it refuses one in a compile without TOTVS' authorization (\"Regular functions are not "
                                "allowed in code. Use USER FUNCTION or STATIC FUNCTION.\")";

    void Checker::program(const Program* p)
    {
      for (const FunctionDef* f : p->functions)
      {
        // A User Function's name is the AppServer's with 'U_' before it (a
        // Web's 'W_', an Html's 'H_'), no keyword -- not tried: only a
        // Static, a Main and a bare Function's are checked.
        std::string type = lc(f->type);
        if (type.empty() || type == "static" || type == "main") { keyword_name(f->name, f->line); }
        funcs_[lc(f->name)] = Func{ f->name, lc(f->type), f->params.size(), f->line };
        // A bare 'Function' whose name has no 'u_', or a 'Main Function': a
        // regular function, which TOTVS compiles with its authorization --
        // without one the AppServer refuses it (tried on 24.3.1.9).
        if ((f->type.empty() && !starts_with(lc(f->name), "u_")) || lc(f->type) == "main")
        {
          std::string what = f->type.empty() ? "a regular function" : "a Main Function, a regular function to the AppServer";
          warned.push_back({ f->line, "'" + f->name + "' is " + what + ": " + REGULAR });
        }
        if (is_runtime_verb(f->name))
        {
          found.push_back({ f->line, "'" + f->name + "' is the name of one of xtpl's verbs: a call to "
                                     + lc(f->name) + "() is the runtime's u_xtpl_" + lc(f->name)
                                     + ", never a function of the file. Give it another name." });
        }
      }
      // A .prw counts a function's name to 10 characters, its prefix
      // included: 'ProcessOrderCreated' and 'ProcessOrderUpdated' are one
      // function there, PROCESSORD (tried on 24.3.1.9).
      if (advpl_)
      {
        static const std::unordered_map<std::string, std::string> prefix = { { "user", "u_" }, { "web", "w_" },
                                                                             { "html", "h_" } };
        std::unordered_map<std::string, const FunctionDef*> first;
        for (const FunctionDef* f : p->functions)
        {
          auto x = prefix.find(lc(f->type));
          std::string full = (x != prefix.end() && !starts_with(lc(f->name), x->second.c_str()) ? x->second : std::string()) + f->name;
          std::string key = uc(full.substr(0, 10));
          auto [it, fresh] = first.emplace(key, f);
          if (!fresh && lc(it->second->name) != lc(f->name))
          {
            found.push_back({ f->line, "'" + f->name + "' and '" + it->second->name + "' (line "
                                       + num(it->second->line) + ") are one function in a .prw, which counts a name "
                                       + "to 10 characters (" + key + "): the AppServer refuses the second." });
          }
        }
      }
      for (const External* x : p->externals)
      {
        if (x->alias) { continue; }
        for (const std::string& n : x->names) { externals_[lc(n)] = x->line; }
      }
      for (const External* x : p->externals)
      {
        if (!x->alias) { continue; }
        for (const std::string& n : x->names) { external_alias_.insert(uc(n)); }
      }
      std::vector<Declarator*> statics;
      for (const Declaration* d : p->statics)
      {
        for (Declarator* v : d->declarators) { statics.push_back(v); }
      }
      for (const Declarator* d : statics)
      {
        agrees(d);
        keyword_name(d->name, d->line);
      }
      for (const FunctionDef* f : p->functions) { file_statics(f->body, statics); }
      for (const MethodImpl* m : p->methods) { file_statics(m->body, statics); }
      std::stable_sort(statics.begin(), statics.end(),
                       [](const Declarator* a, const Declarator* b) { return a->line < b->line; });
      for (const Declarator* d : statics) { file_static(d); }
      for (const FunctionDef* f : p->functions) { ends_.push_back(f->line); }
      for (const MethodImpl* m : p->methods)
      {
        ends_.push_back(m->line);
        keyword_name(m->name, m->line);
      }
      for (const ClassDef* c : p->classes)
      {
        ends_.push_back(c->line);
        classes_.insert(lc(c->name));
        for (const DataMember* m : c->members) { keyword_name(m->name, m->line); }
        for (const MethodSig* m : c->methods)
        {
          keyword_name(m->name, m->line);
          // 'Public Static Method' is C2003: a static method has no
          // visibility (tried on 24.3.1.9).
          if (m->is_static && m->visibility)
          {
            found.push_back({ m->line, "a static method takes no visibility: the AppServer refuses '"
                                       + *m->visibility + "' with 'Static' (\"C2003 Syntax Error\", tried on "
                                       + "24.3.1.9). Write 'Static Method " + m->name + "(...)'." });
          }
        }
        // A Data's value: the AppServer ignores it, in a .tlpp and a .prw
        // (tried on 24.3.1.9).
        for (const DataMember* m : c->members)
        {
          if (!m->init) { continue; }
          auto t = m->type && !advpl_ ? TYPED_START.find(lc(*m->type)) : TYPED_START.end();
          std::string start = t != TYPED_START.end() ? t->second.second : "Nil";
          // The value it starts at anyway -- 'as Numeric default 0', 'init
          // Nil' -- is harmless.
          if (is(m->init, EK::Literal))
          {
            auto l = static_cast<const Literal*>(m->init);
            std::string same = l->type == "Variant" ? "Nil"
                               : l->type == "Numeric" && std::strtod(l->text.c_str(), nullptr) == 0 ? "0"
                               : l->type == "Character" && unquoted(l->text).empty() ? "\"\""
                               : l->type == "Logical" && lc(l->text) == ".f." ? ".F." : "";
            if (same == start) { continue; }
          }
          warned.push_back({ m->line, "'" + m->name + "' is given a value with '" + m->init_word
                                      + "', which the AppServer ignores: it starts at " + start
                                      + ". Give it its value in the constructor." });
        }
      }
      // The include files: the file's, and a function's own '#include'.
      auto include_of = [&](const std::string& line)
      {
        std::string l = lc(trim(line));
        if (l.compare(0, 1, "#") != 0) { return; }
        std::size_t i = 1;
        while (i < l.size() && (l[i] == ' ' || l[i] == '\t')) { i++; }
        if (l.compare(i, 7, "include") != 0) { return; }
        std::size_t q = l.find_first_of("\"'<", i + 7);
        if (q == std::string::npos) { return; }
        std::size_t e = l.find_first_of("\"'>", q + 1);
        std::string name = l.substr(q + 1, e == std::string::npos ? std::string::npos : e - q - 1);
        std::size_t cut = name.find_last_of("/\\");
        includes_.insert(cut == std::string::npos ? name : name.substr(cut + 1));
      };
      for (const std::string& d : p->directives) { include_of(d); }
      auto body_includes = [&](const Body& b)
      {
        walk(b, [&](Stmt* s)
        {
          if (s->kind != SK::RawStmt) { return; }
          for (const std::string& l : static_cast<const RawStmt*>(s)->lines) { include_of(l); }
        });
      };
      for (const FunctionDef* f : p->functions) { body_includes(f->body); }
      for (const MethodImpl* m : p->methods) { body_includes(m->body); }
      // TCQUERY is topconn.ch's: a file that includes only totvs.ch has no
      // TCQUERY, and the AppServer refuses its line (C2003, tried on
      // 24.3.1.9). Another include file may bring it; so may a command of
      // the file's own.
      for (const std::string& i : includes_)
      {
        if (i != "totvs.ch" && i != "tlpp-core.th") { tcquery_ok_ = true; break; }
        tcquery_ok_ = false;
      }
      if (includes_.empty()) { tcquery_ok_ = false; }
      for (const std::string& d : p->directives)
      {
        if (lc(d).find("tcquery") != std::string::npos) { tcquery_ok_ = true; }
      }
      // A method of a class this file does not declare: the AppServer takes
      // it for a regular function (tried on 24.3.1.9).
      for (const MethodImpl* m : p->methods)
      {
        if (m->ws || m->class_name.empty() || classes_.count(lc(m->class_name))) { continue; }
        warned.push_back({ m->line, "'" + m->name + "' is a method of " + m->class_name + ", which this file does not "
                                    + "declare, so the AppServer takes it for a regular function: " + REGULAR });
      }
      std::sort(ends_.begin(), ends_.end());
      // '#define NAME': m:i/ ^ '#' \h* 'define' \h+ (\w+) /
      for (const std::string& d : p->directives)
      {
        std::size_t i = 0;
        if (d.empty() || d[0] != '#') { continue; }
        i = 1;
        while (i < d.size() && is_h(static_cast<unsigned char>(d[i]))) { i++; }
        if (d.size() - i < 6 || lc(d.substr(i, 6)) != "define") { continue; }
        i += 6;
        std::size_t h = i;
        while (i < d.size() && is_h(static_cast<unsigned char>(d[i]))) { i++; }
        if (i == h) { continue; }
        std::size_t w = i;
        while (i < d.size() && is_w(static_cast<unsigned char>(d[i]))) { i++; }
        if (i > w) { defines_.insert(lc(d.substr(w, i - w))); }
      }
      auto privates = [&](const Body& b)
      {
        walk(b, [&](Stmt* s)
        {
          if (s->kind != SK::Declaration) { return; }
          auto d = static_cast<const Declaration*>(s);
          if (d->scope != "private" && d->scope != "public") { return; }
          for (const Declarator* v : d->declarators) { privates_.insert(lc(v->name)); }
        });
      };
      for (const FunctionDef* f : p->functions) { privates(f->body); }
      for (const MethodImpl* m : p->methods) { privates(m->body); }
      for (const FunctionDef* f : p->functions)
      {
        for (const Param* q : f->params) { type_word(q->type_word, f->line); }
        type_word(f->rettype_word, f->line);
        function(f->params, f->body, f->line);
      }
      for (const MethodImpl* m : p->methods)
      {
        for (const Param* q : m->params) { type_word(q->type_word, m->line); }
        type_word(m->returns, m->line);
        function(m->params, m->body, m->line);
      }
      for (const ClassDef* c : p->classes)
      {
        if (advpl_) { break; }
        for (const DataMember* d : c->members) { type_word(d->type, d->line ? d->line : c->line); }
      }
      static_never_read();
    }

    void Checker::raw_reads(const std::string& text)
    {
      // text.comb(/ <[A..Za..z_]> \w* /)
      std::size_t i = 0;
      while (i < text.size())
      {
        if (!is_alpha(static_cast<unsigned char>(text[i])))
        {
          i++;
          continue;
        }
        std::size_t b = i;
        i++;
        while (i < text.size() && is_w(static_cast<unsigned char>(text[i]))) { i++; }
        std::string k = lc(text.substr(b, i - b));
        if (Found v = find(k))
        {
          v.v->reads++;
          leaves(v.v, v.v->name, true);
        }
        else if (auto u = static_uses_.find(k); u != static_uses_.end())
        {
          u->second.reads++;
        }
      }
    }

    void Checker::unclosed(const Literal* e)
    {
      const std::string& t = e->text;
      if (t.size() >= 2 && t.back() == t.front()) { return; }
      warning("this string is not closed: TL++ ends it at the end of the line -- " + t);
    }

    void Checker::type_word(const OptStr& word, int line)
    {
      // AdvPL's own words for a type, which a .prw takes and TL++ does not
      // ("Invalid Type STRING", tried on 24.3.1.9).
      static const std::unordered_map<std::string, std::string> advpl_words =
      {
        { "string", "Character" }, { "number", "Numeric" }, { "logic", "Logical" }, { "boolean", "Logical" },
      };
      if (word && !advpl_)
      {
        if (auto a = advpl_words.find(lc(*word)); a != advpl_words.end())
        {
          line_ = line;
          problem("'as " + *word + "': TL++ has no type '" + *word + "' -- write 'as " + a->second + "' (a .prw "
                  + "takes it: AdvPL does not check its types).");
          return;
        }
      }
      if (!word || !(word->size() == 1 || lc(*word) == "char" || lc(*word) == "block")) { return; }
      static const std::unordered_map<std::string, std::string> whole =
      {
        { "a", "Array" }, { "n", "Numeric" }, { "c", "Character" }, { "l", "Logical" }, { "d", "Date" },
        { "o", "Object" }, { "b", "CodeBlock" }, { "j", "JSON" }, { "u", "Variant" }, { "char", "Character" },
        { "block", "CodeBlock" },
      };
      line_ = line;
      auto w = whole.find(lc(*word));
      problem("'as " + *word + "': TL++ has no type '" + *word + "' -- write 'as "
              + (w != whole.end() ? w->second : *word) + "'.");
    }

    void Checker::function(const std::vector<Param*>& params, const Body& b, int line)
    {
      retired_.clear();
      scalar_.clear();
      json_.clear();
      records_.clear();
      opened_.clear();
      warned_alias_.clear();
      scope_ = new_scope(nullptr, false);
      line_ = line;
      for (const Param* q : params) { declare(q->name, line, q->attributes, "param"); }
      body(b);
      never_read();
      returns(b, line);
    }

    void Checker::never_read()
    {
      std::vector<Var*> unread;
      for (Var* v : records_)
      {
        if (v->kind == "local" && !v->reads) { unread.push_back(v); }
      }
      std::stable_sort(unread.begin(), unread.end(), [](const Var* a, const Var* b) { return a->line < b->line; });
      for (const Var* v : unread)
      {
        warned.push_back({ v->line, v->writes ? "'" + v->name + "' is assigned but never read"
                                              : "'" + v->name + "' is declared but never used" });
      }
    }

    void Checker::returns(const Body& b, int fline)
    {
      std::vector<const ReturnStmt*> valued;
      std::vector<const ReturnStmt*> bare;
      walk(b, [&](Stmt* s)
      {
        if (s->kind != SK::ReturnStmt) { return; }
        auto r = static_cast<const ReturnStmt*>(s);
        (r->value ? valued : bare).push_back(r);
      });
      const Stmt* last = nullptr;
      for (auto it = b.rbegin(); it != b.rend(); ++it)
      {
        const Stmt* s = *it;
        bool static_decl = s->kind == SK::Declaration && static_cast<const Declaration*>(s)->scope == "static";
        if (!static_decl && s->kind != SK::NoOpStmt)
        {
          last = s;
          break;
        }
      }
      int next = -1;
      for (int e : ends_)
      {
        if (e > fline)
        {
          next = e;
          break;
        }
      }
      int end = next >= 0 ? next - 1 : (lines_ ? lines_ : (last && last->line ? last->line : fline));
      bool ends_without = !last || last->kind != SK::ReturnStmt;
      const std::string w0019 = "the function ends without a 'return': Protheus warns about it (W0019), and will refuse it";
      if (valued.empty())
      {
        if (ends_without) { warned.push_back({ end, w0019 }); }
        return;
      }
      int first = valued[0]->line;
      for (const ReturnStmt* r : valued) { first = std::min(first, r->line); }
      for (const ReturnStmt* r : bare)
      {
        warned.push_back({ r->line, "this returns nothing, but the function returns a value on line " + num(first) });
      }
      bool modified_return = last && last->kind == SK::Modified
                             && static_cast<const Modified*>(last)->stmt->kind == SK::ReturnStmt;
      if (ends_without && !modified_return)
      {
        warned.push_back({ end, "the function can reach its end without a return, but returns a value on line "
                                + num(first) });
      }
      else if (ends_without)
      {
        warned.push_back({ end, w0019 });
      }
    }

    // A 'then' chain that is all of a condition: 'If cS then Empty()' reads
    // as BASIC's 'If ... Then', and a reader can miss the chain.
    void Checker::then_cond(const Expr* cond, const std::string& where)
    {
      if (!cond || cond->kind != EK::Pipeline || !static_cast<const Pipeline*>(cond)->then)
      {
        return;
      }
      warned.push_back({ cond->line > 0 ? cond->line : line_,
                         "the condition of " + where + " is a 'then' chain, which reads as 'if ... then': write "
                         "'|>' there, or put the chain in parentheses" });
    }

    // ---- scopes -------------------------------------------------------------
    // A name the AppServer reads as a keyword written short.
    void Checker::keyword_name(const std::string& name, int line)
    {
      std::string k = short_keyword(name);
      // A reserved word xc refuses as a name already.
      if (k.empty() || is_reserved(name) || !keyword_seen_.insert(num(line) + " " + lc(name)).second) { return; }
      std::string code = k == "local" ? "C9907 Invalid use of reserved word LOCAL" : "C2003 Syntax Error";
      std::string what = name.size() == k.size() ? "the AppServer's keyword " + uc(k) + ", and it refuses the line"
                         : uc(k) + " written short: the AppServer reads a name of 4 letters or more that begins one of "
                           "its keywords as the keyword, and refuses the line";
      found.push_back({ line, "'" + name + "' is " + what + " (\"" + code + "\", tried on 24.3.1.9). Give it another "
                              + "name." });
    }

    void Checker::declare(const std::string& name, int line, const std::vector<std::string>& attributes,
                          const std::string& kind, bool written)
    {
      keyword_name(name, line);
      std::string k = lc(name);
      if (auto it = scope_->names.find(k); it != scope_->names.end())
      {
        if (kind == "block-param")
        {
          warned.push_back({ line, "'" + name + "' is a parameter of this block twice: the AppServer takes it, and '"
                                   + name + "' is the argument in the last of its places" });
        }
        else if (scope_->outer)
        {
          found.push_back({ line, "'" + name + "' is already declared in this block." });
        }
        else
        {
          Var* v = it->second;
          warned.push_back({ line, "'" + name + "' is declared again (first on line " + num(v->line)
                                   + "): the same variable -- a value assigns it, none leaves it as it was. "
                                   + "The AppServer warns too (W0011, \"Variable " + uc(name) + " redefined\")" });
          if (written) { v->writes++; }
        }
        return;
      }
      vars_.push_back(Var{ name, line, kind, 0, written ? 1 : 0, has(attributes, "const"), has(attributes, "contained") });
      Var* v = &vars_.back();
      scope_->names[k] = v;
      records_.push_back(v);
      retired_.erase(k);
    }

    template <class F>
    void Checker::in_block(F code)
    {
      Scope* outer = scope_;
      scope_ = new_scope(outer, false);
      code();
      Scope* inner = scope_;
      scope_ = outer;
      for (const auto& [k, v] : inner->names)
      {
        if (!find(k)) { retired_[k] = v->line; }
      }
    }

    Found Checker::find(const std::string& k) const
    {
      bool crossed = false;
      for (Scope* s = scope_; s; s = s->outer)
      {
        if (auto it = s->names.find(k); it != s->names.end()) { return Found{ it->second, crossed }; }
        crossed = crossed || s->closure;
      }
      return Found{};
    }

    bool Checker::exempt(const std::string& name) const
    {
      std::string k = lc(name);
      return KNOWN.count(k) || is_reserved(name) || is_generated(name) || externals_.count(k) || defines_.count(k)
             || privates_.count(k) || statics_.count(k);
    }

    // ---- names --------------------------------------------------------------
    void Checker::leaves(const Var* v, const std::string& name, bool how)
    {
      if (v->contained && how)
      {
        problem("'" + name + "' is <contained> (declared on line " + num(v->line) + ") and cannot leave its block.");
      }
    }

    void Checker::read(const std::string& name)
    {
      std::string k = lc(name);
      if (Found v = find(k))
      {
        v.v->reads++;
        leaves(v.v, name, v.captured || in_defer_);
        return;
      }
      if (auto r = retired_.find(k); r != retired_.end())
      {
        problem("'" + name + "' is out of scope here (block local declared on line " + num(r->second) + ").");
        return;
      }
      if (auto u = static_uses_.find(k); u != static_uses_.end())
      {
        u->second.reads++;
        return;
      }
      if (exempt(name) || implicit_.count(k)) { return; }
      if (warned_names_.insert("read " + k).second) { warning("'" + name + "' is not declared"); }
    }

    void Checker::write(const std::string& name, bool reads)
    {
      std::string k = lc(name);
      if (Found v = find(k))
      {
        reads ? v.v->reads++ : v.v->writes++;
        if (v.v->is_const)
        {
          problem("'" + name + "' is <const> (declared on line " + num(v.v->line) + ") and cannot be assigned.");
        }
        leaves(v.v, name, v.captured || in_defer_);
        return;
      }
      if (auto r = retired_.find(k); r != retired_.end())
      {
        problem("'" + name + "' is out of scope here (block local declared on line " + num(r->second) + ").");
        return;
      }
      if (auto x = externals_.find(k); x != externals_.end())
      {
        problem("'" + name + "' is external (line " + num(x->second) + ") and cannot be assigned.");
        return;
      }
      if (auto u = static_uses_.find(k); u != static_uses_.end())
      {
        if (u->second.is_const)
        {
          problem("'" + name + "' is <const> (declared on line " + num(statics_[k]) + ") and cannot be assigned.");
        }
        reads ? u->second.reads++ : u->second.writes++;
        return;
      }
      if (exempt(name) || implicit_.count(k)) { return; }
      implicit_.insert(k);
      if (warned_names_.insert("write " + k).second)
      {
        warning("'" + name + "' is not declared, so this creates a PRIVATE");
      }
    }

    void Checker::by_ref(const std::string& name)
    {
      std::string k = lc(name);
      if (Found v = find(k))
      {
        v.v->reads++;
        v.v->start.clear();          // what it is given may be Nil
        if (v.v->is_const)
        {
          problem("'" + name + "' is <const> (declared on line " + num(v.v->line)
                  + ") and cannot be passed by reference with '@'.");
        }
        leaves(v.v, name, true);
        return;
      }
      read(name);
    }

    void Checker::block_arg(const std::string& verb, Expr* e)
    {
      if (!(takes_block(lc(verb)) && is(e, EK::Name)))
      {
        expr(e);
        return;
      }
      const std::string& n = name_of(e);
      std::string k = lc(n);
      if (find(k) || retired_.count(k) || exempt(n)) { read(n); }
    }

    // ---- statements ---------------------------------------------------------
    void Checker::body(const Body& stmts)
    {
      const Declaration* priv = nullptr;
      for (Stmt* s : stmts)
      {
        if (s->kind == SK::Declaration)
        {
          auto d = static_cast<const Declaration*>(s);
          if (d->scope == "private" || d->scope == "public")
          {
            if (!priv) { priv = d; }
          }
          else if (d->scope == "local" && priv)
          {
            line_ = s->line;
            problem("'local' after '" + priv->scope + "' (line " + num(priv->line) + "): a private or a public is a "
                    + "statement, and every local comes before the first statement.");
          }
        }
        stmt(s);
      }
    }

    void Checker::file_statics(const Body& stmts, std::vector<Declarator*>& statics)
    {
      for (const Stmt* s : stmts)
      {
        if (s->kind == SK::Declaration && static_cast<const Declaration*>(s)->scope == "static")
        {
          static_decls_.insert(s);
          for (Declarator* d : static_cast<const Declaration*>(s)->declarators) { statics.push_back(d); }
        }
        for (const Body& b : bodies_of(s)) { file_statics(b, statics); }
      }
    }

    void Checker::file_static(const Declarator* d)
    {
      std::string k = lc(d->name);
      if (auto s = statics_.find(k); s != statics_.end())
      {
        warned.push_back({ d->line, "'" + d->name + "' is already a static of this file (line " + num(s->second)
                                    + "): both are one variable, which starts with the last value given in the file" });
        return;
      }
      statics_[k] = d->line;
      static_uses_[k] = StaticUse{ d->name, 0, d->init ? 1 : 0, has(d->attributes, "const") };
      static_order_.push_back(k);
    }

    void Checker::static_value(const Declarator* d)
    {
      Set said;
      std::function<void(Expr*)> look = [&](Expr* e)
      {
        if (!e || is_code_block(e)) { return; }
        if (is(e, EK::Name))
        {
          const std::string& n = name_of(e);
          if (Found v = find(lc(n)))
          {
            const std::string& kind = v.v->kind;
            if ((kind == "param" || kind == "local" || kind == "loop") && said.insert(lc(n)).second)
            {
              warned.push_back({ d->line, "'" + n + "' is a " + (kind == "param" ? "parameter" : "local")
                                          + ": a static takes its value once, at load, when '" + n
                                          + "' does not exist -- it is Nil there" });
            }
          }
        }
        for (Expr* x : subexprs(e)) { look(x); }
      };
      look(d->init);
    }

    void Checker::static_never_read()
    {
      std::vector<std::string> keys = static_order_;
      std::stable_sort(keys.begin(), keys.end(),
                       [&](const std::string& a, const std::string& b) { return statics_[a] < statics_[b]; });
      for (const std::string& k : keys)
      {
        const StaticUse& u = static_uses_[k];
        if (u.reads) { continue; }
        warned.push_back({ statics_[k], u.writes ? "'" + u.name + "' is assigned but never read"
                                                 : "'" + u.name + "' is declared but never used" });
      }
    }

    void Checker::stmt(Stmt* s)
    {
      if (s->line) { line_ = s->line; }
      sources_ok_.clear();
      chains_ok_.clear();
      if (s->oneline)
      {
        // A one-line form inside another's branch is in parentheses, so that
        // an 'else' has one 'if' to go with; one over lines() is a block,
        // which closes the file on every way out.
        const char* kw = s->kind == SK::IfStmt ? "if" : s->kind == SK::WhileStmt ? "while" : "for";
        if (s->bare)
        {
          problem(std::string("a one-line '") + kw + "' inside another goes in parentheses: 'if a exec (if b exec x "
                  "else y), z'.");
        }
        if (s->kind == SK::ForInStmt && is(static_cast<ForInStmt*>(s)->source, EK::Call)
            && source_kind(static_cast<ForInStmt*>(s)->source) == "lines")
        {
          problem("a 'for ... in lines()' on one line is refused: write the block, which closes the file on every way "
                  "out.");
        }
      }
      // The rule for rows(), lines() and 'lo..hi': where a chain from one may
      // be, and the source alone.
      std::vector<Expr*> whole;
      switch (s->kind)
      {
        case SK::Assignment:
        {
          auto a = static_cast<Assignment*>(s);
          if (a->op == ":=") { whole.push_back(a->value); }
          break;
        }
        case SK::ReturnStmt:
          if (auto v = static_cast<ReturnStmt*>(s)->value) { whole.push_back(v); }
          break;
        case SK::CallStmt:
          whole.push_back(static_cast<CallStmt*>(s)->call);
          break;
        case SK::Declaration:
        {
          auto d = static_cast<Declaration*>(s);
          if (d->scope == "local" || d->scope == "private" || d->scope == "public")
          {
            for (Declarator* v : d->declarators)
            {
              if (v->init) { whole.push_back(v->init); }
            }
          }
          break;
        }
        case SK::ForInStmt:
          whole.push_back(static_cast<ForInStmt*>(s)->source);
          break;
        default:
          break;
      }
      for (Expr* w : whole)
      {
        if (is(w, EK::Call)) { sources_ok_.insert(w); }
        if (is(w, EK::Pipeline)) { chains_ok_.insert(w); }
      }
      // A guard that is the whole value of 'x := ...', of a declaration (but a
      // static's) or of 'return' runs as statements, a Begin Sequence: a chain
      // under it is a statement's, and fuses.
      bool hash_target = s->kind == SK::Assignment && is(static_cast<Assignment*>(s)->target, EK::HashIndex);
      if ((s->kind == SK::Assignment || s->kind == SK::ReturnStmt || s->kind == SK::Declaration) && !hash_target)
      {
        for (Expr* w : whole)
        {
          if (!is(w, EK::Guard)) { continue; }
          stmt_guards_.insert(w);
          Expr* g = static_cast<Guard*>(w)->expr;
          if (is(g, EK::Pipeline)) { chain_at_[g] = "statement"; }
        }
      }
      switch (s->kind)
      {
        case SK::CallStmt:
        {
          Expr* c = static_cast<CallStmt*>(s)->call;
          if (is(c, EK::Pipeline)) { chain_at_[c] = "effect"; }
          break;
        }
        case SK::Assignment:
        {
          Expr* v = static_cast<Assignment*>(s)->value;
          if (is(v, EK::Pipeline)) { chain_at_[v] = "statement"; }
          break;
        }
        case SK::ReturnStmt:
        {
          Expr* v = static_cast<ReturnStmt*>(s)->value;
          if (is(v, EK::Pipeline)) { chain_at_[v] = "statement"; }
          break;
        }
        default:
          break;
      }

      switch (s->kind)
      {
        case SK::Declaration:
        {
          auto decl = static_cast<Declaration*>(s);
          for (Declarator* d : decl->declarators)
          {
            std::vector<std::string> w = words(d->typespec_text.value_or(""));
            type_word(w.size() > 1 ? OptStr(w[1]) : std::nullopt, d->line);
            agrees(d);
            if (static_decls_.count(s) && d->init) { static_value(d); }
            in_static_ = static_decls_.count(s) > 0;
            if (d->init) { expr(d->init); }
            in_static_ = false;
            for (Expr* x : d->dims) { expr(x); }
            // A Private or a Public is the program's while it runs, not its
            // block's: one declared in an If is there after the EndIf.
            if (decl->scope == "private" || decl->scope == "public" || static_decls_.count(s))
            {
              keyword_name(d->name, d->line);
              continue;
            }
            declare(d->name, d->line, d->attributes, "local", d->init != nullptr);
            note_scalar(d);
            auto t = w.size() > 1 ? TYPED_START.find(lc(w[1])) : TYPED_START.end();
            if (t != TYPED_START.end() && !d->init && d->dims.empty() && decl->scope == "local")
            {
              if (Found f = find(lc(d->name)); f && f.v->line == d->line)
              {
                f.v->type = t->second.first;
                f.v->start = t->second.second;
              }
            }
          }
          break;
        }
        case SK::Assignment:
        {
          auto a = static_cast<Assignment*>(s);
          if (is(a->target, EK::AliasField))
          {
            dict_type(static_cast<const AliasField*>(a->target), a->value, a->op == ":=");
          }
          expr(a->value);
          if (a->op == "?=") { never_nil(a->target, a->op); }
          target(a->target, a->op);
          break;
        }
        case SK::CallStmt:
          expr(static_cast<CallStmt*>(s)->call);
          break;
        case SK::ReturnStmt:
          if (auto v = static_cast<ReturnStmt*>(s)->value) { expr(v); }
          break;
        case SK::IfStmt:
        {
          auto i = static_cast<IfStmt*>(s);
          if (i->header_decl)
          {
            expr(i->header_decl->init);
            agrees(i->header_decl);
          }
          in_block([&]
          {
            if (auto d = i->header_decl) { declare(d->name, d->line, d->attributes, "local", true); }
            for (Branch* b : i->branches)
            {
              then_cond(b->cond, b == i->branches.front() ? "an 'if'" : "an 'elseif'");
              expr(b->cond);
              body(b->body);
            }
            body(i->otherwise);
          });
          break;
        }
        case SK::WhileStmt:
        {
          auto w = static_cast<WhileStmt*>(s);
          if (w->header_decl)
          {
            expr(w->header_decl->init);
            agrees(w->header_decl);
          }
          in_block([&]
          {
            if (auto d = w->header_decl) { declare(d->name, d->line, d->attributes, "local", true); }
            then_cond(w->cond, "a 'while'");
            expr(w->cond);
            body(w->body);
          });
          break;
        }
        case SK::ForStmt:
        {
          auto f = static_cast<ForStmt*>(s);
          expr(f->from_);
          expr(f->to_);
          expr(f->step);
          if (!f->var_local) { write(f->var, true); }
          in_block([&]
          {
            if (f->var_local) { declare(f->var, f->line, {}, "loop"); }
            body(f->body);
          });
          break;
        }
        case SK::ForInStmt:
        {
          auto f = static_cast<ForInStmt*>(s);
          if (is(f->source, EK::Call) && lc(static_cast<const Call*>(f->source)->name) == "rows")
          {
            problem("'for ... in' over rows() is not supported: a loop body can move the table's position, "
                    "and 'loop' would skip the advance. Walk the area with a chain -- "
                    "rows(\"SA1\") |> tap([r] ...) -- or write the While loop yourself.");
          }
          expr(f->source);
          in_block([&]
          {
            declare(f->elem, f->line, {}, "loop");
            if (f->index) { declare(*f->index, f->line, {}, "loop"); }
            body(f->body);
          });
          break;
        }
        case SK::ForTimesStmt:
        {
          auto f = static_cast<ForTimesStmt*>(s);
          expr(f->count);
          in_block([&] { body(f->body); });
          break;
        }
        case SK::CaseStmt:
        {
          auto c = static_cast<CaseStmt*>(s);
          if (c->subject_decl)
          {
            expr(c->subject_decl->init);
            agrees(c->subject_decl);
          }
          if (auto a = c->subject_assign)
          {
            expr(a->value);
            target(a->target, a->op);
          }
          in_block([&]
          {
            if (auto d = c->subject_decl) { declare(d->name, d->line, d->attributes, "local", true); }
            for (Branch* b : c->branches)
            {
              then_cond(b->cond, "a 'case'");
              expr(b->cond);
              body(b->body);
            }
            body(c->otherwise);
          });
          break;
        }
        case SK::SequenceStmt:
        {
          auto q = static_cast<SequenceStmt*>(s);
          in_block([&] { body(q->body); });
          if (q->error_var && !bytecode_)
          {
            // Probes xdp to xdr, on 24.3.1.9, in TL++ and AdvPL alike: inside,
            // the function's Locals are Nil, and they come back untouched.
            warned.push_back({ q->recover_line ? q->recover_line : line_,
                               "'Recover Using " + *q->error_var + "': the AppServer runs this Recover with every "
                               "Local Nil but " + *q->error_var + ", and gives the function's back as they were at "
                               "End Sequence -- nothing assigned there stays, " + *q->error_var + " included. A "
                               "plain Recover has the function's Locals; the Break's value can go in a Static first" });
          }
          if (q->error_var) { write(*q->error_var); }
          in_block([&] { body(q->recover); });
          break;
        }
        case SK::TryStmt:
        {
          auto q = static_cast<TryStmt*>(s);
          in_block([&] { body(q->body); });
          if (q->error_var) { write(*q->error_var); }
          in_block([&] { body(q->handler); });
          in_block([&] { body(q->finally); });
          break;
        }
        case SK::TransactionStmt:
        {
          auto q = static_cast<TransactionStmt*>(s);
          in_block([&] { body(q->body); });
          break;
        }
        case SK::BreakStmt:
          if (static_cast<BreakStmt*>(s)->empty_call) { problem(BREAK_EMPTY); }
          if (auto v = static_cast<BreakStmt*>(s)->value) { expr(v); }
          break;
        case SK::NoOpStmt:
        {
          const std::string& w = static_cast<NoOpStmt*>(s)->word;
          warning(lc(w) == "default"
                  ? "'" + w + "' is no label of Do Case's -- 'Otherwise' is: the AppServer takes it as a name on its own, "
                    + "the line does nothing (W0001), and the lines after it belong to the case before"
                  : "'" + w + "' is no TL++ keyword: the AppServer takes it as a name on its own, "
                    + "and the line does nothing (W0001)");
          break;
        }
        case SK::DefaultStmt:
          for (Assignment* p : static_cast<DefaultStmt*>(s)->pairs)
          {
            expr(p->value);
            target(p->target, "+=");
          }
          break;
        case SK::UsingAlias:
        {
          auto u = static_cast<UsingAlias*>(s);
          if (u->order) { expr(u->order); }
          if (find(lc(u->area))) { read(u->area); } else { opened_.insert(uc(u->area)); }
          in_block([&] { body(u->body); });
          break;
        }
        case SK::WithObject:
        {
          auto w = static_cast<WithObject*>(s);
          expr(w->subject);
          in_block([&] { body(w->body); });
          break;
        }
        case SK::Modified:
        {
          auto m = static_cast<Modified*>(s);
          then_cond(m->cond, "a postfix '" + lc(m->op) + "'");
          expr(m->cond);
          stmt(m->stmt);
          break;
        }
        case SK::Deferred:
        {
          bool saved = in_defer_;
          in_defer_ = true;
          stmt(static_cast<Deferred*>(s)->stmt);
          in_defer_ = saved;
          break;
        }
        case SK::RawStmt:
        {
          auto r = static_cast<RawStmt*>(s);
          std::string l = r->lines.empty() ? std::string() : trim(r->lines[0]);
          auto starts = [&](const char* w)
          {
            std::size_t n = std::char_traits<char>::length(w);
            return l.size() >= n && lc(l.substr(0, n)) == w && (l.size() == n || !is_w(static_cast<unsigned char>(l[n])));
          };
          if (starts("tcquery") || starts("beginsql"))
          {
            // 'TCQUERY ... ALIAS "QRY"', 'BeginSql Alias "QRY"': the area is
            // opened here.
            std::string u = lc(l);
            std::size_t a = u.find(" alias ");
            if (a != std::string::npos)
            {
              std::size_t q = l.find_first_not_of(" \t", a + 7);
              if (q != std::string::npos && (l[q] == '"' || l[q] == '\''))
              {
                std::size_t e = l.find(l[q], q + 1);
                if (e != std::string::npos) { opened_.insert(uc(l.substr(q + 1, e - q - 1))); }
              }
            }
          }
          if (!tcquery_ok_ && starts("tcquery"))
          {
            problem("'" + l.substr(0, 7) + "' is a command of topconn.ch, which this file does not include: "
                    + "without it the AppServer refuses the line (\"C2003 Syntax Error\").");
          }
          for (const std::string& x : r->lines) { raw_reads(x); }
          break;
        }
        default:
          break;
      }
    }

    void Checker::target(Expr* t, const std::string& op)
    {
      if (is(t, EK::Name)) { write(name_of(t), !(op == ":=" || op == "=")); }
      else { expr(t); }
    }

    // A '?:' on a name, or a '?=' to it, declared with a type and no value,
    // and not assigned since: TL++ started it at its type's value, not Nil.
    void Checker::never_nil(const Expr* e, const std::string& op)
    {
      if (!is(e, EK::Name) || in_static_ || advpl_) { return; }
      const std::string& name = name_of(e);
      Found f = find(lc(name));
      if (!f || f.v->start.empty() || f.v->writes > 0) { return; }
      warning("'" + name + "' is declared as " + f.v->type + " with no value: TL++ starts it at " + f.v->start
              + ", not Nil, so '" + op + "' " + (op == "?=" ? "never assigns it" : "gives it and never its alternative")
              + " (with no type it would start at Nil)");
    }

    // 'j:name' on a name declared as a JsonObject: the AppServer has no
    // member by name in one, to read or to write (probes xds and xdt, on
    // 24.3.1.9).
    void Checker::json_member(const Member* m)
    {
      if (!is(m->base, EK::Name) || !json_.count(lc(name_of(m->base)))) { return; }
      const std::string& n = name_of(m->base);
      warning("'" + n + ":" + m->name + "': the AppServer has no member by name in a JsonObject -- \"invalid property "
              + uc(m->name) + "\" -- its key is " + n + "[\"" + m->name + "\"]");
    }

    void Checker::note_scalar(const Declarator* d)
    {
      std::string k = lc(d->name);
      // typespec-text.subst(/:i ^ 'as' \s+ /, '').lc
      std::string type = d->typespec_text.value_or("");
      if (type.size() > 2 && lc(type.substr(0, 2)) == "as" && (CHAR_CLASS[static_cast<unsigned char>(type[2])] & C_S))
      {
        std::size_t i = 2;
        while (i < type.size() && (CHAR_CLASS[static_cast<unsigned char>(type[i])] & C_S)) { i++; }
        type = type.substr(i);
      }
      type = lc(type);
      // A JsonObject: a JSON literal, JsonObject():New(), 'as JSON'.
      auto m = is(d->init, EK::MethodCall) ? static_cast<const MethodCall*>(d->init) : nullptr;
      if (type == "json" || is(d->init, EK::JsonLit)
          || (m && lc(m->name) == "new" && is(m->base, EK::Call) && lc(static_cast<const Call*>(m->base)->name) == "jsonobject"))
      {
        json_.insert(k);
      }
      else
      {
        json_.erase(k);
      }
      if (SCALAR_TYPES.count(type))
      {
        scalar_[k] = " -- it is declared 'as " + type + "'";
      }
      else if (is_literal(d->init) && is_scalar(d->init))
      {
        scalar_[k] = " -- it was declared as " + static_cast<const Literal*>(d->init)->text;
      }
    }

    // ---- expressions --------------------------------------------------------
    void Checker::expr(Expr* e)
    {
      if (!e) { return; }
      EK k = e->kind;
      if (k == EK::Name)
      {
        read(name_of(e));
        return;
      }
      if (k == EK::Literal)
      {
        if (static_cast<Literal*>(e)->type == "Character") { unclosed(static_cast<Literal*>(e)); }
        return;
      }
      bool field_compare = false;
      if (k == EK::SafeMember) { json_member(static_cast<Member*>(e)); }
      if (k == EK::Binary)
      {
        auto b = static_cast<Binary*>(e);
        field_compare = COMPARE.count(b->op) && (is(b->left, EK::AliasField) || is(b->right, EK::AliasField));
        if (b->op == "?:") { never_nil(b->left, b->op); }
        // A number and a string, written as such, under arithmetic: TL++'s
        // compiler refuses it (probe xdp: 1 + "a"); AdvPL's takes it.
        if (!advpl_ && b->left && b->right && is(b->left, EK::Literal) && is(b->right, EK::Literal)
            && (b->op == "+" || b->op == "-" || b->op == "*" || b->op == "/" || b->op == "%" || b->op == "^"
                || b->op == "**"))
        {
          auto letter = [](const Expr* x) -> std::string
          {
            const std::string& t = static_cast<const Literal*>(x)->type;
            return t == "Numeric" ? "N" : t == "Character" ? "C" : "";
          };
          std::string l = letter(b->left);
          std::string r = letter(b->right);
          if (!l.empty() && !r.empty() && l != r)
          {
            problem("'" + b->op + "' between a number and a string: TL++ refuses it -- \"Incompatible types between "
                    + l + " and " + r + "\"");
          }
        }
      }
      if (k == EK::Index || k == EK::Member || k == EK::MethodCall || (k == EK::Binary && !field_compare))
      {
        if (k == EK::Member)
        {
          constructed(static_cast<Member*>(e)->base, ":" + static_cast<Member*>(e)->name);
          json_member(static_cast<Member*>(e));
        }
        else if (k == EK::MethodCall)
        {
          auto m = static_cast<MethodCall*>(e);
          constructed(m->base, ":" + m->name + "()");
          constructor(m);
        }
        for (Expr* x : subexprs(e)) { expr(x); }
        return;
      }
      if (is_literal(e) && static_cast<Literal*>(e)->type == "Character") { unclosed(static_cast<Literal*>(e)); }
      switch (k)
      {
        case EK::UserTrans:
        {
          auto u = static_cast<UserTrans*>(e);
          if (u->base) { expr(u->base); }
          raw_reads(u->text);
          break;
        }
        case EK::CodeBlock:
        case EK::Lambda:
        {
          auto c = static_cast<CodeBlock*>(e);
          Scope* outer = scope_;
          scope_ = new_scope(outer, true);
          for (const std::string& p : c->params) { declare(p, line_, {}, "block-param"); }
          for (Expr* x : c->body) { expr(x); }
          scope_ = outer;
          break;
        }
        case EK::InAlias:
          alias_base(static_cast<InAlias*>(e)->base);
          break;
        case EK::AliasField:
        {
          auto a = static_cast<AliasField*>(e);
          field(a);
          alias_base(a->base);
          if (a->macro) { expr(a->macro); }
          break;
        }
        case EK::Ref:
        {
          Expr* t = static_cast<Ref*>(e)->target;
          if (is(t, EK::Name)) { by_ref(name_of(t)); } else { expr(t); }
          break;
        }
        case EK::AssignExpr:
        {
          auto a = static_cast<AssignExpr*>(e);
          if (is(a->target, EK::AliasField))
          {
            dict_type(static_cast<const AliasField*>(a->target), a->value, a->op == ":=");
          }
          expr(a->value);
          target(a->target, a->op);
          break;
        }
        case EK::Binary:
        {
          // A field compared with a literal, either way round.
          auto b = static_cast<Binary*>(e);
          if (is(b->left, EK::AliasField)) { dict_type(static_cast<const AliasField*>(b->left), b->right, false); }
          else { dict_type(static_cast<const AliasField*>(b->right), b->left, false); }
          for (Expr* x : subexprs(e)) { expr(x); }
          break;
        }
        case EK::Call:
        {
          auto c = static_cast<Call*>(e);
          call(c);
          // StaticCall(SOURCE, Function, ...): a source's name and a function's,
          // not variables.
          std::size_t skip = lc(c->name) == "staticcall" ? 2 : 0;
          for (std::size_t i = 0; i < c->args.size(); i++)
          {
            if (i < skip && is(c->args[i], EK::Name)) { continue; }
            if (i == 0) { expr(c->args[i]); } else { block_arg(c->name, c->args[i]); }
          }
          break;
        }
        case EK::Pipeline:
        {
          auto p = static_cast<Pipeline*>(e);
          chain(p);
          expr(p->source);
          for (const Call* st : p->stages)
          {
            for (Expr* a : st->args) { block_arg(st->name, a); }
          }
          break;
        }
        case EK::Guard:
        {
          auto g = static_cast<Guard*>(e);
          if (const Call* c = source_of(g->expr))
          {
            problem("'fallback' cannot guard a walk over " + lc(c->name) + "(). The guard needs an expression "
                    + "and a walk is a loop. Assign the chain first, then guard what uses it.");
          }
          if (is(g->expr, EK::Pipeline) && source_of(g->expr)) { chains_ok_.insert(g->expr); }
          if (is(g->expr, EK::Pipeline) && !stmt_guards_.count(g)) { guarded_.insert(g->expr); }
          expr(g->expr);
          expr(g->fallback);
          break;
        }
        default:
          for (Expr* x : subexprs(e)) { expr(x); }
          break;
      }
    }

    // 'Name():M(...)', TL++'s form for an object of the class Name -- 'Name'
    // with no arguments.
    void Checker::constructor(const MethodCall* m)
    {
      if (is(m->base, EK::Call) && static_cast<const Call*>(m->base)->args.empty()) { made_.insert(m->base); }
    }

    // A member or a method after 'Name():M(...)': TL++ takes nothing there
    // (tried on 24.3.1.9).
    void Checker::constructed(const Expr* base, const std::string& after)
    {
      if (advpl_ || !is(base, EK::MethodCall)) { return; }
      auto m = static_cast<const MethodCall*>(base);
      if (!is(m->base, EK::Call) || !static_cast<const Call*>(m->base)->args.empty()) { return; }
      std::string made = static_cast<const Call*>(m->base)->name + "():" + m->name + "()";
      problem("'" + made + "' makes an object, and TL++ takes nothing after it: '" + after
              + "' there is a syntax error to the AppServer (C2003). Keep the object in a variable first.");
    }

    void Checker::call(const Call* c)
    {
      std::string n = lc(c->name);
      // What the AppServer refused, in a .prw and a .tlpp (tried on 24.3.1.9).
      if (n == "staticcall")
      {
        warning("StaticCall() is of restricted use: the AppServer refused it in a compile without TOTVS' "
                "authorization (C9909 \"Staticall has a restrict use\")");
      }
      if (n == "break" && c->args.empty()) { problem(BREAK_EMPTY); }
      if (n == "freeobj" && !c->args.empty() && is(c->args[0], EK::Name) && lc(name_of(c->args[0])) == "self")
      {
        problem("FreeObj(" + name_of(c->args[0]) + "): the AppServer does not free the object a method runs in "
                + "(C9910 \"Free SELF object is not allowed\").");
      }
      // An area opened here: DbSelectArea("SA1") and the like, and rows("SA1").
      if (OPENERS.count(n) || n == "rows")
      {
        for (const Expr* a : c->args)
        {
          if (!is_literal(a) || is(a, EK::Interp) || static_cast<const Literal*>(a)->type != "Character") { continue; }
          std::string name = unquoted(static_cast<const Literal*>(a)->text);
          bool ident = !name.empty() && is_alpha(static_cast<unsigned char>(name[0]));
          for (std::size_t i = 1; ident && i < name.size(); i++)
          {
            ident = is_w(static_cast<unsigned char>(name[i]));
          }
          if (ident) { opened_.insert(uc(name)); }
        }
      }
      if ((n == "rows" || n == "lines") && !sources_ok_.count(c))
      {
        problem("'" + n + "()' is a source, and only reads at the head of a chain. Assign it, "
                + "or feed it into stages with '|>'.");
      }
      bool u = starts_with(n, "u_");
      std::string plain = u ? n.substr(2) : n;
      // A class of the file, called for its instance -- 'TransfArm():New()' --
      // though a User Function has its name: an idiom of Protheus', which a
      // file of a class compiles with a function of the same name.
      if (!u && classes_.count(n))
      {
        // In TL++ only 'Name():M(...)' makes an object: a class is no function
        // (tried on 24.3.1.9).
        if (!advpl_ && !made_.count(c))
        {
          problem("'" + c->name + "' is a class: only '" + c->name + "():New(...)' makes an object of it -- a "
                  + "class is no function, and '" + c->name + "(" + (c->args.empty() ? "" : "...")
                  + ")' fails when it runs (\"cannot find function " + uc(c->name) + " in AppMap\").");
        }
        return;
      }
      // A Web Function is found as 'w_' and its name, an Html Function as
      // 'h_' (tried on 24.3.1.9): called by the plain name, it is not found.
      static const std::unordered_map<std::string, std::pair<std::string, std::string>> PREFIXED =
      {
        { "web", { "w_", "Web Function" } },
        { "html", { "h_", "Html Function" } },
      };
      if (auto f = funcs_.find(n); f != funcs_.end())
      {
        if (auto w = PREFIXED.find(f->second.kind); w != PREFIXED.end())
        {
          problem("'" + c->name + "' is a " + w->second.second + " (line " + num(f->second.line) + "), so it is called "
                  + "as '" + w->second.first + c->name + "' -- the compiler puts the prefix on the declaration.");
          return;
        }
      }
      if (auto f = funcs_.find(plain); f != funcs_.end())
      {
        if (u && f->second.kind == "static")
        {
          problem("'" + c->name + "' -- " + f->second.name + " is a static function in this file, so it is called by "
                  + "its plain name, without the 'u_'.");
        }
        else if (!u && f->second.kind == "user")
        {
          problem("'" + c->name + "' is a user function (line " + num(f->second.line) + "), so it is called as "
                  + "'u_" + c->name + "' -- the compiler puts the prefix on the declaration.");
        }
      }
      auto f = funcs_.find(n);
      if (f == funcs_.end()) { f = funcs_.find(plain); }
      if (f == funcs_.end()) { return; }
      std::size_t given = 0;
      for (const Expr* a : c->args)
      {
        if (!is(a, EK::Omitted)) { given++; }
      }
      std::size_t params = f->second.params;
      if (given > params)
      {
        // AdvPL drops the rest; TL++ refuses the call (C9901, tried on 24.3.1.9).
        std::string m = f->second.name + "() takes " + std::to_string(params) + " parameter" + (params == 1 ? "" : "s")
                        + " (line " + num(f->second.line) + "), but is given " + std::to_string(given);
        if (advpl_) { warning(m + " -- the rest are dropped."); }
        else { problem(m + " -- TL++ refuses the call (\"More parameters used in function call than expected\")."); }
      }
    }

    void Checker::field(const AliasField* f)
    {
      auto word = alias_word(f);
      if (!word) { return; }
      std::string a = uc(*word);
      // 'M->x' and 'MEMVAR->x' are the variable x, a Private's or a Public's:
      // no area, and no field of the dictionary.
      if (a == "M" || a == "MEMVAR") { return; }
      if (!(opened_.count(a) || external_alias_.count(a) || starts_with(a, "__") || !warned_alias_.insert(a).second))
      {
        warning("nothing in this function opened " + a + ". Wrap the use in 'using alias " + a + " do', "
                + "or declare 'external alias " + a + "' if the caller opens it.");
      }
      if (!f->macro) { dict_field(*word, f->field); }
    }

    std::optional<std::string> Checker::alias_word(const AliasField* f) const
    {
      std::optional<std::string> word = f->alias;
      if (!word && is(f->base, EK::Name)) { word = name_of(f->base); }
      if (word && !find(lc(*word))) { return word; }
      return std::nullopt;
    }

    // ---- the dictionary -----------------------------------------------------
    void Checker::dict_field(const std::string& alias, const std::string& fieldname)
    {
      if (dictionary_.empty()) { return; }
      std::string a = uc(alias);
      std::string f = uc(fieldname);
      if (!dict_seen_.insert(num(line_) + " " + a + " " + f).second) { return; }
      auto t = dictionary_.find(a);
      if (t == dictionary_.end())
      {
        dict("alias '" + alias + "' is not in the dictionary. A table that is missing usually means "
             + "the export is out of date.");
        return;
      }
      if (t->second.count(f)) { return; }
      auto near = closest(f, t->second);
      std::string hint = near ? " Did you mean " + *near + "?" : "";
      dict("'" + alias + "->" + fieldname + "' is not a field of " + a + "." + hint);
    }

    void Checker::dict_type(const AliasField* ref, const Expr* lit, bool assigned)
    {
      if (dictionary_.empty()) { return; }
      auto word = alias_word(ref);
      if (!word) { return; }
      auto t = dictionary_.find(uc(*word));
      if (t == dictionary_.end()) { return; }
      auto entry = t->second.find(uc(ref->field));
      if (entry == t->second.end()) { return; }
      const std::string& kind = entry->second.type;
      int size = entry->second.size;
      if (kind.empty()) { return; }
      auto seen = literal_kind(lit);
      if (!seen) { return; }
      static const std::unordered_map<std::string, std::string> names =
      {
        { "C", "character" }, { "N", "numeric" }, { "D", "date" }, { "L", "logical" }, { "M", "memo" },
      };
      auto named = [&](const std::string& l)
      {
        auto it = names.find(l);
        return it != names.end() ? it->second : l;
      };
      std::string wanted = kind == "M" ? "C" : kind;
      std::string shown = *word + "->" + ref->field;
      if (seen->letter != wanted)
      {
        dict(shown + " is " + named(kind) + ", " + (assigned ? "assigned" : "compared with") + " a "
             + named(seen->letter) + " value.");
        return;
      }
      if (assigned && wanted == "C" && size && static_cast<int>(seen->text.size()) > size)
      {
        dict(shown + " holds " + num(size) + " characters, but is assigned " + std::to_string(seen->text.size()) + ".");
      }
    }

    void Checker::alias_base(Expr* b)
    {
      if (!b) { return; }
      if (!is(b, EK::Name))
      {
        expr(b);
        return;
      }
      if (find(lc(name_of(b)))) { read(name_of(b)); }
    }

    // ---- fusion -------------------------------------------------------------
    void Checker::fusion(const Pipeline* p)
    {
      if (p->stages.empty()) { return; }
      auto at = chain_at_.find(p);
      std::string where = at != chain_at_.end() ? at->second : "value";
      if (where != "value" && !guarded_.count(p)) { loose_left(p); }
      if (guarded_.count(p) && !is_source(p->source)
          && fuse_from(p->stages, [&](const std::string& n) { return static_cast<bool>(find(n)); }, where == "effect") >= 0)
      {
        warning("'fallback' inside an expression turns off fusion for this chain -- a guard there needs an "
                "expression and a fused loop is not one, so each stage builds an array again. Make the guard "
                "the whole value of the statement, or guard the part that can fail and leave the chain outside it.");
      }
    }

    void Checker::loose_left(const Pipeline* p)
    {
      if (!source_) { return; }
      const Expr* h = p->source;
      if (!(h->from >= 0 && h->to > h->from)) { return; }
      std::string_view src = *source_;
      std::size_t from = std::min(static_cast<std::size_t>(h->from), src.size());
      std::size_t to = std::min(static_cast<std::size_t>(h->to), src.size());
      std::string text = trim(src.substr(from, to - from));
      // What is outside brackets and strings; '->' is an alias, not a '>'.
      std::string bare;
      int depth = 0;
      char quote = 0;
      for (char c : text)
      {
        if (quote)
        {
          if (c == quote || c == '\n' || c == '\r') { quote = 0; }
        }
        else if (c == '"' || c == '\'') { quote = c; }
        else if (c == '(' || c == '[' || c == '{') { depth++; }
        else if (c == ')' || c == ']' || c == '}') { depth--; }
        else if (depth == 0) { bare += c; }
      }
      std::string flat;
      for (std::size_t i = 0; i < bare.size(); i++)
      {
        if (bare[i] == '-' && i + 1 < bare.size() && bare[i + 1] == '>')
        {
          flat += ' ';
          i++;
        }
        else
        {
          flat += bare[i];
        }
      }
      std::string l = lc(flat);
      bool loose = l.find(".and.") != std::string::npos || l.find(".or.") != std::string::npos
                   || l.find_first_of("<>") != std::string::npos || l.find("==") != std::string::npos
                   || l.find("!=") != std::string::npos;
      if (!loose) { return; }
      warning("the whole left side of '|>' is the first argument, so '" + first_chars(text, 40) + "' is what gets "
              + "fed in. Put brackets around the part you meant to chain.");
    }

    void Checker::chain(const Pipeline* p)
    {
      fusion(p);
      const Expr* head = p->source;
      if (is_rows_or_lines(head) || is(head, EK::Interval))
      {
        sources_ok_.insert(head);
        if (!chains_ok_.count(p))
        {
          std::string what = is(head, EK::Interval) ? "a range" : lc(static_cast<const Call*>(head)->name) + "()";
          problem("a chain from " + what + " runs as a loop, before its statement, so it is only the whole value "
                  + "of 'x := ...', of a local, private or public, or of 'return', or a statement of its own. "
                  + "Assign it to a variable first, where it should run.");
        }
      }
      // Over rows("SA1"), before a map, 'r:A1_COD' is SA1's field A1_COD.
      if (!dictionary_.empty() && is(head, EK::Call) && lc(static_cast<const Call*>(head)->name) == "rows")
      {
        auto src0 = static_cast<const Call*>(head);
        const Expr* a0 = src0->args.empty() ? nullptr : src0->args[0];
        if (is_literal(a0) && !is(a0, EK::Interp) && static_cast<const Literal*>(a0)->type == "Character")
        {
          std::string alias = unquoted(static_cast<const Literal*>(a0)->text);
          for (const Call* st : p->stages)
          {
            const Expr* l = st->args.empty() ? nullptr : st->args[0];
            if (is(l, EK::Lambda) && static_cast<const Lambda*>(l)->params.size() == 1)
            {
              auto lam = static_cast<const Lambda*>(l);
              std::string param = lc(lam->params[0]);
              for (Expr* b : lam->body)
              {
                walk_expr(b, [&](Expr* x)
                {
                  if (!is_member(x)) { return; }
                  const Expr* base = static_cast<const Member*>(x)->base;
                  if (is(base, EK::Name) && lc(name_of(base)) == param)
                  {
                    dict_field(alias, static_cast<const Member*>(x)->name);
                  }
                });
              }
            }
            std::string n = lc(st->name);
            if (n == "map" || n == "expand") { break; }
          }
        }
      }
      const Expr* src = p->source;
      if (is_literal(src) && is_scalar(src))
      {
        scalar_source(static_cast<const Literal*>(src)->text, "");
      }
      else if (is(src, EK::Name))
      {
        if (auto w = scalar_.find(lc(name_of(src))); w != scalar_.end()) { scalar_source(name_of(src), w->second); }
      }
      // Over rows(), before a 'map' the element is the record.
      if (is(src, EK::Call) && lc(static_cast<const Call*>(src)->name) == "rows")
      {
        for (const Call* st : p->stages)
        {
          std::string n = lc(st->name);
          if (n == "map" || n == "expand") { break; }
          if (n == "distinctadjacent" && st->args.empty())
          {
            problem("distinctAdjacent over rows() needs a key -- the record is not a value to compare "
                    "against the previous one. Give it one, as distinctAdjacent([r] r:C6_NUM), or map first.");
            break;
          }
        }
      }
    }

    void Checker::scalar_source(const std::string& shown, const std::string& why)
    {
      problem(shown + " is a single value" + why + ", and a chain walks a collection. Write {" + shown + "} for a "
              + "one-element array, or 'lo..hi' for a range.");
    }

    // ---- the names xc keeps for itself --------------------------------------
    void reserved_name(std::vector<Finding>& found, const std::string& name, int line)
    {
      if (is_reserved(name)) { found.push_back({ line, "Cannot use reserved word '" + name + "' as a variable name." }); }
    }

    void generated_name(std::vector<Finding>& found, const std::string& name, int line)
    {
      if (is_generated(name))
      {
        found.push_back({ line, "'" + name + "' has the shape of a name xc generates, so it cannot be declared. "
                                + "Reserved: '<kind>_<depth>_<index>' -- fo_0_0, fv_1_2, s_1_0, b_0_x." });
      }
    }

    void names_of(std::vector<Finding>& found, const std::vector<Param*>& params, const Body& body, int line)
    {
      for (const Param* q : params) { reserved_name(found, q->name, line); }
      for (const Stmt* s : body)
      {
        if (s->kind != SK::Declaration) { continue; }
        for (const Declarator* d : static_cast<const Declaration*>(s)->declarators)
        {
          generated_name(found, d->name, d->line);
        }
      }
      walk(body, [&](Stmt* s)
      {
        switch (s->kind)
        {
          case SK::Declaration:
            for (const Declarator* d : static_cast<Declaration*>(s)->declarators) { reserved_name(found, d->name, d->line); }
            break;
          case SK::ForStmt:
            reserved_name(found, static_cast<ForStmt*>(s)->var, s->line);
            break;
          case SK::ForInStmt:
          {
            auto f = static_cast<ForInStmt*>(s);
            reserved_name(found, f->elem, s->line);
            if (f->index) { reserved_name(found, *f->index, s->line); }
            break;
          }
          case SK::IfStmt:
            if (auto d = static_cast<IfStmt*>(s)->header_decl) { reserved_name(found, d->name, d->line); }
            break;
          case SK::WhileStmt:
            if (auto d = static_cast<WhileStmt*>(s)->header_decl) { reserved_name(found, d->name, d->line); }
            break;
          case SK::CaseStmt:
            if (auto d = static_cast<CaseStmt*>(s)->subject_decl) { reserved_name(found, d->name, d->line); }
            break;
          default:
            break;
        }
      });
    }
  }

  Checked check_all(const Program* p, int lines, const Dictionary& dictionary, bool strict,
                    std::optional<std::string_view> source, bool advpl, bool bytecode)
  {
    Checker c(lines, dictionary, strict, source, advpl, bytecode);
    c.program(p);
    for (Finding& f : decimal_problems(p, source, advpl)) { c.found.push_back(std::move(f)); }
    Checked typed = typed_problems(p, dictionary);
    for (Finding& f : typed.errors) { c.found.push_back(std::move(f)); }
    for (Finding& f : typed.warnings) { c.warned.push_back(std::move(f)); }
    return Checked{ tidy(c.found), tidy(c.warned) };
  }

  std::vector<Finding> check_names(const Program* p)
  {
    std::vector<Finding> found;
    for (const Declaration* d : p->statics)
    {
      for (const Declarator* v : d->declarators) { reserved_name(found, v->name, v->line); }
    }
    for (const FunctionDef* f : p->functions) { names_of(found, f->params, f->body, f->line); }
    for (const MethodImpl* m : p->methods) { names_of(found, m->params, m->body, m->line); }
    return tidy(found);
  }

  std::vector<Finding> check_declared_names(const Declaration* d)
  {
    std::vector<Finding> found;
    for (const Declarator* v : d->declarators)
    {
      reserved_name(found, v->name, v->line);
      generated_name(found, v->name, v->line);
    }
    return found;
  }

  Dictionary load_dictionary(const std::string& path)
  {
    std::ifstream in(path, std::ios::binary);
    if (!in) { throw std::runtime_error(path + ": cannot be read"); }
    std::ostringstream s;
    s << in.rdbuf();
    std::string bytes = s.str();
    std::string text;
    if (!utf8_to_cp1252(bytes, text)) { text = bytes; }
    std::vector<std::vector<std::string>> rows;
    for (const std::string& l : lines_of(text)) { rows.push_back(csv_row(l)); }
    if (rows.empty()) { throw std::runtime_error(path + ": empty dictionary"); }
    std::vector<std::string> head;
    for (const std::string& h : rows[0]) { head.push_back(uc(trim(h))); }
    auto column = [&](std::initializer_list<const char*> ws) -> int
    {
      for (std::size_t i = 0; i < head.size(); i++)
      {
        for (const char* w : ws)
        {
          if (head[i].find(w) != std::string::npos) { return static_cast<int>(i); }
        }
      }
      return -1;
    };
    int alias_at = column({ "ARQUIVO", "ALIAS", "TABELA", "TABLE" });
    int field_at = column({ "CAMPO", "FIELD" });
    int type_at = column({ "TIPO", "TYPE" });
    int size_at = column({ "TAMANHO", "SIZE", "LEN" });
    std::size_t first = 1;
    if (alias_at < 0 || field_at < 0)
    {
      alias_at = 0;
      field_at = 1;
      type_at = -1;
      size_at = -1;
      first = 0;
    }
    Dictionary dictionary;
    for (std::size_t r = first; r < rows.size(); r++)
    {
      const std::vector<std::string>& row = rows[r];
      int n = static_cast<int>(row.size());
      if (n <= std::max(alias_at, field_at)) { continue; }
      std::string alias = uc(trim(row[static_cast<std::size_t>(alias_at)]));
      std::string fieldname = uc(trim(row[static_cast<std::size_t>(field_at)]));
      if (alias.empty() || fieldname.empty()) { continue; }
      std::string kind = type_at >= 0 && n > type_at ? uc(trim(row[static_cast<std::size_t>(type_at)])).substr(0, 1) : "";
      std::string digits = size_at >= 0 && n > size_at ? trim(row[static_cast<std::size_t>(size_at)]) : "";
      bool all_digits = !digits.empty()
                        && std::all_of(digits.begin(), digits.end(), [](char c) { return c >= '0' && c <= '9'; });
      int size = 0;
      if (all_digits)
      {
        try { size = std::stoi(digits); } catch (const std::exception&) { size = 0; }
      }
      dictionary[alias][fieldname] = Field{ kind, size };
    }
    return dictionary;
  }
}
