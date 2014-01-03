module Main where

import Data.Ratio
import qualified Data.Map as Map
import Control.Monad
import Control.Monad.Error
import Numeric

import Parsing




-------------------------------------------------------------


-------------------------------------------------------------


-- Code generation for numpy arrays

generateNumpy :: MTree -> String
generateNumpy (Leaf a) = [a]
generateNumpy (Branch2 MProduct t1 t2) = "np.dot(" ++ (generateNumpy t1) ++ 
                                          ", " ++ (generateNumpy t2)  ++ ")" 
generateNumpy (Branch2 MSum t1 t2) = (generateNumpy t1) ++ " + " ++ (generateNumpy t2)
generateNumpy (Branch1 MInverse t) = "np.linalg.inv(" ++ (generateNumpy t) ++ ")"
generateNumpy (Branch1 MTranspose t) = (generateNumpy t) ++ ".T" -- caution: might we need parentheses here?
generateNumpy (Branch1 MNegate t) = "-" ++ (generateNumpy t)


------------------------------------------------------------

-- return the size and properties of the matrix generated by a subtree
treeMatrix :: MTree -> SymbolTable -> ThrowsError Matrix
treeMatrix (Leaf a) tbl = maybe (throwError $ UnboundName a) return (Map.lookup a tbl)
treeMatrix (Branch2 MProduct t1 t2) tbl = mergeMatrix prodSizeCheck prodNewSize MProduct t1 t2 tbl
treeMatrix (Branch2 MSum t1 t2) tbl = mergeMatrix sumSizeCheck sumNewSize MSum t1 t2 tbl
treeMatrix (Branch1 MInverse t) tbl = updateMatrix squareCheck sameSize MInverse t tbl
treeMatrix (Branch1 MTranspose t) tbl = updateMatrix trueCheck transSize MTranspose t tbl
treeMatrix (Branch1 MNegate t) tbl = updateMatrix squareCheck sameSize MNegate t tbl

prodSizeCheck r1 c1 r2 c2 = (c1 == r2)
sumSizeCheck r1 c1 r2 c2 = (r1 == r2) && (r2 == c2)

squareCheck r c = (r == c)
trueCheck r c = True

sameSize r c = (r, c)
transSize r c = (c, r)

prodNewSize r1 c1 r2 c2 = (r1, c2)
sumNewSize r1 c1 r2 c2 = (r1, c1)

mergeMatrix sizeCheck newSize op t1 t2 tbl = 
            do m1 <- treeMatrix t1 tbl
               m2 <- treeMatrix t2 tbl
               let (Matrix r1 c1 props1) = m1 
                   (Matrix r2 c2 props2) = m2
               if sizeCheck r1 c1 r2 c2
                  then return $ (uncurry Matrix) (newSize r1 c1 r2 c2) (mergeProps op props1 props2)
                  else throwError $ SizeMismatch op m1 m2

updateMatrix sizeCheck newSize op t tbl = 
             do m <- treeMatrix t tbl
                let (Matrix r c props) = m
                if sizeCheck r c
                   then return $ (uncurry Matrix) (newSize r c) (updateProps op props)
                   else throwError $ InvalidOp op m

mergeClosedProps :: [MProperty] -> [MProperty] -> [MProperty] -> [MProperty]
mergeClosedProps closedProps props1 props2 = filter (\x -> (x `elem` props1) && (x `elem` props2) ) closedProps

mergeProps :: BinOp -> [MProperty] -> [MProperty] -> [MProperty]
mergeProps MProduct props1 props2 = mergeClosedProps [Diagonal] props1 props2
mergeProps MSum props1 props2 = mergeClosedProps [Diagonal, Symmetric, PosDef] props1 props2

updateClosedProps :: [MProperty] -> [MProperty] -> [MProperty]
updateClosedProps closedProps props = filter (\x -> x `elem` props) closedProps

updateProps :: UnOp -> [MProperty] -> [MProperty]
updateProps MInverse props = updateClosedProps [Diagonal, Symmetric, PosDef] props
updateProps MTranspose props = updateClosedProps [Diagonal, Symmetric, PosDef] props
updateProps MNegate props = updateClosedProps [Diagonal, Symmetric] props

----------------------------------------------------------------

-- http://www.ee.ucla.edu/ee236b/lectures/num-lin-alg.pdf
-- http://www.prism.gatech.edu/~gtg031s/files/Floating_Point_Handbook_v13.pdf

treeFLOPs :: MTree -> SymbolTable -> ThrowsError Int
treeFLOPs (Leaf a) tbl = return 0
treeFLOPs (Branch2 MProduct t1 t2) tbl = do (Matrix r1 c1 props1) <- treeMatrix t1 tbl
                                            (Matrix r2 c2 props2) <- treeMatrix t2 tbl
                                            flops1 <- treeFLOPs t1 tbl
                                            flops2 <- treeFLOPs t2 tbl
                                            return $ r1 * c2 * (2*c2 - 1) + flops1 + flops2
treeFLOPs (Branch2 MSum t1 t2) tbl = do (Matrix r1 c1 props1) <- treeMatrix t1 tbl
                                        (Matrix r2 c2 props2) <- treeMatrix t2 tbl
                                        flops1 <- treeFLOPs t1 tbl
                                        flops2 <- treeFLOPs t2 tbl
                                        return $ r1 * c1 + flops1 + flops2
treeFLOPs (Branch1 MInverse t) tbl = do (Matrix r c props) <- treeMatrix t tbl
                                        flops <- treeFLOPs t tbl
                                        return $ (3 * r * r * r) `quot` 4 + flops
treeFLOPs (Branch1 MTranspose t) tbl = treeFLOPs t tbl
treeFLOPs (Branch1 MNegate t) tbl = treeFLOPs t tbl

------------------------------------------------------------

fakeSymbols :: SymbolTable
fakeSymbols = Map.fromList [('A', Matrix 1000 1000 []), ('B', Matrix 1000 1000 []), ('x', Matrix 1000 1 [])]

fakeTree :: MTree
fakeTree = Branch2 MProduct (Branch2 MProduct (Leaf 'A') (Leaf 'B')) (Leaf 'x')

main = putStrLn "hello"