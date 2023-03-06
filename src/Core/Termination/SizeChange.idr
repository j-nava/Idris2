module Core.Termination.SizeChange

import Core.Context
import Core.Context.Log
import Core.Name

import Core.Termination.References

import Libraries.Data.NameMap
import Libraries.Data.SortedMap
import Libraries.Data.SortedSet

%default covering

------------------------------------------------------------------------
-- Basic types

||| Refer to an argument by its position
-- This seems to assume that a function has a set number of arguments
-- (a constraint we currently enforce: all clauses' LHS need to have
-- the same number of arguments)
Arg : Type
Arg = Nat

||| A change in (g y₀ ⋯ yₙ) with respect to (f x₀ ⋯ xₙ) is
||| for each argument yᵢ in g either:
|||   Nothing        if it's not related to any of the xⱼ
|||   Just (j, rel)  if yᵢ `rel` xⱼ
Change : {- f g -} Type
Change = List (Maybe (Arg, SizeChange))

||| A path in the call graph lists the source location of the successive calls
||| and the name of each of the functions being called
||| TODO: also record the arguments so that we can print e.g.
|||   flip x y -> flop y x -> flip x y
||| instead of the less useful
|||   flip -> flop -> flip
public export
Path : {- f g -} Type
Path = List (FC, Name)

||| An arg change in g with respect to f is given by:
|||   the actual changes in g with respect to f
|||   the path in the call graph leading from f to g
||| The path is only here for error-reporting purposes
record ArgChange {- f g -} where
  constructor MkArgChange
  change : Change {- f g -}
  path : Path {- f g -}

||| Sc graphs to be added
WorkList : Type
WorkList = SortedSet (Name, Name, ArgChange)

||| Transitively-closed (modulo work list) set of sc-graphs
||| Note: oh if only we had dependent name maps!
SCSet : Type
SCSet = NameMap {- \ f => -}
      $ NameMap {- \ g => -}
      $ SortedSet $ ArgChange {- f g -}


------------------------------------------------------------------------
-- Instances

-- ignore path
Eq ArgChange where
  (==) a1 a2 = a1.change == a2.change

Ord ArgChange where
  compare a1 a2 = compare a1.change a2.change

Show ArgChange where
  show a = show a.change ++ " @" ++ show a.path

------------------------------------------------------------------------
-- Utility functions

||| Empty set of sc-graphs
initSCSet : SCSet
initSCSet = empty

lookupMap : Name -> NameMap (NameMap v) -> NameMap v
lookupMap n m = fromMaybe empty (lookup n m)

lookupSet : Ord v => Name -> NameMap (SortedSet v) -> SortedSet v
lookupSet n m = fromMaybe empty (lookup n m)

lookupGraphs : Name -> Name -> SCSet -> SortedSet ArgChange
lookupGraphs f g = lookupSet g . lookupMap f

||| Smart filter: only keep the paths starting from f
selectDom : Name -> SCSet -> SCSet
selectDom f s = insert f (lookupMap f s) empty

||| Smart filter: only keep the paths ending in g
selectCod : Name -> SCSet -> SCSet
selectCod g s = map (\m => insert g (lookupSet g m) empty) s

foldl : (acc -> Name -> Name -> ArgChange -> acc) -> acc -> SCSet -> acc
foldl f_acc acc
    = foldlNames (\acc, f =>
        foldlNames (\acc, g =>
          foldl (\acc, c => f_acc acc f g c) acc)
          acc)
        acc

insertGraph : (f, g : Name) -> ArgChange {- f g -} -> SCSet -> SCSet
insertGraph f g ch s
  = let s_f = lookupMap f s in
    let s_fg = lookupSet g s_f in
    insert f (insert g (insert ch s_fg) s_f) s

------------------------------------------------------------------------
-- Actual size-change computations

||| Diagrammatic composition:
||| Given a (Change f g) and a (Change g h), compute a (Change f h)
composeChange : Change {- f g -} -> Change {- g h -} -> Change {- f h -}
composeChange c1 c2
    -- We have (giving more precise types)
    -- h z₀ ⋯ zₚ, g y₀ ⋯ yₙ, f x₀ ⋯ xₘ
    -- c1 : Vect n (Maybe (Fin m, SizeChange))
    -- c2 : Vect p (Maybe (Fin n, SizeChange))
    -- and we want
    -- Vect p (Maybe (Fin m, SizeChange))
    -- We use the SizeChange monoid: Unknown is a 0, Same is a neutral
    = map (>>= (\(i, r) => map (r <+>) <$> getArg i c1)) c2
  where
    getArg : Nat -> List (Maybe a) -> Maybe a
    getArg i c = join $ getAt i c

||| Diagrammatic composition:
||| Given an (ArgChange f g) and an (ArgChange g h), compute an (ArgChange f h)
composeArgChange : ArgChange {- f g -} -> ArgChange {- g h -} -> ArgChange {- f h -}
composeArgChange a1 a2
    = MkArgChange
        (composeChange a1.change a2.change)
        (a1.path ++ a2.path)

||| Precompose a given Arg change & insert it in the worklist (unless it's already known)
preCompose : (f : Name) -> ArgChange {- f g -} -> -- /!\ g bound later
             SCSet ->
             WorkList ->
             (g : Name) -> (h : Name) -> ArgChange {- g h -} ->
             WorkList
preCompose f ch1 s work _ h ch2
   = let ch : ArgChange {- f h -} = composeArgChange ch1 ch2 in
     if contains ch (lookupGraphs f h s) then
       work
     else
       insert (f, h, ch) work

||| Precompose a given Arg change & insert it in the worklist (unless it's already known)
postCompose : (h : Name) -> ArgChange {- g h -} -> -- /!\ g bound later
              SCSet ->
              WorkList ->
              (f : Name) -> (g : Name) -> ArgChange {- f g -} ->
              WorkList
postCompose h ch2 s work f _ ch1
   = let ch : ArgChange {- f h -} = composeArgChange ch1 ch2 in
     if contains ch (lookupGraphs f h s) then
       work
     else
       insert (f, h, ch) work

mutual
  addGraph : {auto c : Ref Ctxt Defs} ->
             (f, g : Name) -> ArgChange {- f g -} ->
             WorkList ->
             SCSet ->
             SCSet
  addGraph f g ch work s_in
      = let s = insertGraph f g ch s_in
            -- Now that (ch : ArgChange f g) has been added, we need to update
            -- the graph with the paths it has extended i.e.

            -- the ones start in g
            after = selectDom g s
            work_pre = foldl (preCompose f ch s) work after

            -- and the ones ending in f
            before = selectCod f s
            work_post = foldl (postCompose g ch s) work_pre before in

        -- And then we need to close over all of these new paths too
        transitiveClosure work_post s

  transitiveClosure : {auto c : Ref Ctxt Defs} ->
                      WorkList ->
                      SCSet ->
                      SCSet
  transitiveClosure work s
      = case pop work of
             Nothing => s
             Just ((f, g, ch), work) =>
               addGraph f g ch work s

-- find (potential) chain of calls to given function (inclusive)
prefixPath : NameMap (FC, Name) -> (g : Name) -> {- Exists \ f => -} Path {- f g -}
prefixPath pred g = go g []
  where
    go : Name -> Path -> Path
    go g path
        = let Just (l, f) = lookup g pred
             | Nothing => path in
          if f == g then -- we've reached the entry point!
            path
          else
            go f ((l, g) :: path)

||| Finding non-terminating loops
findLoops : {auto c : Ref Ctxt Defs} -> SCSet ->
            Core (NameMap {- $ \ f => -} (Maybe (Path {- f f -} )))
findLoops s
    = do -- Comparing (f x₀ ⋯ xₙ) with (f xᵧ₍₀₎ ⋯ xᵧ₍ₙ₎) for size changes only makes
         -- sense if the position for we can say something are stable under γ.
         -- Hence the following filter:
         let loops = filterEndos (\a => composeChange a.change a.change == a.change) s
         log "totality.termination.calc" 7 $ "Loops: " ++ show loops
         let terms = map (foldMap (\a => checkDesc a.change a.path)) loops
         pure terms
    where
      filterEndos : (ArgChange -> Bool) -> SCSet -> NameMap (List ArgChange)
      filterEndos p = mapWithKey (\f, m => filter p (Data.SortedSet.toList (lookupSet f m)))

      checkDesc : Change -> Path -> Maybe Path
      checkDesc [] p = Just p
      checkDesc (Just (_, Smaller) :: _) p = Nothing
      checkDesc (_ :: xs) p = checkDesc xs p

findNonTerminatingLoop : {auto c : Ref Ctxt Defs} -> SCSet -> Core (Maybe (Name, Path))
findNonTerminatingLoop s
    = do loops <- findLoops s
         pure $ findNonTerminating loops
    where
      findNonTerminating : NameMap (Maybe Path) -> Maybe (Name, Path)
      findNonTerminating = foldlNames (\acc, g, m => map (g,) m <+> acc) empty

||| Steps in a path leading to a loop are also problematic
setPrefixTerminating : {auto c : Ref Ctxt Defs} ->
                       Path -> Name -> Core ()
setPrefixTerminating [] g = pure ()
setPrefixTerminating (_ :: []) g = pure ()
setPrefixTerminating ((l, f) :: p) g
    = do setTerminating l f (NotTerminating (BadPath p g))
         setPrefixTerminating p g

addFunctions : {auto c : Ref Ctxt Defs} ->
              Defs ->
              List GlobalDef -> -- functions we're adding
              NameMap (FC, Name) -> -- functions we've already seen (and their predecessor)
              WorkList ->
              Core (Either Terminating (WorkList, NameMap (FC, Name)))
addFunctions defs [] pred work
    = pure $ Right (work, pred)
addFunctions defs (d1 :: ds) pred work
    = do log "totality.termination.calc" 8 $ "Adding function: " ++ show d1.fullname
         calls <- foldlC resolveCall [] d1.sizeChange
         let Nothing = find isNonTerminating calls
            | Just (d2, l, _) =>
              do let g = d2.fullname
                 log "totality.termination.calc" 7 $ "Non-terminating function call: " ++ show g
                 let init = prefixPath pred d1.fullname ++ [(l, g)]
                 setPrefixTerminating init g
                 pure $ Left (NotTerminating (BadPath init g))
         let (ds, pred, work) = foldl addCall (ds, pred, work) (filter isUnchecked calls)
         addFunctions defs ds pred work
  where
    resolveCall : List (GlobalDef, FC, (Name, Name, ArgChange)) ->
                  SCCall ->
                  Core (List (GlobalDef, FC, (Name, Name, ArgChange)))
    resolveCall calls (MkSCCall g ch l)
        = do Just d2 <- lookupCtxtExact g (gamma defs)
                | Nothing => do log "totality.termination.calc" 7 $ "Not found: " ++ show g
                                pure calls
             pure ((d2, l, (d1.fullname, d2.fullname, MkArgChange ch [(l, d2.fullname)])) :: calls)

    addCall : (List GlobalDef, NameMap (FC, Name), WorkList) ->
                  (GlobalDef, FC, (Name, Name, ArgChange)) ->
                  (List GlobalDef, NameMap (FC, Name), WorkList)
    addCall (ds, pred, work_in) (d2, l, c)
        = let work = insert c work_in in
          case lookup d2.fullname pred of
               Just _ =>
                 (ds, pred, work)
               Nothing =>
                 (d2 :: ds, insert d2.fullname (l, d1.fullname) pred, work)

    isNonTerminating : (GlobalDef, _, _) -> Bool
    isNonTerminating (d2, _, _)
        = case d2.totality.isTerminating of
               NotTerminating _ => True
               _ => False

    isUnchecked : (GlobalDef, _, _) -> Bool
    isUnchecked (d2, _, _)
        = case d2.totality.isTerminating of
               Unchecked => True
               _ => False

initWork : {auto c : Ref Ctxt Defs} ->
           Defs ->
           GlobalDef -> -- entry
           Core (Either Terminating (WorkList, NameMap (FC, Name)))
initWork defs def = addFunctions defs [def] (insert def.fullname (def.location, def.fullname) empty) empty

export
calcTerminating : {auto c : Ref Ctxt Defs} ->
                  FC -> Name -> Core Terminating
calcTerminating loc n
    = do defs <- get Ctxt
         logC "totality.termination.calc" 7 $ do pure $ "Calculating termination: " ++ show !(toFullNames n)
         Just def <- lookupCtxtExact n (gamma defs)
            | Nothing => undefinedName loc n
         IsTerminating <- totRefs defs (nub !(addCases defs (keys (refersTo def))))
            | bad => pure bad
         Right (work, pred) <- initWork defs def
            | Left bad => pure bad
         let s = transitiveClosure work initSCSet
         Nothing <- findNonTerminatingLoop s
           | Just (g, loop) =>
               ifThenElse (def.fullname == g)
                 (pure $ NotTerminating (RecPath loop))
                 (do setTerminating EmptyFC g (NotTerminating (RecPath loop))
                     let init = prefixPath pred g
                     setPrefixTerminating init g
                     pure $ NotTerminating (BadPath init g))
         pure IsTerminating
  where
    addCases' : Defs -> NameMap () -> List Name -> Core (List Name)
    addCases' defs all [] = pure (keys all)
    addCases' defs all (n :: ns)
        = case lookup n all of
             Just _ => addCases' defs all ns
             Nothing =>
               if caseFn !(getFullName n)
                  then case !(lookupCtxtExact n (gamma defs)) of
                            Just def => addCases' defs (insert n () all)
                                                  (keys (refersTo def) ++ ns)
                            Nothing => addCases' defs (insert n () all) ns
                  else addCases' defs (insert n () all) ns

    addCases : Defs -> List Name -> Core (List Name)
    addCases defs ns = addCases' defs empty ns
