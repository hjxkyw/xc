#include "totvs.ch"

user function f(cName, h)
  local jA := u_xtpl_jnew({{"name", cName}, {"qty", 3}})
  local jB := JsonObject():New()
  local jC := u_xtpl_jnew({{"k", u_xtpl_hget(h, "x")}})
return {jA, jB, jC}
