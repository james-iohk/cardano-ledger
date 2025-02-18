{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Cardano.Ledger.Shelley.Rules.Epoch
  ( EPOCH,
    EpochPredicateFailure (..),
    EpochEvent (..),
    PredicateFailure,
  )
where

import Cardano.Ledger.BaseTypes (ShelleyBase)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core
import Cardano.Ledger.Shelley.EpochBoundary (SnapShots, obligation)
import Cardano.Ledger.Shelley.LedgerState
  ( EpochState,
    LedgerState,
    PState (..),
    UpecState (..),
    esAccountState,
    esLState,
    esNonMyopic,
    esPp,
    esPrevPp,
    esSnapshots,
    lsDPState,
    lsUTxOState,
    rewards,
    _deposited,
    _ppups,
    _reserves,
    pattern DPState,
    pattern EpochState,
  )
import Cardano.Ledger.Shelley.Rewards ()
import Cardano.Ledger.Shelley.Rules.PoolReap
  ( POOLREAP,
    PoolreapEvent,
    PoolreapPredicateFailure,
    PoolreapState (..),
  )
import Cardano.Ledger.Shelley.Rules.Snap (SNAP, SnapEvent, SnapPredicateFailure)
import Cardano.Ledger.Shelley.Rules.Upec (UPEC, UpecPredicateFailure)
import Cardano.Ledger.Slot (EpochNo)
import Control.SetAlgebra (eval, (⨃))
import Control.State.Transition
  ( Embed (..),
    STS (..),
    TRC (..),
    TransitionRule,
    judgmentContext,
    trans,
  )
import Data.Default.Class (Default)
import qualified Data.Map.Strict as Map
import Data.Void (Void)
import GHC.Generics (Generic)
import GHC.Records (HasField)
import NoThunks.Class (NoThunks (..))

data EPOCH era

data EpochPredicateFailure era
  = PoolReapFailure (PredicateFailure (EraRule "POOLREAP" era)) -- Subtransition Failures
  | SnapFailure (PredicateFailure (EraRule "SNAP" era)) -- Subtransition Failures
  | UpecFailure (PredicateFailure (EraRule "UPEC" era)) -- Subtransition Failures
  deriving (Generic)

deriving stock instance
  ( Eq (PredicateFailure (EraRule "POOLREAP" era)),
    Eq (PredicateFailure (EraRule "SNAP" era)),
    Eq (PredicateFailure (EraRule "UPEC" era))
  ) =>
  Eq (EpochPredicateFailure era)

deriving stock instance
  ( Show (PredicateFailure (EraRule "POOLREAP" era)),
    Show (PredicateFailure (EraRule "SNAP" era)),
    Show (PredicateFailure (EraRule "UPEC" era))
  ) =>
  Show (EpochPredicateFailure era)

data EpochEvent era
  = PoolReapEvent (Event (EraRule "POOLREAP" era))
  | SnapEvent (Event (EraRule "SNAP" era))
  | UpecEvent (Event (EraRule "UPEC" era))

instance
  ( EraTxOut era,
    Embed (EraRule "SNAP" era) (EPOCH era),
    Environment (EraRule "SNAP" era) ~ LedgerState era,
    State (EraRule "SNAP" era) ~ SnapShots (Crypto era),
    Signal (EraRule "SNAP" era) ~ (),
    Embed (EraRule "POOLREAP" era) (EPOCH era),
    Environment (EraRule "POOLREAP" era) ~ PParams era,
    State (EraRule "POOLREAP" era) ~ PoolreapState era,
    Signal (EraRule "POOLREAP" era) ~ EpochNo,
    Embed (EraRule "UPEC" era) (EPOCH era),
    Environment (EraRule "UPEC" era) ~ EpochState era,
    State (EraRule "UPEC" era) ~ UpecState era,
    Signal (EraRule "UPEC" era) ~ (),
    Default (State (EraRule "PPUP" era)),
    Default (PParams era),
    HasField "_keyDeposit" (PParams era) Coin,
    HasField "_poolDeposit" (PParams era) Coin
  ) =>
  STS (EPOCH era)
  where
  type State (EPOCH era) = EpochState era
  type Signal (EPOCH era) = EpochNo
  type Environment (EPOCH era) = ()
  type BaseM (EPOCH era) = ShelleyBase
  type PredicateFailure (EPOCH era) = EpochPredicateFailure era
  type Event (EPOCH era) = EpochEvent era
  transitionRules = [epochTransition]

instance
  ( NoThunks (PredicateFailure (EraRule "POOLREAP" era)),
    NoThunks (PredicateFailure (EraRule "SNAP" era)),
    NoThunks (PredicateFailure (EraRule "UPEC" era))
  ) =>
  NoThunks (EpochPredicateFailure era)

epochTransition ::
  forall era.
  ( Embed (EraRule "SNAP" era) (EPOCH era),
    Environment (EraRule "SNAP" era) ~ LedgerState era,
    State (EraRule "SNAP" era) ~ SnapShots (Crypto era),
    Signal (EraRule "SNAP" era) ~ (),
    Embed (EraRule "POOLREAP" era) (EPOCH era),
    Environment (EraRule "POOLREAP" era) ~ PParams era,
    State (EraRule "POOLREAP" era) ~ PoolreapState era,
    Signal (EraRule "POOLREAP" era) ~ EpochNo,
    Embed (EraRule "UPEC" era) (EPOCH era),
    Environment (EraRule "UPEC" era) ~ EpochState era,
    State (EraRule "UPEC" era) ~ UpecState era,
    Signal (EraRule "UPEC" era) ~ (),
    HasField "_keyDeposit" (PParams era) Coin,
    HasField "_poolDeposit" (PParams era) Coin
  ) =>
  TransitionRule (EPOCH era)
epochTransition = do
  TRC
    ( _,
      EpochState
        { esAccountState = acnt,
          esSnapshots = ss,
          esLState = ls,
          esPrevPp = pr,
          esPp = pp,
          esNonMyopic = nm
        },
      e
      ) <-
    judgmentContext
  let utxoSt = lsUTxOState ls
  let DPState dstate pstate = lsDPState ls
  ss' <-
    trans @(EraRule "SNAP" era) $ TRC (ls, ss, ())

  let PState pParams fPParams _ = pstate
      ppp = eval (pParams ⨃ fPParams)
      pstate' =
        pstate
          { _pParams = ppp,
            _fPParams = Map.empty
          }
  PoolreapState utxoSt' acnt' dstate' pstate'' <-
    trans @(EraRule "POOLREAP" era) $
      TRC (pp, PoolreapState utxoSt acnt dstate pstate', e)

  let epochState' =
        EpochState
          acnt'
          ss'
          (ls {lsUTxOState = utxoSt', lsDPState = DPState dstate' pstate''})
          pr
          pp
          nm

  UpecState pp' ppupSt' <-
    trans @(EraRule "UPEC" era) $
      TRC (epochState', UpecState pp (_ppups utxoSt'), ())
  let utxoSt'' = utxoSt' {_ppups = ppupSt'}

  let Coin oblgCurr = obligation pp (rewards dstate') (_pParams pstate'')
      Coin oblgNew = obligation pp' (rewards dstate') (_pParams pstate'')
      Coin reserves = _reserves acnt'
      utxoSt''' = utxoSt'' {_deposited = Coin oblgNew}
      acnt'' = acnt' {_reserves = Coin $ reserves + oblgCurr - oblgNew}
  pure $
    epochState'
      { esAccountState = acnt'',
        esLState = (esLState epochState') {lsUTxOState = utxoSt'''},
        esPrevPp = pp,
        esPp = pp'
      }

instance
  ( EraTxOut era,
    PredicateFailure (EraRule "SNAP" era) ~ SnapPredicateFailure era,
    Event (EraRule "SNAP" era) ~ SnapEvent era
  ) =>
  Embed (SNAP era) (EPOCH era)
  where
  wrapFailed = SnapFailure
  wrapEvent = SnapEvent

instance
  ( Era era,
    STS (POOLREAP era),
    PredicateFailure (EraRule "POOLREAP" era) ~ PoolreapPredicateFailure era,
    Event (EraRule "POOLREAP" era) ~ PoolreapEvent era
  ) =>
  Embed (POOLREAP era) (EPOCH era)
  where
  wrapFailed = PoolReapFailure
  wrapEvent = PoolReapEvent

instance
  ( Era era,
    STS (UPEC era),
    PredicateFailure (EraRule "UPEC" era) ~ UpecPredicateFailure era,
    Event (EraRule "UPEC" era) ~ Void
  ) =>
  Embed (UPEC era) (EPOCH era)
  where
  wrapFailed = UpecFailure
  wrapEvent = UpecEvent
