{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Process.Effect.Utils
  ( withMessageChan,
    withResp,
    forever,
    newMessageChan,
    handleMsg,
  )
where

import Control.Carrier.Lift (Lift (..), sendM)
import Control.Effect.Labelled
import Control.Monad.Class.MonadSTM
  ( MonadSTM
      ( TQueue,
        atomically,
        newTQueueIO,
        putTMVar,
        readTQueue
      ),
  )
import GHC.TypeLits (Symbol)
import Process.Effect.HasMessageChan
  ( HasMessageChan,
    blockGetMessage,
  )
import Process.Effect.HasPeer
import Process.Effect.Type (RespVal (..), Some (..))

handleMsg ::
  forall (name :: Symbol) n s ts sig m.
  ( MonadSTM n,
    Has (Lift n) sig m,
    HasLabelled name (Peer s ts n) sig m
  ) =>
  (forall s0. s n (s0 n) %1 -> m ()) ->
  m ()
handleMsg f = do
  chan <- getSelfTQueue @name
  Some tc <- sendM @n $ atomically $ readTQueue chan
  f tc
{-# INLINE handleMsg #-}

withMessageChan ::
  forall symbol n s sig m.
  ( MonadSTM n,
    Has (Lift n) sig m,
    HasMessageChan symbol s n sig m
  ) =>
  (forall s0. s n (s0 n) %1 -> m ()) ->
  m ()
withMessageChan f = do
  Some v <- blockGetMessage @symbol
  f v
{-# INLINE withMessageChan #-}

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

newMessageChan :: forall n s. MonadSTM n => n (TQueue n (Some n s))
newMessageChan = newTQueueIO
