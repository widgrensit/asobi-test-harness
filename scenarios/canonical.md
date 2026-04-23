# Canonical smoke scenarios

Every SDK's smoke test must pass these scenarios against the harness
(`docker compose up` in this repo). Each scenario names the specific
server messages the SDK must produce or handle. If the server protocol
moves, this file moves too and all SDK smoke tests must be updated
lockstep — same drift-prevention contract as `asobi_site_snippets`.

## 1. Connect + auth

- `POST /api/v1/auth/register` — returns `{ access_token, refresh_token, player_id }`.
- Open WebSocket at `/ws`.
- Send `session.connect` with `{ token }`. Receive `session.connected` with `{ player_id }`.
- Pass criterion: `player_id` in reply matches `player_id` from REST register.

## 2. Matchmaker → match.joined

- Register a second player and repeat the connect step.
- Both clients send `matchmaker.add` with `{ mode: "smoke" }`.
- Both receive `matchmaker.queued` within 2s.
- Both receive `match.joined` within 5s (the smoke mode's `match_size = 2`).
- Pass criterion: the `match_id` in both `match.joined` payloads is identical.

## 3. match.input → match.state

- One client sends `match.input` with `{ data: { move_x: 1, move_y: 0 } }`.
- Client receives at least one `match.state` payload where
  `players[<self_player_id>].x == 1` and `inputs_seen == 1`.
- Pass criterion: above within 1s of sending the input.

## 4. Match lifecycle (optional)

- Clients remain connected; server auto-finishes the match at tick 150.
- Each client eventually receives a `match.finished` or `match.left`
  (implementation-dependent, not required for initial smoke).

## Writing a new SDK smoke test

Each SDK's `smoke_tests/` folder should contain a single executable
(Node script, dart, shell, etc.) that:

1. Reads `ASOBI_URL` env var (default `http://localhost:8080`).
2. Runs scenarios 1-3 sequentially.
3. Exits 0 on success, 1 on failure, with a clear stderr log.

CI invokes it as:

```bash
docker compose -f asobi-test-harness/docker-compose.yml up -d
# wait for health
./smoke_tests/run.sh
docker compose -f asobi-test-harness/docker-compose.yml down
```
