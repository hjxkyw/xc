// xc -- the tree as text (see dump.h).

#include "dump.h"

#include <cstdio>

namespace xc
{
  namespace
  {
    const char* expr_kind(EK k)
    {
      switch (k)
      {
        case EK::Literal: return "Literal";
        case EK::Name: return "Name";
        case EK::UserTrans: return "UserTrans";
        case EK::Call: return "Call";
        case EK::Binary: return "Binary";
        case EK::Index: return "Index";
        case EK::SelfRef: return "SelfRef";
        case EK::SubjectRef: return "SubjectRef";
        case EK::Member: return "Member";
        case EK::SafeMember: return "SafeMember";
        case EK::HashIndex: return "HashIndex";
        case EK::Interval: return "Interval";
        case EK::MethodCall: return "MethodCall";
        case EK::SafeCall: return "SafeCall";
        case EK::AliasField: return "AliasField";
        case EK::InAlias: return "InAlias";
        case EK::Macro: return "Macro";
        case EK::Ref: return "Ref";
        case EK::Omitted: return "Omitted";
        case EK::ExprList: return "ExprList";
        case EK::AssignExpr: return "AssignExpr";
        case EK::ArrayLit: return "ArrayLit";
        case EK::Interp: return "Interp";
        case EK::JsonLit: return "JsonLit";
        case EK::HashLit: return "HashLit";
        case EK::CodeBlock: return "CodeBlock";
        case EK::Lambda: return "Lambda";
        case EK::Guard: return "Guard";
        case EK::Pipeline: return "Pipeline";
        case EK::Dot: return "Dot";
        case EK::DotCall: return "DotCall";
        case EK::Named: return "Named";
      }
      return "?";
    }

    const char* stmt_kind(SK k)
    {
      switch (k)
      {
        case SK::Declaration: return "Declaration";
        case SK::Assignment: return "Assignment";
        case SK::CallStmt: return "CallStmt";
        case SK::ReturnStmt: return "ReturnStmt";
        case SK::ExitStmt: return "ExitStmt";
        case SK::LoopStmt: return "LoopStmt";
        case SK::Annotation: return "Annotation";
        case SK::IfStmt: return "IfStmt";
        case SK::CaseStmt: return "CaseStmt";
        case SK::WhileStmt: return "WhileStmt";
        case SK::ForStmt: return "ForStmt";
        case SK::ForInStmt: return "ForInStmt";
        case SK::ForTimesStmt: return "ForTimesStmt";
        case SK::Modified: return "Modified";
        case SK::Deferred: return "Deferred";
        case SK::UsingAlias: return "UsingAlias";
        case SK::WithObject: return "WithObject";
        case SK::RawStmt: return "RawStmt";
        case SK::TryStmt: return "TryStmt";
        case SK::TransactionStmt: return "TransactionStmt";
        case SK::NoOpStmt: return "NoOpStmt";
        case SK::BreakStmt: return "BreakStmt";
        case SK::DefaultStmt: return "DefaultStmt";
        case SK::SequenceStmt: return "SequenceStmt";
      }
      return "?";
    }

    class Dumper
    {
    public:
      std::string out;

      void program(const Program* p)
      {
        head(0, "Program");
        opt(2, "ns", p->ns);
        strs(2, "usings", p->usings);
        strs(2, "directives", p->directives);
        count(2, "annotations", p->annotations.size());
        for (const Annotation* a : p->annotations) { stmt(4, a); }
        count(2, "functions", p->functions.size());
        for (const FunctionDef* f : p->functions) { function(4, f); }
        count(2, "classes", p->classes.size());
        for (const ClassDef* c : p->classes) { klass(4, c); }
        count(2, "methods", p->methods.size());
        for (const MethodImpl* m : p->methods) { method(4, m); }
        count(2, "externals", p->externals.size());
        for (const External* x : p->externals) { external(4, x); }
        count(2, "statics", p->statics.size());
        for (const Declaration* d : p->statics) { stmt(4, d); }
        if (p->types.empty()) { return; }
        count(2, "types", p->types.size());
        for (const TypeDef* t : p->types) { type(4, t); }
      }

      void one(const Expr* e) { expr(0, e); }

    private:
      void head(int in, const std::string& text)
      {
        out.append(static_cast<std::size_t>(in), ' ');
        out += text;
        out += '\n';
      }

      static std::string quoted(const std::string& s)
      {
        std::string q = "\"";
        for (char ch : s)
        {
          unsigned char u = static_cast<unsigned char>(ch);
          if (u == '\\' || u == '"')
          {
            q += '\\';
            q += ch;
          }
          else if (u < 32 || u > 126)
          {
            char b[8];
            std::snprintf(b, sizeof b, "\\x%02X", u);
            q += b;
          }
          else
          {
            q += ch;
          }
        }
        return q + "\"";
      }

      void num(int in, const char* name, long long n) { head(in, std::string(name) + " " + std::to_string(n)); }
      void flag(int in, const char* name, bool b) { head(in, std::string(name) + (b ? " true" : " false")); }
      void str(int in, const char* name, const std::string& s) { head(in, std::string(name) + " " + quoted(s)); }
      void opt(int in, const char* name, const OptStr& s) { head(in, std::string(name) + " " + (s ? quoted(*s) : "nil")); }
      void count(int in, const char* name, std::size_t n) { head(in, std::string(name) + " (" + std::to_string(n) + ")"); }

      void strs(int in, const char* name, const std::vector<std::string>& v)
      {
        std::string t = std::string(name) + " [";
        for (std::size_t i = 0; i < v.size(); i++) { t += (i ? ", " : "") + quoted(v[i]); }
        head(in, t + "]");
      }

      void child(int in, const char* name, const Expr* e)
      {
        if (!e)
        {
          head(in, std::string(name) + " nil");
          return;
        }
        head(in, name);
        expr(in + 2, e);
      }

      void exprs(int in, const char* name, const std::vector<Expr*>& v)
      {
        count(in, name, v.size());
        for (const Expr* e : v) { expr(in + 2, e); }
      }

      void pairs(int in, const char* name, const std::vector<KeyValue*>& v)
      {
        count(in, name, v.size());
        for (const KeyValue* kv : v)
        {
          head(in + 2, "KeyValue");
          child(in + 4, "key", kv->key);
          child(in + 4, "value", kv->value);
        }
      }

      void body(int in, const char* name, const Body& b)
      {
        count(in, name, b.size());
        for (const Stmt* s : b) { stmt(in + 2, s); }
      }

      void expr(int in, const Expr* e)
      {
        if (!e)
        {
          head(in, "nil");
          return;
        }
        head(in, expr_kind(e->kind));
        int f = in + 2;
        num(f, "line", e->line);
        num(f, "from", e->from);
        num(f, "to", e->to);
        switch (e->kind)
        {
          case EK::Literal:
          {
            auto x = static_cast<const Literal*>(e);
            str(f, "type", x->type);
            str(f, "text", x->text);
            break;
          }
          case EK::Name:
            str(f, "name", static_cast<const Name*>(e)->name);
            break;
          case EK::UserTrans:
          {
            auto x = static_cast<const UserTrans*>(e);
            str(f, "text", x->text);
            child(f, "base", x->base);
            break;
          }
          case EK::Call:
          {
            auto x = static_cast<const Call*>(e);
            str(f, "name", x->name);
            exprs(f, "args", x->args);
            break;
          }
          case EK::Binary:
          {
            auto x = static_cast<const Binary*>(e);
            str(f, "op", x->op);
            child(f, "left", x->left);
            child(f, "right", x->right);
            break;
          }
          case EK::Index:
          {
            auto x = static_cast<const Index*>(e);
            child(f, "base", x->base);
            exprs(f, "indices", x->indices);
            break;
          }
          case EK::SelfRef:
          case EK::SubjectRef:
          case EK::Omitted:
            break;
          case EK::Member:
          case EK::SafeMember:
          {
            auto x = static_cast<const Member*>(e);
            child(f, "base", x->base);
            str(f, "name", x->name);
            if (!x->of_type.empty())
            {
              str(f, "of_type", x->of_type);
              num(f, "pos", x->pos);
            }
            break;
          }
          case EK::HashIndex:
          {
            auto x = static_cast<const HashIndex*>(e);
            child(f, "base", x->base);
            child(f, "key", x->key);
            num(f, "set_kind", x->set_kind);
            break;
          }
          case EK::Interval:
          {
            auto x = static_cast<const Interval*>(e);
            child(f, "lo", x->lo);
            child(f, "hi", x->hi);
            break;
          }
          case EK::MethodCall:
          case EK::SafeCall:
          {
            auto x = static_cast<const MethodCall*>(e);
            child(f, "base", x->base);
            str(f, "name", x->name);
            exprs(f, "args", x->args);
            if (!x->of_type.empty()) { str(f, "of_type", x->of_type); }
            break;
          }
          case EK::Dot:
          {
            auto x = static_cast<const Dot*>(e);
            child(f, "base", x->base);
            str(f, "name", x->name);
            str(f, "of_type", x->of_type);
            num(f, "pos", x->pos);
            break;
          }
          case EK::DotCall:
          {
            auto x = static_cast<const DotCall*>(e);
            child(f, "base", x->base);
            str(f, "name", x->name);
            exprs(f, "args", x->args);
            str(f, "of_type", x->of_type);
            break;
          }
          case EK::Named:
          {
            auto x = static_cast<const Named*>(e);
            str(f, "name", x->name);
            child(f, "value", x->value);
            break;
          }
          case EK::AliasField:
          {
            auto x = static_cast<const AliasField*>(e);
            child(f, "base", x->base);
            opt(f, "alias", x->alias);
            str(f, "field", x->field);
            child(f, "macro", x->macro);
            break;
          }
          case EK::InAlias:
          {
            auto x = static_cast<const InAlias*>(e);
            child(f, "base", x->base);
            opt(f, "alias", x->alias);
            child(f, "expr", x->expr);
            break;
          }
          case EK::Macro:
          {
            auto x = static_cast<const Macro*>(e);
            child(f, "target", x->target);
            flag(f, "called", x->called);
            exprs(f, "args", x->args);
            break;
          }
          case EK::Ref:
            child(f, "target", static_cast<const Ref*>(e)->target);
            break;
          case EK::ExprList:
            exprs(f, "items", static_cast<const ExprList*>(e)->items);
            break;
          case EK::AssignExpr:
          {
            auto x = static_cast<const AssignExpr*>(e);
            child(f, "target", x->target);
            str(f, "op", x->op);
            child(f, "value", x->value);
            str(f, "incdec", x->incdec);
            break;
          }
          case EK::ArrayLit:
          {
            auto x = static_cast<const ArrayLit*>(e);
            str(f, "type", x->type);
            str(f, "text", x->text);
            exprs(f, "items", x->items);
            str(f, "elem", x->elem);
            break;
          }
          case EK::Interp:
          {
            auto x = static_cast<const Interp*>(e);
            str(f, "type", x->type);
            str(f, "text", x->text);
            count(f, "parts", x->parts.size());
            for (const Part& part : x->parts)
            {
              if (const std::string* s = std::get_if<std::string>(&part)) { head(f + 2, quoted(*s)); }
              else { expr(f + 2, std::get<Expr*>(part)); }
            }
            break;
          }
          case EK::JsonLit:
          {
            auto x = static_cast<const JsonLit*>(e);
            str(f, "type", x->type);
            str(f, "text", x->text);
            pairs(f, "pairs", x->pairs);
            break;
          }
          case EK::HashLit:
          {
            auto x = static_cast<const HashLit*>(e);
            str(f, "type", x->type);
            str(f, "text", x->text);
            pairs(f, "pairs", x->pairs);
            str(f, "key_type", x->key_type);
            str(f, "value_type", x->value_type);
            num(f, "set_kind", x->set_kind);
            break;
          }
          case EK::CodeBlock:
          case EK::Lambda:
          {
            auto x = static_cast<const CodeBlock*>(e);
            str(f, "type", x->type);
            str(f, "text", x->text);
            strs(f, "params", x->params);
            exprs(f, "body", x->body);
            break;
          }
          case EK::Guard:
          {
            auto x = static_cast<const Guard*>(e);
            child(f, "expr", x->expr);
            child(f, "fallback", x->fallback);
            break;
          }
          case EK::Pipeline:
          {
            auto x = static_cast<const Pipeline*>(e);
            child(f, "source", x->source);
            count(f, "stages", x->stages.size());
            for (const Call* c : x->stages) { expr(f + 2, c); }
            flag(f, "then", x->then);
            break;
          }
        }
      }

      void declarator(int in, const char* name, const Declarator* d)
      {
        if (!d)
        {
          head(in, std::string(name) + " nil");
          return;
        }
        head(in, name);
        int f = in + 2;
        head(f, "Declarator");
        f += 2;
        str(f, "name", d->name);
        child(f, "init", d->init);
        str(f, "declared", d->declared);
        strs(f, "attributes", d->attributes);
        num(f, "line", d->line);
        flag(f, "type_first", d->type_first);
        opt(f, "typespec_text", d->typespec_text);
        exprs(f, "dims", d->dims);
        str(f, "container", d->container);
        flag(f, "init_made", d->init_made);
      }

      void branches(int in, const std::vector<Branch*>& v)
      {
        count(in, "branches", v.size());
        for (const Branch* b : v)
        {
          head(in + 2, "Branch");
          child(in + 4, "cond", b->cond);
          body(in + 4, "body", b->body);
        }
      }

      void stmt(int in, const Stmt* s)
      {
        if (!s)
        {
          head(in, "nil");
          return;
        }
        head(in, stmt_kind(s->kind));
        int f = in + 2;
        num(f, "line", s->line);
        num(f, "from", s->from);
        num(f, "to", s->to);
        flag(f, "oneline", s->oneline);
        flag(f, "bare", s->bare);
        switch (s->kind)
        {
          case SK::Declaration:
          {
            auto x = static_cast<const Declaration*>(s);
            str(f, "scope", x->scope);
            count(f, "declarators", x->declarators.size());
            for (const Declarator* d : x->declarators) { declarator(f + 2, "-", d); }
            break;
          }
          case SK::Assignment:
          {
            auto x = static_cast<const Assignment*>(s);
            child(f, "target", x->target);
            str(f, "op", x->op);
            child(f, "value", x->value);
            break;
          }
          case SK::CallStmt:
            child(f, "call", static_cast<const CallStmt*>(s)->call);
            break;
          case SK::ReturnStmt:
            child(f, "value", static_cast<const ReturnStmt*>(s)->value);
            break;
          case SK::ExitStmt:
          case SK::LoopStmt:
            break;
          case SK::Annotation:
          {
            auto x = static_cast<const Annotation*>(s);
            str(f, "name", x->name);
            exprs(f, "args", x->args);
            break;
          }
          case SK::IfStmt:
          {
            auto x = static_cast<const IfStmt*>(s);
            branches(f, x->branches);
            body(f, "otherwise", x->otherwise);
            declarator(f, "header_decl", x->header_decl);
            break;
          }
          case SK::CaseStmt:
          {
            auto x = static_cast<const CaseStmt*>(s);
            branches(f, x->branches);
            body(f, "otherwise", x->otherwise);
            declarator(f, "subject_decl", x->subject_decl);
            if (x->subject_assign)
            {
              head(f, "subject_assign");
              stmt(f + 2, x->subject_assign);
            }
            else
            {
              head(f, "subject_assign nil");
            }
            break;
          }
          case SK::WhileStmt:
          {
            auto x = static_cast<const WhileStmt*>(s);
            child(f, "cond", x->cond);
            body(f, "body", x->body);
            declarator(f, "header_decl", x->header_decl);
            break;
          }
          case SK::ForStmt:
          {
            auto x = static_cast<const ForStmt*>(s);
            str(f, "var", x->var);
            flag(f, "var_local", x->var_local);
            child(f, "from_", x->from_);
            child(f, "to_", x->to_);
            child(f, "step", x->step);
            body(f, "body", x->body);
            num(f, "endname_from", x->endname_from);
            num(f, "endname_to", x->endname_to);
            break;
          }
          case SK::ForInStmt:
          {
            auto x = static_cast<const ForInStmt*>(s);
            str(f, "elem", x->elem);
            opt(f, "index", x->index);
            flag(f, "keyed", x->keyed);
            child(f, "source", x->source);
            body(f, "body", x->body);
            num(f, "endname_from", x->endname_from);
            num(f, "endname_to", x->endname_to);
            break;
          }
          case SK::ForTimesStmt:
          {
            auto x = static_cast<const ForTimesStmt*>(s);
            child(f, "count", x->count);
            body(f, "body", x->body);
            break;
          }
          case SK::Modified:
          {
            auto x = static_cast<const Modified*>(s);
            head(f, "stmt");
            stmt(f + 2, x->stmt);
            str(f, "op", x->op);
            child(f, "cond", x->cond);
            break;
          }
          case SK::Deferred:
            head(f, "stmt");
            stmt(f + 2, static_cast<const Deferred*>(s)->stmt);
            break;
          case SK::UsingAlias:
          {
            auto x = static_cast<const UsingAlias*>(s);
            str(f, "area", x->area);
            child(f, "order", x->order);
            body(f, "body", x->body);
            break;
          }
          case SK::WithObject:
          {
            auto x = static_cast<const WithObject*>(s);
            child(f, "subject", x->subject);
            body(f, "body", x->body);
            break;
          }
          case SK::RawStmt:
          {
            auto x = static_cast<const RawStmt*>(s);
            flag(f, "block", x->block);
            strs(f, "lines", x->lines);
            break;
          }
          case SK::TryStmt:
          {
            auto x = static_cast<const TryStmt*>(s);
            body(f, "body", x->body);
            opt(f, "error_var", x->error_var);
            body(f, "handler", x->handler);
            body(f, "finally", x->finally);
            break;
          }
          case SK::TransactionStmt:
            body(f, "body", static_cast<const TransactionStmt*>(s)->body);
            break;
          case SK::NoOpStmt:
            str(f, "word", static_cast<const NoOpStmt*>(s)->word);
            break;
          case SK::BreakStmt:
          {
            auto x = static_cast<const BreakStmt*>(s);
            child(f, "value", x->value);
            flag(f, "empty_call", x->empty_call);
            break;
          }
          case SK::DefaultStmt:
          {
            auto x = static_cast<const DefaultStmt*>(s);
            count(f, "pairs", x->pairs.size());
            for (const Assignment* a : x->pairs) { stmt(f + 2, a); }
            break;
          }
          case SK::SequenceStmt:
          {
            auto x = static_cast<const SequenceStmt*>(s);
            body(f, "body", x->body);
            flag(f, "has_recover", x->has_recover);
            opt(f, "error_var", x->error_var);
            num(f, "recover_line", x->recover_line);
            body(f, "recover", x->recover);
            break;
          }
        }
      }

      void params(int in, const std::vector<Param*>& v)
      {
        count(in, "params", v.size());
        for (const Param* q : v)
        {
          if (!q)
          {
            head(in + 2, "nil");
            continue;
          }
          head(in + 2, "Param");
          int f = in + 4;
          str(f, "name", q->name);
          str(f, "declared", q->declared);
          opt(f, "type_word", q->type_word);
          strs(f, "attributes", q->attributes);
          num(f, "attrs_from", q->attrs_from);
          num(f, "attrs_to", q->attrs_to);
          str(f, "container", q->container);
          num(f, "type_from", q->type_from);
          num(f, "type_to", q->type_to);
          str(f, "type_tlpp", q->type_tlpp);
        }
      }

      void function(int in, const FunctionDef* fd)
      {
        head(in, "FunctionDef");
        int f = in + 2;
        str(f, "type", fd->type);
        str(f, "name", fd->name);
        params(f, fd->params);
        count(f, "annotations", fd->annotations.size());
        for (const Annotation* a : fd->annotations) { stmt(f + 2, a); }
        body(f, "body", fd->body);
        num(f, "line", fd->line);
        opt(f, "rettype_word", fd->rettype_word);
        str(f, "ret_container", fd->ret_container);
        num(f, "ret_from", fd->ret_from);
        num(f, "ret_to", fd->ret_to);
        str(f, "ret_tlpp", fd->ret_tlpp);
        if (fd->of_type.empty()) { return; }
        str(f, "of_type", fd->of_type);
        str(f, "method", fd->method);
        num(f, "head_from", fd->head_from);
        num(f, "head_to", fd->head_to);
        num(f, "paren", fd->paren);
      }

      // A type: only a file that has one says it has any.
      void type(int in, const TypeDef* t)
      {
        head(in, "TypeDef");
        int f = in + 2;
        str(f, "name", t->name);
        if (!t->base.empty()) { str(f, "base", t->base); }
        num(f, "line", t->line);
        num(f, "from", t->from);
        num(f, "head_to", t->head_to);
        num(f, "end_from", t->end_from);
        num(f, "end_to", t->end_to);
        num(f, "end_line", t->end_line);
        count(f, "fields", t->fields.size());
        for (const TypeField* x : t->fields)
        {
          head(f + 2, "TypeField");
          num(f + 4, "from", x->from);
          num(f + 4, "to", x->to);
          declarator(f + 4, "decl", x->decl);
        }
        std::vector<std::string> names;
        for (const FunctionDef* m : t->methods) { names.push_back(m->name); }
        strs(f, "methods", names);
      }

      void klass(int in, const ClassDef* c)
      {
        head(in, "ClassDef");
        int f = in + 2;
        str(f, "name", c->name);
        strs(f, "supers", c->supers);
        strs(f, "ifaces", c->ifaces);
        count(f, "members", c->members.size());
        for (const DataMember* d : c->members)
        {
          head(f + 2, "DataMember");
          int g = f + 4;
          str(g, "name", d->name);
          opt(g, "type", d->type);
          opt(g, "visibility", d->visibility);
          num(g, "line", d->line);
          child(g, "init", d->init);
          str(g, "init_word", d->init_word);
          str(g, "container", d->container);
          num(g, "type_from", d->type_from);
          num(g, "type_to", d->type_to);
          str(g, "type_tlpp", d->type_tlpp);
        }
        count(f, "methods", c->methods.size());
        for (const MethodSig* m : c->methods)
        {
          head(f + 2, "MethodSig");
          int g = f + 4;
          str(g, "name", m->name);
          params(g, m->params);
          opt(g, "visibility", m->visibility);
          flag(g, "constructor", m->constructor);
          flag(g, "is_static", m->is_static);
          opt(g, "returns", m->returns);
          num(g, "line", m->line);
          str(g, "ret_container", m->ret_container);
          num(g, "ret_from", m->ret_from);
          num(g, "ret_to", m->ret_to);
          str(g, "ret_tlpp", m->ret_tlpp);
        }
        num(f, "line", c->line);
        flag(f, "iface", c->iface);
      }

      void method(int in, const MethodImpl* m)
      {
        head(in, "MethodImpl");
        int f = in + 2;
        str(f, "class_name", m->class_name);
        str(f, "name", m->name);
        params(f, m->params);
        opt(f, "returns", m->returns);
        body(f, "body", m->body);
        num(f, "line", m->line);
        flag(f, "ws", m->ws);
        str(f, "ret_container", m->ret_container);
        num(f, "ret_from", m->ret_from);
        num(f, "ret_to", m->ret_to);
        str(f, "ret_tlpp", m->ret_tlpp);
      }

      void external(int in, const External* x)
      {
        head(in, "External");
        int f = in + 2;
        flag(f, "alias", x->alias);
        strs(f, "names", x->names);
        num(f, "line", x->line);
        num(f, "from", x->from);
        num(f, "to", x->to);
      }
    };
  }

  std::string dump(const Program* p)
  {
    Dumper d;
    d.program(p);
    return d.out;
  }

  std::string dump_expr(const Expr* e)
  {
    Dumper d;
    d.one(e);
    return d.out;
  }
}
