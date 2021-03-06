{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Example.EOT where

import Control.Algebra (Has, type (:+:))
import Control.Carrier.Reader (Reader, asks)
import Control.Concurrent
  ( threadDelay,
    tryTakeMVar,
  )
import Control.Concurrent.STM (readTVarIO)
import Control.Monad (forever)
import Control.Monad.IO.Class (MonadIO (..))
import qualified Data.Map as Map
import Example.Metric
import Example.Type
import Control.Carrier.HasServer (HasServer, cast)
import Control.Carrier.Metric
  ( Metric,
    getAll,
    inc,
    showMetric,
  )
import Process.Type (Result (Result))

-------------------------------------eot server
eotProcess ::
  ( MonadIO m,
    HasServer "log" SigLog '[Log] sig m,
    HasServer "et" SigException '[ProcessR] sig m,
    Has (Reader EotConfig :+: Metric ETmetric) sig m
  ) =>
  m ()
eotProcess = forever $ do
  inc all_et_cycle
  tvar <- asks etMap
  tmap <- liftIO $ readTVarIO tvar
  flip Map.traverseWithKey tmap $ \_ tv ->
    liftIO (tryTakeMVar tv) >>= \case
      Nothing -> do
        inc all_et_nothing
        pure ()
      Just (Result _ pid res) -> do
        case res of
          Left _ -> inc all_et_exception
          Right _ -> inc all_et_terminate
        cast @"et" (ProcessR pid res)
  interval <- asks einterval
  allMetrics <- getAll @ETmetric
  cast @"log" $ LW (showMetric allMetrics)
  liftIO $ threadDelay interval
