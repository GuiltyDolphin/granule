module Checker.MonadSpec where

import Test.Hspec

import Syntax.Identifiers
import Syntax.Type

import Checker.Monad
import Control.Monad.State.Strict
import Control.Monad.Trans.Maybe
import Control.Monad.Reader.Class
import Checker.Constraints
import Checker.Predicates
import Checker.LaTeX

spec :: Spec
spec = do
  -- Unit tests
  localCheckingSpec

  -- describe "" $ it "" $ True `shouldBe` True


localCheckingSpec :: Spec
localCheckingSpec = do
    describe "Unit tests on localised checking function" $ do
      it "Updates do not leak" $ do
        (Just (out, local), state) <- localising
        -- State hasn't been changed by the local context
        state `shouldBe` endStateExpectation
        out   `shouldBe` (Just "x10")
        (_, localState) <- runChecker endStateExpectation (runMaybeT local)
        localState `shouldBe` (transformState endStateExpectation)

  where
    endStateExpectation = initState { uniqueVarIdCounter = 10 }
    localising = runChecker initState $ runMaybeT $ do
      state <- get
      put (state { uniqueVarIdCounter = 10 })
      localChecking $ do
        state <- get
        put (transformState state)
        return $ "x" <> show (uniqueVarIdCounter state)
    transformState st =
      st { uniqueVarIdCounter  = 1 + uniqueVarIdCounter st
         , tyVarContext = [(mkId "inner", (KType, ForallQ))]
         , kVarContext  = [(mkId "innerk", KType)]
         , deriv        = Just $ Leaf "testing"
         , derivStack   = [Leaf "unit test"] }
