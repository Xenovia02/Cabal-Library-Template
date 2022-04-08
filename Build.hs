{-# LANGUAGE BangPatterns #-}

module Build where

import Prelude hiding (readFile, lines)

import Control.Monad ((<$!>), when, forM_, mapM_)
import Data.Text (Text)
import qualified Data.Text as T (lines)
import Data.Text.IO (readFile)
import System.Directory
import System.IO ()
import Text.Parsec (parse)

import CmdLine (CmdLine(..))
import CmdLine.Flags
import Analyzer.Analyzer
import Analyzer.Error (prettyError)
import Builder.Builder
import Builder.CmdLine
import Builder.Output
import Parser.Data (Expr, Import(..))
import Parser.Error (prettyParseErr)
import Parser.Parser
import Typing.Checker
import Pretty
import Utils


default (Int, Double)



build :: BuilderIO ()
build = do
    files <- getSourceFiles
    forM_ files $ buildFile
    status "Finished building\n"

-- buildFromMain = do

buildFile :: FilePath -> BuilderIO ()
buildFile path = do
    setFilePath path
    name <- getModule
    isUTD <- isUpToDate name
    if isUTD then return () else do
        setBuildDir (modToPath name)
        message ("Building Module ["*|name|*"]\n")
        dir <- getBuildDir
        doTrace <- cmdTrace <$!> getCmdLine
        when doTrace <#>
            createDirectoryIfMissing True dir
        src <- readFile <#> path
        (imports, src') <- getImports src
        forM_ imports $ \imp ->
            buildFile (modToPath (impModule imp))
        setSource src
        parseRes <- parseFile src'
        analyzeFile parseRes
        addUTDModule name

-- get the list of imports to build
getImports :: Text -> BuilderIO ([Import], Text)
getImports src = do
    name <- getModule
    case parse importsParser name src of
        Left err -> fatal $
            prettyParseErr err src|+
            "\n$rFailed while parsing module\n"
            
        Right (modName, imports, src') -> do
            when (name /= modName) $ fatal $
                "module declaration does not match the \
                \filename\n\
                \    Expected: "+|name|+"\n\
                \    Found   : "+|modName|+"\n$r\
                \Failed while parsing module "+|name|+"\n"
            return (imports, src')

parseFile :: Text -> BuilderIO [Expr]
parseFile src = do
    name <- getModule
    debug ("Parsing   ["+|name|+"]\n")
    case parse roseParser name src of
        Left err -> do
            fatal $ prettyParseErr err src+\
                "Failed while parsing module("+|name|+")"
        Right exprs -> do
            trace "Parse-Tree.txt" $
                concatMap pretty exprs
            return exprs

analyzeFile :: [Expr] -> BuilderIO Analysis
analyzeFile es = do
    name <- getModule
    debug ("Analyzing ["+|name|+"]\n")
    let !res = analyze_ $! mapM_ infer_ es
    trace "Symbol-Table.txt" $
        detailed (arTable res)
    if null $ arErrors res then
        return res
    else do
        lns <- T.lines <$> getSource
        forM_ (arErrors res) $ \em -> do
            message (prettyError lns em)
        flgs <- cmdFlags <$!> getCmdLine
        if f_fatal_errors `isFEnabled` flgs then fatal
            ("Failed while analyzing module ("+|
                name|+")\n")
        else
            return res
