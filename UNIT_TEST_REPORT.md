# Unit test report

Date: 2026-10-11. Scope: unit tests only (no live Supabase, NATS, MLflow or Docker).
Web-client changes were merged separately (amcp-platform-clients PR #5).

## How to run

| Repo | Command | Result |
|---|---|---|
| amcp-ai-engine | `cd ai/inference && pip install -r requirements.txt -r requirements-dev.txt && pytest tests` | **34 passed** |
| amcp-services | `pip install -r requirements-dev.txt && pytest` | **131 passed** |
| amcp-platform-clients / amcp-web-client | `npx ng test --watch=false` | **25 passed** (18 files) |
| amcp-platform-clients / amcp-admin-client | `npx ng test --watch=false` | **27 passed** (19 files) |
| **Total** | | **217 passed, 0 failed** |

## Bugs the tests found (all fixed)

1. **Supabase artifact cache path (amcp-ai-engine, `registry.py`).**
   `_try_load_from_supabase` downloaded the artifact, then loaded it from
   `<cache>/<model>/artifacts/artifacts/x.joblib` (relative path joined twice).
   Cloud-hosted models would be downloaded but never loaded, silently falling
   back to mock scoring. Fixed: `base_dir=MODEL_CACHE_DIR / model_id`.
2. **Route guards called `inject()` after `await` (both Angular clients, `auth.guard.ts`).**
   `inject(Router)` outside the injection context throws NG0203, so the
   redirect-to-login / redirect-to-dashboard branches would error at runtime.
   Fixed: `Router` captured before the `await`.
3. **Web client `tsconfig.spec.json` was a copy of the app config.** It
   *excluded* `*.spec.ts` and loaded `node` types, so `ng test` failed to
   compile (16 "file not found in TypeScript compilation" errors). Fixed to
   match the admin client.
4. **Stale scaffold specs (both clients).** `Auth`, `DrawerNav` specs lacked a
   router provider; `App` spec asserted an `<h1>User Drawer` that no longer
   exists. Fixed.

## What is covered

**Inference service (34)** — deterministic mock scoring; label threshold at 0.5;
artifact resolution order (MLflow → Supabase Storage → local file → mock);
Supabase download + local caching + failure fall-through; corrupt artifact and
feature-count mismatch degrade rather than crash; missing-feature warning;
hot-swap on new registry version; `/health` (degraded/ok, image version
`MODEL_VERSION`/`dev`), `/models`, `/predict` validation (404/422), `/reload`,
repeated-call stability.

**Shared runtime + domain services (≈45)** — `DomainEvent` create/round-trip/
defaults; payload validation; inference request formatting; severity bands
(medium/high/critical at 0.5/0.75/0.9) and threshold boundary; alert metadata;
NATS publish, subscribe, malformed-message drop, broker-unreachable → HTTP-only;
inference failure swallowed; `/health`, `/trigger`; all four flagship services
wired to the right domain/model/subject.

**Gateway, dashboard API and admin API (≈86)** — HS256 verify; expired / wrong-signature / wrong-audience /
tampered / `alg=none` rejection; ES256 via JWKS; admin-role gate; 401 on every
protected route; open `/v1/models`; `/v1/domains/status` up/down; trigger
forwarding, 404, 502, body validation; rate limit (10/min → 429 on the 11th);
CORS allowed/blocked/preflight; legacy unversioned aliases; alert DB-first with
memory fallback, newest-first, domain filter, limit; `alert_store` write/read/
degradation paths; `record_store` memory/DB/seed/owner isolation;
`platform_api` derived predictions/detections/incidents, manual predict proxy
(404/422/502), seeded collections, automation toggle, per-user settings/profile;
`admin_api` role gate, status mapping, server-side role on create, validation,
suspend/restore, upstream errors.

**Angular (web 25 / admin 27)** — bearer token attached only to gateway URLs
and never to third parties; no header when signed out; `authGuard`/`guestGuard`
redirects, SSR bypass, non-admin rejection (admin); plus the existing
per-page "should create" specs now compiling and passing.

## Not covered (be honest in the write-up)

- Gateway NATS subscription callback and startup/shutdown hooks.
- Real MLflow load path (`mlflow.pyfunc.load_model`) is only exercised via stubs.
- Angular page components are only "creates without error" smoke tests;
  no behavioural/usability tests; `auth.service` and `platform-api.service` untested.
- C++ desktop client: no tests.
- Training pipelines / preprocessing: no tests.
- Integration, end-to-end, performance and production-deployment tests are
  **not** done — those still need the live stack (`smoke-test.sh`, `TESTING.md`).
