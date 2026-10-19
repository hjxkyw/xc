#include "protheus.ch"

// What the AppServer refused in a .prw and in a .tlpp alike (tried on
// 24.3.1.9): StaticCall() -- "Staticall has a restrict use" (C9909), in a
// compile without TOTVS' authorization: a warning -- and FreeObj(Self) in a
// method -- "Free SELF object is not allowed" (C9910): an error.
Class Upd
  Method New() Constructor
  Method Destroy()
EndClass

Method New() Class Upd
Return Self

Method Destroy() Class Upd
  FreeObj(SELF)
Return Nil

User Function Chama()
Return StaticCall(MATA010, A010Valid, 1)
