{-# LANGUAGE TemplateHaskell, DeriveFunctor #-}
module Lamdu.Data.Infer.ExprRefs
  ( ExprRefs, empty
  , fresh, find
  , readRep, writeRep
  , popRep
  , read, write, modify
  , union, equiv
  , UnifyRefsResult(..)
  , unifyRefs
  , optimize
  ) where

import Control.Applicative ((<$>), (<*))
import Control.Arrow ((***))
import Control.Lens.Operators
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.State (StateT(..), execStateT, evalState)
import Control.Monad.Trans.Writer (runWriter)
import Control.MonadA (MonadA)
import Data.Foldable (traverse_)
import Data.Maybe.Utils (unsafeUnjust)
import Data.OpaqueRef (Ref, RefMap)
import Prelude hiding (read)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.State as State
import qualified Control.Monad.Trans.Writer as Writer
import qualified Data.OpaqueRef as OR
import qualified Data.UnionFind as UF

data ExprRefs p a = ExprRefs
  { _exprRefsUF :: UF.UnionFind p
  , _exprRefsData :: RefMap p a
  } deriving (Functor)
Lens.makeLenses ''ExprRefs

empty :: ExprRefs p a
empty = ExprRefs
  { _exprRefsUF = UF.empty
  , _exprRefsData = OR.emptyRefMap
  }

fresh :: MonadA m => a -> StateT (ExprRefs p a) m (Ref p)
fresh dat = do
  rep <- Lens.zoom exprRefsUF UF.freshRef
  writeRep rep dat
  return rep

find :: MonadA m => String -> Ref p -> StateT (ExprRefs p a) m (Ref p)
find msg = Lens.zoom exprRefsUF . UF.lookup msg

readRep ::
  MonadA m => Ref p -> StateT (ExprRefs p a) m a
readRep rep =
  unsafeUnjust ("missing ref: " ++ show rep) <$>
  Lens.use (exprRefsData . Lens.at rep)

popRep ::
  MonadA m => Ref p -> StateT (ExprRefs p a) m a
popRep rep =
  Lens.zoom (exprRefsData . Lens.at rep) $
  unsafeUnjust ("missing ref: " ++ show rep)
  <$> State.get <* State.put Nothing

writeRep ::
  Monad m => Ref p -> a -> StateT (ExprRefs p a) m ()
writeRep rep dat = exprRefsData . Lens.at rep .= Just dat

read ::
  MonadA m => Ref p -> StateT (ExprRefs p a) m a
read ref = readRep =<< find "read" ref

write ::
  MonadA m => Ref p -> a -> StateT (ExprRefs p a) m ()
write ref dat =
  (`writeRep` dat) =<< find "write" ref

modify ::
  MonadA m => Ref p -> (a -> a) ->
  StateT (ExprRefs p a) m ()
modify ref f = write ref . f =<< read ref

union :: MonadA m => Ref p -> Ref p -> StateT (ExprRefs p a) m (Ref p)
union x y = Lens.zoom exprRefsUF $ UF.union x y

equiv :: MonadA m => Ref p -> Ref p -> StateT (ExprRefs p a) m Bool
equiv x y = Lens.zoom exprRefsUF $ UF.equivalent x y

data UnifyRefsResult a
  = UnifyRefsAlreadyUnified
  | UnifyRefsUnified a a

unifyRefs ::
  MonadA m => Ref p -> Ref p ->
  StateT (ExprRefs p a) m (Ref p, UnifyRefsResult a)
unifyRefs x y = do
  xRep <- find "unify.x" x
  yRep <- find "unify.y" y
  if xRep == yRep
    then return (xRep, UnifyRefsAlreadyUnified)
    else do
      xData <- popRep xRep
      yData <- popRep yRep
      rep <- x `union` y
      writeRep rep $ error "unifyRefs caller read the unified ref data before writing it"
      return (rep, UnifyRefsUnified xData yData)

optimize ::
  ((Ref p -> Ref p) -> a -> b) -> ExprRefs p a -> (Ref p -> Ref p, ExprRefs p b)
optimize onData (ExprRefs oldUf oldRefsData) =
  ( refRename "ExprRefs.optimize:user ref inexistent"
  , ExprRefs newUf newRefsData
  )
  where
    (newUf, refRenames) =
      runWriter . (`execStateT` UF.empty) $
      oldRefsData ^.. OR.unsafeRefMapItems . Lens._1 & traverse_ %%~ freshRef
    refRename msg oldRef =
      let oldRep = (`evalState` oldUf) $ UF.lookup "optimize:in old UF" oldRef
      in refRenames ^? Lens.ix oldRep & unsafeUnjust msg
    newRefsData =
      oldRefsData
      & OR.unsafeRefMapItems %~
        (refRename "optimize:onOldRefItem"
         ***
         onData (refRename "optimize:onRefData"))
    freshRef oldRep = do
      newRep <- UF.freshRef
      lift $ Writer.tell (OR.refMapSingleton oldRep newRep)
