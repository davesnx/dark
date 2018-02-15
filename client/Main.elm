port module Main exposing (..)


-- builtins
import Maybe

-- lib
import Json.Decode as JSD
import Http
import Keyboard.Event
import Keyboard.Key as Key
import Navigation
import Mouse
import List.Extra as LE

-- dark
import RPC exposing (rpc, saveTest, integrationRpc)
import Types exposing (..)
import View
import Clipboard
import Defaults
import Runtime as RT
import Entry
import Autocomplete as AC
import Viewport
import Window.Events exposing (onWindow)
import VariantTesting exposing (parseVariantTestsFromQueryString)
import Util
import Pointer as P
import AST
import Selection
import Runtime
import Toplevel as TL
import Analysis
import Util exposing (deMaybe)
import IntegrationTest


-----------------------
-- TOP-LEVEL
-----------------------
main : Program Flags Model Msg
main = Navigation.programWithFlags
         LocationChange
         { init = init
         , view = View.view
         , update = update
         , subscriptions = subscriptions}


-----------------------
-- MODEL
-----------------------
parseLocation : Navigation.Location -> Maybe Pos
parseLocation loc =
      let removeHash = String.dropLeft 1 loc.hash -- remove "#"
      in
          case String.split "&" removeHash of -- split on delimiter
            [xpart, ypart] ->
              let trimmedx = String.dropLeft 1 xpart -- remove 'X'
                  trimmedy = String.dropLeft 1 ypart -- remove 'Y'
              in
                  case String.toInt trimmedx of
                    Err _ -> Nothing
                    Ok x ->
                      case String.toInt trimmedy of
                        Err _ -> Nothing
                        Ok y ->
                          let newPosition = { x = x, y = y }
                          in
                              Just newPosition
            _ -> Nothing

flag2function : FlagFunction -> Function
flag2function fn =
  { name = fn.name
  , description = fn.description
  , returnTipe = RT.str2tipe fn.return_type
  , parameters = List.map (\p -> { name = p.name
                                 , tipe = RT.str2tipe p.tipe
                                 , block_args = p.block_args
                                 , optional = p.optional
                                 , description = p.description}) fn.parameters
  , infix = fn.infix
  }

init : Flags -> Navigation.Location -> ( Model, Cmd Msg )
init {editorState, complete} location =
  let editor = case editorState of
            Just e -> e
            Nothing -> Defaults.defaultEditor
      tests = case parseVariantTestsFromQueryString location.search of
                  Just t  -> t
                  Nothing -> []
      m = Defaults.defaultModel editor
      center =
        case parseLocation location of
          Nothing -> m.center
          Just c -> c
      m2 = { m | complete = AC.init (List.map flag2function complete)
               , tests = tests
               , toplevels = []
               , center = center
           }
      shouldRunIntegrationTest =
        "/admin/integration_test" == location.pathname
      integrationTestName = String.dropRight 10 location.hostname
  in
    if shouldRunIntegrationTest
    then m2 ! [integrationRpc m integrationTestName]
    else m2 ! [rpc m FocusNothing []]


-----------------------
-- ports, save Editor state in LocalStorage
-----------------------
port setStorage : Editor -> Cmd a

-----------------------
-- updates
-----------------------

replaceToplevel : Model -> Toplevel -> Model
replaceToplevel m tl =
  let newToplevels = m
                     |> .toplevels
                     |> List.filter (\this_tl -> this_tl.id /= tl.id)
                     |> List.append [tl]
  in { m | toplevels = newToplevels }

processFocus : Model -> Focus -> Modification
processFocus m focus =
  case focus of
    FocusNext tlid pred ->
      let tl = TL.getTL m tlid
          next = TL.getNextBlank tl pred in
      case next of
        Just p -> Enter (Filling tlid p)
        Nothing -> Select tlid Nothing
    FocusExact tlid p ->
      case p of
        PFilled _ _ -> Select tlid (Just p)
        PBlank _ _ -> Enter (Filling tlid p)
    Refocus tlid ->
      Select tlid Nothing
    FocusFirstAST tlid ->
      let tl = TL.getTL m tlid
          next = TL.getFirstASTBlank tl in
      case next of
        Just p -> Enter (Filling tlid p)
        Nothing -> Select tlid Nothing
    FocusSame ->
      case unwrapState m.state of
        Selecting tlid mp ->
          case mp of
            Just p ->
              let tl = TL.getTL m tlid in
              if TL.isValidPointer tl p then
                NoChange
              else
                Deselect
            Nothing ->
              NoChange
        Entering (Filling tlid p) ->
          let tl = TL.getTL m tlid in
          if TL.isValidPointer tl p then
            NoChange
          else
            Deselect
        _ -> NoChange
    FocusNothing -> Deselect


update : Msg -> Model -> (Model, Cmd Msg)
update msg m =
  let mods = update_ msg m
      (newm, newc) = updateMod mods (m, Cmd.none)
  in
    ({ newm | lastMsg = msg
            , lastMod = mods}
     , Cmd.batch [newc, m |> Defaults.model2editor |> setStorage])

updateMod : Modification -> (Model, Cmd Msg) -> (Model, Cmd Msg)
updateMod mod (m, cmd) =
  let _ = if m.integrationTestState /= NoIntegrationTest
          then Debug.log "mod update" mod
          else mod
      closeThreads newM =
        -- close open threads in the previous TL
        m.state
        |> tlidOf
        |> Maybe.map (\tlid ->
            let tl = TL.getTL m tlid in
            case tl.data of
              TLHandler h ->
                let replacement = AST.closeThread h.ast in
                if replacement == h.ast
                then []
                else
                  let tl = TL.getTL m tlid
                      newH = { h | ast = replacement }
                      calls = [ SetHandler tl.id tl.pos newH]
                  -- call RPC on the new model
                  in [rpc newM FocusSame calls]
              _ -> [])
        |> Maybe.withDefault []
        |> \rpc -> if tlidOf newM.state == tlidOf m.state
                   then []
                   else rpc
  in
  let (newm, newcmd) =
    case mod of
      Error e -> { m | error = Just e} ! []
      ClearError -> { m | error = Nothing} ! []

      RPC (calls, focus) ->
        -- immediately update the model based on SetHandler and focus, if
        -- possible
        let hasNonHandlers =
              List.any (\c -> case c of
                                SetHandler _ _ _ ->
                                  False
                                _ -> True) calls

        in if hasNonHandlers
           then
             m ! [rpc m focus calls]
           else
             let localM =
                   List.foldl (\call m ->
                     case call of
                       SetHandler tlid pos h ->
                         replaceToplevel m
                           {id = tlid, pos = pos, data = TLHandler h }
                       _ -> m) m calls

                 (withFocus, wfCmd) =
                   updateMod (Many [ AutocompleteMod ACReset
                                   , processFocus localM focus
                                   ])
                             (localM, Cmd.none)
              in withFocus ! [wfCmd, rpc m focus calls]

      NoChange -> m ! []
      TriggerIntegrationTest name ->
        let expect = IntegrationTest.trigger name in
        { m | integrationTestState = expect } ! []
      EndIntegrationTest ->
        let expectationFn =
            case m.integrationTestState of
              IntegrationTestExpectation fn -> fn
              IntegrationTestFinished _ ->
                Debug.crash "Attempted to end integration test but one ran + was already finished"
              NoIntegrationTest ->
                Debug.crash "Attempted to end integration test but none was running"
            result = expectationFn m
        in
        { m | integrationTestState = IntegrationTestFinished result } ! []

      MakeCmd cmd -> m ! [cmd]
      SetState state ->
        -- DOES NOT RECALCULATE VIEW
        { m | state = state } ! []

      Select tlid p ->
        let newM = { m | state = Selecting tlid p } in
        newM ! closeThreads newM

      Deselect ->
        let newM = { m | state = Deselected }
        in newM ! (closeThreads newM)

      Enter entry ->
        let varnames =
              case entry of
                Creating _ -> m.globals
                Filling tlid p ->
                  Analysis.getAvailableVarnames m tlid (P.idOf p)
            showFunctions =
              case entry of
                Creating _ -> True
                Filling tlid p -> P.typeOf p == Expr
            lv =
              case entry of
                Creating _ -> Nothing
                Filling tlid p ->
                  let tl = TL.getTL m tlid in
                  let obj =
                    case P.typeOf p of
                      Expr ->
                        let handler = deMaybe "handler - expr" <| TL.asHandler tl
                            parent = AST.parentOf_ (P.idOf p) handler.ast in
                        case parent of
                          Just (Thread _ exprs) ->
                            let ids = List.map AST.toP exprs in
                            ids
                            |> LE.elemIndex p
                            |> Maybe.map (\x -> x - 1)
                            |> Maybe.andThen (\i -> LE.getAt i ids)
                          _ ->
                            Nothing

                      Field ->
                        let handler = deMaybe "handler - field" <| TL.asHandler tl
                            parent = AST.parentOf (P.idOf p) handler.ast in
                        case parent of
                          FieldAccess id obj _ ->
                            Just <| AST.toP obj
                          _ ->
                            Nothing
                      _ ->
                        Nothing
                  in
                  obj
                  |> Maybe.map P.idOf
                  |> Maybe.andThen (Analysis.getLiveValue m tlid)
                  -- don't filter on incomplete values
                  |> Maybe.andThen (\lv -> if lv.tipe == TIncomplete
                                           then Nothing
                                           else Just lv)
            extras =
              case entry of
                Creating _ -> []
                Filling tlid p ->
                  case P.typeOf p of
                    HTTPVerb ->
                      [ "GET"
                      , "POST"
                      , "PUT"
                      , "DELETE"
                      , "PATCH"
                      ]
                    DBColType ->
                      [ "String"
                      , "Int"
                      , "Boolean"
                      , "Float"
                      , "Title"
                      , "Url"
                      , "Date"
                      ]
                    _ -> []

            (complete, acCmd) =
              processAutocompleteMods m [ ACSetAvailableVarnames varnames
                                        , ACShowFunctions showFunctions
                                        , ACSetExtras extras
                                        , ACFilterByLiveValue lv
                                        ]
            newM = { m | state = Entering entry, complete = complete }
        in
        newM ! (closeThreads newM ++ [acCmd, Entry.focusEntry])


      SetToplevels tls tlars globals ->
        { m | toplevels = tls
            , analysis = tlars
            , globals = globals
        } ! []

      SetCenter c ->
        { m | center = c } ! []
      CopyToClipboard clipboard ->
        { m | clipboard = clipboard } ! []
      Drag tlid offset hasMoved state ->
        { m | state = Dragging tlid offset hasMoved state } ! []
      AutocompleteMod mod ->
        let (complete, cmd) = processAutocompleteMods m [mod]
        in ({ m | complete = complete }
            , cmd)
      -- applied from left to right
      Many mods -> List.foldl updateMod (m, Cmd.none) mods
  in
    (newm, Cmd.batch [cmd, newcmd])

processAutocompleteMods : Model -> List AutocompleteMod -> (Autocomplete, Cmd Msg)
processAutocompleteMods m mods =
  let complete = List.foldl
        (\mod complete -> AC.update mod complete)
        m.complete
        mods
  in (complete, AC.focusItem complete.index)

-- Figure out from the string and the state whether this '.' means field
-- access.
isFieldAccessDot : State -> String -> Bool
isFieldAccessDot state baseStr =
  -- We know from the fact that this function is called that there has
  -- been a '.' entered. However, it might not be in baseStr, so
  -- canonicalize it first.
  let str = Util.replace "\\.*$" "" baseStr
      intOrString = String.startsWith "\"" str || Runtime.isInt str
  in
  case state of
    Entering (Creating _) -> not intOrString
    Entering (Filling tlid p) ->
      (P.typeOf p == Expr
       || P.typeOf p == Field)
      && not intOrString
    _ -> False

update_ : Msg -> Model -> Modification
update_ msg m =
  let _ = if m.integrationTestState /= NoIntegrationTest
          then Debug.log "msg update" msg
          else msg in
  case (msg, m.state) of

    (GlobalKeyPress event, state) ->
      if event.ctrlKey && (event.keyCode == Key.Z || event.keyCode == Key.Y)
      then
        case event.keyCode of
          Key.Z -> RPC ([Undo], FocusSame)
          Key.Y -> RPC ([Redo], FocusSame)
          _ -> NoChange
      else
        case state of
          Selecting tlid p ->
            case event.keyCode of
              Key.Delete ->
                case p of
                  Nothing ->
                    Many [ RPC ([DeleteTL tlid], FocusNothing), Deselect ]
                  Just i -> Selection.delete m tlid i
              Key.Backspace ->
                case p of
                  Nothing ->
                    Many [ RPC ([DeleteTL tlid], FocusNothing), Deselect ]
                  Just i -> Selection.delete m tlid i
              Key.Escape ->
                case p of
                  -- if we're selecting an expression,
                  -- go 'up' to selecting the toplevel only
                  Just p ->
                    Select tlid Nothing
                  -- if we're selecting a toplevel only, deselect.
                  Nothing ->
                    Deselect
              Key.Enter ->
                if event.shiftKey
                then
                  let tl = TL.getTL m tlid in
                  case tl.data of
                    TLDB _ ->
                      RPC ([ AddDBCol tlid (gid ()) (gid ())]
                          , FocusNext tlid Nothing)
                    TLHandler h ->
                      case p of
                        Just p ->
                          let replacement = AST.addThreadHole (P.idOf p) h.ast in
                          RPC ( [ SetHandler tl.id tl.pos { h | ast = replacement}]
                              , FocusNext tlid Nothing)
                        Nothing -> NoChange
                else
                  case p of
                    Just i -> Selection.enter m tlid i
                    Nothing -> Selection.selectDownLevel m tlid p
              Key.Up -> Selection.selectUpLevel m tlid p
              Key.Down -> Selection.selectDownLevel m tlid p
              Key.Right -> Selection.selectNextSibling m tlid p
              Key.Left -> Selection.selectPreviousSibling m tlid p
              Key.Tab ->
                case p of
                  Just pp ->
                    if event.shiftKey
                    then Selection.selectPrevBlank m tlid p
                    else Selection.selectNextBlank m tlid p
                  Nothing ->
                    if event.shiftKey
                    then Selection.selectPrevToplevel m (Just tlid)
                    else Selection.selectNextToplevel m (Just tlid)
              Key.O ->
                if event.ctrlKey
                then Selection.selectUpLevel m tlid p
                else NoChange
              Key.I ->
                if event.ctrlKey
                then Selection.selectDownLevel m tlid p
                else NoChange
              Key.N ->
                if event.ctrlKey
                then Selection.selectNextSibling m tlid p
                else NoChange
              Key.P ->
                if event.ctrlKey
                then Selection.selectPreviousSibling m tlid p
                else NoChange
              Key.C ->
                if event.ctrlKey
                then
                  let tl = TL.getTL m tlid
                  in
                      Clipboard.copy m tl p
                else NoChange
              Key.V ->
                if event.ctrlKey
                then
                  let tl = TL.getTL m tlid in
                  case p of
                    Nothing ->
                      case TL.rootOf tl of
                        Just i -> Clipboard.paste m tl i
                        Nothing -> NoChange
                    Just i ->
                      Clipboard.paste m tl i
                else NoChange
              Key.X ->
                if event.ctrlKey
                then
                  case p of
                    Nothing -> NoChange
                    Just i ->
                      let tl = TL.getTL m tlid in
                      Clipboard.cut m tl i
                else NoChange
              _ -> NoChange

          Entering cursor ->
            if event.ctrlKey
            then
              case event.keyCode of
                Key.P -> AutocompleteMod ACSelectUp
                Key.N -> AutocompleteMod ACSelectDown
                Key.V ->
                  case cursor of
                    Creating pos -> Clipboard.newFromClipboard m pos
                    Filling tlid p ->
                      let tl = TL.getTL m tlid in
                      Clipboard.paste m tl p
                Key.Enter ->
                  if AC.isLargeStringEntry m.complete
                  then Entry.submit m cursor Entry.ContinueThread m.complete.value
                  else if AC.isSmallStringEntry m.complete
                  then
                    Many [ AutocompleteMod (ACAppendQuery "\n")
                         , MakeCmd Entry.focusEntry
                         ]
                  else NoChange
                _ -> NoChange
            else if event.shiftKey && event.keyCode == Key.Enter
            then
              case cursor of
                Filling tlid p ->
                  let tl = TL.getTL m tlid in
                  case tl.data of
                    TLDB _ -> NoChange
                    TLHandler h ->
                      let name = AC.getValue m.complete
                      in Entry.submit m cursor Entry.StartThread name
                Creating _ ->
                  let name = AC.getValue m.complete
                  in Entry.submit m cursor Entry.StartThread name
            else
              case event.keyCode of
                Key.Spacebar ->

                  -- if we're trying to create a database via our magic
                  -- incantation, then we should be able to do that without
                  -- submitting
                  if String.startsWith "DB" m.complete.value
                  || m.complete.value == "="
                  || AC.isStringEntry m.complete
                  then
                    -- TODO: appending isnt right when we're editing, we want
                    -- to put this wherever the cursor is. We need to allow the
                    -- inputbox to do it's thing.
                    AutocompleteMod <| ACAppendQuery " "
                  else
                    let name = AC.getValue m.complete
                    in Entry.submit m cursor Entry.ContinueThread name

                Key.Enter ->
                  if AC.isLargeStringEntry m.complete
                  then AutocompleteMod (ACSetQuery m.complete.value)
                  else
                    let name = AC.getValue m.complete
                    in Entry.submit m cursor Entry.ContinueThread name

                Key.Tab ->
                  case cursor of
                    Filling tlid p ->
                      if event.shiftKey
                      then
                        Selection.enterPrevBlank m tlid (Just p)
                      else
                        Selection.enterNextBlank m tlid (Just p)
                    Creating _ ->
                      NoChange

                Key.Unknown c ->
                  if event.key == Just "."
                  && isFieldAccessDot m.state m.complete.value
                  then
                    let name = AC.getValue m.complete
                    in Entry.submit m cursor Entry.ContinueThread (name ++ ".")
                  else NoChange

                Key.Escape ->
                  case cursor of
                    Creating _ -> Many [Deselect, AutocompleteMod ACReset]
                    Filling tlid p ->
                      let tl = TL.getTL m tlid in
                        case tl.data of
                          TLHandler h ->
                            let replacement = AST.closeThread h.ast in
                            if replacement == h.ast
                            then
                              Many [ Select tlid (Just p)
                                   , AutocompleteMod ACReset]
                            else
                              RPC ( [ SetHandler tl.id tl.pos { h | ast = replacement}]
                                  , FocusNext tl.id Nothing)
                          _ ->
                            Many [ Select tlid (Just p)
                                 , AutocompleteMod ACReset]

                Key.Up -> AutocompleteMod ACSelectUp
                Key.Down -> AutocompleteMod ACSelectDown
                Key.Right ->
                  let sp = AC.sharedPrefix m.complete in
                  if sp == "" then NoChange
                  else
                    AutocompleteMod <| ACSetQuery sp

                key ->
                  NoChange


          Deselected ->
            case event.keyCode of
              Key.Enter -> Entry.createFindSpace m
              Key.Up -> Viewport.moveUp m.center
              Key.Down -> Viewport.moveDown m.center
              Key.Left -> Viewport.moveLeft m.center
              Key.Right -> Viewport.moveRight m.center
              Key.Tab -> Selection.selectNextToplevel m Nothing
              _ -> NoChange

          Dragging _ _ _ _ -> NoChange


    ------------------------
    -- entry node
    ------------------------
    (EntryInputMsg target, _) ->
      -- There are functions to convert strings to and from quoted
      -- strings, but they don't get to run until later, so hack
      -- around the problem here.
      let query = if target == "\""
                  then "\"\""
                  else target in
      -- don't process the autocomplete for '.', as nothing will match
      -- and it will reset the order, losing our spot. The '.' will be
      -- processed by
      if String.endsWith "." query
      && isFieldAccessDot m.state query
      then
        NoChange
      else
        Many [ AutocompleteMod <| ACSetQuery query
             , MakeCmd Entry.focusEntry
             ]

    (EntrySubmitMsg, _) ->
      NoChange -- just keep this here to prevent the page from loading


    ------------------------
    -- mouse
    ------------------------

    -- The interaction between the different mouse states is a little
    -- tricky. We use stopPropagating a lot of ensure the interactions
    -- work, but also combine multiple interactions into single
    -- handlers to make it easier to choose between the desired
    -- interactions (esp ToplevelClickUp)

    (GlobalClick event, _) ->
      if event.button == Defaults.leftButton
      then Many [ AutocompleteMod ACReset
                , Enter (Creating (Viewport.toAbsolute m event.pos))]
      else NoChange


    (AutocompleteClick value, state) ->
      case unwrapState m.state of
        Entering cursor ->
          Entry.submit m cursor Entry.ContinueThread value
        _ -> NoChange


    ------------------------
    -- dragging
    ------------------------
    (ToplevelClickDown tl event, _) ->
      if event.button == Defaults.leftButton
      then Drag tl.id event.pos False m.state
      else NoChange

    (DragToplevel id mousePos, _) ->
      case m.state of
        Dragging tlid startVPos _ origState ->
          let xDiff = mousePos.x-startVPos.vx
              yDiff = mousePos.y-startVPos.vy
              m2 = TL.move tlid xDiff yDiff m in
          Many [ SetToplevels m2.toplevels m2.analysis m2.globals
               , Drag tlid {vx=mousePos.x, vy=mousePos.y} True origState ]
        _ -> NoChange

    (ToplevelClickUp tlid mPointer event, _) ->
      if event.button == Defaults.leftButton
      then
        case m.state of
          Dragging tlid startVPos hasMoved origState ->
            let xDiff = event.pos.vx-startVPos.vx
                yDiff = event.pos.vy-startVPos.vy
                m2 = TL.move tlid xDiff yDiff m
                tl = TL.getTL m2 tlid
            in
            if hasMoved
            then Many
                  [ SetState origState
                  , RPC ([MoveTL tl.id tl.pos], FocusSame)]
            -- this is where we select toplevels
            else Select tlid mPointer
          _ ->
            -- if we stopPropagative the TopleveClickDown
            NoChange
      else NoChange


    -----------------
    -- Buttons
    -----------------
    (ClearGraph, _) ->
      Many [ RPC ([DeleteAll], FocusNothing), Deselect]

    (SaveTestButton, _) ->
      MakeCmd saveTest

    (FinishIntegrationTest, _) ->
      EndIntegrationTest

    -----------------
    -- URL stuff
    -----------------
    (NavigateTo url, _) ->
      MakeCmd (Navigation.newUrl url)

    (RPCCallBack focus extraMod calls (Ok (toplevels, analysis, globals)), _) ->
      let m2 = { m | toplevels = toplevels }
          newState = processFocus m2 focus
      -- TODO: can make this much faster by only receiving things that have
      -- been updated
      in Many [ SetToplevels toplevels analysis globals
              , AutocompleteMod ACReset
              , ClearError
              , newState
              , extraMod -- for testing, maybe more
              ]

    (SaveTestCallBack (Ok msg), _) ->
      Error <| "Success! " ++ msg


    ------------------------
    -- plumbing
    ------------------------
    (RPCCallBack _ _ _ (Err (Http.BadStatus error)), _) ->
      Error <| "Error: " ++ error.body

    (RPCCallBack _ _ _ (Err (Http.NetworkError)), _) ->
      Error <| "Network error: is the server running?"

    (SaveTestCallBack (Err err), _) ->
      Error <| "Error: " ++ (toString err)

    (FocusEntry _, _) ->
      NoChange

    (NothingClick _, _) ->
      NoChange

    (FocusAutocompleteItem _, _) ->
      NoChange

    (LocationChange loc, _) ->
      case (parseLocation loc) of
        Nothing -> NoChange
        Just c -> SetCenter c

    t -> Error <| "Dark Client Error: nothing for " ++ (toString t)


-----------------------
-- SUBSCRIPTIONS
-----------------------
subscriptions : Model -> Sub Msg
subscriptions m =
  let keySubs =
        [onWindow "keydown"
           (JSD.map GlobalKeyPress Keyboard.Event.decodeKeyboardEvent)]
      dragSubs =
        case m.state of
          -- we use IDs here because the node will change
          -- before they're triggered
          Dragging id offset _ _ ->
            [ Mouse.moves (DragToplevel id)]
          _ -> []
  in Sub.batch
    (List.concat [keySubs, dragSubs])


