module Infer
  ( check
  , unify
  ) where

import           Control.Monad
import           Control.Monad.State
import           Control.Monad.Trans.Except

import           Control.Comonad.Cofree

import qualified Text.Show.Pretty           as Pr

import           Data

check :: Identifier -> QuasiComp -> WithEnv ()
check main e = do
  t <- inferC e
  insWTEnv main t -- insert the type of main function
  env <- get
  sub <- unify $ constraintEnv env
  env' <- get
  let aenv = argEnv env'
  argSubst <- unifyArg aenv
  let tenv' =
        map (\(s, t) -> (s, applyArgSubst argSubst $ sType sub t)) $
        weakTypeEnv env
  modify (\e -> e {weakTypeEnv = tenv', constraintEnv = []})

inferV :: QuasiValue -> WithEnv WeakType
inferV (QuasiValue (Meta {ident = i} :< ValueVar s)) = do
  mt <- lookupWTEnv s
  case mt of
    Just t -> do
      insWTEnv i t
      return t
    Nothing -> do
      new <- WeakTypePosHole <$> newName
      insWTEnv s new
      insWTEnv i new
      return new
inferV (QuasiValue (Meta {ident = j} :< ValueNodeApp s vs)) = do
  mt <- lookupVEnv s
  case mt of
    Nothing -> lift $ throwE $ "const " ++ s ++ " is not defined"
    Just (_, xts, t) -> do
      tvs <- mapM (inferV . QuasiValue) vs
      forM_ (zip xts tvs) $ \(xt, t2) -> insCEnv (weakenValueType $ snd xt) t2
      insWTEnv j $ weakenValueType t
      return $ weakenValueType t
inferV (QuasiValue (Meta {ident = i} :< ValueThunk e)) = do
  t <- inferC e
  let result = WeakTypeDown t i
  insWTEnv i result
  return result

inferC :: QuasiComp -> WithEnv WeakType
inferC (QuasiComp (Meta {ident = i} :< QuasiCompLam s e)) = do
  t <- WeakTypePosHole <$> newName
  insWTEnv s t
  te <- inferC (QuasiComp e)
  let result = WeakTypeForall (Ident s, t) te
  insWTEnv i result
  return result
inferC (QuasiComp (Meta {ident = l} :< QuasiCompApp e v)) = do
  te <- inferC (QuasiComp e)
  tv <- inferV v
  i <- newName
  insWTEnv i (WeakTypeNegHole i)
  j <- newName
  insCEnv te (WeakTypeForall (Hole j, tv) (WeakTypeNegHole i))
  let result = WeakTypeNegHole i
  insWTEnv l result
  return result
inferC (QuasiComp (Meta {ident = i} :< QuasiCompRet v)) = do
  tv <- inferV v
  let result = WeakTypeUp tv
  insWTEnv i result
  return result
inferC (QuasiComp (Meta {ident = i} :< QuasiCompBind s e1 e2)) = do
  t <- WeakTypePosHole <$> newName
  insWTEnv s t
  t1 <- inferC (QuasiComp e1)
  t2 <- inferC (QuasiComp e2)
  insCEnv (WeakTypeUp t) t1
  insWTEnv i t2
  return t2
inferC (QuasiComp (Meta {ident = l} :< QuasiCompUnthunk v)) = do
  t <- inferV v
  i <- newName
  insCEnv t (WeakTypeDown (WeakTypeNegHole i) l)
  let result = WeakTypeNegHole i
  insWTEnv l result
  return result
inferC (QuasiComp (Meta {ident = i} :< QuasiCompMu s e)) = do
  t <- WeakTypePosHole <$> newName
  insWTEnv s t
  te <- inferC (QuasiComp e)
  insCEnv (WeakTypeDown te i) t
  insWTEnv i te
  return te
inferC (QuasiComp (Meta {ident = i} :< QuasiCompCase vs vses)) = do
  ts <- mapM inferV vs
  let (vss, es) = unzip vses
  tvss <- mapM (mapM inferPat) vss
  forM_ tvss $ \tvs -> do forM_ (zip ts tvs) $ \(t1, t2) -> do insCEnv t1 t2
  ans <- WeakTypeNegHole <$> newName
  tes <- mapM (inferC . QuasiComp) es
  forM_ tes $ \te -> insCEnv ans te
  insWTEnv i ans
  return ans

inferPat :: Pat -> WithEnv WeakType
inferPat (Meta {ident = i} :< PatHole) = do
  t <- WeakTypePosHole <$> newName
  insWTEnv i t
  return t
inferPat (Meta {ident = i} :< PatVar s) = do
  mt <- lookupWTEnv s
  case mt of
    Just t -> do
      insWTEnv i t
      return t
    Nothing -> do
      new <- WeakTypePosHole <$> newName
      insWTEnv s new
      insWTEnv i new
      return new
inferPat (Meta {ident = j} :< PatApp s vs) = do
  mt <- lookupVEnv s
  case mt of
    Nothing -> lift $ throwE $ "const " ++ s ++ " is not defined"
    Just (_, xts, t) -> do
      tvs <- mapM inferPat vs
      -- need to add explicit parametrization
      forM_ (zip xts tvs) $ \(xt, t2) -> insCEnv (weakenValueType $ snd xt) t2
      insWTEnv j $ weakenValueType t
      return $ weakenValueType t

type Subst = [(String, WeakType)]

type Constraint = [(WeakType, WeakType)]

unify :: Constraint -> WithEnv Subst
unify [] = return []
unify ((WeakTypePosHole s, t2):cs) = do
  sub <- unify (sConstraint [(s, t2)] cs)
  return $ compose sub [(s, t2)]
unify ((t1, WeakTypePosHole s):cs) = do
  sub <- unify (sConstraint [(s, t1)] cs)
  return $ compose sub [(s, t1)]
unify ((WeakTypeNegHole s, t2):cs) = do
  sub <- unify (sConstraint [(s, t2)] cs)
  return $ compose sub [(s, t2)]
unify ((t1, WeakTypeNegHole s):cs) = do
  sub <- unify (sConstraint [(s, t1)] cs)
  return $ compose sub [(s, t1)]
unify ((WeakTypeVar s1, WeakTypeVar s2):cs)
  | s1 == s2 = unify cs
unify ((WeakTypeForall (i, tdom1) tcod1, WeakTypeForall (j, tdom2) tcod2):cs) = do
  insAEnv i j
  unify $ (tdom1, tdom2) : (tcod1, tcod2) : cs
unify ((WeakTypeNode x ts1, WeakTypeNode y ts2):cs)
  | x == y = unify $ (zip ts1 ts2) ++ cs
unify ((WeakTypeUp t1, WeakTypeUp t2):cs) = do
  unify $ (t1, t2) : cs
unify ((WeakTypeDown t1 i, WeakTypeDown t2 j):cs) = do
  insThunkEnv i j
  unify $ (t1, t2) : cs
unify ((WeakTypeUniv i, WeakTypeUniv j):cs) = do
  insLEnv i j
  unify cs
unify ((t1, t2):_) =
  lift $
  throwE $
  "unification failed for:\n" ++ Pr.ppShow t1 ++ "\nand:\n" ++ Pr.ppShow t2

compose :: Subst -> Subst -> Subst
compose s1 s2 = do
  let domS2 = map fst s2
  let codS2 = map snd s2
  let codS2' = map (sType s1) codS2
  let fromS1 = filter (\(ident, _) -> ident `notElem` domS2) s1
  fromS1 ++ zip domS2 codS2'

sType :: Subst -> WeakType -> WeakType
sType _ (WeakTypeVar s) = WeakTypeVar s
sType sub (WeakTypePosHole s) =
  case lookup s sub of
    Nothing -> WeakTypePosHole s
    Just t  -> t
sType sub (WeakTypeNegHole s) =
  case lookup s sub of
    Nothing -> WeakTypeNegHole s
    Just t  -> t
sType sub (WeakTypeUp t) = do
  let t' = sType sub t
  WeakTypeUp t'
sType sub (WeakTypeDown t i) = do
  let t' = sType sub t
  WeakTypeDown t' i
sType _ (WeakTypeUniv i) = WeakTypeUniv i
sType sub (WeakTypeForall (s, tdom) tcod) = do
  let tdom' = sType sub tdom
  let tcod' = sType sub tcod
  WeakTypeForall (s, tdom') tcod'
sType sub (WeakTypeNode s ts) = do
  let ts' = map (sType sub) ts
  WeakTypeNode s ts'

sConstraint :: Subst -> Constraint -> Constraint
sConstraint s = map (\(t1, t2) -> (sType s t1, sType s t2))

type ArgConstraint = [(IdentOrHole, IdentOrHole)]

type ArgSubst = [(Identifier, IdentOrHole)]

unifyArg :: ArgConstraint -> WithEnv ArgSubst
unifyArg [] = return []
unifyArg ((Hole s1, j):cs) = do
  sub <- unifyArg (sArgConstraint [(s1, j)] cs)
  return $ argCompose sub [(s1, j)]
unifyArg ((i, Hole s2):cs) = do
  sub <- unifyArg (sArgConstraint [(s2, i)] cs)
  return $ argCompose sub [(s2, i)]
unifyArg ((Ident s1, Ident s2):cs)
  | s1 == s2 = unifyArg cs
unifyArg ((x, y):_) =
  lift $
  throwE $
  "arg-unification failed for:\n" ++ Pr.ppShow x ++ "\nand:\n" ++ Pr.ppShow y

sArgConstraint :: ArgSubst -> ArgConstraint -> ArgConstraint
sArgConstraint s = map (\(t1, t2) -> (sArg s t1, sArg s t2))

sArg :: ArgSubst -> IdentOrHole -> IdentOrHole
sArg cs (Ident s) =
  case lookup s cs of
    Nothing -> Ident s
    Just s' -> s'
sArg cs (Hole s) =
  case lookup s cs of
    Nothing -> Hole s
    Just s' -> s'

argCompose :: ArgSubst -> ArgSubst -> ArgSubst
argCompose s1 s2 = do
  let domS2 = map fst s2
  let codS2 = map snd s2
  let codS2' = map (sArg s1) codS2
  let fromS1 = filter (\(ident, _) -> ident `notElem` domS2) s1
  fromS1 ++ zip domS2 codS2'

applyArgSubst :: ArgSubst -> WeakType -> WeakType
applyArgSubst _ (WeakTypeVar s) = WeakTypeVar s
applyArgSubst _ (WeakTypePosHole s) = WeakTypePosHole s
applyArgSubst _ (WeakTypeNegHole s) = WeakTypeNegHole s
applyArgSubst sub (WeakTypeNode x ts) = do
  let ts' = map (applyArgSubst sub) ts
  WeakTypeNode x ts'
applyArgSubst sub (WeakTypeUp t) = do
  let t' = applyArgSubst sub t
  WeakTypeUp t'
applyArgSubst sub (WeakTypeDown t i) = do
  let t' = applyArgSubst sub t
  WeakTypeDown t' i
applyArgSubst _ (WeakTypeUniv i) = WeakTypeUniv i
applyArgSubst sub (WeakTypeForall (s, tdom) tcod) = do
  let tdom' = applyArgSubst sub tdom
  let tcod' = applyArgSubst sub tcod
  WeakTypeForall (sArg sub s, tdom') tcod'
