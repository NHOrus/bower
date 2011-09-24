%-----------------------------------------------------------------------------%

:- module callout.
:- interface.

:- import_module io.
:- import_module list.

:- import_module data.
:- import_module json.

%-----------------------------------------------------------------------------%

:- pred get_notmuch_config(string::in, io.res(string)::out, io::di, io::uo)
    is det.

:- pred run_notmuch(list(string)::in, pred(json, T)::in(pred(in, out) is det),
    T::out, io::di, io::uo) is det.

:- pred parse_messages_list(json::in, list(message)::out) is det.

:- pred parse_top_message(json::in, message::out) is det.

:- pred parse_threads_list(json::in, list(thread)::out) is det.

:- pred parse_message_id_list(json::in, list(message_id)::out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module cord.
:- import_module map.
:- import_module maybe.
:- import_module parsing_utils.
:- import_module require.
:- import_module string.

:- import_module popen.
:- import_module quote_arg.

%-----------------------------------------------------------------------------%

get_notmuch_config(Key, Res, !IO) :-
    popen("notmuch config get " ++ Key, Res0, !IO),
    (
        Res0 = ok(Value0),
        Value = string.strip(Value0),
        Res = ok(Value)
    ;
        Res0 = error(_),
        Res = Res0
    ).

%-----------------------------------------------------------------------------%

run_notmuch(Args, P, Result, !IO) :-
    args_to_quoted_command(["notmuch" | Args], Command),
    popen(Command, CommandResult, !IO),
    (
        CommandResult = ok(String),
        parse_json(String, ParseResult),
        (
            ParseResult = ok(JSON),
            P(JSON, Result)
        ;
            ParseResult = error(_, _, _),
            error(string(ParseResult))
        )
    ;
        CommandResult = error(_),
        error(string(CommandResult))
    ).

%-----------------------------------------------------------------------------%

parse_messages_list(JSON, Messages) :-
    ( JSON = array([List]) ->
        parse_inner_message_list(List, Messages)
    ; JSON = array([]) ->
        Messages = []
    ;
        notmuch_json_error
    ).

parse_top_message(JSON, Message) :-
    parse_message_details(JSON, [], Message).

:- pred parse_inner_message_list(json::in, list(message)::out) is det.

parse_inner_message_list(JSON, Messages) :-
    ( JSON = array(Array) ->
        list.map(parse_message, Array, Messages)
    ;
        notmuch_json_error
    ).

:- pred parse_message(json::in, message::out) is det.

parse_message(JSON, Message) :-
    ( JSON = array([JSON1, JSON2]) ->
        parse_inner_message_list(JSON2, Replies),
        parse_message_details(JSON1, Replies, Message)
    ;
        notmuch_json_error
    ).

:- pred parse_message_details(json::in, list(message)::in, message::out) is det.

parse_message_details(JSON, Replies, Message) :-
    (
        JSON/"id" = unesc_string(Id),
        MessageId = message_id(Id),
        JSON/"timestamp" = int(Timestamp),
        JSON/"headers" = map(HeaderMap),
        map.foldl(parse_header, HeaderMap, init_headers, Headers),
        JSON/"tags" = array(TagsList),
        list.map(parse_tag, TagsList, Tags),
        JSON/"body" = array(BodyList),
        list.foldl(parse_content(MessageId), BodyList, cord.init, Body)
    ->
        Message = message(MessageId, Timestamp, Headers, Tags, Body, Replies)
    ;
        notmuch_json_error
    ).

:- pred parse_header(key::in, json::in, headers::in, headers::out) is semidet.

parse_header(Key, unesc_string(Value), !Headers) :-
    ( Key = "Date" ->
        !Headers ^ h_date := Value
    ; Key = "From" ->
        !Headers ^ h_from := Value
    ; Key = "To" ->
        !Headers ^ h_to := Value
    ; Key = "Cc" ->
        !Headers ^ h_cc := Value
    ; Key = "Bcc" ->
        !Headers ^ h_bcc := Value
    ; Key = "Subject" ->
        !Headers ^ h_subject := Value
    ; Key = "Reply-To" ->
        !Headers ^ h_replyto := Value
    ; Key = "References" ->
        !Headers ^ h_references := Value
    ; Key = "In-Reply-To" ->
        !Headers ^ h_inreplyto := Value
    ;
        Rest0 = !.Headers ^ h_rest,
        map.insert(Key, Value, Rest0, Rest),
        !Headers ^ h_rest := Rest
    ).

:- pred parse_content(message_id::in, json::in,
    cord(content)::in, cord(content)::out) is det.

parse_content(MessageId, JSON, !Contents) :-
    (
        JSON/"id" = int(Part),
        JSON/"content-type" = unesc_string(ContentType)
    ->
        ( JSON/"filename" = unesc_string(Filename) ->
            MaybeFilename = yes(Filename)
        ;
            MaybeFilename = no
        ),
        ( JSON/"content" = unesc_string(ContentString) ->
            Content = content(MessageId, Part, ContentType, yes(ContentString),
                MaybeFilename),
            snoc(Content, !Contents)
        ; JSON/"content" = array(SubParts) ->
            list.foldl(parse_content(MessageId), SubParts, !Contents)
        ;
            % "content" is unavailable for non-text parts.
            % We can those by running notmuch show --part=N id:NNN
            Content = content(MessageId, Part, ContentType, no, MaybeFilename),
            snoc(Content, !Contents)
        )
    ;
        notmuch_json_error
    ).

%-----------------------------------------------------------------------------%

parse_threads_list(Json, Threads) :-
    ( Json = array(List) ->
        list.map(parse_thread, List, Threads)
    ;
        notmuch_json_error
    ).

:- pred parse_thread(json::in, thread::out) is det.

parse_thread(Json, Thread) :-
    (
        Json/"thread" = unesc_string(Id),
        Json/"timestamp" = int(Timestamp),
        Json/"authors" = unesc_string(Authors),
        Json/"subject" = unesc_string(Subject),
        Json/"tags" = array(TagsList),
        Json/"matched" = int(Matched),
        Json/"total" = int(Total),
        list.map(parse_tag, TagsList, Tags)
    ->
        Thread = thread(thread_id(Id), Timestamp, Authors, Subject, Tags,
            Matched, Total)
    ;
        notmuch_json_error
    ).

:- pred parse_tag(json::in, string::out) is semidet.

parse_tag(Json, Tag) :-
    Json = unesc_string(Tag).

%-----------------------------------------------------------------------------%

parse_message_id_list(JSON, MessageId) :-
    (
        JSON = array(List),
        list.map(parse_message_id, List, MessageId0)
    ->
        MessageId = MessageId0
    ;
        notmuch_json_error
    ).

:- pred parse_message_id(json::in, message_id::out) is semidet.

parse_message_id(unesc_string(Id), message_id(Id)).

%-----------------------------------------------------------------------------%

:- func json / string = json is semidet.

map(Map) / Key = Value :-
    map.search(Map, Key, Value).

:- func unesc_string(string::out) = (json::in) is semidet.

unesc_string(unescape(EscString)) = string(EscString).

:- pred notmuch_json_error is erroneous.

notmuch_json_error :-
    error("notmuch_json_error").

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sts=4 sw=4 et
