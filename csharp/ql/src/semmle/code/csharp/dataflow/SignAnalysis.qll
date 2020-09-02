/**
 * Provides sign analysis to determine whether expression are always positive
 * or negative.
 *
 * The analysis is implemented as an abstract interpretation over the
 * three-valued domain `{negative, zero, positive}`.
 */

private import csharp
private import Ssa
private import SsaReadPosition
private import ConstantUtils
private import SsaUtils
private import semmle.code.csharp.controlflow.Guards as G
private import Linq.Helpers as Linq

private class Guard = G::Guard;

private newtype TSign =
  TNeg() or
  TZero() or
  TPos()

private class Sign extends TSign {
  /** Gets the string representation of the sign. */
  string toString() {
    result = "-" and this = TNeg()
    or
    result = "0" and this = TZero()
    or
    result = "+" and this = TPos()
  }

  /** Increments the sign. */
  Sign inc() {
    this = TNeg() and result = TNeg()
    or
    this = TNeg() and result = TZero()
    or
    this = TZero() and result = TPos()
    or
    this = TPos() and result = TPos()
  }

  /** Decrements the sign. */
  Sign dec() { result.inc() = this }

  /** Negates the sign. */
  Sign neg() {
    this = TNeg() and result = TPos()
    or
    this = TZero() and result = TZero()
    or
    this = TPos() and result = TNeg()
  }

  /** Bitwise complements the sign. */
  Sign bitnot() {
    this = TNeg() and result = TPos()
    or
    this = TNeg() and result = TZero()
    or
    this = TZero() and result = TNeg()
    or
    this = TPos() and result = TNeg()
  }

  /** Adds the two signs. */
  Sign add(Sign s) {
    this = TZero() and result = s
    or
    s = TZero() and result = this
    or
    this = s and this = result
    or
    this = TPos() and s = TNeg()
    or
    this = TNeg() and s = TPos()
  }

  /** Multiplies the two signs. */
  Sign mul(Sign s) {
    result = TZero() and this = TZero()
    or
    result = TZero() and s = TZero()
    or
    result = TNeg() and this = TPos() and s = TNeg()
    or
    result = TNeg() and this = TNeg() and s = TPos()
    or
    result = TPos() and this = TPos() and s = TPos()
    or
    result = TPos() and this = TNeg() and s = TNeg()
  }

  /** Integer divides the two signs. */
  Sign div(Sign s) {
    result = TZero() and s = TNeg()
    or
    result = TZero() and s = TPos() // ex: 3 / 5 = 0
    or
    result = TNeg() and this = TPos() and s = TNeg()
    or
    result = TNeg() and this = TNeg() and s = TPos()
    or
    result = TPos() and this = TPos() and s = TPos()
    or
    result = TPos() and this = TNeg() and s = TNeg()
  }

  /** Modulo divides the two signs. */
  Sign rem(Sign s) {
    result = TZero() and s = TNeg()
    or
    result = TZero() and s = TPos()
    or
    result = this and s = TNeg()
    or
    result = this and s = TPos()
  }

  /** Bitwise `and` the two signs. */
  Sign bitand(Sign s) {
    result = TZero() and this = TZero()
    or
    result = TZero() and s = TZero()
    or
    result = TZero() and this = TPos()
    or
    result = TZero() and s = TPos()
    or
    result = TNeg() and this = TNeg() and s = TNeg()
    or
    result = TPos() and this = TNeg() and s = TPos()
    or
    result = TPos() and this = TPos() and s = TNeg()
    or
    result = TPos() and this = TPos() and s = TPos()
  }

  /** Bitwise `or` the two signs. */
  Sign bitor(Sign s) {
    result = TZero() and this = TZero() and s = TZero()
    or
    result = TNeg() and this = TNeg()
    or
    result = TNeg() and s = TNeg()
    or
    result = TPos() and this = TPos() and s = TZero()
    or
    result = TPos() and this = TZero() and s = TPos()
    or
    result = TPos() and this = TPos() and s = TPos()
  }

  /** Bitwise `xor` the two signs. */
  Sign bitxor(Sign s) {
    result = TZero() and this = s
    or
    result = this and s = TZero()
    or
    result = s and this = TZero()
    or
    result = TPos() and this = TPos() and s = TPos()
    or
    result = TNeg() and this = TNeg() and s = TPos()
    or
    result = TNeg() and this = TPos() and s = TNeg()
    or
    result = TPos() and this = TNeg() and s = TNeg()
  }

  /** Left shifts the sign by `s`. */
  Sign lshift(Sign s) {
    result = TZero() and this = TZero()
    or
    result = this and s = TZero()
    or
    this != TZero() and s != TZero()
  }

  /** Right shifts the sign by `s`. */
  Sign rshift(Sign s) {
    result = TZero() and this = TZero()
    or
    result = this and s = TZero()
    or
    result = TNeg() and this = TNeg()
    or
    result != TNeg() and this = TPos() and s != TZero()
  }
}

/** Gets the sign of `e` if this can be directly determined. */
private Sign certainExprSign(Expr e) {
  exists(int i | e.(ConstantIntegerExpr).getIntValue() = i |
    i < 0 and result = TNeg()
    or
    i = 0 and result = TZero()
    or
    i > 0 and result = TPos()
  )
  or
  not exists(e.(ConstantIntegerExpr).getIntValue()) and
  (
    exists(float f |
      f = e.(LongLiteral).getValue().toFloat() or
      f = e.(RealLiteral).getValue().toFloat()
    |
      f < 0 and result = TNeg()
      or
      f = 0 and result = TZero()
      or
      f > 0 and result = TPos()
    )
    or
    exists(string charlit | charlit = e.(CharLiteral).getValue() |
      if charlit = "\\0" or charlit = "\\u0000" then result = TZero() else result = TPos()
    )
    or
    containerSizeAccess(e.(PropertyAccess)) and
    (result = TPos() or result = TZero())
    or
    e instanceof Linq::CountCall and
    (result = TPos() or result = TZero())
  )
}

private predicate containerSizeAccess(PropertyAccess pa) {
  propertyOverrides(pa.getTarget(), "System.Collections.Generic.IEnumerable<>", "Count") or
  propertyOverrides(pa.getTarget(), "System.Collections.ICollection", "Count") or
  propertyOverrides(pa.getTarget(), "System.String", "Length") or
  propertyOverrides(pa.getTarget(), "System.Array", "Length")
}

private class NumericOrCharType extends Type {
  NumericOrCharType() {
    this instanceof CharType or
    this instanceof IntegralType or
    this instanceof FloatingPointType or
    this instanceof DecimalType
  }
}

/** Holds if the sign of `e` is too complicated to determine. */
private predicate unknownSign(Expr e) {
  not exists(e.(ConstantIntegerExpr).getIntValue()) and
  (
    exists(IntegerLiteral lit | lit = e and not exists(lit.getValue().toInt()))
    or
    exists(LongLiteral lit | lit = e and not exists(lit.getValue().toFloat()))
    or
    exists(CastExpr cast, Type fromtyp |
      cast = e and
      fromtyp = cast.getExpr().getType() and
      not fromtyp instanceof NumericOrCharType
    )
    or
    // array access, indexer access
    e instanceof ElementAccess and e.getType() instanceof NumericOrCharType
    or
    // property access
    e instanceof PropertyAccess and e.getType() instanceof NumericOrCharType
    or
    //method call, local function call, ctor call, ...
    e instanceof Call and e.getType() instanceof NumericOrCharType
  )
}

/**
 * Holds if `lowerbound` is a lower bound for `v` at `pos`. This is restricted
 * to only include bounds for which we might determine a sign.
 */
private predicate lowerBound(Expr lowerbound, Definition v, SsaReadPosition pos, boolean isStrict) {
  exists(boolean testIsTrue, RelationalOperation comp |
    pos.hasReadOfVar(v) and
    pos.isControledBy(comp, testIsTrue) and
    not unknownSign(lowerbound)
  |
    testIsTrue = true and
    comp.getLesserOperand() = lowerbound and
    comp.getGreaterOperand() = ssaRead(v, 0) and
    (if comp.isStrict() then isStrict = true else isStrict = false)
    or
    testIsTrue = false and
    comp.getGreaterOperand() = lowerbound and
    comp.getLesserOperand() = ssaRead(v, 0) and
    (if comp.isStrict() then isStrict = false else isStrict = true)
  )
}

/**
 * Holds if `upperbound` is an upper bound for `v` at `pos`. This is restricted
 * to only include bounds for which we might determine a sign.
 */
private predicate upperBound(Expr upperbound, Definition v, SsaReadPosition pos, boolean isStrict) {
  exists(boolean testIsTrue, RelationalOperation comp |
    pos.hasReadOfVar(v) and
    pos.isControledBy(comp, testIsTrue) and
    not unknownSign(upperbound)
  |
    testIsTrue = true and
    comp.getGreaterOperand() = upperbound and
    comp.getLesserOperand() = ssaRead(v, 0) and
    (if comp.isStrict() then isStrict = true else isStrict = false)
    or
    testIsTrue = false and
    comp.getLesserOperand() = upperbound and
    comp.getGreaterOperand() = ssaRead(v, 0) and
    (if comp.isStrict() then isStrict = false else isStrict = true)
  )
}

/**
 * Holds if `eqbound` is an equality/inequality for `v` at `pos`. This is
 * restricted to only include bounds for which we might determine a sign. The
 * boolean `isEq` gives the polarity:
 *  - `isEq = true` : `v = eqbound`
 *  - `isEq = false` : `v != eqbound`
 */
private predicate eqBound(Expr eqbound, Definition v, SsaReadPosition pos, boolean isEq) {
  exists(Guard guard, boolean testIsTrue, boolean polarity |
    pos.hasReadOfVar(v) and
    pos.isControledBy(guard, testIsTrue) and
    guard.isEquality(eqbound, ssaRead(v, 0), polarity) and
    isEq = polarity.booleanXor(testIsTrue).booleanNot() and
    not unknownSign(eqbound)
  )
}

/**
 * Holds if `bound` is a bound for `v` at `pos` that needs to be positive in
 * order for `v` to be positive.
 */
private predicate posBound(Expr bound, Definition v, SsaReadPosition pos) {
  upperBound(bound, v, pos, _) or
  eqBound(bound, v, pos, true)
}

/**
 * Holds if `bound` is a bound for `v` at `pos` that needs to be negative in
 * order for `v` to be negative.
 */
private predicate negBound(Expr bound, Definition v, SsaReadPosition pos) {
  lowerBound(bound, v, pos, _) or
  eqBound(bound, v, pos, true)
}

/**
 * Holds if `bound` is a bound for `v` at `pos` that can restrict whether `v`
 * can be zero.
 */
private predicate zeroBound(Expr bound, Definition v, SsaReadPosition pos) {
  lowerBound(bound, v, pos, _) or
  upperBound(bound, v, pos, _) or
  eqBound(bound, v, pos, _)
}

/** Holds if `bound` allows `v` to be positive at `pos`. */
private predicate posBoundOk(Expr bound, Definition v, SsaReadPosition pos) {
  posBound(bound, v, pos) and TPos() = exprSign(bound)
}

/** Holds if `bound` allows `v` to be negative at `pos`. */
private predicate negBoundOk(Expr bound, Definition v, SsaReadPosition pos) {
  negBound(bound, v, pos) and TNeg() = exprSign(bound)
}

/** Holds if `bound` allows `v` to be zero at `pos`. */
private predicate zeroBoundOk(Expr bound, Definition v, SsaReadPosition pos) {
  lowerBound(bound, v, pos, _) and TNeg() = exprSign(bound)
  or
  lowerBound(bound, v, pos, false) and TZero() = exprSign(bound)
  or
  upperBound(bound, v, pos, _) and TPos() = exprSign(bound)
  or
  upperBound(bound, v, pos, false) and TZero() = exprSign(bound)
  or
  eqBound(bound, v, pos, true) and TZero() = exprSign(bound)
  or
  eqBound(bound, v, pos, false) and TZero() != exprSign(bound)
}

/**
 * Holds if there is a bound that might restrict whether `v` has the sign `s`
 * at `pos`.
 */
private predicate hasGuard(Definition v, SsaReadPosition pos, Sign s) {
  s = TPos() and posBound(_, v, pos)
  or
  s = TNeg() and negBound(_, v, pos)
  or
  s = TZero() and zeroBound(_, v, pos)
}

pragma[noinline]
private Sign guardedSsaSign(Definition v, SsaReadPosition pos) {
  // SSA variable can have sign `result`
  result = ssaDefSign(v) and
  // SSA variable can have sign `result`
  pos.hasReadOfVar(v) and
  // there are guards at this position on `v` that might restrict it to be sign `result`.
  // (So we need to check if they are satisfied)
  hasGuard(v, pos, result)
}

pragma[noinline]
private Sign unguardedSsaSign(Definition v, SsaReadPosition pos) {
  // SSA variable can have sign `result`
  result = ssaDefSign(v) and
  // SSA variable can have sign `result`
  pos.hasReadOfVar(v) and
  // there's no guard at this position on `v` that might restrict it to be sign `result`.
  not hasGuard(v, pos, result)
}

/**
 * Gets the sign of `v` at read position `pos`, when there's at least one guard
 * on `v` at position `pos`. Each bound corresponding to a given sign must be met
 * in order for `v` to be of that sign.
 */
private Sign guardedSsaSignOk(Definition v, SsaReadPosition pos) {
  result = TPos() and
  forex(Expr bound | posBound(bound, v, pos) | posBoundOk(bound, v, pos))
  or
  result = TNeg() and
  forex(Expr bound | negBound(bound, v, pos) | negBoundOk(bound, v, pos))
  or
  result = TZero() and
  forex(Expr bound | zeroBound(bound, v, pos) | zeroBoundOk(bound, v, pos))
}

/** Gets a possible sign for `v` at `pos`. */
Sign ssaSign(Definition v, SsaReadPosition pos) {
  result = unguardedSsaSign(v, pos)
  or
  result = guardedSsaSign(v, pos) and
  result = guardedSsaSignOk(v, pos)
}

/** Gets a possible sign for `v`. */
pragma[nomagic]
private Sign ssaDefSign(Definition v) {
  exists(AssignableDefinition def | def = v.(ExplicitDefinition).getADefinition() |
    result = exprSign(def.getSource())
    or
    not exists(def.getSource()) and
    not def.getElement() instanceof MutatorOperation
    or
    result = exprSign(def.getElement().(PostIncrExpr).getOperand()).inc()
    or
    result = exprSign(def.getElement().(PreIncrExpr).getOperand()).inc()
    or
    result = exprSign(def.getElement().(PostDecrExpr).getOperand()).dec()
    or
    result = exprSign(def.getElement().(PreDecrExpr).getOperand()).dec()
  )
  or
  v =
    any(ImplicitDefinition id |
      result = fieldSign(id.getSourceVariable().getAssignable()) or
      not id.getSourceVariable().getAssignable() instanceof Field
    )
  or
  exists(PhiNode phi, Definition inp, SsaReadPositionPhiInputEdge edge |
    v = phi and
    edge.phiInput(phi, inp) and
    result = ssaSign(inp, edge)
  )
}

/** Gets a possible sign for `f`. */
private Sign fieldSign(Field f) {
  result = exprSign(f.getAnAssignedValue())
  or
  exists(PostIncrExpr inc | inc.getOperand() = f.getAnAccess() and result = fieldSign(f).inc())
  or
  exists(PreIncrExpr inc | inc.getOperand() = f.getAnAccess() and result = fieldSign(f).inc())
  or
  exists(PostDecrExpr inc | inc.getOperand() = f.getAnAccess() and result = fieldSign(f).dec())
  or
  exists(PreDecrExpr inc | inc.getOperand() = f.getAnAccess() and result = fieldSign(f).dec())
  or
  exists(AssignOperation a | a.getLValue() = f.getAnAccess() | result = exprSign(a))
  or
  f.fromSource() and not exists(f.getInitializer()) and result = TZero()
}

/** Gets a possible sign for `e`. */
cached
private Sign exprSign(Expr e) {
  result = certainExprSign(e)
  or
  not exists(certainExprSign(e)) and
  (
    unknownSign(e)
    or
    exists(Definition v | v.getARead() = e |
      result = ssaSign(v, any(SsaReadPositionBlock bb | bb.getBlock().getANode().getElement() = e))
      or
      not exists(SsaReadPositionBlock bb | bb.getBlock().getANode().getElement() = e) and
      result = ssaDefSign(v)
    )
    or
    exists(AssignableAccess access | access = e |
      not exists(Definition v | v.getARead() = access) and
      (
        result = fieldSign(access.getTarget()) or
        not access instanceof FieldAccess
      )
    )
    or
    result = exprSign(e.(AssignExpr).getRValue())
    or
    result = exprSign(e.(UnaryPlusExpr).getOperand())
    or
    result = exprSign(e.(PostIncrExpr).getOperand())
    or
    result = exprSign(e.(PostDecrExpr).getOperand())
    or
    result = exprSign(e.(PreIncrExpr).getOperand()).inc()
    or
    result = exprSign(e.(PreDecrExpr).getOperand()).dec()
    or
    result = exprSign(e.(UnaryMinusExpr).getOperand()).neg()
    or
    result = exprSign(e.(ComplementExpr).getOperand()).bitnot()
    or
    exists(DivExpr div |
      div = e and
      result = exprSign(div.getLeftOperand()) and
      result != TZero()
    |
      div.getRightOperand().(RealLiteral).getValue().toFloat() = 0
    )
    or
    exists(Sign s1, Sign s2 | binaryOpSigns(e, s1, s2) |
      (e instanceof AssignAddExpr or e instanceof AddExpr) and
      result = s1.add(s2)
      or
      (e instanceof AssignSubExpr or e instanceof SubExpr) and
      result = s1.add(s2.neg())
      or
      (e instanceof AssignMulExpr or e instanceof MulExpr) and
      result = s1.mul(s2)
      or
      (e instanceof AssignDivExpr or e instanceof DivExpr) and
      result = s1.div(s2)
      or
      (e instanceof AssignRemExpr or e instanceof RemExpr) and
      result = s1.rem(s2)
      or
      (e instanceof AssignAndExpr or e instanceof BitwiseAndExpr) and
      result = s1.bitand(s2)
      or
      (e instanceof AssignOrExpr or e instanceof BitwiseOrExpr) and
      result = s1.bitor(s2)
      or
      (e instanceof AssignXorExpr or e instanceof BitwiseXorExpr) and
      result = s1.bitxor(s2)
      or
      (e instanceof AssignLShiftExpr or e instanceof LShiftExpr) and
      result = s1.lshift(s2)
      or
      (e instanceof AssignRShiftExpr or e instanceof RShiftExpr) and
      result = s1.rshift(s2)
    )
    or
    result = exprSign(e.(ConditionalExpr).getThen())
    or
    result = exprSign(e.(ConditionalExpr).getElse())
    or
    result = exprSign(e.(SwitchExpr).getACase().getBody())
    or
    result = exprSign(e.(CastExpr).getExpr())
  )
}

private Sign binaryOpLhsSign(Expr e) {
  result = exprSign(e.(BinaryOperation).getLeftOperand()) or
  result = exprSign(e.(AssignOperation).getLValue())
}

private Sign binaryOpRhsSign(Expr e) {
  result = exprSign(e.(BinaryOperation).getRightOperand()) or
  result = exprSign(e.(AssignOperation).getRValue())
}

pragma[noinline]
private predicate binaryOpSigns(Expr e, Sign lhs, Sign rhs) {
  lhs = binaryOpLhsSign(e) and
  rhs = binaryOpRhsSign(e)
}

/** Holds if `e` can be positive and cannot be negative. */
predicate positive(Expr e) {
  exprSign(e) = TPos() and
  not exprSign(e) = TNeg()
}

/** Holds if `e` can be negative and cannot be positive. */
predicate negative(Expr e) {
  exprSign(e) = TNeg() and
  not exprSign(e) = TPos()
}

/** Holds if `e` is strictly positive. */
predicate strictlyPositive(Expr e) {
  exprSign(e) = TPos() and
  not exprSign(e) = TNeg() and
  not exprSign(e) = TZero()
}

/** Holds if `e` is strictly negative. */
predicate strictlyNegative(Expr e) {
  exprSign(e) = TNeg() and
  not exprSign(e) = TPos() and
  not exprSign(e) = TZero()
}
