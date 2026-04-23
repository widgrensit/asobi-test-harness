# asobi-test-harness

A minimal, deterministic Asobi backend for validating SDKs in CI. Not a demo, not a dev environment — just a fixed game mode and a known-good server every SDK's smoke test can run against.

## What's in the box

- `docker-compose.yml` — Postgres + `ghcr.io/widgrensit/asobi_lua:latest` on port 8080.
- `lua/smoke.lua` — a deliberately boring 2-player match that echoes inputs into state. Tick counter increments; the match auto-finishes at tick 150.
- `lua/manifest.lua` — registers the `smoke` mode with asobi_lua.
- `scenarios/canonical.md` — the contract every SDK's smoke test must satisfy.

## Running locally

```bash
docker compose up -d
# wait ~10 seconds for health
curl http://localhost:8080/api/v1/health
```

Tear down when done:

```bash
docker compose down -v
```

## SDK smoke test layout

Every client SDK has a `smoke_tests/` folder with one runnable script that:

1. Reads `ASOBI_URL` (default `http://localhost:8080`).
2. Exercises the 3 canonical scenarios in `scenarios/canonical.md`.
3. Exits non-zero on failure.

CI in each SDK repo starts this harness, runs the smoke test, tears down. See `asobi-js/smoke_tests/` for the reference implementation.

## Why this repo is separate

- **Single source of truth.** One game mode, one Docker setup, seven SDKs pointing at it. If the protocol drifts, one test file fails in one repo.
- **Not a demo.** No art, no UI, no scenes. Meant for CI, not for showing off.
- **Parallel to the demos.** Per-engine demo projects (`asobi-unreal-demo`, `asobi-unity-demo`, etc.) still exist — they're the marketing / DX layer. This is the validation layer.

## License

Apache 2.0
