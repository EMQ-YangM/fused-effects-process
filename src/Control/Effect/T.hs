{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.Effect.T where

import Control.Algebra (Algebra (..), Has, type (:+:) (..))
import Control.Carrier.Lift (Lift (..), sendM)
import Control.Carrier.Reader
  ( Reader,
    ReaderC (..),
    ask,
    runReader,
  )
import Control.Carrier.State.Strict
  ( State,
    get,
    modify,
    runState,
  )
import Control.Effect.Labelled
  ( HasLabelled,
    Labelled,
    runLabelled,
    sendLabelled,
  )
import Control.Monad (void)
import Control.Monad.Class.MonadFork (MonadFork (forkIO))
import Control.Monad.Class.MonadSTM
  ( MonadSTM
      ( TMVar,
        TQueue,
        atomically,
        newEmptyTMVarIO,
        newTQueueIO,
        putTMVar,
        readTQueue,
        takeTMVar,
        writeTQueue
      ),
  )
import Control.Monad.Class.MonadSay (MonadSay (..))
import Control.Monad.Class.MonadTime (DiffTime, MonadTime (..))
import Control.Monad.Class.MonadTimer
  ( MonadDelay (..),
    MonadTimer (timeout),
  )
import Control.Monad.IOSim
  ( IOSim,
    runSimTrace,
    selectTraceEventsSay,
  )
import Data.Kind
  ( Type,
  )
import GHC.TypeLits
  ( Symbol,
  )

type Some :: (Type -> Type) -> ((Type -> Type) -> Type -> Type) -> Type
data Some n f where
  Some :: !(f n (t n)) -> Some n f

inject ::
  forall
    (e :: (Type -> Type) -> Type)
    (f :: ((Type -> Type) -> Type -> Type))
    (n :: Type -> Type).
  ToSig e f n =>
  e n ->
  Some n f
inject = Some . toSig

class
  ToSig
    (e :: (Type -> Type) -> Type)
    (f :: (Type -> Type) -> Type -> Type)
    (n :: Type -> Type)
  where
  toSig :: e n -> f n (e n)

data RespVal n a where
  RespVal :: !(TMVar n a) -> RespVal n a

type Request ::
  ((Type -> Type) -> Type -> Type) ->
  [Type] ->
  (Type -> Type) ->
  (Type -> Type) ->
  Type ->
  Type
data Request s ts n m a where
  Call ::
    (ToSig t s n) =>
    (RespVal n b -> t n) ->
    Request s ts n m b
  Cast ::
    (ToSig t s n) =>
    t n ->
    Request s ts n m ()
  TimeoutCall ::
    (ToSig t s n) =>
    DiffTime ->
    (RespVal n b -> t n) ->
    Request s ts n m (Maybe b)

type RequestC ::
  ((Type -> Type) -> Type -> Type) ->
  [Type] ->
  (Type -> Type) ->
  (Type -> Type) ->
  Type ->
  Type
newtype RequestC s ts n m a = RequestC
  { unRequestC ::
      ReaderC (TQueue n (Some n s)) m a
  }
  deriving (Functor, Applicative, Monad)

instance
  ( Monad n,
    MonadTimer n,
    MonadSTM n,
    Has (Lift n) sig m
  ) =>
  Algebra (Request s ts n :+: sig) (RequestC s ts n m)
  where
  alg hdl sig ctx = RequestC $
    ReaderC $ \c -> case sig of
      L (Call f) -> do
        val <- sendM @n $ do
          tmvar <- newEmptyTMVarIO
          atomically $ writeTQueue c (inject (f $ RespVal tmvar))
          atomically $ takeTMVar tmvar
        pure (val <$ ctx)
      L (Cast f) -> do
        sendM @n $ atomically $ writeTQueue c (inject f)
        pure ctx
      L (TimeoutCall i f) -> do
        val <- sendM @n $ do
          tmvar <- newEmptyTMVarIO
          atomically $ writeTQueue c (inject (f $ RespVal tmvar))
          timeout i $ atomically $ takeTMVar tmvar
        pure (val <$ ctx)
      R signa -> alg (runReader c . unRequestC . hdl) signa ctx
  {-# INLINE alg #-}

call ::
  forall serverName s ts n sig m e b.
  ( ToSig e s n,
    HasLabelled (serverName :: Symbol) (Request s ts n) sig m
  ) =>
  (RespVal n b -> e n) ->
  m b
call f = sendLabelled @serverName (Call f)
{-# INLINE call #-}

cast ::
  forall serverName s ts n sig m e.
  ( ToSig e s n,
    HasLabelled (serverName :: Symbol) (Request s ts n) sig m
  ) =>
  e n ->
  m ()
cast f = sendLabelled @serverName (Cast f)
{-# INLINE cast #-}

timeoutCall ::
  forall serverName s ts n sig m e b.
  ( ToSig e s n,
    HasLabelled (serverName :: Symbol) (Request s ts n) sig m
  ) =>
  DiffTime ->
  (RespVal n b -> e n) ->
  m (Maybe b)
timeoutCall time f = sendLabelled @serverName (TimeoutCall time f)
{-# INLINE timeoutCall #-}

type HasServer (serverName :: Symbol) s ts n sig m =
  ( HasLabelled serverName (Request s ts n) sig m
  )

runWithServer ::
  forall serverName n s ts m a.
  TQueue n (Some n s) ->
  Labelled (serverName :: Symbol) (RequestC s ts n) m a ->
  m a
runWithServer chan f =
  runReader chan $ unRequestC $ runLabelled f
{-# INLINE runWithServer #-}

instance Algebra (Lift (IOSim s)) (IOSim s) where
  alg hdl (LiftWith with) = with hdl

withMessageChan ::
  forall n s sig m.
  ( MonadSTM n,
    Has (Lift n) sig m,
    Has (Reader (TQueue n (Some n s))) sig m
  ) =>
  (forall s0. s n s0 %1 -> m ()) ->
  m ()
withMessageChan f = do
  tc <- ask @(TQueue n (Some n s))
  Some v <- sendM @n $ atomically $ readTQueue tc
  f v

withResp ::
  forall n sig m a.
  ( MonadSTM n,
    Has (Lift n) sig m
  ) =>
  RespVal n a %1 ->
  m a ->
  m ()
withResp (RespVal tmv) ma = do
  val <- ma
  sendM @n $ atomically $ putTMVar tmv val
{-# INLINE withResp #-}

forever :: (Applicative f) => f () -> f b
forever a = let a' = a *> a' in a'
{-# INLINE forever #-}

--------------------------- example

data C (n :: Type -> Type) where
  C :: RespVal n Int %1 -> C n

data D (n :: Type -> Type) where
  D :: Int -> D n

data SigC n s where
  SigC1 :: C n %1 -> SigC n (C n)
  SigC2 :: D n %1 -> SigC n (D n)

instance ToSig C SigC n where
  toSig = SigC1

instance ToSig D SigC n where
  toSig = SigC2

client ::
  forall n sig m.
  ( MonadDelay n,
    Has (Lift n) sig m,
    HasServer "s" SigC '[C n, D n] n sig m
  ) =>
  m ()
client = do
  val <- call @"s" C
  if val > 10000
    then pure ()
    else do
      cast @"s" $ D val
      sendM @n $ threadDelay 0.3
      client

server ::
  forall n sig m.
  ( MonadSay n,
    MonadSTM n,
    MonadTime n,
    Has (Lift n) sig m,
    Has (State Int) sig m,
    Has (Reader (TQueue n (Some n SigC))) sig m
  ) =>
  m ()
server = forever $ do
  withMessageChan @n @SigC $ \case
    SigC1 (C resp) -> withResp resp $ do
      get @Int
    SigC2 (D i) -> do
      time <- sendM @n $ getCurrentTime
      sendM @n $ say $ show (time, i)
      modify @Int (+ i)

runval ::
  forall n.
  ( MonadSay n,
    MonadSTM n,
    MonadFork n,
    MonadDelay n,
    MonadTimer n,
    MonadTime n,
    Algebra (Lift n) n
  ) =>
  n ()
runval = do
  s <- newTQueueIO
  forkIO
    . void
    $ runWithServer @"s" @n s client

  forkIO
    . void
    . runReader s
    . runState @Int 1
    $ server @n

  threadDelay 2
  pure ()

runval1 :: IO ()
runval1 = runval

runval2 :: [String]
runval2 = selectTraceEventsSay $ runSimTrace runval

-- >>> runval2
-- ["(1970-01-01 00:00:00 UTC,1)","(1970-01-01 00:00:00.3 UTC,2)","(1970-01-01 00:00:00.6 UTC,4)","(1970-01-01 00:00:00.9 UTC,8)","(1970-01-01 00:00:01.2 UTC,16)","(1970-01-01 00:00:01.5 UTC,32)","(1970-01-01 00:00:01.8 UTC,64)"]