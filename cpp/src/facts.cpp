// xc -- what the passes after the parser find in a tree (see facts.h).
//
//   unit statics | unit fn NAME [dw] [nw] | unit method CLASS:NAME [dw] [nw]
//   declared NAME...              the names declared_names() gives, sorted
//   v NAME [dw] [nw]              a static, and what its type is
//   s KIND LINE FROM              a statement (xcb.ch's kind)
//   e KIND FROM TO FLAGS...       an expression, then what is said of it
//   ! EFFECT MESSAGE              what chain_problems() says of a chain
//
// The flags: D N K a Decimal, a number, a constant (Decimals); >D >N a value
// that goes into one (decimal_values); verb block one src dp= np= of a
// call; set= of a set operator; read= write= of a 'h{k}'; misused of a
// lambda; split= ssplit= fuse= src= of a chain.

#include "facts.h"

#include <algorithm>
#include <unordered_set>
#include <vector>

#include "chains.h"
#include "chars.h"
#include "decimal.h"
#include "walk.h"

namespace xc
{
  namespace
  {
    std::string bits(const std::vector<bool>& v)
    {
      std::string out;
      for (bool b : v) { out += b ? '1' : '0'; }
      return out;
    }

    // Where each of some stages is among all of them, from 0: '-' for none.
    std::string places(const std::vector<Call*>& all, const std::vector<Call*>& some)
    {
      std::string out;
      for (const Call* c : some)
      {
        auto at = std::find(all.begin(), all.end(), c);
        out += (out.empty() ? "" : ",") + std::to_string(at - all.begin());
      }
      return out.empty() ? "-" : out;
    }

    std::string split_text(const std::vector<Call*>& all, const Split& s)
    {
      std::string t = "-";
      if (s.terminal) { t = places(all, { s.terminal }); }
      return places(all, s.fused) + "/" + t + "/" + places(all, s.rest);
    }

    std::string words_of(const OptStr& w)
    {
      return std::string(decimal_word(w) ? " dw" : "") + (numeric_word(w) ? " nw" : "");
    }

    class Facts
    {
    public:
      explicit Facts(bool advpl) : advpl_(advpl) {}

      std::string run(const Program* p)
      {
        if (!advpl_) { dec_.file(p); }
        out_ += "unit statics\n";
        dec_.function({}, {});
        dv_ = DecimalValues{};
        declared_.clear();
        for (const Declaration* d : p->statics)
        {
          for (const Declarator* v : d->declarators)
          {
            if (v->init && decimal_word(v->typespec_text)) { dv_.into_decimal.insert(v->init); }
          }
        }
        for (const Declaration* d : p->statics)
        {
          for (Declarator* v : d->declarators)
          {
            out_ += "v " + v->name + words_of(v->typespec_text) + "\n";
            walk_expr(v->init, [&](Expr* x) { expr(x); });
          }
        }
        for (const FunctionDef* f : p->functions)
        {
          unit("fn " + f->name, f->params, f->body, f->rettype_word);
        }
        for (const MethodImpl* m : p->methods)
        {
          unit("method " + m->class_name + ":" + m->name, m->params, m->body, m->returns);
        }
        return out_;
      }

    private:
      bool advpl_;
      Decimals dec_;
      DecimalValues dv_;
      std::unordered_set<std::string> declared_;
      std::string out_;

      Declared declared() const
      {
        return [this](const std::string& n) { return declared_.count(n) > 0; };
      }

      void unit(const std::string& head, const std::vector<Param*>& params, const Body& body, const OptStr& returns)
      {
        out_ += "unit " + head + words_of(returns) + "\n";
        dec_.function(params, body);
        dv_ = decimal_values(dec_, body, Returns{ decimal_word(returns), numeric_word(returns) });
        declared_ = declared_names(params, body);
        std::vector<std::string> names(declared_.begin(), declared_.end());
        std::sort(names.begin(), names.end());
        out_ += "declared";
        for (const std::string& n : names) { out_ += " " + n; }
        out_ += "\n";
        walk(body, [&](Stmt* s)
        {
          out_ += "s " + std::to_string(static_cast<int>(s->kind) + 101) + " " + std::to_string(s->line) + " "
                  + std::to_string(s->from) + "\n";
          for (Expr* e : exprs_of(s))
          {
            walk_expr(e, [&](Expr* x) { expr(x); });
          }
        });
      }

      void expr(Expr* e)
      {
        std::string t = "e " + std::to_string(static_cast<int>(e->kind) + 1) + " " + std::to_string(e->from) + " "
                        + std::to_string(e->to);
        if (dec_.decimal(e)) { t += " D"; }
        if (dec_.numeric(e)) { t += " N"; }
        if (dec_.constant(e)) { t += " K"; }
        if (dv_.into_decimal.count(e)) { t += " >D"; }
        if (dv_.into_numeric.count(e)) { t += " >N"; }
        std::vector<std::string> problems;
        switch (e->kind)
        {
          case EK::Call:
          {
            auto c = static_cast<const Call*>(e);
            if (is_runtime_verb(c->name)) { t += " verb"; }
            if (takes_block(lc(c->name))) { t += " block"; }
            if (one_array(c->name, c->args.size())) { t += " one"; }
            if (const std::vector<bool>* d = dec_.params_of(e)) { t += " dp=" + bits(*d); }
            if (const std::vector<bool>* n = dec_.numeric_params_of(e)) { t += " np=" + bits(*n); }
            break;
          }
          case EK::Binary:
          {
            std::string f = set_function(static_cast<const Binary*>(e)->op);
            if (!f.empty()) { t += " set=" + f; }
            break;
          }
          case EK::HashIndex:
          {
            auto h = static_cast<const HashIndex*>(e);
            t += " read=" + key_reader(h) + " write=" + key_writer(h);
            break;
          }
          case EK::Lambda:
          {
            auto l = static_cast<const Lambda*>(e);
            if (!l->params.empty() && record_misused(l)) { t += " misused"; }
            break;
          }
          case EK::Pipeline:
          {
            auto p = static_cast<const Pipeline*>(e);
            t += " split=" + split_text(p->stages, split_stages(p->stages, true, declared()));
            t += " ssplit=" + split_text(p->stages, split_stages(p->stages, false, declared()));
            t += " fuse=" + std::to_string(fuse_from(p->stages, declared(), false)) + ","
                 + std::to_string(fuse_from(p->stages, declared(), true));
            break;
          }
          default:
            break;
        }
        if (is_source(e)) { t += " src"; }
        if (const Expr* src = source_call(e))
        {
          t += " src=" + source_kind(src);
          for (int effect = 0; effect < 2; effect++)
          {
            for (const std::string& m : chain_problems(e, effect == 1, declared()))
            {
              problems.push_back("! " + std::to_string(effect) + " " + m);
            }
          }
        }
        out_ += t + "\n";
        for (const std::string& m : problems) { out_ += m + "\n"; }
      }
    };
  }

  std::string facts(const Program* p, bool advpl)
  {
    return "facts\n" + Facts(advpl).run(p);
  }
}
