{-# LANGUAGE TemplateHaskell #-}
module Data.UnionFind
  ( UnionFind
  , freshRef, find, union, equivalent
  , empty
  ) where

import Control.Applicative ((<$>), Applicative(..))
import Control.Lens.Operators
import Control.Monad.Trans.State (StateT(..), state)
import Control.MonadA (MonadA)
import Data.Binary (Binary(..))
import Data.Function (on)
import Data.Maybe.Utils (unsafeUnjust)
import Data.OpaqueRef (Ref)
import qualified Control.Lens as Lens
import qualified Data.IntDisjointSet as IDS
import qualified Data.OpaqueRef as OpaqueRef

data UnionFind p = UnionFind
  { _ufRefs :: IDS.IntDisjointSet
  , _ufFresh :: OpaqueRef.Fresh p
  }
Lens.makeLenses ''UnionFind

instance Binary (UnionFind p) where
  get = UnionFind <$> get <*> get
  put (UnionFind x y) = put x >> put y

empty :: UnionFind p
empty =
  UnionFind
  { _ufRefs = IDS.empty
  , _ufFresh = OpaqueRef.initialFresh
  }

ufState ::
  Monad m =>
  (IDS.IntDisjointSet -> (b, IDS.IntDisjointSet)) ->
  StateT (UnionFind p) m b
ufState = Lens.zoom ufRefs . state

freshRef :: MonadA m => StateT (UnionFind p) m (Ref p)
freshRef = do
  ref <- Lens.zoom ufFresh OpaqueRef.freshRef
  ufRefs %= IDS.insert (OpaqueRef.unsafeAsInt ref)
  return ref

find :: MonadA m => Ref p -> StateT (UnionFind p) m (Ref p)
find ref =
  OpaqueRef.unsafeFromInt .
  unsafeUnjust ("UnionFind.find: Not found: " ++ show ref) <$>
  (ufState . IDS.lookup . OpaqueRef.unsafeAsInt) ref

union :: MonadA m => Ref p -> Ref p -> StateT (UnionFind p) m (Ref p)
union x y =
  OpaqueRef.unsafeFromInt .
  unsafeUnjust "union on invalid ref" <$> ufState (on IDS.unionRep OpaqueRef.unsafeAsInt x y)

equivalent :: Monad m => Ref p -> Ref p -> StateT (UnionFind p) m Bool
equivalent x y = ufState $ on IDS.equivalent OpaqueRef.unsafeAsInt x y
