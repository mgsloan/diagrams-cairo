{-# LANGUAGE DeriveDataTypeable, CPP #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Diagrams.Backend.Cairo.CmdLine
-- Copyright   :  (c) 2011 Diagrams-cairo team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  diagrams-discuss@googlegroups.com
--
-- Convenient creation of command-line-driven executables for
-- rendering diagrams using the cairo backend.
--
-----------------------------------------------------------------------------

module Diagrams.Backend.Cairo.CmdLine
       ( defaultMain
       , multiMain
       , animMain

       , Cairo
       ) where

import Data.List (intercalate)
import Diagrams.Prelude hiding (width, height, interval)
import Diagrams.Backend.Cairo

-- Below hack is needed because GHC 7.0.x has a bug regarding export
-- of data family constructors; see comments in Diagrams.Backend.Cairo
#if __GLASGOW_HASKELL__ < 702 || __GLASGOW_HASKELL__ >= 704
import Diagrams.Backend.Cairo.Internal
#endif

import System.Console.CmdArgs.Implicit hiding (args)

import Prelude hiding      (catch)

import Data.Maybe          (fromMaybe)
import Control.Monad       (when, forM_, mplus)
import Data.List.Split

import Text.Printf

import System.Environment  (getArgs, getProgName)
import System.Directory    (getModificationTime)
import System.FilePath     (addExtension, splitExtension)
import System.Process      (runProcess, waitForProcess)
import System.IO           (openFile, hClose, IOMode(..),
                            hSetBuffering, BufferMode(..), stdout)
import System.Exit         (ExitCode(..))
#if __GLASGOW_HASKELL__ < 706
import System.Time         (ClockTime, getClockTime)
#else
import Data.Time.Clock     (UTCTime, getCurrentTime)
#endif
import Control.Concurrent  (threadDelay)
import Control.Exception   (catch, SomeException(..), bracket)

#ifdef CMDLINELOOP
import System.Posix.Process (executeFile)
#endif

data DiagramOpts = DiagramOpts
                   { width     :: Maybe Int
                   , height    :: Maybe Int
                   , output    :: FilePath
                   , list      :: Bool
                   , selection :: Maybe String
                   , fpu       :: Double
#ifdef CMDLINELOOP
                   , loop      :: Bool
                   , src       :: Maybe String
                   , interval  :: Int
#endif
                   }
  deriving (Show, Data, Typeable)

diagramOpts :: String -> Bool -> DiagramOpts
diagramOpts prog sel = DiagramOpts
  { width =  def
             &= typ "INT"
             &= help "Desired width of the output image"

  , height = def
             &= typ "INT"
             &= help "Desired height of the output image"

  , output = def
           &= typFile
           &= help "Output file"

  , selection = def
              &= help "Name of the diagram to render"
              &= (if sel then typ "NAME" else ignore)

  , list = def
         &= (if sel then help "List all available diagrams" else ignore)

  , fpu = 30
          &= typ "FLOAT"
          &= help "Frames per unit time (for animations)"
#ifdef CMDLINELOOP
  , loop = False
            &= help "Run in a self-recompiling loop"
  , src  = def
            &= typFile
            &= help "Source file to watch"
  , interval = 1 &= typ "SECONDS"
                 &= help "When running in a loop, check for changes every n seconds."
#endif
  }
  &= summary "Command-line diagram generation."
  &= program prog

-- | This is the simplest way to render diagrams, and is intended to
--   be used like so:
--
-- > ... definitions ...
-- >
-- > main = defaultMain myDiagram
--
--   Compiling this file will result in an executable which takes
--   various command-line options for setting the size, output file,
--   and so on, and renders @myDiagram@ with the specified options.
--
--   On Unix systems, the generated executable also supports a
--   rudimentary \"looped\" mode, which watches the source file for
--   changes and recompiles itself on the fly.
--
--   Pass @--help@ to the generated executable to see all available
--   options.

defaultMain :: Diagram Cairo R2 -> IO ()
defaultMain d = do
  prog <- getProgName
  args <- getArgs
  opts <- cmdArgs (diagramOpts prog False)
  chooseRender opts d
#ifdef CMDLINELOOP
  when (loop opts) (waitForChange Nothing opts prog args)
#endif

chooseRender :: DiagramOpts -> Diagram Cairo R2 -> IO ()
chooseRender opts d =
  case splitOn "." (output opts) of
    [""] -> putStrLn "No output file given."
    ps | last ps `elem` ["png", "ps", "pdf", "svg"] -> do
           let outTy = case last ps of
                 "png" -> PNG
                 "ps"  -> PS
                 "pdf" -> PDF
                 "svg" -> SVG
                 _     -> PDF
           fst $ renderDia
                   Cairo
                   ( CairoOptions
                     (output opts)
                     (mkSizeSpec
                       (fromIntegral <$> width opts)
                       (fromIntegral <$> height opts)
                     )
                     outTy
                   )
                   d
       | otherwise -> putStrLn $ "Unknown file type: " ++ last ps

-- | @multiMain@ is like 'defaultMain', except instead of a single
--   diagram it takes a list of diagrams paired with names as input.
--   The generated executable then takes an argument specifying the
--   name of the diagram that should be rendered.  This is a
--   convenient way to create an executable that can render many
--   different diagrams without modifying the source code in between
--   each one.
multiMain :: [(String, Diagram Cairo R2)] -> IO ()
multiMain ds = do
  prog <- getProgName
  opts <- cmdArgs (diagramOpts prog True)
  if list opts
    then showDiaList (map fst ds)
    else
      case selection opts of
        Nothing  -> putStrLn "No diagram selected." >> showDiaList (map fst ds)
        Just sel -> case lookup sel ds of
          Nothing -> putStrLn $ "Unknown diagram: " ++ sel
          Just d  -> chooseRender opts d

-- | Display the list of diagrams available for rendering.
showDiaList :: [String] -> IO ()
showDiaList ds = do
  putStrLn "Available diagrams:"
  putStrLn $ "  " ++ intercalate " " ds

-- | @animMain@ takes an animation and produces a command-line program
--   which will crudely \"render\" the animation by rendering one image
--   for each frame, named by extending the given output file name by
--   consecutive integers.  For example if the given output file name
--   is @foo\/blah.png@, the frames will be saved in @foo\/blah001.png@,
--   @foo\/blah002.png@, and so on (the number of padding digits used
--   depends on the total number of frames).  It is up to the user to
--   take these images and stitch them together into an actual
--   animation format (using, /e.g./ @ffmpeg@).
--
--   Of course, this is a rather crude method of rendering animations;
--   more sophisticated methods will likely be added in the future.
animMain :: Animation Cairo R2 -> IO ()
animMain anim = do
  prog <- getProgName
  opts <- cmdArgs (diagramOpts prog False)
  let frames  = simulate (toRational $ fpu opts) anim
      nDigits = length . show . length $ frames
  forM_ (zip [1..] frames) $ \(i,d) ->
    chooseRender (indexize nDigits i opts) d

-- | @indexize d n@ adds the integer index @n@ to the end of the
--   output file name, padding with zeros if necessary so that it uses
--   at least @d@ digits.
indexize :: Int -> Integer -> DiagramOpts -> DiagramOpts
indexize nDigits i opts = opts { output = output' }
  where fmt         = "%0" ++ show nDigits ++ "d"
        output'     = addExtension (base ++ printf fmt (i::Integer)) ext
        (base, ext) = splitExtension (output opts)

#ifdef CMDLINELOOP
#if __GLASGOW_HASKELL__ < 706
waitForChange :: Maybe ClockTime -> DiagramOpts -> String -> [String] -> IO ()
#else
waitForChange :: Maybe UTCTime -> DiagramOpts -> String -> [String] -> IO ()
#endif
waitForChange lastAttempt opts prog args = do
    hSetBuffering stdout NoBuffering
    go lastAttempt
  where go lastAtt = do
          threadDelay (1000000 * interval opts)
          -- putStrLn $ "Checking... (last attempt = " ++ show lastAttempt ++ ")"
          (newBin, newAttempt) <- recompile lastAtt prog (src opts)
          if newBin
            then executeFile prog False args Nothing
            else go $ newAttempt `mplus` lastAtt

-- | @recompile t prog@ attempts to recompile @prog@, assuming the
--   last attempt was made at time @t@.  If @t@ is @Nothing@ assume
--   the last attempt time is the same as the modification time of the
--   binary.  If the source file modification time is later than the
--   last attempt time, then attempt to recompile, and return the time
--   of this attempt.  Otherwise (if nothing has changed since the
--   last attempt), return @Nothing@.  Also return a Bool saying
--   whether a successful recompilation happened.
#if __GLASGOW_HASKELL__ < 706
recompile :: Maybe ClockTime -> String -> Maybe String -> IO (Bool, Maybe ClockTime)
#else
recompile :: Maybe UTCTime -> String -> Maybe String -> IO (Bool, Maybe UTCTime)
#endif
recompile lastAttempt prog mSrc = do
  let errFile = prog ++ ".errors"
      srcFile = fromMaybe (prog ++ ".hs") mSrc
  binT <- maybe (getModTime prog) (return . Just) lastAttempt
  srcT <- getModTime srcFile
  if (srcT > binT)
    then do
      putStr "Recompiling..."
      status <- bracket (openFile errFile WriteMode) hClose $ \h ->
        waitForProcess =<< runProcess "ghc" ["--make", srcFile]
                           Nothing Nothing Nothing Nothing (Just h)

      if (status /= ExitSuccess)
        then putStrLn "" >> putStrLn (replicate 75 '-') >> readFile errFile >>= putStr
        else putStrLn "done."

#if __GLASGOW_HASKELL__ < 706
      curTime <- getClockTime
#else
      curTime <- getCurrentTime
#endif
      return (status == ExitSuccess, Just curTime)

    else return (False, Nothing)

 where getModTime f = catch (Just <$> getModificationTime f)
                            (\(SomeException _) -> return Nothing)
#endif