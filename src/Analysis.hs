module Analysis where

import qualified Data.Map as Map
import Data.List
import Control.Monad.Error

import MTypes

fakeSymbols :: SymbolTable
fakeSymbols = Map.fromList [("A", Matrix 1000 1000 []), ("B", Matrix 1000 1000 []), ("x", Matrix 1000 1 [])]

fakeTree :: Expr
fakeTree = Let "C" (Branch2 MSum (Leaf "A") (Leaf "B") ) True (Branch2 MProduct (Branch2 MProduct (Leaf "A") (Leaf "C") ) (Leaf "x"))

fakeTree2 :: Expr
fakeTree2 = Branch2 MProduct  (Branch1 MTranspose (Branch2 MProduct (Leaf "A") (Leaf "x") )) (Branch2 MProduct (Leaf "A") (Leaf "x") )


----------------------------------------------------------------------

-- return the new symbol table after binding a Let expression
tblBind :: Expr -> SymbolTable -> ThrowsError SymbolTable
tblBind (Let lhs rhs tmp body) tbl = do letMatrix <- treeMatrix rhs tbl
                                        return $ Map.insert lhs letMatrix tbl
tblBind _ tbl = return tbl

-- return the size and properties of the matrix generated by a subtree
treeMatrix :: Expr -> SymbolTable -> ThrowsError Matrix
treeMatrix (Leaf a) tbl = maybe (throwError $ UnboundName a) return (Map.lookup a tbl)
treeMatrix (IdentityLeaf n) tbl = return $ Matrix n n [Symmetric, PosDef, Diagonal, LowerTriangular]
treeMatrix (LiteralScalar x) tbl = return $ Matrix 1 1 [Symmetric, Diagonal, LowerTriangular]
treeMatrix (Branch3 MTernaryProduct t1 t2 t3) tbl = updateMatrixTernaryOp ternProductSizeCheck ternProductNewSize MTernaryProduct t1 t2 t3 tbl
treeMatrix (Branch2 MLinSolve t1 t2) tbl = updateMatrixBinaryOp linsolveSizeCheck truePropCheck linsolveNewSize MLinSolve t1 t2 tbl
treeMatrix (Branch2 MCholSolve t1 t2) tbl = updateMatrixBinaryOp linsolveSizeCheck cholsolvePropCheck linsolveNewSize MCholSolve t1 t2 tbl
treeMatrix (Branch2 MProduct t1 t2) tbl = updateMatrixBinaryOp prodSizeCheck truePropCheck prodNewSize MProduct t1 t2 tbl
treeMatrix (Branch2 MScalarProduct t1 t2) tbl = updateMatrixBinaryOp scalarprodSizeCheck truePropCheck scalarprodNewSize MProduct t1 t2 tbl
treeMatrix (Branch2 MSum t1 t2) tbl = updateMatrixBinaryOp sumSizeCheck truePropCheck sumNewSize MSum t1 t2 tbl
treeMatrix (Branch1 MInverse t) tbl = updateMatrixUnaryOp squareCheck (const True) sameSize MInverse t tbl
treeMatrix (Branch1 MTranspose t) tbl = updateMatrixUnaryOp trueCheck (const True) transSize MTranspose t tbl
treeMatrix (Branch1 MNegate t) tbl = updateMatrixUnaryOp squareCheck (const True) sameSize MNegate t tbl
treeMatrix (Branch1 MChol t) tbl = updateMatrixUnaryOp squareCheck (elem PosDef) sameSize MChol t tbl
treeMatrix n@(Let lhs rhs tmp body) tbl = do newtbl <- tblBind n tbl
                                             treeMatrix body newtbl



-----------------------------------------------------------------------
-- Identity special-case: replace all "I" leafs with IdentityLeafs of 
-- appropriate size
-----------------------------------------------------------------------

idshape2 :: BinOp -> Bool -> Int -> Int -> Int
idshape2 MProduct idOnRight n m = if idOnRight then m else n
idshape2 MSum _ n _ = n -- the n != m case will be caught in a typecheck later
idshape2 MLinSolve idOnRight n m = if idOnRight then n else m
idshape2 MCholSolve idOnRight n m = if idOnRight then n else m



preprocess :: Expr -> SymbolTable -> ThrowsError Expr
preprocess (Leaf "I") _ = throwError $ AnalysisError "could not infer size of identity matrix"
preprocess (Leaf a) _ = return $ Leaf a
preprocess (IdentityLeaf n) _ = return $ IdentityLeaf n
preprocess (LiteralScalar n) _ = return $ LiteralScalar n
preprocess (Branch1 op a) tbl = do newA <- preprocess a tbl
                                   return $ Branch1 op newA
preprocess (Branch2 op a (Leaf "I")) tbl = 
                do newA <- preprocess a tbl
                   (Matrix n m _) <- treeMatrix newA tbl
                   preprocess (Branch2 op newA (IdentityLeaf (idshape2 op True n m))) tbl
preprocess (Branch2 op (Leaf "I") b) tbl = 
                do newB <- preprocess b tbl
                   (Matrix n m _) <- treeMatrix newB tbl
                   preprocess (Branch2 op (IdentityLeaf (idshape2 op False n m)) newB) tbl
preprocess (Branch2 MProduct a b) tbl = do newA <- preprocess a tbl
                                           newB <- preprocess b tbl
                                           (Matrix n1 m1 _) <- treeMatrix newA tbl
                                           (Matrix n2 m2 _) <- treeMatrix newB tbl
                                           if (n1==1 && m1==1) 
                                           then return $ Branch2 MScalarProduct newA newB
                                           else if (n2==1 && m2==1) 
                                                then return $ Branch2 MScalarProduct newB newA
                                           else return $ Branch2 MProduct newA newB
preprocess (Branch2 op a b) tbl = do newA <- preprocess a tbl
                                     newB <- preprocess b tbl
                                     return $ Branch2 op newA newB
preprocess (Branch3 _ _ _ _) _ = throwError $ AnalysisError "encountered a ternop while parsing identity matrices, but the parser should never produce ternops!"
preprocess (Let lhs rhs tmp body) tbl  = do newRHS <- preprocess rhs tbl
                                            letMatrix <- treeMatrix newRHS tbl
                                            let newtbl = Map.insert lhs letMatrix tbl
                                            newBody <- preprocess body newtbl
                                            return $ Let lhs newRHS tmp newBody

-----------------
-- functions to check that matrices have the right properties to accept a given op
-- TODO: Why are so many of these things even here? Why not just have
-- (const $ const True) wherever truePropCheck is being used?
                                             
cholsolvePropCheck props1 props2 = LowerTriangular `elem` props1
truePropCheck props1 props2 = True

---------------------
-- functions to check that matrices are the right size for a given op

ternProductSizeCheck r1 c1 r2 c2 r3 c3 = (prodSizeCheck r1 c1 r2 c2) && (prodSizeCheck r2 c2 r3 c3)
linsolveSizeCheck r1 c1 r2 _ = (r1 == r2) && (r1 == c1)
                  -- for now, let's say we can only apply linsolve to square matrices
prodSizeCheck r1 c1 r2 _ = (c1 == r2)
sumSizeCheck r1 c1 r2 c2 = (r1 == r2) && (c1 == c2)
scalarprodSizeCheck r1 c1 r2 c2 = (r1==1 && c1==1)

squareCheck = (==)
trueCheck = const $ const True

----------------------
-- functions to compute the result size for a given op

sameSize r c = (r, c)
transSize r c = (c, r)

ternProductNewSize r1 c1 r2 c2 r3 c3 = (uncurry (prodNewSize r1 c1)) (prodNewSize r2 c2 r3 c3)
linsolveNewSize _ c1 _ c2 = (c1, c2)
prodNewSize r1 _ _ c2 = (r1, c2)
scalarprodNewSize r1 c1 r2 c2 = (r2, c2)
sumNewSize r1 c1 _ _ = (r1, c1)

--------------------
-- compute new matrix sizes and properties for various operator types

updateMatrixTernaryOp :: (Int -> Int -> Int -> Int -> Int -> Int -> Bool)
                       -> (Int -> Int -> Int -> Int -> Int -> Int -> (Int, Int))
                       -> TernOp
                       -> Expr
                       -> Expr
                       -> Expr
                       -> SymbolTable
                       -> ThrowsError Matrix
updateMatrixTernaryOp sizeCheck newSize op t1 t2 t3 tbl =
            do m1 <- treeMatrix t1 tbl
               m2 <- treeMatrix t2 tbl
               m3 <- treeMatrix t3 tbl
               let (Matrix r1 c1 props1) = m1
                   (Matrix r2 c2 props2) = m2
                   (Matrix r3 c3 props3) = m3
               if sizeCheck r1 c1 r2 c2 r3 c3
                  then return $ (uncurry Matrix) (newSize r1 c1 r2 c2 r3 c3) (updateTernaryProps op props1 props2 props3 t1 t2 t3)
                  else throwError $ SizeMismatchTern op m1 m2 m3

updateMatrixBinaryOp :: (Int -> Int -> Int -> Int -> Bool)
                      -> ([MProperty] -> [MProperty] -> Bool)
                      -> (Int -> Int -> Int -> Int -> (Int, Int))
                      -> BinOp
                      -> Expr
                      -> Expr
                      -> SymbolTable
                      -> ThrowsError Matrix
updateMatrixBinaryOp sizeCheck propCheck newSize op t1 t2 tbl =
            do m1 <- treeMatrix t1 tbl
               m2 <- treeMatrix t2 tbl
               let (Matrix r1 c1 props1) = m1
                   (Matrix r2 c2 props2) = m2
               if sizeCheck r1 c1 r2 c2
                  then if propCheck props1 props2
                       then return $ (uncurry Matrix) (newSize r1 c1 r2 c2) (updateBinaryProps op props1 props2 t1 t2)
                       else throwError $ WrongProperties op props1 props2 t1 t2
                  else throwError $ SizeMismatch op m1 m2 t1 t2


updateMatrixUnaryOp :: (Int -> Int -> Bool)
                     -> ([MProperty] -> Bool)
                     -> (Int -> Int -> (Int, Int))
                     -> UnOp
                     -> Expr
                     -> SymbolTable
                     -> Either MError Matrix
updateMatrixUnaryOp sizeCheck propCheck newSize op t tbl =
             do m <- treeMatrix t tbl
                let (Matrix r c props) = m
                if sizeCheck r c
                then if propCheck props
                     then return $ (uncurry Matrix) (newSize r c) (updateProps op props)
                     else throwError $ WrongProperties1 op props t
                else throwError $ InvalidOp op m

-------------------------------------
-- functions to infer properties of the result of a given op, based on properties / structure / identities of the inputs


updateBinaryClosedProps :: [MProperty] -> [MProperty] -> [MProperty] -> [MProperty]
updateBinaryClosedProps = (intersect .) . intersect

updateBinaryProps :: BinOp -> [MProperty] -> [MProperty] -> Expr -> Expr -> [MProperty]
updateBinaryProps MProduct props1 props2 t1 t2 = nub $ (updateBinaryClosedProps [Diagonal, LowerTriangular] props1 props2) ++
                                                       if (productPosDef t1 t2) then [PosDef] else []
updateBinaryProps MScalarProduct props1 props2 t1 t2 = intersect [Symmetric, Diagonal, LowerTriangular] props2 
updateBinaryProps MSum props1 props2 _ _ = updateBinaryClosedProps [Diagonal, Symmetric, PosDef, LowerTriangular] props1 props2
updateBinaryProps MLinSolve props1 props2 _ _ = updateBinaryClosedProps [] props1 props2
updateBinaryProps MCholSolve props1 props2 _ _ = updateBinaryClosedProps [] props1 props2

-- try to prove positive-definiteness for a standard matrix product
productPosDef :: Expr -> Expr -> Bool
productPosDef (Branch1 MTranspose l) r = (l == r) -- rule: A^TA is always non-negative definite (and is posdef iff A is invertible)
productPosDef l (Branch1 MTranspose r) = (l == r)
productPosDef _ _ = False

updateTernaryProps :: TernOp -> [MProperty] -> [MProperty] -> [MProperty] -> Expr -> Expr -> Expr -> [MProperty]
updateTernaryProps MTernaryProduct props1 props2 props3 t1 t2 t3 =
                   let binaryPropsFirstPair = updateBinaryProps MProduct props1 props2 t1 t2
                       binaryPropsOverall = updateBinaryProps MProduct binaryPropsFirstPair props3 (Branch2 MProduct t1 t2) t3 in
                   nub $ binaryPropsOverall ++
                         if (ternProductPosDef props1 props2 props3 t1 t2 t3) then [PosDef] else []

-- try to prove positive-definiteness for a ternary product. currently recognizes:
-- Q^T M Q  for M posdef
-- Q^-1 M Q for M posdef
-- NMN for N,M posdef
-- FIXME: we're currently a bit loose about the distinction between posdef and non-negative def.
-- TODO: Why are there so many function lying around that don't actually
-- use their argument? Fix this...
ternProductPosDef :: [MProperty] -> [MProperty] -> a -> Expr -> b -> Expr -> Bool
ternProductPosDef _ props2 _ (Branch1 MTranspose l) _ r = (PosDef `elem` props2) && (l==r)
ternProductPosDef _ props2 _ l _ (Branch1 MTranspose r) = (PosDef `elem` props2) && (l==r)
ternProductPosDef _ props2 _ (Branch1 MInverse l) _ r = (PosDef `elem` props2) && (l==r)
ternProductPosDef _ props2 _ l _ (Branch1 MInverse r) = (PosDef `elem` props2) && (l==r)
ternProductPosDef props1 props2 _ l _ r = (PosDef `elem` props1) && (PosDef `elem` props2) && (l==r)

updateProps :: UnOp -> [MProperty] -> [MProperty]
updateProps MInverse props   = intersect [Diagonal, Symmetric, PosDef, LowerTriangular] props
updateProps MTranspose props = intersect [Diagonal, Symmetric, PosDef] props
updateProps MNegate  props  = intersect [Diagonal, Symmetric] props
updateProps MChol props = [LowerTriangular ] ++ (intersect [Diagonal ] props)
----------------------------------------------------------------

----------------------------------------------------------------------------------------------------------
-- Method to compute number of floating-point operators to evaluate a
-- matrix expression. Used by the optimizer.

-- http://www.ee.ucla.edu/ee236b/lectures/num-lin-alg.pdf
-- http://www.prism.gatech.edu/~gtg031s/files/Floating_Point_Handbook_v13.pdf

letcost_CONST = 1 -- charge 1 FLOP for an assignment statement, arbitrarily
transposecost_CONST = 1

treeFLOPs :: Expr -> SymbolTable -> ThrowsError Int
treeFLOPs (Leaf _) _ = return 0
treeFLOPs (IdentityLeaf n) _ = return $ n * n
treeFLOPs (LiteralScalar n) _ = return 0
treeFLOPs (Branch3 MTernaryProduct t1 t2 t3) tbl =
        treeFLOPs (Branch2 MProduct (Branch2 MProduct t1 t2) t3) tbl
treeFLOPs (Branch2 MProduct t1 t2) tbl =
        do (Matrix r1 c1 _) <- treeMatrix t1 tbl
           (Matrix _ c2 _) <- treeMatrix t2 tbl
           flops1 <- treeFLOPs t1 tbl
           flops2 <- treeFLOPs t2 tbl
           return $ r1 * c2 * (2*c1 - 1) + flops1 + flops2
treeFLOPs (Branch2 MScalarProduct t1 t2) tbl =
        do (Matrix r c _) <- treeMatrix t2 tbl
           flops1 <- treeFLOPs t1 tbl
           flops2 <- treeFLOPs t2 tbl
           return $ r*c + flops1 + flops2

-- assume LU decomposition: 2/3n^3 to do the decomposition,
-- plus 2n^2 to solve for each column of the result.
treeFLOPs (Branch2 MLinSolve t1 t2) tbl =
        do (Matrix r1 _ _) <- treeMatrix t1 tbl
           (Matrix _ c2 _) <- treeMatrix t2 tbl
           flops1 <- treeFLOPs t1 tbl
           flops2 <- treeFLOPs t2 tbl
           return $ 2 * ((r1 * r1 * r1) `quot` 3 + (c2 * r1 * r1) ) +
                flops1 + flops2

treeFLOPs (Branch2 MCholSolve t1 t2) tbl =
        do (Matrix r1 _ _) <- treeMatrix t1 tbl
           (Matrix _ c2 _) <- treeMatrix t2 tbl
           flops1 <- treeFLOPs t1 tbl
           flops2 <- treeFLOPs t2 tbl
           return $ (2 * c2 * r1 * r1) + flops1 + flops2
treeFLOPs (Branch2 MSum t1 t2) tbl =
        do (Matrix r1 c1 _) <- treeMatrix t1 tbl
           (Matrix _ _ _) <- treeMatrix t2 tbl
           flops1 <- treeFLOPs t1 tbl
           flops2 <- treeFLOPs t2 tbl
           return $ r1 * c1 + flops1 + flops2
treeFLOPs (Branch1 MInverse t) tbl =
        do (Matrix r _ props) <- treeMatrix t tbl
           flops <- treeFLOPs t tbl
           if LowerTriangular `elem` props
           then return $ (r * r + r) `quot` 2 + flops -- inverse of a triangular matrix by back substitution, http://mathforcollege.com/nm/simulations/nbm/04sle/nbm_sle_sim_inversecomptime.pdf
           else return $ (3 * r * r * r) `quot` 4 + flops
treeFLOPs (Branch1 MTranspose t) tbl = do n <- treeFLOPs t tbl 
                                          return $ n + transposecost_CONST
treeFLOPs (Branch1 MNegate t) tbl = treeFLOPs t tbl
treeFLOPs (Branch1 MChol t) tbl =
        do (Matrix r _ _) <- treeMatrix t tbl
           flops <- treeFLOPs t tbl
           return $ (r * r * r) `quot` 3 + flops
treeFLOPs (Let lhs rhs tmp body) tbl = do letMatrix <- treeMatrix rhs tbl
                                          letFLOPs <- treeFLOPs rhs tbl
                                          let newtbl = Map.insert lhs letMatrix tbl
                                          bodyFLOPs <- (treeFLOPs body newtbl)
                                          return $ letFLOPs + bodyFLOPs + letcost_CONST

