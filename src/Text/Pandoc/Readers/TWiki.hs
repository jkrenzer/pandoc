{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE RelaxedPolyRec    #-}
-- RelaxedPolyRec needed for inlinesBetween on GHC < 7
{- |
   Module      : Text.Pandoc.Readers.TWiki
   Copyright   : Copyright (C) 2014 Alexander Sulfrian
   License     : GNU GPL, version 2 or above

   Maintainer  : Alexander Sulfrian <alexander.sulfrian@fu-berlin.de>
   Stability   : alpha
   Portability : portable

Conversion of twiki text to 'Pandoc' document.
-}
module Text.Pandoc.Readers.TWiki ( readTWiki
                                 ) where

import Prelude
import Control.Monad
import Control.Monad.Except (throwError)
import Data.Char (isAlphaNum)
import qualified Data.Foldable as F
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Text.HTML.TagSoup
import qualified Text.Pandoc.Legacy.Builder as B -- TODO text: remove Legacy
import Text.Pandoc.Class (PandocMonad (..))
import Text.Pandoc.Legacy.Definition -- TODO text: remove Legacy
import Text.Pandoc.Options
import Text.Pandoc.Parsing hiding (enclosed, nested)
import Text.Pandoc.Readers.HTML (htmlTag, isCommentTag)
import Text.Pandoc.Legacy.Shared (crFilter)
import Text.Pandoc.XML (fromEntities)

-- | Read twiki from an input string and return a Pandoc document.
readTWiki :: PandocMonad m
          => ReaderOptions
          -> Text
          -> m Pandoc
readTWiki opts s = do
  res <- readWithM parseTWiki def{ stateOptions = opts }
             (T.unpack (crFilter s) ++ "\n\n")
  case res of
       Left e  -> throwError e
       Right d -> return d

type TWParser = ParserT [Char] ParserState

--
-- utility functions
--

tryMsg :: String -> TWParser m a -> TWParser m a
tryMsg msg p = try p <?> msg

nested :: PandocMonad m => TWParser m a -> TWParser m a
nested p = do
  nestlevel <- stateMaxNestingLevel <$>  getState
  guard $ nestlevel > 0
  updateState $ \st -> st{ stateMaxNestingLevel = stateMaxNestingLevel st - 1 }
  res <- p
  updateState $ \st -> st{ stateMaxNestingLevel = nestlevel }
  return res

htmlElement :: PandocMonad m => String -> TWParser m (Attr, String)
htmlElement tag = tryMsg tag $ do
  (TagOpen _ attr, _) <- htmlTag (~== TagOpen tag [])
  content <- manyTill anyChar (endtag <|> endofinput)
  return (htmlAttrToPandoc attr, trim content)
  where
    endtag     = void $ htmlTag (~== TagClose tag)
    endofinput = lookAhead $ try $ skipMany blankline >> skipSpaces >> eof
    trim       = dropWhile (=='\n') . reverse . dropWhile (=='\n') . reverse

htmlAttrToPandoc :: [Attribute String] -> Attr
htmlAttrToPandoc attrs = (ident, classes, keyvals)
  where
    ident   = fromMaybe "" $ lookup "id" attrs
    classes = maybe [] words $ lookup "class" attrs
    keyvals = [(k,v) | (k,v) <- attrs, k /= "id" && k /= "class"]

parseHtmlContentWithAttrs :: PandocMonad m
                          => String -> TWParser m a -> TWParser m (Attr, [a])
parseHtmlContentWithAttrs tag parser = do
  (attr, content) <- htmlElement tag
  parsedContent <- try $ parseContent content
  return (attr, parsedContent)
  where
    parseContent = parseFromString' $ nested $ manyTill parser endOfContent
    endOfContent = try $ skipMany blankline >> skipSpaces >> eof

parseHtmlContent :: PandocMonad m => String -> TWParser m a -> TWParser m [a]
parseHtmlContent tag p = snd <$> parseHtmlContentWithAttrs tag p

--
-- main parser
--

parseTWiki :: PandocMonad m => TWParser m Pandoc
parseTWiki =
  B.doc . mconcat <$> many block <* spaces <* eof


--
-- block parsers
--

block :: PandocMonad m => TWParser m B.Blocks
block = do
  res <- mempty <$ skipMany1 blankline
         <|> blockElements
         <|> para
  skipMany blankline
  trace (take 60 $ show $ B.toList res)
  return res

blockElements :: PandocMonad m => TWParser m B.Blocks
blockElements = choice [ separator
                       , header
                       , verbatim
                       , literal
                       , list ""
                       , table
                       , blockQuote
                       , noautolink
                       ]

separator :: PandocMonad m => TWParser m B.Blocks
separator = tryMsg "separator" $ string "---" >> newline >> return B.horizontalRule

header :: PandocMonad m => TWParser m B.Blocks
header = tryMsg "header" $ do
  string "---"
  level <- length <$> many1 (char '+')
  guard $ level <= 6
  classes <- option [] $ string "!!" >> return ["unnumbered"]
  skipSpaces
  content <- B.trimInlines . mconcat <$> manyTill inline newline
  attr <- registerHeader ("", classes, []) content
  return $ B.headerWith attr level content

verbatim :: PandocMonad m => TWParser m B.Blocks
verbatim = uncurry B.codeBlockWith <$> (htmlElement "verbatim" <|> htmlElement "pre")

literal :: PandocMonad m => TWParser m B.Blocks
literal = rawBlock <$> htmlElement "literal"
  where
    format (_, _, kvs)        = fromMaybe "html" $ lookup "format" kvs
    rawBlock (attrs, content) = B.rawBlock (format attrs) content

list :: PandocMonad m => String -> TWParser m B.Blocks
list prefix = choice [ bulletList prefix
                     , orderedList prefix
                     , definitionList prefix]

definitionList :: PandocMonad m => String -> TWParser m B.Blocks
definitionList prefix = tryMsg "definitionList" $ do
  indent <- lookAhead $ string prefix *> many1 (string "   ") <* string "$ "
  elements <- many $ parseDefinitionListItem (prefix ++ concat indent)
  return $ B.definitionList elements
  where
    parseDefinitionListItem :: PandocMonad m
                            => String -> TWParser m (B.Inlines, [B.Blocks])
    parseDefinitionListItem indent = do
      string (indent ++ "$ ") >> skipSpaces
      term <- many1Till inline $ string ": "
      line <- listItemLine indent $ string "$ "
      return (mconcat term, [line])

bulletList :: PandocMonad m => String -> TWParser m B.Blocks
bulletList prefix = tryMsg "bulletList" $
                    parseList prefix (char '*') (char ' ')

orderedList :: PandocMonad m => String -> TWParser m B.Blocks
orderedList prefix = tryMsg "orderedList" $
                     parseList prefix (oneOf "1iIaA") (string ". ")

parseList :: PandocMonad m
          => String -> TWParser m Char -> TWParser m a -> TWParser m B.Blocks
parseList prefix marker delim = do
  (indent, style) <- lookAhead $ string prefix *> listStyle <* delim
  blocks <- many $ parseListItem (prefix ++ indent) (char style <* delim)
  return $ case style of
    '1' -> B.orderedListWith (1, DefaultStyle, DefaultDelim) blocks
    'i' -> B.orderedListWith (1, LowerRoman, DefaultDelim) blocks
    'I' -> B.orderedListWith (1, UpperRoman, DefaultDelim) blocks
    'a' -> B.orderedListWith (1, LowerAlpha, DefaultDelim) blocks
    'A' -> B.orderedListWith (1, UpperAlpha, DefaultDelim) blocks
    _   -> B.bulletList blocks
  where
    listStyle = do
      indent <- many1 $ string "   "
      style <- marker
      return (concat indent, style)

parseListItem :: (PandocMonad m, Show a)
              => String -> TWParser m a -> TWParser m B.Blocks
parseListItem prefix marker = string prefix >> marker >> listItemLine prefix marker

listItemLine :: (PandocMonad m, Show a)
             => String -> TWParser m a -> TWParser m B.Blocks
listItemLine prefix marker = mconcat <$> (lineContent >>= parseContent)
  where
    lineContent = do
      content <- anyLine
      continuation <- optionMaybe listContinuation
      return $ filterSpaces content ++ "\n" ++ maybe "" ("   " ++) continuation
    filterSpaces = reverse . dropWhile (== ' ') . reverse
    listContinuation = notFollowedBy (string prefix >> marker) >>
                       string "   " >> lineContent
    parseContent = parseFromString' $ many1 $ nestedList <|> parseInline
    parseInline = (B.plain . mconcat) <$> many1Till inline (lastNewline <|> newlineBeforeNestedList)
    nestedList = list prefix
    lastNewline = try $ char '\n' <* eof
    newlineBeforeNestedList = try $ char '\n' <* lookAhead nestedList

table :: PandocMonad m => TWParser m B.Blocks
table = try $ do
  tableHead <- optionMaybe (unzip <$> many1Till tableParseHeader newline)
  rows <- many1 tableParseRow
  return $ buildTable mempty rows $ fromMaybe (align rows, columns rows) tableHead
  where
    buildTable caption rows (aligns, heads)
                    = B.table caption aligns heads rows
    align rows      = replicate (columCount rows) (AlignDefault, 0)
    columns rows    = replicate (columCount rows) mempty
    columCount rows = length $ head rows

tableParseHeader :: PandocMonad m => TWParser m ((Alignment, Double), B.Blocks)
tableParseHeader = try $ do
  char '|'
  leftSpaces <- length <$> many spaceChar
  char '*'
  content <- tableColumnContent (char '*' >> skipSpaces >> char '|')
  char '*'
  rightSpaces <- length <$> many spaceChar
  optional tableEndOfRow
  return (tableAlign leftSpaces rightSpaces, content)
  where
    tableAlign left right
      | left >= 2 && left == right = (AlignCenter, 0)
      | left > right = (AlignRight, 0)
      | otherwise = (AlignLeft, 0)

tableParseRow :: PandocMonad m => TWParser m [B.Blocks]
tableParseRow = many1Till tableParseColumn newline

tableParseColumn :: PandocMonad m => TWParser m B.Blocks
tableParseColumn = char '|' *> skipSpaces *>
                   tableColumnContent (skipSpaces >> char '|')
                   <* skipSpaces <* optional tableEndOfRow

tableEndOfRow :: PandocMonad m => TWParser m Char
tableEndOfRow = lookAhead (try $ char '|' >> char '\n') >> char '|'

tableColumnContent :: PandocMonad m => TWParser m a -> TWParser m B.Blocks
tableColumnContent end = (B.plain . mconcat) <$> manyTill content (lookAhead $ try end)
  where
    content = continuation <|> inline
    continuation = try $ char '\\' >> newline >> return mempty

blockQuote :: PandocMonad m => TWParser m B.Blocks
blockQuote = (B.blockQuote . mconcat) <$> parseHtmlContent "blockquote" block

noautolink :: PandocMonad m => TWParser m B.Blocks
noautolink = do
  (_, content) <- htmlElement "noautolink"
  st <- getState
  setState $ st{ stateAllowLinks = False }
  blocks <- try $ parseContent content
  setState $ st{ stateAllowLinks = True }
  return $ mconcat blocks
  where
    parseContent = parseFromString' $ many block

para :: PandocMonad m => TWParser m B.Blocks
para = (result . mconcat) <$> many1Till inline endOfParaElement
 where
   endOfParaElement = lookAhead $ endOfInput <|> endOfPara <|> newBlockElement
   endOfInput       = try $ skipMany blankline >> skipSpaces >> eof
   endOfPara        = try $ blankline >> skipMany1 blankline
   newBlockElement  = try $ blankline >> void blockElements
   result content   = if F.all (==Space) content
                      then mempty
                      else B.para $ B.trimInlines content


--
-- inline parsers
--

inline :: PandocMonad m => TWParser m B.Inlines
inline = choice [ whitespace
                , br
                , macro
                , strong
                , strongHtml
                , strongAndEmph
                , emph
                , emphHtml
                , boldCode
                , smart
                , link
                , htmlComment
                , code
                , codeHtml
                , nop
                , autoLink
                , str
                , symbol
                ] <?> "inline"

whitespace :: PandocMonad m => TWParser m B.Inlines
whitespace = lb <|> regsp
  where lb = try $ skipMany spaceChar >> linebreak >> return B.space
        regsp = try $ skipMany1 spaceChar >> return B.space

br :: PandocMonad m => TWParser m B.Inlines
br = try $ string "%BR%" >> return B.linebreak

linebreak :: PandocMonad m => TWParser m B.Inlines
linebreak = newline >> notFollowedBy newline >> (lastNewline <|> innerNewline)
  where lastNewline  = eof >> return mempty
        innerNewline = return B.space

between :: (Monoid c, PandocMonad m, Show b)
        => TWParser m a -> TWParser m b -> (TWParser m b -> TWParser m c)
        -> TWParser m c
between start end p =
  mconcat <$> try (start >> notFollowedBy whitespace >> many1Till (p end) end)

enclosed :: (Monoid b, PandocMonad m, Show a)
         => TWParser m a -> (TWParser m a -> TWParser m b) -> TWParser m b
enclosed sep p = between sep (try $ sep <* endMarker) p
  where
    endMarker   = lookAhead $ void endSpace <|> void (oneOf ".,!?:)|") <|> eof
    endSpace    = (spaceChar <|> newline) >> return B.space

macro :: PandocMonad m => TWParser m B.Inlines
macro = macroWithParameters <|> withoutParameters
  where
    withoutParameters = emptySpan <$> enclosed (char '%') (const macroName)
    emptySpan name = buildSpan name [] mempty

macroWithParameters :: PandocMonad m => TWParser m B.Inlines
macroWithParameters = try $ do
  char '%'
  name <- macroName
  (content, kvs) <- attributes
  char '%'
  return $ buildSpan name kvs $ B.str content

buildSpan :: String -> [(String, String)] -> B.Inlines -> B.Inlines
buildSpan className kvs = B.spanWith attrs
  where
    attrs             = ("", ["twiki-macro", className] ++ additionalClasses, kvsWithoutClasses)
    additionalClasses = maybe [] words $ lookup "class" kvs
    kvsWithoutClasses = [(k,v) | (k,v) <- kvs, k /= "class"]

macroName :: PandocMonad m => TWParser m String
macroName = do
  first <- letter
  rest <- many $ alphaNum <|> char '_'
  return (first:rest)

attributes :: PandocMonad m => TWParser m (String, [(String, String)])
attributes = foldr (either mkContent mkKvs) ([], [])
  <$> (char '{' *> spnl *> many (attribute <* spnl) <* char '}')
  where
    spnl                      = skipMany (spaceChar <|> newline)
    mkContent c  ([], kvs)   = (c, kvs)
    mkContent c  (rest, kvs) = (c ++ " " ++ rest, kvs)
    mkKvs     kv (cont, rest) = (cont, kv : rest)

attribute :: PandocMonad m => TWParser m (Either String (String, String))
attribute = withKey <|> withoutKey
  where
    withKey = try $ do
      key <- macroName
      char '='
      curry Right key <$> parseValue False
    withoutKey = try $ Left <$> parseValue True
    parseValue allowSpaces = fromEntities <$> (withQuotes <|> withoutQuotes allowSpaces)
    withQuotes             = between (char '"') (char '"') (\_ -> count 1 $ noneOf ['"'])
    withoutQuotes allowSpaces
      | allowSpaces = many1 $ noneOf "}"
      | otherwise   = many1 $ noneOf " }"

nestedInlines :: (Show a, PandocMonad m)
              => TWParser m a -> TWParser m B.Inlines
nestedInlines end = innerSpace <|> nestedInline
  where
    innerSpace   = try $ whitespace <* notFollowedBy end
    nestedInline = notFollowedBy whitespace >> nested inline

strong :: PandocMonad m => TWParser m B.Inlines
strong = try $ B.strong <$> enclosed (char '*') nestedInlines

strongHtml :: PandocMonad m => TWParser m B.Inlines
strongHtml = B.strong . mconcat <$> (parseHtmlContent "strong" inline <|> parseHtmlContent "b" inline)

strongAndEmph :: PandocMonad m => TWParser m B.Inlines
strongAndEmph = try $ B.emph . B.strong <$> enclosed (string "__") nestedInlines

emph :: PandocMonad m => TWParser m B.Inlines
emph = try $ B.emph <$> enclosed (char '_')
                        (\p -> notFollowedBy (char '|') >> nestedInlines p)
-- emphasis closers can't cross table cell boundaries, see #3921

emphHtml :: PandocMonad m => TWParser m B.Inlines
emphHtml = B.emph . mconcat <$> (parseHtmlContent "em" inline <|> parseHtmlContent "i" inline)

nestedString :: (Show a, PandocMonad m)
             => TWParser m a -> TWParser m String
nestedString end = innerSpace <|> count 1 nonspaceChar
  where
    innerSpace = try $ many1 spaceChar <* notFollowedBy end

boldCode :: PandocMonad m => TWParser m B.Inlines
boldCode = try $ (B.strong . B.code . fromEntities) <$> enclosed (string "==") nestedString

htmlComment :: PandocMonad m => TWParser m B.Inlines
htmlComment = htmlTag isCommentTag >> return mempty

code :: PandocMonad m => TWParser m B.Inlines
code = try $ (B.code . fromEntities) <$> enclosed (char '=') nestedString

codeHtml :: PandocMonad m => TWParser m B.Inlines
codeHtml = do
  (attrs, content) <- parseHtmlContentWithAttrs "code" anyChar
  return $ B.codeWith attrs $ fromEntities content

autoLink :: PandocMonad m => TWParser m B.Inlines
autoLink = try $ do
  state <- getState
  guard $ stateAllowLinks state
  (text, url) <- parseLink
  guard $ checkLink (last url)
  return $ makeLink (text, url)
  where
    parseLink            = notFollowedBy nop >> (uri <|> emailAddress)
    makeLink (text, url) = B.link url "" $ B.str text
    checkLink c
      | c == '/' = True
      | otherwise = isAlphaNum c

str :: PandocMonad m => TWParser m B.Inlines
str = B.str <$> (many1 alphaNum <|> count 1 characterReference)

nop :: PandocMonad m => TWParser m B.Inlines
nop = try $ (void exclamation <|> void nopTag) >> followContent
  where
    exclamation   = char '!'
    nopTag        = stringAnyCase "<nop>"
    followContent = B.str . fromEntities <$> many1 nonspaceChar

symbol :: PandocMonad m => TWParser m B.Inlines
symbol = B.str <$> count 1 nonspaceChar

smart :: PandocMonad m => TWParser m B.Inlines
smart = do
  guardEnabled Ext_smart
  doubleQuoted <|> singleQuoted <|>
    choice [ apostrophe
           , dash
           , ellipses
           ]

singleQuoted :: PandocMonad m => TWParser m B.Inlines
singleQuoted = try $ do
  singleQuoteStart
  withQuoteContext InSingleQuote
    (B.singleQuoted . B.trimInlines . mconcat <$> many1Till inline singleQuoteEnd)

doubleQuoted :: PandocMonad m => TWParser m B.Inlines
doubleQuoted = try $ do
  doubleQuoteStart
  contents <- mconcat <$> many (try $ notFollowedBy doubleQuoteEnd >> inline)
  withQuoteContext InDoubleQuote (doubleQuoteEnd >>
   return (B.doubleQuoted $ B.trimInlines contents))
   <|> return (B.str "\8220" B.<> contents)

link :: PandocMonad m => TWParser m B.Inlines
link = try $ do
  st <- getState
  guard $ stateAllowLinks st
  setState $ st{ stateAllowLinks = False }
  (url, title, content) <- linkText
  setState $ st{ stateAllowLinks = True }
  return $ B.link url title content

linkText :: PandocMonad m => TWParser m (String, String, B.Inlines)
linkText = do
  string "[["
  url <- many1Till anyChar (char ']')
  content <- option (B.str url) (mconcat <$> linkContent)
  char ']'
  return (url, "", content)
  where
    linkContent      = char '[' >> many1Till anyChar (char ']') >>= parseLinkContent
    parseLinkContent = parseFromString' $ many1 inline
