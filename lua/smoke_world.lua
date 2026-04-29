-- Deterministic smoke-test world mode.
--
-- Parallel to smoke.lua but for world-mode (zone-based, no matchmaker).
-- Used by the multiplayer CT suite and by SDK world-mode smoke tests.
-- Semantics are deliberately boring so assertions are easy to write:
--
--   - Single zone at (0, 0).
--   - One entity per player, entity_id == player_id.
--   - handle_input applies move_x / move_y deltas directly to entity x/y.
--   - tick counter in zone_state increments every server tick.
--   - World never auto-finishes (CT suite controls lifecycle).
--
-- Any test that does the following must pass:
--   1. Register N players (N in [2..10]) and connect each to /ws.
--   2. C1 sends world.find_or_create { mode = "smoke_world" } -> world_id.
--   3. C2..CN send world.join { world_id }.
--   4. Each client sends world.input { move_x = i } where i is their index.
--   5. Within K ticks, every client receives a world.tick whose entity for
--      every other client reflects that client's move (x == i).

game_type   = "world"
match_size  = 1
max_players = 16
lazy_zones  = false

function init(_config)
    return { tick_count = 0 }
end

function join(_player_id, state)
    return state
end

function leave(_player_id, state)
    return state
end

function spawn_position(_player_id, _state)
    return { x = 0, y = 0 }
end

function generate_world(_seed, _config)
    return {
        ["0,0"] = { tick_count = 0 }
    }
end

function zone_tick(entities, zone_state)
    zone_state.tick_count = (zone_state.tick_count or 0) + 1
    return entities, zone_state
end

function handle_input(player_id, input, entities)
    local e = entities[player_id]
    if not e then return entities end

    e.x = (e.x or 0) + (tonumber(input.move_x) or 0)
    e.y = (e.y or 0) + (tonumber(input.move_y) or 0)
    e.inputs_seen = (e.inputs_seen or 0) + 1

    entities[player_id] = e
    return entities
end

function post_tick(_tick, state)
    state.tick_count = (state.tick_count or 0) + 1
    return state
end

function get_state(_player_id, state)
    return state
end
