-- Provides all the type information for built-ins

module Checker.Primitives where

import Syntax.Expr

protocol = KConstr $ mkId "Protocol"

typeLevelConstructors :: [(Id, (Kind, Cardinality))]
typeLevelConstructors =
    [ (mkId "()", (KType, Just 1))
    , (mkId ",", (KFun KType (KFun KType KType), Just 1))
    , (mkId "Int",  (KType, Nothing))
    , (mkId "Float", (KType, Nothing))
    , (mkId "Char", (KType, Nothing))
    , (mkId "String", (KType, Nothing))
    , (mkId "FileIO", (KFun KType KType, Nothing))
    , (mkId "Session", (KFun KType KType, Nothing))
    , (mkId "N", (KFun (KConstr $ mkId "Nat=") KType, Just 2))
    , (mkId "Cartesian", (KCoeffect, Nothing))   -- Singleton coeffect
    , (mkId "Nat",  (KCoeffect, Nothing))
    , (mkId "Nat=", (KCoeffect, Nothing))
    , (mkId "Nat*", (KCoeffect, Nothing))
    , (mkId "Q",    (KCoeffect, Nothing)) -- Rationals
    , (mkId "Level", (KCoeffect, Nothing)) -- Security level
    , (mkId "Set", (KFun (KVar $ mkId "k") (KFun (KConstr $ mkId "k") KCoeffect), Nothing))
    , (mkId "+",   (KFun (KConstr $ mkId "Nat=") (KFun (KConstr $ mkId "Nat=") (KConstr $ mkId "Nat=")), Nothing))
    , (mkId "*",   (KFun (KConstr $ mkId "Nat=") (KFun (KConstr $ mkId "Nat=") (KConstr $ mkId "Nat=")), Nothing))
    , (mkId "/\\", (KFun (KConstr $ mkId "Nat=") (KFun (KConstr $ mkId "Nat=") (KConstr $ mkId "Nat=")), Nothing))
    , (mkId "\\/", (KFun (KConstr $ mkId "Nat=") (KFun (KConstr $ mkId "Nat=") (KConstr $ mkId "Nat=")), Nothing))
    -- File stuff
    , (mkId "Handle", (KType, Nothing))
    -- Channels and protocol types
    , (mkId "Send", (KFun KType (KFun protocol protocol), Nothing))
    , (mkId "Recv", (KFun KType (KFun protocol protocol), Nothing))
    , (mkId "End" , (protocol, Nothing))
    , (mkId "Chan", (KFun protocol KType, Nothing))
    , (mkId "Dual", (KFun protocol protocol, Nothing))
    ]

dataConstructors :: [(Id, Type)]
dataConstructors =
    [ (mkId "()", Forall [] (TyCon $ mkId "()"))
    , (mkId ",", Forall [((mkId "a"),KType),((mkId "b"),KType)]
        (FunTy (TyVar (mkId "a"))
          (FunTy (TyVar (mkId "b"))
                 (TyApp (TyApp (TyCon (mkId ",")) (TyVar (mkId "a"))) (TyVar (mkId "b"))))))
    ]

builtins :: [(Id, Type)]
builtins =
  [ -- Graded monad unit operation
    (mkId "pure", Forall [(mkId "a", KType)]
       $ (FunTy (TyVar $ mkId "a") (Diamond [] (TyVar $ mkId "a"))))

    -- String stuff
  , (mkId "stringAppend", Forall []
      $ (FunTy (TyCon $ mkId "String") (FunTy (TyCon $ mkId "String") (TyCon $ mkId "String"))))
  , (mkId "showChar", Forall []
      $ (FunTy (TyCon $ mkId "Char") (TyCon $ mkId "String")))

    -- Effectful primitives
  , (mkId "read", Forall [] $ Diamond ["R"] (TyCon $ mkId "String"))
  , (mkId "write", Forall [] $
       FunTy (TyCon $ mkId "String") (Diamond ["W"] (TyCon $ mkId "()")))
  , (mkId "readInt", Forall [] $ Diamond ["R"] (TyCon $ mkId "Int"))
    -- Other primitives
  , (mkId "intToFloat", Forall [] $ FunTy (TyCon $ mkId "Int")
                                                    (TyCon $ mkId "Float"))

  , (mkId "showInt", Forall [] $ FunTy (TyCon $ mkId "Int")
                                                    (TyCon $ mkId "String"))

    -- File stuff
  , (mkId "openFile", Forall [] $
                        FunTy (TyCon $ mkId "String")
                          (FunTy (TyCon $ mkId "IOMode")
                                (Diamond ["O"] (TyCon $ mkId "Handle"))))
  , (mkId "hGetChar", Forall [] $
                        FunTy (TyCon $ mkId "Handle")
                               (Diamond ["RW"]
                                (TyApp (TyApp (TyCon $ mkId ",")
                                              (TyCon $ mkId "Handle"))
                                       (TyCon $ mkId "Char"))))
  , (mkId "hPutChar", Forall [] $
                        FunTy (TyCon $ mkId "Handle")
                         (FunTy (TyCon $ mkId "Char")
                           (Diamond ["W"] (TyCon $ mkId "Handle"))))
  , (mkId "isEOF", Forall [] $
                     FunTy (TyCon $ mkId "Handle")
                            (Diamond ["R"]
                             (TyApp (TyApp (TyCon $ mkId ",")
                                           (TyCon $ mkId "Handle"))
                                    (TyCon $ mkId "Bool"))))
  , (mkId "hClose", Forall [] $
                        FunTy (TyCon $ mkId "Handle")
                               (Diamond ["C"] (TyCon $ mkId "()")))
    -- protocol typed primitives
  , (mkId "send", Forall [(mkId "a", KType), (mkId "s", protocol)]
                  $ ((con "Chan") .@ (((con "Send") .@ (var "a")) .@  (var "s")))
                      .-> ((var "a")
                        .-> (Diamond ["Com"] ((con "Chan") .@ (var "s")))))

  , (mkId "recv", Forall [(mkId "a", KType), (mkId "s", protocol)]
       $ ((con "Chan") .@ (((con "Recv") .@ (var "a")) .@  (var "s")))
         .-> (Diamond ["Com"] ((con "," .@ (var "a")) .@ ((con "Chan") .@ (var "s")))))

  , (mkId "close", Forall [] $
                    ((con "Chan") .@ (con "End")) .-> (Diamond ["Com"] (con "()")))

  -- fork : (c -> Diamond ()) -> Diamond c'
  , (mkId "fork", Forall [(mkId "s", protocol)] $
                    (((con "Chan") .@ (TyVar $ mkId "s")) .-> (Diamond ["Com"] (con "()")))
                    .->
                    (Diamond ["Com"] ((con "Chan") .@ ((TyCon $ mkId "Dual") .@ (TyVar $ mkId "s")))))

   -- forkRep : (c |n| -> Diamond ()) -> Diamond (c' |n|)
  , (mkId "forkRep", Forall [(mkId "s", protocol), (mkId "n", KConstr $ mkId "Nat=")] $
                    (Box (CVar $ mkId "n")
                       ((con "Chan") .@ (TyVar $ mkId "s")) .-> (Diamond ["Com"] (con "()")))
                    .->
                    (Diamond ["Com"]
                       (Box (CVar $ mkId "n")
                         ((con "Chan") .@ ((TyCon $ mkId "Dual") .@ (TyVar $ mkId "s"))))))
  ]

binaryOperators :: [(Operator, Type)]
binaryOperators =
  [ ("+", FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Int")))
   ,("+", FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Float")))
   ,("-", FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Int")))
   ,("-", FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Float")))
   ,("*", FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Int")))
   ,("*", FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Float")))
   ,("==", FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Bool")))
   ,("<=", FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Bool")))
   ,("<", FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Bool")))
   ,(">", FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Bool")))
   ,(">=", FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Bool")))
   ,("==", FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Bool")))
   ,("<=", FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Bool")))
   ,("<", FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Bool")))
   ,(">", FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Bool")))
   ,(">=", FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Bool"))) ]
