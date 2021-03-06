{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Example.PTC where

import Control.Algebra (Has, type (:+:))
import Control.Carrier.Reader (Reader, asks)
import Control.Concurrent
  ( threadDelay,
  )
import Control.Concurrent.STM
import Control.Monad (forM_, forever)
import Control.Monad.IO.Class (MonadIO (..))
import Example.Metric
import Example.Type
import Control.Carrier.HasServer (HasServer, call, cast)
import Control.Carrier.Metric
  ( Metric,
    getAll,
    inc,
    showMetric,
  )

-------------------------------------process timeout checker
ptcProcess ::
  ( MonadIO m,
    HasServer "log" SigLog '[Log] sig m,
    Has (Reader PtConfig :+: Metric PTmetric) sig m,
    HasServer "ptc" SigTimeoutCheck '[StartTimoutCheck, ProcessTimeout] sig m
  ) =>
  m ()
ptcProcess = forever $ do
  allMetrics <- getAll @PTmetric
  cast @"log" $ LW $ showMetric allMetrics
  inc all_pt_cycle
  res <- call @"ptc" StartTimoutCheck
  tim <- asks ptctimeout
  liftIO $ threadDelay tim
  forM_ res $ \(pid, tmv) ->
    liftIO (atomically $ tryTakeTMVar tmv) >>= \case
      Nothing -> do
        inc all_pt_timeout
        cast @"ptc" (ProcessTimeout pid)
      Just TimeoutCheckFinish -> do
        inc all_pt_tcf
