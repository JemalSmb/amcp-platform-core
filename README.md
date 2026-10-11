# AMCP Platform Core

Deployment entrypoint for the AMCP platform: root `docker-compose.yml`, `Caddyfile`
(HTTPS reverse proxy), `smoke-test.sh`, and deploy/ops docs.

## Required layout

The compose file reaches the other repos by relative path, so clone all four
side by side (locally and on the server):

```text
<workspace>/
├── amcp-core/               <- this repo; run docker compose from here
├── amcp-services/           https://github.com/JemalSmb/amcp-services
├── amcp-ai-engine/          https://github.com/JemalSmb/amcp-ai-engine
└── amcp-platform-clients/   https://github.com/JemalSmb/amcp-platform-clients
```

```bash
cp .env.example .env     # fill in the values; .env is gitignored
docker compose up -d --build
```

---

# AMCP — AI Modular Cybersecurity Platform

AMCP is an AI-driven monitoring platform spanning cybersecurity, finance, and
manufacturing. It combines a shared model-serving layer with per-domain
microservices that turn incoming events (network flows, transactions, sensor
readings, emails, etc.) into scored predictions and, above a threshold,
alerts. An aggregation gateway exposes a single API surface over the domain
services and inference layer for the web dashboard.

See `CURRENT_STATE_IMPLEMENTATION_PLAN.md` and `DOMAIN_ROADMAP.md` for the
detailed scope, history, and longer-term roadmap. This file is a short,
practical runbook for getting the stack up and verifying it works.

## Repo layout

```
amcp-ai-engine/
  ai/inference/         FastAPI model-serving API (serve.py). Loads trained
                         models and exposes GET /health, GET /models,
                         POST /models/{id}/predict, POST /models/{id}/reload.
                         Runs on port 8000.
  ai/training/          Training pipelines and model artifacts per domain
                         (cybersecurity, finance, manufacturing).

amcp-services/amcp-platform-services/
  shared/base_service.py   Shared DomainMicroservice runtime: validates a
                            /trigger payload, calls the inference service,
                            and (if NATS is reachable) publishes an alert
                            event; otherwise logs what it would have
                            published.
  services/gateway/        Aggregation gateway (port 8080). Proxies model
                            info, health-checks the flagship services,
                            buffers/serves recent alert events, and relays
                            trigger calls.
  services/{cybersecurity,finance,manufacturing}/...
                            One directory per domain service. Four are fully
                            wired end-to-end ("flagship" services, see
                            below); the rest are placeholder stubs.

amcp-clients/amcp-platform-clients/apps/web-client/amcp-web-client/
  Angular dashboard that talks to the gateway (http://localhost:8080).
```

## Running the platform

Once the platform is running (via `docker compose up -d` at the repo root —
this brings up NATS, Postgres, MLflow, the inference service, the domain
services, the gateway, and the web client), the key entry points are:

- Inference API: `http://localhost:8000`
- Gateway API: `http://localhost:8080`
- Web dashboard: served by the Angular client container (see its own docs
  for the exact port)
- Flagship domain services directly: `8001` (threat-detection), `8003`
  (phishing-detector), `8011` (fraud-detector), `8021`
  (process-anomaly-detector)

If the root `docker-compose.yml` isn't available yet in your checkout, each
service can also be run standalone (e.g. `python service.py` from its
directory, or `uvicorn serve:app` for the inference service), as long as
`INFERENCE_URL` and `NATS_URL` are set appropriately for the domain
services.

For a step-by-step manual walkthrough (launching each piece by hand,
checking the frontend in a browser, curling each service) see
`TESTING.md`.

## Running the smoke test

Once some or all of the stack is up:

```
./smoke-test.sh
```

This is a standalone bash + curl script (no test framework needed). It checks,
in order:

1. Inference service `GET /health` (200, status `ok` or `degraded`) and
   `GET /models` (200, non-empty JSON array).
2. `GET /health` for each of the four flagship domain services
   (threat-detection:8001, phishing-detector:8003, fraud-detector:8011,
   process-anomaly-detector:8021).
3. `POST /trigger` on each of those four with a plausible fake feature
   payload, asserting HTTP 200 and a `published` boolean in the response
   (`true` or `false` are both acceptable outcomes — it just means the
   score was above or below that service's alert threshold).
4. Gateway `GET /health`, `GET /models`, `GET /domains/status`, and
   `GET /alerts` (all expected to return 200).

Each check prints `PASS`, `FAILED`, or `SKIPPED`. A connection refusal/timeout
(service not up yet) is reported as `SKIPPED`, not `FAILED`, so you can run
this against a partially-started stack. The script exits non-zero only if at
least one check produced a real `FAILED` (bad status code or malformed body
from something that did respond).

## Current status

**Implemented and working end-to-end:**
- Inference service (`amcp-ai-engine/ai/inference/serve.py`)
- Four flagship domain services, each wired to the inference API via the
  shared `DomainMicroservice` runtime: threat-detection, phishing-detector,
  fraud-detector, process-anomaly-detector
- Aggregation gateway (`services/gateway/gateway.py`) fronting the above
- Angular dashboard scaffold wired to call the gateway

**Still stubs (health check only, no real `/trigger` logic):**
- The remaining domain services under `services/cybersecurity/`,
  `services/finance/`, and `services/manufacturing/` (e.g.
  ransomware-detection, iot-anomaly-detector, aml-monitor,
  quality-controller, and others). At last check there are 34 total service
  directories across the three domains, 4 of which are the flagship
  services above — so 30 stubs, not the ~26 originally estimated. They boot
  and answer `GET /health` but do not yet implement domain-specific feature
  extraction or model wiring.

For the detailed backlog and priority order across AI, microservices,
backend/API, and frontend work, see `DOMAIN_ROADMAP.md`. For the delivery
history and MVP scoping decisions, see
`CURRENT_STATE_IMPLEMENTATION_PLAN.md`.
