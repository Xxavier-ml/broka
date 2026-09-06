# BROKA Calling — Architecture & Status

This documents BROKA's buyer↔seller audio/video calling system as of the
production-hardening pass described in CHANGES.md. It exists because
ARCHITECTURE.md doesn't currently cover calling at all.

## Architecture overview

WebRTC peer-to-peer media, with the backend acting purely as a signaling
relay plus authoritative call-session state:

- **`backend/api/core/call_state.py`** — the authoritative session store.
  Redis-backed in production (falls back to an in-memory store if
  `REDIS_URL` is unset, e.g. local dev), with an explicit state machine
  (see below) and an O(1) secondary index for the "is there a call waiting
  for me on this listing" poll.
- **`backend/api/routers/calls.py`** — REST endpoints (initiate, get a
  room-scoped token, TURN credentials, log a call's outcome, poll for a
  pending call) plus the `/calls/ws/{room_id}` WebSocket that relays SDP
  offers/answers and ICE candidates between exactly two authenticated
  participants. Live WebSocket connections are held in a process-local
  dict — see **Multi-instance limitation** below.
- **`backend/api/core/cloudflare_turn_client.py`** — generates short-lived
  Cloudflare Realtime TURN credentials on request. A real circuit breaker
  wraps the Cloudflare API call; on any failure the client falls back to
  STUN-only rather than failing the call.
- **`flutter_app/lib/services/webrtc_service.dart`** — the client-side
  peer connection, signaling, and recovery logic (generation-guarded
  against stale async callbacks, bounded reconnect/ICE-restart with
  backoff, a WebSocket heartbeat, queued ICE candidates, offer/answer
  caching for replay after a reconnect).
- **`flutter_app/lib/screens/voip_call_screen.dart`** — the call UI
  (ringing/accept/decline, in-call controls, outcome logging).
- **`flutter_app/lib/services/notification_service.dart`** — the *active*
  local-notification system (see **Incoming-call delivery** below).
- **`flutter_app/lib/services/call_foreground_service.dart`** +
  **`android/.../CallForegroundService.kt`** — keeps the mic/camera alive
  through backgrounding and screen lock via a real Android foreground
  service, for both the caller (from the moment they call) and the callee
  (from the moment they accept).

## Authoritative state machine

```
initiating → ringing → accepted → connecting → connected
                                                    ↕ disconnected (recovering)
ringing     → declined | missed | expired
any active  → failed
any active  → ended
```

All transitions are validated server-side (`call_state.is_valid_transition`);
duplicate same-state events are harmless no-ops, and terminal states
(`declined`, `missed`, `expired`, `failed`, `ended`) never transition back
to an active state. `connected` sessions use a separate, longer,
auto-renewing TTL from `ringing`/`connecting` sessions specifically so a
call lasting well over 2 minutes doesn't have its server-side session
disappear out from under it.

Call **outcomes** (for history/logging, via `POST /calls/log-result`) are
a business-level classification layered on top of the state machine, not
new states: `completed`, `declined`, `missed`, and `cancelled` (caller
hung up before any answer — distinct from `missed`, which means the
*callee* never responded; both map to the same underlying `missed`
CallState). Outcome recording is idempotent — whichever side's client
reports first wins, and the backend derives caller/callee/listing/call
type from the authoritative session rather than trusting the reporting
client's claims about any of them.

## Incoming-call delivery

Two mechanisms now work together, with clearly defined roles:

- **FCM (primary — background/terminated delivery).** Wired up this
  pass: `main.dart` initializes Firebase and registers foreground
  (`onMessage`), background (`onBackgroundMessage`, a required top-level
  entry-point function), tap (`onMessageOpenedApp`), and cold-start
  (`getInitialMessage`) handlers. The incoming-call push is sent
  **data-only** (no FCM `notification` block) specifically so the app's
  own code decides what to show — not a generic OS-displayed banner —
  regardless of foreground/background/terminated state. A device's FCM
  token is (re-)registered every time `GlobalPollerService.start()` runs,
  which already happens at every login/session-restore path, and again
  on token refresh.
- **Polling (foreground fallback).** `GlobalPollerService` polls
  `GET /calls/pending/{listing_id}` while the app is foregrounded (any
  screen, not just the negotiation screen for that listing). Both paths
  converge on the same `NotificationService.showIncomingCall` /
  `navigateFromPayload` — one call-routing mechanism regardless of which
  detected the call. The notification's ID is derived from `room_id`
  (not a fixed constant), so two different incoming calls get distinct
  notification slots while the same call detected through both paths
  still correctly collapses into one.

Tapping the notification (from either mechanism) re-verifies the call is
still live via `checkIncomingCall` and routes to `/voip-call` with a
fresh room-scoped token — never trusting the notification payload alone
for authorization, and never requiring the negotiation screen to already
be open.

**Everything above is wired up in code but not yet functional in
practice**: it depends on a real Firebase project + `google-services.json`
that don't exist in this repo (can't be committed) and haven't been set
up yet. See FCM_SETUP_REMAINING.md for exactly what's left, all of it
external configuration + device verification, none of it more code.

## TURN / ICE

`GET /calls/turn-credentials` returns short-lived Cloudflare-generated
credentials; Flutter never holds a static TURN secret. TURN is used only
as a relay fallback when direct/STUN connectivity fails, and the
connection-path diagnostic (`direct` / `stun` / `turn`) is derived from
the actual selected ICE candidate pair's type, not from whether TURN was
merely configured. Credentials are refreshed pre-emptively before an ICE
restart if they're within 2 minutes of expiry (not a continuous mid-call
refresh loop — BROKA's calls are short 1-to-1 sessions well under
Cloudflare's TTL, so that wasn't judged necessary).

## Android

A real foreground service (`microphone|camera` types) plus a partial wake
lock (with a 30-minute safety-timeout cap) keeps a call alive through
backgrounding and screen lock, for both parties. `usesCleartextTraffic`
is `false` in the shipped app (a debug-only manifest override keeps local
HTTP dev servers working). The incoming-call notification's
`fullScreenIntent` is backed by the `USE_FULL_SCREEN_INTENT` permission.
Native bridge calls (Dart ↔ Kotlin) fail safely on either side.

Known, deliberate non-goal: swiping the app away from Android's recents
list ends an active call rather than surviving it. True survive-anything
calling would need Android's Telecom/ConnectionService integration,
which is a real feature addition, not a hardening-pass fix.

## iOS

**No calling infrastructure exists.** The `ios/` tree in this repo export
has no `AppDelegate.swift`, no Xcode project files, no Podfile, and
`Info.plist` is an unmodified Flutter template with no VoIP/PushKit/
CallKit/background-mode configuration. This was confirmed by inspection,
not assumed — and deliberately not faked with untested Swift. iOS calling
is DEFERRED, not implemented, not partially implemented.

## Multi-instance limitation

Call *state* is Redis-backed and already safe across multiple backend
instances. Live WebSocket *connections* are held in a process-local dict
(`_rooms` in `calls.py`), which is **single-instance only** — two peers
signaling through different backend instances would never reach each
other. This is fine for the current single-instance Render deployment and
is explicitly not being solved in this pass (per its own scope); the
state/connection split is deliberate so a Redis Pub/Sub (or similar)
relay layer could be added later without redesigning `call_state.py`.

## Required environment variables

| Variable | Purpose |
|---|---|
| `REDIS_URL` | Backs `call_state.py`'s session store and rate limiting. Falls back to in-memory (single-process only) if unset. |
| `CLOUDFLARE_TURN_KEY_ID`, `CLOUDFLARE_TURN_API_TOKEN` | Generate short-lived TURN credentials. Falls back to STUN-only if unset/failing. |
| `CLOUDFLARE_ACCOUNT_ID` | Optional, used alongside the above. |
| `CALL_TOKEN_EXPIRE_MINUTES` | Room-scoped call token lifetime (default 5). |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | Backend FCM push capability (already implemented server-side; see FCM_SETUP_REMAINING.md for the still-missing client half). |

## What device testing must still confirm

None of the following has been verified on a physical device as of this
pass — everything above was arrived at through direct code reading, a
standalone simulation of the event-loop fix, and static/syntax checks
only, in a sandboxed environment with no Flutter toolchain, no physical
device, and no live Redis/Cloudflare/FCM to test against:

- All four call directions (buyer/seller × audio/video) end to end.
- The WebSocket heartbeat and client watchdog under a real flaky/dropped
  connection, not a simulated one.
- The pre-restart TURN credential refresh (`setConfiguration()`) actually
  behaves as expected on-device.
- Foreground/background/screen-lock behavior on a real Android device.
- **FCM delivery end to end** — foreground, backgrounded, and fully
  terminated — once a real Firebase project + `google-services.json`
  exist (see FCM_SETUP_REMAINING.md). Nothing about the FCM wiring has
  been compiled, run, or confirmed to actually wake a terminated app.
- The full physical-device test matrix in the hardening pass's own spec
  (two devices, all call/network/lifecycle combinations).

See CHANGES.md for the full list of bugs found and fixed during this
pass, and its final report for exact readiness status per platform/
direction.
