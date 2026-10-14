// xc -- a tree as JSON (see json.h).

#include "json.h"

#include <cstdio>

namespace xc
{
  namespace
  {
    class Writer
    {
    public:
      std::string out;

      void str(const std::string& s)
      {
        out += '"';
        for (unsigned char c : s)
        {
          if (c >= 0x20 && c <= 0x7E && c != '"' && c != '\\')
          {
            out += static_cast<char>(c);
          }
          else
          {
            char buf[8];
            std::snprintf(buf, sizeof buf, "\\u00%02X", c);
            out += buf;
          }
        }
        out += '"';
      }

      void opt(const OptStr& s)
      {
        if (s) { str(*s); } else { out += "null"; }
      }

      void num(long n) { out += std::to_string(n); }
      void boolean(bool b) { out += b ? "true" : "false"; }

      // '{"node":"X"' -- then fields, then close().
      void open(const char* node)
      {
        out += "{\"node\":\"";
        out += node;
        out += '"';
      }

      void key(const char* k)
      {
        out += ",\"";
        out += k;
        out += "\":";
      }

      void close() { out += '}'; }

      void expr(const Expr* e);
      void stmt(const Stmt* s);
      void body(const Body& b);
      void declarator(const Declarator* d);
      void param(const Param* p);
      void program(const Program* p);

      template <class T, class F>
      void list(const std::vector<T>& v, F each)
      {
        out += '[';
        for (std::size_t i = 0; i < v.size(); i++)
        {
          if (i) { out += ','; }
          each(v[i]);
        }
        out += ']';
      }

      void stail(const Stmt* s)
      {
        key("line");
        num(s->line);
        key("src-from");
        num(s->from);
        key("src-to");
        num(s->to);
        close();
      }

      void exprs(const std::vector<Expr*>& v)
      {
        out += '[';
        for (std::size_t i = 0; i < v.size(); i++)
        {
          if (i) { out += ','; }
          expr(v[i]);
        }
        out += ']';
      }

      void strs(const std::vector<std::string>& v)
      {
        out += '[';
        for (std::size_t i = 0; i < v.size(); i++)
        {
          if (i) { out += ','; }
          str(v[i]);
        }
        out += ']';
      }

      void pairs(const std::vector<KeyValue*>& v)
      {
        out += '[';
        for (std::size_t i = 0; i < v.size(); i++)
        {
          if (i) { out += ','; }
          open("KeyValue");
          key("key");
          expr(v[i]->key);
          key("value");
          expr(v[i]->value);
          close();
        }
        out += ']';
      }

      // What every expression ends with: Expr's own attributes.
      void tail(const Expr* e)
      {
        key("line");
        num(e->line);
        key("src-from");
        num(e->from);
        key("src-to");
        num(e->to);
        close();
      }

      void literal(const Literal* l)
      {
        key("type");
        str(l->type);
        key("text");
        str(l->text);
        tail(l);
      }
    };

    void Writer::expr(const Expr* e)
    {
      if (!e)
      {
        out += "null";
        return;
      }
      switch (e->kind)
      {
        case EK::Literal:
        {
          open("Literal");
          literal(static_cast<const Literal*>(e));
          return;
        }
        case EK::Name:
        {
          open("Name");
          key("name");
          str(static_cast<const Name*>(e)->name);
          break;
        }
        case EK::UserTrans:
        {
          auto u = static_cast<const UserTrans*>(e);
          open("UserTrans");
          key("text");
          str(u->text);
          key("base");
          expr(u->base);
          break;
        }
        case EK::Call:
        {
          auto c = static_cast<const Call*>(e);
          open("Call");
          key("name");
          str(c->name);
          key("args");
          exprs(c->args);
          break;
        }
        case EK::Binary:
        {
          auto b = static_cast<const Binary*>(e);
          open("Binary");
          key("op");
          str(b->op);
          key("left");
          expr(b->left);
          key("right");
          expr(b->right);
          break;
        }
        case EK::Index:
        {
          auto x = static_cast<const Index*>(e);
          open("Index");
          key("base");
          expr(x->base);
          key("indices");
          exprs(x->indices);
          break;
        }
        case EK::SelfRef:    open("SelfRef"); break;
        case EK::SubjectRef: open("SubjectRef"); break;
        case EK::Omitted:    open("Omitted"); break;
        case EK::Member:
        case EK::SafeMember:
        {
          auto m = static_cast<const Member*>(e);
          open(e->kind == EK::Member ? "Member" : "SafeMember");
          key("base");
          expr(m->base);
          key("name");
          str(m->name);
          break;
        }
        case EK::HashIndex:
        {
          auto h = static_cast<const HashIndex*>(e);
          open("HashIndex");
          key("base");
          expr(h->base);
          key("key");
          expr(h->key);
          break;
        }
        case EK::Interval:
        {
          auto i = static_cast<const Interval*>(e);
          open("Interval");
          key("lo");
          expr(i->lo);
          key("hi");
          expr(i->hi);
          break;
        }
        case EK::MethodCall:
        case EK::SafeCall:
        {
          auto m = static_cast<const MethodCall*>(e);
          open(e->kind == EK::MethodCall ? "MethodCall" : "SafeCall");
          key("base");
          expr(m->base);
          key("name");
          str(m->name);
          key("args");
          exprs(m->args);
          break;
        }
        case EK::AliasField:
        {
          auto a = static_cast<const AliasField*>(e);
          open("AliasField");
          key("base");
          expr(a->base);
          key("alias");
          opt(a->alias);
          key("field");
          str(a->field);
          key("macro");
          expr(a->macro);
          break;
        }
        case EK::InAlias:
        {
          auto a = static_cast<const InAlias*>(e);
          open("InAlias");
          key("base");
          expr(a->base);
          key("alias");
          opt(a->alias);
          key("expr");
          expr(a->expr);
          break;
        }
        case EK::Macro:
        {
          auto m = static_cast<const Macro*>(e);
          open("Macro");
          key("target");
          expr(m->target);
          key("called");
          boolean(m->called);
          key("args");
          exprs(m->args);
          break;
        }
        case EK::Ref:
        {
          open("Ref");
          key("target");
          expr(static_cast<const Ref*>(e)->target);
          break;
        }
        case EK::ExprList:
        {
          open("ExprList");
          key("items");
          exprs(static_cast<const ExprList*>(e)->items);
          break;
        }
        case EK::AssignExpr:
        {
          auto a = static_cast<const AssignExpr*>(e);
          open("AssignExpr");
          key("target");
          expr(a->target);
          key("op");
          str(a->op);
          key("value");
          expr(a->value);
          key("incdec");
          str(a->incdec);
          break;
        }
        case EK::ArrayLit:
        {
          auto a = static_cast<const ArrayLit*>(e);
          open("ArrayLit");
          key("items");
          exprs(a->items);
          literal(a);
          return;
        }
        case EK::Interp:
        {
          auto s = static_cast<const Interp*>(e);
          open("Interp");
          key("parts");
          out += '[';
          for (std::size_t i = 0; i < s->parts.size(); i++)
          {
            if (i) { out += ','; }
            if (auto t = std::get_if<std::string>(&s->parts[i])) { str(*t); }
            else { expr(std::get<Expr*>(s->parts[i])); }
          }
          out += ']';
          literal(s);
          return;
        }
        case EK::JsonLit:
        case EK::HashLit:
        {
          bool json = e->kind == EK::JsonLit;
          open(json ? "JsonLit" : "HashLit");
          key("pairs");
          pairs(json ? static_cast<const JsonLit*>(e)->pairs : static_cast<const HashLit*>(e)->pairs);
          literal(static_cast<const Literal*>(e));
          return;
        }
        case EK::CodeBlock:
        case EK::Lambda:
        {
          auto c = static_cast<const CodeBlock*>(e);
          open(e->kind == EK::CodeBlock ? "CodeBlock" : "Lambda");
          key("params");
          strs(c->params);
          key("body");
          exprs(c->body);
          literal(c);
          return;
        }
        case EK::Guard:
        {
          auto g = static_cast<const Guard*>(e);
          open("Guard");
          key("expr");
          expr(g->expr);
          key("fallback");
          expr(g->fallback);
          break;
        }
        case EK::Pipeline:
        {
          auto p = static_cast<const Pipeline*>(e);
          open("Pipeline");
          key("source");
          expr(p->source);
          key("stages");
          out += '[';
          for (std::size_t i = 0; i < p->stages.size(); i++)
          {
            if (i) { out += ','; }
            expr(p->stages[i]);
          }
          out += ']';
          break;
        }
      }
      tail(e);
    }
  }

  void Writer::body(const Body& b)
  {
    list(b, [&](const Stmt* s) { stmt(s); });
  }

  void Writer::declarator(const Declarator* d)
  {
    if (!d)
    {
      out += "null";
      return;
    }
    open("Declarator");
    key("name");
    str(d->name);
    key("init");
    expr(d->init);
    key("declared");
    str(d->declared);
    key("attributes");
    strs(d->attributes);
    key("line");
    num(d->line);
    key("type-first");
    boolean(d->type_first);
    key("typespec-text");
    opt(d->typespec_text);
    key("dims");
    exprs(d->dims);
    close();
  }

  void Writer::param(const Param* p)
  {
    if (!p)
    {
      out += "null";
      return;
    }
    open("Param");
    key("name");
    str(p->name);
    key("declared");
    str(p->declared);
    key("type-word");
    opt(p->type_word);
    key("attributes");
    strs(p->attributes);
    key("attrs-from");
    num(p->attrs_from);
    key("attrs-to");
    num(p->attrs_to);
    close();
  }

  void Writer::stmt(const Stmt* s)
  {
    if (!s)
    {
      out += "null";
      return;
    }
    auto branches = [&](const std::vector<Branch*>& v)
    {
      list(v, [&](const Branch* b)
      {
        open("Branch");
        key("cond");
        expr(b->cond);
        key("body");
        body(b->body);
        close();
      });
    };
    switch (s->kind)
    {
      case SK::Declaration:
      {
        auto d = static_cast<const Declaration*>(s);
        open("Declaration");
        key("scope");
        str(d->scope);
        key("declarators");
        list(d->declarators, [&](const Declarator* x) { declarator(x); });
        break;
      }
      case SK::Assignment:
      {
        auto a = static_cast<const Assignment*>(s);
        open("Assignment");
        key("target");
        expr(a->target);
        key("op");
        str(a->op);
        key("value");
        expr(a->value);
        break;
      }
      case SK::CallStmt:
      {
        open("CallStmt");
        key("call");
        expr(static_cast<const CallStmt*>(s)->call);
        break;
      }
      case SK::ReturnStmt:
      {
        open("ReturnStmt");
        key("value");
        expr(static_cast<const ReturnStmt*>(s)->value);
        break;
      }
      case SK::ExitStmt: open("ExitStmt"); break;
      case SK::LoopStmt: open("LoopStmt"); break;
      case SK::Annotation:
      {
        auto a = static_cast<const Annotation*>(s);
        open("Annotation");
        key("name");
        str(a->name);
        key("args");
        exprs(a->args);
        break;
      }
      case SK::IfStmt:
      {
        auto i = static_cast<const IfStmt*>(s);
        open("IfStmt");
        key("branches");
        branches(i->branches);
        key("otherwise");
        body(i->otherwise);
        key("header-decl");
        declarator(i->header_decl);
        break;
      }
      case SK::CaseStmt:
      {
        auto c = static_cast<const CaseStmt*>(s);
        open("CaseStmt");
        key("branches");
        branches(c->branches);
        key("otherwise");
        body(c->otherwise);
        key("subject-decl");
        declarator(c->subject_decl);
        key("subject-assign");
        stmt(c->subject_assign);
        break;
      }
      case SK::WhileStmt:
      {
        auto w = static_cast<const WhileStmt*>(s);
        open("WhileStmt");
        key("cond");
        expr(w->cond);
        key("body");
        body(w->body);
        key("header-decl");
        declarator(w->header_decl);
        break;
      }
      case SK::ForStmt:
      {
        auto f = static_cast<const ForStmt*>(s);
        open("ForStmt");
        key("var");
        str(f->var);
        key("var-local");
        boolean(f->var_local);
        key("from");
        expr(f->from_);
        key("to");
        expr(f->to_);
        key("step");
        expr(f->step);
        key("body");
        body(f->body);
        key("endname-from");
        num(f->endname_from);
        key("endname-to");
        num(f->endname_to);
        break;
      }
      case SK::ForInStmt:
      {
        auto f = static_cast<const ForInStmt*>(s);
        open("ForInStmt");
        key("elem");
        str(f->elem);
        key("index");
        opt(f->index);
        key("source");
        expr(f->source);
        key("body");
        body(f->body);
        key("endname-from");
        num(f->endname_from);
        key("endname-to");
        num(f->endname_to);
        break;
      }
      case SK::ForTimesStmt:
      {
        auto f = static_cast<const ForTimesStmt*>(s);
        open("ForTimesStmt");
        key("count");
        expr(f->count);
        key("body");
        body(f->body);
        break;
      }
      case SK::Modified:
      {
        auto m = static_cast<const Modified*>(s);
        open("Modified");
        key("stmt");
        stmt(m->stmt);
        key("op");
        str(m->op);
        key("cond");
        expr(m->cond);
        break;
      }
      case SK::Deferred:
      {
        open("Deferred");
        key("stmt");
        stmt(static_cast<const Deferred*>(s)->stmt);
        break;
      }
      case SK::UsingAlias:
      {
        auto u = static_cast<const UsingAlias*>(s);
        open("UsingAlias");
        key("area");
        str(u->area);
        key("order");
        expr(u->order);
        key("body");
        body(u->body);
        break;
      }
      case SK::WithObject:
      {
        auto w = static_cast<const WithObject*>(s);
        open("WithObject");
        key("subject");
        expr(w->subject);
        key("body");
        body(w->body);
        break;
      }
      case SK::RawStmt:
      {
        auto r = static_cast<const RawStmt*>(s);
        open("RawStmt");
        key("block");
        boolean(r->block);
        key("lines");
        strs(r->lines);
        break;
      }
      case SK::TryStmt:
      {
        auto t = static_cast<const TryStmt*>(s);
        open("TryStmt");
        key("body");
        body(t->body);
        key("error-var");
        opt(t->error_var);
        key("handler");
        body(t->handler);
        key("finally");
        body(t->finally);
        break;
      }
      case SK::TransactionStmt:
      {
        open("TransactionStmt");
        key("body");
        body(static_cast<const TransactionStmt*>(s)->body);
        break;
      }
      case SK::NoOpStmt:
      {
        open("NoOpStmt");
        key("word");
        str(static_cast<const NoOpStmt*>(s)->word);
        break;
      }
      case SK::BreakStmt:
      {
        open("BreakStmt");
        key("value");
        expr(static_cast<const BreakStmt*>(s)->value);
        break;
      }
      case SK::DefaultStmt:
      {
        open("DefaultStmt");
        key("pairs");
        list(static_cast<const DefaultStmt*>(s)->pairs, [&](const Assignment* a) { stmt(a); });
        break;
      }
      case SK::SequenceStmt:
      {
        auto q = static_cast<const SequenceStmt*>(s);
        open("SequenceStmt");
        key("body");
        body(q->body);
        key("has-recover");
        boolean(q->has_recover);
        key("error-var");
        opt(q->error_var);
        key("recover");
        body(q->recover);
        break;
      }
    }
    stail(s);
  }

  void Writer::program(const Program* p)
  {
    auto params = [&](const std::vector<Param*>& v) { list(v, [&](const Param* x) { param(x); }); };
    open("Program");
    key("namespace");
    opt(p->ns);
    key("usings");
    strs(p->usings);
    key("directives");
    strs(p->directives);
    key("annotations");
    list(p->annotations, [&](const Annotation* a) { stmt(a); });
    key("functions");
    list(p->functions, [&](const FunctionDef* f)
    {
      open("FunctionDef");
      key("type");
      str(f->type);
      key("name");
      str(f->name);
      key("params");
      params(f->params);
      key("annotations");
      list(f->annotations, [&](const Annotation* a) { stmt(a); });
      key("body");
      body(f->body);
      key("line");
      num(f->line);
      key("rettype-word");
      opt(f->rettype_word);
      close();
    });
    key("classes");
    list(p->classes, [&](const ClassDef* c)
    {
      open("ClassDef");
      key("name");
      str(c->name);
      key("supers");
      strs(c->supers);
      key("members");
      list(c->members, [&](const DataMember* m)
      {
        open("DataMember");
        key("name");
        str(m->name);
        key("type");
        opt(m->type);
        key("visibility");
        opt(m->visibility);
        close();
      });
      key("methods");
      list(c->methods, [&](const MethodSig* m)
      {
        open("MethodSig");
        key("name");
        str(m->name);
        key("params");
        params(m->params);
        key("visibility");
        opt(m->visibility);
        key("constructor");
        boolean(m->constructor);
        key("returns");
        opt(m->returns);
        close();
      });
      key("line");
      num(c->line);
      close();
    });
    key("methods");
    list(p->methods, [&](const MethodImpl* m)
    {
      open("MethodImpl");
      key("class-name");
      str(m->class_name);
      key("name");
      str(m->name);
      key("params");
      params(m->params);
      key("returns");
      opt(m->returns);
      key("body");
      body(m->body);
      key("line");
      num(m->line);
      close();
    });
    key("externals");
    list(p->externals, [&](const External* x)
    {
      open("External");
      key("alias");
      boolean(x->alias);
      key("names");
      strs(x->names);
      key("line");
      num(x->line);
      key("src-from");
      num(x->from);
      key("src-to");
      num(x->to);
      close();
    });
    key("statics");
    list(p->statics, [&](const Declaration* d) { stmt(d); });
    close();
  }

  std::string to_json(const Program* p)
  {
    Writer w;
    w.program(p);
    return std::move(w.out);
  }

  std::string to_json(const Expr* e)
  {
    Writer w;
    w.expr(e);
    return std::move(w.out);
  }
}
