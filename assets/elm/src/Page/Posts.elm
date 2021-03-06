module Page.Posts exposing (Model, Msg(..), consumeEvent, init, setup, subscriptions, teardown, title, update, view)

import Avatar exposing (personAvatar)
import Component.Post
import Connection exposing (Connection)
import Event exposing (Event)
import Group exposing (Group)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Icons
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import KeyboardShortcuts
import ListHelpers exposing (insertUniqueBy, removeBy)
import Pagination
import Post exposing (Post)
import Query.PostsInit as PostsInit
import Reply exposing (Reply)
import Repo exposing (Repo)
import Route exposing (Route)
import Route.Posts exposing (Params(..))
import Route.SpaceUsers
import Session exposing (Session)
import Space exposing (Space)
import SpaceUser exposing (SpaceUser)
import Task exposing (Task)
import TaskHelpers
import Time exposing (Posix, Zone, every)
import View.Helpers exposing (displayName, smartFormatTime, viewIf)
import View.Layout exposing (spaceLayout)



-- MODEL


type alias Model =
    { params : Params
    , viewer : SpaceUser
    , space : Space
    , bookmarks : List Group
    , featuredUsers : List SpaceUser
    , posts : Connection Component.Post.Model
    , now : ( Zone, Posix )
    }



-- PAGE PROPERTIES


title : String
title =
    "Activity"



-- LIFECYCLE


init : Params -> Session -> Task Session.Error ( Session, Model )
init params session =
    session
        |> PostsInit.request params
        |> TaskHelpers.andThenGetCurrentTime
        |> Task.andThen (buildModel params)


buildModel : Params -> ( ( Session, PostsInit.Response ), ( Zone, Posix ) ) -> Task Session.Error ( Session, Model )
buildModel params ( ( session, { viewer, space, bookmarks, featuredUsers, posts } ), now ) =
    Task.succeed ( session, Model params viewer space bookmarks featuredUsers posts now )


setup : Model -> Cmd Msg
setup model =
    let
        postsCmd =
            model.posts
                |> Connection.toList
                |> List.map (\c -> Cmd.map (PostComponentMsg c.id) (Component.Post.setup c))
                |> Cmd.batch
    in
    postsCmd


teardown : Model -> Cmd Msg
teardown model =
    let
        postsCmd =
            model.posts
                |> Connection.toList
                |> List.map (\c -> Cmd.map (PostComponentMsg c.id) (Component.Post.teardown c))
                |> Cmd.batch
    in
    postsCmd



-- UPDATE


type Msg
    = Tick Posix
    | SetCurrentTime Posix Zone
    | PostComponentMsg String Component.Post.Msg
    | NoOp


update : Msg -> Session -> Model -> ( ( Model, Cmd Msg ), Session )
update msg session model =
    case msg of
        Tick posix ->
            ( ( model, Task.perform (SetCurrentTime posix) Time.here ), session )

        SetCurrentTime posix zone ->
            { model | now = ( zone, posix ) }
                |> noCmd session

        PostComponentMsg id componentMsg ->
            case Connection.get .id id model.posts of
                Just component ->
                    let
                        ( ( newComponent, cmd ), newSession ) =
                            Component.Post.update componentMsg (Space.getId model.space) session component
                    in
                    ( ( { model | posts = Connection.update .id newComponent model.posts }
                      , Cmd.map (PostComponentMsg id) cmd
                      )
                    , newSession
                    )

                Nothing ->
                    noCmd session model

        NoOp ->
            noCmd session model


noCmd : Session -> Model -> ( ( Model, Cmd Msg ), Session )
noCmd session model =
    ( ( model, Cmd.none ), session )



-- EVENTS


consumeEvent : Event -> Model -> ( Model, Cmd Msg )
consumeEvent event model =
    case event of
        Event.GroupBookmarked group ->
            ( { model | bookmarks = insertUniqueBy Group.getId group model.bookmarks }, Cmd.none )

        Event.GroupUnbookmarked group ->
            ( { model | bookmarks = removeBy Group.getId group model.bookmarks }, Cmd.none )

        Event.ReplyCreated reply ->
            let
                postId =
                    Reply.getPostId reply
            in
            case Connection.get .id postId model.posts of
                Just component ->
                    let
                        ( newComponent, cmd ) =
                            Component.Post.handleReplyCreated reply component
                    in
                    ( { model | posts = Connection.update .id newComponent model.posts }
                    , Cmd.map (PostComponentMsg postId) cmd
                    )

                Nothing ->
                    ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )



-- SUBSCRIPTIONS


subscriptions : Sub Msg
subscriptions =
    Sub.batch
        [ every 1000 Tick
        ]



-- VIEW


view : Repo -> Maybe Route -> Model -> Html Msg
view repo maybeCurrentRoute model =
    spaceLayout repo
        model.viewer
        model.space
        model.bookmarks
        maybeCurrentRoute
        [ div [ class "mx-56" ]
            [ div [ class "mx-auto max-w-90 leading-normal" ]
                [ div [ class "sticky pin-t border-b mb-3 py-4 bg-white z-50" ]
                    [ div [ class "flex items-center" ]
                        [ h2 [ class "flex-no-shrink font-extrabold text-2xl" ] [ text "Activity" ]
                        , controlsView model
                        ]
                    ]
                , postsView repo model
                , sidebarView repo model.space model.featuredUsers
                ]
            ]
        ]


controlsView : Model -> Html Msg
controlsView model =
    div [ class "flex flex-grow justify-end" ]
        [ paginationView model.space model.posts
        ]


paginationView : Space -> Connection a -> Html Msg
paginationView space connection =
    Pagination.view connection
        (Route.Posts << Before (Space.getSlug space))
        (Route.Posts << After (Space.getSlug space))


postsView : Repo -> Model -> Html Msg
postsView repo model =
    if Connection.isEmptyAndExpanded model.posts then
        div [ class "pt-8 pb-8 text-center text-lg" ]
            [ text "You're all caught up!" ]

    else
        div [] <|
            Connection.mapList (postView repo model) model.posts


postView : Repo -> Model -> Component.Post.Model -> Html Msg
postView repo model component =
    div [ class "py-4" ]
        [ component
            |> Component.Post.view repo model.space model.viewer model.now
            |> Html.map (PostComponentMsg component.id)
        ]


sidebarView : Repo -> Space -> List SpaceUser -> Html Msg
sidebarView repo space featuredUsers =
    div [ class "fixed pin-t pin-r w-56 mt-3 py-2 pl-6 border-l min-h-half" ]
        [ h3 [ class "mb-2 text-base font-extrabold" ]
            [ a
                [ Route.href (Route.SpaceUsers <| Route.SpaceUsers.Root (Space.getSlug space))
                , class "flex items-center text-dusty-blue-darkest no-underline"
                ]
                [ text "Directory"
                ]
            ]
        , div [ class "pb-4" ] <| List.map (userItemView repo) featuredUsers
        , a
            [ Route.href (Route.SpaceSettings (Space.getSlug space))
            , class "text-sm text-blue no-underline"
            ]
            [ text "Space Settings" ]
        ]


userItemView : Repo -> SpaceUser -> Html Msg
userItemView repo user =
    let
        userData =
            user
                |> Repo.getSpaceUser repo
    in
    div [ class "flex items-center pr-4 mb-px" ]
        [ div [ class "flex-no-shrink mr-2" ] [ personAvatar Avatar.Tiny userData ]
        , div [ class "flex-grow text-sm truncate" ] [ text <| displayName userData ]
        ]
