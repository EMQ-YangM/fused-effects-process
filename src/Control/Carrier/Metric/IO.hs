{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.Carrier.Metric.IO
  ( Metric,
    inc,
    dec,
    getVal,
    putVal,
    getAll,
    runMetric,
    runMetricWith,
    showMetric,
    creatVec,
    Vec (..),
    K (..),
    Vlength (..),
    NameVector (..),
    module Data.Default.Class,
  )
where

import Control.Carrier.Reader
  ( Algebra,
    ReaderC (..),
    runReader,
  )
import Control.Effect.Labelled
  ( Algebra (..),
    type (:+:) (..),
  )
import Control.Effect.Metric
import Control.Monad (forM_)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Data (Proxy (..))
import Data.Default.Class (Default (..))
import qualified Data.Vector as V
import Data.Vector.Unboxed.Mutable
  ( IOVector,
    replicate,
    unsafeModify,
    unsafeRead,
    unsafeWrite,
  )
import qualified Data.Vector.Unboxed.Mutable as M
import GHC.TypeLits
  ( KnownNat,
    natVal,
  )
import Prelude hiding (replicate)

toi :: forall s. (KnownNat s) => K s -> Int
toi _ = fromIntegral $ natVal (Proxy :: Proxy s)
{-# INLINE toi #-}

get :: (KnownNat s, Default a) => (a -> K s) -> Int
get v1 = toi . v1 $ def
{-# INLINE get #-}

fun ::
  (KnownNat s, Default a) =>
  IOVector Int ->
  (a -> K s) ->
  (Int -> Int) ->
  IO ()
fun v idx f = unsafeModify v f (get idx)
{-# INLINE fun #-}

gv :: (KnownNat s, Default a) => IOVector Int -> (a -> K s) -> IO Int
gv v idx = unsafeRead v (get idx)
{-# INLINE gv #-}

pv :: (KnownNat s, Default a) => IOVector Int -> (a -> K s) -> Int -> IO ()
pv v idx = unsafeWrite v (get idx)
{-# INLINE pv #-}

inc1 :: (KnownNat s, Default a) => IOVector Int -> (a -> K s) -> IO ()
inc1 v idx = fun v idx (+ 1)
{-# INLINE inc1 #-}

dec1 :: (KnownNat s, Default a) => IOVector Int -> (a -> K s) -> IO ()
dec1 v idx = fun v idx (\x -> x - 1)
{-# INLINE dec1 #-}

newtype MetriC v m a = MetriC {unMetric :: ReaderC (IOVector Int) m a}
  deriving (Functor, Applicative, Monad, MonadIO)

instance
  (Algebra sig m, MonadIO m, Default v, NameVector v) =>
  Algebra (Metric v :+: sig) (MetriC v m)
  where
  alg hdl sig ctx = MetriC $
    ReaderC $ \iov -> case sig of
      L (Inc g) -> do
        liftIO $ inc1 iov g
        pure ctx
      L (Dec g) -> do
        liftIO $ dec1 iov g
        pure ctx
      L (GetVal g) -> do
        v <- liftIO $ gv iov g
        pure (v <$ ctx)
      L (PutVal g v) -> do
        liftIO $ pv iov g v
        pure ctx
      L GetAll -> do
        v <- liftIO $ M.ifoldr' (\i a b -> (vName @v undefined V.! i, a) : b) [] iov
        pure (v <$ ctx)
      L Reset -> do
        forM_ [0 .. M.length iov - 1] $ \i ->
          liftIO $ unsafeWrite iov i 0
        pure ctx
      R signa -> alg (runReader iov . unMetric . hdl) signa ctx
  {-# INLINE alg #-}

runMetric ::
  forall v m a. (MonadIO m, Default v, Vlength v) => MetriC v m a -> m a
runMetric f = do
  v <- liftIO creatVec
  runMetricWith v f
{-# INLINE runMetric #-}

data Vec v = Vec v (IOVector Int)

creatVec :: forall v. (Vlength v, Default v) => IO (Vec v)
creatVec = do
  iov <- replicate (vlength @v undefined) 0
  pure (Vec def iov)
{-# INLINE creatVec #-}

runMetricWith :: forall v m a. (MonadIO m) => Vec v -> MetriC v m a -> m a
runMetricWith (Vec _ iov) f = runReader iov $ unMetric f
{-# INLINE runMetricWith #-}

showMetric :: [(String, Int)] -> String
showMetric [] = []
showMetric ((name, val) : xs) =
  name ++ ": " ++ show val ++ "\n" ++ showMetric xs
{-# INLINE showMetric #-}
