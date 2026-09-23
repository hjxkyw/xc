# XC::Types -- checking that an initializer agrees with the declared type.
#
# The first thing built on the tree, and the first thing a regular expression
# could not do: knowing the TYPE of an expression takes knowing what it is --
# a literal, a sum, a call -- not just what it looks like.
#
#     local nX := "text" as Numeric       refused
#     local nX := 1 + 2 as Numeric        accepted: a sum of numbers is a number
#     local nX := f() as Numeric          accepted: there is no way to know
#
# Where there is no way to know, nothing is reported. A checker that refuses
# what it does not understand is a checker nobody uses.

use XC::AST;

unit module XC::Types;

# The operators that decide the type on their own, whatever the operands.
constant @LOGICAL-OPS = ('==', '!=', '<>', '<', '>', '<=', '>=', '$',
                         '.and.', '.or.', '!');
constant @NUMERIC-OPS = ('-', '*', '/', '%', 'neg');

# The type of an expression, or '?' when it cannot be told from here.
sub type-of(Expr $e --> Str) is export
{
  return UNKNOWN without $e;

  given $e
  {
    when Literal { .type }

    when Binary
    {
      # The node saved first: inside a 'given' the topic '$_' becomes
      # something else, and '.left' would be called on a string.
      my $node = $_;
      my $op = $node.op;

      # Lists, not 'when a | b' nor 'when a || b'. The junction does not
      # become a plain string in the end, and 'a || b' is just 'a' -- with
      # that, '!=' and '<' fell into "unknown", and
      # 'local nX := a != b as Numeric' was accepted without any test noticing.
      return 'Logical' if $op (elem) @LOGICAL-OPS;
      return 'Numeric' if $op (elem) @NUMERIC-OPS;

      # '+' adds numbers and joins strings. The result is only known when both
      # sides say the same thing.
      if $op eq '+'
      {
        my $a = type-of($node.left);
        my $b = type-of($node.right);
        return $a if $a eq $b && ($a eq 'Numeric' || $a eq 'Character');
      }

      UNKNOWN
    }

    # A call returns whatever the function returns, and that is not here.
    default { UNKNOWN }
  }
}

# The problems of a declaration, one per declarator that does not agree.
sub check-declaration(Declaration $d --> List) is export
{
  my @problems;
  for $d.declarators -> $v
  {
    next if $v.declared eq UNKNOWN;          # no 'as': nothing to check
    next without $v.init;                    # no initializer
    my $found = type-of($v.init);
    next if $found eq UNKNOWN;               # no way to know
    next if $v.declared eq 'Variant';        # accepts anything

    # Nil fits any type: it is how TL++ writes "not yet".
    next if $v.init ~~ Literal && $v.init.text.lc eq 'nil';

    if $found ne $v.declared
    {
      @problems.push:
        "line {$v.line}: '{$v.name}' is declared as {$v.declared}, "
        ~ "but its initial value is {$found}";
    }
  }
  @problems.List
}
