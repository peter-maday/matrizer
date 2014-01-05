module Parsing where

import Control.Applicative((<*))
import Text.Parsec
import Text.Parsec.String
import Text.Parsec.Expr
import Text.Parsec.Token
import Text.Parsec.Language
import Control.Monad
import Control.Monad.Error
import qualified Data.Map as Map

linespaces :: Parser()
linespaces = skipMany $ oneOf " \t"

----------------------------------------------------------------------
-- AST Definition
-----------------------------------------------------------------------

data MTree = Leaf Char | Branch1 UnOp MTree | Branch2 BinOp MTree MTree 
data BinOp = MProduct | MSum
data UnOp = MInverse | MTranspose | MNegate 

------------------------------------------------------------------------
-- Pretty printing

showBinOp :: BinOp -> String
showBinOp MProduct = "*"
showBinOp MSum = "+"
instance Show BinOp where show = showBinOp

showUnOp :: UnOp -> String
showUnOp MInverse = "inv"
showUnOp MTranspose = "transpose"
showUnOp MNegate = "neg"
instance Show UnOp where show = showUnOp

showTree :: MTree -> String
showTree (Leaf a) = [a]
showTree (Branch1 op c) = "(" ++ show op ++ " " ++ showTree c ++ ")"
showTree (Branch2 op a b) = "(" ++ show op ++ " " ++ showTree a ++ " " ++ showTree b ++ ")"
instance Show MTree where show = showTree


----------------------------------------------------------------------------------------------
-- Lexer
----------------------------------------------------------------------------------------------

token_def = emptyDef{ commentStart = "\"\"\""
                    , commentEnd = "\"\"\""
                    , commentLine = "#"
                    , identStart = letter
                    , identLetter = oneOf ""
                    , opStart = oneOf "+-*'^" 
                    , opLetter = oneOf "+-*'^1"
                    , reservedOpNames = ["+", "", "-", "*", "^-1", "'"]
                    }
TokenParser{ parens = m_parens
           , identifier = m_identifier
           , reservedOp = m_reservedOp
           , reserved = m_reserved
           , semiSep1 = m_semiSep1
           , whiteSpace = m_whiteSpace } = makeTokenParser token_def


exprparser :: Parser MTree
exprparser = buildExpressionParser table term <?> "expression"
table = [ [Prefix (m_reservedOp "-" >> return (Branch1 MNegate))] -- note: this will parse A-B as A * (-B)
        , [Postfix (m_reservedOp "^-1" >> return (Branch1 MInverse))]
        , [Postfix (m_reservedOp "'" >> return (Branch1 MTranspose))]
        , [Infix (m_reservedOp "*" >> return (Branch2 MProduct)) AssocLeft]
        , [Infix (m_reservedOp "" >> return (Branch2 MProduct)) AssocLeft]
        , [Infix (m_reservedOp "+" >> return (Branch2 MSum)) AssocLeft]
        ]
term = m_parens exprparser
       <|> fmap Leaf letter


---------------------------------------------------------------------------------------------------
-- Error definitions

-- Datatype for errors --
data MError = SizeMismatch BinOp Matrix Matrix 
            | InvalidOp UnOp Matrix
            | UnboundName Char
            | Default String
            | BadDimension String
            | Parser ParseError

showError :: MError -> String
showError (SizeMismatch op m1 m2) = "Invalid matrix dimensions for operation (" ++ showDim m1 ++ ") " ++ show op ++ " (" ++ showDim m2 ++ ")"
showError (InvalidOp op m) = "Invalid operation '" ++ show op ++ "' on matrix " ++ show m 
showError (UnboundName c) = "Undefined matrix name " ++ show c
showError (Default s) = "Default Error???" ++ show s
showError (BadDimension d) = "Invalid dimension specification'" ++ show d ++ "'"
showError (Parser err) = "Parse error at " ++ show err

instance Show MError where show = showError

instance Error MError where
         noMsg = Default "An error has occurred"
         strMsg = Default

type ThrowsError = Either MError

trapError action = catchError action (return . show)

extractValue :: ThrowsError a -> a
extractValue (Right val) = val

---------------------------------------------------------------------------


type SymbolTable = Map.Map Char Matrix
type SizeTable = Map.Map Char Int

------------------------------
-- # Symbol table
-- # Symbol : Size Expression
-- A: n x n
-- B: A x n
-- x: n x 1
-- n ~ 100
-- # Program
-- ABx
--
------------------------------

data MatrixSym = MatrixSym String String [MProperty]
data Matrix = Matrix Int Int [MProperty] 
--------------------------------------------
-- Arjun comment:
-- The parser reads in the symbol table, where each line is a
-- MatrixSym (i.e. "A: n x n" is a MatrixSym Varsize "n" Varsize "n"
-- []). But eventually we want all the Varsizes to be concrete
-- integers, which eventually gets converted to type Matrix. Not sure
-- this is the best way, what about statically checking that the Size
-- constructor is of the "LitSize" type and not the "VarSize" type...?
--------------------------------------------

data MProperty = Symmetric | PosDef | Diagonal deriving Eq

showMProperty :: MProperty -> String
showMProperty Symmetric = "symmetric"
showMProperty PosDef = "posdef"
showMProperty Diagonal = "diag"
instance Show MProperty where show = showMProperty

showMatrix (Matrix rows cols props) = (show rows) ++ "x" ++ (show cols) ++ " " ++ (show props)
instance Show Matrix where show = showMatrix

showDim :: Matrix -> String
showDim (Matrix r c props) =  (show r) ++ "x" ++ (show c)

showMatrixSym (MatrixSym rows cols props) = (show rows) ++ "x" ++ (show cols) ++ " " ++ (show props)
instance Show MatrixSym where show = showMatrixSym

------------------------------------------------------------
-- Actual Parsing Code for the symbol table
------------------------------------------------------------


parseMProp :: Parser MProperty
parseMProp = do propName <- many1 letter
                return $ case propName of
                            "symmetric" -> Symmetric
                            "sym" -> Symmetric
                            "posdef" -> PosDef
                            "pd" -> PosDef
                            "diag" -> Diagonal

parsePropList :: Parser [MProperty]
parsePropList = sepBy parseMProp $ many1 $ oneOf " \t,"

data PreambleLine = MatrixLine Char MatrixSym | SymbolLine Char Int | BlankLine  deriving (Show)
parseMatrix :: Parser PreambleLine
parseMatrix = do linespaces
                 c <- letter
                 linespaces
                 char ':'
                 linespaces
                 sym1 <- ((liftM (:[]) letter) <|> many1 digit)
                 linespaces
                 char 'x'
                 linespaces
                 sym2 <- ((liftM (:[]) letter) <|> many1 digit)
                 linespaces
                 propList <- parsePropList
                 return $ MatrixLine c (MatrixSym sym1 sym2 propList)

parseSymbolDef :: Parser PreambleLine
parseSymbolDef = do linespaces
                    c <- letter
                    linespaces
                    oneOf "=~"
                    linespaces
                    n <- liftM read $ many1 digit
                    return $ SymbolLine c n

parseComment :: Parser String
parseComment = char '#' >> many (noneOf "\n")
                   
parseBlankLine :: Parser PreambleLine
parseBlankLine = do linespaces
                    optional parseComment
                    return BlankLine
                     

parsePreamble :: Parser [PreambleLine]
parsePreamble = endBy ((try parseSymbolDef) <|> (try parseMatrix) <|> parseBlankLine) (char '\n')

parseInput :: Parser ([PreambleLine], MTree)
parseInput = do lines <- parsePreamble
                spaces
                tree <- exprparser
                spaces
                return (lines, tree)

------------------------------------------------------------------

subSymbolDefMatrix :: Map.Map Char Int -> (Char, MatrixSym) -> ThrowsError (Char, Matrix)
subSymbolDefMatrix defs (c, (MatrixSym sym1 sym2 propList)) = do n1 <- subSymbolDef sym1 defs
                                                                 n2 <- subSymbolDef sym2 defs
                                                                 return (c, Matrix n1 n2 propList)

subSymbolDef :: String -> Map.Map Char Int -> ThrowsError Int
subSymbolDef s defs = case reads s of
                           [(n, "")] -> return n
                           [(n, _)] -> throwError $ BadDimension s
                           [] -> maybe (throwError $ UnboundName c) return (Map.lookup c defs)
                      where c = (s !! 0)


subPreamble :: [PreambleLine] -> ThrowsError SymbolTable
subPreamble preamble = let matrices = [(c,n) | (MatrixLine c n)  <- preamble]
                           defs = Map.fromList [(c,n) | (SymbolLine c n) <- preamble]
                           mapped = mapM (subSymbolDefMatrix defs) matrices 
                       in (liftM Map.fromList) mapped

readInput :: String -> ThrowsError (SymbolTable, MTree)
readInput s = do (lines, tree) <- readOrThrow parseInput s
                 table <- subPreamble lines
                 return (table, tree)

-----------------------------------------------------------------

readOrThrow :: Parser a -> String -> ThrowsError a
readOrThrow parser input = case parse parser "matrizer" input of
         Left err -> throwError $ Parser err
         Right val -> return val



play :: String -> IO ()
play inp = case readInput inp of
                { Left err -> print err
                ; Right ans -> print ans
                }

playPreamble :: String -> IO ()
playPreamble inp = case readOrThrow parsePreamble inp of
                { Left err -> print err
                ; Right ans -> print ans
                }

playFile :: String -> IO()
playFile fname = do inp <- readFile fname
                    case readInput inp of
                     Left err -> print err
                     Right ans -> print ans
