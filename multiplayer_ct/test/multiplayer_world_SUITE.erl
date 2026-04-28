-module(multiplayer_world_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([world_fanout_property/1]).

%% PropEr property entry — exported so proper:quickcheck/2 can find it.
-export([prop_world_fanout/0]).

-define(HARNESS_HOST, "localhost").
-define(HARNESS_PORT, 8080).
%% No /health endpoint exists; any HTTP status (incl. 404) proves the listener is up.
-define(READINESS_PATH, "/api/v1/health").
-define(MODE, ~"smoke_world").
-define(FANOUT_TIMEOUT_MS, 8_000).
-define(POLL_INTERVAL_MS, 100).
-define(NUMTESTS, 9).

all() ->
    [world_fanout_property].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gun),
    HarnessRoot = harness_root(),
    ct:pal("Bringing up docker compose at ~s", [HarnessRoot]),
    Up = os:cmd("cd '" ++ HarnessRoot ++ "' && docker compose up -d 2>&1"),
    ct:pal("docker compose up -> ~s", [Up]),
    case wait_for_health(60) of
        ok ->
            [{harness_root, HarnessRoot} | Config];
        {error, Reason} ->
            ct:pal(
                "Logs:~n~s",
                [
                    os:cmd(
                        "cd '" ++ HarnessRoot ++
                            "' && docker compose logs --tail=200 asobi 2>&1"
                    )
                ]
            ),
            os:cmd("cd '" ++ HarnessRoot ++ "' && docker compose down -v 2>&1"),
            {fail, {harness_unhealthy, Reason}}
    end.

end_per_suite(Config) ->
    HarnessRoot = ?config(harness_root, Config),
    Down = os:cmd("cd '" ++ HarnessRoot ++ "' && docker compose down -v 2>&1"),
    ct:pal("docker compose down -> ~s", [Down]),
    ok.

%% rebar3 ct invokes from the project root (multiplayer_ct/); harness root is
%% one dir up. Allow override via env for callers that run differently.
harness_root() ->
    case os:getenv("ASOBI_HARNESS_ROOT") of
        false -> filename:absname("..");
        Root -> Root
    end.

world_fanout_property(_Config) ->
    Opts = [
        {numtests, ?NUMTESTS},
        {to_file, user},
        long_result
    ],
    Result = proper:quickcheck(prop_world_fanout(), Opts),
    case Result of
        true ->
            ok;
        Counter ->
            ct:fail({property_failed, Counter})
    end.

%% --- Property ---

prop_world_fanout() ->
    ?FORALL(
        N,
        proper_types:integer(2, 10),
        run_fanout_iteration(N)
    ).

run_fanout_iteration(N) ->
    RunId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Clients = start_clients(N, RunId),
    try
        WorldId = host_creates_world(Clients),
        ok = guests_join(WorldId, Clients),
        ok = each_sends_input(Clients),
        wait_for_fanout(Clients, N, ?FANOUT_TIMEOUT_MS)
    after
        stop_clients(Clients)
    end.

-spec start_clients(pos_integer(), binary()) -> [pid()].
start_clients(N, RunId) ->
    [start_client(I, RunId) || I <- lists:seq(1, N)].

-spec start_client(pos_integer(), binary()) -> pid().
start_client(I, RunId) ->
    Username = <<"smoke-", RunId/binary, "-", (integer_to_binary(I))/binary>>,
    Opts = #{host => ?HARNESS_HOST, port => ?HARNESS_PORT, username => Username},
    case gen_server:start(mc_client, Opts, []) of
        {ok, Pid} when is_pid(Pid) ->
            {ok, _PlayerId} = mc_client:register_and_connect(Pid),
            Pid
    end.

-spec host_creates_world([pid(), ...]) -> binary().
host_creates_world([Host | _]) ->
    {ok, WorldId} = mc_client:create_world(Host, ?MODE),
    WorldId.

-spec guests_join(binary(), [pid()]) -> ok.
guests_join(_WorldId, []) ->
    ok;
guests_join(_WorldId, [_]) ->
    ok;
guests_join(WorldId, [_Host | Guests]) ->
    _ = [{ok, WorldId} = mc_client:join_world(P, WorldId) || P <- Guests],
    ok.

-spec each_sends_input([pid()]) -> ok.
each_sends_input(Clients) ->
    each_sends_input_at(Clients, 1).

-spec each_sends_input_at([pid()], pos_integer()) -> ok.
each_sends_input_at([], _) ->
    ok;
each_sends_input_at([P | Rest], I) ->
    mc_client:send_world_input(P, #{~"move_x" => I, ~"move_y" => 0}),
    each_sends_input_at(Rest, I + 1).

-spec wait_for_fanout([pid()], pos_integer(), pos_integer()) -> boolean().
wait_for_fanout(Clients, N, BudgetMs) ->
    Deadline = erlang:monotonic_time(millisecond) + BudgetMs,
    Expected = expected_xs(N),
    poll_until_fanout(Clients, Expected, Deadline).

-spec poll_until_fanout([pid()], [pos_integer()], integer()) -> boolean().
poll_until_fanout(Clients, Expected, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case all_clients_have(Clients, Expected) of
        true ->
            true;
        {false, _Detail} when Now >= Deadline ->
            ct:pal(
                "Fanout failed for ~p clients. Per-client view:~n~p",
                [length(Clients), per_client_view(Clients)]
            ),
            false;
        {false, _} ->
            timer:sleep(?POLL_INTERVAL_MS),
            poll_until_fanout(Clients, Expected, Deadline)
    end.

-spec expected_xs(pos_integer()) -> [pos_integer()].
expected_xs(N) ->
    [I || I <- lists:seq(1, N)].

-spec all_clients_have([pid()], [pos_integer()]) ->
    true | {false, [{pid(), boolean()}]}.
all_clients_have(Clients, ExpectedXs) ->
    PlayerIds = [mc_client:player_id(C) || C <- Clients],
    Expected = maps:from_list(lists:zip(PlayerIds, ExpectedXs)),
    Pairs = [{C, client_has_all(C, Expected)} || C <- Clients],
    case lists:all(fun({_, R}) -> R =:= true end, Pairs) of
        true -> true;
        false -> {false, Pairs}
    end.

-spec client_has_all(pid(), #{binary() => pos_integer()}) -> boolean().
client_has_all(Pid, Expected) ->
    Entities = mc_client:entities(Pid),
    maps:fold(
        fun
            (_PlayerId, _ExpectedX, false) ->
                false;
            (PlayerId, ExpectedX, true) ->
                case maps:get(PlayerId, Entities, undefined) of
                    undefined ->
                        false;
                    EState when is_map(EState) ->
                        case maps:get(~"x", EState, undefined) of
                            ExpectedX -> true;
                            X when is_number(X), X =:= ExpectedX -> true;
                            _ -> false
                        end;
                    _ ->
                        false
                end
        end,
        true,
        Expected
    ).

-spec per_client_view([pid()]) -> [map()].
per_client_view(Clients) ->
    [
        #{
            player_id => mc_client:player_id(C),
            last_tick => mc_client:last_tick(C),
            entities => mc_client:entities(C)
        }
     || C <- Clients
    ].

-spec stop_clients([pid()]) -> ok.
stop_clients(Clients) ->
    _ = [stop_one(P) || P <- Clients],
    ok.

-spec stop_one(pid()) -> ok.
stop_one(Pid) ->
    try mc_client:stop(Pid) of
        _ -> ok
    catch
        _:_ -> ok
    end.

%% --- Health polling ---

wait_for_health(0) ->
    {error, timeout};
wait_for_health(N) ->
    case http_get_status(?HARNESS_HOST, ?HARNESS_PORT, ?READINESS_PATH) of
        {ok, Status} when is_integer(Status) -> ok;
        _ ->
            timer:sleep(1000),
            wait_for_health(N - 1)
    end.

http_get_status(Host, Port, Path) ->
    case gun:open(Host, Port, #{retry => 0}) of
        {ok, Pid} ->
            try
                case gun:await_up(Pid, 2_000) of
                    {ok, _} ->
                        Ref = gun:get(Pid, Path),
                        case gun:await(Pid, Ref, 2_000) of
                            {response, _, Status, _} -> {ok, Status};
                            {error, R} -> {error, R}
                        end;
                    {error, R} ->
                        {error, R}
                end
            after
                gun:close(Pid)
            end;
        {error, R} ->
            {error, R}
    end.
