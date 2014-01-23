module Optimization where

import qualified Data.Map as Map
import qualified Data.Set as Set

import Data.List

import Control.Monad
import Control.Monad.Error
import System.Environment

import MTypes
import Analysis

--------------------------------------------------------------------------------------------------------
-- Zipper definitions for the MTree structure (see http://learnyouahaskell.com/zippers) 

data Crumb = LeftCrumb BinOp MTree | RightCrumb BinOp MTree | SingleCrumb UnOp deriving (Show)
type Breadcrumbs = [Crumb]

type MZipper = (MTree, Breadcrumbs)

goLeft :: MZipper -> Maybe MZipper
goLeft (Branch2 op l r, bs) = Just (l, LeftCrumb op r:bs)  
goLeft _ = Nothing

goRight :: MZipper -> Maybe MZipper
goRight (Branch2 op l r, bs) = Just (r, RightCrumb op l:bs)  
goRight _ = Nothing

goDown :: MZipper -> Maybe MZipper
goDown (Branch1 op t, bs) = Just (t, SingleCrumb op : bs)
goDown _ = Nothing

goUp :: MZipper -> Maybe MZipper
goUp (t, LeftCrumb op r : bs) = Just (Branch2 op t r, bs)
goUp (t, RightCrumb op l : bs) = Just (Branch2 op l t, bs)
goUp (t, SingleCrumb op : bs) = Just (Branch1 op t, bs)
goUp _ = Nothing

topMost :: MZipper -> MZipper
topMost (t,[]) = (t,[])  
topMost z = topMost $ maybe z id (goUp z)  

modify :: (MTree -> Maybe MTree) -> MZipper -> MZipper  
modify f (t, bs) = case (f t) of
  Just a -> (a, bs)
  Nothing -> (t, bs)

zipperToTree :: MZipper -> MTree
zipperToTree (n, bs) = n

-----------------------------------------------------------------
-- Main optimizer logic


-- toplevel optimization function: first, call optimizeHelper to
--  get a list of all transformed versions of the current tree
--  (applying all rules at every node until no new trees are
--  produced). Second, calculate FLOPs for each of the transformed
--  trees (note technically the FLOPs calculation can fail, so we get
--  sketchyFLOPsList which is a list of ThrowsError Int, hence the
--  final fmap which deals with this).  Finally, sort the zipped
--  (flops, trees) list to get the tree with the smallest FLOP count,
--  and return that.
optimize :: MTree -> SymbolTable -> ThrowsError (Int, MTree)
optimize tree tbl = let (_, allTreesSet) = optimizeHelper [tree] (Set.singleton tree)
                        allTreesList = Set.toList allTreesSet
                        sketchyFLOPsList = mapM (flip treeFLOPs tbl) allTreesList in
                    fmap (\ flopsList -> head $ sort $ zip flopsList allTreesList) sketchyFLOPsList


-- inputs: a list of still-to-be-transformed expressions, and a set of all expressions that have already been generated by the optimization rules
-- outputs: a new list of candidate expressions, constructed by removing the first element of the previous list, and appending to the end all legal transformations of that element that are not already in the tabu set. also returns a augmented tabu set containing all of the newly generated expressions (the same ones that were added to the list)
type TabuSet = Set.Set MTree
optimizeHelper :: [MTree] -> TabuSet -> ([MTree], TabuSet)
optimizeHelper [] exprSet = ([], exprSet)
optimizeHelper (t:ts) exprSet = let generatedExprs = Set.fromList $ optimizerTraversal (t, [])
                                    novelExprs = Set.difference generatedExprs exprSet in
                                    optimizeHelper ( ts ++ (Set.toList novelExprs) ) (Set.union exprSet novelExprs)
  
-- Given a zipper corresponding to a position (node) in a tree, return
-- the list of all new trees constructable by applying a single
-- optimization rule either at the current node, or (recursively) at
-- any descendant node. Note: the transformed trees we return are
-- rooted at the toplevel, i.e. they have been 'unzipped' by
-- reconstructTree.
optimizerTraversal :: MZipper -> [MTree]
optimizerTraversal (Leaf c, bs) = []
optimizerTraversal z@( n@(Branch2 op l r), bs) = (map (reconstructTree z) (optimizeAtNode n) ) ++  
                                                 (maybe [] id (fmap optimizerTraversal (goLeft z) )) ++
                                                 (maybe [] id (fmap optimizerTraversal (goRight z)))
optimizerTraversal z@( n@(Branch1 op t), bs) = (map (reconstructTree z) (optimizeAtNode n) ) ++
                                               (maybe [] id (fmap optimizerTraversal (goDown z)))

-- Given a tree node, return a list of all transformed nodes that can be generated by applying optimization rules at that node.
optimizeAtNode :: MTree -> [MTree]
optimizeAtNode t = mapMaybeFunc t optimizationRules

-- Take a zipper representing a subtree, and a new subtree to replace that subtree. 
-- return a full (rooted) tree with the new subtree in the appropriate place. 
reconstructTree :: MZipper -> MTree -> MTree
reconstructTree (t1, bs) t2 = zipperToTree $ topMost (t2, bs)

-- Utility function used by optimizeAtNode: map a function f over a
-- list, silently discarding any element for which f returns Nothing.
mapMaybeFunc :: a -> [(a -> Maybe b)] -> [b]
mapMaybeFunc _ []     = []
mapMaybeFunc x (f:fs) = 
  case f x of
    Just y  -> y : mapMaybeFunc x fs
    Nothing -> mapMaybeFunc x fs

------------------------------------------------------------------
-- List of optimizations
--
-- An optimization is a function MTree -> Maybe MTree. The input is
-- assumed to be a subexpression. If the optimization can apply to
-- that subexpression, it returns the transformed
-- subexpression. Otherwise it returns Nothing.
--
-- Note that an optimization does not always need to be helpful:
-- optimizations which increase the number of required FLOPs will be
-- selected against, but are perfectly legal (and sometimes necessary
-- as intermediate steps). 
--
-- The major current restriction on optimizations is that they should
-- generate at most a finite group of results: thus 'right-multiply by
-- the identity' is not currently allowed as an optimization, since it
-- generates AI, AII, AIII, etc. and will thus yield an infinitely
-- large set of transformed expressions. This could be fixed in the
-- future by imposing a maximum search depth.
--
-- To add a new optimization: make sure to include it in the list of
-- optimizationRules. This list is consulted by optimizeNode to
-- generate all possible transformed versions of a subtree.

binopSumRules = [commonFactorLeft, commonFactorRight]
binopProductRules = [assocMult]
optimizationRules = binopSumRules ++ binopProductRules

assocMult :: MTree -> Maybe MTree
assocMult (Branch2 MProduct (Branch2 MProduct l c) r) = Just (Branch2 MProduct l (Branch2 MProduct c r))
assocMult (Branch2 MProduct l (Branch2 MProduct c r)) = Just (Branch2 MProduct (Branch2 MProduct l c) r)
assocMult _ = Nothing

commonFactorRight :: MTree -> Maybe MTree
commonFactorRight (Branch2 MSum (Branch2 MProduct l1 l2) (Branch2 MProduct r1 r2)) = 
  if (l2 == r2) 
     then Just (Branch2 MProduct (Branch2 MSum l1 r1) l2)
     else Nothing
commonFactorRight _ = Nothing

commonFactorLeft :: MTree -> Maybe MTree
commonFactorLeft (Branch2 MSum (Branch2 MProduct l1 l2) (Branch2 MProduct r1 r2)) = 
  if (l1 == r1) 
     then Just (Branch2 MProduct l1 (Branch2 MSum l2 r2))
     else Nothing
commonFactorLeft _ = Nothing

-- cancelInverseCheck :: MZipper -> Boolean
-- cancelInverseCheck (Branch2 MProduct (Branch1 MInverse linv) r, bs) = eq linv r
-- cancelInverseCheck (Branch2 MProduct l (Branch1 MInverse rinv), bs) = eq l rinv
-- cancelInverseCheck _ = False

-- cancelInverse :: MZipper -> MZipper
-- cancelInverse (Branch2 MProduct l r, bs) = Leaf 'I'
-- PROBLEM: how to represent inverse matrices? a symbolic 'I' doesn't have a fixed size in the symbol table. maybe I should define a new MTree constructor Identity n, to represent an identity matrix of size n. this would then need special treatment in the parser and elsewhere (would need to automatically have the 'diagonal', 'symmetric', etc. properties). 
