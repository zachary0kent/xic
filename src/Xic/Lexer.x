{
{-# OPTIONS_GHC -fno-warn-unused-imports #-}

module Xic.Lexer (handleLex, AlexState, initialState, HandlerEffects) where

import Cleff
import Cleff.Error
import Cleff.State (State)
import Cleff.State qualified as State
import Control.Monad
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as ByteString
import Data.ByteString.Lazy.UTF8 qualified as UTF8
import Data.Int (Int64)
import Xic.Compile.Options (Lang (..))
import Xic.Lexer.Char (string)
import Xic.Lexer.Error qualified as Lexer
import Xic.Lexer.Position (Position (..), Positioned (..))
import Xic.Lexer.Token (Token (..))
import Prelude hiding (Ordering (..))
}

%wrapper "monad-bytestring"

@char    = \' (\\ \' | ~\')* \'
@string  = \" (\\ \" | ~\")* \"
@comment = "//" .*
@id      = [a-zA-Z][a-zA-Z0-9\'\_]*
@int     = \-? [0-9]+

tokens :-
  @comment | $white    ;
  "use"                { rword USE }
  "if"                 { rword IF }
  "else"               { rword ELSE }
  "while"              { rword WHILE }
  "return"             { rword RETURN }
  "break"              { rword BREAK }
  "length"             { rword LENGTH }
  \(                   { rword LPAREN }
  \)                   { rword RPAREN }
  \[                   { rword LBRACK }
  \]                   { rword RBRACK }
  \{                   { rword LBRACE }
  \}                   { rword RBRACE }
  \=                   { rword GETS }
  \*                   { rword MULT }
  "*>>"                { rword HIGHMULT }
  \/                   { rword DIV }
  \%                   { rword MOD }
  \+                   { rword PLUS }
  \-                   { rword MINUS }
  \<                   { rword LT }
  "<="                 { rword LEQ }
  ">="                 { rword GEQ }
  \>                   { rword GT }
  "=="                 { rword EQ }
  "!="                 { rword NEQ }
  \!                   { rword NOT }
  \&                   { rword AND }
  \|                   { rword OR }
  \:                   { rword COLON }
  \;                   { rword SEMICOLON }
  \,                   { rword COMMA }
  \_                   { rword WILDCARD }
  @char                { withLexeme charLiteral }
  @string              { withLexeme stringLiteral }
  @int                 { withLexeme intLiteral }
  "int"                { rword TYINT }
  "bool"               { rword TYBOOL }
  "record" / { isRho } { rword RECORD }
  "null"   / { isRho } { rword NULL }
  \.       / { isRho } { rword DOT }
  @id                  { withLexeme identifier }
{
isRho :: Lang -> AlexInput -> Int -> AlexInput -> Bool
isRho lang _ _ _ = lang == Rho

rword :: token -> AlexAction token
rword tok = token \_ _ -> tok

alexEOF :: Alex Token
alexEOF = pure EOF

withLexeme :: (String -> Alex a) -> AlexAction a
withLexeme tok (_, _, lexeme, _) len =
  tok $ UTF8.toString $ ByteString.take len lexeme

charLiteral :: String -> Alex Token
charLiteral lexeme =
  case string lexeme of
    Right [c] -> pure $ CHAR c
    _ -> alexError "error:Invalid character constant"

identifier :: String -> Alex Token
identifier = pure . ID

stringLiteral :: String -> Alex Token
stringLiteral lexeme =
  case string lexeme of
    Right lit -> pure $ STRING lit
    Left _ -> alexError "error:Invalid string literal"

intLiteral :: String -> Alex Token
intLiteral lexeme = do
  when (not $ inRange int64Range value) do
    alexError "error:Integer literal too large"
  pure $ INT $ fromInteger value
    where
      value = read lexeme
      int64Range = (toInteger @Int64 minBound, toInteger @Int64 maxBound)

getInput :: State AlexState :> es => Eff es AlexInput
getInput = do
  AlexState{alex_pos, alex_bpos, alex_chr, alex_inp} <- State.get
  pure (alex_pos, alex_chr, alex_inp, alex_bpos)

setInput :: State AlexState :> es => AlexInput -> Eff es ()
setInput (alex_pos, alex_chr, alex_inp, alex_bpos) =
  State.modify \state -> state {alex_pos, alex_chr, alex_inp, alex_bpos}

getStartCode :: State AlexState :> es => Eff es Int
getStartCode = State.gets alex_scd

type HandlerEffects :: [Effect]
type HandlerEffects = '[Error (Positioned Lexer.Error), State AlexState]

liftAlex :: HandlerEffects :>> es => Position -> Alex a -> Eff es (Positioned a)
liftAlex position (Alex alex) = do
  state <- State.get
  case alex state of
    Right (state', value) -> do
      State.put state'
      pure Positioned {value, position}
    Left message ->
      throwError Positioned {value = Lexer.Error message, position}

eof :: Position -> Positioned Token
eof position = Positioned {value = EOF, position}

initialState :: ByteString -> AlexState
initialState alex_inp =
  AlexState
    { alex_bpos = 0,
      alex_pos = alexStartPos,
      alex_inp,
      alex_chr = '\n',
      alex_scd = 0
    }

handleLex :: Lang -> HandlerEffects :>> es => Eff es (Positioned Token)
handleLex lang = do
  sc <- getStartCode
  input@(AlexPn _ line column, _, _, n) <- getInput
  let position = Position {line, column}
  case alexScanUser lang input sc of
    AlexEOF -> pure $ eof position
    AlexError (AlexPn _ line column, _, _, _) ->
      Lexer.throwGeneric Position {line, column}
    AlexSkip next _ -> setInput next *> handleLex lang
    AlexToken next@(_, _, _, n') _ action -> do
      setInput next
      let len = n' - n
          result = action (ignorePendingBytes input) len
      liftAlex position result
}
