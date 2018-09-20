-----------------------------------------------------------------------------
-- |
-- Module      :  Documentation.SBV.Examples.Lists.BoundedMutex
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Demonstrates use of bounded list utilities, proving a simple
-- mutex algorithm correct up to given bounds.
-----------------------------------------------------------------------------

{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedLists     #-}

module Documentation.SBV.Examples.Lists.BoundedMutex where

import Data.SBV
import Data.SBV.Control

import qualified Data.SBV.List         as L
import qualified Data.SBV.List.Bounded as L

-- | Each agent can be in one of the three states
data State = Idle     -- ^ Regular work
           | Ready    -- ^ Intention to enter critical state
           | Critical -- ^ In the critical state

-- | Make 'State' a symbolic enumeration
mkSymbolicEnumeration ''State

-- | The type synonym 'SState' is mnemonic for symbolic state.
type SState = SBV State

-- | Symbolic version of 'Idle'
idle :: SState
idle = literal Idle

-- | Symbolic version of 'Ready'
ready :: SState
ready = literal Ready

-- | Symbolic version of 'Critical'
critical :: SState
critical = literal Critical

-- | A bounded mutex property holds for two sequences of state transitions, if they are not in
-- their critical section at the same time up to that given bound.
mutex :: Int -> SList State -> SList State -> SBool
mutex i p1s p2s = L.band i $ L.bzipWith i (\p1 p2 -> p1 ./= critical ||| p2 ./= critical) p1s p2s

-- | A sequence is valid upto a bound if it starts at 'Idle', and follows the mutex rules. That is:
--
--    * From 'Idle' it can switch to 'Ready' or stay 'Idle'
--    * From 'Ready' it can switch to 'Critical' if it's its turn
--    * From 'Critical' it can either stay in 'Critical' or go back to 'Idle'
--
-- The variable @me@ identifies the agent id.
validSequence :: Int -> Integer -> SList Integer -> SList State -> SBool
validSequence b me pturns proc = bAnd [ L.length proc .== fromIntegral b
                                      , idle .== L.head proc
                                      , check b pturns proc idle
                                      ]
   where check 0 _  _  _    = true
         check i ts ps prev = let (cur,  rest)  = L.uncons ps
                                  (turn, turns) = L.uncons ts
                                  ok   = ite (prev .== idle)                          (cur `sElem` [idle, ready])
                                       $ ite (prev .== ready &&& turn .== literal me) (cur `sElem` [critical])
                                       $ ite (prev .== critical)                      (cur `sElem` [critical, idle])
                                       $                                              (cur `sElem` [prev])
                              in ok &&& check (i-1) turns rest cur

-- | The mutex algorithm, coded implicity as an assignment to turns. Turns start at @1@, and at each stage is either
-- @1@ or @2@; giving preference to that process. The only condition is that if either process is in its critical
-- section, then the turn value stays the same. Note that this is sufficient to satisfy safety (i.e., mutual
-- exclusion), though it does not guarantee liveness.
validTurns :: Int -> SList Integer -> SList State -> SList State -> SBool
validTurns b turns process1 process2 = bAnd [ L.length turns .== fromIntegral b
                                            , 1 .== L.head turns
                                            , check b turns process1 process2 1
                                            ]
   where check 0 _  _     _     _    = true
         check i ts proc1 proc2 prev =   cur `sElem` [1, 2]
                                     &&& (p1 .== critical ||| p2 .== critical ==> cur .== prev)
                                     &&& check (i-1) rest p1s p2s cur
            where (cur, rest) = L.uncons ts
                  (p1,  p1s)  = L.uncons proc1
                  (p2,  p2s)  = L.uncons proc2

-- | Check that we have the mutex property so long as 'validSequence' and 'validTurns' holds; i.e.,
-- so long as both the agents and the arbiter act according to the rules. The check is bounded up-to-the
-- given concrete bound; so this is an example of a bounded-model-checking style proof. We have:
--
-- >>> checkMutex 20
-- All is good!
checkMutex :: Int -> IO ()
checkMutex b = runSMT $ do
                  p1    :: SList State   <- sList "p1"
                  p2    :: SList State   <- sList "p2"
                  turns :: SList Integer <- sList "turns"

                  -- Ensure that both sequences and the turns are valid
                  constrain $ validSequence b 1 turns p1
                  constrain $ validSequence b 2 turns p2
                  constrain $ validTurns    b turns p1 p2

                  -- Try to assert that mutex does not hold. If we get a
                  -- counter example, we would've found a violation!
                  constrain $ bnot $ mutex b p1 p2

                  query $ do cs <- checkSat
                             case cs of
                               Unk   -> error "Solver said Unknown!"
                               Unsat -> io . putStrLn $ "All is good!"
                               Sat   -> do io . putStrLn $ "Violation detected!"
                                           do p1V <- getValue p1
                                              p2V <- getValue p2
                                              ts  <- getValue turns

                                              io . putStrLn $ "P1: " ++ show p1V
                                              io . putStrLn $ "P2: " ++ show p2V
                                              io . putStrLn $ "Ts: " ++ show ts
