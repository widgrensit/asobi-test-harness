# multiplayer_ct

Erlang Common Test suite that drives N concurrent WebSocket clients against
the harness and asserts zone-broadcast fanout. Catches the bug class where a
player's move is correctly applied server-side but never relayed to the other
subscribed clients in the same zone.

## What it tests

`multiplayer_world_SUITE` runs a PropEr property:

> ∀ N ∈ [2..10], if N clients all join the same `smoke_world` world and each
> client `i` sends `world.input { move_x = i }`, then every client's view of
> the entity set eventually contains every other client's player with
> `x == sent_move_x`.

PropEr picks N at random per iteration (`numtests=9` by default). On failure
it shrinks to the smallest N that breaks and logs the seed for replay.

## Running

From this directory:

```bash
rebar3 ct
```

The suite brings the harness up via `docker compose up -d` (one dir up) in
`init_per_suite`, polls `/api/v1/health` until ready (≤60s), and tears down
with `docker compose down -v` in `end_per_suite`.

Override the harness root with `ASOBI_HARNESS_ROOT=/path/to/asobi-test-harness`.

## What's deliberately not here

- **No match-mode property test.** Match `match_size` is a fixed Lua global
  per mode, so a property over N requires fixture proliferation. The existing
  in-process tests in `asobi_lua/test/` cover match broadcast.
- **No multi-zone or world-recovery tests.** Single zone at (0, 0) keeps the
  property assertions simple. Add follow-up suites if needed.
