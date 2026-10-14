// xc -- walking the tree (see walk.h).

#include "walk.h"

namespace xc
{
  namespace
  {
    void add(std::vector<Expr*>& out, Expr* e)
    {
      if (e) { out.push_back(e); }
    }

    void add(std::vector<Expr*>& out, const std::vector<Expr*>& v)
    {
      for (Expr* e : v) { add(out, e); }
    }

    void add_pairs(std::vector<Expr*>& out, const std::vector<KeyValue*>& v)
    {
      for (const KeyValue* kv : v)
      {
        add(out, kv->key);
        add(out, kv->value);
      }
    }
  }

  std::vector<Expr*> subexprs(const Expr* e)
  {
    std::vector<Expr*> out;
    switch (e->kind)
    {
      case EK::UserTrans:
        add(out, static_cast<const UserTrans*>(e)->base);
        break;
      case EK::Call:
        add(out, static_cast<const Call*>(e)->args);
        break;
      case EK::Binary:
      {
        auto b = static_cast<const Binary*>(e);
        add(out, b->left);
        add(out, b->right);
        break;
      }
      case EK::Index:
      {
        auto x = static_cast<const Index*>(e);
        add(out, x->base);
        add(out, x->indices);
        break;
      }
      case EK::Member:
      case EK::SafeMember:
        add(out, static_cast<const Member*>(e)->base);
        break;
      case EK::HashIndex:
      {
        auto h = static_cast<const HashIndex*>(e);
        add(out, h->base);
        add(out, h->key);
        break;
      }
      case EK::Interval:
      {
        auto r = static_cast<const Interval*>(e);
        add(out, r->lo);
        add(out, r->hi);
        break;
      }
      case EK::MethodCall:
      case EK::SafeCall:
      {
        auto m = static_cast<const MethodCall*>(e);
        add(out, m->base);
        add(out, m->args);
        break;
      }
      case EK::AliasField:
      {
        auto a = static_cast<const AliasField*>(e);
        add(out, a->base);
        add(out, a->macro);
        break;
      }
      case EK::InAlias:
      {
        auto a = static_cast<const InAlias*>(e);
        add(out, a->base);
        add(out, a->expr);
        break;
      }
      case EK::Macro:
      {
        auto m = static_cast<const Macro*>(e);
        add(out, m->target);
        add(out, m->args);
        break;
      }
      case EK::Ref:
        add(out, static_cast<const Ref*>(e)->target);
        break;
      case EK::ExprList:
        add(out, static_cast<const ExprList*>(e)->items);
        break;
      case EK::AssignExpr:
      {
        auto a = static_cast<const AssignExpr*>(e);
        add(out, a->target);
        add(out, a->value);
        break;
      }
      case EK::ArrayLit:
        add(out, static_cast<const ArrayLit*>(e)->items);
        break;
      case EK::Interp:
        for (const Part& p : static_cast<const Interp*>(e)->parts)
        {
          if (auto x = std::get_if<Expr*>(&p)) { add(out, *x); }
        }
        break;
      case EK::JsonLit:
        add_pairs(out, static_cast<const JsonLit*>(e)->pairs);
        break;
      case EK::HashLit:
        add_pairs(out, static_cast<const HashLit*>(e)->pairs);
        break;
      case EK::CodeBlock:
      case EK::Lambda:
        add(out, static_cast<const CodeBlock*>(e)->body);
        break;
      case EK::Guard:
      {
        auto g = static_cast<const Guard*>(e);
        add(out, g->expr);
        add(out, g->fallback);
        break;
      }
      case EK::Pipeline:
      {
        auto p = static_cast<const Pipeline*>(e);
        add(out, p->source);
        for (Call* c : p->stages) { add(out, c); }
        break;
      }
      default:
        break;
    }
    return out;
  }

  void walk_expr(Expr* e, const std::function<void(Expr*)>& f)
  {
    if (!e) { return; }
    f(e);
    for (Expr* k : subexprs(e)) { walk_expr(k, f); }
  }

  std::vector<Expr*> exprs_of(const Stmt* s)
  {
    std::vector<Expr*> out;
    switch (s->kind)
    {
      case SK::Declaration:
        for (const Declarator* d : static_cast<const Declaration*>(s)->declarators) { add(out, d->init); }
        break;
      case SK::Assignment:
      {
        auto a = static_cast<const Assignment*>(s);
        add(out, a->target);
        add(out, a->value);
        break;
      }
      case SK::CallStmt:
        add(out, static_cast<const CallStmt*>(s)->call);
        break;
      case SK::ReturnStmt:
        add(out, static_cast<const ReturnStmt*>(s)->value);
        break;
      case SK::Annotation:
        add(out, static_cast<const Annotation*>(s)->args);
        break;
      case SK::Modified:
        add(out, static_cast<const Modified*>(s)->cond);
        break;
      case SK::IfStmt:
      {
        auto i = static_cast<const IfStmt*>(s);
        if (i->header_decl) { add(out, i->header_decl->init); }
        for (const Branch* b : i->branches) { add(out, b->cond); }
        break;
      }
      case SK::CaseStmt:
      {
        auto c = static_cast<const CaseStmt*>(s);
        if (c->subject_decl) { add(out, c->subject_decl->init); }
        if (c->subject_assign) { add(out, c->subject_assign->value); }
        for (const Branch* b : c->branches) { add(out, b->cond); }
        break;
      }
      case SK::WhileStmt:
      {
        auto w = static_cast<const WhileStmt*>(s);
        if (w->header_decl) { add(out, w->header_decl->init); }
        add(out, w->cond);
        break;
      }
      case SK::ForStmt:
      {
        auto f = static_cast<const ForStmt*>(s);
        add(out, f->from_);
        add(out, f->to_);
        add(out, f->step);
        break;
      }
      case SK::ForInStmt:
        add(out, static_cast<const ForInStmt*>(s)->source);
        break;
      case SK::ForTimesStmt:
        add(out, static_cast<const ForTimesStmt*>(s)->count);
        break;
      case SK::UsingAlias:
        add(out, static_cast<const UsingAlias*>(s)->order);
        break;
      case SK::WithObject:
        add(out, static_cast<const WithObject*>(s)->subject);
        break;
      case SK::BreakStmt:
        add(out, static_cast<const BreakStmt*>(s)->value);
        break;
      case SK::DefaultStmt:
        for (const Assignment* a : static_cast<const DefaultStmt*>(s)->pairs)
        {
          add(out, a->target);
          add(out, a->value);
        }
        break;
      default:
        break;
    }
    return out;
  }

  std::vector<Body> bodies_of(const Stmt* s)
  {
    switch (s->kind)
    {
      case SK::IfStmt:
      {
        auto i = static_cast<const IfStmt*>(s);
        std::vector<Body> out;
        for (const Branch* b : i->branches) { out.push_back(b->body); }
        out.push_back(i->otherwise);
        return out;
      }
      case SK::CaseStmt:
      {
        auto c = static_cast<const CaseStmt*>(s);
        std::vector<Body> out;
        for (const Branch* b : c->branches) { out.push_back(b->body); }
        out.push_back(c->otherwise);
        return out;
      }
      case SK::WhileStmt:        return { static_cast<const WhileStmt*>(s)->body };
      case SK::ForStmt:          return { static_cast<const ForStmt*>(s)->body };
      case SK::ForInStmt:        return { static_cast<const ForInStmt*>(s)->body };
      case SK::ForTimesStmt:     return { static_cast<const ForTimesStmt*>(s)->body };
      case SK::UsingAlias:       return { static_cast<const UsingAlias*>(s)->body };
      case SK::WithObject:       return { static_cast<const WithObject*>(s)->body };
      case SK::TransactionStmt:  return { static_cast<const TransactionStmt*>(s)->body };
      case SK::SequenceStmt:
      {
        auto q = static_cast<const SequenceStmt*>(s);
        return { q->body, q->recover };
      }
      case SK::TryStmt:
      {
        auto t = static_cast<const TryStmt*>(s);
        return { t->body, t->handler, t->finally };
      }
      case SK::Modified:         return { Body{ static_cast<const Modified*>(s)->stmt } };
      case SK::Deferred:         return { Body{ static_cast<const Deferred*>(s)->stmt } };
      default:                   return {};
    }
  }

  void walk(const Body& body, const std::function<void(Stmt*)>& f)
  {
    for (Stmt* s : body)
    {
      f(s);
      for (const Body& b : bodies_of(s)) { walk(b, f); }
    }
  }
}
