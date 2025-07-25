{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module EVM.Solidity
  ( solidity
  , solcRuntime
  , solcRuntime'
  , yul
  , yulRuntime
  , JumpType (..)
  , SolcContract (..)
  , Contracts (..)
  , ProjectType (..)
  , BuildOutput (..)
  , StorageItem (..)
  , SourceCache (..)
  , SrcMap (..)
  , CodeType (..)
  , Method (..)
  , SlotType (..)
  , Reference(..)
  , Mutability(..)
  , readBuildOutput
  , readFilteredBuildOutput
  , functionAbi
  , makeSrcMaps
  , readSolc
  , readJSON
  , readStdJSON
  , stripBytecodeMetadata
  , stripBytecodeMetadataSym
  , signature
  , solc
  , Language(..)
  , stdjson
  , parseMethodInput
  , lineSubrange
  , astIdMap
  , astSrcMap
  , containsLinkerHole
  , makeSourceCache
) where

import EVM.ABI
import EVM.Types hiding (Success)

import Optics.Core
import Optics.Operators.Unsafe
import EVM.Effects
import EVM.Expr (maybeLitByteSimp)

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Unlift
import Data.Aeson (encode)
import Data.Aeson.Types
import Data.Aeson.Optics
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Scientific
import Data.ByteString (ByteString, readFile)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as BS16
import Data.ByteString.Lazy (toStrict)
import Data.Char (isDigit)
import Data.Foldable
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.HashMap.Strict qualified as HMap
import Data.List (sort, isPrefixOf, isInfixOf, isSuffixOf, elemIndex, tails, findIndex)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe
import Data.Semigroup
import Data.Sequence (Seq)
import Data.Text (pack, intercalate)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Data.Text.IO (writeFile)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Data.Word (Word8)
import Options.Generic
import Prelude hiding (readFile, writeFile)
import System.FilePattern.Directory
import System.FilePath.Posix
import System.Process
import Text.Read (readMaybe)
import Witch (unsafeInto)
import Data.Either.Extra (maybeToEither)

data StorageItem = StorageItem
  { slotType :: SlotType
  , offset :: Int
  , slot :: Int
  } deriving (Show, Eq)

data SlotType
  -- Note that mapping keys can only be elementary;
  -- that excludes arrays, contracts, and mappings.
  = StorageMapping (NonEmpty AbiType) AbiType
  | StorageValue AbiType
--  | StorageArray AbiType
  deriving Eq

instance Show SlotType where
 show (StorageValue t) = show t
 show (StorageMapping s t) =
   foldr
   (\x y ->
       "mapping("
       <> show x
       <> " => "
       <> y
       <> ")")
   (show t) s

instance Read SlotType where
  readsPrec _ t@('m':'a':'p':'p':'i':'n':'g':'(':s) =
    let (lhs,rhs) = case T.splitOn " => " (pack s) of
          (l:r) -> (l,r)
          _ -> internalError $ "could not parse storage item: " <> t
        first = fromJust $ parseTypeName mempty lhs
        target = fromJust $ parseTypeName mempty (T.replace ")" "" (last rhs))
        rest = fmap (fromJust . (parseTypeName mempty . (T.replace "mapping(" ""))) (take (length rhs - 1) rhs)
    in [(StorageMapping (first NonEmpty.:| rest) target, "")]
  readsPrec _ s = [(StorageValue $ fromMaybe (internalError $ "could not parse storage item: " <> s) (parseTypeName mempty (pack s)),"")]

data SolcContract = SolcContract
  { runtimeCodehash  :: W256
  , creationCodehash :: W256
  , runtimeCode      :: ByteString
  , creationCode     :: ByteString
  , contractName     :: Text
  , constructorInputs :: [(Text, AbiType)]
  , abiMap           :: Map FunctionSelector Method
  , eventMap         :: Map W256 Event
  , errorMap         :: Map W256 SolError
  , immutableReferences :: Map W256 [Reference]
  , storageLayout    :: Maybe (Map Text StorageItem)
  , runtimeSrcmap    :: Seq SrcMap
  , creationSrcmap   :: Seq SrcMap
  } deriving (Show, Eq, Generic)

data Method = Method
  { output :: [(Text, AbiType)]
  , inputs :: [(Text, AbiType)]
  , name :: Text
  , methodSignature :: Text
  , mutability :: Mutability
  } deriving (Show, Eq, Ord, Generic)

data Mutability
  = Pure       -- ^ specified to not read blockchain state
  | View       -- ^ specified to not modify the blockchain state
  | NonPayable -- ^ function does not accept Ether - the default
  | Payable    -- ^ function accepts Ether
 deriving (Show, Eq, Ord, Generic)

-- | A mapping from contract identifiers (filepath:name) to a SolcContract object
newtype Contracts = Contracts (Map Text SolcContract)
  deriving newtype (Show, Eq, Semigroup, Monoid)

-- | A mapping from contract identifiers (filepath:name) to their ast json
newtype Asts = Asts (Map Text Value)
  deriving newtype (Show, Eq, Semigroup, Monoid)

-- | Solidity source files are identified either by their location in the vfs, or by a src map identifier
data SrcFile = SrcFile
  { id :: Int
  , filepath :: FilePath
  }
  deriving (Show, Eq, Ord)

-- | A mapping from source files to (maybe) their contents
newtype Sources = Sources (Map SrcFile (Maybe ByteString))
  deriving newtype (Show, Eq, Semigroup, Monoid)

data BuildOutput = BuildOutput
  { contracts :: Contracts
  , sources   :: SourceCache
  }
  deriving (Show, Eq)

instance Semigroup BuildOutput where
  (BuildOutput a b) <> (BuildOutput c d) = BuildOutput (a <> c) (b <> d)
instance Monoid BuildOutput where
  mempty = BuildOutput mempty mempty

-- | The various project types understood by hevm
data ProjectType = CombinedJSON | Foundry
  deriving (Eq, Show, Read, ParseField)

data SourceCache = SourceCache
  { files  :: Map Int (FilePath, ByteString)
  , lines  :: Map Int (Vector ByteString)
  , asts   :: Map Text Value
  } deriving (Show, Eq, Generic)

data Reference = Reference
  { start :: Int,
    length :: Int
  } deriving (Show, Eq)

instance FromJSON Reference where
  parseJSON (Object v) = Reference
    <$> v .: "start"
    <*> v .: "length"
  parseJSON invalid =
    typeMismatch "Transaction" invalid

instance Semigroup SourceCache where
  SourceCache a b c <> SourceCache d e f = SourceCache (a <> d) (b <> e) (c <> f)

instance Monoid SourceCache where
  mempty = SourceCache mempty mempty mempty

data JumpType = JumpInto | JumpFrom | JumpRegular
  deriving (Show, Eq, Ord, Generic)

data SrcMap = SM {
  offset        :: {-# UNPACK #-} !Int,
  length        :: {-# UNPACK #-} !Int,
  file          :: {-# UNPACK #-} !Int,
  jump          :: JumpType,
  modifierDepth :: {-# UNPACK #-} !Int
} deriving (Show, Eq, Ord, Generic)

data SrcMapParseState
  = F1 String Int
  | F2 Int String Int
  | F3 Int Int String Int
  | F4 Int Int Int (Maybe JumpType)
  | F5 Int Int Int JumpType String
  | Fe
  deriving Show

data CodeType = Creation | Runtime
  deriving (Show, Eq, Ord)

-- Obscure but efficient parser for the Solidity sourcemap format.
makeSrcMaps :: Text -> Maybe (Seq SrcMap)
makeSrcMaps = (\case (_, Fe, _) -> Nothing; x -> Just (done x))
             . T.foldl' (flip go) (mempty, F1 [] 1, SM 0 0 0 JumpRegular 0)
  where
    done (xs, s, p) = let (xs', _, _) = go ';' (xs, s, p) in xs'
    readR = read . reverse

    go :: Char -> (Seq SrcMap, SrcMapParseState, SrcMap) -> (Seq SrcMap, SrcMapParseState, SrcMap)
    go ':' (xs, F1 [] _, p@(SM a _ _ _ _))     = (xs, F2 a [] 1, p)
    go ':' (xs, F1 ds k, p)                    = (xs, F2 (k * (readR ds)) [] 1, p)
    go '-' (xs, F1 [] _, p)                    = (xs, F1 [] (-1), p)
    go d   (xs, F1 ds k, p) | isDigit d        = (xs, F1 (d : ds) k, p)
    go ';' (xs, F1 [] k, p)                    = (xs |> p, F1 [] k, p)
    go ';' (xs, F1 ds k, SM _ b c d e)         = let p' = SM (k * (readR ds)) b c d e in (xs |> p', F1 [] 1, p')

    go '-' (xs, F2 a [] _, p)                  = (xs, F2 a [] (-1), p)
    go d   (xs, F2 a ds k, p) | isDigit d      = (xs, F2 a (d : ds) k, p)
    go ':' (xs, F2 a [] _, p@(SM _ b _ _ _))   = (xs, F3 a b [] 1, p)
    go ':' (xs, F2 a ds k, p)                  = (xs, F3 a (k * (readR ds)) [] 1, p)
    go ';' (xs, F2 a [] _, SM _ b c d e)       = let p' = SM a b c d e in (xs |> p', F1 [] 1, p')
    go ';' (xs, F2 a ds k, SM _ _ c d e)       = let p' = SM a (k * (readR ds)) c d e in
                                                 (xs |> p', F1 [] 1, p')

    go d   (xs, F3 a b ds k, p) | isDigit d    = (xs, F3 a b (d : ds) k, p)
    go '-' (xs, F3 a b [] _, p)                = (xs, F3 a b [] (-1), p)
    go ':' (xs, F3 a b [] _, p@(SM _ _ c _ _)) = (xs, F4 a b c Nothing, p)
    go ':' (xs, F3 a b ds k, p)                = (xs, F4 a b (k * (readR ds)) Nothing, p)
    go ';' (xs, F3 a b [] _, SM _ _ c d e)     = let p' = SM a b c d e in (xs |> p', F1 [] 1, p')
    go ';' (xs, F3 a b ds k, SM _ _ _ d e)     = let p' = SM a b (k * (readR ds)) d e in
                                                 (xs |> p', F1 [] 1, p')

    go 'i' (xs, F4 a b c Nothing, p)           = (xs, F4 a b c (Just JumpInto), p)
    go 'o' (xs, F4 a b c Nothing, p)           = (xs, F4 a b c (Just JumpFrom), p)
    go '-' (xs, F4 a b c Nothing, p)           = (xs, F4 a b c (Just JumpRegular), p)
    go ':' (xs, F4 a b c (Just d),  p)         = (xs, F5 a b c d [], p)
    go ':' (xs, F4 a b c _, p@(SM _ _ _ d _))  = (xs, F5 a b c d [], p)
    go ';' (xs, F4 a b c _, SM _ _ _ d e)      = let p' = SM a b c d e in
                                                 (xs |> p', F1 [] 1, p')

    go d   (xs, F5 a b c j ds, p) | isDigit d  = (xs, F5 a b c j (d : ds), p)
    go ';' (xs, F5 a b c j [], _)              = let p' = SM a b c j (-1) in -- solc <0.6
                                                 (xs |> p', F1 [] 1, p')
    go ';' (xs, F5 a b c j ds, _)              = let p' = SM a b c j (readR ds) in -- solc >=0.6
                                                 (xs |> p', F1 [] 1, p')

    go c (xs, state, p)                        = (xs, internalError ("srcmap: y u " ++ show c ++ " in state" ++ show state ++ "?!?"), p)

-- | Reads all solc output json files found under the provided filepath and returns them merged into a BuildOutput
readBuildOutput :: App m => FilePath -> ProjectType -> m (Err BuildOutput)
readBuildOutput root projectType = readFilteredBuildOutput root (const True) projectType

readFilteredBuildOutput :: App m => FilePath -> (FilePath -> Bool) -> ProjectType -> m (Err BuildOutput)
readFilteredBuildOutput root jsonFilter CombinedJSON = do
  let outDir = root </> "out"
  allJsons <- liftIO $ findJsonFiles outDir
  let jsons = filter jsonFilter allJsons
  case jsons of
    [x] -> readSolc CombinedJSON root (outDir </> x)
    [] -> pure . Left $ "no json files found in: " <> outDir
    _ -> pure . Left $ "multiple json files found in: " <> outDir
readFilteredBuildOutput root jsonFilter _ = do
  let outDir = root </> "out"
  allJsons <- liftIO $ findJsonFiles outDir
  let jsons = filter jsonFilter allJsons
  case (filterMetadata jsons) of
    [] -> pure . Left $ "no json files found in: " <> outDir
    js -> do
      outputs <- sequence <$> mapM (readSolc Foundry root) ((fmap ((</>) (outDir))) js)
      pure . (fmap mconcat) $ outputs

-- | Finds all json files under the provided filepath, searches recursively
-- Filtering out:  * "kompiled" which gets added to `out` by `kontrol`
--                 * "build-info" which gets added by forge
findJsonFiles :: FilePath -> IO [FilePath]
findJsonFiles root =  filter (doesNotContain ["build-info", "kompiled"])
                  <$> getDirectoryFiles root ["**/*.json"]
  where
    doesNotContain :: [String] -> String -> Bool
    doesNotContain forbiddenStrs str = all (\forbidden -> not (isInfixOf forbidden str)) forbiddenStrs

-- | Filters out metadata json files
filterMetadata :: [FilePath] -> [FilePath]
filterMetadata = filter (not . isSuffixOf ".metadata.json")

makeSourceCache :: FilePath -> Sources -> Asts -> IO SourceCache
makeSourceCache root (Sources sources) (Asts asts) = do
  files <- Map.fromList <$> forM (Map.toList sources) (\x@(SrcFile id' fp, _) -> do
      contents <- case x of
        (_,  Just content) -> pure content
        (SrcFile _ _, Nothing) -> BS.readFile (root </> fp)
      pure (id', (fp, contents))
    )
  pure $! SourceCache
    { files = files
    , lines = fmap (Vector.fromList . BS.split 0xa . snd) files
    , asts  = asts
    }

lineSubrange ::
  Vector ByteString -> (Int, Int) -> Int -> Maybe (Int, Int)
lineSubrange xs (s1, n1) i =
  let
    ks = Vector.map (\x -> 1 + BS.length x) xs
    s2  = Vector.sum (Vector.take i ks)
    n2  = ks Vector.! i
  in
    if s1 + n1 < s2 || s1 > s2 + n2
    then Nothing
    else Just (s1 - s2, min (s2 + n2 - s1) n1)

readSolc :: App m => ProjectType -> FilePath -> FilePath -> m (Err BuildOutput)
readSolc pt root fp = do
  -- NOTE: we cannot and must not use Data.Text.IO.readFile because that takes the locale
  --       and may fail with very strange errors when the JSON it's reading
  --       contains any UTF-8 character -- which it will with foundry
  fileContents <- liftIO $ fmap Data.Text.Encoding.decodeUtf8 $ Data.ByteString.readFile fp
  let contractName = T.pack $ takeBaseName fp
  case readJSON pt contractName fileContents of
      Left err -> pure . Left $ "unable to parse " <> show pt <> " project JSON: " <> fp
        <> " Contract: " <> show contractName <> "\nError: " <> err
      Right (contracts, asts, sources) -> do
        conf <- readConfig
        when (conf.debug) $ liftIO $ putStrLn $ "Parsed contract: " <> show contractName <> " file: " <> fp
        sourceCache <- liftIO $ makeSourceCache root sources asts
        pure (Right (BuildOutput contracts sourceCache))

yul :: Text -> Text -> IO (Maybe ByteString)
yul contractName src = do
  json <- solc Yul src False
  let f = (json ^?! key "contracts") ^?! key (Key.fromText "hevm.sol")
      c = f ^?! key (Key.fromText $ if T.null contractName then "object" else contractName)
      bytecode = c ^?! key "evm" ^?! key "bytecode" ^?! key "object" % _String
  pure $ (toCode contractName) <$> (Just bytecode)

yulRuntime :: Text -> Text -> IO (Maybe ByteString)
yulRuntime contractName src = do
  json <- solc Yul src False
  let f = (json ^?! key "contracts") ^?! key (Key.fromText "hevm.sol")
      c = f ^?! key (Key.fromText $ if T.null contractName then "object" else contractName)
      bytecode = c ^?! key "evm" ^?! key "deployedBytecode" ^?! key "object" % _String
  pure $ (toCode contractName) <$> (Just bytecode)

solidity
  :: (MonadUnliftIO m)
  => Text -> Text -> m (Maybe ByteString)
solidity contract src = liftIO $ do
  json <- solc Solidity src False
  let (Contracts sol, _, _) = fromJust $ readStdJSON json
  pure $ Map.lookup ("hevm.sol:" <> contract) sol <&> (.creationCode)

solcRuntime'
  :: App m
  => Text -> Text -> Bool -> m (Maybe ByteString)
solcRuntime' contract src viaIR = do
  conf <- readConfig
  liftIO $ do
    json <- solc Solidity src viaIR
    when conf.dumpExprs $ liftIO $ Data.Text.IO.writeFile "compiled_code.json" json
    case readStdJSON json of
      Just (Contracts sol, _, _) -> pure $ Map.lookup ("hevm.sol:" <> contract) sol <&> (.runtimeCode)
      Nothing -> internalError $ "unable to parse solidity output:\n" <> (T.unpack json)

solcRuntime
  :: App m
  => Text -> Text -> m (Maybe ByteString)
solcRuntime contract src = solcRuntime' contract src False

functionAbi :: Text -> IO Method
functionAbi f = do
  json <- solc Solidity ("contract ABI { function " <> f <> " public {}}") False
  let (Contracts sol, _, _) = fromMaybe
        (internalError . T.unpack $ "while trying to parse function signature `"
          <> f <> "`, unable to parse solc output:\n" <> json)
        (readStdJSON json)
  case Map.toList (fromJust (Map.lookup "hevm.sol:ABI" sol)).abiMap of
    [(_,b)] -> pure b
    _ -> internalError "unexpected abi format"

force :: String -> Maybe a -> a
force s = fromMaybe (internalError s)

readJSON :: ProjectType -> Text -> Text -> Err (Contracts, Asts, Sources)
readJSON CombinedJSON _ json = readCombinedJSON json
readJSON _ contractName json = readFoundryJSON contractName json

-- | Reads a foundry json output
readFoundryJSON :: Text -> Text -> Err (Contracts, Asts, Sources)
readFoundryJSON contractName json = do
  runtime <- maybeToEither "missing 'deployedBytecode' field" $ json ^? key "deployedBytecode"
  runtimeCode <- maybeToEither "missing 'deployedBytecode.object' field" $
    (toCode contractName) . strip0x'' <$> runtime ^? key "object" % _String
  runtimeSrcMap <- case runtime ^? key "sourceMap" % _String of
    Nothing -> Right $ force "Source map creation error" $ makeSrcMaps ""  -- sourceMap is optional
    Just smap -> maybeToEither "invalid sourceMap format" $ makeSrcMaps smap

  creation <- maybeToEither "missing 'bytecode' field" $ json ^? key "bytecode"
  creationCode <- maybeToEither "missing 'bytecode.object' field" $
    (toCode contractName) . strip0x'' <$> creation ^? key "object" % _String
  creationSrcMap <- case creation ^? key "sourceMap" % _String of
    Nothing -> Right $ force "Source map creation error" $ makeSrcMaps ""  -- sourceMap is optional
    Just smap -> maybeToEither "invalid sourceMap format" $ makeSrcMaps smap

  ast <- maybeToEither "missing 'ast' field. Recompile with `forge clean && forge build --ast`" $ json ^? key "ast"
  path <- maybeToEither "missing 'ast.absolutePath' field" $ ast ^? key "absolutePath" % _String
  abi <- maybeToEither "missing or invalid 'abi' array" $ toList <$> json ^? key "abi" % _Array
  id' <- maybeToEither "missing or invalid 'id' field" $ unsafeInto <$> json ^? key "id" % _Integer

  let contract = SolcContract
        { runtimeCodehash     = keccak' (stripBytecodeMetadata runtimeCode)
        , creationCodehash    = keccak' (stripBytecodeMetadata creationCode)
        , runtimeCode         = runtimeCode
        , creationCode        = creationCode
        , contractName        = path <> ":" <> contractName
        , abiMap              = mkAbiMap abi
        , eventMap            = mkEventMap abi
        , errorMap            = mkErrorMap abi
        , runtimeSrcmap       = runtimeSrcMap
        , creationSrcmap      = creationSrcMap
        , constructorInputs   = mkConstructor abi
        , storageLayout       = mkStorageLayout $ json ^? key "storageLayout"
        , immutableReferences = mempty -- TODO: foundry doesn't expose this?
        }
  Right ( Contracts $ Map.singleton (path <> ":" <> contractName) contract
        , Asts      $ Map.singleton path ast
        , Sources   $ Map.singleton (SrcFile id' (T.unpack path)) Nothing
        )

-- | Parses the standard json output from solc
readStdJSON :: Text -> Maybe (Contracts, Asts, Sources)
readStdJSON json = do
  contracts <- KeyMap.toHashMapText <$> json ^? key "contracts" % _Object
  -- TODO: support the general case of "urls" and "content" in the standard json
  sources <- KeyMap.toHashMapText <$>  json ^? key "sources" % _Object
  let asts = force "JSON lacks abstract syntax trees." . preview (key "ast") <$> sources
      contractMap = f contracts
      getId src = unsafeInto $ (force "" $ HMap.lookup src sources) ^?! key "id" % _Integer
      contents src = (SrcFile (getId src) (T.unpack src), encodeUtf8 <$> HMap.lookup src (mconcat $ Map.elems $ snd <$> contractMap))
  pure ( Contracts $ fst <$> contractMap
         , Asts      $ Map.fromList (HMap.toList asts)
         , Sources   $ Map.fromList $ contents <$> (sort $ HMap.keys sources)
         )
  where
    f :: (AsValue s) => HMap.HashMap Text s -> (Map Text (SolcContract, (HMap.HashMap Text Text)))
    f x = Map.fromList . (concatMap g) . HMap.toList $ x
    g (s, x) = h s <$> HMap.toList (KeyMap.toHashMapText (fromMaybe (internalError "Could not parse json object") (preview _Object x)))
    h :: Text -> (Text, Value) -> (Text, (SolcContract, HMap.HashMap Text Text))
    h s (c, x) =
      let
        evmstuff = x ^?! key "evm"
        sc = s <> ":" <> c
        runtime = evmstuff ^?! key "deployedBytecode"
        creation =  evmstuff ^?! key "bytecode"
        theRuntimeCode = (toCode sc) $ fromMaybe "" $ runtime ^? key "object" % _String
        theCreationCode = (toCode sc) $ fromMaybe "" $ creation ^? key "object" % _String
        srcContents :: Maybe (HMap.HashMap Text Text)
        srcContents = do metadata <- x ^? key "metadata" % _String
                         srcs <- KeyMap.toHashMapText <$> metadata ^? key "sources" % _Object
                         pure $ fmap
                           (fromMaybe (internalError "could not parse contents field into a string") . preview (key "content" % _String))
                           (HMap.filter (isJust . preview (key "content")) srcs)
        abis = force ("abi key not found in " <> show x) $
          toList <$> x ^? key "abi" % _Array
      in (sc, (SolcContract {
        runtimeCode      = theRuntimeCode,
        creationCode     = theCreationCode,
        runtimeCodehash  = keccak' (stripBytecodeMetadata theRuntimeCode),
        creationCodehash = keccak' (stripBytecodeMetadata theCreationCode),
        runtimeSrcmap    = force "srcmap-runtime" (makeSrcMaps (runtime ^?! key "sourceMap" % _String)),
        creationSrcmap   = force "srcmap" (makeSrcMaps (creation ^?! key "sourceMap" % _String)),
        contractName = sc,
        constructorInputs = mkConstructor abis,
        abiMap        = mkAbiMap abis,
        eventMap      = mkEventMap abis,
        errorMap      = mkErrorMap abis,
        storageLayout = mkStorageLayout $ x ^? key "storageLayout",
        immutableReferences = fromMaybe mempty $
          do x' <- runtime ^? key "immutableReferences"
             case fromJSON x' of
               Success a -> pure a
               _ -> Nothing
      }, fromMaybe mempty srcContents))

-- deprecate me soon
readCombinedJSON :: Text -> Err (Contracts, Asts, Sources)
readCombinedJSON json = do
  contracts <- maybeToEither "missing or invalid 'contracts' field" $ f . KeyMap.toHashMapText <$> (json ^? key "contracts" % _Object)
  sources <- maybeToEither "missing or invalid 'sourceList' field" $ toList . fmap (preview _String) <$> json ^? key "sourceList" % _Array
  astsPre <- maybeToEither "JSON lacks abstract syntax trees (ast). Recompile with `forge clean && forge build --ast`" $ json ^? key "sources" % _Object
  pure ( Contracts contracts
       , Asts (Map.fromList (HMap.toList (KeyMap.toHashMapText astsPre)))
       , Sources $ Map.fromList $
           (\(path, id') -> (SrcFile id' (T.unpack path), Nothing)) <$>
             zip (catMaybes sources) [0..]
       )
  where
    f x = Map.fromList . HMap.toList $ HMap.mapWithKey g x
    g s x =
      let
        theRuntimeCode = (toCode s) (x ^?! key "bin-runtime" % _String)
        theCreationCode = (toCode s) (x ^?! key "bin" % _String)
        abis = toList $ case (x ^?! key "abi") ^? _Array of
                 Just v -> v                                       -- solc >= 0.8
                 Nothing -> (x ^?! key "abi" % _String) ^?! _Array -- solc <  0.8
      in SolcContract {
        runtimeCode      = theRuntimeCode,
        creationCode     = theCreationCode,
        runtimeCodehash  = keccak' (stripBytecodeMetadata theRuntimeCode),
        creationCodehash = keccak' (stripBytecodeMetadata theCreationCode),
        runtimeSrcmap    = force "internal error: srcmap-runtime" (makeSrcMaps (x ^?! key "srcmap-runtime" % _String)),
        creationSrcmap   = force "internal error: srcmap" (makeSrcMaps (x ^?! key "srcmap" % _String)),
        contractName = s,
        constructorInputs = mkConstructor abis,
        abiMap       = mkAbiMap abis,
        eventMap     = mkEventMap abis,
        errorMap     = mkErrorMap abis,
        storageLayout = mkStorageLayout $ x ^? key "storage-layout",
        immutableReferences = mempty -- TODO: deprecate combined-json
      }

mkAbiMap :: [Value] -> Map FunctionSelector Method
mkAbiMap abis = Map.fromList $
  let
    relevant = filter (\y -> "function" == y ^?! key "type" % _String) abis
    f abi =
      (abiKeccak (encodeUtf8 (signature abi)),
       Method { name = abi ^?! key "name" % _String
              , methodSignature = signature abi
              , inputs = map parseMethodInput
                 (toList (abi ^?! key "inputs" % _Array))
              , output = map parseMethodInput
                 (toList (abi ^?! key "outputs" % _Array))
              , mutability = parseMutability
                 (abi ^?! key "stateMutability" % _String)
              })
  in f <$> relevant

mkEventMap :: [Value] -> Map W256 Event
mkEventMap abis = Map.fromList $
  let
    relevant = filter (\y -> "event" == y ^?! key "type" % _String) abis
    f abi =
     ( keccak' (encodeUtf8 (signature abi))
     , Event
       (abi ^?! key "name" % _String)
       (case abi ^?! key "anonymous" % _Bool of
         True -> Anonymous
         False -> NotAnonymous)
       (map (\y ->
        ( y ^?! key "name" % _String
        , force "type" (parseTypeName' y)
        , if y ^?! key "indexed" % _Bool
          then Indexed
          else NotIndexed
        ))
       (toList $ abi ^?! key "inputs" % _Array))
     )
  in f <$> relevant

mkErrorMap :: [Value] -> Map W256 SolError
mkErrorMap abis = Map.fromList $
  let
    relevant = filter (\y -> "error" == y ^?! key "type" % _String) abis
    f abi =
     ( stripKeccak $ keccak' (encodeUtf8 (signature abi))
     , SolError
       (abi ^?! key "name" % _String)
       (map (force "internal error: type" . parseTypeName')
       (toList $ abi ^?! key "inputs" % _Array))
     )
  in f <$> relevant
  where
    stripKeccak :: W256 -> W256
    stripKeccak = read . take 10 . show

mkConstructor :: [Value] -> [(Text, AbiType)]
mkConstructor abis =
  let
    isConstructor y =
      "constructor" == y ^?! key "type" % _String
  in
    case filter isConstructor abis of
      [abi] -> map parseMethodInput (toList (abi ^?! key "inputs" % _Array))
      [] -> [] -- default constructor has zero inputs
      _  -> internalError "strange: contract has multiple constructors"

mkStorageLayout :: Maybe Value -> Maybe (Map Text StorageItem)
mkStorageLayout Nothing = Nothing
mkStorageLayout (Just json) = do
  items <- json ^? key "storage" % _Array
  types <- json ^? key "types"
  fmap Map.fromList (forM (Vector.toList items) $ \item ->
    do name <- item ^? key "label" % _String
       offset <- item ^? key "offset" % _Number >>= toBoundedInteger
       slot <- item ^? key "slot" % _String
       typ <- Key.fromText <$> item ^? key "type" % _String
       slotType <- types ^?! key typ ^? key "label" % _String
       pure (name, StorageItem (read $ T.unpack slotType) offset (read $ T.unpack slot)))

signature :: AsValue s => s -> Text
signature abi =
  case abi ^?! key "type" of
    "fallback" -> "<fallback>"
    _ ->
      fold [
        fromMaybe "<constructor>" (abi ^? key "name" % _String), "(",
        intercalate ","
          (map (\x -> x ^?! key "type" % _String)
            (toList $ abi ^?! key "inputs" % _Array)),
        ")"
      ]

-- Helper function to convert the fields to the desired type
parseTypeName' :: AsValue s => s -> Maybe AbiType
parseTypeName' x =
  parseTypeName
    (fromMaybe mempty $ x ^? key "components" % _Array % to parseComponents)
    (x ^?! key "type" % _String)
  where parseComponents = fmap $ snd . parseMethodInput

parseMutability :: Text -> Mutability
parseMutability "view" = View
parseMutability "pure" = Pure
parseMutability "nonpayable" = NonPayable
parseMutability "payable" = Payable
parseMutability _ = internalError "unknown function mutability"

-- This actually can also parse a method output! :O
parseMethodInput :: AsValue s => s -> (Text, AbiType)
parseMethodInput x =
  ( x ^?! key "name" % _String
  , force "method type" (parseTypeName' x)
  )

containsLinkerHole :: Text -> Bool
containsLinkerHole = regexMatches "__\\$[a-z0-9]{34}\\$__"

toCode :: Text -> Text -> ByteString
toCode contractName t = case BS16.decodeBase16Untyped (encodeUtf8 t) of
  Right d -> d
  Left e -> if containsLinkerHole t
            then error $ T.unpack ("Error toCode: unlinked libraries detected in bytecode, in " <> contractName)
            else error $ T.unpack ("Error toCode:" <> e <> ", in " <> contractName)

solc :: Language -> Text -> Bool -> IO Text
solc lang src viaIR = T.pack <$> readProcess "solc" ["--standard-json"] (T.unpack $ stdjson lang src viaIR)

data Language = Solidity | Yul
  deriving (Show)

data StandardJSON = StandardJSON Language Text Bool
-- more options later perhaps

instance ToJSON StandardJSON where
  toJSON (StandardJSON lang src viaIR) =
    object [ "language" .= show lang
           , "sources" .= object ["hevm.sol" .= object ["content" .= src]]
           , "settings" .=
             object [ "viaIR" .= viaIR
                    , "outputSelection" .=
                    object ["*" .=
                      object ["*" .= (toJSON
                              ["metadata" :: String,
                               "evm.bytecode",
                               "evm.deployedBytecode",
                               "abi",
                               "storageLayout",
                               "evm.bytecode.sourceMap",
                               "evm.bytecode.linkReferences",
                               "evm.bytecode.generatedSources",
                               "evm.deployedBytecode.sourceMap",
                               "evm.deployedBytecode.linkReferences",
                               "evm.deployedBytecode.generatedSources",
                               "evm.deployedBytecode.immutableReferences"
                              ]),
                              "" .= (toJSON ["ast" :: String])
                             ]
                            ]
                    ]
           ]

stdjson :: Language -> Text -> Bool -> Text
stdjson lang src viaIR = decodeUtf8 $ toStrict $ encode $ StandardJSON lang src viaIR

-- | When doing CREATE and passing constructor arguments, Solidity loads
-- the argument data via the creation bytecode, since there is no "calldata"
-- for CREATE.
--
-- This interferes with our ability to look up the current contract by
-- codehash, so we must somehow strip away this extra suffix. Luckily
-- we can detect the end of the actual bytecode by looking for the
-- "metadata hash". (Not 100% correct, but works in practice.)
--
-- Actually, we strip away the entire BZZR suffix too, because as long
-- as the codehash matches otherwise, we don't care if there is some
-- difference there.
stripBytecodeMetadata :: ByteString -> ByteString
stripBytecodeMetadata bs =
  let stripCandidates = flip BS.breakSubstring bs <$> knownBzzrPrefixes in
    case find ((/= mempty) . snd) stripCandidates of
      Nothing -> bs
      Just (b, _) -> b

stripBytecodeMetadataSym :: [Expr Byte] -> [Expr Byte]
stripBytecodeMetadataSym b =
  let
    concretes :: [Maybe Word8]
    concretes = maybeLitByteSimp <$> b
    bzzrs :: [[Maybe Word8]]
    bzzrs = fmap (Just) . BS.unpack <$> knownBzzrPrefixes
    candidates = (flip Data.List.isInfixOf concretes) <$> bzzrs
  in case elemIndex True candidates of
    Nothing -> b
    Just i -> let ind = fromJust $ infixIndex (bzzrs !! i) concretes
              in take ind b

infixIndex :: (Eq a) => [a] -> [a] -> Maybe Int
infixIndex needle haystack = findIndex (isPrefixOf needle) (tails haystack)

knownBzzrPrefixes :: [ByteString]
knownBzzrPrefixes = [
  -- a1 65 "bzzr0" 0x58 0x20 (solc <= 0.5.8)
  BS.pack [0xa1, 0x65, 98, 122, 122, 114, 48, 0x58, 0x20],
  -- a2 65 "bzzr0" 0x58 0x20 (solc >= 0.5.9)
  BS.pack [0xa2, 0x65, 98, 122, 122, 114, 48, 0x58, 0x20],
  -- a2 65 "bzzr1" 0x58 0x20 (solc >= 0.5.11)
  BS.pack [0xa2, 0x65, 98, 122, 122, 114, 49, 0x58, 0x20],
  -- a2 64 "ipfs" 0x58 0x22 (solc >= 0.6.0)
  BS.pack [0xa2, 0x64, 0x69, 0x70, 0x66, 0x73, 0x58, 0x22]
  ]

-- | Every node in the AST has an ID, and other nodes reference those
-- IDs.  This function recurses through the tree looking for objects
-- with the "id" key and makes a big map from ID to value.
astIdMap :: Foldable f => f Value -> Map Int Value
astIdMap = foldMap f
  where
    f :: Value -> Map Int Value
    f (Array x) = foldMap f x
    f v@(Object x) =
      let t = foldMap f (KeyMap.elems x)
      in case KeyMap.lookup "id" x of
        Nothing         -> t
        Just (Number i) -> t <> Map.singleton (round i) v
        Just _          -> t
    f _ = mempty

astSrcMap :: Map Int Value -> (SrcMap -> Maybe Value)
astSrcMap astIds =
  \(SM i n f _ _)  -> Map.lookup (i, n, f) tmp
  where
    tmp :: Map (Int, Int, Int) Value
    tmp =
       Map.fromList
      . mapMaybe
        (\v -> do
          src <- preview (key "src" % _String) v
          [i, n, f] <- mapM (readMaybe . T.unpack) (T.split (== ':') src)
          pure ((i, n, f), v)
        )
      . Map.elems
      $ astIds

-- needs to be here not Format due to cyclic module deps
strip0x'' :: Text -> Text
strip0x'' s = if "0x" `T.isPrefixOf` s then T.drop 2 s else s
