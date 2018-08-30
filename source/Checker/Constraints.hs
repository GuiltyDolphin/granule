{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ImplicitParams #-}

{- Deals with compilation of coeffects into symbolic representations of SBV -}

module Checker.Constraints where

import Data.Foldable (foldrM)
import Data.List (isPrefixOf)
import Data.SBV hiding (kindOf, name, symbolic)
import qualified Data.Set as S
import Control.Arrow (first)

import Checker.Predicates
import Context (Ctxt)
import Syntax.Expr
import Syntax.Pretty
import Utils

-- | What is the SBV represnetation of a quantifier
compileQuant :: SymWord a => Quantifier -> (String -> Symbolic (SBV a))
compileQuant ForallQ   = forall
compileQuant InstanceQ = exists
compileQuant BoundQ    = exists

normaliseConstraint :: Constraint -> Constraint
normaliseConstraint (Eq s c1 c2 k)   = Eq s (normalise c1) (normalise c2) k
normaliseConstraint (Neq s c1 c2 k)  = Neq s (normalise c1) (normalise c2) k
normaliseConstraint (ApproximatedBy s c1 c2 k) = ApproximatedBy s (normalise c1) (normalise c2) k

-- Compile constraint into an SBV symbolic bool, along with a list of
-- constraints which are trivially unsatisfiable (e.g., things like 1=0).
compileToSBV :: (?globals :: Globals) =>
  Pred -> Ctxt (Type, Quantifier) -> Ctxt Type
  -> (Symbolic SBool, Symbolic SBool, [Constraint])
compileToSBV predicate tyVarContext kVarContext =
  (buildTheorem id compileQuant
  , buildTheorem bnot (compileQuant . flipQuant)
  , trivialUnsatisfiableConstraints predicate')

  where
    flipQuant ForallQ   = InstanceQ
    flipQuant InstanceQ = ForallQ
    flipQuant BoundQ    = BoundQ

    predicate' = rewriteConstraints kVarContext predicate

    buildTheorem ::
        (SBool -> SBool)
     -> (forall a. SymWord a => Quantifier -> (String -> Symbolic (SBV a)))
     -> Symbolic SBool
    buildTheorem polarity quant = do
        (pres, constraints, solverVars) <-
            foldrM (createFreshVar quant) (true, true, []) tyVarContext
        predC <- buildTheorem' solverVars predicate'
        return (polarity (pres ==> (constraints &&& predC)))

    -- Build the theorem, doing local creation of universal variables
    -- when needed (see Impl case)
    buildTheorem' :: Ctxt SCoeffect -> Pred -> Symbolic SBool
    buildTheorem' solverVars (Conj ps) = do
      ps' <- mapM (buildTheorem' solverVars) ps
      return $ foldr (&&&) true ps'

    buildTheorem' solverVars (Impl [] p1 p2) = do
        p1' <- buildTheorem' solverVars p1
        p2' <- buildTheorem' solverVars p2
        return $ p1' ==> p2'

    -- TODO: generalise this to not just Nat= indices
    buildTheorem' solverVars (Impl (v:vs) p p') =
      if v `elem` (vars p ++ vars p')
        then forAll [internalName v] (\vSolver -> do
             impl <- buildTheorem' ((v, SNat Discrete vSolver) : solverVars) (Impl vs p p')
             return $ (vSolver .>= literal 0) ==> impl)
        else do
          buildTheorem' solverVars (Impl vs p p')

    buildTheorem' solverVars (Con cons) =
      return $ compile solverVars cons

    -- Perform a substitution on a predicate tree
    -- substPred rmap = predFold Conj Impl (Con . substConstraint rmap)
    -- substConstraint rmap (Eq s' c1 c2 k) =
    --     Eq s' (substCoeffect rmap c1) (substCoeffect rmap c2) k
    -- substConstraint rmap (ApproximatedBy s' c1 c2 k) =
    --     ApproximatedBy s' (substCoeffect rmap c1) (substCoeffect rmap c2) k

    -- Create a fresh solver variable of the right kind and
    -- with an associated refinement predicate
    createFreshVar
      :: (forall a. SymWord a => Quantifier -> (String -> Symbolic (SBV a)))
      -> (Id, (Type, Quantifier))
      -> (SBool, SBool, Ctxt SCoeffect)
      -> Symbolic (SBool, SBool, Ctxt SCoeffect)
    -- Ignore variables coming from a dependent pattern match
    createFreshVar _ (_, (_, BoundQ)) x = return x

    createFreshVar quant
                   (var, (kind, quantifierType))
                   (universalConstraints, existentialConstraints, ctxt) = do
      (pre, symbolic) <- freshCVar quant (internalName var) kind quantifierType
      let (universalConstraints', existentialConstraints') =
            case quantifierType of
              ForallQ -> (pre &&& universalConstraints, existentialConstraints)
              InstanceQ -> (universalConstraints, pre &&& existentialConstraints)
              BoundQ -> (universalConstraints, pre &&& existentialConstraints)
      return (universalConstraints', existentialConstraints', (var, symbolic) : ctxt)

-- given an context mapping coeffect type variables to coeffect typ,
-- then rewrite a set of constraints so that any occruences of the kind variable
-- are replaced with the coeffect type
rewriteConstraints :: Ctxt Type -> Pred -> Pred
rewriteConstraints ctxt =
    predFold Conj Impl (\c -> Con $ foldr (uncurry updateConstraint) c ctxt)
  where
    -- `updateConstraint v k c` rewrites any occurence of the kind variable
    -- `v` in the constraint `c` with the kind `k`
    updateConstraint :: Id -> Type -> Constraint -> Constraint
    updateConstraint ckindVar ckind (Eq s c1 c2 k) =
      Eq s (updateCoeffect ckindVar ckind c1) (updateCoeffect ckindVar ckind c2)
        (case k of
          TyVar ckindVar' | ckindVar == ckindVar' -> ckind
          _ -> k)
    updateConstraint ckindVar ckind (Neq s c1 c2 k) =
            Neq s (updateCoeffect ckindVar ckind c1) (updateCoeffect ckindVar ckind c2)
              (case k of
                TyVar ckindVar' | ckindVar == ckindVar' -> ckind
                _ -> k)

    updateConstraint ckindVar ckind (ApproximatedBy s c1 c2 k) =
      ApproximatedBy s (updateCoeffect ckindVar ckind c1) (updateCoeffect ckindVar ckind c2)
        (case k of
          TyVar ckindVar' | ckindVar == ckindVar' -> ckind
          _  -> k)

    -- `updateCoeffect v k c` rewrites any occurence of the kind variable
    -- `v` in the coeffect `c` with the kind `k`
    updateCoeffect :: Id -> Type -> Coeffect -> Coeffect
    updateCoeffect ckindVar ckind (CZero (TyVar ckindVar'))
      | ckindVar == ckindVar' = CZero ckind
    updateCoeffect ckindVar ckind (COne (TyVar ckindVar'))
      | ckindVar == ckindVar' = COne ckind
    updateCoeffect ckindVar ckind (CMeet c1 c2) =
      CMeet (updateCoeffect ckindVar ckind c1) (updateCoeffect ckindVar ckind c2)
    updateCoeffect ckindVar ckind (CJoin c1 c2) =
      CJoin (updateCoeffect ckindVar ckind c1) (updateCoeffect ckindVar ckind c2)
    updateCoeffect ckindVar ckind (CPlus c1 c2) =
      CPlus (updateCoeffect ckindVar ckind c1) (updateCoeffect ckindVar ckind c2)
    updateCoeffect ckindVar ckind (CTimes c1 c2) =
      CTimes (updateCoeffect ckindVar ckind c1) (updateCoeffect ckindVar ckind c2)
    updateCoeffect ckindVar ckind (CExpon c1 c2) =
      CExpon (updateCoeffect ckindVar ckind c1) (updateCoeffect ckindVar ckind c2)
    updateCoeffect _ _ c = c

-- Symbolic coeffects
data SCoeffect =
     SNat      NatModifier SInteger
   | SNatOmega SInteger
   | SFloat    SFloat
   | SLevel    SInteger
   | SSet      (S.Set (Id, Type))
  deriving (Show, Eq)

-- | Generate a solver variable of a particular kind, along with
-- a refinement predicate
freshCVar :: (forall a . SymWord a => Quantifier -> (String -> Symbolic (SBV a)))
          -> String -> Type -> Quantifier -> Symbolic (SBool, SCoeffect)

freshCVar quant name (TyCon k) q
  | internalName k == "Q" = do
        solverVar <- (quant q) name
        return (true, SFloat solverVar)
  | otherwise  = do
  solverVar <- (quant q) name
  case internalName k of
    "Nat*" -> return (solverVar .>= literal 0, SNatOmega solverVar)
    "Nat" -> return (solverVar .>= literal 0, SNat Ordered solverVar)
    "Cartesian" -> return (solverVar .== literal 1 ||| solverVar .== literal 0, SNat Ordered solverVar)
    "Nat=" -> return (solverVar .>= literal 0, SNat Discrete solverVar)
    "Level" -> return (solverVar .== literal 0 ||| solverVar .== 1, SLevel solverVar)
    "Set" -> return (true, SSet S.empty)

-- A poly typed coeffect variable whose element is 'infinity' gets
-- compiled into the One type (since this satisfies all the same properties)
freshCVar quant name (TyVar v) q | "infinity" == internalName v
-- future TODO: resolve polymorphism to free coeffect (uninterpreted)
                           || "kprom" `isPrefixOf` internalName v = do
  solverVar <- (quant q) name
  return (solverVar .== literal 1, SNat Ordered solverVar)

freshCVar _ _ k _ =
  error $ "Trying to make a fresh solver variable for a coeffect of kind: " ++ show k ++ " but I don't know how."

-- Compile a constraint into a symbolic bool (SBV predicate)
compile :: (?globals :: Globals) =>
  Ctxt SCoeffect -> Constraint -> SBool
compile vars (Eq _ c1 c2 k) =
  eqConstraint c1' c2'
    where
      c1' = compileCoeffect c1 k vars
      c2' = compileCoeffect c2 k vars
compile vars (Neq _ c1 c2 k) =
   bnot (eqConstraint c1' c2')
  where
    c1' = compileCoeffect c1 k vars
    c2' = compileCoeffect c2 k vars
compile vars (ApproximatedBy _ c1 c2 k) =
  approximatedByOrEqualConstraint c1' c2'
    where
      c1' = compileCoeffect c1 k vars
      c2' = compileCoeffect c2 k vars

-- Compile a coeffect term into its symbolic representation
compileCoeffect :: (?globals :: Globals) =>
  Coeffect -> Type -> [(Id, SCoeffect)] -> SCoeffect

compileCoeffect (CSig c k) _ ctxt = compileCoeffect c k ctxt

compileCoeffect (Level n) (TyCon k) _ | internalName k == "Level" =
  SLevel . fromInteger . toInteger $ n

-- Any polymorphic `Inf` gets compiled to the `Inf : One` coeffect
compileCoeffect (CInfinity (TyVar _)) _ _ = SNat Ordered 1
compileCoeffect (CInfinity (TyCon k)) _ _ | internalName k == "Cartesian" =
  SNat Ordered 1

compileCoeffect (CNat _ n) (TyCon k) _ =
  case internalName k of
    "Nat" -> SNat Ordered  . fromInteger . toInteger $ n
    "Nat=" -> SNat Discrete . fromInteger . toInteger $ n -- <- This can also happen when we use
                    -- natural number coeffects but with an explicit signature to make them Nat=

compileCoeffect (CNatOmega (n)) (TyCon k) _ | internalName k == "Nat*" =
  case n of
    Left () -> error "TODO: Recursion not yet supported"
    Right n -> SNatOmega . fromInteger . toInteger $ n

compileCoeffect (CFloat r) (TyCon k) _ | internalName k == "Q" = SFloat  . fromRational $ r

compileCoeffect (CSet xs) (TyCon k) _ | internalName k == "Set" =
  SSet . S.fromList $ (map (first mkId) xs)

compileCoeffect (CVar v) _ vars =
   case lookup v vars of
    Just cvar -> cvar
    _ -> error $ "Looking up a variable '" ++ pretty v ++ "' in " ++ show vars

compileCoeffect c@(CMeet n m) k vars =
  case (compileCoeffect n k vars, compileCoeffect m k vars) of
    (SNat o1 n1, SNat o2 n2) ->
      case k of
        TyVar v | internalName v == "infinity" -> SNat Ordered 1
        TyCon k | internalName k == "Cartesian" -> SNat Ordered (n1 `smin` n2)
        _ | o1 == o2 -> SNat o1 (n1 `smin` n2)
    (SSet s, SSet t) -> SSet $ S.intersection s t
    (SLevel s, SLevel t) -> SLevel $ s `smin` t
    (SFloat n1, SFloat n2) -> SFloat (n1 `smin` n2)
    _ -> error $ "Failed to compile: " ++ pretty c ++ " of kind " ++ pretty k

compileCoeffect c@(CJoin n m) k vars =
  case (compileCoeffect n k vars, compileCoeffect m k vars) of
    (SNat o1 n1, SNat o2 n2) ->
      case k of
        TyVar v | internalName v == "infinity" -> SNat Ordered 1
        TyCon k | internalName k == "Cartesian" -> SNat Ordered (n1 `smax` n2)
        _ | o1 == o2 -> SNat o1 (n1 `smax` n2)
    (SSet s, SSet t) -> SSet $ S.intersection s t
    (SLevel s, SLevel t) -> SLevel $ s `smax` t
    (SFloat n1, SFloat n2) -> SFloat (n1 `smax` n2)
    _ -> error $ "Failed to compile: " ++ pretty c ++ " of kind " ++ pretty k

compileCoeffect c@(CPlus n m) k vars =
  case (compileCoeffect n k vars, compileCoeffect m k vars) of
    (SNat o1 n1, SNat o2 n2) ->
      case k of
        TyVar v | internalName v == "infinity" -> SNat Ordered 1
        TyCon k | internalName k == "Cartesian" -> SNat Ordered (n1 `smax` n2)
        _ | o1 == o2 -> SNat o1 (n1 + n2)
    (SSet s, SSet t) -> SSet $ S.union s t
    (SLevel lev1, SLevel lev2) -> SLevel $ lev1 `smax` lev2
    (SFloat n1, SFloat n2) -> SFloat $ n1 + n2
    _ -> error $ "Failed to compile: " ++ pretty c ++ " of kind " ++ pretty k

compileCoeffect c@(CTimes n m) k vars =
  case (compileCoeffect n k vars, compileCoeffect m k vars) of
    (SNat o1 n1, SNat o2 n2) ->
      case k of
        TyVar v | internalName v == "infinity"  -> SNat Ordered 1
        TyCon k | internalName k == "Cartesian" -> SNat Ordered (n1 `smax` n2)
        _ | o1 == o2 -> SNat o1 (n1 * n2)
    (SSet s, SSet t) -> SSet $ S.union s t
    (SLevel lev1, SLevel lev2) -> SLevel $ lev1 `smin` lev2
    (SFloat n1, SFloat n2) -> SFloat $ n1 * n2
    _ -> error $ "Failed to compile: " ++ pretty c ++ " of kind " ++ pretty k

compileCoeffect c@(CExpon n m) k vars =
  case (compileCoeffect n k vars, compileCoeffect m k vars) of
    (SNat o1 n1, SNat o2 n2) ->
      case k of
        TyVar v | internalName v == "infinity"  -> SNat Ordered 1
        TyCon k | internalName k == "Cartesian" -> SNat Ordered (n1 `smax` n2)
        _ | o1 == o2 -> SNat o1 (n1 .^ n2)
    _ -> error $ "Failed to compile: " ++ pretty c ++ " of kind " ++ pretty k

compileCoeffect (CZero (TyCon k')) (TyCon k) _ =
  case internalName k' of
    "Level" | internalName k == "Level" -> SLevel 0
    "Nat" | internalName k == "Nat" -> SNat Ordered 0
    "Nat=" | internalName k == "Nat=" -> SNat Discrete 0
    "Q" | internalName k == "Q" -> SFloat (fromRational 0)
    "Set" | internalName k == "Set" -> SSet (S.fromList [])
    "Cartesian" | internalName k == "Cartesian" -> SNat Ordered 0

compileCoeffect (COne (TyCon k')) (TyCon k) _ =
  case internalName k' of
    "Level" | internalName k == "Level" -> SLevel 1
    "Nat" | internalName k == "Nat" -> SNat Ordered 1
    "Nat=" | internalName k == "Nat=" -> SNat Discrete 1
    "Q" | internalName k == "Q" -> SFloat (fromRational 1)
    "Set" | internalName k == "Set" -> SSet (S.fromList [])
    "Cartesian" | internalName k == "Cartesian" -> SNat Ordered 1

compileCoeffect _ (TyVar v) _ | "infinity" == internalName v = SNat Ordered 1

-- Trying to compile a coeffect from a promotion that was never
-- constrained further: default to the cartesian coeffect
-- future TODO: resolve polymorphism to free coeffect (uninterpreted)
compileCoeffect c (TyVar v) _ | "kprom" `isPrefixOf` internalName v =
  case c of
    CZero _ -> SNat Ordered 0
    _       -> SNat Ordered 1

compileCoeffect c (TyVar _) _ =
   error $ "Trying to compile a polymorphically kinded " ++ pretty c

compileCoeffect coeff ckind _ =
   error $ "Can't compile a coeffect: " ++ pretty coeff ++ " {" ++ (show coeff) ++ "}"
        ++ " of kind " ++ pretty ckind

-- | Generate equality constraints for two symbolic coeffects
eqConstraint :: SCoeffect -> SCoeffect -> SBool
eqConstraint (SNat _ n) (SNat _ m) = n .== m
eqConstraint (SFloat n) (SFloat m) = n .== m
eqConstraint (SLevel l) (SLevel k) = l .== k
eqConstraint x y =
   error $ "Kind error trying to generate equality " ++ show x ++ " = " ++ show y

-- | Generate less-than-equal constraints for two symbolic coeffects
approximatedByOrEqualConstraint :: SCoeffect -> SCoeffect -> SBool
approximatedByOrEqualConstraint (SNat Ordered n) (SNat Ordered m)   = n .<= m
approximatedByOrEqualConstraint (SNat Discrete n) (SNat Discrete m) = n .== m
approximatedByOrEqualConstraint (SFloat n) (SFloat m)   = n .<= m
approximatedByOrEqualConstraint (SLevel l) (SLevel k) = l .<= k
approximatedByOrEqualConstraint (SSet s) (SSet t) =
  if s == t then true else false
approximatedByOrEqualConstraint x y =
   error $ "Kind error trying to generate " ++ show x ++ " <= " ++ show y


trivialUnsatisfiableConstraints :: Pred -> [Constraint]
trivialUnsatisfiableConstraints cs =
    (filter unsat) . (map normaliseConstraint) . positiveConstraints $ cs
  where
    -- Only check trivial constraints in positive positions
    -- This means we don't report a branch concluding false trivially
    -- TODO: may check trivial constraints everywhere?
    positiveConstraints = predFold concat (\_ _ q -> q) (\x -> [x])

    unsat :: Constraint -> Bool
    unsat (Eq _ c1 c2 _)  = c1 `eqC` c2
    unsat (Neq _ c1 c2 _) = not (c1 `eqC` c2)
    unsat (ApproximatedBy _ c1 c2 _) = c1 `approximatedByC` c2

    -- TODO: unify this with eqConstraint and approximatedByOrEqualConstraint
    -- Attempt to see if one coeffect is trivially greater than the other
    approximatedByC :: Coeffect -> Coeffect -> Bool
    approximatedByC (CNat Ordered n)  (CNat Ordered m)  = not $ n <= m
    approximatedByC (CNat Discrete n) (CNat Discrete m) = not $ n == m
    approximatedByC (Level n) (Level m)   = not $ n >= m
    approximatedByC (CFloat n) (CFloat m) = not $ n <= m
    approximatedByC _ _                   = False

    -- Attempt to see if one coeffect is trivially not equal to the other
    eqC :: Coeffect -> Coeffect -> Bool
    eqC (CNat Ordered n)  (CNat Ordered m)  = n /= m
    eqC (CNat Discrete n) (CNat Discrete m) = n /= m
    eqC (Level n) (Level m)   = n /= m
    eqC (CFloat n) (CFloat m) = n /= m
    eqC _ _                   = False
