// An AdvPL source: no Decimal, and a type does not choose what a variable
// starts at -- every one starts at Nil.
User Function Legacy(nIn)
  Local nX as Numeric
  Local cY As Character
  ConOut(ValType(nX), ValType(cY), ValType(nIn))
Return nX
