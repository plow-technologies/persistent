{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}
{-# OPTIONS_GHC -fno-warn-unused-imports #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module DataTypeTest (specs) where

import Control.Applicative (liftA2)
import Database.Persist.TH
#ifdef WITH_POSTGRESQL
import Data.Aeson (Value(..))
import Database.Persist.Postgresql.JSON
import qualified Data.HashMap.Strict as HM
#endif
import Data.Char (generalCategory, GeneralCategory(..))
import qualified Data.ByteString as BS
import Data.Fixed (Pico,Micro)
import Data.IntMap (IntMap)
import qualified Data.Text as T
import Data.Time (Day, UTCTime (..), fromGregorian, picosecondsToDiffTime,
                  TimeOfDay (TimeOfDay), timeToTimeOfDay, timeOfDayToTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds, posixSecondsToUTCTime)
import Test.QuickCheck.Arbitrary (Arbitrary, arbitrary)
import Test.QuickCheck.Gen (Gen(..), frequency, listOf, sized, resize)
import Test.QuickCheck.Instances ()
import Test.QuickCheck.Random (newQCGen)

import Init

type Tuple a b = (a, b)

#ifdef WITH_NOSQL
mkPersist persistSettings [persistUpperCase|
#else
-- Test lower case names
share [mkPersist persistSettings, mkMigrate "dataTypeMigrate"] [persistLowerCase|
#endif
DataTypeTable no-json
    text Text
    textMaxLen Text maxlen=100
    bytes ByteString
    bytesTextTuple (Tuple ByteString Text)
    bytesMaxLen ByteString maxlen=100
    int Int
    intList [Int]
    intMap (IntMap Int)
    double Double
    bool Bool
    day Day
#ifndef WITH_NOSQL
    pico Pico
    time TimeOfDay
#endif
    utc UTCTime
#if defined(WITH_MYSQL) && !(defined(OLD_MYSQL))
    -- For MySQL, provide extra tests for time fields with fractional seconds,
    -- since the default (used above) is to have no fractional part.  This
    -- requires the server version to be at least 5.6.4, and should be switched
    -- off for older servers by defining OLD_MYSQL.
    timeFrac TimeOfDay sqltype=TIME(6)
    utcFrac UTCTime sqltype=DATETIME(6)
#endif
#ifdef WITH_POSTGRESQL
    jsonb Value
#endif
|]

cleanDB :: (MonadIO m, PersistQuery backend, backend ~ PersistEntityBackend DataTypeTable) => ReaderT backend m ()
cleanDB = deleteWhere ([] :: [Filter DataTypeTable])

specs :: Spec
specs = describe "data type specs" $
    it "handles all types" $ asIO $ runConn $ do

#ifndef WITH_NOSQL
        _ <- runMigrationSilent dataTypeMigrate
        -- Ensure reading the data from the database works...
        _ <- runMigrationSilent dataTypeMigrate
#endif
        cleanDB
        rvals <- liftIO $ randomValues 1000
        forM_ rvals $ \x -> do
            key <- insert x
            Just y <- get key
            liftIO $ do
                let check :: (Eq a, Show a) => String -> (DataTypeTable -> a) -> IO ()
                    check s f = (s, f x) @=? (s, f y)
                -- Check floating-point near equality
                let check' :: String -> (DataTypeTable -> Pico) -> IO ()
                    check' s f
                        | abs (f x - f y) < 0.000001 = return ()
                        | otherwise = (s, f x) @=? (s, f y)
                -- Check individual fields for better error messages
                check "text" dataTypeTableText
                check "textMaxLen" dataTypeTableTextMaxLen
                check "bytes" dataTypeTableBytes
                check "bytesTextTuple" dataTypeTableBytesTextTuple
                check "bytesMaxLen" dataTypeTableBytesMaxLen
                check "int" dataTypeTableInt
                check "intList" dataTypeTableIntList
                check "intMap" dataTypeTableIntMap
                check "bool" dataTypeTableBool
                check "day" dataTypeTableDay
#ifndef WITH_NOSQL
                check' "pico" dataTypeTablePico
                check "time" (roundTime . dataTypeTableTime)
#endif
#if !(defined(WITH_NOSQL)) || (defined(WITH_NOSQL) && defined(HIGH_PRECISION_DATE))
                check "utc" (roundUTCTime . dataTypeTableUtc)
#endif
#if defined(WITH_MYSQL) && !(defined(OLD_MYSQL))
                check "timeFrac" (dataTypeTableTimeFrac)
                check "utcFrac" (dataTypeTableUtcFrac)
#endif
#ifdef WITH_POSTGRESQL
                check "jsonb" dataTypeTableJsonb
#endif

                -- Do a special check for Double since it may
                -- lose precision when serialized.
                when (getDoubleDiff (dataTypeTableDouble x)(dataTypeTableDouble y) > 1e-14) $
                  check "double" dataTypeTableDouble
    where
      normDouble :: Double -> Double
      normDouble x | abs x > 1 = x / 10 ^ (truncate (logBase 10 (abs x)) :: Integer)
                   | otherwise = x
      getDoubleDiff x y = abs (normDouble x - normDouble y)

roundFn :: RealFrac a => a -> Integer
#ifdef OLD_MYSQL
-- At version 5.6.4, MySQL changed the method used to round values for
-- date/time types - this is the same version which added support for
-- fractional seconds in the storage type.
roundFn = truncate
#else
roundFn = round
#endif

roundTime :: TimeOfDay -> TimeOfDay
#ifdef WITH_MYSQL
roundTime t = timeToTimeOfDay $ fromIntegral $ roundFn $ timeOfDayToTime t
#else
roundTime = id
#endif

roundUTCTime :: UTCTime -> UTCTime
#ifdef WITH_MYSQL
roundUTCTime t =
    posixSecondsToUTCTime $ fromIntegral $ roundFn $ utcTimeToPOSIXSeconds t
#else
roundUTCTime = id
#endif

randomValues :: Int -> IO [DataTypeTable]
randomValues i = do
  gs <- replicateM i newQCGen
  return $ zipWith (unGen arbitrary) gs [0..]

instance Arbitrary DataTypeTable where
  arbitrary = DataTypeTable
     <$> arbText                -- text
     <*> (T.take 100 <$> arbText)          -- textManLen
     <*> arbitrary              -- bytes
     <*> liftA2 (,) arbitrary arbText      -- bytesTextTuple
     <*> (BS.take 100 <$> arbitrary)       -- bytesMaxLen
     <*> arbitrary              -- int
     <*> arbitrary              -- intList
     <*> arbitrary              -- intMap
     <*> arbitrary              -- double
     <*> arbitrary              -- bool
     <*> arbitrary              -- day
#ifndef WITH_NOSQL
     <*> arbitrary              -- pico
     <*> (truncateTimeOfDay =<< arbitrary) -- time
#endif
     <*> (truncateUTCTime   =<< arbitrary) -- utc
#if defined(WITH_MYSQL) && !(defined(OLD_MYSQL))
     <*> (truncateTimeOfDay =<< arbitrary) -- timeFrac
     <*> (truncateUTCTime   =<< arbitrary) -- utcFrac
#endif
#ifdef WITH_POSTGRESQL
     <*> arbitrary              -- value
#endif

#ifdef WITH_POSTGRESQL
instance Arbitrary Value where
  arbitrary = frequency [ (1, pure Null)
                        , (1, Bool <$> arbitrary)
                        , (2, Number <$> arbitrary)
                        , (2, String <$> arbText)
                        , (3, Array <$> limitIt 4 arbitrary)
                        , (3, Object <$> arbObject)
                        ]
    where limitIt i x = sized $ \n -> do
            let m = if n > i then i else n
            resize m x
          arbObject = limitIt 4 -- Recursion can make execution divergent
                    $ fmap HM.fromList -- HashMap -> [(,)]
                    . listOf -- [(,)] -> (,)
                    . liftA2 (,) arbText -- (,) -> Text and Value
                    $ limitIt 4 arbitrary -- Again, precaution against divergent recursion.
#endif


arbText :: Gen Text
arbText =
     T.pack
  .  filter ((`notElem` forbidden) . generalCategory)
  .  filter (<= '\xFFFF') -- only BMP
  .  filter (/= '\0')     -- no nulls
  .  T.unpack
  <$> arbitrary
  where forbidden = [NotAssigned, PrivateUse]

-- truncate less significant digits
truncateToMicro :: Pico -> Pico
truncateToMicro p = let
  p' = fromRational . toRational $ p  :: Micro
  in   fromRational . toRational $ p' :: Pico

truncateTimeOfDay :: TimeOfDay -> Gen TimeOfDay
truncateTimeOfDay (TimeOfDay h m s) =
  return $ TimeOfDay h m $ truncateToMicro s

truncateUTCTime :: UTCTime -> Gen UTCTime
truncateUTCTime (UTCTime d dift) = do
  let pico = fromRational . toRational $ dift :: Pico
      picoi= truncate . (*1000000000000) . toRational $ truncateToMicro pico :: Integer
      -- https://github.com/lpsmith/postgresql-simple/issues/123
      d' = max d $ fromGregorian 1950 1 1
  return $ UTCTime d' $ picosecondsToDiffTime picoi

asIO :: IO a -> IO a
asIO = id
