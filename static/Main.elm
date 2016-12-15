port module Main exposing (..)

-- builtins
import Html
import Html.Attributes as Attrs
import Html.Events as Events
import Result
import Char
import Dict exposing (Dict)
import Json.Encode as JSE
import Json.Decode as JSD
import Json.Decode.Pipeline as JSDP

-- lib
import Keyboard
import Mouse
import Dom
import Task
import Http
import Collage
import Element
import Text
import Color


-- mine
import Native.Window
import Native.Timestamp


-- TOP-LEVEL
main : Program Never Model Msg
main = Html.program
       { init = init
       , view = view
       , update = update
       , subscriptions = subscriptions}

consts = { spacer = 5
         , lineHeight = 18
         , paramWidth = 50
         , dotRadius = 5
         , dotWidth = 10
         , dotContainer = 20
         , toolbarOffset = 77
         , letterWidth = 7
         }


-- MODEL
type alias Model = { nodes : NodeDict
                   , cursor : Cursor
                   , inputValue : String
                   , state : State
                   , tempFieldName : String
                   , errors : List String
                   , lastPos : Pos
                   , drag : Drag
                   }

type alias Node = { name : Name
                  , id : ID
                  , pos : Pos
                  , is_datastore : Bool
                  -- for DSes
                  , fields : List (String, String)
                  -- for functions
                  , parameters : List String
                  }

type alias Name = String
type ID = ID String
type alias Pos = {x: Int, y: Int}
type alias NodeDict = Dict Name Node
type alias Cursor = Maybe ID
type Drag = NoDrag
          | Drag ID

type NodeSlot = NSNode Node
              | NSNone

init : ( Model, Cmd Msg )
init = let m = { nodes = Dict.empty
               , cursor = Nothing
               , state = NOTHING
               , errors = [".", "."]
               , inputValue = ""
               , tempFieldName = ""
               , lastPos = {x=-1, y=-1}
               , drag = NoDrag
               }
       in (m, rpc m <| LoadInitialGraph)



-- RPC
type RPC
    = LoadInitialGraph
    | AddDatastore String Pos
    | AddDatastoreField String String
    | AddFunctionCall String Pos
    | UpdatePosition ID

rpc : Model -> RPC -> Cmd Msg
rpc model call =
    let payload = encodeRPC model call
        json = Http.jsonBody payload
        request = Http.post "/admin/api/rpc" json decodeGraph
    in Http.send RPCCallBack request

encodeRPC : Model -> RPC -> JSE.Value
encodeRPC m call =
    let (cmd, args) =
            case call of
                LoadInitialGraph -> ("load_initial_graph", JSE.object [])
                AddDatastore name pos -> ("add_datastore"
                                         , JSE.object [ ("name", JSE.string name)
                                                      , ("x", JSE.int pos.x)
                                                      , ("y", JSE.int pos.y)])
                AddDatastoreField name type_ -> ("add_datastore_field",
                                                 JSE.object [ ("name", JSE.string name)
                                                            , ("type", JSE.string type_)])
                AddFunctionCall name pos -> ("add_function_call",
                                                 JSE.object [ ("name", JSE.string name)
                                                            , ("x", JSE.int pos.x)
                                                            , ("y", JSE.int pos.y)])
                UpdatePosition (ID id) ->
                    case Dict.get id m.nodes of
                        Nothing -> Debug.crash "should never happen"
                        Just node -> ("update_position",
                                          JSE.object [ ("id", JSE.string id)
                                                     , ("x", JSE.int node.pos.x)
                                                     , ("y", JSE.int node.pos.y)])
    in JSE.object [ ("command", JSE.string cmd)
                  , ("args", args)
                  , ("cursor", case m.cursor of
                                   Just (ID id) -> JSE.string id
                                   Nothing -> JSE.string "")]


decodeNode : JSD.Decoder Node
decodeNode =
  let toNode : Name -> String -> List(String,String) -> List String -> Bool -> Int -> Int -> Node
      toNode name id fields parameters is_datastore x y =
          { name = name
          , id = ID id
          , fields = fields
          , parameters = parameters
          , is_datastore = is_datastore
          , pos = {x=x, y=y}
          }
  in JSDP.decode toNode
      |> JSDP.required "name" JSD.string
      |> JSDP.required "id" JSD.string
      |> JSDP.optional "fields" (JSD.keyValuePairs JSD.string) []
      |> JSDP.optional "parameters" (JSD.list JSD.string) []
      |> JSDP.optional "is_datastore" JSD.bool False
      |> JSDP.required "x" JSD.int
      |> JSDP.required "y" JSD.int
      -- |> JSDP.resolve

decodeGraph : JSD.Decoder (NodeDict, Cursor)
decodeGraph =
    let toGraph : NodeDict -> String -> (NodeDict, Cursor)
        toGraph nodes cursor = (nodes, (case cursor of
                                              "" -> Nothing
                                              str -> (Just (ID str))))
    in JSDP.decode toGraph
        -- |> JSDP.required "edges" (JSD.list JSD.string)
        |> JSDP.required "nodes" (JSD.dict decodeNode)
        |> JSDP.required "cursor" JSD.string



-- UPDATE
type Msg
    = MouseDown Mouse.Position
    | DragStart Mouse.Position
    | DragMove ID Mouse.Position
    | DragEnd ID Mouse.Position
    | InputMsg String
    | SubmitMsg
    | KeyMsg Keyboard.KeyCode
    | FocusResult (Result Dom.Error ())
    | RPCCallBack (Result Http.Error (NodeDict, Cursor))

type State
    = NOTHING
    | ADDING_FUNCTION
    | ADDING_DS_NAME
    | ADDING_DS_FIELD_NAME
    | ADDING_DS_FIELD_TYPE

update : Msg -> Model -> (Model, Cmd Msg)
update msg m =
    case (m.state, msg) of
        (_, MouseDown pos) ->
            -- if the mouse is within a node, select the node. Else create a new one.
            case findNode m pos of
                NSNone -> ({ m | state = ADDING_FUNCTION
                               , cursor = Nothing
                               , lastPos = pos
                           }, focusInput)
                NSNode node -> ({ m | state = ADDING_DS_FIELD_NAME
                                    , inputValue = ""
                                    , lastPos = pos
                                    , cursor = Just node.id
                                }, focusInput)

        (_, DragStart pos) ->
            case findNode m pos of
                NSNone -> (m, Cmd.none)
                NSNode node -> ({ m | drag = Drag node.id
                                }, Cmd.none)
        (_, DragMove id pos) ->
            ({ m | nodes = updateDragPosition pos id m.nodes
             }, Cmd.none)
        (_, DragEnd id _) ->
            -- to avoid moving when we just want to select, don't set to mouseUp position
            ({ m | drag = NoDrag
             }, rpc m <| UpdatePosition id)
        (ADDING_FUNCTION, SubmitMsg) ->
            if String.toLower(m.inputValue) == "ds"
            then ({ m | state = ADDING_DS_NAME
                      , inputValue = ""
                  }, focusInput)
            else ({ m | state = NOTHING
                      , inputValue = ""
                  }, Cmd.batch [focusInput, rpc m <| AddFunctionCall m.inputValue m.lastPos])
        (ADDING_DS_NAME, SubmitMsg) ->
            ({ m | state = ADDING_DS_FIELD_NAME
                 , inputValue = ""
             }, Cmd.batch [focusInput, rpc m <| AddDatastore m.inputValue m.lastPos])
        (ADDING_DS_FIELD_NAME, SubmitMsg) ->
            if m.inputValue == ""
            then -- the DS has all its fields
                ({ m | state = NOTHING
                     , inputValue = ""
                 }, Cmd.none)
            else  -- save the field name, we'll submit it later the type
                ({ m | state = ADDING_DS_FIELD_TYPE
                     , inputValue = ""
                     , tempFieldName = m.inputValue
                 }, focusInput)
        (ADDING_DS_FIELD_TYPE, SubmitMsg) ->
            ({ m | state = ADDING_DS_FIELD_NAME
                 , inputValue = ""
             }, Cmd.batch [focusInput, rpc m <| AddDatastoreField m.tempFieldName m.inputValue])

        (_, RPCCallBack (Ok (nodes, cursor))) ->
            ({ m | nodes = nodes
                 , cursor = cursor
             }, Cmd.none)
        (_, RPCCallBack (Err (Http.BadStatus error))) ->
            ({ m | errors = addError ("Bad RPC call: " ++ toString(error.status.message)) m
                 , state = NOTHING
             }, Cmd.none)

        (_, FocusResult (Ok ())) ->
            -- Yay, you focused a field! Ignore.
            ( m, Cmd.none )
        (_, InputMsg target) ->
            -- Syncs the form with the model. The actual submit is in SubmitMsg
            ({ m | inputValue = target
             }, Cmd.none)
        t -> -- All other cases
            ({ m | errors = addError ("Nothing for " ++ (toString t)) m }, Cmd.none )

        -- KeyMsg key -> -- Keyboard input
        --     ({ model | errors = addError "Not supported yet" model}, Cmd.none)




-- SUBSCRIPTIONS
subscriptions : Model -> Sub Msg
subscriptions m =
    let dragSubs = case m.drag of
                       Drag id -> [ Mouse.moves (DragMove id)
                                  , Mouse.ups (DragEnd id)]
                       NoDrag -> []
        standardSubs = [ Mouse.downs MouseDown
                       , Mouse.downs DragStart]
    in Sub.batch
        (List.concat [standardSubs, dragSubs])

--        , Keyboard.downs KeyMsg





-- VIEW
view : Model -> Html.Html Msg
view model =
    Html.div [] [ viewInput model.inputValue
                , viewState model.state
                , viewErrors model.errors
                , viewCanvas model
                ]

viewInput value = Html.div [] [
                   Html.form [
                        Events.onSubmit (SubmitMsg)
                       ] [
                        Html.input [ Attrs.id inputID
                                   , Events.onInput InputMsg
                                   , Attrs.value value
                                   ] []
                       ]
                  ]



viewState state = Html.div [] [ Html.text ("state: " ++ toString state) ]
viewErrors errors = Html.div [] (List.map str2div errors)

viewCanvas : Model -> Html.Html msg
viewCanvas model =
    let (w, h) = windowSize ()
    in Element.toHtml
        (Collage.collage w h
             ([viewClick model.lastPos]
             ++
             viewAllNodes model model.nodes))

viewClick : Pos -> Collage.Form
viewClick pos = Collage.circle 10
                |> Collage.filled Color.lightCharcoal
                |> Collage.move (p2c pos)

viewAllNodes : Model -> Dict String Node -> List Collage.Form
viewAllNodes model nodes = dlMap (viewNode model) nodes

viewNode : Model -> Node -> Collage.Form
viewNode model node =
    let
        color = nodeColor model node
        name = Element.centered (node.name |> Text.fromString |> Text.bold)
        fields = viewFields node.fields
        parameters = viewParameters node.parameters
        entire = Element.flow Element.down [ name
                                           , Element.spacer consts.spacer consts.spacer
                                           , parameters
                                           , fields]
        (w, h) = Element.sizeOf entire
        box = Collage.rect (toFloat w) (toFloat h)
                     |> Collage.filled color
        group = Collage.group [ box
                              , Collage.toForm entire]
    in Collage.move (p2c node.pos) group

nodeColor : Model -> Node -> Color.Color
nodeColor m node = if (Drag node.id) == m.drag
                   then Color.lightRed
                   else if (Just node.id) == m.cursor
                        then Color.lightGreen
                        else Color.lightGrey

viewFields fields =
    Element.flow Element.down (List.map viewField fields)

viewField (name, type_) =
    (Element.flow
        Element.right
         [ Element.container
               consts.paramWidth consts.lineHeight
               Element.midLeft
                   (Element.leftAligned (Text.fromString name))
         , Element.container
               consts.paramWidth consts.lineHeight
               Element.midRight
                   (Element.rightAligned (Text.fromString type_))])

viewParameters parameters =
    Element.flow Element.down (List.map viewParameter parameters)

viewDot =
    Collage.collage
        consts.dotWidth
        consts.dotContainer
        [Collage.filled Color.red
             (Collage.circle consts.dotRadius)]

viewParameter name =
    Element.flow
        Element.right
            [ viewDot
            , Element.container consts.paramWidth consts.lineHeight
                Element.midLeft (Element.leftAligned (Text.fromString name))]




-- UTIL


timestamp : () -> Int
timestamp a = Native.Timestamp.timestamp a

windowSize : () -> (Int, Int)
windowSize a = let size = Native.Window.size a
               in (size.width, size.height)

inputID = "darkInput"
focusInput = Dom.focus inputID |> Task.attempt FocusResult

addError error model =
    let time = timestamp ()
               in
    List.take 2 ((error ++ "-" ++ toString time) :: model.errors)

str2div str = Html.div [] [Html.text str]


p2c : Pos  -> (Float, Float)
p2c pos = let (w, h) = windowSize ()
          in (toFloat pos.x - toFloat w / 2,
              toFloat h / 2 - toFloat pos.y + consts.toolbarOffset)

withinNode : Node -> Mouse.Position -> Bool
withinNode node pos =
    let height = nodeHeight node
        width = nodeWidth node
    in node.pos.x >= pos.x - (width // 2)
    && node.pos.x <= pos.x + (width // 2)
    && node.pos.y >= pos.y - (height // 2)
    && node.pos.y <= pos.y + (height // 2)

nodeWidth node =
    if node.is_datastore
    then 2 * consts.paramWidth
    else max consts.paramWidth (consts.letterWidth * String.length(node.name))

nodeHeight node =
    consts.spacer + consts.lineHeight * (1 + List.length node.parameters + List.length node.fields)

-- If the click is on a slot, return the slot. Else return the node.
slotOrNode : Node -> Pos -> NodeSlot
slotOrNode node pos = NSNode node
    -- we clicked on a slot if we're on the left edge, below the spacer.
    -- let leftEdge = node.pos.x - consts.param
        -- isLeftEdge = node.pos.x - node.

findNode : Model -> Mouse.Position -> NodeSlot
findNode model pos =
    let nodes = Dict.values model.nodes
        candidates = List.filter (\n -> withinNode n pos) nodes
        distances = List.map
                    (\n -> (n, abs (pos.x - n.pos.x) + abs (pos.y - n.pos.y)))
                    candidates
        sorted = List.sortBy (\(n, dist) -> dist) distances
        winner = List.head sorted
    in case winner of
           Just (node, _) -> slotOrNode node pos
           Nothing -> NSNone

dlMap : (b -> c) -> Dict comparable b -> List c
dlMap fn d = List.map fn (Dict.values d)

updateDragPosition : Pos -> ID -> NodeDict -> NodeDict
updateDragPosition pos (ID id) nodes =
    Dict.update id (Maybe.map (\n -> {n | pos = pos})) nodes
