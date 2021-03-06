module Clarify.Linearize
  ( linearize,
  )
where

import Clarify.Utility
import Data.Code
import Data.Env
import Data.Ident
import qualified Data.IntMap as IntMap

-- insert an appropriate header for a closed chain
linearize ::
  [(Ident, CodePlus)] -> -- [(x1, t1), ..., (xn, tn)]  (closed chain)
  CodePlus ->
  WithEnv CodePlus
linearize xts =
  linearize' IntMap.empty (reverse xts)

type NameMap = IntMap.IntMap [Ident]

linearize' ::
  NameMap ->
  [(Ident, CodePlus)] -> -- [(xn, tn), ..., (x1, t1)]  (reversed closed chain)
  CodePlus ->
  WithEnv CodePlus
linearize' nm binder e =
  case binder of
    [] ->
      return e
    (x, t) : xts -> do
      (nmE, e') <- distinguishCode [x] e
      let newNm = merge [nmE, nm]
      e'' <- withHeader newNm x t e'
      linearize' newNm xts e''

-- insert header for a variable
withHeader :: NameMap -> Ident -> CodePlus -> CodePlus -> WithEnv CodePlus
withHeader nm x t e =
  case IntMap.lookup (asInt x) nm of
    Nothing ->
      withHeaderAffine x t e
    Just [] ->
      raiseCritical' $ "impossible. x: " <> asText' x
    Just [z] ->
      withHeaderLinear z x e
    Just (z1 : z2 : zs) ->
      withHeaderRelevant x t z1 z2 zs e

-- withHeaderAffine x t e ~>
--   bind _ :=
--     bind exp := t^# in        --
--     exp @ (0, x) in           -- AffineApp
--   e
withHeaderAffine :: Ident -> CodePlus -> CodePlus -> WithEnv CodePlus
withHeaderAffine x t e@(m, _) = do
  hole <- newNameWith' "unit"
  discardUnusedVar <- toAffineApp m x t
  return (m, CodeUpElim hole discardUnusedVar e)

-- withHeaderLinear z x e ~>
--   bind z := return x in
--   e
withHeaderLinear :: Ident -> Ident -> CodePlus -> WithEnv CodePlus
withHeaderLinear z x e@(m, _) =
  return (m, CodeUpElim z (m, CodeUpIntro (m, DataUpsilon x)) e)

-- withHeaderRelevant x t [x1, ..., x{N}] e ~>
--   bind exp := t in
--   bind sigTmp1 := exp @ (0, x) in               --
--   let (x1, tmp1) := sigTmp1 in                  --
--   ...                                           -- withHeaderRelevant'
--   bind sigTmp{N-1} := exp @ (0, tmp{N-2}) in    --
--   let (x{N-1}, x{N}) := sigTmp{N-1} in          --
--   e                                             --
-- (assuming N >= 2)
withHeaderRelevant ::
  Ident ->
  CodePlus ->
  Ident ->
  Ident ->
  [Ident] ->
  CodePlus ->
  WithEnv CodePlus
withHeaderRelevant x t x1 x2 xs e@(m, _) = do
  (expVarName, expVar) <- newDataUpsilonWith m "exp"
  linearChain <- toLinearChain $ x : x1 : x2 : xs
  rel <- withHeaderRelevant' t expVar linearChain e
  return (m, CodeUpElim expVarName t rel)

type LinearChain = [(Ident, (Ident, Ident))]

--    toLinearChain [x0, x1, x2, ..., x{N-1}] (N >= 3)
-- ~> [(x0, (x1, tmp1)), (tmp1, (x2, tmp2)), ..., (tmp{N-3}, (x{N-2}, x{N-1}))]
--
-- example behavior (length xs = 5):
--   xs = [x1, x2, x3, x4, x5]
--   valueSeq = [x2, x3, x4]
--   tmpSeq = [tmpA, tmpB]
--   tmpSeq' = [x1, tmpA, tmpB, x5]
--   pairSeq = [(x2, tmpA), (x3, tmpB), (x4, x5)]
--   result = [(x1, (x2, tmpA)), (tmpA, (x3, tmpB)), (tmpB, (x4, x5))]
--
-- example behavior (length xs = 3):
--   xs = [x1, x2, x3]
--   valueSeq = [x2]
--   tmpSeq = []
--   tmpSeq' = [x1, x3]
--   pairSeq = [(x2, x3)]
--   result = [(x1, (x2, x3))]
toLinearChain :: [Ident] -> WithEnv LinearChain
toLinearChain xs = do
  let valueSeq = init $ tail xs
  tmpSeq <- mapM (const $ newNameWith' "chain") $ replicate (length xs - 3) ()
  let tmpSeq' = [head xs] ++ tmpSeq ++ [last xs]
  let pairSeq = zip valueSeq (tail tmpSeq')
  return $ zip (init tmpSeq') pairSeq

-- withHeaderRelevant' expVar [(x1, (x2, tmpA)), (tmpA, (x3, tmpB)), (tmpB, (x3, x4))] ~>
--   bind sigVar1 := expVar @ (1, x1) in
--   let (x2, tmpA) := sigVar1 in
--   bind sigVar2 := expVar @ (1, tmpA) in
--   let (x3, tmpB) := sigVar2 in
--   bind sigVar3 := expVar @ (1, tmpB) in
--   let (x3, x4) := sigVar3 in
--   e
withHeaderRelevant' :: CodePlus -> DataPlus -> LinearChain -> CodePlus -> WithEnv CodePlus
withHeaderRelevant' t expVar ch cont@(m, _) =
  case ch of
    [] ->
      return cont
    (x, (x1, x2)) : chain -> do
      cont' <- withHeaderRelevant' t expVar chain cont
      (sigVarName, sigVar) <- newDataUpsilonWith m "sig"
      return
        ( m,
          CodeUpElim
            sigVarName
            ( m,
              CodePiElimDownElim
                expVar
                [(m, DataEnumIntro boolTrue), (m, DataUpsilon x)]
            )
            (m, sigmaElim [x1, x2] sigVar cont')
        )

merge :: [NameMap] -> NameMap
merge =
  foldr (IntMap.unionWith (++)) IntMap.empty

distinguishData :: [Ident] -> DataPlus -> WithEnv (NameMap, DataPlus)
distinguishData zs term =
  case term of
    (ml, DataUpsilon x) ->
      if x `notElem` zs
        then return (IntMap.empty, term)
        else do
          x' <- newNameWith x
          return (IntMap.singleton (asInt x) [x'], (ml, DataUpsilon x'))
    (ml, DataSigmaIntro mk ds) -> do
      (vss, ds') <- unzip <$> mapM (distinguishData zs) ds
      return (merge vss, (ml, DataSigmaIntro mk ds'))
    (m, DataStructIntro dks) -> do
      let (ds, ks) = unzip dks
      (vss, ds') <- unzip <$> mapM (distinguishData zs) ds
      return (merge vss, (m, DataStructIntro $ zip ds' ks))
    _ ->
      return (IntMap.empty, term)

distinguishCode :: [Ident] -> CodePlus -> WithEnv (NameMap, CodePlus)
distinguishCode zs term =
  case term of
    (ml, CodePrimitive theta) -> do
      (vs, theta') <- distinguishPrimitive zs theta
      return (vs, (ml, CodePrimitive theta'))
    (ml, CodePiElimDownElim d ds) -> do
      (vs, d') <- distinguishData zs d
      (vss, ds') <- unzip <$> mapM (distinguishData zs) ds
      return (merge $ vs : vss, (ml, CodePiElimDownElim d' ds'))
    (ml, CodeSigmaElim mk xs d e) -> do
      (vs1, d') <- distinguishData zs d
      let zs' = filter (`notElem` xs) zs
      (vs2, e') <- distinguishCode zs' e
      return (merge [vs1, vs2], (ml, CodeSigmaElim mk xs d' e'))
    (ml, CodeUpIntro d) -> do
      (vs, d') <- distinguishData zs d
      return (vs, (ml, CodeUpIntro d'))
    (ml, CodeUpElim x e1 e2) -> do
      (vs1, e1') <- distinguishCode zs e1
      if x `elem` zs
        then return (vs1, (ml, CodeUpElim x e1' e2))
        else do
          (vs2, e2') <- distinguishCode zs e2
          return (merge [vs1, vs2], (ml, CodeUpElim x e1' e2'))
    (ml, CodeEnumElim d branchList) -> do
      (vs, d') <- distinguishData zs d
      let (cs, es) = unzip branchList
      (vss, es') <- unzip <$> mapM (distinguishCode zs) es
      return (merge $ vs : vss, (ml, CodeEnumElim d' (zip cs es')))
    (ml, CodeStructElim xts d e) -> do
      (vs1, d') <- distinguishData zs d
      let zs' = filter (`notElem` map fst xts) zs
      (vs2, e') <- distinguishCode zs' e
      return (merge [vs1, vs2], (ml, CodeStructElim xts d' e'))

distinguishPrimitive :: [Ident] -> Primitive -> WithEnv (NameMap, Primitive)
distinguishPrimitive zs term =
  case term of
    PrimitiveUnaryOp op d -> do
      (vs, d') <- distinguishData zs d
      return (vs, PrimitiveUnaryOp op d')
    PrimitiveBinaryOp op d1 d2 -> do
      (vs1, d1') <- distinguishData zs d1
      (vs2, d2') <- distinguishData zs d2
      return (merge [vs1, vs2], PrimitiveBinaryOp op d1' d2')
    PrimitiveArrayAccess lowType d1 d2 -> do
      (vs1, d1') <- distinguishData zs d1
      (vs2, d2') <- distinguishData zs d2
      return (merge [vs1, vs2], PrimitiveArrayAccess lowType d1' d2')
    PrimitiveSyscall num ds -> do
      (vss, ds') <- unzip <$> mapM (distinguishData zs) ds
      return (merge vss, PrimitiveSyscall num ds')
