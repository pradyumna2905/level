module Route.Groups exposing (Params(..), parser, toString)

import Url.Builder as Builder exposing (absolute)
import Url.Parser as Parser exposing ((</>), Parser, map, oneOf, s, string)


type Params
    = Root String
    | After String String
    | Before String String


parser : Parser (Params -> a) a
parser =
    oneOf
        [ map Root (string </> s "groups")
        , map After (string </> s "groups" </> s "after" </> string)
        , map Before (string </> s "groups" </> s "before" </> string)
        ]


toString : Params -> String
toString params =
    case params of
        Root slug ->
            absolute [ slug, "groups" ] []

        After slug cursor ->
            absolute [ slug, "groups", "after", cursor ] []

        Before slug cursor ->
            absolute [ slug, "groups", "before", cursor ] []
