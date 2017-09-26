{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Syntax.Expr (Id, Value(..), Expr(..), Type(..), TypeScheme(..),
                   Def(..), Op(..),
                   Pattern(..), CKind(..), Coeffect(..), NatModifier(..), Effect,
                   uniqueNames, arity, fvs, subst,
                   normalise,
                   nullSpan, getSpan, getEnd, getStart, Pos, Span
                   ) where

import Data.List
import Control.Monad.State
import GHC.Generics (Generic)

import Syntax.FirstParameter

type Id = String
data Op = Add | Sub | Mul deriving (Eq, Show)

type Pos = (Int, Int) -- (line, column)
type Span = (Pos, Pos)
nullSpan :: Span
nullSpan = ((0, 0), (0, 0))

getSpan :: FirstParameter t Span => t -> Span
getSpan = getFirstParameter

getEnd ::  FirstParameter t Span => t -> Pos
getEnd = snd . getSpan

getStart ::  FirstParameter t Span => t -> Pos
getStart = fst . getSpan

-- Values in Granule
data Value = Abs Id (Maybe Type) Expr
           | NumInt Int
           | NumFloat Double
           | Promote Expr
           | Pure Expr
           | Var Id
           | Constr String
          deriving (Eq, Show)

-- Expressions (computations) in Granule
data Expr = App Span Expr Expr
          | Binop Span Op Expr Expr
          | LetBox Span Id Type Expr Expr
          | LetDiamond Span Id Type Expr Expr
          | Val Span Value
          | Case Span Expr [(Pattern, Expr)]
          deriving (Eq, Show, Generic)

instance FirstParameter Expr Span

-- Pattern matchings
data Pattern = PVar Span Id        -- Variable patterns
             | PWild Span          -- Wildcard (underscore) pattern
             | PBoxVar Span Id     -- Box patterns (with a variable pattern inside)
             | PInt Span Int       -- Numeric patterns
             | PFloat Span Double
             | PConstr Span String -- Constructor pattern
             | PApp Span Pattern Pattern -- Apply pattern
          deriving (Eq, Show, Generic)

instance FirstParameter Pattern Span

class Binder t where
  bvs :: t -> [Id]
  freshenBinder :: t -> Freshener t

instance Binder Pattern where
  bvs (PVar _ v)     = [v]
  bvs (PBoxVar _ v)  = [v]
  bvs (PApp _ p1 p2) = bvs p1 ++ bvs p2
  bvs _           = []

  freshenBinder (PVar s var) = do
      var' <- freshVar var
      return $ PVar s var'

  freshenBinder (PBoxVar s var) = do
      var' <- freshVar var
      return $ PBoxVar s var'

  freshenBinder (PApp s p1 p2) = do
      p1' <- freshenBinder p1
      p2' <- freshenBinder p2
      return $ PApp s p1' p2'

  freshenBinder p = return p

type Freshener t = State (Int, [(Id, Id)]) t

class Term t where
  -- Compute the free variables in a term
  fvs :: t -> [Id]
  -- Syntactic substitution of an expression into a term
  -- (assuming variables are all unique to avoid capture)
  subst :: Expr -> Id -> t -> Expr
  -- Freshen
  freshen :: t -> Freshener t

-- Helper in the Freshener monad, creates a fresh id (and
-- remembers the mapping).
freshVar :: Id -> Freshener Id
freshVar var = do
   (v, nmap) <- get
   let var' = var ++ show v
   put (v+1, (var, var') : nmap)
   return var'

instance Term Value where
    fvs (Abs x _ e) = (fvs e) \\ [x]
    fvs (Var x)     = [x]
    fvs (Pure e)    = fvs e
    fvs (Promote e) = fvs e
    fvs _             = []

    subst es v (Abs w t e)      = Val nullSpan $ Abs w t (subst es v e)
    subst es v (Pure e)         = Val nullSpan $ Pure (subst es v e)
    subst es v (Promote e)      = Val nullSpan $ Promote (subst es v e)
    subst es v (Var w) | v == w = es
    subst _ _ val               = Val nullSpan val

    freshen (Abs var t e) = do
      var' <- freshVar var
      e'   <- freshen e
      return $ Abs var' t e'

    freshen (Pure e) = do
      e' <- freshen e
      return $ Pure e'

    freshen (Promote e) = do
      e' <- freshen e
      return $ Promote e'

    freshen (Var v) = do
      (_, nmap) <- get
      case lookup v nmap of
         Just v' -> return (Var v')
         -- This case happens if we are referring to a defined
         -- function which does not get its name freshened
         Nothing -> return (Var v)

    freshen v = return v

instance Term Expr where
   fvs (App _ e1 e2)            = fvs e1 ++ fvs e2
   fvs (Binop _ _ e1 e2)        = fvs e1 ++ fvs e2
   fvs (LetBox _ x _ e1 e2)     = fvs e1 ++ ((fvs e2) \\ [x])
   fvs (LetDiamond _ x _ e1 e2) = fvs e1 ++ ((fvs e2) \\ [x])
   fvs (Val _ e)                = fvs e
   fvs (Case _ e cases)         = fvs e ++ (concatMap (fvs . snd) cases
                                      \\ concatMap (bvs . fst) cases)

   subst es v (App s e1 e2)        = App s (subst es v e1) (subst es v e2)
   subst es v (Binop s op e1 e2)   = Binop s op (subst es v e1) (subst es v e2)
   subst es v (LetBox s w t e1 e2) = LetBox s w t (subst es v e1) (subst es v e2)
   subst es v (LetDiamond s w t e1 e2) =
                                   LetDiamond s w t (subst es v e1) (subst es v e2)
   subst es v (Val _ val)          = subst es v val
   subst es v (Case s expr cases)  = Case s
                                     (subst es v expr)
                                     (map (\(p, e) -> (p, subst es v e)) cases)

   freshen (LetBox s var t e1 e2) = do
      var' <- freshVar var
      e1'  <- freshen e1
      e2'  <- freshen e2
      return $ LetBox s var' t e1' e2'

   freshen (App s e1 e2) = do
      e1' <- freshen e1
      e2' <- freshen e2
      return $ App s e1' e2'

   freshen (LetDiamond s var t e1 e2) = do
      var' <- freshVar var
      e1'  <- freshen e1
      e2'  <- freshen e2
      return $ LetDiamond s var' t e1' e2'

   freshen (Binop s op e1 e2) = do
      e1' <- freshen e1
      e2' <- freshen e2
      return $ Binop s op e1' e2'

   freshen (Case s expr cases) = do
      expr'     <- freshen expr
      cases' <- forM cases $ \(p, e) -> do
                  p' <- freshenBinder p
                  e' <- freshen e
                  return (p', e')
      return (Case s expr' cases')

   freshen (Val s v) = do
     v' <- freshen v
     return (Val s v')


--------- Definitions

data Def =
    Def
    Span         -- Source span of the definition
    Id           -- Name of the definition
    Expr         -- Expression
    [Pattern]    -- Pattern matches
    TypeScheme   -- The type signature of the definition
    [TypeScheme] -- Any negative type signatures
  deriving (Eq, Show, Generic)

instance FirstParameter Def Span

-- Alpha-convert all bound variables
uniqueNames :: [Def] -> ([Def], [(Id, Id)])
uniqueNames = (\(defs, (_, nmap)) -> (defs, nmap))
            . flip runState (0 :: Int, [])
            . mapM freshenDef
  where
    freshenDef (Def s var e ps t unts) = do
      e'  <- freshen e
      ps' <- mapM freshenBinder ps
      return $ Def s var e' ps' t unts

----------- Types

data TypeScheme = Forall Span [(String, CKind)] Type
    deriving (Eq, Show, Generic)

instance FirstParameter TypeScheme Span

data Type = FunTy Type Type
          | ConT String
          | Box Coeffect Type
          | Diamond Effect Type
          | TyVar String
    deriving (Eq, Ord, Show)

arity :: Type -> Int
arity (FunTy _ t) = 1 + arity t
arity _           = 0

type Effect = [String]

data Coeffect = CNat   NatModifier Int
              | CFloat  Rational
              | CNatOmega (Either () Int)
              | CVar   String
              | CPlus  Coeffect Coeffect
              | CTimes Coeffect Coeffect
              | CZero  CKind
              | COne   CKind
              | Level Int
              | CSet [(String, Type)]
    deriving (Eq, Ord, Show)

data NatModifier = Ordered | Discrete
  deriving (Show, Ord, Eq)

data CKind = CConstr Id | CPoly Id
    deriving (Eq, Ord, Show)

-- | Normalise a coeffect using the semiring laws and some
--   local evaluation of natural numbers
--   There is plenty more scope to make this more comprehensive
normalise :: Coeffect -> Coeffect
normalise (CPlus (CZero _) n) = n
normalise (CPlus n (CZero _)) = n
normalise (CTimes (COne _) n) = n
normalise (CTimes n (COne _)) = n
normalise (COne (CConstr "Nat")) = CNat Ordered 1
normalise (CZero (CConstr "Nat")) = CNat Ordered 0
normalise (COne (CConstr "Nat=")) = CNat Discrete 1
normalise (CZero (CConstr "Nat=")) = CNat Discrete 0
normalise (COne (CConstr "Level")) = Level 1
normalise (CZero (CConstr "Level")) = Level 0
normalise (COne (CConstr "Q")) = CFloat 1
normalise (CZero (CConstr "Q")) = CFloat 0
normalise (CPlus (Level n) (Level m)) = Level (n `max` m)
normalise (CTimes (Level n) (Level m)) = Level (n `min` m)
normalise (CPlus (CFloat n) (CFloat m)) = CFloat (n + m)
normalise (CTimes (CFloat n) (CFloat m)) = CFloat (n * m)
normalise (CPlus (CNat k n) (CNat k' m)) | k == k' = CNat k (n + m)
normalise (CTimes (CNat k n) (CNat k' m)) | k == k' = CNat k (n * m)
normalise (CPlus n m) =
    if (n == n') && (m == m')
    then CPlus n m
    else normalise (CPlus n' m')
  where
    n' = normalise n
    m' = normalise m
normalise (CTimes n m) =
    if (n == n') && (m == m')
    then CTimes n m
    else normalise (CTimes n' m')
  where
    n' = normalise n
    m' = normalise m
normalise c = c