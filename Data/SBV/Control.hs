-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.Control
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Control sublanguage for interacting with SMT solvers.
-----------------------------------------------------------------------------

{-# LANGUAGE NamedFieldPuns #-}

module Data.SBV.Control (
     -- * User queries
     -- $queryIntro
       Query, query

     -- * Checking satisfiability
     , CheckSatResult(..), checkSat, checkSatUsing, checkSatAssuming, checkSatAssumingWithUnsatisfiableSet

     -- * Querying the solver
     -- ** Extracting values
     , getValue, getModel, getAssignment, getSMTResult, getUnknownReason

     -- ** Extracting the unsat core
     , getUnsatCore

     -- ** Extracting a proof
     , getProof

     -- ** Extracting assertions
     , getAssertions

     -- * Getting solver information
     , SMTInfoFlag(..), SMTErrorBehavior(..), SMTReasonUnknown(..), SMTInfoResponse(..)
     , getInfo, getOption

     -- * Entering and exiting assertion stack
     , getAssertionStackDepth, push, pop, inNewAssertionStack

     -- * Tactics
     , caseSplit

     -- * Resetting the solver state
     , resetAssertions

     -- * Communicating results back
     -- ** Constructing assignments
     , (|->)

     -- ** Miscellaneous
     , echo

     -- ** Terminating the query
     , mkSMTResult
     , exit

     -- * Controlling the solver behavior
     , ignoreExitCode, timeout

     -- * Performing actions
     , io

     -- * Solver options
     , SMTOption(..)

     -- * Logics supported
     , Logic(..)

     ) where

import Data.SBV.Core.Data     (SMTProblem(..), SMTSolver(..), SMTConfig(..))
import Data.SBV.Core.Symbolic ( Query, IStage(..), SBVRunMode(..), Symbolic, Query(..)
                              , extractSymbolicSimulationState, solverSetOptions, runMode
                              )

import Data.SBV.Control.Query
import Data.SBV.Control.Utils (runProofOn)

import Data.IORef (readIORef, writeIORef)

import qualified Control.Monad.Reader as R (ask)
import Control.Monad.Trans  (liftIO)
import Control.Monad.State  (evalStateT)

-- | Run a custom query
query :: Query a -> Symbolic a
query (Query userQuery) = do
     st <- R.ask
     rm <- liftIO $ readIORef (runMode st)
     case rm of
        -- Transitioning from setup
        SMTMode ISetup isSAT cfg -> liftIO $ do let backend = engine (solver cfg)

                                                res <- extractSymbolicSimulationState st

                                                let SMTProblem{smtOptions, smtLibPgm} = runProofOn cfg isSAT [] res
                                                    cfg' = cfg { solverSetOptions = solverSetOptions cfg ++ smtOptions }
                                                    pgm  = smtLibPgm cfg'

                                                writeIORef (runMode st) $ SMTMode IRun isSAT cfg

                                                backend cfg' st (show pgm) $ evalStateT userQuery

        -- Already in a query, in theory we can just continue, but that causes use-case issues
        -- so we reject it. TODO: Review if we should actually support this. The issue arises with
        -- expressions like this:
        --
        -- In the following t0's output doesn't get recorded, as the output call is too late when we get
        -- here. (The output field isn't "incremental.") So, t0/t1 behave differently!
        --
        --   t0 = satWith z3{verbose=True, transcript=Just "t.smt2"} $ query (return (false::SBool))
        --   t1 = satWith z3{verbose=True, transcript=Just "t.smt2"} $ ((return (false::SBool)) :: Predicate)
        --
        -- Also, not at all clear what it means to go in an out of query mode:
        --
        -- r = runSMTWith z3{verbose=True} $ do
        --         a' <- sInteger "a"
        --
        --        (a, av) <- query $ do _ <- checkSat
        --                              av <- getValue a'
        --                              return (a', av)
        --
        --        liftIO $ putStrLn $ "Got: " ++ show av
        --        -- constrain $ a .> literal av + 1      -- Cant' do this since we're "out" of query. Sigh.
        --
        --        bv <- query $ do constrain $ a .> literal av + 1
        --                         _ <- checkSat
        --                         getValue a
        --
        --        return $ a' .== a' + 1
        --
        -- This would be one possible implementation, alas it has the problems above:
        --
        --    SMTMode IRun _ _ -> liftIO $ evalStateT userQuery st
        --
        -- So, we just reject it.

        SMTMode IRun _ _ -> error $ unlines [ ""
                                            , "*** Data.SBV: Unsupported nested query is detected."
                                            , "***"
                                            , "*** Please group your queries into one block. Note that this"
                                            , "*** can also arise if you have a call to 'query' not within 'runSMT'"
                                            , "*** For instance, within 'sat'/'prove' calls with custom user queries."
                                            , "*** The solution is to do the sat/prove part in the query directly."
                                            , "***"
                                            , "*** While multiple/nested queries should not be necessary in general,"
                                            , "*** please do get in touch if your use case does require such a feature,"
                                            , "*** to see how we can accommodate such scenarios."
                                            ]

        -- Otherwise choke!
        m -> error $ unlines [ ""
                             , "*** Data.SBV: Invalid query call."
                             , "***"
                             , "***   Current mode: " ++ show m
                             , "***"
                             , "*** Query calls are only valid within runSMT/runSMTWith calls"
                             ]

{- $queryIntro
In certain cases, the user might want to take over the communication with the solver, programmatically
querying the engine and issuing commands accordingly. Even with human guidance, perhaps, where the user
can take a look at the engine state and issue commands to guide the proof. This is an advanced feature,
as the user is given full access to the underlying SMT solver, so the usual protections provided by
SBV are no longer there to prevent mistakes.
-}
