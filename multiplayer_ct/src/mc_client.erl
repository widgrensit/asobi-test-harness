-module(mc_client).
-moduledoc """
Multi-client WS driver for the asobi-test-harness multiplayer CT suite.

One process per simulated player. Owns a gun HTTP+WS connection, registers the
player via REST, opens /ws, runs session.connect, and accumulates the entity
state from world.tick deltas so the suite can assert fanout.
""".

-behaviour(gen_server).

-export([
    register_and_connect/1,
    create_world/2,
    join_world/2,
    send_world_input/2,
    entities/1,
    last_tick/1,
    player_id/1,
    stop/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-type opts() :: #{
    host := string(),
    port := pos_integer(),
    username := binary()
}.

-export_type([opts/0]).

-record(state, {
    host :: string(),
    port :: pos_integer(),
    username :: binary(),
    password :: binary(),
    player_id :: undefined | binary(),
    session_token :: undefined | binary(),
    gun_pid :: undefined | pid(),
    ws_ref :: undefined | gun:stream_ref(),
    cid_counter = 0 :: non_neg_integer(),
    pending = #{} :: #{integer() => {gen_server:from(), atom()}},
    entities = #{} :: #{binary() => map()},
    last_tick = 0 :: non_neg_integer()
}).

%% --- API ---

-spec register_and_connect(pid()) -> {ok, binary()} | {error, term()}.
register_and_connect(Pid) ->
    narrow_ok_binary(gen_server:call(Pid, register_and_connect, 30_000)).

-spec create_world(pid(), binary()) -> {ok, binary()} | {error, term()}.
create_world(Pid, Mode) ->
    narrow_ok_binary(gen_server:call(Pid, {create_world, Mode}, 30_000)).

-spec join_world(pid(), binary()) -> {ok, binary()} | {error, term()}.
join_world(Pid, WorldId) ->
    narrow_ok_binary(gen_server:call(Pid, {join_world, WorldId}, 30_000)).

-spec send_world_input(pid(), map()) -> ok.
send_world_input(Pid, Input) ->
    gen_server:cast(Pid, {send_world_input, Input}).

-spec entities(pid()) -> map().
entities(Pid) ->
    case gen_server:call(Pid, entities) of
        M when is_map(M) -> M
    end.

-spec last_tick(pid()) -> non_neg_integer().
last_tick(Pid) ->
    case gen_server:call(Pid, last_tick) of
        N when is_integer(N), N >= 0 -> N
    end.

-spec player_id(pid()) -> binary().
player_id(Pid) ->
    case gen_server:call(Pid, player_id) of
        B when is_binary(B) -> B
    end.

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-spec narrow_ok_binary(term()) -> {ok, binary()} | {error, term()}.
narrow_ok_binary({ok, B}) when is_binary(B) -> {ok, B};
narrow_ok_binary({error, R}) -> {error, R};
narrow_ok_binary(Other) -> {error, {unexpected_reply, Other}}.

%% --- gen_server ---

-spec init(opts()) -> {ok, #state{}}.
init(#{host := Host, port := Port, username := Username}) ->
    Password = <<"smoke-pw-", Username/binary, "-x">>,
    {ok, #state{host = Host, port = Port, username = Username, password = Password}}.

handle_call(register_and_connect, _From, State) ->
    case do_register(State) of
        {ok, PlayerId, Token, S1} ->
            case do_ws_connect(S1) of
                {ok, S2} ->
                    case
                        do_session_connect(S2#state{player_id = PlayerId, session_token = Token})
                    of
                        {ok, S3} -> {reply, {ok, PlayerId}, S3};
                        {error, R} -> {reply, {error, R}, S2}
                    end;
                {error, R} ->
                    {reply, {error, R}, S1}
            end;
        {error, R} ->
            {reply, {error, R}, State}
    end;
handle_call({create_world, Mode}, From, State) ->
    send_world_op(~"world.create", Mode, From, create_world, State);
handle_call({join_world, WorldId}, From, State) ->
    Cid = State#state.cid_counter + 1,
    Msg = #{
        ~"type" => ~"world.join",
        ~"cid" => Cid,
        ~"payload" => #{~"world_id" => WorldId}
    },
    ok = ws_send_json(State, Msg),
    {noreply, State#state{
        cid_counter = Cid,
        pending = (State#state.pending)#{Cid => {From, join_world}}
    }};
handle_call(entities, _From, State) ->
    {reply, State#state.entities, State};
handle_call(last_tick, _From, State) ->
    {reply, State#state.last_tick, State};
handle_call(player_id, _From, State) ->
    {reply, State#state.player_id, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({send_world_input, Input}, State) ->
    Msg = #{
        ~"type" => ~"world.input",
        ~"payload" => #{~"data" => Input}
    },
    ok = ws_send_json(State, Msg),
    {noreply, State};
handle_cast(_, State) ->
    {noreply, State}.

handle_info({gun_ws, _Pid, _Ref, {text, Bin}}, State) ->
    case json:decode(Bin) of
        Msg when is_map(Msg) ->
            {noreply, handle_ws_msg(Msg, State)};
        _ ->
            {noreply, State}
    end;
handle_info({gun_ws, _Pid, _Ref, close}, State) ->
    {noreply, State};
handle_info({gun_down, _Pid, _Proto, _Reason, _Streams}, State) ->
    {noreply, State};
handle_info({gun_up, _Pid, _Proto}, State) ->
    {noreply, State};
handle_info({gun_error, _, _, _Reason}, State) ->
    {noreply, State};
handle_info(_Other, State) ->
    {noreply, State}.

terminate(_Reason, #state{gun_pid = undefined}) ->
    ok;
terminate(_Reason, #state{gun_pid = Pid}) ->
    try gun:close(Pid) of
        _ -> ok
    catch
        _:_ -> ok
    end.

%% --- WS message handling ---

handle_ws_msg(#{~"type" := ~"world.tick", ~"payload" := Payload}, State) when is_map(Payload) ->
    Tick =
        case maps:get(~"tick", Payload, 0) of
            T when is_integer(T), T >= 0 -> T;
            _ -> 0
        end,
    Updates =
        case maps:get(~"updates", Payload, []) of
            L when is_list(L) -> L;
            _ -> []
        end,
    Entities1 = apply_updates(State#state.entities, Updates),
    LastTick =
        case Tick > State#state.last_tick of
            true -> Tick;
            false -> State#state.last_tick
        end,
    State#state{entities = Entities1, last_tick = LastTick};
handle_ws_msg(#{~"type" := Type, ~"cid" := Cid} = Msg, State) when is_integer(Cid) ->
    Pending = State#state.pending,
    case maps:find(Cid, Pending) of
        {ok, {From, _Tag}} ->
            reply_pending(From, Type, Msg),
            State#state{pending = maps:remove(Cid, Pending)};
        error ->
            State
    end;
handle_ws_msg(_, State) ->
    State.

reply_pending(From, ~"world.joined", Msg) ->
    Payload =
        case maps:get(~"payload", Msg, #{}) of
            P when is_map(P) -> P;
            _ -> #{}
        end,
    case maps:get(~"world_id", Payload, undefined) of
        W when is_binary(W) -> gen_server:reply(From, {ok, W});
        _ -> gen_server:reply(From, {error, missing_world_id})
    end;
reply_pending(From, ~"error", Msg) ->
    Payload =
        case maps:get(~"payload", Msg, #{}) of
            P when is_map(P) -> P;
            _ -> #{}
        end,
    Reason = maps:get(~"reason", Payload, unknown),
    gen_server:reply(From, {error, Reason});
reply_pending(From, _, _) ->
    gen_server:reply(From, ok).

apply_updates(Entities, []) ->
    Entities;
apply_updates(Entities, [Update | Rest]) when is_map(Update) ->
    apply_updates(apply_update(Entities, Update), Rest);
apply_updates(Entities, [_ | Rest]) ->
    apply_updates(Entities, Rest).

apply_update(Entities, #{~"op" := ~"a", ~"id" := Id} = Full) when is_binary(Id) ->
    Entities#{Id => maps:without([~"op", ~"id"], Full)};
apply_update(Entities, #{~"op" := ~"u", ~"id" := Id} = Diff) when is_binary(Id) ->
    Existing = maps:get(Id, Entities, #{}),
    Merged = maps:merge(Existing, maps:without([~"op", ~"id"], Diff)),
    Entities#{Id => Merged};
apply_update(Entities, #{~"op" := ~"r", ~"id" := Id}) when is_binary(Id) ->
    maps:remove(Id, Entities);
apply_update(Entities, _) ->
    Entities.

%% --- HTTP: register + login fallback ---

do_register(State = #state{host = Host, port = Port, username = U, password = P}) ->
    Body = json:encode(#{username => U, password => P}),
    case gun_post(Host, Port, "/api/v1/auth/register", Body) of
        {ok, 200, RespBody} ->
            decode_auth(RespBody, State);
        {ok, 422, _} ->
            do_login(State);
        {ok, Status, RespBody} ->
            {error, {register_failed, Status, RespBody}};
        {error, R} ->
            {error, R}
    end.

do_login(State = #state{host = Host, port = Port, username = U, password = P}) ->
    Body = json:encode(#{username => U, password => P}),
    case gun_post(Host, Port, "/api/v1/auth/login", Body) of
        {ok, 200, RespBody} ->
            decode_auth(RespBody, State);
        {ok, Status, RespBody} ->
            {error, {login_failed, Status, RespBody}};
        {error, R} ->
            {error, R}
    end.

decode_auth(RespBody, State) ->
    case json:decode(RespBody) of
        #{~"player_id" := PlayerId, ~"session_token" := Token} when
            is_binary(PlayerId), is_binary(Token)
        ->
            {ok, PlayerId, Token, State};
        Other ->
            {error, {bad_auth_response, Other}}
    end.

gun_post(Host, Port, Path, Body) ->
    {ok, Pid} = gun:open(Host, Port, #{retry => 0, protocols => [http]}),
    try
        case gun:await_up(Pid, 5_000) of
            {ok, _} ->
                Headers = [{~"content-type", ~"application/json"}],
                Ref = gun:post(Pid, Path, Headers, Body),
                case gun:await(Pid, Ref, 10_000) of
                    {response, fin, Status, _} ->
                        {ok, Status, ~""};
                    {response, nofin, Status, _} ->
                        case gun:await_body(Pid, Ref, 10_000) of
                            {ok, RespBody} -> {ok, Status, RespBody};
                            {error, R} -> {error, {body_error, R}}
                        end;
                    {error, R} ->
                        {error, R}
                end;
            {error, R} ->
                {error, {await_up_failed, R}}
        end
    after
        gun:close(Pid)
    end.

%% --- WS connect ---

do_ws_connect(State = #state{host = Host, port = Port}) ->
    {ok, Pid} = gun:open(Host, Port, #{retry => 0, protocols => [http]}),
    case gun:await_up(Pid, 5_000) of
        {ok, _} ->
            Ref = gun:ws_upgrade(Pid, "/ws"),
            receive
                {gun_upgrade, Pid, Ref, [~"websocket"], _} ->
                    {ok, State#state{gun_pid = Pid, ws_ref = Ref}};
                {gun_response, Pid, Ref, _, Status, _} ->
                    gun:close(Pid),
                    {error, {ws_upgrade_failed, Status}};
                {gun_error, Pid, Ref, R} ->
                    gun:close(Pid),
                    {error, {ws_error, R}}
            after 5_000 ->
                gun:close(Pid),
                {error, ws_upgrade_timeout}
            end;
        {error, R} ->
            gun:close(Pid),
            {error, {await_up_failed, R}}
    end.

do_session_connect(State = #state{session_token = Token, player_id = PlayerId}) ->
    Cid = State#state.cid_counter + 1,
    Msg = #{
        ~"type" => ~"session.connect",
        ~"cid" => Cid,
        ~"payload" => #{~"token" => Token}
    },
    ok = ws_send_json(State, Msg),
    receive
        {gun_ws, _Pid, _Ref, {text, Bin}} ->
            case json:decode(Bin) of
                #{~"type" := ~"session.connected", ~"payload" := #{~"player_id" := PlayerId}} ->
                    {ok, State#state{cid_counter = Cid}};
                #{~"type" := ~"error", ~"payload" := P} ->
                    {error, {session_connect_failed, P}};
                Other ->
                    {error, {unexpected_reply, Other}}
            end
    after 5_000 ->
        {error, session_connect_timeout}
    end.

send_world_op(Type, Mode, From, Tag, State) ->
    Cid = State#state.cid_counter + 1,
    Msg = #{
        ~"type" => Type,
        ~"cid" => Cid,
        ~"payload" => #{~"mode" => Mode}
    },
    ok = ws_send_json(State, Msg),
    {noreply, State#state{
        cid_counter = Cid,
        pending = (State#state.pending)#{Cid => {From, Tag}}
    }}.

ws_send_json(#state{gun_pid = Pid, ws_ref = Ref}, Msg) when is_pid(Pid), Ref =/= undefined ->
    Bin = iolist_to_binary(json:encode(Msg)),
    gun:ws_send(Pid, Ref, {text, Bin}),
    ok.
