#include "protheus.ch"

// A .prw counts a function's name to 10 characters, its 'U_' included:
// 'ProcessOrderCreated' and 'ProcessOrderUpdated' are one function there,
// PROCESSORD, and the AppServer refuses the second ("Redefinition of
// function PROCESSORD", tried on 24.3.1.9; limaduzz11's webhook-receiver
// .prw). A .tlpp counts the whole name.
Static Function ProcessOrderCreated(cId)
Return cId

Static Function ProcessOrderUpdated(cId)
Return cId

User Function HttpClientGet()
Return ProcessOrderCreated("1") + ProcessOrderUpdated("2")

User Function HttpClientPost()
Return nil
