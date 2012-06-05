{-# LANGUAGE TypeFamilies, FlexibleContexts #-}
module Editor.Data.Load
  ( StoredExpression(..)
  , guid, esGuid
  , loadDefinition, DefinitionEntity(..)
  , loadExpression, ExpressionEntity(..)
  )
where

import Control.Monad (liftM, liftM2)
import Data.Store.Guid (Guid)
import Data.Store.Transaction (Transaction)
import Editor.Anchors (ViewTag)
import qualified Editor.Data as Data
import qualified Data.Store.IRef as IRef
import qualified Data.Store.Transaction as Transaction
import qualified Editor.Data.Ops as DataOps

data StoredExpression m = StoredExpression
  { esIRef :: Data.ExpressionIRef
  , esReplace :: Maybe (Data.ExpressionIRef -> m ())
  }

-- TODO: ExpressionEntity -> ExpressionEntity
data ExpressionEntity m = ExpressionEntity
  { entityStored :: StoredExpression m
  , entityValue :: Data.Expression (ExpressionEntity m)
  }

data DefinitionEntity m = DefinitionEntity
  { defEntityIRef :: Data.DefinitionIRef
  , defEntityValue :: Data.Definition (ExpressionEntity m)
  }

-- TODO: explain..
-- How could we compare the esReplace field?
-- Do we really need this instance?
instance Eq (StoredExpression m) where
  StoredExpression x _ == StoredExpression y _ = x == y

type T = Transaction ViewTag

esGuid :: StoredExpression m -> Guid
esGuid = IRef.guid . Data.unExpressionIRef . esIRef

guid :: ExpressionEntity m -> Guid
guid = esGuid . entityStored

loadExpression
  :: Monad m
  => Data.ExpressionIRef
  -> Maybe (Data.ExpressionIRef -> T m ())
  -> T m (ExpressionEntity (T m))
loadExpression exprI mSetter = do
  expr <- Data.readExprIRef exprI
  liftM (ExpressionEntity (StoredExpression exprI mSetter)) $
    case expr of
    Data.ExpressionLambda lambda ->
      liftM Data.ExpressionLambda $ loadLambda Data.ExpressionLambda lambda
    Data.ExpressionPi lambda ->
      liftM Data.ExpressionPi $ loadLambda Data.ExpressionPi lambda
    Data.ExpressionApply apply@(Data.Apply funcI argI) ->
      liftM Data.ExpressionApply $
      liftM2 Data.Apply
      (loadExpression funcI (Just (DataOps.applyFuncSetter exprI apply)))
      (loadExpression argI (Just (DataOps.applyArgSetter exprI apply)))
    Data.ExpressionGetVariable x -> return $ Data.ExpressionGetVariable x
    Data.ExpressionLiteralInteger x -> return $ Data.ExpressionLiteralInteger x
    Data.ExpressionHole -> return Data.ExpressionHole
    Data.ExpressionMagic -> return Data.ExpressionMagic
    Data.ExpressionBuiltin bi -> return $ Data.ExpressionBuiltin bi
    where
      loadLambda cons lambda@(Data.Lambda argType body) =
        liftM2 Data.Lambda
        (loadExpression argType
         (Just (DataOps.lambdaTypeSetter cons exprI lambda)))
        (loadExpression body
         (Just (DataOps.lambdaBodySetter cons exprI lambda)))

loadDefinition
  :: Monad m
  => Data.DefinitionIRef
  -> T m (DefinitionEntity (T m))
loadDefinition defI = do
  def <- Transaction.readIRef defI
  liftM (DefinitionEntity defI) $
    case def of
    Data.Definition typeI bodyI -> do
      loadedType <-
        loadExpression typeI . Just $
        Transaction.writeIRef defI . flip Data.Definition bodyI
      loadedExpr <-
        loadExpression bodyI . Just $
        Transaction.writeIRef defI . Data.Definition typeI
      return $ Data.Definition loadedType loadedExpr
