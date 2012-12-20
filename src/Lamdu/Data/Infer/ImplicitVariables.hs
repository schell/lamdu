{-# LANGUAGE DeriveFunctor, DeriveDataTypeable, TemplateHaskell #-}
module Lamdu.Data.Infer.ImplicitVariables
  ( addVariables, Payload(..)
  ) where

import Control.Applicative ((<$>))
import Control.Lens ((^.))
import Control.Monad (foldM)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State (StateT, State, evalStateT, mapStateT, state)
import Control.Monad.Trans.State.Utils (toStateT)
import Control.MonadA (MonadA)
import Data.Binary (Binary(..), getWord8, putWord8)
import Data.Derive.Binary (makeBinary)
import Data.DeriveTH (derive)
import Data.Functor.Identity (Identity(..))
import Data.Maybe (fromMaybe)
import Data.Monoid (mempty)
import Data.Store.Guid (Guid)
import Data.Typeable (Typeable)
import Lamdu.Data.Infer.UntilConflict (inferAssertNoConflict)
import System.Random (RandomGen, random)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.State as State
import qualified Data.Store.Guid as Guid
import qualified Lamdu.Data as Data
import qualified Lamdu.Data.Infer as Infer

data Payload a = Stored a | AutoGen Guid
  deriving (Eq, Ord, Show, Functor, Typeable)
derive makeBinary ''Payload

isUnrestrictedHole :: Data.Expression def Infer.IsRestrictedPoly -> Bool
isUnrestrictedHole
  (Data.Expression
    (Data.ExpressionLeaf Data.Hole)
    Infer.UnrestrictedPoly) = True
isUnrestrictedHole _ = False

unMaybe :: StateT s Maybe b -> StateT s Identity b
unMaybe =
  mapStateT (Identity . fromMaybe (error "Infer error when adding implicit vars!"))

-- TODO: Infer.Utils
actions :: Infer.InferActions def Maybe
actions = Infer.InferActions $ const Nothing

addVariableForHole ::
  (Ord def, RandomGen g) =>
  Infer.InferNode def ->
  StateT g (State (Infer.Context def)) (Guid, Infer.InferNode def)
addVariableForHole holePoint = do
  paramGuid <- state random
  let
    getVar = Data.pureExpression $ Data.makeParameterRef paramGuid
    loaded =
      fromMaybe (error "Should not be loading defs when loading a mere getVar") $
      Infer.load loader Nothing getVar
  lift $ do
    inferredGetVar <- inferAssertNoConflict loaded holePoint
    let
      paramTypeRef =
        Infer.tvType . Infer.nRefs . Infer.iPoint . fst $
        inferredGetVar ^. Data.ePayload
    paramTypeTypeRef <- Infer.createRefExpr
    return
      ( paramGuid
      , Infer.InferNode (Infer.TypedValue paramTypeRef paramTypeTypeRef) mempty
      )
  where
    loader = Infer.Loader $ const Nothing

addVariablesForExpr ::
  (MonadA m, Ord def, RandomGen g) =>
  Infer.Loader def m ->
  Data.Expression def (Infer.Inferred def, a) ->
  StateT g (StateT (Infer.Context def) m) [(Guid, Infer.InferNode def)]
addVariablesForExpr loader expr = do
  reinferred <-
    lift . State.gets . Infer.derefExpr $
    Lens.over (Lens.mapped . Lens._1) Infer.iPoint expr
  if isUnrestrictedHole $ inferredVal reinferred
    then
      fmap (:[]) . mapStateT toStateT . addVariableForHole $
      Infer.iPoint . fst $ expr ^. Data.ePayload
    else do
      reloaded <-
        lift . lift . Infer.load loader Nothing $ -- <-- TODO: Nothing?
        inferredVal reinferred
      reinferredLoaded <-
        lift . toStateT . inferAssertNoConflict reloaded .
        Infer.iPoint . fst $ Lens.view Data.ePayload reinferred
      fmap concat . mapM (addVariablesForExpr loader) .
        filter (isUnrestrictedHole . inferredVal) $
        Data.subExpressions reinferredLoaded
  where
    inferredVal = Infer.iValue . fst . Lens.view Data.ePayload

addParam ::
  Ord def =>
  Data.Expression def (Infer.InferNode def, Payload a) ->
  (Guid, Infer.InferNode def) ->
  State (Infer.Context def)
  (Data.Expression def (Infer.InferNode def, Payload a))
addParam body (paramGuid, paramTypeNode) = do
  newRootNode <- Infer.newNodeWithScope mempty
  let
    newRootExpr =
      Data.Expression newRootLam (newRootNode, AutoGen (Guid.augment "root" paramGuid))
  unMaybe $ Infer.addRules actions [fst <$> newRootExpr]
  return newRootExpr
  where
    paramTypeExpr =
      Data.Expression
      (Data.ExpressionLeaf Data.Hole)
      (paramTypeNode, AutoGen (Guid.augment "paramType" paramGuid))
    newRootLam =
      Data.makeLambda paramGuid paramTypeExpr body

addVariables ::
  (MonadA m, Ord def, RandomGen g) =>
  g -> Infer.Loader def m ->
  Data.Expression def (Infer.Inferred def, a) ->
  StateT (Infer.Context def) m
  (Data.Expression def (Infer.Inferred def, Payload a))
addVariables gen loader expr = do
  implicitParams <-
    (`evalStateT` gen) . fmap concat .
    mapM (addVariablesForExpr loader) $ Data.funcArguments expr
  newRoot <-
    toStateT $ foldM addParam
    ( Lens.over Lens._1 Infer.iPoint
    . Lens.over Lens._2 Stored <$> expr)
    implicitParams
  State.gets $ Infer.derefExpr newRoot