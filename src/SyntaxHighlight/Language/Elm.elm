module SyntaxHighlight.Language.Elm
    exposing
        ( parse
          -- Exposing just for tests purpose
        , toSyntax
          -- Exposing just for tests purpose
        , SyntaxType(..)
        )

import Char
import Set exposing (Set)
import Parser exposing (Parser, oneOf, zeroOrMore, oneOrMore, ignore, symbol, keyword, (|.), (|=), source, ignoreUntil, keep, Count(..), Error, map, andThen, delayedCommit)
import SyntaxHighlight.Fragment exposing (Fragment, Color(..), normal, emphasis)
import SyntaxHighlight.Helpers exposing (isWhitespace, isSpace, isLineBreak, number, delimited)


type alias Syntax =
    ( SyntaxType, String )


type SyntaxType
    = Normal
    | Comment
    | String
    | BasicSymbol
    | GroupSymbol
    | Capitalized
    | Keyword
    | Function
    | TypeSignature
    | Space
    | LineBreak
    | Number
    | Infix


parse : String -> Result Error (List Fragment)
parse =
    toSyntax
        >> Result.map (List.map syntaxToFragment)


toSyntax : String -> Result Error (List Syntax)
toSyntax =
    Parser.run (lineStart functionBody [])


lineStart : (List Syntax -> Parser (List Syntax)) -> List Syntax -> Parser (List Syntax)
lineStart continueFunction revSyntaxList =
    oneOf
        [ moduleDeclaration "module" revSyntaxList
        , moduleDeclaration "import" revSyntaxList
        , Parser.keyword "port"
            |> andThen (\_ -> portDeclaration revSyntaxList)
        , oneOf [ space, comment ]
            |> andThen (\n -> continueFunction (n :: revSyntaxList))
        , lineBreak
            |> andThen (\n -> lineStart continueFunction (n :: revSyntaxList))
        , functionBodyKeyword revSyntaxList
        , variable
            |> map ((,) Function)
            |> andThen (\n -> functionSignature (n :: revSyntaxList))
        , functionBody revSyntaxList
        ]



-- Module Declaration


moduleDeclaration : String -> List Syntax -> Parser (List Syntax)
moduleDeclaration keyword revSyntaxList =
    Parser.keyword keyword
        |> andThen (\_ -> moduleDeclarationHelp keyword revSyntaxList)


moduleDeclarationHelp : String -> List Syntax -> Parser (List Syntax)
moduleDeclarationHelp keyword revSyntaxList =
    oneOf
        [ oneOf
            [ space
            , comment
            , lineBreak
            ]
            |> andThen
                (\n ->
                    modDecLoop
                        (n :: ( Keyword, keyword ) :: revSyntaxList)
                )
        , end (( Keyword, keyword ) :: revSyntaxList)
        , keep zeroOrMore isVariableChar
            |> andThen
                (\str ->
                    functionSignature
                        (( Function, keyword ++ str ) :: revSyntaxList)
                )
        ]


modDecLoop : List Syntax -> Parser (List Syntax)
modDecLoop revSyntaxList =
    oneOf
        [ lineBreak
            |> andThen (\n -> lineStart modDecLoop (n :: revSyntaxList))
        , symbol "("
            |> map (always ( Normal, "(" ))
            |> andThen (\n -> modDecParentheses (n :: revSyntaxList))
        , oneOf
            [ space
            , comment
            , commentChar |> map ((,) Normal)
            , Parser.keyword "exposing"
                |> map (always ( Keyword, "exposing" ))
            , Parser.keyword "as"
                |> map (always ( Keyword, "as" ))
            , keep oneOrMore (not << mdlIsSpecialChar)
                |> map ((,) Normal)
            ]
            |> andThen (\n -> modDecLoop (n :: revSyntaxList))
        , end revSyntaxList
        ]


mdlIsSpecialChar : Char -> Bool
mdlIsSpecialChar c =
    isWhitespace c || isCommentChar c || c == '('


modDecParentheses : List Syntax -> Parser (List Syntax)
modDecParentheses revSyntaxList =
    oneOf
        [ lineBreak
            |> andThen (\n -> lineStart modDecParentheses (n :: revSyntaxList))
        , symbol ")"
            |> map (always ( Normal, ")" ))
            |> andThen (\n -> modDecLoop (n :: revSyntaxList))
        , oneOf
            [ space
            , comment
            , infixParser
            , commentChar |> map ((,) Normal)
            , keep oneOrMore (\c -> c == ',' || c == '.')
                |> map ((,) Normal)
            , (ignore (Exactly 1) Char.isUpper
                |. ignore zeroOrMore (not << mdpIsSpecialChar)
              )
                |> source
                |> map ((,) TypeSignature)
            , keep oneOrMore (not << mdpIsSpecialChar)
                |> map ((,) Function)
            ]
            |> andThen (\n -> modDecParentheses (n :: revSyntaxList))
        , symbol "("
            |> map (always ( Normal, "(" ))
            |> andThen (\n -> modDecParNest 0 (n :: revSyntaxList))
        , end revSyntaxList
        ]


mdpIsSpecialChar : Char -> Bool
mdpIsSpecialChar c =
    isWhitespace c || isCommentChar c || c == '(' || c == ')' || c == ',' || c == '.'


modDecParNest : Int -> List Syntax -> Parser (List Syntax)
modDecParNest nestLevel revSyntaxList =
    oneOf
        [ lineBreak
            |> andThen (\n -> lineStart (modDecParNest nestLevel) (n :: revSyntaxList))
        , symbol "("
            |> map (always ( Normal, "(" ))
            |> andThen (\n -> modDecParNest (nestLevel + 1) (n :: revSyntaxList))
        , symbol ")"
            |> map (always ( Normal, ")" ))
            |> andThen
                (\n ->
                    if nestLevel == 0 then
                        modDecParentheses (n :: revSyntaxList)
                    else
                        modDecParNest (max 0 (nestLevel - 1)) (n :: revSyntaxList)
                )
        , oneOf
            [ comment
            , commentChar |> map ((,) Normal)
            , keep oneOrMore (not << mdpnIsSpecialChar)
                |> map ((,) Normal)
            ]
            |> andThen (\n -> modDecParNest nestLevel (n :: revSyntaxList))
        , end revSyntaxList
        ]


mdpnIsSpecialChar : Char -> Bool
mdpnIsSpecialChar c =
    isLineBreak c || isCommentChar c || c == '(' || c == ')'



-- Port Declaration


portDeclaration : List Syntax -> Parser (List Syntax)
portDeclaration revSyntaxList =
    oneOf
        [ oneOf
            [ space
            , comment
            , lineBreak
            ]
            |> andThen (\n -> portLoop (n :: ( Keyword, "port" ) :: revSyntaxList))
        , end (( Keyword, "port" ) :: revSyntaxList)
        , keep zeroOrMore isVariableChar
            |> andThen
                (\str ->
                    functionSignature
                        (( Function, ("port" ++ str) ) :: revSyntaxList)
                )
        ]


portLoop : List Syntax -> Parser (List Syntax)
portLoop revSyntaxList =
    oneOf
        [ oneOf
            [ space
            , comment
            , lineBreak
            ]
            |> andThen (\n -> portLoop (n :: revSyntaxList))
        , moduleDeclaration "module" revSyntaxList
        , variable
            |> map ((,) Function)
            |> andThen (\n -> functionSignature (n :: revSyntaxList))
        , functionBody revSyntaxList
        ]



-- Function Signature


functionSignature : List Syntax -> Parser (List Syntax)
functionSignature revSyntaxList =
    oneOf
        [ symbol ":"
            |> map (always ( BasicSymbol, ":" ))
            |> andThen (\n -> functionSignatureLoop (n :: revSyntaxList))
        , space
            |> andThen (\n -> functionSignature (n :: revSyntaxList))
        , lineBreak
            |> andThen (\n -> lineStart functionSignature (n :: revSyntaxList))
        , functionBody revSyntaxList
        ]


functionSignatureLoop : List Syntax -> Parser (List Syntax)
functionSignatureLoop revSyntaxList =
    oneOf
        [ lineBreak
            |> andThen (\n -> lineStart functionSignature (n :: revSyntaxList))
        , functionSignatureContent
            |> andThen (\n -> functionSignatureLoop (n :: revSyntaxList))
        , end revSyntaxList
        ]


functionSignatureContent : Parser Syntax
functionSignatureContent =
    let
        isSpecialChar c =
            isWhitespace c || c == '(' || c == ')' || c == '-' || c == ','
    in
        oneOf
            [ space
            , comment
            , symbol "()" |> map (always ( TypeSignature, "()" ))
            , symbol "->" |> map (always ( BasicSymbol, "->" ))
            , keep oneOrMore (\c -> c == '(' || c == ')' || c == '-' || c == ',')
                |> map ((,) Normal)
            , source
                (ignore (Exactly 1) Char.isUpper
                    |. ignore zeroOrMore (not << isSpecialChar)
                )
                |> map ((,) TypeSignature)
            , keep oneOrMore (not << isSpecialChar)
                |> map ((,) Normal)
            ]



-- Function Body


functionBody : List Syntax -> Parser (List Syntax)
functionBody revSyntaxList =
    oneOf
        [ functionBodyKeyword revSyntaxList
        , functionBodyContent
            |> andThen (\n -> functionBody (n :: revSyntaxList))
        , lineBreak
            |> andThen (\n -> lineStart functionBody (n :: revSyntaxList))
        , end revSyntaxList
        ]


functionBodyContent : Parser Syntax
functionBodyContent =
    oneOf
        [ space
        , string
        , comment
        , number
            |> source
            |> map ((,) Number)
        , symbol "()"
            |> map (always ( Capitalized, "()" ))
        , infixParser
        , basicSymbol
            |> map ((,) BasicSymbol)
        , groupSymbol
            |> map ((,) GroupSymbol)
        , capitalized
            |> map ((,) Capitalized)
        , variable
            |> map ((,) Normal)
        , weirdText
            |> map ((,) Normal)
        ]


space : Parser Syntax
space =
    keep oneOrMore isSpace
        |> map ((,) Space)


lineBreak : Parser Syntax
lineBreak =
    keep oneOrMore isLineBreak
        |> map ((,) LineBreak)


functionBodyKeyword : List Syntax -> Parser (List Syntax)
functionBodyKeyword revSyntaxList =
    functionBodyKeywords
        |> andThen
            (\kwStr ->
                oneOf
                    [ oneOf
                        [ space
                        , comment
                        , lineBreak
                        ]
                        |> andThen
                            (\n ->
                                functionBody
                                    (n :: ( Keyword, kwStr ) :: revSyntaxList)
                            )
                    , end (( Keyword, kwStr ) :: revSyntaxList)
                    , keep zeroOrMore isVariableChar
                        |> andThen
                            (\str ->
                                functionBody
                                    (( Normal, (kwStr ++ str) ) :: revSyntaxList)
                            )
                    ]
            )


functionBodyKeywords : Parser String
functionBodyKeywords =
    [ "as"
    , "where"
    , "let"
    , "in"
    , "if"
    , "else"
    , "then"
    , "case"
    , "of"
    , "type"
    , "alias"
    ]
        |> List.map (Parser.keyword >> source)
        |> oneOf


basicSymbol : Parser String
basicSymbol =
    keep oneOrMore isBasicSymbol


isBasicSymbol : Char -> Bool
isBasicSymbol c =
    Set.member c basicSymbols


basicSymbols : Set Char
basicSymbols =
    Set.fromList
        [ '|'
        , '.'
        , '='
        , '\\'
        , '/'
        , '('
        , ')'
        , '-'
        , '>'
        , '<'
        , ':'
        , '+'
        , '!'
        , '$'
        , '%'
        , '&'
        , '*'
        ]


groupSymbol : Parser String
groupSymbol =
    keep oneOrMore isGroupSymbol


isGroupSymbol : Char -> Bool
isGroupSymbol c =
    Set.member c groupSymbols


groupSymbols : Set Char
groupSymbols =
    Set.fromList
        [ ','
        , '['
        , ']'
        , '{'
        , '}'
        ]


capitalized : Parser String
capitalized =
    source <|
        ignore (Exactly 1) Char.isUpper
            |. ignore zeroOrMore isVariableChar


variable : Parser String
variable =
    source <|
        ignore (Exactly 1) Char.isLower
            |. ignore zeroOrMore isVariableChar


isVariableChar : Char -> Bool
isVariableChar c =
    not
        (isWhitespace c
            || isBasicSymbol c
            || isGroupSymbol c
            || (c == '"')
            || (c == '\'')
        )


weirdText : Parser String
weirdText =
    keep oneOrMore isVariableChar
        |> source



-- Infix


infixParser : Parser Syntax
infixParser =
    delayedCommit (symbol "(")
        (delayedCommit (ignore oneOrMore isInfixChar) (symbol ")"))
        |> source
        |> map ((,) Infix)


isInfixChar : Char -> Bool
isInfixChar c =
    Set.member c infixSet


infixSet : Set Char
infixSet =
    Set.fromList
        [ '+'
        , '-'
        , '/'
        , '*'
        , '='
        , '.'
        , '$'
        , '<'
        , '>'
        , ':'
        , '&'
        , '|'
        , '^'
        , '?'
        , '%'
        , '#'
        , '@'
        , '~'
        , '!'
        , ','
        ]



-- String/Char


string : Parser Syntax
string =
    oneOf
        [ tripleDoubleQuote
        , oneDoubleQuote
        , quote
        ]
        |> source
        |> map ((,) String)


oneDoubleQuote : Parser ()
oneDoubleQuote =
    delimited
        { start = "\""
        , end = "\""
        , isNestable = False
        , isEscapable = True
        }


tripleDoubleQuote : Parser ()
tripleDoubleQuote =
    delimited
        { start = "\"\"\""
        , end = "\"\"\""
        , isNestable = False
        , isEscapable = False
        }


quote : Parser ()
quote =
    delimited
        { start = "'"
        , end = "'"
        , isNestable = False
        , isEscapable = True
        }



-- Comments


comment : Parser Syntax
comment =
    oneOf
        [ inlineComment
        , multilineComment
        ]
        |> source
        |> map ((,) Comment)


inlineComment : Parser ()
inlineComment =
    symbol "--"
        |. ignore zeroOrMore (not << isLineBreak)


multilineComment : Parser ()
multilineComment =
    delimited
        { start = "{-"
        , end = "-}"
        , isNestable = True
        , isEscapable = False
        }


commentChar : Parser String
commentChar =
    keep (Exactly 1) isCommentChar


isCommentChar : Char -> Bool
isCommentChar c =
    c == '-' || c == '{'


end : List Syntax -> Parser (List Syntax)
end revSyntaxList =
    Parser.end
        |> map (\_ -> List.reverse revSyntaxList)


syntaxToFragment : Syntax -> Fragment
syntaxToFragment ( syntaxType, text ) =
    case syntaxType of
        Normal ->
            normal Default text

        Comment ->
            normal Color1 text

        String ->
            normal Color2 text

        BasicSymbol ->
            normal Color3 text

        GroupSymbol ->
            normal Color4 text

        Capitalized ->
            normal Color6 text

        Keyword ->
            normal Color3 text

        Function ->
            normal Color5 text

        TypeSignature ->
            emphasis Color4 text

        Space ->
            normal Default text

        LineBreak ->
            normal Default text

        Number ->
            normal Color6 text

        Infix ->
            normal Color5 text
