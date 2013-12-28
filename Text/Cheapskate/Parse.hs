{-# LANGUAGE OverloadedStrings #-}
module Text.Cheapskate.Parse (
         parseMarkdown
       , processLines {- TODO for now -}
       ) where
import Text.ParserCombinators
import Text.Cheapskate.Util
import Text.Cheapskate.ContainerStack
import Text.Cheapskate.Inlines
import Text.Cheapskate.Types
import Data.Char hiding (Space)
import qualified Data.Set as Set
import Prelude hiding (takeWhile)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Monoid
import Data.Foldable (toList)
import Data.Sequence ((|>), viewr, ViewR(..), singleton)
import Control.Monad.RWS
import Control.Applicative

-- import Debug.Trace
-- tr' s x = trace (s ++ ": " ++ show x) x

parseMarkdown :: Text -> Blocks
parseMarkdown = processDocument . processLines

processDocument :: (Container, ReferenceMap) -> Blocks
processDocument (Container ct cs, refmap) =
  case ct of
    Document -> processElts refmap (toList cs)
    _        -> error "top level container is not Document"


-- Recursively generate blocks.
-- This requires grouping text lines into paragraphs
-- and list items into lists, handling blank lines,
-- parsing inline contents of texts and resolving referencess.
processElts :: ReferenceMap -> [Elt] -> Blocks
processElts _ [] = mempty
processElts refmap (L _lineNumber lf : rest) =
  case lf of
    TextLine t -> singleton (Para $ parseInlines refmap txt) <>
                  processElts refmap rest'
               where txt = T.stripEnd $ joinLines $ map T.stripStart
                           $ t : map extractText textlines
                     (textlines, rest') = span isTextLine rest
                     isTextLine (L _ (TextLine _)) = True
                     isTextLine _ = False
    BlankLine{} -> processElts refmap rest
    ATXHeader lvl t -> singleton (Header lvl $ parseInlines refmap t) <>
                       processElts refmap rest
    SetextHeader lvl t -> singleton (Header lvl $ parseInlines refmap t) <>
                          processElts refmap rest
    Rule -> singleton HRule <> processElts refmap rest
processElts refmap (C (Container ct cs) : rest) =
  case ct of
    Document -> error "Document container found inside Document"
    BlockQuote -> singleton (Blockquote $ processElts refmap (toList cs)) <>
                  processElts refmap rest
    ListItem { listType = listType' } ->
        singleton (List isTight listType' items') <> processElts refmap rest'
              where xs = takeListItems rest
                    rest' = drop (length xs) rest
                    takeListItems (C c@(Container ListItem { listType = lt' } _)
                       : zs)
                      | listTypesMatch lt' listType' = C c : takeListItems zs
                    takeListItems (lf@(L _ (BlankLine _)) :
                             c@(C (Container ListItem { listType = lt' } _)) :
                             zs)
                      | listTypesMatch lt' listType' = lf : c : takeListItems zs
                    takeListItems _ = []
                    listTypesMatch (Bullet c1) (Bullet c2) = c1 == c2
                    listTypesMatch (Numbered w1 _) (Numbered w2 _) = w1 == w2
                    listTypesMatch _ _ = False
                    items = mapMaybe getItem (Container ct cs : [c | C c <- xs])
                    getItem (Container ListItem{} cs') = Just $ toList cs'
                    getItem _                         = Nothing
                    items' = map (processElts refmap) items
                    isTight = not (any isBlankLine xs) &&
                              all tightListItem items
    FencedCode _ _ info' -> singleton (CodeBlock attr txt) <>
                               processElts refmap rest
                  where txt = joinLines $ map extractText $ toList cs
                        attr = case T.words info' of
                                  []    -> CodeAttr Nothing
                                  (w:_) -> CodeAttr (Just w)
    IndentedCode -> singleton (CodeBlock (CodeAttr Nothing) txt)
                    <> processElts refmap rest'
                  where txt = joinLines $ stripTrailingEmpties
                              $ concatMap extractCode cbs
                        stripTrailingEmpties = reverse .
                          dropWhile (T.all (==' ')) . reverse
                        -- explanation for next line:  when we parsed
                        -- the blank line, we dropped nonindent spaces.
                        -- but for this, code block context, we want
                        -- to have dropped indent spaces. we simply drop
                        -- one more:
                        extractCode (L _ (BlankLine t)) = [T.drop 1 t]
                        extractCode (C (Container IndentedCode cs')) =
                          map extractText $ toList cs'
                        extractCode _ = []
                        (cbs, rest') = span isIndentedCodeOrBlank
                                       (C (Container ct cs) : rest)
                        isIndentedCodeOrBlank (L _ BlankLine{}) = True
                        isIndentedCodeOrBlank (C (Container IndentedCode _))
                                                              = True
                        isIndentedCodeOrBlank _               = False

    RawHtmlBlock -> singleton (HtmlBlock txt) <> processElts refmap rest
                  where txt = joinLines (map extractText (toList cs))
    Reference{} -> processElts refmap rest

   where isBlankLine (L _ BlankLine{}) = True
         isBlankLine _ = False
         tightListItem [] = True
         tightListItem xs = not $ any isBlankLine xs


processLines :: Text -> (Container, ReferenceMap)
processLines t = (doc, refmap)
  where
  (doc, refmap) = evalRWS (mapM_ processLine lns >> closeStack) () startState
  lns        = zip [1..] (map tabFilter $ T.lines t)
  startState = ContainerStack (Container Document mempty) []

tryScanners :: [Container] -> Text -> (Text, Int)
tryScanners cs t = case parse (scanners $ map scanner cs) t of
                        Right (t', n)  -> (t', n)
                        Left e         -> error $ "error parsing scanners: " ++
                                           show e
  where scanners [] = (,) <$> takeText <*> pure 0
        scanners (p:ps) = (p *> scanners ps)
                      <|> ((,) <$> takeText <*> pure (length (p:ps)))
        scanner c = case containerType c of
                       BlockQuote     -> scanBlockquoteStart
                       IndentedCode   -> scanIndentSpace
                       FencedCode{startColumn = col} ->
                                         scanSpacesToColumn col
                       RawHtmlBlock   -> nfb scanBlankline
                       li@ListItem{}  -> scanBlankline
                                         <|>
                                         (do scanSpacesToColumn
                                                (markerColumn li + 1)
                                             upToCountChars (padding li - 1)
                                                (==' ')
                                             return ())
                       Reference{}    -> nfb scanBlankline >>
                                         nfb scanReference
                       _              -> return ()

containerize :: Bool -> Int -> Text -> ([ContainerType], Leaf)
containerize lastLineIsText offset t =
  case parse newContainers t of
       Right (cs,t') -> (cs, t')
       Left err      -> error (show err)
  where newContainers = do
          getPosition >>= \pos -> setPosition pos{ column = offset + 1 }
          regContainers <- many (containerStart lastLineIsText)
          verbatimContainers <- option []
                            $ count 1 (verbatimContainerStart lastLineIsText)
          if null verbatimContainers
             then (,) <$> pure regContainers <*> leaf lastLineIsText
             else (,) <$> pure (regContainers ++ verbatimContainers) <*>
                            textLineOrBlank
textLineOrBlank :: Parser Leaf
textLineOrBlank = consolidate <$> takeText
  where consolidate ts = if T.all (==' ') ts
                            then BlankLine ts
                            else TextLine ts

containerStart :: Bool -> Parser ContainerType
containerStart _lastLineIsText =
      (BlockQuote <$ scanBlockquoteStart)
  <|> parseListMarker

verbatimContainerStart :: Bool -> Parser ContainerType
verbatimContainerStart lastLineIsText = nfb scanBlankline *>
   (  parseCodeFence
  <|> (guard (not lastLineIsText) *> (IndentedCode <$ scanIndentSpace))
  <|> (guard (not lastLineIsText) *> (RawHtmlBlock <$ parseHtmlBlockStart))
  <|> (guard (not lastLineIsText) *> (Reference <$ scanReference))
   )

leaf :: Bool -> Parser Leaf
leaf lastLineIsText = scanNonindentSpace *> (
     (ATXHeader <$> parseAtxHeaderStart <*>
         (T.strip . removeATXSuffix <$> takeText))
   <|> (guard lastLineIsText *> (SetextHeader <$> parseSetextHeaderLine <*> pure mempty))
   <|> (Rule <$ scanHRuleLine)
   <|> textLineOrBlank
  )
  where removeATXSuffix t = case T.dropWhileEnd (`elem` " #") t of
                                 t' | T.null t' -> t'
                                      -- an escaped \#
                                    | T.last t' == '\\' -> t' <> "#"
                                    | otherwise -> t'


processLine :: (LineNumber, Text) -> ContainerM ()
processLine (lineNumber, txt) = do
  ContainerStack top@(Container ct cs) rest <- get
  let (t', numUnmatched) = tryScanners (reverse $ top:rest) txt
  let lastLineIsText = numUnmatched == 0 &&
                       case viewr cs of
                            (_ :> L _ (TextLine _)) -> True
                            _                       -> False
  case ct of
    RawHtmlBlock{} | numUnmatched == 0 -> addLeaf lineNumber (TextLine t')
    IndentedCode   | numUnmatched == 0 -> addLeaf lineNumber (TextLine t')
    FencedCode{ fence = fence' } ->
    -- here we don't check numUnmatched because we allow laziness
      if fence' `T.isPrefixOf` t'
         -- closing code fence
         then closeContainer
         else addLeaf lineNumber (TextLine t')
    _ -> case containerize lastLineIsText (T.length txt - T.length t') t' of
       ([], TextLine t) ->
         case viewr cs of
            -- lazy continuation?
            (_ :> L _ (TextLine _))
              | ct /= IndentedCode -> addLeaf lineNumber (TextLine t)
            _ -> replicateM numUnmatched closeContainer >> addLeaf lineNumber (TextLine t)
       ([], SetextHeader lev _) | numUnmatched == 0 ->
           case viewr cs of
             (cs' :> L _ (TextLine t)) -> -- replace last text line with setext header
               put $ ContainerStack (Container ct (cs' |> L lineNumber (SetextHeader lev t))) rest
               -- Note: the following case should not occur, since
               -- we don't add a SetextHeader leaf unless lastLineIsText.
             _ -> error "setext header line without preceding text line"
       (ns, lf) -> do -- close unmatched containers, add new ones
           replicateM numUnmatched closeContainer
           mapM_ addContainer ns
           case (reverse ns, lf) of
             -- don't add blank line at beginning of fenced code or html block
             (FencedCode{}:_,  BlankLine{}) -> return ()
             _ -> addLeaf lineNumber lf

-- Scanners.

scanReference :: Scanner
scanReference =
  () <$ lookAhead (scanNonindentSpace >> pLinkLabel >> scanChar ':')

-- Scan the beginning of a blockquote:  up to three
-- spaces indent, the `>` character, and an optional space.
scanBlockquoteStart :: Scanner
scanBlockquoteStart =
  scanNonindentSpace >> scanChar '>' >> option () (scanChar ' ')

-- Parse the sequence of `#` characters that begins an ATX
-- header, and return the number of characters.  We require
-- a space after the initial string of `#`s, as not all markdown
-- implementations do. This is because (a) the ATX reference
-- implementation requires a space, and (b) since we're allowing
-- headers without preceding blank lines, requiring the space
-- avoids accidentally capturing a line like `#8 toggle bolt` as
-- a header.
parseAtxHeaderStart :: Parser Int
parseAtxHeaderStart = do
  char '#'
  hashes <- upToCountChars 5 (== '#')
  skip (==' ') <|> scanBlankline
  return $ T.length hashes + 1

parseSetextHeaderLine :: Parser Int
parseSetextHeaderLine = do
  d <- char '-' <|> char '='
  let lev = if d == '=' then 1 else 2
  many (char d)
  scanBlankline
  return lev

-- Scan a horizontal rule line: "...three or more hyphens, asterisks,
-- or underscores on a line by themselves. If you wish, you may use
-- spaces between the hyphens or asterisks."
scanHRuleLine :: Scanner
scanHRuleLine = do
  c <- satisfy $ inClass "*_-"
  count 2 $ scanSpaces >> char c
  skipWhile (\x -> x == ' ' || x == c)
  endOfInput

-- Parse an initial code fence line, returning
-- the fence part and the rest (after any spaces).
parseCodeFence :: Parser ContainerType
parseCodeFence = do
  scanNonindentSpace
  col <- column <$> getPosition
  c <- satisfy $ inClass "`~"
  count 2 (char c)
  extra <- takeWhile (== c)
  scanSpaces
  rawattr <- takeWhile (/='`')
  endOfInput
  return $ FencedCode { startColumn = col
                      , fence = T.pack [c,c,c] <> extra
                      , info = rawattr }

-- Parse the start of an HTML block:  either an HTML tag or an
-- HTML comment, with no indentation.
parseHtmlBlockStart :: Parser ()
parseHtmlBlockStart = () <$ lookAhead
  ( scanNonindentSpace *>
     ((do t <- pHtmlTag
          guard $ f $ fst t
          return $ snd t)
    <|> string "<!--"
    <|> string "-->"
     )
  )
 where f (Opening name) = name `Set.member` blockHtmlTags
       f (SelfClosing name) = name `Set.member` blockHtmlTags
       f (Closing name) = name `Set.member` blockHtmlTags

-- List of block level tags for HTML 5.
blockHtmlTags :: Set.Set Text
blockHtmlTags = Set.fromList
 [ "article", "header", "aside", "hgroup", "blockquote", "hr",
   "body", "li", "br", "map", "button", "object", "canvas", "ol",
   "caption", "output", "col", "p", "colgroup", "pre", "dd",
   "progress", "div", "section", "dl", "table", "dt", "tbody",
   "embed", "textarea", "fieldset", "tfoot", "figcaption", "th",
   "figure", "thead", "footer", "footer", "tr", "form", "ul",
   "h1", "h2", "h3", "h4", "h5", "h6", "video"]


-- Parse a list marker and return the list type.
parseListMarker :: Parser ContainerType
parseListMarker = do
  scanNonindentSpace
  col <- column <$> getPosition
  ty <- parseBullet <|> parseListNumber
  padding' <- (1 <$ scanBlankline)
          <|> (1 <$ (skip (==' ') *> lookAhead (count 4 (char ' '))))
          <|> (T.length <$> takeWhile (==' '))
  guard $ padding' > 0
  return $ ListItem { listType = ty
                    , markerColumn = col
                    , padding = padding' + listMarkerWidth ty
                    }

listMarkerWidth :: ListType -> Int
listMarkerWidth (Bullet _) = 1
listMarkerWidth (Numbered _ n) | n < 10    = 2
                               | n < 100   = 3
                               | n < 1000  = 4
                               | otherwise = 5

-- Parse a bullet and return list type.
parseBullet :: Parser ListType
parseBullet = do
  c <- satisfy $ inClass "+*-"
  unless (c == '+')
    $ nfb $ (count 2 $ scanSpaces >> skip (== c)) >>
          skipWhile (\x -> x == ' ' || x == c) >> endOfInput -- hrule
  return $ Bullet c

-- Parse a list number marker and return list type.
parseListNumber :: Parser ListType
parseListNumber = do
    num <- (read . T.unpack) <$> takeWhile1 isDigit
    wrap <-  PeriodFollowing <$ skip (== '.')
         <|> ParenFollowing <$ skip (== ')')
    return $ Numbered wrap num

