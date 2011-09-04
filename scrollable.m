%-----------------------------------------------------------------------------%

:- module scrollable.
:- interface.

:- import_module bool.
:- import_module io.
:- import_module list.

:- import_module curs.
:- import_module curs.panel.

%-----------------------------------------------------------------------------%

:- type scrollable(T).

:- typeclass line(T) where [
    pred draw_line(panel::in, T::in, bool::in, io::di, io::uo) is det
].

:- func init(list(T)) = scrollable(T).

:- func init_with_cursor(list(T), int) = scrollable(T).

:- func get_lines(scrollable(T)) = list(T).

:- func get_num_lines(scrollable(T)) = int.

:- func get_top(scrollable(T)) = int.

:- pred set_top(int::in, scrollable(T)::in, scrollable(T)::out) is det.

:- pred get_cursor(scrollable(T)::in, int::out) is semidet.

:- pred set_cursor_centred(int::in, int::in,
    scrollable(T)::in, scrollable(T)::out) is det.

:- pred get_cursor_line(scrollable(T)::in, int::out, T::out) is semidet.

:- pred set_cursor_line(T::in, scrollable(T)::in, scrollable(T)::out) is det.

:- pred scroll(int::in, int::in, bool::out,
    scrollable(T)::in, scrollable(T)::out) is det.

:- pred move_cursor(int::in, int::in, bool::out,
    scrollable(T)::in, scrollable(T)::out) is det.

:- pred search_forward(pred(T)::in(pred(in) is semidet),
    scrollable(T)::in, int::in, int::out, T::out) is semidet.

:- pred search_reverse(pred(T)::in(pred(in) is semidet),
    scrollable(T)::in, int::in, int::out) is semidet.

:- pred draw(list(panel)::in, scrollable(T)::in, io::di, io::uo) is det
    <= scrollable.line(T).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module int.
:- import_module maybe.
:- import_module require.

:- type scrollable(T)
    --->    scrollable(
                s_lines     :: list(T),
                s_numlines  :: int,
                s_top       :: int,
                s_cursor    :: maybe(int)
            ).

%-----------------------------------------------------------------------------%

init(Lines) = scrollable(Lines, NumLines, Top, no) :-
    list.length(Lines, NumLines),
    Top = 0.

init_with_cursor(Lines, Cursor) = Scrollable :-
    list.length(Lines, NumLines),
    Top = 0,
    Scrollable = scrollable(Lines, NumLines, Top, yes(Cursor)).

get_lines(Scrollable) = Scrollable ^ s_lines.

get_num_lines(Scrollable) = Scrollable ^ s_numlines.

get_top(Scrollable) = Scrollable ^ s_top.

set_top(Top, !Scrollable) :-
    !Scrollable ^ s_top := Top.

get_cursor(Scrollable, Cursor) :-
    Scrollable ^ s_cursor = yes(Cursor).

set_cursor_centred(Cursor, NumRows, !Scrollable) :-
    Top = max(0, Cursor - NumRows//2),
    !Scrollable ^ s_top := Top,
    !Scrollable ^ s_cursor := yes(Cursor).

get_cursor_line(Scrollable, Cursor, Line) :-
    Lines = Scrollable ^ s_lines,
    MaybeCursor = Scrollable ^ s_cursor,
    MaybeCursor = yes(Cursor),
    list.index0(Lines, Cursor, Line).

set_cursor_line(Line, !Scrollable) :-
    (
        !.Scrollable ^ s_lines = Lines0,
        !.Scrollable ^ s_cursor = yes(Cursor),
        list.replace_nth(Lines0, Cursor + 1, Line, Lines)
    ->
        !Scrollable ^ s_lines := Lines
    ;
        unexpected($module, $pred, "failed")
    ).

scroll(NumRows, Delta, HitLimit, !Scrollable) :-
    !.Scrollable = scrollable(Lines, NumLines, Top0, MaybeCursor0),
    TopLimit = max(max(0, NumLines - NumRows), Top0),
    Top = clamp(0, Top0 + Delta, TopLimit),
    ( Top = Top0, Delta < 0 ->
        HitLimit = yes
    ; Top = Top0, Delta > 0 ->
        HitLimit = yes
    ;
        HitLimit = no
    ),
    % XXX cursor
    MaybeCursor = MaybeCursor0,
    !:Scrollable = scrollable(Lines, NumLines, Top, MaybeCursor).

move_cursor(NumRows, Delta, HitLimit, !Scrollable) :-
    !.Scrollable = scrollable(Lines, NumLines, Top0, MaybeCursor0),
    (
        MaybeCursor0 = yes(Cursor0),
        Cursor = clamp(0, Cursor0 + Delta, NumLines - 1),
        ( Cursor = Cursor0 ->
            HitLimit = yes
        ;
            HitLimit = no,
            ( Cursor < Top0 ->
                Top = max(Cursor - NumRows + 1, 0)
            ; Top0 + NumRows - 1 < Cursor ->
                Top = Cursor
            ;
                Top = Top0
            ),
            !:Scrollable = scrollable(Lines, NumLines, Top, yes(Cursor))
        )
    ;
        MaybeCursor0 = no,
        HitLimit = no
    ).

search_forward(P, Scrollable, I0, I, MatchLine) :-
    Scrollable = scrollable(Lines0, _NumLines, _Top, _MaybeCursor),
    list.drop(I0, Lines0, Lines),
    search_loop(P, Lines, I0, I, MatchLine).

search_reverse(P, Scrollable, I0, I) :-
    Scrollable = scrollable(Lines0, _NumLines, _Top, _MaybeCursor),
    list.take_upto(I0, Lines0, Lines1),
    list.reverse(Lines1, RevLines),
    search_loop(P, RevLines, 1, N, _),
    I = I0 - N.

:- pred search_loop(pred(T)::in(pred(in) is semidet),
    list(T)::in, int::in, int::out, T::out) is semidet.

search_loop(P, [X | Xs], N0, N, MatchX) :-
    ( P(X) ->
        N = N0,
        MatchX = X
    ;
        search_loop(P, Xs, N0 + 1, N, MatchX)
    ).

draw(RowPanels, Scrollable, !IO) :-
    Scrollable = scrollable(Lines0, _NumLines, Top, MaybeCursor),
    ( list.drop(Top, Lines0, Lines1) ->
        Lines = Lines1
    ;
        Lines = []
    ),
    (
        MaybeCursor = yes(Cursor),
        N = Cursor - Top
    ;
        MaybeCursor = no,
        N = -1
    ),
    draw_lines(RowPanels, Lines, N, !IO).

:- pred draw_lines(list(panel)::in, list(T)::in, int::in,
    io::di, io::uo) is det
    <= scrollable.line(T).

draw_lines([], _, _, !IO).
draw_lines([Panel | Panels], Lines, N, !IO) :-
    panel.erase(Panel, !IO),
    (
        Lines = [Line | RestLines],
        IsCursor = (N = 0 -> yes ; no),
        draw_line(Panel, Line, IsCursor, !IO)
    ;
        Lines = [],
        RestLines = []
    ),
    draw_lines(Panels, RestLines, N - 1, !IO).

:- func clamp(int, int, int) = int.

clamp(Min, X, Max) =
    ( X < Min -> Min
    ; X > Max -> Max
    ; X
    ).

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sts=4 sw=4 et