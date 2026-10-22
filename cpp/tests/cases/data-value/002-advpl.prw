#include "protheus.ch"

// In AdvPL a typed Data starts at Nil too: each value is a warning.
Class Pedido
  Data nTotal As Numeric Init 0
  Data cObs As String Init ""
  Method New() Constructor
EndClass

Method New() Class Pedido
Return Self
