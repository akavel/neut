-- This module "polarizes" a neutral term into a negative term. Operationally,
-- this corresponds to determination of the order of evaluation. In proof-theoretic
-- term, we translate a ordinary dependent calculus to a dependent variant of
-- Call-By-Push-Value. A detailed explanation of Call-By-Push-Value can be found
-- in P. Levy, "Call-by-Push-Value: A Subsuming Paradigm". Ph. D. thesis,
-- Queen Mary College, 2001.
module Polarize
  ( polarize
  ) where

import Control.Monad.Except
import Control.Monad.State
import Data.List
import Prelude hiding (pi)

import Data.Basic
import Data.Code
import Data.Env
import Data.Term

polarize :: TermPlus -> WithEnv CodePlus
polarize (m, TermTau) = do
  let ml = snd $ obtainInfoMeta m
  v <- cartesianUniv ml
  return (ml, CodeUpIntro v)
polarize (m, TermTheta x) = polarizeTheta m x
polarize (m, TermUpsilon x) = do
  let ml = snd $ obtainInfoMeta m
  return (ml, CodeUpIntro (ml, DataUpsilon x))
polarize (m, TermPi _) = do
  let ml = snd $ obtainInfoMeta m
  tau <- cartesianImmediate ml
  (envVarName, envVar) <- newDataUpsilon
  let retTau = (ml, CodeUpIntro tau)
  let retEnvVar = (ml, CodeUpIntro envVar)
  closureType <-
    cartesianSigma
      "CLS"
      ml
      [Right (envVarName, retTau), Left retEnvVar, Left retTau]
  return (ml, CodeUpIntro closureType)
polarize (m, TermPiIntro xts e) = do
  let xs = map fst xts
  let fvs = obtainFreeVarList xs e
  e' <- polarize e
  makeClosure Nothing fvs m xts e'
polarize (m, TermPiElim e es) = do
  e' <- polarize e
  callClosure m e' es
polarize (m, TermMu (f, t) e) = do
  let ml = snd $ obtainInfoMeta m
  let (nameList, _, typeList) = unzip3 $ obtainFreeVarList [f] e
  let fvs = zip nameList typeList
  let fvs' = map toTermUpsilon fvs
  h <- newNameWith "hole"
  let clsMuType = (MetaTerminal ml, TermPi $ fvs ++ [(h, t)])
  let lamBody =
        substTermPlus
          [ ( f
            , ( MetaNonTerminal t ml
              , TermPiElim (MetaNonTerminal clsMuType ml, TermTheta f) fvs'))
          ]
          e
  let clsMeta = MetaNonTerminal clsMuType ml
  lamBody' <- polarize lamBody
  -- ここはクロージャではなく直接呼び出すように最適化が可能
  -- (その場合は上のsubstTermPlusの中のTermPiElimを「直接の」callへと書き換える必要がある)
  -- いや、clsにすぐcallClosureしてるから、インライン展開で結局直接の呼び出しになるのでは？
  cls <- makeClosure (Just f) [] clsMeta fvs lamBody'
  callClosure m cls fvs'
polarize (m, TermIntS size l) = do
  let ml = snd $ obtainInfoMeta m
  return (ml, CodeUpIntro (ml, DataIntS size l))
polarize (m, TermIntU size l) = do
  let ml = snd $ obtainInfoMeta m
  return (ml, CodeUpIntro (ml, DataIntU size l))
polarize (m, TermFloat16 l) = do
  let ml = snd $ obtainInfoMeta m
  return (ml, CodeUpIntro (ml, DataFloat16 l))
polarize (m, TermFloat32 l) = do
  let ml = snd $ obtainInfoMeta m
  return (ml, CodeUpIntro (ml, DataFloat32 l))
polarize (m, TermFloat64 l) = do
  let ml = snd $ obtainInfoMeta m
  return (ml, CodeUpIntro (ml, DataFloat64 l))
polarize (m, TermEnum _) = do
  let ml = snd $ obtainInfoMeta m
  v <- cartesianImmediate ml
  return (ml, CodeUpIntro v)
polarize (m, TermEnumIntro l) = do
  let ml = snd $ obtainInfoMeta m
  return (ml, CodeUpIntro (ml, DataEnumIntro l))
polarize (m, TermEnumElim e bs) = do
  let (cs, es) = unzip bs
  es' <- mapM polarize es
  (yts, y) <- polarize' e
  let ml = snd $ obtainInfoMeta m
  return $ bindLet yts (ml, CodeEnumElim y (zip cs es'))
polarize (m, TermArray _ _ _) = do
  let ml = snd $ obtainInfoMeta m
  tau <- cartesianImmediate ml
  (arrVarName, arrVar) <- newDataUpsilon
  let retTau = (ml, CodeUpIntro tau)
  let retArrVar = (ml, CodeUpIntro arrVar)
  arrayClsType <-
    cartesianSigma "ARRAYCLS" ml [Right (arrVarName, retTau), Left retArrVar]
  return (ml, CodeUpIntro arrayClsType)
polarize (m, TermArrayIntro k les) = do
  let ml = snd $ obtainInfoMeta m
  let retKindType = (ml, CodeUpIntro $ kindAsType k)
  -- arrayType = Sigma [_ : A, ..., _ : A]
  name <- newNameWith "array"
  arrayType <-
    cartesianSigma name ml $ map Left $ replicate (length les) retKindType
  let (ls, es) = unzip les
  (xess, xs) <- unzip <$> mapM polarize' es
  return $
    bindLet (concat xess) $
    ( ml
    , CodeUpIntro $
      (ml, DataSigmaIntro [arrayType, (ml, DataArrayIntro k (zip ls xs))]))
polarize (m, TermArrayElim k e1 e2) = do
  let ml = snd $ obtainInfoMeta m
  e1' <- polarize e1
  e2' <- polarize e2
  (arrVarName, arrVar) <- newDataUpsilon
  (idxVarName, idxVar) <- newDataUpsilon
  affVarName <- newNameWith "aff"
  relVarName <- newNameWith "rel"
  (arrTypeVarName, arrTypeVar) <- newDataUpsilon
  return $
    bindLet [(arrVarName, e1'), (idxVarName, e2')] $
    ( ml
    , CodeSigmaElim
        [arrTypeVarName, arrVarName]
        arrVar
        ( ml
        , CodeSigmaElim
            [affVarName, relVarName]
            arrTypeVar
            (ml, CodeArrayElim k arrVar idxVar)))

kindAsType :: ArrayKind -> DataPlus
kindAsType (ArrayKindIntS i) = (Nothing, (DataTheta $ "i" ++ show i))
kindAsType (ArrayKindIntU i) = (Nothing, (DataTheta $ "u" ++ show i))
kindAsType (ArrayKindFloat size) =
  (Nothing, (DataTheta $ "f" ++ show (sizeAsInt size)))

obtainFreeVarList ::
     [Identifier] -> TermPlus -> [(Identifier, Maybe Loc, TermPlus)]
obtainFreeVarList xs e = do
  filter (\(x, _, _) -> x `notElem` xs) $ varTermPlus e

type Binder = [(Identifier, CodePlus)]

-- polarize'がつくった変数はlinearに使用するようにすること。
polarize' :: TermPlus -> WithEnv (Binder, DataPlus)
polarize' e@(m, _) = do
  e' <- polarize e
  (varName, var) <- newDataUpsilon' $ snd $ obtainInfoMeta m
  return ([(varName, e')], var)

makeClosure ::
     Maybe Identifier -- the name of newly created closure
  -> [(Identifier, Maybe Loc, TermPlus)] -- list of free variables in `lam (x1, ..., xn). e`
  -> Meta -- meta of lambda
  -> [(Identifier, TermPlus)] -- the `(x1 : A1, ..., xn : An)` in `lam (x1 : A1, ..., xn : An). e`
  -> CodePlus -- the `e` in `lam (x1, ..., xn). e`
  -> WithEnv CodePlus
makeClosure mName fvs m xts e = do
  let (xs, _) = unzip xts
  let ml = snd $ obtainInfoMeta m
  let (freeVarNameList, locList, freeVarTypeList) = unzip3 fvs
  negTypeList <- mapM polarize freeVarTypeList
  expName <- newNameWith "exp"
  envExp <- cartesianSigma expName ml $ map Left negTypeList
  (envVarName, envVar) <- newDataUpsilon
  e' <- linearize (zip freeVarNameList freeVarTypeList ++ xts) e
  let lamBody = (ml, CodeSigmaElim freeVarNameList envVar e') -- このSigmaElimは「特別」なやつ（これだけ非線形でありうる）
  let fvSigmaIntro =
        ( ml
        , DataSigmaIntro $ zipWith (curry toDataUpsilon) freeVarNameList locList)
  name <-
    case mName of
      Just lamThetaName -> return lamThetaName
      Nothing -> newNameWith "cls"
  penv <- gets codeEnv
  when (name `elem` map fst penv) $ insCodeEnv name (envVarName : xs) lamBody
  return $
    ( ml
    , CodeUpIntro
        (ml, DataSigmaIntro [envExp, fvSigmaIntro, (ml, DataTheta name)]))

callClosure :: Meta -> CodePlus -> [TermPlus] -> WithEnv CodePlus
callClosure m e es = do
  (xess, xs) <- unzip <$> mapM polarize' es
  let ml = snd $ obtainInfoMeta m
  (clsVarName, clsVar) <- newDataUpsilon
  (typeVarName, typeVar) <- newDataUpsilon
  (envVarName, envVar) <- newDataUpsilon
  (lamVarName, lamVar) <- newDataUpsilon
  affVarName <- newNameWith "aff"
  relVarName <- newNameWith "rel"
  return $
    bindLet
      ((clsVarName, e) : concat xess)
      ( ml
      , CodeSigmaElim
          [typeVarName, envVarName, lamVarName]
          clsVar
          ( ml
          , CodeSigmaElim
              [affVarName, relVarName]
              typeVar
              (ml, CodePiElimDownElim lamVar (envVar : xs))))

-- linearize xts eは、xtsで指定された変数がeのなかでlinearに使用されるようにする。
-- xtsは「eのなかでlinearに出現するべき変数」。
linearize :: [(Identifier, TermPlus)] -> CodePlus -> WithEnv CodePlus
linearize xts e@(m, CodeSigmaElim ys d cont) = do
  let xts' = filter (\(x, _) -> x `notElem` ys ++ varCode e) xts -- eで使用されていない変数は「こっち」でfreeするので不要
  -- eの中で使用されていない変数をxtsから除外することでより早い段階でfreeを挿入することができるようになる。
  -- （使わない変数をずっと保持して関数の末尾になってようやくfreeする、なんてのは無駄なのでこれは最適化として機能する）
  -- CodeSigmaElimだけでなくUpElim, EnumElimに対しても同様の最適化をおこなっている。
  cont' <- linearize xts' cont
  withHeader xts (m, CodeSigmaElim ys d cont')
linearize xts e@(m, CodeUpElim x e1 e2) = do
  let as = filter (`notElem` varCode e) $ map fst xts -- `a` here stands for affine (list of variables that are used in the affine way)
  let xts1' = filter (\(y, _) -> y `notElem` as) xts
  e1' <- linearize xts1' e1
  let xts2' = filter (\(y, _) -> y `notElem` x : as) xts
  e2' <- linearize xts2' e2
  withHeader xts (m, CodeUpElim x e1' e2')
linearize xts e@(m, CodeEnumElim d les) = do
  let (ls, es) = unzip les
  let xts' = filter (\(x, _) -> x `notElem` varCode e) xts
  es' <- mapM (linearize xts') es
  withHeader xts (m, CodeEnumElim d $ zip ls es')
linearize xts e = withHeader xts e -- eのなかにCodePlusが含まれないケース

withHeader :: [(Identifier, TermPlus)] -> CodePlus -> WithEnv CodePlus
withHeader xts e = do
  (xtzss, e') <- distinguish xts e
  withHeader' xtzss e'

withHeader' ::
     [(Identifier, TermPlus, [Identifier])] -> CodePlus -> WithEnv CodePlus
withHeader' [] e = return e
withHeader' ((x, t, []):xtzss) e = do
  e' <- withHeader' xtzss e
  t' <- polarize t
  withHeaderAffine x t' e'
withHeader' ((_, _, [_]):xtzss) e = withHeader' xtzss e -- already linear
withHeader' ((x, t, (z1:z2:zs)):xtzss) e = do
  e' <- withHeader' xtzss e
  t' <- polarize t
  withHeaderRelevant x t' z1 z2 zs e'

-- withHeaderAffine x t e ~>
--   bind _ :=
--     bind exp := t^# in
--     let (aff, rel) := exp in
--     aff @ x in
--   e
withHeaderAffine :: Identifier -> CodePlus -> CodePlus -> WithEnv CodePlus
withHeaderAffine x t e = do
  hole <- newNameWith "var"
  discardUnusedVar <- toAffineApp Nothing x t
  return (Nothing, CodeUpElim hole discardUnusedVar e)

-- withHeaderRelevant x t [x1, ..., x{N}] e ~>
--   bind exp := t in
--   let (aff, rel) := exp in
--   let sigTmp1 := rel @ x in
--   let (x1, tmp1) := sigTmp1 in
--   ...
--   let sigTmp{N-1} := rel @ tmp{N-2} in
--   let (x{N-1}, x{N}) := sigTmp{N-1} in
--   e
-- (assuming N >= 2)
withHeaderRelevant ::
     Identifier
  -> CodePlus
  -> Identifier
  -> Identifier
  -> [Identifier]
  -> CodePlus
  -> WithEnv CodePlus
withHeaderRelevant x t x1 x2 xs e = do
  (expVarName, expVar) <- newDataUpsilon
  (affVarName, _) <- newDataUpsilon
  (relVarName, relVar) <- newDataUpsilon
  let ml = fst e
  rel <- withHeaderRelevant' relVar (ml, DataUpsilon x) x1 x2 xs e
  return
    ( ml
    , CodeUpElim
        expVarName
        t
        (ml, CodeSigmaElim [affVarName, relVarName] expVar rel))

-- withHeaderRelevant' relVar x y1 y2 [y3, y4] e ~>
--   bind sigVar1 := relVar @ x in
--   let (y1, tmp1) := sigVar1 in
--   bind sigVar2 := relVar @ tmp1 in
--   let (y2, tmp2) := sigVar2 in
--   bind sigVar3 := relVar @ tmp2 in
--   let (y3, y4) := sigVar3 in
--   e
withHeaderRelevant' ::
     DataPlus
  -> DataPlus -- copy from
  -> Identifier -- copy to (1)
  -> Identifier -- copy to (2)
  -> [Identifier]
  -> CodePlus
  -> WithEnv CodePlus
withHeaderRelevant' relVar x y1 y2 [] e = do
  let ml = fst e
  (sigVarName, sigVar) <- newDataUpsilon
  return $
    ( ml
    , CodeUpElim
        sigVarName
        (ml, CodePiElimDownElim relVar [x])
        (ml, CodeSigmaElim [y1, y2] sigVar e))
withHeaderRelevant' relVar x y1 y2 (y:ys) e = do
  (tmpVarName, tmpVar) <- newDataUpsilon
  let ml = fst e
  (sigVarName, sigVar) <- newDataUpsilon
  -- e' =
  --   bind someNewVar := relVar @ tmpVar in
  --   let (y2, NOT_KNOWN_YET) := someNewVar in
  --   ...
  --   e
  e' <- withHeaderRelevant' relVar tmpVar y2 y ys e
  -- resulting term:
  --   bind sigVar := relVar @ x in
  --   let (y1, tmpVar) := sigVar in
  --   bind someNewVar := relVar @ tmpVar in     ---
  --   let (y2, NOT_KNOWN_YET) := someNewVar in  ---  e'
  --   ...                                       ---
  --   e                                         ---
  return $
    ( ml
    , CodeUpElim
        sigVarName
        (ml, CodePiElimDownElim relVar [x])
        (ml, CodeSigmaElim [y1, tmpVarName] sigVar e'))

bindLet :: Binder -> CodePlus -> CodePlus
bindLet [] cont = cont
bindLet ((x, e):xes) cont = do
  let cont' = bindLet xes cont
  (fst cont', CodeUpElim x e cont')

cartesianImmediate :: Maybe Loc -> WithEnv DataPlus
cartesianImmediate ml = do
  aff <- affineImmediate ml
  rel <- relevantImmediate ml
  return (ml, DataSigmaIntro [aff, rel])

affineImmediate :: Maybe Loc -> WithEnv DataPlus
affineImmediate ml = do
  cenv <- gets codeEnv
  let thetaName = "EXPONENT.IMMEDIATE.AFFINE"
  let theta = (ml, DataTheta thetaName)
  case lookup thetaName cenv of
    Just _ -> return theta
    Nothing -> do
      immVarName <- newNameWith "var"
      insCodeEnv
        thetaName
        [immVarName]
        (Nothing, CodeUpIntro (Nothing, DataSigmaIntro []))
      return theta

relevantImmediate :: Maybe Loc -> WithEnv DataPlus
relevantImmediate ml = do
  cenv <- gets codeEnv
  let thetaName = "EXPONENT.IMMEDIATE.RELEVANT"
  let theta = (ml, DataTheta thetaName)
  case lookup thetaName cenv of
    Just _ -> return theta
    Nothing -> do
      (immVarName, immVar) <- newDataUpsilon
      insCodeEnv
        thetaName
        [immVarName]
        (Nothing, CodeUpIntro (Nothing, DataSigmaIntro [immVar, immVar]))
      return theta

cartesianUniv :: Maybe Loc -> WithEnv DataPlus
cartesianUniv ml = do
  aff <- affineUniv ml
  rel <- relevantUniv ml
  return (ml, DataSigmaIntro [aff, rel])

-- \x -> let (_, _) := x in unit
affineUniv :: Maybe Loc -> WithEnv DataPlus
affineUniv ml = do
  cenv <- gets codeEnv
  let thetaName = "EXPONENT.UNIV.AFFINE"
  let theta = (ml, DataTheta thetaName)
  case lookup thetaName cenv of
    Just _ -> return theta
    Nothing -> do
      (univVarName, univVar) <- newDataUpsilon
      affVarName <- newNameWith "var"
      relVarName <- newNameWith "var"
      insCodeEnv
        thetaName
        [univVarName]
        -- let (a, b) := x in return ()
        ( Nothing
        , CodeSigmaElim
            [affVarName, relVarName]
            univVar
            (Nothing, CodeUpIntro (Nothing, DataSigmaIntro [])))
      return theta

relevantUniv :: Maybe Loc -> WithEnv DataPlus
relevantUniv ml = do
  cenv <- gets codeEnv
  let thetaName = "EXPONENT.UNIV.RELEVANT"
  let theta = (ml, DataTheta thetaName)
  case lookup thetaName cenv of
    Just _ -> return theta
    Nothing -> do
      (univVarName, univVar) <- newDataUpsilon
      (affVarName, affVar) <- newDataUpsilon
      (relVarName, relVar) <- newDataUpsilon
      insCodeEnv
        thetaName
        [univVarName]
        -- let (a, b) := x in return ((a, b), (a, b))
        ( Nothing
        , CodeSigmaElim
            [affVarName, relVarName]
            univVar
            ( Nothing
            , CodeUpIntro
                ( Nothing
                , DataSigmaIntro
                    [ (Nothing, DataSigmaIntro [affVar, relVar])
                    , (Nothing, DataSigmaIntro [affVar, relVar])
                    ])))
      return theta

cartesianSigma ::
     Identifier
  -> Maybe Loc
  -> [Either CodePlus (Identifier, CodePlus)]
  -> WithEnv DataPlus
cartesianSigma thetaName ml mxes = do
  aff <- affineSigma thetaName ml mxes
  rel <- relevantSigma thetaName ml mxes
  return (ml, DataSigmaIntro [aff, rel])

-- (Assuming `ei` = `return di` for some `di` such that `xi : di`)
-- affineSigma NAME LOC [x1 : e1, ..., xn : en]   ~>
--   update CodeEnv with NAME ~> (thunk LAM), where LAM is:
--   lam z.
--     let (x1, ..., xn) := z in
--     bind y1 :=
--       bind f1 = e1 in              ---
--       let (aff-1, rel-1) = f1 in   ---  APP-1
--       aff-1 @ x1 in                ---
--     ...
--     bind yn :=
--       bind fn = en in              ---
--       let (aff-n, rel-n) := fn in  ---  APP-n
--       aff-n @ xn in                ---
--     return ()
-- (Note that sigma-elim for yi is not necessary since all of them are units.)
affineSigma ::
     Identifier
  -> Maybe Loc
  -> [Either CodePlus (Identifier, CodePlus)]
  -> WithEnv DataPlus
affineSigma thetaName ml mxes = do
  cenv <- gets codeEnv
  let theta = (ml, DataTheta thetaName)
  case lookup thetaName cenv of
    Just _ -> return theta
    Nothing -> do
      xes <- mapM supplyName mxes
      (sigVarName, sigVar) <- newDataUpsilon
      -- appList == [APP-1, ..., APP-n]
      appList <- forM xes $ \(x, e) -> toAffineApp ml x e
      ys <- mapM (const $ newNameWith "var") xes
      insCodeEnv
        thetaName
        [sigVarName]
        ( ml
        , CodeSigmaElim
            (map fst xes)
            sigVar
            (bindLet (zip ys appList) (ml, CodeUpIntro (ml, DataSigmaIntro []))))
      return theta

-- (Assuming `ei` = `return di` for some `di` such that `xi : di`)
-- relevantSigma NAME LOC [x1, e1, ..., xn, en]   ~>
--   update CodeEnv with NAME ~> (thunk LAM), where LAM is:
--   lam z.
--     let (x1, ..., xn) := z in
--     bind pair-1 :=
--       bind f1 = e1 in              ---
--       let (aff-1, rel-1) = f1 in   ---  APP-1
--       rel-1 @ x1 in                ---
--     ...
--     bind pair-n :=
--       bind fn = en in              ---
--       let (aff-n, rel-n) := fn in  ---  APP-n
--       rel-n @ xn in                ---
--     let (p11, p12) := pair-1 in               ---
--     ...                                       ---  TRANSPOSE-SIGMA
--     let (pn1, pn2) := pair-n in               ---
--     return ((p11, ..., pn1), (p12, ..., pn2)) ---
relevantSigma ::
     Identifier
  -> Maybe Loc
  -> [Either CodePlus (Identifier, CodePlus)]
  -> WithEnv DataPlus
relevantSigma thetaName ml mxes = do
  cenv <- gets codeEnv
  let theta = (ml, DataTheta thetaName)
  case lookup thetaName cenv of
    Just _ -> return theta
    Nothing -> do
      xes <- mapM supplyName mxes
      (sigVarName, sigVar) <- newDataUpsilon
      -- appList == [APP-1, ..., APP-n]
      appList <- forM xes $ \(x, e) -> toRelevantApp ml x e
      (pairVarNameList, pairVarList) <-
        unzip <$> mapM (const $ newDataUpsilon) xes
      transposedPair <- transposeSigma pairVarList
      insCodeEnv
        thetaName
        [sigVarName]
        ( ml
        , CodeSigmaElim
            (map fst xes)
            sigVar
            (bindLet (zip pairVarNameList appList) transposedPair))
      return theta

-- transposeSigma [d1, ..., dn] :=
--   let (x1, y1) := d1 in
--   ...
--   let (xn, yn) := dn in
--   return ((x1, ..., xn), (y1, ..., yn))
transposeSigma :: [DataPlus] -> WithEnv CodePlus
transposeSigma ds = do
  (xVarNameList, xVarList) <- unzip <$> mapM (const $ newDataUpsilon) ds
  (yVarNameList, yVarList) <- unzip <$> mapM (const $ newDataUpsilon) ds
  return $
    bindSigmaElim (zip (zip xVarNameList yVarNameList) ds) $
    ( Nothing
    , CodeUpIntro
        ( Nothing
        , DataSigmaIntro
            [ (Nothing, DataSigmaIntro xVarList)
            , (Nothing, DataSigmaIntro yVarList)
            ]))

bindSigmaElim :: [((Identifier, Identifier), DataPlus)] -> CodePlus -> CodePlus
bindSigmaElim [] cont = cont
bindSigmaElim (((x, y), d):xyds) cont = do
  let cont' = bindSigmaElim xyds cont
  (fst cont', CodeSigmaElim [x, y] d cont')

-- toAffineApp ML x e ~>
--   bind f := e in
--   let (aff, rel) := f in
--   aff @ x
toAffineApp :: Maybe Loc -> Identifier -> CodePlus -> WithEnv CodePlus
toAffineApp ml x e = do
  (expVarName, expVar) <- newDataUpsilon
  (affVarName, affVar) <- newDataUpsilon
  (relVarName, _) <- newDataUpsilon
  return
    ( ml
    , CodeUpElim
        expVarName
        e
        ( ml
        , CodeSigmaElim
            [affVarName, relVarName]
            expVar
            (ml, CodePiElimDownElim affVar [toDataUpsilon (x, fst e)])))

-- toRelevantApp ML x e ~>
--   bind f := e in
--   let (aff, rel) := f in
--   rel @ x
toRelevantApp :: Maybe Loc -> Identifier -> CodePlus -> WithEnv CodePlus
toRelevantApp ml x e = do
  (expVarName, expVar) <- newDataUpsilon
  (affVarName, _) <- newDataUpsilon
  (relVarName, relVar) <- newDataUpsilon
  return
    ( ml
    , CodeUpElim
        expVarName
        e
        ( ml
        , CodeSigmaElim
            [affVarName, relVarName]
            expVar
            (ml, CodePiElimDownElim relVar [toDataUpsilon (x, fst e)])))

polarizeTheta :: Meta -> Identifier -> WithEnv CodePlus
polarizeTheta m name
  | Just (lowType, op) <- asUnaryOpMaybe name =
    polarizeUnaryOp name op lowType m
polarizeTheta m name
  | Just (lowType, op) <- asBinaryOpMaybe name =
    polarizeBinaryOp name op lowType m
polarizeTheta m name
  | Just (sysCall, len, idxList) <- asSysCallMaybe name =
    polarizeSysCall name sysCall len idxList m
polarizeTheta m name@"core.print.i64" = polarizePrint name m
polarizeTheta _ _ = throwError "polarize.theta"

polarizeUnaryOp :: Identifier -> UnaryOp -> LowType -> Meta -> WithEnv CodePlus
polarizeUnaryOp name op lowType m = do
  let ml = snd $ obtainInfoMeta m
  (x, varX) <- newDataUpsilon
  -- どうせcartesianImmediateに噛ませるのでenumなら何でもオーケー
  let immediateType = (MetaTerminal ml, TermEnum "top")
  makeClosure
    (Just name)
    []
    m
    [(x, immediateType)]
    (ml, CodeTheta (ThetaUnaryOp op lowType varX))

polarizeBinaryOp ::
     Identifier -> BinaryOp -> LowType -> Meta -> WithEnv CodePlus
polarizeBinaryOp name op lowType m = do
  let ml = snd $ obtainInfoMeta m
  (x, varX) <- newDataUpsilon
  (y, varY) <- newDataUpsilon
  -- どうせcartesianImmediateに噛ませるのでenumなら何でもオーケー
  let immediateType = (MetaTerminal ml, TermEnum "top")
  makeClosure
    (Just name)
    []
    m
    [(x, immediateType), (y, immediateType)]
    (ml, CodeTheta (ThetaBinaryOp op lowType varX varY))

polarizePrint :: Identifier -> Meta -> WithEnv CodePlus
polarizePrint name m = do
  let ml = snd $ obtainInfoMeta m
  (x, varX) <- newDataUpsilon
  let i64Type = (MetaTerminal ml, TermEnum "i64")
  makeClosure (Just name) [] m [(x, i64Type)] (ml, CodeTheta (ThetaPrint varX))

polarizeSysCall ::
     Identifier -- the name of theta
  -> SysCall -- the kind of system call
  -> Int -- the length of the arguments of the theta
  -> [Int] -- used (or, non-discarded) arguments in its actual implementation (index starts from zero)
  -> Meta -- the meta of the theta
  -> WithEnv CodePlus
polarizeSysCall name sysCall argLen argIdxList m = do
  let (t, ml) = obtainInfoMeta m
  case t of
    (_, TermPi xts)
      -- (+1) is required since xts containts the type of cod
      | length xts == argLen + 1 -> do
        let ys = map (\i -> toVar $ fst $ xts !! i) argIdxList
        makeClosure
          (Just name)
          []
          m
          xts
          (ml, CodeTheta (ThetaSysCall sysCall ys))
    _ -> throwError $ "the type of " ++ name ++ " is wrong"

toVar :: Identifier -> DataPlus
toVar x = (Nothing, DataUpsilon x)

newDataUpsilon :: WithEnv (Identifier, DataPlus)
newDataUpsilon = newDataUpsilon' Nothing

newDataUpsilon' :: Maybe Loc -> WithEnv (Identifier, DataPlus)
newDataUpsilon' ml = do
  x <- newNameWith "arg"
  return (x, (ml, DataUpsilon x))
