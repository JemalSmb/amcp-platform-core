# Manual testing guide

This is the step-by-step walkthrough for a human to click/curl through the
whole stack and confirm it actually works — as opposed to `smoke-test.sh`,
which is the scripted/automated version of the backend checks below. Use
this when you want to see it running (browser, terminal output), or when
`smoke-test.sh` fails and you need to isolate which piece broke.

Run each section in its own terminal tab, in the order given — later
sections depend on earlier ones being up.

## 0. Prerequisites

- Python 3.11+, `pip install -r requirements.txt` in each service directory
  you plan to run standalone (or use `docker compose up -d` from the repo
  root to start everything at once — see `README.md`).
- Node 20+ for the Angular clients.
- NATS is optional for manual testing: every service degrades gracefully
  (logs what it *would* publish) if it can't reach a broker, so you can test
  the HTTP paths without running NATS at all. Run `docker run -p 4222:4222
  nats:2-alpine` if you want to see real pub/sub (e.g. alerts actually
  showing up in the gateway's `/alerts`).

## 1. Inference service

```bash
cd amcp-ai-engine/ai/inference
uvicorn serve:app --host 0.0.0.0 --port 8000 --reload
```

Check:
- `curl http://localhost:8000/health` → `status` is `"ok"` or `"degraded"`
  (degraded just means no trained models loaded yet — mock scoring still
  works).
- `curl http://localhost:8000/models` → non-empty JSON array. Note the
  `id` values (e.g. `anomaly_detection`) — you'll need them for step 2.
- `curl -X POST http://localhost:8000/models/anomaly_detection/predict -H 'content-type: application/json' -d '{"features": {"a": 1.0, "b": 2.0}}'`
  → 200 with a `label` and `score`.

## 2. Flagship domain services

Each needs `INFERENCE_URL` pointing at step 1 and (optionally) `NATS_URL`.
Run each in its own terminal:

```bash
cd amcp-services/amcp-platform-services
INFERENCE_URL=http://localhost:8000 PORT=8001 python services/cybersecurity/threat-detection/service.py
INFERENCE_URL=http://localhost:8000 PORT=8003 python services/cybersecurity/phishing-detector/service.py
INFERENCE_URL=http://localhost:8000 PORT=8011 python services/finance/fraud-detector/service.py
INFERENCE_URL=http://localhost:8000 PORT=8021 python services/manufacturing/process-anomaly-detector/service.py
```

For each one, check:
- `curl http://localhost:<port>/health` → 200, shows `service`, `domain`,
  `model_id`.
- Trigger it with a fake event and watch the terminal log a prediction (and
  either "published" to NATS or "no NATS connection, would publish"):
  ```bash
  curl -X POST http://localhost:8001/trigger -H 'content-type: application/json' \
    -d '{"features": {"packet_rate": 500, "byte_count": 1500000}}'
  ```
  → 200 with `{"published": true/false, ...}`. Both outcomes are fine —
  `false` just means the mock/trained model scored it below the alert
  threshold. Try a few different feature values if you want to see
  `published: true` at least once.

Any of the other ~30 stub services under `services/cybersecurity/`,
`services/finance/`, `services/manufacturing/` can be started the same way
but only `/health` will respond meaningfully — they have no real `/trigger`
logic yet.

## 3. Gateway

```bash
cd amcp-services/amcp-platform-services
NATS_URL=nats://localhost:4222 \
INFERENCE_URL=http://localhost:8000 \
THREAT_DETECTION_URL=http://localhost:8001 \
PHISHING_DETECTOR_URL=http://localhost:8003 \
FRAUD_DETECTOR_URL=http://localhost:8011 \
PROCESS_ANOMALY_DETECTOR_URL=http://localhost:8021 \
PORT=8080 python services/gateway/gateway.py
```

Check:
- `curl http://localhost:8080/health` → `nats_connected` is `true` only if
  you started a NATS broker in step 0; otherwise `false` is expected, not a
  bug.
- `curl http://localhost:8080/models` → same list as inference's `/models`,
  proxied.
- `curl http://localhost:8080/domains/status` → all four flagship services
  `"status": "up"` if they're running from step 2.
- `curl http://localhost:8080/alerts` → empty list if NATS isn't running or
  nothing has crossed the alert threshold yet; otherwise recent alert
  events, most recent first.
- `curl -X POST http://localhost:8080/domains/threat-detection/trigger -H 'content-type: application/json' -d '{"features": {"packet_rate": 9000, "byte_count": 50000000}}'`
  → relays to the threat-detection service and returns its response.

## 4. Angular web client (user dashboard)

```bash
cd amcp-clients/amcp-platform-clients/apps/web-client/amcp-web-client
npm install   # first time only
npm start     # ng serve, defaults to http://localhost:4200
```

Open `http://localhost:4200` in a browser and check:
- The **home** page loads without console errors and shows domain
  status/model info. Open browser devtools → Network tab and confirm it's
  hitting `http://localhost:8080/models`, `/domains/status`, `/alerts` (not
  just rendering static mock data) — if the gateway isn't running you
  should still see the page render using mock-data fallback, just with
  obviously placeholder-looking numbers.
- The **alerts** page loads and, if you triggered any alerts in step 2/3
  with a NATS broker running, shows them in the list.
- Stop the gateway (Ctrl+C in its terminal) and reload the dashboard — it
  should fall back to mock data instead of showing a blank/broken page.
  This confirms the `useGatewayData` fallback path in
  `platform-api.service.ts` actually works.

## 5. Angular admin client

This is a **separate** Angular app with its own API service and mock data —
it has not been wired to the gateway yet, so for now it's expected to only
show mock data.

```bash
cd amcp-clients/amcp-platform-clients/apps/web-client/amcp-admin-client
npm install   # first time only
npm run start -- --port 4201   # avoid colliding with the web client on 4200
```

Open `http://localhost:4201` and confirm it loads (mock data only, by
design — not a bug).

## 6. Desktop client (optional, Qt)

The Qt desktop client under
`amcp-clients/amcp-platform-clients/apps/desktop-client/` is a skeleton with
a `build/` directory already configured via CMake/Ninja. To try it:

```bash
cd amcp-clients/amcp-platform-clients/apps/desktop-client/build
ninja
./amcp-user-desktop/amcp-user-desktop   # or amcp-admin-desktop/amcp-admin-desktop
```

Treat this as UI-skeleton verification only (does it launch, does the
window render) — it is not expected to be wired to live backend data yet.

## 7. Everything at once via Docker Compose

Once you've verified the pieces individually, confirm the orchestrated
version works the same way:

```bash
docker compose up -d --build
./smoke-test.sh
docker compose logs -f gateway   # tail a specific service if something looks off
docker compose down
```

If `smoke-test.sh` reports `FAILED` (not `SKIPPED`) for anything, go back to
the matching numbered section above and run that piece standalone to
isolate the problem.
