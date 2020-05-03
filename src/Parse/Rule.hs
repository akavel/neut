module Parse.Rule
  ( parseInductive,
    asInductive,
    generateProjections,
  )
where

import Control.Monad.State.Lazy
import Data.Env
import Data.Ident
import qualified Data.IntMap as IntMap
import Data.Meta
import Data.Namespace
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Tree
import Data.WeakTerm
import Parse.Discern
import Parse.Interpret

parseInductive :: Meta -> [TreePlus] -> WithEnv [WeakStmt]
parseInductive m ts = do
  ts' <- mapM setupIndPrefix ts
  parseConnective m ts' toInductive toInductiveIntroList

setupIndPrefix :: TreePlus -> WithEnv TreePlus
setupIndPrefix inputTree =
  case inputTree of
    (m, TreeNode ((ma, TreeLeaf a) : xts : rules)) -> do
      rules' <- mapM (setupIndPrefix' a) rules
      return (m, TreeNode ((ma, TreeLeaf a) : xts : rules'))
    _ ->
      raiseSyntaxError (fst inputTree) "(LEAF (TREE ... TREE) TREE)"

setupIndPrefix' :: T.Text -> TreePlus -> WithEnv TreePlus
setupIndPrefix' a inputTree =
  case inputTree of
    (m, TreeNode ((mb, TreeLeaf b) : rest)) ->
      return (m, TreeNode ((mb, TreeLeaf (a <> nsSep <> b)) : rest))
    _ ->
      raiseSyntaxError (fst inputTree) "(LEAF (TREE ... TREE) TREE)"

-- variable naming convention on parsing connectives:
--   a : the name of a formation rule, like `nat`, `list`, `stream`, etc.
--   b : the name of an introduction/elimination rule, like `zero`, `cons`, `head`, etc.
--   x : the name of an argument of a formation rule, like `A` in `list A` or `stream A`.
--   y : the name of an argument of an introduction/elimination rule, like `w` or `ws` in `cons : Pi (w : A, ws : list A). list A`.
parseConnective ::
  Meta ->
  [TreePlus] ->
  ([WeakTextPlus] -> [WeakTextPlus] -> Connective -> WithEnv [WeakStmt]) ->
  ([WeakTextPlus] -> [WeakTextPlus] -> Connective -> WithEnv [WeakStmt]) ->
  WithEnv [WeakStmt]
parseConnective m ts f g = do
  connectiveList <- mapM parseConnective' ts
  fs <- mapM formationRuleOf' connectiveList
  ats <- mapM ruleAsWeakTextPlus fs
  bts <- concat <$> mapM toInternalRuleList connectiveList
  checkNameSanity m $ ats ++ bts
  connectiveList' <- concat <$> mapM (f ats bts) connectiveList
  ruleList <- concat <$> mapM (g ats bts) connectiveList
  return $ connectiveList' ++ ruleList

parseConnective' :: TreePlus -> WithEnv Connective
parseConnective' inputTree =
  case inputTree of
    (m, TreeNode ((_, TreeLeaf name) : (_, TreeNode xts) : rules)) -> do
      xts' <- mapM interpretWeakIdentPlus xts
      rules' <- mapM parseRule rules
      return (m, name, xts', rules')
    _ ->
      raiseSyntaxError (fst inputTree) "(LEAF (TREE ... TREE) ...)"

toIndInfo :: TreePlus -> WithEnv (WeakTextPlus, [WeakIdentPlus])
toIndInfo ts = do
  connectiveList <- parseConnective' ts
  fs <- formationRuleOf connectiveList
  at <- ruleAsWeakTextPlus fs
  bts <- toInternalRuleList connectiveList
  case bts of
    [(_, "new", (_, WeakTermPi xts _))] ->
      return (at, xts)
    _ ->
      undefined

generateProjections :: TreePlus -> WithEnv [WeakStmt]
generateProjections t = do
  ((ma, a, ta), bts) <- toIndInfo t
  (xts, _) <- separatePi ta
  h <- newNameWith'' "_"
  let dom = (ma, h, (ma, WeakTermPiElim (ma, WeakTermUpsilon $ asIdent a) (map toVar' xts)))
  forM bts $ \(mb, b, tb) ->
    WeakStmtLetWT mb
      <$> discernIdentPlus
        ( mb,
          asIdent (a <> nsSep <> asText b),
          (mb, WeakTermPi (xts ++ [dom]) tb)
        )
      <*> discern
        ( mb,
          WeakTermPiIntro
            (xts ++ [dom])
            ( mb,
              WeakTermPiElim
                (mb, WeakTermUpsilon $ asIdent (a <> nsSep <> "fold"))
                $ map toVar' (xts ++ [dom])
                  ++ [ (mb, WeakTermPiIntro xts tb),
                       (mb, WeakTermPiIntro bts (mb, WeakTermUpsilon b))
                     ]
            )
        )

separatePi :: WeakTermPlus -> WithEnv ([WeakIdentPlus], WeakTermPlus)
separatePi e =
  case e of
    (_, WeakTermPi xts cod) ->
      return (xts, cod)
    _ -> do
      p' e
      raiseSyntaxError (fst e) "(pi (TREE ... TREE) TREE)"

parseRule :: TreePlus -> WithEnv Rule
parseRule inputTree =
  case inputTree of
    (m, TreeNode [(mName, TreeLeaf name), (_, TreeNode xts), t]) -> do
      t' <- interpret t
      xts' <- mapM interpretWeakIdentPlus xts
      return (m, name, mName, xts', t')
    _ ->
      raiseSyntaxError (fst inputTree) "(LEAF (TREE ... TREE) TREE)"

checkNameSanity :: Meta -> [WeakTextPlus] -> WithEnv ()
checkNameSanity m atsbts = do
  let asbs = map (\(_, x, _) -> x) atsbts
  when (not $ isLinear asbs) $
    raiseError
      m
      "the names of the rules of inductive/coinductive type must be distinct"

toInductive :: [WeakTextPlus] -> [WeakTextPlus] -> Connective -> WithEnv [WeakStmt]
toInductive ats bts connective@(m, ai, xts, _) = do
  at <- formationRuleOf connective >>= ruleAsWeakIdentPlus
  let cod = (m, WeakTermPiElim (m, WeakTermUpsilon $ asIdent ai) (map toVar' xts))
  let atsbts = map textPlusToWeakIdentPlus $ ats ++ bts
  -- definition of inductive type
  indType <-
    discern
      (m, WeakTermPiIntro xts (m, WeakTermPi atsbts cod))
  at' <- discernIdentPlus at
  insForm (length ats) at' indType
  -- definition of fold
  z <- newNameWith'' "_"
  let zt = (m, z, cod)
  let indArgs = xts ++ [zt] ++ atsbts
  fold <-
    discern
      (m, WeakTermPiIntro indArgs (m, WeakTermPiElim (toVar' zt) (map toVar' atsbts)))
  foldIdent <-
    discernIdentPlus
      (m, asIdent $ ai <> nsSep <> "fold", (m, WeakTermPi indArgs cod))
  return
    [ WeakStmtLetWT m at' indType,
      WeakStmtLetWT m foldIdent fold
    ]

toInductiveIntroList :: [WeakTextPlus] -> [WeakTextPlus] -> Connective -> WithEnv [WeakStmt]
toInductiveIntroList ats bts (_, a, xts, rules) = do
  let ats' = map textPlusToWeakIdentPlus ats
  let bts' = map textPlusToWeakIdentPlus bts
  concat <$> mapM (toInductiveIntro ats' bts' xts a) rules

-- represent the introduction rule within CoC
toInductiveIntro ::
  [WeakIdentPlus] ->
  [WeakIdentPlus] ->
  [WeakIdentPlus] ->
  T.Text ->
  Rule ->
  WithEnv [WeakStmt]
toInductiveIntro ats bts xts ai (mb, bi, m, yts, cod)
  | (_, WeakTermPiElim (_, WeakTermUpsilon a') es) <- cod,
    ai == asText a',
    length xts == length es = do
    let vs = varWeakTermPlus (m, WeakTermPi yts cod)
    let xts' = filter (\(_, x, _) -> x `S.member` vs) xts
    constructor <-
      discern
        ( m,
          WeakTermPiIntro
            (xts' ++ yts)
            ( m,
              WeakTermPiIntro
                (ats ++ bts)
                (m, WeakTermPiElim (mb, WeakTermUpsilon (asIdent bi)) (map toVar' yts))
            )
        )
    constructorIdent <-
      discernIdentPlus
        (mb, asIdent bi, (m, WeakTermPi (xts' ++ yts) cod))
    case constructor of
      (_, WeakTermPiIntro xtsyts (_, WeakTermPiIntro atsbts (_, WeakTermPiElim b _))) -> do
        as <- mapM (\(_, x, _) -> asInt <$> discernText m (asText x)) ats
        insInductive as constructorIdent
        yts' <- mapM (internalize as atsbts) $ drop (length xts') xtsyts
        return
          [ WeakStmtLetWT
              m
              constructorIdent
              ( m,
                WeakTermPiIntro
                  xtsyts
                  ( m,
                    WeakTermPiIntro atsbts (m, WeakTermPiElim b yts')
                  )
              )
          ]
      _ ->
        raiseCritical m "inductive-intro"
  | otherwise =
    raiseError m $
      "the succedent of an introduction rule of `"
        <> ai
        <> "` must be of the form `("
        <> showItems (ai : map (const "_") xts)
        <> ")`"

ruleAsWeakIdentPlus :: Rule -> WithEnv WeakIdentPlus
ruleAsWeakIdentPlus (mb, b, m, xts, t) =
  return (mb, asIdent b, (m, WeakTermPi xts t))

ruleAsWeakTextPlus :: Rule -> WithEnv WeakTextPlus
ruleAsWeakTextPlus (mb, b, m, xts, t) =
  return (mb, b, (m, WeakTermPi xts t))

textPlusToWeakIdentPlus :: WeakTextPlus -> WeakIdentPlus
textPlusToWeakIdentPlus (mx, x, t) =
  (mx, asIdent x, t)

formationRuleOf :: Connective -> WithEnv Rule
formationRuleOf (m, a, xts, _) =
  return (m, a, m, xts, (m, WeakTermTau))

formationRuleOf' :: Connective -> WithEnv Rule
formationRuleOf' (m, x, xts, rules) = do
  let bs = map (\(_, b, _, _, _) -> b) rules
  let bis = zip bs [0 ..]
  -- register "nat" ~> [("zero", 0), ("succ", 1)], "list" ~> [("nil", 0), ("cons", 1)], etc.
  insEnumEnv m x bis
  return (m, x, m, xts, (m, WeakTermTau))

toInternalRuleList :: Connective -> WithEnv [WeakTextPlus]
toInternalRuleList (_, _, _, rules) =
  mapM ruleAsWeakTextPlus rules

toVar' :: WeakIdentPlus -> WeakTermPlus
toVar' (m, x, _) =
  (m, WeakTermUpsilon x)

insForm :: Int -> WeakIdentPlus -> WeakTermPlus -> WithEnv ()
insForm i (_, a, _) e
  | i == 1 =
    modify (\env -> env {formationEnv = IntMap.insert (asInt a) (Just e) (formationEnv env)})
  | otherwise =
    modify (\env -> env {formationEnv = IntMap.insert (asInt a) Nothing (formationEnv env)})

insInductive :: [Int] -> WeakIdentPlus -> WithEnv ()
insInductive as bt =
  case as of
    [ai] -> do
      ienv <- gets indEnv
      modify (\env -> env {indEnv = IntMap.insertWith optConcat ai (Just [bt]) ienv})
    _ ->
      forM_ as $ \ai ->
        modify (\env -> env {indEnv = IntMap.insert ai Nothing (indEnv env)})

optConcat :: Maybe [a] -> Maybe [a] -> Maybe [a]
optConcat mNew mOld = do
  mNew' <- mNew
  mOld' <- mOld
  -- insert mNew at the end of the list (to respect the structure of ind/coind represented as pi/sigma)
  return $ mOld' ++ mNew'

toApp :: Meta -> TreePlus -> [TreePlus] -> WithEnv TreePlus
toApp m a xts = do
  argList <- mapM extractArg xts
  return (m, TreeNode (a : argList))

asInductive :: Meta -> [TreePlus] -> WithEnv TreePlus
asInductive m ts =
  case ts of
    (a : (_, TreeNode xts) : rules) -> do
      app <- toApp m a xts
      return
        ( m,
          TreeNode
            [ a,
              (m, TreeNode xts),
              ( m,
                TreeNode
                  [ (m, TreeLeaf "new"),
                    (m, TreeNode rules),
                    app
                  ]
              )
            ]
        )
    _ ->
      raiseSyntaxError m "(LEAF (TREE ... TREE) ...)"

extractArg :: TreePlus -> WithEnv TreePlus
extractArg tree =
  case tree of
    (m, TreeLeaf x) ->
      return (m, TreeLeaf x)
    (_, TreeNode [(m, TreeLeaf x), _]) ->
      return (m, TreeLeaf x)
    t ->
      raiseSyntaxError (fst t) "LEAF | (LEAF TREE)"

data Mode
  = ModeForward
  | ModeBackward
  deriving (Show)

internalize :: [Int] -> [WeakIdentPlus] -> WeakIdentPlus -> WithEnv WeakTermPlus
internalize as atsbts (m, y, t) = do
  let sub = IntMap.fromList $ zip as (map toVar' atsbts)
  let modifier e = (fst e, WeakTermPiElim e (map toVar' atsbts))
  theta ModeForward sub modifier t (m, WeakTermUpsilon y)

flipMode :: Mode -> Mode
flipMode mode =
  case mode of
    ModeForward -> ModeBackward
    ModeBackward -> ModeForward

isResolved :: SubstWeakTerm -> WeakTermPlus -> Bool
isResolved sub e = do
  let outerVarList = IntMap.keys sub
  let freeVarSet = S.map asInt $ varWeakTermPlus e
  all (`S.notMember` freeVarSet) outerVarList

-- e : Aを受け取って、flipしていないときはIN(A) = BをみたすB型のtermを、
-- また、flipしてるときはOUT(A) = BをみたすB型のtermを、
-- それぞれ構成して返す。IN/OUTはSubstWeakTermによって定まるものとする。
theta ::
  Mode -> -- 現在の変換がflipしているかそうでないかの情報
  SubstWeakTerm -> -- out ~> in (substitution sub := {x1 := x1', ..., xn := xn'})
  (WeakTermPlus -> WeakTermPlus) ->
  WeakTermPlus -> -- a type `A`
  WeakTermPlus -> -- a term `e` of type `A`
  WithEnv WeakTermPlus
theta mode isub modifier t e = do
  ienv <- gets indEnv
  case t of
    (_, WeakTermPi xts cod) ->
      thetaPi mode isub modifier xts cod e
    (_, WeakTermPiElim va@(_, WeakTermUpsilon ai) es)
      | Just _ <- IntMap.lookup (asInt ai) isub ->
        thetaInductive mode isub ai modifier es e
      -- nested inductive
      | Just (Just bts) <- IntMap.lookup (asInt ai) ienv,
        not (all (isResolved isub) es) ->
        thetaInductiveNested mode isub modifier e va ai es bts
      -- nestedの外側がmutualであるとき。このときはエラーとする。
      | Just Nothing <- IntMap.lookup (asInt ai) ienv ->
        thetaInductiveNestedMutual (metaOf t) ai
    _ ->
      if isResolved isub t
        then return e
        else do
          p "isub:"
          p' isub
          raiseError (metaOf t) $
            "malformed inductive/coinductive type definition: " <> toText t

thetaPi ::
  Mode ->
  SubstWeakTerm ->
  (WeakTermPlus -> WeakTermPlus) ->
  [WeakIdentPlus] ->
  WeakTermPlus ->
  WeakTermPlus ->
  WithEnv WeakTermPlus
thetaPi mode isub modifier xts cod e = do
  (xts', cod') <- renameBinder xts cod
  let (ms', xs', ts') = unzip3 xts'
  -- eta展開のための変数を用意
  let xs'' = zipWith (\m x -> (m, WeakTermUpsilon x)) ms' xs'
  -- xsを「逆方向」で変換（実際には逆向きの変換は不可能なので、2回flipされることを期待して変換）
  -- こうしたあとでx : In(A)と束縛してからthetaでの変換結果を使えば、x' : Out(A)が得られるので
  -- 引数として与えられるようになる、というわけ。
  xsBackward <- zipWithM (theta (flipMode mode) isub modifier) ts' xs''
  -- appのほうを「順方向」で変換
  appForward <- theta mode isub modifier cod' (fst e, WeakTermPiElim e xsBackward)
  -- 結果をまとめる
  let ts'' = map (substWeakTermPlus isub) ts' -- 引数をinternalizeされたバージョンの型にする
  return (fst e, WeakTermPiIntro (zip3 ms' xs' ts'') appForward)

thetaInductive ::
  Mode ->
  SubstWeakTerm ->
  Ident ->
  (WeakTermPlus -> WeakTermPlus) ->
  [WeakTermPlus] ->
  WeakTermPlus ->
  WithEnv WeakTermPlus
thetaInductive mode isub a modifier es e
  | ModeBackward <- mode =
    raiseError (metaOf e) $
      "found a contravariant occurence of `"
        <> asText a
        <> "` in the antecedent of an introduction rule"
  -- `list @ i64` のように、中身が処理済みであることをチェック (この場合はes == [i64])
  | all (isResolved isub) es =
    return $ modifier e
  | otherwise =
    raiseError (metaOf e) "found a self-nested inductive type"

thetaInductiveNested ::
  Mode ->
  SubstWeakTerm -> -- inductiveのためのaのsubst (outer -> inner)
  (WeakTermPlus -> WeakTermPlus) ->
  WeakTermPlus -> -- 変換されるべきterm
  WeakTermPlus -> -- list Aにおけるlist
  Ident -> -- list (トップレベルで定義されている名前、つまりouterの名前)
  [WeakTermPlus] -> -- list AにおけるA
  [WeakIdentPlus] -> -- トップレベルで定義されているコンストラクタたち
  WithEnv WeakTermPlus
thetaInductiveNested mode isub modifier e va aOuter es bts = do
  (xts, (_, aInner, _), btsInner) <- lookupInductive (metaOf va) aOuter
  let es' = map (substWeakTermPlus isub) es
  args <-
    zipWithM
      (toInternalizedArg mode isub aInner aOuter xts modifier es es')
      bts
      btsInner
  let m = fst e
  return
    ( m,
      WeakTermPiElim
        e
        ((m, WeakTermPiIntro xts (m, WeakTermPiElim va es')) : args)
    )

thetaInductiveNestedMutual :: Meta -> Ident -> WithEnv WeakTermPlus
thetaInductiveNestedMutual m ai =
  raiseError m $
    "mutual inductive type `"
      <> asText ai
      <> "` cannot be used to construct a nested inductive type"

lookupInductive ::
  Meta ->
  Ident ->
  WithEnv ([WeakIdentPlus], WeakIdentPlus, [WeakIdentPlus])
lookupInductive m ai = do
  fenv <- gets formationEnv
  case IntMap.lookup (asInt ai) fenv of
    Just (Just (_, WeakTermPiIntro xts (_, WeakTermPi atsbts (_, WeakTermPiElim (_, WeakTermUpsilon _) _)))) -> do
      let at = head atsbts
      let bts = tail atsbts -- valid since a is not mutual
      return (xts, at, bts)
    Just (Just e) ->
      raiseCritical m $
        "malformed inductive type (Parse.lookupInductive): \n" <> toText e
    Just Nothing ->
      raiseError m $
        "the inductive type `" <> asText ai <> "` must be a non-mutual inductive type"
    Nothing ->
      raiseCritical m $ "no such inductive type defined: " <> asText ai

-- nested inductiveにおける引数をinternalizeする。
-- （これ、recursiveに処理できないの？）
toInternalizedArg ::
  Mode ->
  SubstWeakTerm -> -- inductiveのためのaのsubst (outer -> inner)
  Ident -> -- innerでのaの名前。listの定義の中に出てくるほうのlist.
  Ident -> -- outerでのaの名前。listとか。
  [WeakIdentPlus] -> -- aの引数。
  (WeakTermPlus -> WeakTermPlus) -> -- base caseでのinternalizeのための情報。
  [WeakTermPlus] -> -- list @ (e1, ..., en)の引数部分。
  [WeakTermPlus] -> -- eiをisubでsubstしたもの。
  WeakIdentPlus -> -- outerでのコンストラクタ。
  WeakIdentPlus -> -- innerでのコンストラクタ。xts部分の引数だけouterのコンストラクタと型がずれていることに注意。
  WithEnv WeakTermPlus
toInternalizedArg mode isub aInner aOuter xts modifier es es' b bInner =
  case bInner of
    (mbInner, _, (_, WeakTermPi ytsInner _)) -> do
      let (ms, ys, ts) = unzip3 ytsInner
      let vxs = map toVar' xts
      -- 引数の型を適切にsubstする。これによって、aInner (x1, ..., xn)の出現がaOuter (e1', ..., en')へと置き換えられて、
      -- 結果的にaOuterの中身はすべて処理済みとなる。
      -- ytsInnerはPiの内部でのコンストラクタの型であるから、substをするときはaInnerからsubstを行なう必要がある。……本当か？
      -- このsubstを行なうことで結局z @ (aOuter, ARGS)のARGS部分の引数がaOuter関連のもので揃うから正しいはず。
      ts' <- mapM (substRuleType ((aInner, vxs), (aOuter, es'))) ts
      -- aInner (x1, ..., xn) ~> aOuter (e1', ..., en')が終わったら、こんどは型のxiをeiに置き換える。
      -- これによって、
      --   - aOuterの中身はすべて処理済み
      --   - aOuterの外にはeiが出現しうる
      -- という状況が実現できる。これはrecursionの停止を与える。
      let xs = map (\(_, x, _) -> asInt x) xts -- fixme: このへんもrenameBinderでやったほうがいい？
      let sub = IntMap.fromList $ zip xs es
      let ts'' = map (substWeakTermPlus sub) ts'
      ys' <- mapM newNameWith ys
      -- これで引数の型の調整が終わったので、あらためてidentPlusの形に整える
      -- もしかしたらyって名前を別名に変更したほうがいいかもしれないが。
      let ytsInner' = zip3 ms ys' ts''
      -- 引数をコンストラクタに渡せるようにするために再帰的にinternalizeをおこなう。
      -- list (item-outer A)みたいな形だったものは、list (item-inner A)となっているはずなので、thetaは停止する。
      -- list (list (item-outer A))みたいな形だったものも、list (list (item-inner A))となってthetaは停止する。
      let f (m, y, t) = theta mode isub modifier t (m, WeakTermUpsilon y)
      args <- mapM f ytsInner'
      -- あとは結果を返すだけ
      return
        ( mbInner,
          WeakTermPiIntro
            ytsInner'
            (mbInner, WeakTermPiElim (toVar' b) (es' ++ args))
        )
    (m, _, _) ->
      raiseCritical
        m
        "the type of an introduction rule must be represented by a Pi-type, but its not"

renameBinder ::
  [WeakIdentPlus] ->
  WeakTermPlus ->
  WithEnv ([WeakIdentPlus], WeakTermPlus)
renameBinder binder e =
  case binder of
    [] ->
      return ([], e)
    (m, x, t) : ats -> do
      x' <- newNameWith x
      let sub = IntMap.singleton (asInt x) (m, WeakTermUpsilon x')
      let (ats', e') = substWeakTermPlus'' sub ats e -- discern済みなのでこれでオーケーのはず
      (ats'', e'') <- renameBinder ats' e'
      return ((m, x', t) : ats'', e'')

type RuleTypeDom =
  (Ident, [WeakTermPlus])

type RuleTypeCod =
  (Ident, [WeakTermPlus])

type SubstRule =
  (RuleTypeDom, RuleTypeCod)

-- subst a @ (e1, ..., en) ~> a' @ (e1', ..., en')
substRuleType :: SubstRule -> WeakTermPlus -> WithEnv WeakTermPlus
substRuleType sub@((a1, es1), (a2, es2)) term =
  case term of
    (m, WeakTermTau) ->
      return (m, WeakTermTau)
    (m, WeakTermUpsilon x) ->
      return (m, WeakTermUpsilon x)
    (m, WeakTermPi xts t) -> do
      (xts', t') <- substRuleType' sub xts t
      return (m, WeakTermPi xts' t')
    (m, WeakTermPiIntro xts body) -> do
      (xts', body') <- substRuleType' sub xts body
      return (m, WeakTermPiIntro xts' body')
    (m, WeakTermPiElim e es)
      | (mx, WeakTermUpsilon x) <- e,
        a1 == x ->
        case (mapM asUpsilon es1, mapM asUpsilon es) of
          (Just xs', Just ys')
            | xs' == ys' ->
              return (m, WeakTermPiElim (mx, WeakTermUpsilon a2) es2) -- `aOuter @ (処理済み, ..., 処理済み)` への変換
          _ ->
            raiseError
              m
              "generalized inductive type cannot be used to construct a nested inductive type"
      | otherwise -> do
        e' <- substRuleType sub e
        es' <- mapM (substRuleType sub) es
        return (m, WeakTermPiElim e' es')
    (m, WeakTermFix (mx, x, t) xts e) -> do
      t' <- substRuleType sub t
      if fst (fst sub) == x
        then return (m, WeakTermFix (mx, x, t') xts e)
        else do
          (xts', e') <- substRuleType' sub xts e
          return (m, WeakTermFix (mx, x, t') xts' e')
    (m, WeakTermConst x) ->
      return (m, WeakTermConst x)
    (m, WeakTermCall x) ->
      return (m, WeakTermCall x)
    (m, WeakTermHole x) ->
      return (m, WeakTermHole x)
    (m, WeakTermInt t x) -> do
      t' <- substRuleType sub t
      return (m, WeakTermInt t' x)
    (m, WeakTermFloat t x) -> do
      t' <- substRuleType sub t
      return (m, WeakTermFloat t' x)
    (m, WeakTermEnum x) ->
      return (m, WeakTermEnum x)
    (m, WeakTermEnumIntro l) ->
      return (m, WeakTermEnumIntro l)
    (m, WeakTermEnumElim (e, t) branchList) -> do
      t' <- substRuleType sub t
      e' <- substRuleType sub e
      let (caseList, es) = unzip branchList
      es' <- mapM (substRuleType sub) es
      return (m, WeakTermEnumElim (e', t') (zip caseList es'))
    (m, WeakTermArray dom k) -> do
      dom' <- substRuleType sub dom
      return (m, WeakTermArray dom' k)
    (m, WeakTermArrayIntro k es) -> do
      es' <- mapM (substRuleType sub) es
      return (m, WeakTermArrayIntro k es')
    (m, WeakTermArrayElim mk xts v e) -> do
      v' <- substRuleType sub v
      (xts', e') <- substRuleType' sub xts e
      return (m, WeakTermArrayElim mk xts' v' e')
    (m, WeakTermStruct ts) ->
      return (m, WeakTermStruct ts)
    (m, WeakTermStructIntro ets) -> do
      let (es, ts) = unzip ets
      es' <- mapM (substRuleType sub) es
      return (m, WeakTermStructIntro $ zip es' ts)
    (m, WeakTermStructElim xts v e) -> do
      v' <- substRuleType sub v
      let xs = map (\(_, x, _) -> x) xts
      if fst (fst sub) `elem` xs
        then return (m, WeakTermStructElim xts v' e)
        else do
          e' <- substRuleType sub e
          return (m, WeakTermStructElim xts v' e')
    (m, WeakTermQuestion e t) -> do
      e' <- substRuleType sub e
      t' <- substRuleType sub t
      return (m, WeakTermQuestion e' t')
    (m, WeakTermErase xs e) -> do
      e' <- substRuleType sub e
      return (m, WeakTermErase xs e')

substRuleType' ::
  SubstRule ->
  [WeakIdentPlus] ->
  WeakTermPlus ->
  WithEnv ([WeakIdentPlus], WeakTermPlus)
substRuleType' sub binder e =
  case binder of
    [] -> do
      e' <- substRuleType sub e
      return ([], e')
    (m, x, t) : xts -> do
      t' <- substRuleType sub t
      if fst (fst sub) == x
        then return ((m, x, t') : xts, e)
        else do
          (xts', e') <- substRuleType' sub xts e
          return ((m, x, t') : xts', e')
