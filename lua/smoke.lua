-- Deterministic smoke-test match mode.
--
-- Every SDK's smoke test exercises the full connect → queue → play
-- loop against THIS mode. The semantics are deliberately boring so
-- assertions are easy to write:
--
--   - match_size = 2 — match starts when two players queue.
--   - Player state: { x, y, inputs_seen }.
--   - handle_input applies move_x / move_y deltas directly.
--   - tick counter increments every server tick; included in state.
--   - Match auto-finishes at tick 150 so CI runs stay bounded (~5s
--     at 30Hz).
--
-- Any test that does the following must pass:
--   1. Register two players.
--   2. Both queue matchmaker with mode "smoke".
--   3. Both receive match.matched (NOT match.joined) within ~5s.
--   4. Send match.input { move_x = 1 } once.
--   5. Receive at least one match.state whose `players[self].x == 1`.

match_size = 2
max_players = 2

function init(_config)
    return {
        players = {},
        tick_count = 0
    }
end

function join(player_id, state)
    state.players[player_id] = {
        x = 0,
        y = 0,
        inputs_seen = 0
    }
    return state
end

function leave(player_id, state)
    state.players[player_id] = nil
    return state
end

function handle_input(player_id, input, state)
    local p = state.players[player_id]
    if not p then return state end

    p.x = p.x + (tonumber(input.move_x) or 0)
    p.y = p.y + (tonumber(input.move_y) or 0)
    p.inputs_seen = p.inputs_seen + 1

    state.players[player_id] = p
    return state
end

function tick(state)
    state.tick_count = state.tick_count + 1

    if state.tick_count >= 150 then
        state._finished = true
        state._result = {
            status = "completed",
            tick_count = state.tick_count,
            players = state.players
        }
    end

    return state
end

function get_state(_player_id, state)
    return {
        phase = "playing",
        tick = state.tick_count,
        players = state.players
    }
end
