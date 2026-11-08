#include "protheus.ch"

// Clipper's DELETE, alone or with a word, and RENAME.
User Function More(cOld, cNew)
  Delete
  DELETE ALL
  Rename &cOld To &cNew
Return nil
