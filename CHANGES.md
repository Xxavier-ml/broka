# BROKA — Round 22: FCM client integration (final calling-completion pass)

Xavier's final ask for calling: incoming calls must work reliably for
both roles including backgrounded/terminated app states, "to the extent
supported by the target platform" - not just sophisticated WebRTC code.
Same verification discipline as every round before it, with one
important difference to be upfront about: this round's core deliverable
(real FCM client integration) has a hard external dependency this
sandbox cannot satisfy or verify - a real Firebase project and its
`google-services.json`, which only Xavier can create and which must
never be committed. Everything below was written and reasoned through as
carefully as static review, syntax/compile checks, and (for the backend
half) an actual executable test allow; **none of it has been compiled,
run, or verified on a device**. See the final status at the end.

## Backend

**FCM push is now sent data-only.** The `/calls/initiate` push included
both an FCM `notification` block and a `data` block. A `notification`
block gets auto-displayed by the OS using generic system styling
whenever the app isn't foregrounded - for an incoming call, that means a
plain banner instead of the app's own rich notification (full-screen
intent, custom ringtone, call-specific styling), completely bypassing
it. `_send_fcm()` gained an opt-in `data_only` parameter (default
preserves the exact existing behavior for its other three call sites in
`workers.py`, which are unrelated reminder/nudge notifications, not
calling); the `/initiate` call site now passes `data_only=True`. Added
`test_incoming_call_push_is_data_only` to verify this, mocking
`_send_fcm` to inspect the call rather than requiring a real Firebase
project.

## Flutter - full FCM client integration

**`pubspec.yaml`**: added `firebase_core`/`firebase_messaging`. Versions
are a best-effort estimate from training knowledge, compatible with this
project's Flutter/Dart SDK constraint - **not verified against a live
pub.dev**, since this sandbox has no network access. Run `flutter pub
get` to confirm/resolve.

**Android Gradle**: the Google Services plugin is declared in
`settings.gradle` (matching this project's existing plugins-DSL
convention exactly - the same style already used for the Android/Kotlin
plugins there) and applied *conditionally* in `app/build.gradle`, only
if `google-services.json` exists - mirroring the identical
conditional-file pattern this project already uses for its release
signing keystore. The app builds exactly as it does today until that
file is added; nothing breaks in the meantime. `.gitignore` updated so
that file can never be accidentally committed once it exists.

**`main.dart`**: `Firebase.initializeApp()` wrapped in try/catch - without
a real Firebase project this throws, and the catch means the app runs
exactly as it always has (local notifications via polling only) rather
than crashing on startup for every user until Xavier's project exists.
Inside that guard: the background message handler
(`firebaseMessagingBackgroundHandler` - a top-level
`@pragma('vm:entry-point')` function, as FlutterFire requires for it to
survive tree-shaking and run as its own isolate entry point),
`onMessage` (foreground), `onMessageOpenedApp` (tap while backgrounded),
`getInitialMessage()` (cold-start tap - stashed since no navigator
exists yet at this point in `main()`, consumed by `SplashScreen` once it
does), and `onTokenRefresh`.

**One shared call-routing mechanism, not a second system**:
`notification_service.dart` gained `handleForegroundFcmMessage()`, which
calls the exact same `showIncomingCall()` the poller already calls -
foreground behavior is identical no matter which mechanism detected the
call. `navigateFromPayload()` (already fixed in an earlier round) now
serves local-notification taps, `onMessageOpenedApp`, and
`getInitialMessage` alike.

**Removed the dormant `lib/core/notifications/`** (a complete but never-
imported parallel Firebase implementation, flagged in earlier rounds).
With real FCM now wired into the actually-used files, keeping it around
would have been exactly the duplicate/unused Firebase code this pass was
asked to look for and remove.

**Token lifecycle**: `api_service.dart` already had a correct, unused
`registerFcmToken()` (dead code from earlier FCM-readiness work, never
wired up). It's now called from `GlobalPollerService.start()` - already
the one function every login/registration/biometric-reauth/session-
restore path calls, so registering there covers all of them without
duplicating the call at each site, and naturally re-associates the token
with whichever user is now authenticated on a given device. Also wired
to `onTokenRefresh` for the case of a token changing under an
already-running session.

**Two-different-calls notification gap fixed along the way**: every
incoming-call notification previously shared one fixed notification ID
- a second distinct call (rare, but possible) would have silently
replaced the first rather than getting its own slot. The ID is now
derived from `room_id`, so different calls get distinct notifications
while the *same* call detected through both FCM and polling still
correctly collapses into one.

## Final Self-Audit (done explicitly, not assumed)

Checked for: duplicate notification handlers (found and removed the
dormant system above), stale imports (none left dangling), hardcoded
credentials (none - `google-services.json` is referenced only by a file-
existence check, never embedded), token value logging (none - only
non-value log lines like `TOKEN_ISSUED` existed already), role-specific
incoming-call assumptions (already fixed in an earlier round; re-
confirmed clean here), navigation races (the cold-start path clears its
pending state immediately on read, before acting on it, so a
theoretical re-entry is a safe no-op), and one now-stale doc comment in
`notification_service.dart` referencing a symbol that didn't actually
exist anywhere in the file (a leftover from before this round - removed).

## Final status

**Code hardening complete for what a sandboxed environment can produce
and verify — physical device verification and Xavier's own external
Firebase setup are both still required before this is actually
"working" in the sense the objective describes.** More precisely, three
distinct things are true simultaneously:

- Every piece of Flutter/Gradle code needed for FCM client integration
  is now written, follows the platform's required patterns as I
  understand them, and is defensively guarded so it cannot break the
  app for anyone building it before Firebase is configured.
- **None of it has been compiled.** No `flutter pub get`, no `flutter
  analyze`, no `flutter build`, in this sandbox - no network, no Flutter
  toolchain. The package versions are a best estimate, not a
  verification.
- **None of it has been run.** Real FCM delivery - foreground,
  backgrounded, fully terminated - requires Xavier's own Firebase
  project, a real device, and an actual push round-trip. Nothing here
  confirms an incoming call actually wakes a terminated app; it
  confirms the code that's supposed to make that happen is in place and
  reads correctly.

The backend half (`data_only` push) is the one piece of this round
covered by an executable, passing-by-inspection test
(`test_incoming_call_push_is_data_only`) rather than reasoning alone.



Xavier's ask started narrow (backend tests failing in CI, then a Flutter
build failure) and grew into the full "final production-hardening pass
for calling" spec he provided partway through - 19 phases, an explicit
exit-criteria checklist, and an explicit rule not to declare it complete
without real verification. Same discipline as every other round in this
file: every finding checked against the actual current code (not the
prior summary of work Xavier provided, which was treated as a claim to
verify, not a fact to build on - most of it held up; a few things it
didn't mention or got slightly wrong are called out below), nothing
shipped without at least a syntax/compile check, and every genuinely
untestable claim marked as such rather than asserted. No Flutter/Dart
toolchain, no physical device, no live Redis/Cloudflare/FCM, and no
network access existed in the sandbox this round was done in - see
**What's still open** at the end for exactly what that means.

## Backend CI unblock (the original ask)

Two independent bugs, both in `call_state.py`, were failing 13/13 tests
in `test_call_state.py`:

1. **Event-loop mismatch.** `_store` is a module-level singleton whose
   Redis client was cached forever once created. `asyncio_mode = auto`
   gives every test function its own fresh event loop, so the cached
   client's connections - bound to whichever loop created them - broke
   the moment a different test reused them, producing the exact
   `Future ... attached to a different loop` / `Event loop is closed`
   errors in the failing run, with a alternating pass/fail pattern
   (redis-py silently discards a broken connection and reconnects fresh
   on the next call). Fixed by rebuilding the client whenever the running
   loop differs from the one it was built on - a no-op in production,
   which never changes loops. Verified with a standalone asyncio
   simulation reproducing the exact failure pattern before the fix and
   all-pass after, since the real dependency wasn't installable here.
   The identical pattern existed in `rate_limit.py` (its own docstring
   calls out sharing "the same shape") - fixed pre-emptively, though it
   wasn't causing visible failures since that class already fails open on
   Redis errors.

2. **Invalid Redis TTL.** Two expiry tests use `ttl_seconds=0` to
   simulate an already-expired session; `_RedisCallStore.create()` passed
   that straight through to Redis's `SET ... EX 0`, which Redis rejects
   outright. `_write()` and `set_pending()` in the same class already
   clamped this to `max(ttl_seconds, 1)` - `create()` just missed it.
   One test (`test_sweep_removes_expired_sessions`) also assumed
   in-memory-only sweep semantics that the Redis backend's *documented*
   no-op `sweep_expired()` (Redis's own key TTL handles it) can never
   satisfy - made that one assertion backend-aware instead of asserting
   something structurally impossible for the Redis path.

Separately, the next CI run surfaced a Flutter build failure:
`webrtc_service.dart:882` assigned a `Map<dynamic, dynamic>` (from
`flutter_webrtc`'s `StatsReport.values`) directly into a
`Map<String, dynamic>?` variable, which Dart's compiler rejects even
though every key is always a string in practice. Fixed with an explicit
`Map<String, dynamic>.from()` conversion.

## Full calling-system audit

With CI green, Xavier provided the full hardening spec and confirmed the
uploaded release zip matches `main`. What follows is organized by the
spec's own phase numbers.

**Phase 2 (incoming-call pipeline) - one real bug the prior summary
hadn't caught.** The *live* notification tap handler
(`notification_service.dart`'s `navigateFromPayload`) sent every
incoming-call notification tap to `/direct-chat` with a **hardcoded
`role: 'seller'`**, instead of the actual call screen - a tapped
incoming-call notification never opened the call UI at all, and
misidentified the recipient's role whenever a buyer received one.
Ironically, a complete-but-entirely-dormant "v3.0" Firebase notification
system (`lib/core/notifications/`, confirmed never imported anywhere in
real app code) already had the *correct* routing logic. Fixed the live
path to match: re-check the call's live status via the existing
`checkIncomingCall(listingId)` endpoint at tap time (a fresh, still-valid
room-scoped token, rather than trusting anything time-sensitive from
when the notification was first shown) and route to `/voip-call` with
the correct role, falling back to chat only if the call's no longer
pending.

**Phase 5 (WebSocket reliability) - heartbeat was genuinely absent.**
Read the entire WS handler; there was no ping/pong and no receive
timeout at all, so a silently-dropped mobile connection (no clean
FIN/RST) was only ever caught by the underlying TCP stack's own
often-multi-minute dead-peer detection. Implemented on both sides:
server pings every 15s via `calls.py`, closes after 3 missed (~60s total
silence, with an explicit close frame rather than relying on the ASGI
server's own handler-return behavior); client replies to pings and also
runs its own independent 25s watchdog that proactively reconnects if
nothing arrives at all, rather than depending solely on the transport's
error/close callbacks. Also hardened the receive loop against malformed
(non-JSON or non-object) signaling messages, which previously would have
thrown unhandled and killed the loop for that connection.

**Phase 7 (TURN/ICE) - refresh groundwork existed but was never wired
up.** `cloudflare_turn_client.py` itself checked out clean (real circuit
breaker, no secret leakage, correct STUN/TURN separation, graceful
degradation). `webrtc_service.dart` already tracked credential expiry
(`_iceCredentialsExpireAt`) with a comment naming
`RTCPeerConnection.setConfiguration()` as the intended mechanism, never
implemented. Wired it up: `_attemptIceRestart()` now refetches TURN
credentials and calls `setConfiguration()` if they're within 2 minutes of
expiry, before restarting - deliberately a pre-restart check only, not a
continuous mid-call refresh loop (not justified for BROKA's short 1-to-1
calls, per the existing design note). Defensively wrapped: since
`setConfiguration()`'s exact behavior on this `flutter_webrtc` version
couldn't be verified without a device, any failure here falls through to
restarting with whatever configuration is already active - never worse
than the prior always-stale behavior, only better if it works.
**DEVICE-VERIFICATION-REQUIRED.** Separately confirmed the "don't falsely
claim TURN was used" requirement was already correctly implemented - the
connection-path diagnostic checks the actual selected candidate pair's
type (`relay`/`srflx`/`host`), not just whether TURN was configured.

**Phase 9 (Android) - two real gaps.** `CallForegroundService.kt`, the
native bridge, and the Dart wrapper were all solid on inspection (partial
wake lock with a 30-minute safety cap, try/catch on both sides of the
platform channel, and - specifically checked, not assumed - both caller
and callee correctly trigger the foreground service, no asymmetry).
Found and fixed: (1) `usesCleartextTraffic="true"` shipped app-wide even
though production always defaults to HTTPS - moved to a new
`android/app/src/debug/AndroidManifest.xml` override so release builds
can never carry unencrypted traffic while local dev against an HTTP
server still works; (2) the incoming-call notification already sets
`fullScreenIntent: true` (correctly configured otherwise - max priority,
call category, custom ringtone) but the manifest never declared the
`USE_FULL_SCREEN_INTENT` permission that flag depends on, so it likely
silently degraded to a plain heads-up notification on modern Android -
added it. One stale (not fixed - cosmetic only), overly-pessimistic code
comment was found describing a reconnect "room full" race that the
server's actual uid-keyed stale-socket-replacement logic already handles
correctly.

**Phase 10 (iOS) - confirmed, not invented.** The exported `ios/` tree
has only `Info.plist` and icon assets - no `AppDelegate.swift`, no Xcode
project files, no Podfile, and the plist is an unmodified Flutter
template with zero VoIP/CallKit/background-mode configuration. Matches
the prior account. Per the spec's own explicit instruction, documented
this rather than writing untestable Swift.

**Phase 11 (call-result security) - a real outcome-classification gap.**
There was no way to distinguish "caller cancelled before the callee
answered" from "callee never responded" - both were recorded as
`missed`. Worse: the call-history card widget only had explicit handling
for `missed`/`declined`, so naively adding a `cancelled` value without
updating it would have made cancelled calls silently render as
*successfully completed* ones - caught before shipping it. Fixed across
`calls.py` (new `cancelled` outcome, mapped to the existing `missed`
CallState rather than inventing a new terminal state), `voip_call_screen.
dart` (distinguishes via the existing `_isCaller` flag), and the history
card (own icon/label, still offers "Call back"). Everything else in
`calls.py`'s `/log-result` - idempotency, deriving identity from the
authoritative session rather than the client's claims - checked out
exactly as the prior account described.

**Phase 12 (security audit) - one genuinely exploitable gap found.**
`POST /calls/initiate` let a seller supply an arbitrary `callee_id` and
would create a call session (plus send an FCM push, when configured) to
**any** registered user, with no check that a real negotiation thread
ever existed between that buyer and the listing - any seller could
effectively cold-call/harass any other user on the platform. Fixed by
requiring an existing `NegotiationMessage` row for that
`(listing_id, buyer_id)` pair before allowing the call, mirroring the
identical thread-scoping check already used elsewhere in the codebase
(`negotiate.py`/`media.py`) rather than inventing a new pattern. One
accepted tradeoff, not swept under the rug: legacy `NegotiationMessage`
rows with a `NULL buyer_id` (a pre-existing data-quality note already in
that model) won't satisfy this check, so a genuinely old thread could see
a 403 - fails safe rather than unsafe, and self-heals the moment the
buyer sends one new message. Also: replay/enumeration risk was checked
and is already handled (a token can't be replayed against a terminal
session; 128 bits of room-ID entropy; 5-minute call-token expiry), and a
targeted sweep for tokens/SDP/credentials leaking into logs on either
side found nothing.

**Endpoint-level test coverage did not exist at all** for `calls.py`
before this pass - `test_call_state.py` only exercises the internal
store directly, never the actual HTTP routes. Added
`tests/test_calls_initiate.py`, covering the fix above plus five other
cases from the spec's required test list (buyer/seller happy paths,
missing `callee_id`, self-call, invalid listing) - written carefully
against the real model and endpoint code, mirroring `test_auth.py`'s
established SQLite-fixture/`AsyncClient` pattern, but **not executed**
(no pytest/DB in this sandbox).

**`voip_call_screen.dart` - a real duplicate-action gap.** The Accept
button had no guard against a rapid double-tap, and
`WebRtcService.start()` has no internal idempotency check of its own - a
double-tap could fire two concurrent media/connection setups (two
camera/mic requests, two peer connections). Fixed by guarding Accept
(reusing the existing `_accepted` flag) and adding a shared `_endingCall`
guard across Decline, both hangup buttons, and the ring-timeout
auto-hangup path, so none of the four ways a call can end can fire
twice.

**Phase 15 (observability) - one real gap, one dangling hook.** ICE
restart count was tracked internally (for bounding retries) but never
surfaced in the `ConnectionDiagnostics` summary alongside the setup-time
and reconnect-count fields that already were - added it. Separately,
`onDiagnostics` itself was never actually assigned to anything in
`voip_call_screen.dart`, so the whole diagnostics summary reached nothing
outside the service - wired it to a single local debug log line per
call, explicitly not sent anywhere, per the spec's own caution against
implying backend reporting that isn't happening.

**Phase 18 (CI) - `flutter analyze` never ran at all.** The build
workflow only ever ran `flutter pub get` then the full release build -
no static-analysis step in between, meaning a type error (the exact
class this round's own Flutter build fix was) would only surface after
the much slower full APK build. Added a non-blocking `Analyze` step
between them - non-blocking specifically because this pass doesn't
include auditing every pre-existing lint warning across the whole app,
and a sudden strict gate here could block releases over unrelated
findings. Also incidentally explains why the GitHub release had been
stuck since June: `build-apk` `needs: backend-test`, and the backend
tests had been failing since before this round started.

**Phase 19 (docs).** Added `CALLING.md` (architecture, state machine,
incoming-call flow, TURN flow, Android/iOS status, the multi-instance
limitation, required env vars, and what device testing must still
confirm - none of it existed as a single reference before), linked from
`ARCHITECTURE.md`, and added a small note to `FCM_SETUP_REMAINING.md`
about `navigateFromPayload`'s now-more-defensive behavior.

## Final status

Per the spec's own exit-criteria and decision rule:

- **Buyer→seller / seller→buyer**: code-level symmetry confirmed
  (`_initiateCall` handles both directions correctly, the seller-side
  spoofing gap above is fixed) - **ready for device testing**, not
  verified beyond that.
- **Android**: foreground/background lifecycle, permissions, and the two
  fixes above are in solid shape on inspection - **ready to move forward
  pending the actual device-test matrix** (Phase 17), which this sandbox
  cannot run.
- **iOS**: **DEFERRED** - zero infrastructure, confirmed and documented,
  not invented.
- **Multi-instance signaling**: **known, documented, deliberate
  limitation** - state is already Redis-safe; live WS connections are
  not, by design, for this pass.
- **HIGH/CRITICAL remaining**: none identified in this pass's own review
  beyond what's listed as still open below.

**This is explicitly not "CALLING HARDENING COMPLETE."** Phase 17
(physical-device test matrix) has not been run - it categorically cannot
be, in a sandbox with no phone, no Flutter toolchain, and no live
network. Every fix above was verified as rigorously as static reading,
compile/syntax checks, and (for the event-loop fix specifically) a
standalone reproduction allow - not by actually placing a call. Before
moving to the next BROKA feature, Xavier needs to: run the two new/
updated backend test files in real CI, get a real `flutter analyze` +
release build, and run the physical-device matrix from Phase 17 (two
devices, all listed call/network/lifecycle combinations) - classifying
any failure found there as CODE BUG / INFRASTRUCTURE / DEVICE LIMITATION
/ TEST ISSUE per the spec's own instruction, not assuming the best case.



Continuing the production-readiness pass from Round 19 (security) into
scalability - the second category requested, in the order requested.
Same discipline: every finding verified against the actual code, every
fix re-compiled and manually traced, nothing assumed correct because it
looked fine on a skim.

**Database connection pool had zero tuning.** `create_async_engine()` was
called with no `pool_size`, `max_overflow`, `pool_recycle`, or
`pool_pre_ping` - SQLAlchemy's bare defaults. Missing `pool_recycle`
specifically is a well-known production failure mode: most managed
Postgres providers (Render's included) silently close connections that
sit idle past some server-side timeout, and without `pool_recycle` set
below that, SQLAlchemy can hand out a connection the server already
dropped - surfacing as an intermittent "connection was closed" error
that looks random and hits hardest during low-traffic periods. Fixed:
added `pool_recycle=300`, `pool_pre_ping=True` (a cheap liveness check
before handing out any pooled connection, second layer of defence), and
made `pool_size`/`max_overflow` env-configurable (`DB_POOL_SIZE`,
`DB_MAX_OVERFLOW`, defaulting to 10/20) since the right ceiling depends
on Xavier's actual Postgres plan's connection cap, not something this
code can know. Scoped to only apply for real network-hop databases -
SQLite (this app's dev default) doesn't use the same pool model and
`create_async_engine` rejects these kwargs for it.

**Multiple real N+1 query patterns, found with a systematic sweep, not
just the ones already suspected.** Wrote a small AST-based scanner (a
for-loop containing an `await ...execute()` call) across the whole
backend rather than relying on spot-checks, then triaged every hit -
some were false positives (one-time startup schema patches, a one-time
category-seeding script), the rest were real:

- `domains/trust/completion_rate.py`'s `flag_leaked_deals()` and
  `recompute_all_dcr()` (both from Rounds 16/18) - 2 queries per
  candidate deal and 2 queries per seller respectively, meaning query
  count scaled linearly with deal/seller volume. Batched: one query per
  evidence type across the whole run instead of per-record, with the
  per-record time-scoping now done in memory against the already-fetched
  set. Re-traced all three existing `test_completion_rate.py` tests by
  hand against the batched logic to confirm identical outcomes to the
  original per-record version before considering this done - same
  discipline as when those tests were first written, since nothing here
  can actually be executed in this sandbox.
- `routers/negotiate.py`'s `get_inbox()` - a real N+1 nested two levels
  deep on the seller-view side (one query per listing, then one query
  per buyer on that listing). Batched the buyer-view's per-listing
  Listing+User fetch and the seller-view's per-listing re-fetch (which
  was refetching listings the function already had, individually) and
  per-buyer User fetch into single `IN (...)` queries. Deliberately
  **not** touched: the per-thread "last message" query and
  `_thread_unread_and_seen()` (which itself does 2 more queries per
  thread). Batching those needs a greatest-n-per-group query and directly
  touches unread/last-seen state - real remaining work, left for a
  focused pass rather than rushed alongside everything else here, since
  getting that subtly wrong without live-data testing is a worse outcome
  than leaving it as a known, flagged gap.
- `routers/reviews.py`'s review-submission and reviewable-deals-list
  endpoints - found while fixing the N+1 in the second one (see below for
  why the first turned out to matter far more).

**Found something more serious while looking at that reviews.py N+1:
`DealStatus.completed` doesn't exist on that enum** (the same bug flagged
and left alone earlier this session, back when it was out of scope -
now directly in a file already being edited for this pass, so fixed
properly rather than left a second time). Consequence: `submit_review()`
evaluated `(DealStatus.agreed, DealStatus.completed)` as part of its
eligibility check, which raises `AttributeError` the instant it runs,
for every deal regardless of status - meaning this endpoint has never
successfully completed a review. Fixed the typo to `DealStatus.released`.
But the deeper issue was what came after the crash: on success, the
endpoint set `deal.status = DealStatus.completed` and bumped
`seller.completed_deals`, labelled "idempotent guard" - except
`completed_deals` is already correctly bumped by the actual escrow-
release flow (`routers/escrow.py confirm_delivery`, the auto-release
sweep). Naively patching the enum typo without noticing this would have
gone from "reviews always crash" to "reviews double-count completed_deals
for every deal that's both released and reviewed" - the normal case, not
an edge case. Removed the status mutation and the counter bump entirely;
a review now only creates the Review row and updates the seller's rating
(`_recalc_seller_rating`, which is already purely Review-table-based and
unaffected). Fixed the identical typo in the reviewable-deals list too.

**Deal and NegotiationMessage were both missing indexes on their most
heavily-filtered columns.** `Deal` had none at all on `seller_id`,
`buyer_id`, `listing_id`, or `status` - every query in every round this
session that filters a deal by any of these (which is most of them:
`compute_dcr`, `seller_deal_stats`, the sweep's `due_deals`, escrow
flows) was a full table scan. `NegotiationMessage` had none at all,
despite `(listing_id, buyer_id)` being the thread-identity pair queried
constantly throughout `negotiate.py` and this session's leak-detection
work. (Checked `Listing` too, expecting the same gap - it already has
proper indexes on `seller_id`/`category`/`status`/`created_at`, so left
untouched; verifying before fixing caught this before wasting effort
"fixing" something that wasn't broken.)

Fixed both where the fix actually needs to happen twice: `index=True` /
a new composite `Index("ix_negotiation_messages_listing_buyer",
listing_id, buyer_id)` added to the model definitions (covers a fresh
deployment via `create_all()`), and a matching new `CREATE INDEX IF NOT
EXISTS` block added to `init_db()`'s existing ad-hoc schema-patch
mechanism (covers Xavier's already-created tables, which `create_all()`
never retroactively indexes - the exact same "gap that only bites an
existing deployment" shape as the missing-column bug Round 18 fixed,
just for indexes instead of columns). `CREATE INDEX IF NOT EXISTS` is
portable across SQLite and Postgres, unlike `ALTER TABLE ADD COLUMN`'s
`IF NOT EXISTS` support, which isn't reliable on SQLite - hence that
block still using try/except instead.

**Verification:** every file re-compiled clean, full session-wide
regression check re-run (not just this round's files), and the batched
`flag_leaked_deals()`/`recompute_all_dcr()` logic re-traced by hand
against all three existing tests, not just re-read and assumed
equivalent. Nothing here could be run against a real Postgres instance
or measured under actual concurrent load - the pool tuning and index
additions are reasoned from documented SQLAlchemy/Postgres/SQLite
behaviour, not benchmarked.

**Scalability is not fully closed out - still open, flagged rather than
silently skipped:**
- `get_inbox()`'s per-thread last-message and unread/seen queries (noted
  above)
- `core/workers.py`'s single in-process sweep loop won't coordinate
  across multiple app instances if BROKA ever runs more than one - though
  Round 19's row-locking fix means this is now *safe* under multi-
  instance concurrency (Postgres row locks work across separate
  processes/connections, not just within one), just not *efficient*
  (every instance would still redundantly poll)
- Several places construct a fresh `redis.asyncio` client per call
  (`core/stats_cache.py` and similar patterns elsewhere) rather than
  reusing a shared connection pool - real latency/resource cost at
  meaningful request volume, not yet addressed
- Media (voice notes, images) stored as base64 in the relational
  database rather than object storage - noted in Round 19 as a
  scalability concern when it was found from the security angle, not
  yet addressed here either

Continuing into these, and then the remaining "everything else"
category, next.

---

# BROKA — Round 19: Production-readiness audit, Phase 1 (Security)

Xavier asked for a full production-readiness pass - security, scalability,
everything else - treating this as potentially the last review before
launch. Tackling it in the order requested: security first. This round
covers security; scalability and the rest are still ahead.

Framed honestly at the start and worth repeating here: a codebase this
size doesn't get a genuine 9.5/10 audit in one sitting, and some things
(real load testing, a live penetration test, a second engineer's review)
need infrastructure this sandbox doesn't have. What follows is a
systematic pass through the highest-stakes categories for a payments
marketplace, with every finding verified against the actual code before
acting on it - the same discipline every other round this session has run
on - not a checklist skimmed and assumed correct.

**Two severe, exploitable bugs found and fixed:**

1. **Payment-callback forgery across three endpoints.** `mpesa.py`,
   `verify.py`, and `featured.py` each expose a Safaricom STK-callback
   route. `mpesa.py` had a secret-protected variant already built but the
   original unprotected route only logged a warning and processed the
   callback anyway - the warning did nothing. `verify.py` and
   `featured.py` had no protection at all. Net effect: anyone who could
   observe or guess a `CheckoutRequestID` (issued the moment any STK push
   starts, before payment completes) could POST a forged
   `{"ResultCode": 0, ...}` body and have a deal marked paid, get free
   "BROKA Verified" status, or get a free listing boost, with no real
   M-Pesa payment behind any of it.

   Fixed: all three routes now reject outright (404, not a warning) once
   `MPESA_CALLBACK_SECRET` is configured; `verify.py`/`featured.py` gained
   the missing secret-protected variants, mirroring `mpesa.py`'s existing
   pattern; and `MPESA_CALLBACK_SECRET` is now required at startup in
   production (`validate_startup()` in `core/config.py`), so this can't
   silently ship unconfigured. The env var itself, and the reasoning for
   it, were already documented in `.env.example` before this round - the
   code just never fully implemented what the docs described. Updated
   that comment to reflect it now covers all three routes and is
   required, not merely recommended.

2. **No row-level locking anywhere in the codebase, for a genuinely
   racy fund-moving flow.** The automated timeout sweep
   (`core/workers.py`) and manual buyer/seller actions
   (`routers/negotiate.py`, `routers/escrow.py`) check the *same* deal
   statuses to decide refund/release eligibility (`awaiting_resolution`,
   `awaiting_condition_check`, and `paid` all appear in both the sweep's
   `due_deals` filter and at least one manual endpoint's check) - meaning
   both could read a deal as eligible before either committed, and both
   fire a real M-Pesa B2C payout for the same deal.

   Fixed with a new shared helper,
   `domains/escrow/service.lock_deal_if_status()` - a `SELECT ... FOR
   UPDATE` row lock plus a re-check of status at the moment the lock is
   acquired, returning `None` if another transaction already moved the
   deal past that status. Real lock on Postgres; SQLAlchemy silently
   drops the clause on SQLite (this app's dev default, per
   `.env.example`), so the status re-check still runs there but without
   true concurrent protection - acceptable since `validate_startup()`
   already refuses to start in production on SQLite, so the dialect that
   matters for real concurrent traffic is the one where the lock holds.

   Applied at four call sites: the sweep's single per-deal dispatch point
   in `core/workers.py` (protects all five of its downstream timer
   branches at once, since they all act on whatever `deal` object the
   loop hands them), `negotiate.py`'s manual refund and manual release
   intents, and `routers/escrow.py`'s `confirm_delivery` endpoint - found
   by continuing to check every release/refund code path in the
   repository rather than stopping once the first two were fixed. That
   fourth one was missed on the initial pass; caught by deliberately
   re-sweeping for the same pattern rather than assuming two fixes meant
   the class of bug was closed.

**Checked and confirmed already solid, no action needed:**
- `SECRET_KEY`/`ZAC_SECRET` both have hardcoded fallback placeholder
  values in source, which looks alarming in isolation - but both are
  already enforced via `validate_startup()`/`validate_secret_key()`,
  which hard-fail production startup if either is still the default.
  Verified this is actually wired into `main.py`, not just present as
  unused functions.
- Rate limiting on login/register/OTP-request/OTP-verify: real Redis-
  backed sliding-window limiters, double-keyed where it matters (OTP
  request checks both phone and IP; login checks both IP and phone),
  correctly loosened only under `is_test`, confirmed properly scoped and
  not reachable from production config.
- JWT verification pins `algorithms=["HS256"]` explicitly rather than
  trusting the token's own header - correctly closed against algorithm-
  confusion attacks.
- No raw/string-formatted SQL anywhere in the backend - every query
  goes through SQLAlchemy's parameterized query builder.
- The v5 dispute engine's `_load_case_and_authorize()` already properly
  restricts every `/disputes/v2/{case_id}/*` endpoint to the deal's
  actual buyer, seller, or an admin - this fix predates this session
  (the docstring documents it as closing a prior IDOR bug), re-verified
  rather than assumed correct.
- `negotiate.py`'s message-history and inbox endpoints derive
  buyer/seller role server-side from the authenticated user, never from
  a client-suppliable role field, and reject cross-user inbox access
  outright.
- Media upload (`routers/media.py`) stores files as base64 data URIs in
  the database, never writes to disk with an attacker-influenced
  filename - no path-traversal surface exists for this upload path.
  (Storing binary media in the relational database at all is a
  scalability concern, not a security one - flagged for that phase.)

**Adjusted, not hard-failed:** CORS defaults to `allow_origins="*"` if
`ALLOWED_ORIGINS` is unset. Confirmed this backend has zero cookie-based
authentication anywhere in the codebase (grepped for `set_cookie`/
`request.cookies` - no matches) - auth is Bearer-token-only, attached
explicitly by the calling client rather than automatically sent by a
browser the way a cookie would be, which significantly de-risks a
wildcard origin compared to a cookie-authenticated app (no CSRF-style
account-takeover path). Still worth tightening - defense-in-depth, and
it only takes one future browser-based admin panel to change the
calculus - so added a production-startup **warning** (not a hard fail,
given the genuinely lower exploitability today) if `ALLOWED_ORIGINS` is
still unset in production.

**Not done, deliberately:** a live penetration test, dependency-CVE
scanning against a real vulnerability database (no network access in
this sandbox to run one), and load testing against real concurrent
traffic - all need infrastructure this environment doesn't have. Noted
here rather than silently skipped.

**Verification:** every file re-compiled clean with `py_compile`, plus
manual tracing for the undefined-name/wrong-variable class of bug
`py_compile` can't catch - the same discipline as every other round.
Nothing in this round could be exercised against a running server or a
real Postgres instance, so the row-locking fix's actual concurrent
behaviour is reasoned through (SQLAlchemy's documented `with_for_update`
semantics per dialect), not observed directly.

---

# BROKA — Round 18: External audit response — three real bugs fixed, ranking formula made faithful, tests added

Xavier shared a ChatGPT audit of the Volume 2 implementation. Checked it
against the actual code rather than trusting it (the same discipline this
whole effort has run on) - it turned out to be a mix of stale findings
(run against the pre-Round-17 zip, before the ML layer and Zeno persona
existed) and several genuinely correct, serious findings against code that
*is* current. Verified every claim independently before acting on any of
them; this round fixes what checked out.

**Confirmed stale, no action needed:** the audit's "ML layer essentially
not implemented" and "Zeno seller persona - significant gap" findings.
Both exist as of Round 17 (`core/ml/`, `SELLER_COACHING_PROMPT_ADDITION` +
the `zeno_seller_coach` override) - confirmed by checking the actual
working tree before writing anything, not by assuming the audit must be
wrong. Xavier confirmed separately that the audit ran against "the second
last source code."

**Three real, confirmed bugs, fixed:**

1. **Missing schema patch for the two new Deal columns (audit's #1, P0).**
   `leak_flag`/`leak_detected_at` were added to the Deal model in Round
   15-16 but never added to `init_db()`'s existing ad-hoc ALTER-TABLE
   list - the same list that already has a comment documenting this exact
   failure mode from an earlier round ("buy_agent_requests ADD COLUMN...
   this closes that gap"). `Base.metadata.create_all()` only creates
   tables that don't exist yet; it never alters an existing table to add
   a missing column. Any query touching either column against a deals
   table that already existed before this round would have failed
   outright. Fixed by adding both columns to that same list, the
   established pattern for exactly this - not an Alembic migration, which
   Xavier explicitly asked to skip since there's no data to migrate from,
   but the lightweight patch mechanism this codebase already uses for
   every other post-launch column addition. (SellerMetrics itself needed
   no entry - it's a genuinely new table, which create_all() does handle.)

2. **Leak-detection timing wasn't sequential (audit's #2, P0).** §3.2
   specifies 7 days with no payment, THEN a further 5 days of silence -
   12 days total, with the back half of it silent. The code checked "is
   the deal >7 days old" and "was the last message >5 days before now" as
   two independent conditions against `now`, not chained - so a deal
   agreed on day 0 with its last message on day 1 would incorrectly
   qualify as a leak on day 7, five days earlier than the design
   intends. Traced through the audit's own worked example by hand against
   the actual code before fixing it (confirmed the bug), then again
   against the fix (confirmed August 13, not August 8, is now the
   earliest a matching deal flags). Fixed in
   `domains/trust/completion_rate.flag_leaked_deals()`: candidates now
   require the full 12 days elapsed, and the silence check compares the
   last message against when the 7-day window closed, not against `now`.

3. **Leak evidence could bleed across deals (audit's #3, P0).**
   `NegotiationMessage` has no `deal_id` foreign key, only
   `(listing_id, buyer_id)`, and nothing in the schema stops the same
   buyer+listing pair from producing a second Deal row later (no
   UniqueConstraint enforces one deal per pair). The evidence queries
   (both the solicitation-flag join and the last-message check) matched
   only on listing_id+buyer_id, with no time bound - so an solicitation
   flag or silence from an EARLIER, already-resolved deal between the
   same two parties could count as evidence against a newer, unrelated
   one. Fixed by scoping both queries to
   `NegotiationMessage.created_at >= deal.created_at` - the closest proxy
   available to "belongs to this deal's thread" without a schema change.

**One P1 finding fixed properly rather than left as a documented
trade-off:** the ranking formula (audit's #5/#6). Round 16 stored
rank_score as trust+DCR+response renormalised to 0-1, with freshness
applied as an ORDER BY tiebreaker afterward - reasoned at the time as a
portability trade-off (the doc's literal blended formula needs
Postgres-only EXTRACT/GREATEST, which would break on this app's SQLite
dev default). Reconsidering under audit scrutiny, that trade-off was worse
than documented: rank_score is a float, exact ties are rare, so a
tiebreaker-only approach meant freshness had almost no practical effect on
ordering at all, not just a mathematically-inexact one. Fixed by storing
the RAW weighted sum (not renormalised) in
`completion_rate.recompute_all_dcr()`, and adding freshness as a genuine
weighted term in `listings/service.py` via `case()`-bucketed date
comparisons (`Listing.created_at >= <python-computed datetime constant>`)
rather than a date-diff SQL function - portable across both dialects
(plain `>=` on a datetime works identically on SQLite and Postgres) while
actually implementing the real 0.35/0.30/0.15/0.20 formula instead of
approximating it. Added `DEFAULT_RANK_SCORE_FOR_NEW_SELLER`, computed from
the same neutral assumptions used everywhere else in this chapter, rather
than a second hardcoded cold-start number.

**One P1 finding fixed after confirming the audit's read of the actual
flow:** the M-Pesa protection badge (audit's #7). `mpesa_confirmation_screen.
dart` had `const ProtectionBadge(status: 'agreed')` - a deliberate choice
at the time (the screen is only ever reached right after an STK push, for
a deal still genuinely at `agreed`), but the audit is right that hardcoding
is fragile regardless of how correct the common case is - a live status is
cheap to fetch here and was already available via the existing
`getEscrowState(dealId)` endpoint, unused by this screen until now. Fixed:
fetched once via a new `_loadLiveDealStatus()`, same error-swallowing
pattern as the existing `_loadDisputeSummary()` (a failed fetch must never
block or error the actual payment flow), falling back to the same
'agreed' default that was already correct for the normal case.

**Tests added for the two most safety-critical fixes.**
`backend/tests/test_completion_rate.py` - the audit's #4/P0 finding
("no Volume 2 tests... especially dangerous because DCR is now
influencing seller visibility") was correct, and this round fixed exactly
the kind of subtle timing/scoping logic most likely to regress silently.
Covers: DCR cold-start (empty history -> exactly the 80% prior), the
leak-timing fix directly (a deal at 8 days + 5-day-old message must NOT
flag; the same shape at the full 12 days must), and the cross-deal
scoping fix directly (an earlier deal's solicitation flag must not
contaminate a later deal's evaluation). Followed the existing
`test_escrow.py` fixture pattern (temp-file SQLite + `reset_engine()` +
real `init_db()`) rather than inventing a different one.

**Caught in my own test before it shipped:** the third test's own fixture
data was wrong on first draft - I placed Deal B's "proof of continued
activity" message shortly after deal creation instead of after its leak
window closed, which (traced by hand, since nothing here can be executed)
would have made the test's own data register as silence and fail against
correct code, not pass against broken code. Caught by manually tracing
every test's timestamps against the fixed logic before considering any of
this done, the same discipline applied to the implementation itself -
not by running pytest, which isn't possible in this sandbox.

**Not done, deliberately, matching the audit's own P2/P3 framing:** the
external listing-sold-outside-BROKA leak signal (still no data source -
audit agrees this is an acceptable phased gap), real response-time
tracking (still a neutral placeholder - audit agrees ML/analytics
maturity is appropriately deferred at current data volume), position-
aware seller coaching, and distributed locking for the nightly workers
under multi-instance deployment (audit itself frames this as "fix before
horizontal scaling," not before this pilot - Xavier is running a single
Render instance today, so speculative distributed-lock infrastructure
for a scaling scenario that doesn't yet exist was left out rather than
built preemptively).

**Verification:** every backend file touched this round re-compiled clean
with `py_compile`, plus a full session-wide re-check of every file touched
since Round 15. The new test file can't actually be executed in this
sandbox (no pytest installed, no network to install it) - every one of
its three DCR/leak-detection assertions was instead traced by hand against
both the buggy and fixed code, the same way the fixes themselves were
verified, and Postgres-vs-SQLite portability of the new ranking SQL was
reasoned through rather than tested against a real Postgres instance
(none available here either).

---

# BROKA — Round 17: Volume 2 Chapters 4-5 — ML layer (heuristic-first) and Zeno's seller-coaching persona

Implemented §4.1-4.5 (ML layer) and §5.1-5.4 (persona) - the last two
chapters of the Volume 2 design journal. Rounds 15-16 covered §2-3.

**Chapter 4 shipped exactly as §4.4 sequences it: heuristic-only, nothing
trained.** BROKA has zero completed deals in any category (empty database,
per Round 15's constraint), nowhere near the doc's own 300-deals-per-
category threshold for trusting a learned model over a heuristic. Built
the full core/ml/ package - feature_extraction.py, predict.py, train.py -
all real and runnable, but predict.py's predict_price()/predict_leak_risk()
check for a trained artifact first and fall through to a heuristic every
single time today, and train.py's train_all() checks the same 300-deal
threshold per category and skips (logging why) anything below it. Nothing
here is stubbed-but-pretends-to-work; it's genuinely heuristic-only,
matching current data reality, with the model path already wired for the
day a category actually crosses the threshold.

**lightgbm/joblib are not installed.** train.py imports both lazily,
inside the one function that needs them, specifically so nothing else in
this package (predict.py's heuristic path, which is what's live) breaks
if they're absent. Added both to requirements.txt as commented-out lines
with a note on when to uncomment them, rather than as live dependencies
for a training path that can't run yet anyway.

**§4.3 calls for a synchronous MLPredictionService.** That's the right
shape once a category has a loaded model - pure in-memory inference, no
DB call. It isn't achievable for the heuristic fallback today: the
heuristic needs a live category-average query, and this codebase is async
SQLAlchemy throughout with no synchronous DB path anywhere to reuse.
predict_price()/predict_leak_risk() are async for now; the day a category
first gets a trained artifact, that category's predictions stop touching
the DB at request time at all, which is what actually converges toward
§4.3's intent rather than a permanent workaround.

**Caught my own design mistake before it shipped:** first draft put
MLPredictionService as an AIBrokerService instance attribute. AIBrokerService
is constructed fresh on every request (`svc = AIBrokerService()` in the
router, per call) - the whole point of caching a loaded artifact in memory
would have been lost, silently, the first time a model actually existed.
Moved it to a module-level singleton (`ml_prediction_service` in
core/ml/predict.py) instead.

**Chapter 5's coaching persona is its own constant, not merged into
ZENO_PROMPT, and only applies behind a new `zeno_seller_coach` system_override**
- never the plain `zeno` override `zeno_screen.dart` and `product_screen.dart`
also send through the same `/negotiate/chat` endpoint. §5.4 is explicit that
the encouraging/coaching tone "applies to dashboards, pricing help, and
general check-ins, never to an active dispute conversation" - scoping this
to its own override value is what actually enforces that, rather than just
documenting it and hoping every future caller remembers.

`seller_dashboard_screen.dart`'s tips prompt only asked for pricing tips
before this round - nothing in it touched completion rate or ranking at
all, so the new coaching persona would have had nothing relevant to apply
to. Broadened the prompt to include the seller's real DCR (now available
per Round 16) and explicitly invite a visibility-framed tip when there's
room to improve, so §5.3's "always cite a specific, real number" and
"frame every suggestion in terms of what the seller gains" bullets have
actual seller data to work with instead of sitting unused.

**Real bug caught mid-edit, not left in:** my Dart change called
`ApiService.zenoChat(..., systemOverride: 'zeno_seller_coach')` before
`zenoChat()` had any such parameter - it hardcoded `system_override: 'zeno'`
in its request body with nothing to override it. Would not have compiled.
Added `systemOverride` as an optional named parameter (default `'zeno'`,
so the other two existing callers are unaffected) before this went further.

**Where it's wired:**
- `core/ml/feature_extraction.py` (new) - `count_completed_deals_by_category()`
  (the §4.4 gate everything else checks), `extract_pricing_examples()`,
  `extract_leak_risk_examples()` (reuses §2.2's off-platform-solicitation
  audit trail and §3's leak_flag as labels - a classifier needs both
  classes, and both already exist from Rounds 15-16)
- `core/ml/predict.py` (new) - `MLPredictionService`, heuristic price
  estimate (category-median-of-comparable-deals, wide confidence band,
  falls back to the seller's own asking price when a category has zero
  comparable deals yet) and heuristic leak-risk score (hand-weighted, not
  learned - §4.2's classifier replaces this body once labelled examples
  exist)
- `core/ml/train.py` (new) - real LightGBM training code, gated by the
  300-deal threshold per category
- `core/workers.py` - `task_retrain_ml_models()`, wired into the same
  sweep loop as Rounds 15-16, gated via the Redis stats-cache helper
  (lower stakes than DCR's DB-based gate - this runs train_all(), which
  for the foreseeable future just finds every category under threshold
  and logs that, so an occasional redundant run costs almost nothing)
- `domains/ai_broker/service.py` - `price_recommend()` now grounds its
  prompt in a real heuristic number instead of letting the LLM invent
  one; needed a `db` parameter it didn't have before, threaded through
  `domains/ai_broker/router.py`'s endpoint too
- `routers/negotiate.py` - `SELLER_COACHING_PROMPT_ADDITION` constant
  (§5.3's block plus §5.4's guardrail against revealing exact thresholds/
  weights/window durations, even if asked directly); new `zeno_seller_coach`
  branch in the `/chat` handler
- `services/api_service.dart` - `zenoChat()` gained the `systemOverride`
  parameter described above
- `seller_dashboard_screen.dart` - tips prompt broadened to include DCR
  and switched to the new scoped override

**Verification:** every backend file re-compiled clean with `py_compile`,
same as Rounds 15-16, including a full session-wide re-check across every
file touched since Round 15. Both touched Dart files passed a brace/paren
balance check - `seller_dashboard_screen.dart` shows the same pre-existing
1-paren "mismatch" Round 16 already traced to a regex character class in
an untouched line, confirmed again this round by checking that this
round's edit added exactly one open and one close paren (perfectly
balanced on its own). Two real bugs were caught before shipping this
round, both described above - neither would have been caught by
`py_compile` alone, which is why every new function got a manual re-scan
of its local names against its imports on top of the compile check.

**Not done, on purpose:** the dedicated backend test files §6.2's task
table lists (test_completion_rate.py, test_leak_detection.py,
test_off_platform_signal.py, test_ranking.py, and whatever Chapter 4/5
would need) were not added, for Chapters 2-3 or this round. Verification
throughout has been py_compile plus careful manual review, not an actual
pytest run - no dependencies are installed and no network access exists
in this sandbox to install them. That's a real gap between this delivery
and an actually-tested one; worth closing before this reaches production,
not just noted here.

This closes out Volume 2 end to end (§2 through §6, per the doc's own
build order in §6.3) across Rounds 15-17.

---

# BROKA — Round 16: Volume 2 Chapter 3 — Deal Completion Rate, leak detection, ranking integration, seller dashboard

Implemented §3.1-3.7 of the Volume 2 design journal (Deal Completion Rate).
Same no-migrations constraint as Round 15 - the new SellerMetrics table
and Deal.leak_flag/leak_detected_at columns are added straight to the
models, nothing to migrate from with an empty database.

**No agreed_at column.** §3.7 asks for one "if not already derivable from
an audit log entry." It's not just derivable but exactly equal: every Deal
row is created already at DealStatus.agreed (confirmed against every
creation call site back in Round 15's investigation), so Deal.created_at
already IS the agreement timestamp. Added nothing rather than a column
that would always duplicate an existing one.

**dcr_score/rank_score went on a new SellerMetrics table**, per the doc's
own "cleaner if these fields are expected to grow" - Chapter 4 already
earmarks more seller-level ML outputs that would otherwise mean repeatedly
widening User.

**Two more places Volume 2 assumed something that isn't actually there:**
- §3.4's "average response time (existing metric)" - it isn't. Grepped the
  repo the same way Round 15 checked for escrow success rate; no response-
  time tracking exists anywhere. response_time_score is a neutral 0.7
  placeholder for every seller so the ranking formula's shape is complete
  (all 4 weighted terms present, correctly normalised) without silently
  inventing a whole response-time-tracking subsystem that wasn't the ask.
- §3.4's ranking formula blends freshness in as a weighted numeric term
  (rank_score + 0.20*freshness_score). Doing that literally in SQL needs
  EXTRACT(EPOCH FROM ...) and GREATEST(), both Postgres-only - this app's
  dev default is SQLite (.env.example: sqlite+aiosqlite), so that query
  would work in production and break locally. Used Listing.created_at as
  a plain ORDER BY tiebreaker instead - same practical effect (newer
  listings still rank above otherwise-equal ones), fully portable.

**§3.2's leak detection ships with two of three corroborating signals.**
The third - "the related listing was marked sold/unavailable outside of a
BROKA-mediated deal" - has no data source. There is no listing-delisting
or deactivation endpoint anywhere in this codebase, seller-facing or
otherwise, so there's nothing for that signal to read. Implemented:
(a) §2.2's off-platform-solicitation flag firing earlier in the same
thread, audit_logs joined back through negotiation_messages rather than
parsed out of the free-text detail string; (b) extended silence - both
parties quiet for a further 5 days after the 7-day leak window closes. A
deal that's just stale, with neither signal present, is left alone
entirely - not flagged, not penalised - matching §3.2's explicit intent
not to punish ordinary buyer indecision.

**Where it's wired:**
- `database.py` - `Deal.leak_flag`/`leak_detected_at`; new `SellerMetrics`
  table (user_id PK, dcr_score, rank_score, updated_at)
- `domains/trust/completion_rate.py` (new) - `deal_weight()` (§3.3's
  45-day-half-life recency curve), `compute_dcr()` (Bayesian-smoothed
  against an 80% prior, so a brand-new seller starts neutral rather than
  at 0%), `flag_leaked_deals()`, `recompute_all_dcr()` (scores every
  seller with >=1 listing, not just ones with deal history - needed for
  §3.5's cold-start fairness)
- `core/workers.py` - `task_recompute_dcr_and_leaks()`, wired into the
  same sweep loop Round 15 used for the dispute-summary cache, but gated
  via the database (max(SellerMetrics.updated_at)) rather than Redis -
  this result affects real search ranking, so the "have I run in the last
  24h" check needs to survive a Redis restart/flush without silently
  skipping a night or re-running every 5 minutes
- `domains/listings/service.py` - default search sort now joins
  SellerMetrics and orders by rank_score (coalesced to the same 0.80
  neutral prior for sellers with no row yet - cold-start fairness again)
  behind is_featured, ahead of the existing created_at tiebreaker
- `domains/auth/service.py` - profile endpoint includes dcr_score/
  rank_score for any seller with >=1 listing (not gated to completed_deals
  like Round 15's escrow-stats block - a seller with zero deals but a
  listing should still see their neutral starting DCR, not have it hidden)
- `seller_dashboard_screen.dart` - DCR shown with self-explanatory
  high/low framing. Not the fully Zeno-narrated, position-aware version
  the doc's own example shows ("move you from position #14 to the top
  5") - that needs a live per-category rank position this pass doesn't
  compute, and the doc explicitly defers exact tone/language to Chapter 5

**Caught mid-implementation, not left in:** the first draft of
`task_recompute_dcr_and_leaks` called `datetime.utcnow()` without
importing `datetime` in that function's scope - this file imports
`datetime` locally per-function rather than once at module level, and the
new function missed it. A NameError at runtime, invisible to
`py_compile`. Found it by re-scanning every new function's local name
usage against its imports, not by running the code - no way to execute
this backend in this sandbox. Fixed before this file was touched again.

**Verification:** every backend file re-compiled clean with `py_compile`
after each edit, same as Round 15. The one Dart file touched
(seller_dashboard_screen.dart) was checked by hand; a brace/paren balance
pass flagged an apparent 1-paren mismatch that turned out to be a false
positive from a regex character class (`[.)]`) inside a string literal at
an untouched line - confirmed by diffing against the pre-edit file, where
the same mismatch already existed. Still not a substitute for actually
running `flutter analyze`.

**Not done, on purpose:** Chapter 4 (ML feature extraction, heuristic-only
predict functions) and Chapter 5 (Zeno persona/prompt updates, including
the fully narrated version of the DCR copy above) are unbuilt. The doc's
own build order (§6.3) sequences these after Chapter 3.

---

# BROKA — Round 15: Volume 2 Chapter 2 — protection badge, off-platform detection, dispute-summary proof, seller social proof


Implemented §2.1-2.4 of the "Volume 2" design journal (escrow trust/social-proof
chapter). Skipped the Alembic migration Volume 2's Chapter 3 would have needed -
no DB data exists yet, so schema changes (not shipped in this round - see below)
will just be created fresh rather than migrated.

Volume 2 was written against an earlier snapshot of this repo and got several
concrete things wrong about the current code. Corrected each rather than
building on the wrong assumption - flagging clearly here rather than letting a
changelog reader assume the doc was followed verbatim:
- §2.3 named `backend/api/models/dispute.py` as holding "the Dispute model."
  That file is real, but what's in it is `DisputeCase` (the v5 state-machine
  system) - the older, simpler `Dispute` class lives in `database.py` and its
  own router (`routers/disputes.py`) isn't even mounted in `main.py`. Built
  the stats endpoint against `DisputeCase`, which is what's actually live.
- §2.2 said to wire off-platform detection into `domains/ai_broker/service.py`.
  Per Round 14's investigation, that's not the live chat path - `negotiate.py`
  is (registered first in `main.py`, wins the `/negotiate/chat` route
  collision). Detection lives in the `/message` handler in negotiate.py.
- §2.3's suggested path `/api/v1/stats/dispute-summary` doesn't match any
  existing convention - no `/api/v1` prefix exists anywhere in this codebase.
  Used `/disputes/v2/stats/summary`, consistent with how the rest of the v5
  dispute router is laid out.
- §2.3 assumed "a periodic ARQ background job." This codebase doesn't
  actually have ARQ cron scheduling wired up anywhere - periodic work runs
  through one shared `asyncio` sweep loop in `core/workers.py`
  (`_periodic_sweep_loop`, ticks every 5 min). Added the refresh there
  instead, self-gated to recompute only every ~4h.
- §2.4 assumed "Escrow Success Rate" and "Dispute Rate" per seller already
  exist from an earlier "Volume 1" chapter ("placement, not new data").
  Grepped the whole repo - neither exists anywhere, as a column or a
  computed value. Only `completed_deals` is real. Built the other two as a
  new, minimal `seller_deal_stats()` helper in `core/fraud.py`.

**Where it's wired:**
- `core/fraud.py` - `detect_off_platform_solicitation()` (regex/keyword,
  analytics-only, deliberately NOT touching trust_score - a single trigger
  is weak signal on its own) and `seller_deal_stats()` (escrow success rate
  + dispute rate per seller, live-computed, cheap enough not to need caching)
- `core/stats_cache.py` (new) - small generic Redis get/set-JSON helpers,
  its own module so `core/workers.py` and `domains/disputes/router.py` can
  share a cache key without importing each other
- `core/workers.py` - `task_refresh_dispute_summary_cache()`, wired into
  the existing sweep loop; also registered in `WorkerSettings.functions`
  for forward-compat if this ever moves to a real ARQ worker process
- `domains/disputes/router.py` - `GET /disputes/v2/stats/summary`, public
  (no auth - it's aggregate and anonymised), lazily populates the cache on
  a cold miss rather than ever hardcoding a fallback number
- `routers/negotiate.py` - detection + audit log (`record_audit`, action
  `off_platform_solicitation_detected`) right after a message is persisted;
  Zeno's reply prompt gets a conditional instruction block that pulls the
  live `resolved_within_24h_pct` from the same Redis cache the stats
  endpoint reads, so the number Zeno cites is never hardcoded
- `domains/auth/service.py` - `get_user_profile` now includes
  `escrow_success_rate_pct`/`dispute_rate_pct` for accounts with
  `completed_deals > 0`; left `_user_dict` (the bulk/search-result path)
  untouched so list endpoints don't pay a new per-user query
- `widgets/protection_badge.dart` (new) - takes the raw backend status
  string rather than the existing Dart `DealStatus` enum in
  `deal_ws_client.dart`, which doesn't model every state this needs
  (`awaiting_condition_check` etc. currently come back as `unknown`) and
  is pattern-matched exhaustively in two other files
  (`deal_status_widget.dart`, `deal_status_screen.dart`) that couldn't be
  verified without a Dart compiler in this environment
- `services/api_service.dart` - `getDisputeSummaryStats()`
- Wired into `deal_status_widget.dart`, `negotiate_screen.dart` (badge +
  escrow-success-rate next to the existing rating/deals line +
  dispute-summary reassurance), `mpesa_confirmation_screen.dart` (badge +
  live 24h-resolution stat shown specifically during the pending-STK-push
  wait, fetched once, all failures swallowed so a stats-fetch hiccup can
  never disrupt the actual payment flow)

**Not wired: `negotiation_screen.dart`.** Volume 2 listed this as a fourth
surface for the badge. It's real and live (`/direct-chat` route in
`main.dart`), but it's a general direct-messaging screen with no deal/escrow
concept at all - no `DealStatus`, no `dealId` even in its constructor
(`NegotiationScreen({super.key})`). Wiring a protection badge in would mean
inventing status plumbing this screen doesn't have, which is a materially
bigger change than "add an existing widget" - left it out rather than
forcing something in that doesn't fit, or silently dropping it without a note.

**Verification:** every backend file re-compiled clean with `py_compile`
after each edit. No Flutter/Dart SDK is available in this sandbox, so the
five touched `.dart` files were checked by hand - matched existing patterns
closely, verified the Dart `DealStatus` enum's exact member names against
source before referencing them, and did a final brace/paren balance pass
across all five files (all matched). None of that substitutes for actually
running `flutter analyze` - do that before merging.

**Not done, on purpose:** Volume 2's Chapter 3 (Deal Completion Rate scoring
+ leak detection + ranking integration), Chapter 4 (ML feature extraction +
heuristic-only predict functions), and Chapter 5 (Zeno persona/prompt
updates) are unbuilt. Chapter 2 alone was a full round; the doc's own
build order (§6.3) sequences these as later, separate steps.

---

# BROKA — Round 14: Groq decommissioned llama-3.3-70b-versatile → OpenRouter (Nemotron 3 Ultra) wired in as testing fallback

Groq emailed on Aug 14, 2026 that `llama-3.3-70b-versatile` — the model
hardcoded as the fallback AI provider everywhere it's called
(`ai_broker/service.py`, `negotiate.py`, `disputes.py`, and
`domains/disputes/service.py`) — would be decommissioned on 2026-08-16.
A separate pasted analysis (apparently from ChatGPT, reviewing OpenRouter's
current free-model lineup) picked NVIDIA Nemotron 3 Ultra as the top
candidate to test as the replacement, ahead of GPT-OSS-20B and Gemma 4 26B
A4B, which are still queued up for the same evaluation later. Verified the
model ID against OpenRouter's own model page before wiring anything in
rather than trusting the pasted summary: the real current ID is
`nvidia/nemotron-3-ultra-550b-a55b:free`, not the shorthand
`nvidia/nemotron-3-ultra:free` the summary used — the wrong slug would
have made every OpenRouter request 404 silently.

**New middle tier, not a replacement.** All four fallback chains now go
Gemini → OpenRouter (Nemotron 3 Ultra, free tier, TESTING) → Groq →
[cache → 503, wherever that tier already existed]. Nothing about Groq
was touched or removed: `GROQ_API_KEY`, the hardcoded `GROQ_MODEL`
constant, `GROQ_ENDPOINT`, `_call_groq`, `groq_breaker`, and the Render
env var are all exactly as they were — they just now sit one tier
further back, behind the new OpenRouter call, so this tier is currently
a no-op (the model it's pinned to is the one that just got retired) but
it will start working again the moment `GROQ_MODEL` is pointed at a Groq
model still being served. Groq's own suggested replacements (GPT-OSS-120B
/ Qwen3.6 27B) were deliberately left as a note rather than auto-applied
— swapping Groq's model wasn't part of "switch to Nemotron for testing,"
so that's flagged as a follow-up decision, not made silently.

**Where it's wired:**
- `core/config.py` — added `openrouter_api_key` / `openrouter_model`
  (the latter env-overridable via `OPENROUTER_MODEL`, defaulting to the
  verified Nemotron free-tier ID)
- `core/circuit_breaker.py` — added `openrouter_breaker`, same 5-failure
  / 30s-recovery shape as `gemini_breaker` / `groq_breaker`
- `domains/ai_broker/service.py` — new `_call_openrouter` method,
  inserted into `_call_ai` behind the circuit breaker; `circuit_stats()`
  now reports an `"openrouter"` key alongside `"gemini"` / `"groq"`
- `routers/negotiate.py` — this is the live path (registered before
  `ai_broker_router` in `main.py`, so it's what `zeno_screen.dart` /
  `product_screen.dart` / `seller_dashboard_screen.dart` actually hit);
  added `_call_openrouter` and the same fallback-order change
- `routers/disputes.py`, `domains/disputes/service.py` — same shape
  added by hand to each. These two plus `negotiate.py` already
  duplicate Gemini/Groq logic locally instead of importing
  `ai_broker/service.py` (existing comments cite avoiding circular
  imports) — kept that pattern rather than refactoring it into a shared
  module, since consolidating four call sites wasn't asked for and
  touches more than this change needs to
- `.env.example` / `render.yaml` — `OPENROUTER_API_KEY` +
  `OPENROUTER_MODEL` added; `OPENROUTER_MODEL` is a plain Render
  `value`, not a secret, so the model can be swapped from the Render
  dashboard with no redeploy, matching the eval workflow the pasted
  analysis described (swap one line, compare results)
- `ARCHITECTURE.md` — overview line, circuit-breaker section, and
  deployment checklist updated to mention OpenRouter and flag Groq's
  current no-op state

**Not done, on purpose:** no 50-scenario benchmark harness, no
per-provider scoring rubric, no synthetic-data test fixtures, no
Zero-Data-Retention routing config for OpenRouter. The analysis that
prompted this explicitly frames Nemotron as the first of three
candidates to test, not a final pick, and separately flags that real
buyer/seller data (names, phone numbers, prices, DCR) shouldn't go to a
free endpoint yet — both are evaluation/rollout work still ahead, not
implied by "switch to Nemotron for testing."

---

# BROKA — Round 13: ChatGPT HomeScreen review — targeted polish pass

User shared a ChatGPT product/engineering review written against the
actual uploaded `broka-latest-release.zip` source (explicitly reviewing
the real HomeScreen/ProductCard/ProductGridView, not proposing from
scratch), rating the current architecture 8.2/10 and recommending small
targeted corrections rather than another redesign. Verified every
concrete claim against the real code before acting, same as every prior
round - all of them checked out.

**Location detection no longer auto-triggers on Home open.** The round-2
comment defending `_detectLocation()` in `initState()` claimed it "feeds
the main feed's per-listing distance_km annotation" - re-checked both
halves of that and neither holds up: `_fetchListingsPage` sends lat/lng
but never `max_km` (so `listings/service.py` only annotates distance, it
never filters by it), and `ProductCard` has no `distanceKm` display
anywhere to show that annotation even if it existed. So Home was
requesting GPS permission and running reverse-geocoding on every open for
zero visible benefit. Removed the `_detectLocation()` call from
`initState()` only - the method itself,
`_gpsGeolocation()`/`_tryGps()`/`_reverseGeocode()`/`_ipGeolocation()`,
and `ApiService.currentUserLat/Lng` are all untouched, since trader
list/profile, the Buy Agent hub, negotiation, Sell, and the listing map
all still read those fields directly. One honest gap worth recording:
grepped the whole Flutter app and `home_screen.dart` was the *only* GPS
call site in it - so until some other screen explicitly triggers its own
detection (or Home grows an opt-in "near me" filter), `currentUserLat/Lng`
will now simply stay null for most sessions. Several existing call sites
already tolerate that fine (`sell_review_screen.dart` falls back to a
Nairobi coordinate; the repository's `lat`/`lng` params are nullable
throughout), so nothing breaks - it's a real behavior change worth being
aware of, not a regression.

**Discovery rail: one thin divider, nothing else.** The rail deliberately
gave categories and Trending/Auctions/Traders identical pill treatment
(home-redesign brief §5) so nothing read as more "special." The review's
ask here was narrower than it might sound at first - not "split them into
rows," explicitly the opposite ("I wouldn't separate them into different
rows... keep one horizontal rail but subtly differentiate"). Added an
`isDestination` flag to `_RailItem` and one 1px hairline (`_railDivider()`,
reusing the existing `BrokaColors.textLow` token, no new color introduced)
exactly at the boundary between the last category and Trending - still
one rail, still one pill shape, no card-size or label-style difference.

**Removed the auto-scroll nudge.** `_nudgeDiscoveryRail()` (the round-3
0→56px→0 animation) is gone entirely, along with its `postFrameCallback`
trigger in `initState()`. Replaced with a static right-edge fade - a
`ShaderMask`/`BlendMode.dstIn` over the rail's own `ListView` viewport
(fades the rendered pills' alpha near the right edge) rather than a
painted overlay in a guessed background color, so it stays correct
against the header's actual gradient (`BrokaColors.headerGradColors`)
instead of hardcoding a fade-to color that could drift from it. The rail
no longer moves unless the user moves it.

**"Discover on Broka" → "Fresh on Broka."** Same underlying fact as the
round-2 label fix (default order is newest-first, not a popularity or
proximity ranking) - the old label made no false claim but didn't say
anything either. The comment at the call site now says explicitly not to
rename this again to "Recommended for you" / "Popular near you" / "Trending
near you" until the backend genuinely computes that signal.

**Confirmed already correct, no action taken** (the review's own "keep"
list, checked against the real code rather than taken on faith):
`ProductCard` has no fabricated trust/deal/market scores anywhere; the
trader avatar is already 24px (`radius: 12`, bumped in an earlier round);
"View Deal" is already the only primary CTA; the wishlist heart only
renders when a real `onWishlistTap` callback is passed, and none of the
three current `ProductCard` callers pass one, so it correctly stays
hidden rather than faking an interaction; `_buildZenoCompactCta()` is
already the small ~50-70px row the review asked to keep, not the old
large promotional card; and Home's `initState()` already only fetches
categories, the marketplace feed, and the active Buy Agent request -
`_loadTrending()`/`_loadLiveAuctions()` were removed from Home two rounds
ago and were not reintroduced.

**Verification, honestly**: this sandbox has no Flutter/Dart toolchain and
no network access, so `flutter analyze`, the Flutter test suite, and a
release APK build could not actually be run here, unlike what the
review's own pasted instructions ask for. Checked by hand instead: every
edited region was re-read in full after editing, grep confirmed no
leftover references to the removed `_nudgeDiscoveryRail()`, the old
`_detectLocation()` call site, or the old "Discover on Broka" string; no
duplicate method signatures were introduced; and brace/paren/bracket
counts balance across the whole file. Run `flutter analyze` and the
existing suite yourself (Codemagic CI will also do this on push) before
merging - careful manual review is not a substitute for the real
toolchain actually running.

**Files changed this round**: `flutter_app/lib/screens/home_screen.dart`
only. No backend files, no migrations, no other Flutter files touched.

---

# BROKA — Round 12: Meta AI review + timezone bug + visual polish pass

User shared a Meta AI critique of a Home screenshot, with an important
caveat: the screenshot was from the build *before* Round 11 (their words:
"not from the last source code but from the second last"), so several of
its points were already fixed and just needed confirming, not redoing.
Also reported directly: seller ratings look fake, and a listing posted
under 15 minutes ago showed "3h ago." Verified every claim against the
current code before acting, same as every prior round.

**Confirmed already fixed by Round 11, no action needed**: the duplicate
"Trending Near You" / "Popular near you" content (Round 11 removed the
Trending grid from Home entirely).

**Real bug, found the exact mechanism: "3h ago" for a listing posted
minutes ago.** The backend stores every timestamp as naive UTC
(`datetime.utcnow()`, no timezone marker) and serializes it with none
either. `DateTime.tryParse()` on a string with no offset marker is
interpreted by Dart as *local* time, not UTC - so a later `.toUtc()` call
shifts it a second time, subtracting the device's own UTC offset from a
value that was already UTC. In Kenya (UTC+3) that turns "posted 5 minutes
ago" into "posted 3h 5m ago" - which is exactly what was reported, and
the UTC+3 match isn't a coincidence. Added `utils/backend_time.dart`
(`parseBackendUtc`) and applied it at the two call sites feeding the
reported symptom (`BrokaListing`'s createdAt as parsed by
`product_card.dart`, and the older `Listing` model's own createdAt/
featuredUntil parsing in `models/listing.dart`, plus the copy of that
same parse in home_screen.dart's featured-pinning sort). **Grepped the
whole app and found the same `DateTime.tryParse` pattern in 11 more
files** (`api_service.dart`, `auction.dart`, `buy_agent_request.dart`,
`models.dart`, `deal_ws_client.dart`, `review_screen.dart`,
`boost_screen.dart`, `user_profile_screen.dart`, `product_screen.dart`,
`negotiation_screen.dart`, `deal_receipt_history_screen.dart`) - not
fixed this round, flagged in `backend_time.dart`'s own header comment
rather than silently left implied-fixed. Any of those showing a
relative/absolute time to a user likely has the same bug.

**Real bug: seller ratings looked fake.** `User.rating` defaults to `5.0`
at account creation (`database.py`) and is only ever nudged upward from
there on a completed deal - so a brand new seller with zero completed
deals showed a perfect, untouched 5.0, indistinguishable from a seller
with a real track record. `product_card.dart` now only renders a star
rating when `sellerCompletedDeals > 0` too (not just `rating > 0`, which
was true for literally every seller including brand new ones) - shows
"New seller" instead when there's no deal history yet. On the "out of 10"
point: checked directly - `Review.rating` is `1-5 stars` by column
comment and `User.rating` is capped at `min(5.0, ...)` everywhere it's
adjusted. The system is built and stored as a 0-5 scale throughout, not
0-10 - didn't rescale the display since that would misrepresent what the
stored data actually means.

**Visual redesign of the product card** ("not that attractive... make it
super attractive and futuristic"): thin gradient edge (purple-to-blue)
replacing the flat single-color border; price bumped to 16sp with a soft
gold glow; "View Deal" changed from an outlined button in the same gold
tone as the price (competing visually - a real point from the Meta AI
review) to a solid gradient-filled pill, borrowing `GoldButton`'s visual
language rather than inventing a third button style; a faint bottom
scrim on the product image for depth. Trader avatar bumped 18px -> 24px
(continuing round 11's fix in the same direction).

**Discovery rail**: category labels now wrap to 2 lines instead of
truncating at 1 ("Beauty & P...", "Books & Ed..." was unreadable) - real
category names from `categories/seed.py` mostly fit now. Added the
scroll-affordance animation requested: one brief nudge-and-settle on
first load (peek ~56px right, ease back to 0) rather than a continuous
wiggle, which would read as distracting/broken over a full session.

**Also fixed while in the area**: location text now gets a space
inserted after a comma when the seller's own free-text location was
missing one ("Bondo,Siaya" -> "Bondo, Siaya") - cosmetic only, doesn't
touch the stored value. Empty state (already had an icon + message, not
literally blank) gained an actual "+ Sell something" CTA.

**Deliberately not touched**: bottom nav icon style mix (outlined vs.
filled/rounded, flagged as a fair point) - fixing it means picking exact
Material icon constant names I can't verify compile in this sandbox
(no Flutter toolchain here), and a wrong guess is a build break for a
minor polish item. Left as a known, flagged gap rather than risk it.



User shared a follow-up review (also developed with ChatGPT, this one
explicitly reviewing Round 9's actual source rather than proposing from
scratch) of the Round 9 Home redesign. Verified every concrete claim
against the real code before acting, same as every prior round - all of
them checked out, including two I'm glad were caught: a heart icon that
animated convincingly and did nothing, and a "near you" label the backend
can't actually back up.

**Trending grid and Live Auctions carousel removed from Home entirely.**
Round 9 had converted Trending into a 2-column grid sitting above the
main feed - a real improvement over the old horizontal reel, but still a
second, fixed listing block competing with the actual paginated feed for
space, which is exactly what the whole redesign was supposed to
eliminate. Both are now pure `_buildDiscoveryRail()` destinations only -
tapping them opens `TrendingScreen`/`AuctionHouseScreen` unchanged, which
fetch their own data. Home no longer calls either API at all
(`_loadTrending()`/`_loadLiveAuctions()` removed from `initState()`,
along with the now-fully-unused `_trendingItems`/`_liveAuctions` state
and their now-unused repository imports) - one less pair of network
calls on every Home open that Home was never using for anything but a
section it no longer shows.

**Two labels were making claims the backend can't back up:**
- Trending's grid used to say "Popular near [location]" - moot now that
  the section is gone, but worth recording why it was wrong:
  `trending/service.py`'s `list_trending` has zero lat/lng/max_km
  handling (grepped directly) - ranking is pure view/interest-count with
  time decay, no geography involved at all.
- The main feed said "Popular near you." Also not true:
  `_fetchListingsPage` sends `lat`/`lng` but never `max_km`, and
  `listings/service.py`'s `list_listings` only *filters* by distance when
  `max_km` is provided alongside coordinates (grepped and confirmed) -
  without it, lat/lng only annotates each result with a `distance_km`
  value, it doesn't restrict the result set to nearby listings at all.
  "Popular" wasn't accurate either - with no sort selected this is just
  the backend's default order (newest first), not a popularity ranking.
  Changed to "Discover on Broka," which claims nothing the feed can't
  support and doesn't need to change again once a real recommendation
  engine exists.

**Fixed a real fake-interaction bug**: `product_card.dart`'s favorite
heart (added Round 9, with a real scale-bounce animation) was rendered on
every card regardless of whether a working callback existed behind it.
Grepped this entire codebase, backend and Flutter both - there is no
wishlist/favorites system anywhere (no model, no endpoint, no
repository), and none of the three places that construct a `ProductCard`
(Home's feed, Home's search results, `ProductGridView`) ever passed
`onWishlistTap`. So the heart bounced convincingly and updated nothing,
every time, everywhere it appeared. Now only renders when a real
`onWishlistTap` callback is actually provided - today that's never, so
the heart doesn't show at all, which is more honest than a
disabled-looking icon that still invites a tap. The animation/state code
is untouched - a future wishlist feature just needs to pass
`onWishlistTap`/`isWishlisted` and it reappears working, nothing to
rebuild.

**Trader avatar increased from 18px to 24px diameter** (`radius: 9` ->
`radius: 12`) - trust identity, not decoration, and 18px read as nearly
invisible next to the name/rating beside it.

**Confirmed already correct, not touched**: discovery rail composition,
compact Zeno CTA, single View Deal action, condition badges, real
seller_verified/seller_rating (no fabricated trust score), backend
filtering (condition/price/location/sort), pagination. All per the
review's own assessment of Round 9, and consistent with what Round 9's
CHANGES.md entry claims - nothing here contradicted it.



Home's header showed the "BROKA" wordmark but never the icon mark next to
it - the login screen (`auth_screen.dart`'s `_buildLogo()`) has always
shown both together. Replicated that exact treatment in
`home_screen.dart`'s header: same asset (`assets/images/broka_icon.png`,
already declared in pubspec.yaml, no new asset needed), same 44x44 size,
same 13px corner radius, same gold glow. Sits to the left of the existing
greeting/wordmark column; the two icon buttons on the right (filter,
search) are untouched.



User shared a full UI redesign brief (developed with ChatGPT) plus a
current-state screenshot and a target mockup: the core complaint was that
Home spent most of its vertical space on navigation chrome (a Goods/
Traders toggle, a permanent location row, category circles, a giant Zeno
promo card) before showing a single product. Implemented the structural
core of the brief - not every one of its ~40 sections (several are
animation-timing detail or repeated emphasis rather than new asks) - and
substituted real data everywhere the brief's own mockup showed numbers
this codebase has never computed.

**Two things in the brief's mockup were NOT reproduced, on purpose**: a
"🛡 99%" trust percentage (no Deal Completion Rate has ever existed
anywhere in this codebase - see traders/service.py's own note) and
"+67% vs avg" price comparisons (no market-average computation exists
anywhere either). Built the equivalent *intent* - a trust signal next to
the trader's name, a price the buyer can act on - from data that's
actually real: a verified checkmark (`seller_verified`) and a star rating
(`seller_rating`), shown only when there's an actual rating to show. No
fabricated numbers shipped.

**Structural changes** (`home_screen.dart`):
- Goods/Traders toggle removed entirely. Traders is now one destination
  inside a single unified discovery rail, alongside the real categories
  and Trending/Auctions - navigates to its own `TraderListScreen` (no
  longer `embedded`) instead of swapping Home's whole body via
  `MarketplaceState`. `MarketplaceState` itself is untouched (still
  registered in main.dart) in case anything else needs it later - just no
  longer read from this screen.
- Permanent location row removed. Location detection
  (`_detectLocation`/`_locationLabel`) is unchanged - it now surfaces
  contextually as the Trending section's subtitle ("Popular near
  Ugunja") instead of a dedicated always-visible row, and is still
  tappable there to manually re-detect.
- Categories + Trending + Auctions + Traders unified into one horizontally
  scrolling rail (previously three separate rows: a category-circle
  strip, a "Quick Access" chip row, and the mode toggle) - same visual
  treatment for every item so nothing reads as more "special" than a
  category circle, ~80px tall.
- Zeno's card shrunk from a ~180px promotional block to a ~60px compact
  row. Reused `_pulseCtrl` - an `AnimationController` that existed since
  an earlier round but was never actually attached to anything - for a
  slow breathing glow.
- Trending converted from a 200px horizontal reel of narrow cards to a
  2-column grid (capped at 4 items - "See all" reaches the rest via
  `TrendingScreen`), same aspect ratio as the main feed grid below it for
  visual consistency. Live Auctions kept as a horizontal carousel - the
  brief itself allows this for time-sensitive content, and it lowers the
  change surface.
- "Zeno is watching for you" now shows the real match count
  (`req.matchCount`, added Round 4) instead of a binary
  searching/matched state.
- Light entrance animation: header renders instantly, the rail/Zeno-CTA/
  active-request/Trending/Auctions sections fade+slide in with a short
  stagger (`_Entrance`, a small reusable one-shot widget - not a full
  driven `AnimationController` per section).

**Listing card rebuilt** (`product_card.dart`):
- Trader identity row (avatar + name + verified check + real star rating)
  added below the image - not overlaid on it, so it never covers product
  photography, which the brief itself calls out as a priority ("do not
  allow trader information to cover too much of the product").
- Trader photo required a small backend addition:
  `seller_profile_photo` never existed on any listing response (only on
  trader-list responses, added Round 4) - added to `_listing_dict` via
  the same optional-seller/batched-fetch pattern as the four seller
  fields already there. Falls back to an initial-letter avatar when
  absent, same pattern trader cards already use elsewhere - never a
  generated face.
- Condition badge (top-left, real data, blank when the listing has none -
  not "Unknown") and relative freshness text ("2h ago", computed from
  `createdAt`) added.
- Single "View Deal →" button added to every card. There was no "Offer"
  button to remove (the card was previously whole-card-tap-only, no
  buttons at all) - the new button fires the same `onTap` the rest of the
  card already used, not a second navigation target.
- Favorite heart now has a real tap animation (scale 1→1.25→1, ~260ms) -
  extracted into its own small `_FavoriteButton` StatefulWidget so the
  rest of the card can stay a plain `StatelessWidget`.
- `ProductCardSkeleton` gained an actual shimmer sweep (was a static flat
  gradient box before this round, despite the class name).

**Deliberately not done this round, flagged rather than silently
skipped**: a custom Broka-logo pull-to-refresh indicator (brief §29) -
`ProductGridView` already has a functional `RefreshIndicator`, just the
default Material one, not a branded animation. A friendly inline error
state for a failed page fetch (brief §32) - not present before this round
either, and out of scope for a hierarchy/layout redesign. Precise
millisecond-level animation choreography across every section (brief
§21-§30's full timing tables) - implemented the real intent (fade+slide
entrance, favorite bounce, gentle Zeno glow, shimmer) with sensible,
tasteful timings rather than chasing every specified number, since this
environment has no way to visually verify exact motion timing anyway.



User shared a review (from ChatGPT) of the Buy Agent work. Verified every
concrete, checkable claim against the actual code before acting on any of
it — a review like this can be right, wrong, or partially right, and
several of its numeric scores were opinion rather than something to "fix."
Two claims were real, confirmed bugs; a third (matching completeness) was
something I'd already flagged as a known limitation in my own Round 4
comments, so this was the pass to actually close it.

**1. `optimization_configuration` was accepted by the service and stored
on the model, but `_create_buying_request` never actually built or passed
it** — confirmed by grep, zero references. A secondary optimization
preference picked when creating a standing request was silently dropped,
even though the exact same preference is correctly carried through for
one-off `SEARCH_PRODUCTS`/`REFINE_SEARCH`/`SORT_RESULTS` calls. Fixed:
`_create_buying_request` now takes `optimization_secondary` and builds
`{"secondary": ...}` the same way.

**2. `negotiation_authorized` was never actually enforced, and - separately
- was never even settable.** The column existed (correctly defaulting to
`False`), Design v2 §24 explicitly requires genuine pre-authorization
before Zeno negotiates autonomously, and my own Round 4 comment on
`_start_negotiation` referenced this exact field - but nothing anywhere
(no param on either params model, no router field, no Flutter UI) could
ever set it to `True`, and `buy_agent_subscribers.py`'s auto-opener never
checked it at all. So every match auto-messaged the seller regardless,
with the authorization boundary existing in name only. Fixed end to end:
- `CreateBuyingRequestParams`/`UpdateBuyingRequestParams`/the plain
  `BuyAgentRequestIn` (all three creation/update paths) now accept it,
  default `False`.
- `buy_agent_subscribers.py` now checks `req.negotiation_authorized`
  before sending the auto-opener - an unauthorized match still flips
  status to "matched" and increments `match_count` (the buyer still sees
  it), it just doesn't message the seller without having said yes to that.
- Buying Agent Hub gained a checkbox ("Let Zeno message the seller for me
  automatically...") on the "Keep Zeno watching" step, off by default -
  otherwise the backend fix alone would leave this permanently
  unreachable from the app, which is correct-but-inert, not actually done.

**3. The autonomous subscriber only ever checked category + max_price**,
silently ignoring condition, subcategory, distance, and
`must_have_features` even when a standing request specified them - a
"Samsung Galaxy, 8GB RAM, under 10km" request behaved identically to
"anything electronics under budget." This was already flagged as a known
limitation in my own Round 4 comment on this file ("Feature-matching
against must_have_features... is not implemented") - this round actually
closes it. Added `_listing_satisfies_request()`: checks subcategory,
condition, and distance as real hard constraints (opt-in - a constraint
the buyer never specified never excludes a listing), and
`must_have_features` as a best-effort case-insensitive substring check
against the listing's name+description. That last one is a real,
documented limitation, not equivalent to structured attribute matching -
a listing that satisfies a requirement without literally saying so in its
text still won't match. A deeper fix needs the attribute-value validation
this codebase doesn't have at listing-write-time either (see
`filter_bottom_sheet.dart`'s own note on this from Round 4). Updated
`test_matching_listing_opens_disclosed_negotiation_thread` accordingly -
its listing now actually contains the feature its matching request
requires, rather than the match happening despite the listing never
mentioning it (which is what "not implemented" had been letting slide).

**Deliberately not changed, and said so rather than silently declining**:
the review's suggestion to compare multiple candidate listings and hold
out for the best-scored one instead of committing to the first one that
satisfies every constraint. `CREATE_BUYING_REQUEST` already runs an
immediate search against existing inventory before a standing request is
even created (the Hub's confirm-and-search step) - the standing watch's
job is specifically to catch *future* listings, and "first future listing
that genuinely qualifies" is a defensible design for that, not obviously
wrong. Doing real multi-candidate scoring would mean deciding how long to
wait and trading responsiveness for a maybe-better match that may never
come - a real product decision, not something to bundle into a
matching-completeness fix. Also not changed: the review's critique of the
`primary*0.85 + secondary*0.15` ranking blend (a fair point - it doesn't
literally "break ties," it always has some influence) - a tuning
refinement, not a gap, and lower-confidence to get right unilaterally
than the three fixes above.



GitHub Actions' next run (after Round 6) flagged a different test:
`tests/test_traders.py::TestTraders::test_specialization_derived_from_listings_not_self_declared`,
failing on `assert "cat-electronics-2" in spec_ids` with the actual value
being the real seeded Electronics category's UUID instead.

Not a specialization-derivation bug - the subscriber found the right kind
of category, just the wrong *row*. The test creates its own
`Category(id="cat-electronics-2", name="Electronics", parent_id=None)` to
control the scenario precisely, but `setup_db`'s `init_db()` call already
seeds the real canonical "Electronics" top-level category before any test
runs (`seed_categories()`, dedup-checked, runs on every startup - this
predates this round, not something introduced here). So the test
unintentionally created two legitimate top-level rows both named
"Electronics". `trader_specialization_subscribers.py`'s Round 4 fix
(`ORDER BY parent_id IS NULL DESC, id` instead of `scalar_one_or_none()`,
specifically so a genuine name collision logs and picks *a* row instead of
crashing with `MultipleResultsFound`) picked deterministically - by id -
between the two, and the seeded UUID happened to sort first. In real
usage this can't happen at all: `seed_categories()`'s own dedup check
means two top-level categories can never legitimately share a name
outside a test going out of its way to create that. Fixed by renaming the
test's category to something outside the canonical 16 top-level names
("Test Electronics") so there's no collision to tie-break in the first
place, rather than changing the subscriber's (correct, needed-for-the-
real-non-test-case) tie-break logic. Grepped every other test file for
the same `Category(id=...)` pattern — this was the only one.

**Also fixed, unprompted by either CI failure**: while in `database.py`
for the above, noticed `init_db()` already has exactly the mechanism
Round 4's `match_count` column should have used - a hand-maintained,
try/except-wrapped list of forward-compat `ALTER TABLE ... ADD COLUMN`
statements that run safely on every startup against an existing DB, which
I'd missed and instead told you to reset your dev database for. Added
`match_count` to that list. **You no longer need to reset anything** -
correcting what Round 4's CHANGES.md entry told you.



GitHub Actions flagged one failing test after the Round 4 zip:
`tests/test_buy_agent.py::TestBuyAgent::test_matching_listing_opens_disclosed_negotiation_thread`,
`assert me.json() is None` on the last line. Worth being precise about
what this failure actually shows, since it's good news, not a new bug:
everything *before* that line (the listing being created, the in-process
subscriber matching it, the broker-role negotiation message with the
right `is_agent_initiated`/content) passed — meaning `buy_agent_subscribers.py`'s
Round 4 migration to the live event system is confirmed working
end-to-end by a real test run, not just by static review.

The one failing line was asserting the *old* bug: `GET
/buy-agent-requests/me` used to return `None` the instant a request
matched (`get_active_for_buyer` only ever queried `status=="active"`) -
which is exactly what Round 4 fixed, on purpose, because it meant
home_screen.dart's "Match found!" state could never actually be reached.
The test was written against the pre-fix behavior and never got updated
alongside it. Updated the assertion to expect the matched request (and
its `match_count`) instead of `None` - not a behavior change, just the
test catching up to the intentional Round 4 fix.



Reported symptom: audio/video calls worked before, then stopped — the
callee saw no incoming-call screen, no notification, no ringtone at all.
Traced end to end rather than guessing at the calling UI first, since a
symptom this total (zero signal, not degraded quality) usually means
something upstream of the feature itself.

**Root cause: access tokens expire in 15 minutes
(`ACCESS_TOKEN_EXPIRE_MINUTES`) and nothing ever refreshed them.**
`POST /auth/token/refresh` (`refresh_router.py`) has existed and worked
correctly the whole time — but `register()`/`login()`
(`AuthService`) never actually called `create_refresh_token()` or
returned one, so no client could ever obtain a refresh token to exchange.
Compounding it: `ApiService.checkIncomingCall` (what
`GlobalPollerService`'s ~7s background poll uses to detect an incoming
call) and `ApiService.initiateCall` (what the caller uses to register the
call at all) had **zero handling for a 401** — a expired-token response
just silently became "no call" / "call not sent," forever, with no error
anywhere. Net effect: call detection (and initiation) worked perfectly
for the first 15 minutes after login, then went completely and silently
dark for the rest of the session — matching "worked before, tested again
after a while, nothing." The one existing recovery attempt in the app
(`ApiService._tryRefreshOrRelogin`, previously only used by
`createListing`) was *also* broken independently: `Uri.parse('\$baseUrl/...')`
had an escaped dollar sign, so even that one call site's refresh attempt
was hitting a garbage URL, not the real one, this whole time.

Fixed all four pieces:
- `AuthService.register`/`login` now issue a real refresh token
  (`_issue_refresh_token`, DB-backed via `RefreshToken`, matching what
  `refresh_router.py` already expected) and return it as `refresh_token`
  — the Flutter side (`login()`) was already reading and storing that
  field, just never receiving it.
- Fixed the `\$baseUrl` typo.
- `checkIncomingCall`/`getInbox`/`initiateCall` now retry once via
  `_tryRelogin()` on a 401 before giving up.

**Not done, flagged rather than silently left implied-fixed**: the
401-retry pattern above was only added to the 3 call-critical methods.
Grepped the rest of `api_service.dart` (~50 methods) — only
`createListing` had any 401 recovery before this round, and still only 4
of ~50 do now. Anything else that polls or runs in the background will
have the same silent-death-after-15-minutes behavior until this is
broadened file-wide. Didn't do that sweep here: touching a large fraction
of a 1300-line file with no way to compile or run the result in this
environment is a worse risk than leaving it flagged for a dedicated pass.

Also found in the same area, not investigated further (out of scope for
this specific bug): `api/routers/auth.py` is a second, unmounted, fully
dead implementation of the auth endpoints — confirmed dead the same way
`api/routers/listings.py` was in Round 4 (checked `main.py`, only
`api/domains/auth/router.py` is `include_router`'d). One live caller
elsewhere in the backend (`negotiate.py`) imports a helper
(`_approx_location`) from the dead file rather than the live one — works
today (dead code can still be imported from, it's just never *routed to*
as an HTTP endpoint), but is a landmine for a future edit made to the
wrong copy.



Deep audit of the actual source against both docs, section by section,
verified by reading the real code rather than trusting prior notes about
it — several things believed fixed in earlier sessions turned out to be
either genuinely regressed or never actually wired into the code path
that's live in production. Implemented the highest-value gaps found.
Nothing existing was removed; every file in the previous zip is still
here, touched or not.

**Cannot be verified by actually running the app from this environment**
— no Flutter SDK, emulator, or live Postgres/Redis here. Every backend
`.py` file compiles cleanly (`python3 -m py_compile` across the whole
`backend/` tree, not just touched files) and every Dart file was
brace/paren-balance checked across the whole `flutter_app/lib/` tree, but
neither is a substitute for actually building and running both sides
before shipping. Build and click through this before deploying.

## Critical fix: five event subscribers were dead under Redis

The single highest-severity thing found this round. `api/core/events.py`'s
legacy `@subscribe` bus only invokes in-process handlers when
`REDIS_URL` is unset (`_publish_inprocess`) — the moment Redis is
configured, `publish()` writes to a Redis Stream instead
(`_publish_redis`), and nothing anywhere in the codebase ever reads that
stream back out (`consume_redis_stream` exists, is fully correct, and is
never called). `config.py`'s own startup log calls Redis
"production-grade operation", i.e. the recommended deploy config — so
this wasn't a dev-only edge case, it was the *documented* config quietly
breaking everything routed through the old bus.

Confirmed still affected: `buy_agent_subscribers.py` (Zeno's core "watching
for a match" mechanic), `trader_specialization_subscribers.py` (specialty
badges), `auction_hub_subscribers.py` (live bid WebSocket broadcast),
`deal_hub_subscribers.py` (all deal-status WebSocket updates), and
`push_subscribers.py` (every FCM push notification). `zeno_subscribers.py`
was already correctly on the newer system and untouched.

Fix: migrated all five from `@subscribe`/`api.core.events` to
`@subscribe_to`/`api.core.event_catalog`, whose handlers fire
unconditionally inside `emit()` regardless of Redis. Verified this needed
**zero call-site changes anywhere else**: `publish()` already
unconditionally bridges every call to the catalog
(`events.py`'s `_bridge_to_catalog`, called after the Redis/in-process
branch either way), and every event type these five files depend on
(`ListingCreated`, `BidPlaced`, `DealFinalized`, `EscrowFunded`,
`EscrowReleased`, `EscrowRefunded`, `DisputeOpened`, `DisputeResolved`,
`ReviewSubmitted`, `UserVerified`, `FraudFlagged`, `MpesaCallbackReceived`)
was already present in `LEGACY_EVENT_MAP` — checked every one against the
map and against each dataclass's real field names before writing the new
payload access, not assumed. `main.py`'s import block reordered/relabelled
to match (still six plain side-effect imports, same as before).

**Also found, not fixed (pre-existing, separate from this bug, out of
scope for a redesign-guide pass — touches core dispute/verification
business logic, not Home/Zeno)**: grepped every call site and confirmed
nothing in the codebase ever calls `publish(EscrowRefunded(...))`,
`publish(DisputeOpened(...))`, `publish(DisputeResolved(...))`, or
`publish(UserVerified(...))` at all. Those four handlers are now wired
correctly and will fire the instant something publishes them, but nothing
does yet — flagging honestly rather than leaving the impression dispute/
verification notifications fully work end-to-end.

## Zeno Action Engine — closed real gaps in `buy_agent/actions.py`

`REFINE_SEARCH`, `SORT_RESULTS`, `UPDATE_BUYING_REQUEST`, `CHANGE_BUDGET`,
`CANCEL_REQUEST`, `START_NEGOTIATION` were all present in the action
vocabulary but returned `NOT_IMPLEMENTED`. Implemented all six:

- `REFINE_SEARCH`/`SORT_RESULTS` execute identically to `SEARCH_PRODUCTS`
  (a refine *is* a new search with merged-in parameters; a sort *is* a
  re-search with a different `optimization_code`, already a top-level
  field) — no new execution logic needed, just real action names Zeno can
  emit honestly.
- `AIBrokerService.parse_search_intent` gained an `existing_filters` arg:
  when the Hub sends the prior search's parameters alongside a follow-up
  like "only 2018 or newer", the model returns the complete merged filter
  set instead of just the new fragment — this is what makes "Zeno must
  understand that 'it' refers to the active request" (design doc §21)
  actually true rather than aspirational.
- `UPDATE_BUYING_REQUEST`/`CANCEL_REQUEST` close a real usability bug:
  with `BUY_AGENT_MAX_ACTIVE` defaulting to 1 and no prior way to ever
  change status away from "active"/"matched", a buyer who created one
  standing request had **no way to ever create a different one**. Also
  fixed `BuyAgentService.get_active_for_buyer` only ever querying
  `status == "active"` — the instant a request matched (status flips to
  "matched"), it became invisible to `GET /buy-agent-requests/me`, so
  `home_screen.dart`'s "Match found!" display branch had real code that
  could never actually be reached.
- `START_NEGOTIATION` opens a real `NegotiationMessage` thread for a
  specific listing, gated on the Hub already having shown a "shall I
  start the negotiation?" confirmation (design doc §24) before ever
  calling it. Deliberately does **not** reach into
  `routers/negotiate.py`'s `send_message` (~2700 lines, built for a live
  HTTP request's own context) — reuses the same safe, plain-message
  pattern `buy_agent_subscribers.py`'s auto-match opener already
  established, rather than duplicating or destabilizing that file.
- Added `BuyAgentRequest.match_count` (real column, incremented by
  `buy_agent_subscribers.py` on each match) so Home/Hub can show a real
  number instead of the previous binary searching/matched state.

**No new Alembic migration was written for `match_count`** — see the
"About migrations" note near the end of this entry.

## Seller trust info now actually reaches product cards

Confirmed by reading `product_card.dart`'s own code (not assumed): the
verified-badge logic was a proxy (`sellerName != null`) because **no
listings endpoint anywhere returned real seller data** —
`ListingService._listing_dict` never took a seller argument at all, under
any caller, despite `BrokaListing`/`product_card.dart` already being
built to show `seller_verified`/`seller_name`/`seller_rating`/
`seller_completed_deals`. Fixed: `_listing_dict` now optionally takes a
`seller: User`; `create_listing`/`get_listing`/`list_listings` (batched,
one `IN (...)` query for a whole page, not N+1)/`trending.list_trending`
(same batching) all pass one through. `BrokaListing` and the older
`Listing` Flutter model both gained the four fields; `product_card.dart`
now shows a real verified badge plus a compact seller-name line instead
of the old proxy, and no longer needs a type-branch to read them since
both models use the same field names.

Also found and left alone, documented rather than silently ignored:
`api/routers/listings.py` is a second, older listings implementation with
its own (different, `seller_verified`-less) version of this same join —
confirmed via `main.py` that it is **never mounted/imported anywhere**,
i.e. fully dead code, not the one actually serving `/listings` traffic
(that's `api/domains/listings/router.py`, the one fixed above). Left as-is
per "don't eliminate any file."

## Home screen search — was not searching listings at all

Confirmed by reading the code: `_ListingSearchDelegate` is named and
labelled as listing search but its `buildSuggestions`/`buildResults` only
ever called `ApiService.searchUsers` — Home's primary search entry point
could not find a single product, despite both docs explicitly listing
product search as one of Home's most important elements. Rewritten to
search listings by default via `ListingsRepository` (added a `location`
passthrough to it too — the backend's `list_listings` already had a
`location` ILIKE param that this repository simply never exposed), with
trader search kept one tap away via a mode toggle rather than removed.
Added a conservative heuristic (5+ words, plus a budget/intent signal
word or a 4+ digit number) that surfaces an "Ask Zeno" banner for
sentences that read like a buying request rather than a product name —
never blocks or replaces plain search, per design doc §4's explicit
"do not remove normal search in favor of AI." `BuyAgentHubScreen` gained
an optional `initialQuery` constructor param so this hand-off actually
pre-fills and auto-submits instead of dropping the buyer's typed text.

## Home screen structure

- Section order was Quick Access → Top Categories; guide §1's explicit
  target order is the reverse. Swapped.
- Migrated the main feed off the older `ApiService.getListings()`/
  `Listing` stack onto `ListingsRepository`/`BrokaListing` (the stack
  every other screen already uses) — this is what makes Condition/Sort
  filterable from Home at all, and is also what makes the seller-trust
  fix above actually show up on Home's own grid, not just Category
  Zone/Trending/the Buying Agent Hub.
- Filter panel gained Condition chips and a Sort dropdown alongside the
  existing Price/Location — guide §5/§20 list Location, Price, Condition,
  Sort as Home's Global filters; only the first two existed.
- Added a "Popular near you" label above the main grid (target structure
  item #10). Not "Recommended for you" — this app has no
  browsing-history-based personalization signal to back that claim yet,
  and the guide is explicit: never fabricate personalization.

## Traders — N+1 query, and three missing card elements

`TradersService.list_traders` ran one `COUNT(*)` query *per trader in the
list*; batched into one grouped query. Design doc §30 lists
business/profile image, location, and distance as trader-card elements;
none were ever returned by the service despite the underlying data
(`User.profile_photo`/`business_location`/`lat`/`lng`) already existing —
added all three, gated behind the same `User.location_visible` privacy
switch `search_screen.dart`'s existing user search already respects (not
exposed unconditionally just because the doc lists them). Deliberately
did **not** add a Deal Completion Rate field: the doc points at "an
existing per-seller DCR function," but no such function exists anywhere
in this codebase under any name — fabricating one wasn't the ask.

## Filter number-range bounds

`filter_bottom_sheet.dart`'s number-range fields (Year, Mileage, Bedrooms,
Acreage, Screen Size, Seating Capacity, Square Footage, Battery Health,
Power Rating, Shoe Size, Hours Used, Size (ml), Experience Years) all
rendered against a flat, shared 0–100 scale regardless of what the field
actually was — a car's Year squeezed into 0–100 has no usable resolution,
and Mileage needs to reach ~500,000 km. `category_filters` still has no
per-field min/max of its own, so added a small hand-picked bounds lookup
covering every `number_range` field name that actually appears in
`categories/seed.py` today, with a safe 0–100 fallback for any future
field name not yet in the map.

## About migrations

No new Alembic migration files were written this round, per direct
request — `match_count` (`BuyAgentRequest`) is the only new column, added
straight to the SQLAlchemy model in `database.py`. `init_db()` already
calls `Base.metadata.create_all()` on startup, which creates missing
*tables* but — standard SQLAlchemy behaviour, not specific to this
codebase — does **not** add a missing *column* to a table that already
exists. Since there's nothing in the database to preserve right now, the
simplest path is letting the next startup's `create_all()` build the
schema fresh (drop the `buy_agent_requests` table, or the whole dev DB,
once) rather than hand-writing a migration for a single nullable-default
integer column. Happy to generate the real Alembic revision once you're
ready to start preserving data across deploys.


Founder chose "go big" on the aesthetic gap over incremental polish. Scope:
the highest-leverage surfaces (seen on nearly every screen, or the specific
"Zone" moment the original spec called the signature feature) rather than
a mechanical pass over every widget in the app. Built entirely from the
design tokens `BrokaColors` already defined (brand gradient, neon accents,
card gradient) — no new colour system, so nothing here fights with what
was already consistent.

**Cannot be verified visually from this environment** — no Flutter SDK or
emulator available here, only static analysis (brace/paren balance, import
resolution by inspection). Build and eyeball this before shipping.

## New shared tokens (`main.dart`)

`BrokaColors.zoneGradients` — a 2-colour gradient per top-level category,
built mostly from the neon tokens that already existed (Electronics/Phones/
Computers → cyan-blue, Gaming → purple-pink, etc.), plus two new ambers/
oranges for categories with no obvious existing match. `zoneGradientFor()`
does a case-insensitive lookup with a fallback to `brandGradient`, so an
unmapped category never renders with no gradient at all.

`ZoneGlowText` — gradient-filled, glowing header text (`ShaderMask` +
`BlendMode.srcIn` + stacked `Shadow`s). This is the "ELECTRONICS ZONE" /
"GAMING ZONE" treatment from the original spec's mockup — built as a
reusable widget, not copy-pasted per screen, since the Zone concept was
explicitly called out as BROKA's one signature visual idea.

## CategoryZoneScreen — the signature moment

- Plain white category name → `ZoneGlowText`, glowing in that category's
  own gradient.
- Added a radial background wash tinted with the zone's colour, fading
  fast into the standard dark background — deliberately subtle rather
  than a full palette swap, per the founder's own earlier note on Gemini's
  proposal ("BROKA identity stays consistent, while each Zone gets its
  own personality").
- Subcategory chips: selected state now fills with the zone gradient and
  a matching glow instead of the generic purple used everywhere else.

## ProductCard

Swapped local one-off hex values for the shared `BrokaColors` gradient/
border tokens. Price now uses the actual brand violet token. The bare
verified checkmark is now a small "✓ Verified" pill, matching how the
mockup actually labels it, instead of an unlabeled icon.

Deliberately did NOT add a Deal-Completion-Rate badge here even though the
mockup shows one — neither listing model returns that field from the API
today (confirmed against `_listing_dict` in `listings/service.py`), and the
founder's own Document 2 says to hold off on it until there's enough
transaction data anyway. Faking a number would be worse than not showing
one.

Also deliberately did NOT add per-card blur/glassmorphism or drop shadows
— many cards render at once in a 2-column grid, and `BackdropFilter` in
particular is expensive per-instance in Flutter. Kept cards visually clean
and spent the glow budget on the Zone header and buttons instead, where
there's only ever one on screen at a time.

## Home screen category carousel

Each category icon's ring is now that category's own zone gradient
(subtle glow, not solid fill), so browsing the home screen previews which
Zone you're about to enter before you tap in.

## Buy-Agent sheet + Filter sheet buttons

Both "Start Buy Request" and "Apply Filters" were flat `ElevatedButton`s
with a solid violet fill — swapped for the app's own `GoldButton` (already
existed, already used elsewhere: gradient fill + glow), which these two
sheets just weren't using yet. No new component, just consistency.

## Not touched this round

Trader cards/list, Buy-Agent's own layout beyond the button, bottom nav,
and auction cards keep their current look — none were part of the
founder's original complaint, and every screen touched here was chosen
because it's either high-frequency (ProductCard, home screen) or the one
screen the original spec called out by name (the Zone). Worth a follow-up
pass once this round's been seen running on a real device.

---

# BROKA — Round 2 fixes off the Volume 6 build (Buy-Agent free text + empty-category visibility)

## 4. Buy-Agent sheet had no free-text entry point

Volume 6 Ch.8/Ch.11/Ch.28 specified BuyAgentSheet as a plain form (category
chips, max-price field, must-have-features chips) — a deliberate
simplification of the founder's original spec, not a rejection of it: the
founder's brief asked for something closer to "type a sentence, AI figures
out the rest" (e.g. "Samsung phone, 12GB RAM, good battery, under 30000").

**The fix:** added a free-text box at the top of the sheet with a "Let Zeno
fill this in" action. It calls a new endpoint that extracts
category/max_price/must_have_features from the sentence and pre-fills the
*same* fields the form already had — nothing about how a request gets
created or matched downstream changes, and the buyer still reviews/edits
before Start Buy Request. A bad or empty parse just leaves the fields for
manual entry, same as before this box existed.

**New backend surface:** `AIBrokerService.parse_buy_request()` (reuses the
existing Gemini/Groq `_call_ai` wiring — no new LLM integration) and
`POST /buy-agent-requests/parse`, constrained to whatever's actually in the
categories table so it can't invent a category that doesn't exist.

**Files touched:** `ai_broker/service.py`, `buy_agent/router.py`,
`services/api_service.dart`, `buy_agent/presentation/buy_agent_sheet.dart`

## 5. Empty categories were indistinguishable from "broken"

Both the home screen's category carousel and the Buy-Agent sheet's category
picker fail silently when the categories table is empty (see
`migrate_categories_from_freetext.py` — a one-off script, never yet run
against a live database, per Ch.19's own flagged risk). A founder or tester
seeing a blank strip has no way to tell "data not seeded" apart from
"this is broken."

**The fix:** both now show a low-key, non-alarming message once loading
finishes with zero rows ("Browse by category — coming soon" / "No
categories available yet"), instead of silently rendering nothing. This
does not seed any data — running the migration script below is still the
actual fix for the missing categories themselves.

**Files touched:** `screens/home_screen.dart`,
`buy_agent/presentation/buy_agent_sheet.dart`

## Flagged, not fixed: same photo-loss pattern in negotiate_screen.dart / negotiation_screen.dart

Both call `ImagePicker().pickImage(source: ImageSource.camera)` with no
`retrieveLostData()`, same as the Sell flow before fix #3 above. Not patched
here: the Sell flow's fix works because `splash_screen.dart` already knows
to resume straight into `SellPhotosScreen` when a draft exists. Neither
negotiation screen has an equivalent "resume into this exact thread" path,
so bolting on `retrieveLostData()` alone wouldn't reconnect it to anything —
it would need that resume path built first. Worth a dedicated pass if
photo-sending inside negotiations is actually dropping photos in practice.

---

# BROKA — Round 1 fixes off the Volume 6 build (Home screen + Sell photo loss)

Founder review of the first Volume-6 build against Design Journal Volume 6
turned up one real regression against that spec, a price-display bug, and a
recurrence of a photo-loss bug that had already been diagnosed and partly
fixed once before (see "Sell flow — photo capture kicking you back to Home"
below). This entry covers all three.

## 1. Goods/Brokers/House Hunting tab bar and the stats ticker were still shipping

Volume 6 Ch.23 (Phase 0) explicitly says to delete both the stats-row widget
and the Goods/Brokers/House Hunting/Traders TabBar as the very first step —
brokers and house hunting are out of scope for this release. Phases 1–5
(categories, trending, auctions, quick access) were all built correctly on
top of the new structure, but Phase 0's own removal never happened, so both
were still rendering above the category carousel.

**The fix:** deleted `_buildTabBar()`, `_buildTickerStrip()`, and every
field/controller that only existed to support them (`_tabCtrl`, `_tabs`,
`_tabCategories`, `_tickerTimer`, `_tickerShift`). `_fetchListingsPage()` and
`_emptyState()` no longer branch on a tab index — Goods is the only mode
this screen ever renders now (Traders is its own screen behind the mode
toggle, untouched).

**Files touched:** `screens/home_screen.dart`

## 2. Listing prices under 10K were rounding to the nearest thousand

`priceFormatted` divided by 1,000 and rounded to zero decimals for any price
≥1,000, so a KES 1,500 listing displayed as "KES 2K" — a third more than the
actual price. Not a hardcoded value; a rounding artifact that only becomes
obvious on small-ticket items.

**The fix:** prices from 1,000–9,999 now keep one decimal (`KES 1.5K`);
10K and above still round to whole thousands, where the lost precision is
proportionally small. Applied to both `BrokaListing.priceFormatted` and
`ProductCard._formatKes` (the two places this logic was duplicated) —
left the price-filter slider's own formatter alone, since a coarse filter
control rounding to the nearest thousand is fine and always was.

**Files touched:** `features/listings/domain/models/listing.dart`,
`widgets/product_card.dart`

## 3. Sell-flow photo loss on camera kill — the "fixed" bug came back because it was only half-fixed

The earlier fix below (`SellDraftStore` + splash-screen resume) protects
every photo that was already added to the draft *before* the next camera
launch. It cannot protect the one photo that's mid-capture at the exact
instant Android kills the process — that shot was never in the draft to
begin with, and its `pickImage()` Future is abandoned for good once the
isolate awaiting it is gone. On the very first photo of a listing (nothing
upstream yet persisted), that failure mode looks identical to "no images
have been uploaded" — which is almost certainly what happened to the
"xpon router" listing showing no photo on Trending: not a display bug, but
this same capture getting lost during creation.

**The fix:** `SellPhotosScreen` now also calls `image_picker`'s
`retrieveLostData()` on init, sequenced *after* draft-restore completes (not
in parallel — running both at once risked the draft-restore's `_data =
restored` silently wiping out a photo the lost-data check had just
recovered). This is `image_picker`'s own Android-specific channel for a
result that arrives after a cold restart, separate from the Future the
original call could no longer resolve. No-ops safely everywhere else.

**Still true after this fix:** the brief splash-screen flash itself can't be
prevented — that's Android reclaiming memory from a backgrounded process,
not something in the app's control (see below). What changes is that the
photo you just took stops disappearing along with it.

**Files touched:** `screens/sell_photos_screen.dart`

---

# BROKA v6.1 — Phone-first onboarding rework

Reworked account creation end-to-end, based on a founder + reviewer design
pass on the original email/username-based signup flow. Three goals drove
this: (1) let people see the app's value before being asked to sign up,
(2) make phone the identifier instead of email, since a meaningful share of
the target user base is unfamiliar or uncomfortable with email-based signup,
and (3) stop forcing the buyer/seller choice at signup.

## 1. Browse-before-signup

Splash now always routes to Home, logged in or not — the previous
`Splash → Auth → Home` gate (auth required before seeing anything) is gone.
Guests can browse freely; only account-gated actions (Sell, talk to Zeno,
Inbox/negotiations, Profile) prompt sign-up, and — importantly — resume
exactly where the user was headed once they finish, rather than dropping
them back at Home. See `lib/utils/auth_gate.dart`.

## 2. Phone replaces email as the identifier

- `users.phone` is now required + unique; `users.email` is now optional
  (kept, not removed — still useful for password recovery, invoicing, and
  cross-border expansion later, per the design discussion).
- Registration is a 3-step server flow: `POST /auth/otp/request` (sends a
  6-digit SMS code via Africa's Talking, wrapped in the same
  circuit-breaker pattern used for the Gemini/Groq AI fallback chain) →
  `POST /auth/otp/verify` (returns a short-lived signed `phone_verify_token`)
  → `POST /auth/register` (requires that token — you cannot register a
  phone number that hasn't actually received and confirmed the code).
- `POST /auth/login` now takes `{phone, password}` instead of
  `{email, password}`. Biometric login is unchanged (still device-local,
  unlocks the stored session).
- OTP entry in the app uses Flutter's built-in `AutofillHints.oneTimeCode`
  (system-level SMS autofill on both Android and iOS) rather than a
  third-party plugin — no new native permissions, no SHA-hash app
  signature registration to maintain.

## 2a. Migration note

Existing rows (there shouldn't be any in production yet) get a placeholder
`unverified-<id>` phone so the new NOT NULL + UNIQUE constraint doesn't fail
the migration; those accounts can't log in by phone until backfilled
manually. See `migrations/versions/0011_phone_first_onboarding.py`.

## 3. Buyer vs. buyer+seller: no longer a forced choice

Every account starts as `buyer`. Becoming a seller is a separate action
(`POST /auth/upgrade-to-seller`, new "Become a Seller" screen reachable from
Profile) — matches the reviewed decision that most people start as buyers
and shouldn't have to decide upfront.

Seller identity is collected as **structured fields**, not one free-typed
name: `business_name` + `business_category` + `business_location` →
server auto-generates `business_display_name` (e.g. `Clanix · Wholesale ·
Sira`). This was a deliberate change from the original "seller types the
whole thing" idea — a free-typed field would fragment the same business
into "Clanix-Ugunja" / "Clanix ugunja" / "CLANIX" variants that break
search and confuse Zeno's business-description matching. `business_description`
is preserved as free text — that one's meant for Zeno to read, not for
generating an identifier.

## 4. Flutter side

- `lib/utils/auth_gate.dart` (new): `requireAuth()` shows a sign-up prompt
  only when a guarded action is tapped, and lets the caller resume that
  exact action afterward (`AuthScreen` now pops `true` back to its caller
  instead of always replacing with Home — see `_returnAuthenticated()` in
  `auth_screen.dart`).
- `splash_screen.dart`: always proceeds to Home (or a saved sell draft)
  regardless of login state.
- `home_screen.dart`: bottom nav (Inbox / Sell / Zeno / Profile) gated
  through `requireAuth`; Home browsing itself is not.
- `product_screen.dart`: "Start Negotiation" gated the same way.
- `auth_screen.dart`: rewritten as a 6-step wizard (Phone → Verify Code →
  Basic Info → Selfie → Biometrics → Confirm). OTP entry uses Flutter's
  built-in `AutofillHints.oneTimeCode` (system-level SMS autofill on both
  Android and iOS) rather than a third-party plugin. Login form now takes
  phone + password.
- `profile_screen.dart`: no more fake `user@broka.ke` placeholder when a
  user has no email (email tile is now conditional; phone is always shown).
  The Seller Dashboard tile now branches — buyers see "Become a Seller"
  (→ new `become_seller_screen.dart`), buyer_sellers see the dashboard as
  before.
- Also fixed in passing: `currentUserPhone` existed as a field in
  `api_service.dart` (read by `boost_screen.dart` and
  `verification_screen.dart`) but was never actually saved/loaded from
  storage — a pre-existing latent bug. It's wired up correctly now, as a
  side effect of adding phone to the session-persistence path.

## 5. Guest browsing already worked server-side — verified, not changed

`GET /listings/`, `GET /listings/{id}`, and `GET /listings/stats` had no
`get_current_user` dependency already — browsing was never actually
gated on the backend. `POST /listings/` (create), the negotiate endpoints,
and the Zeno/ai_broker endpoints all do require it, confirmed by reading
each router directly, which is what actually makes the Flutter-side gate
meaningful rather than a purely cosmetic client-side check. Added
`get_current_user_optional` to `api/security.py` for future guest-facing
personalization, but nothing currently calls it — noting that so it isn't
mistaken for wired-up behavior.

## What you'll need to do

- Run the new migration (`alembic upgrade head`) — includes the phone
  backfill described above.
- Set `AT_USERNAME` / `AT_API_KEY` (and optionally `AT_SENDER_ID`) for real
  SMS delivery. Without them, `/auth/otp/request` logs the code instead of
  sending it (and — non-production environments only — returns it as
  `debug_code` in the response), so registration is fully testable without
  a live SMS account, but **must** be configured before a real deploy.
- `api/routers/auth.py` (email/password, legacy) was already dead code
  before this change — not imported by `main.py`, only `api/domains/auth/router.py`
  is live. Left it in place rather than deleting it since it wasn't part of
  what was asked, but it now describes a signup flow that no longer exists
  anywhere else in the app; worth deleting in a follow-up cleanup pass.
- Tests in `tests/test_auth.py` were rewritten for the new flow but
  **could not be executed in this environment** (no network egress) —
  run `pytest backend/tests/test_auth.py -v` before merging.



## 1. Listing images sometimes rendering blank

Root cause: `Image.memory(base64Decode(photo))` on the home feed card and the
listing detail gallery had no `errorBuilder`. The surrounding `try/catch`
only catches `base64Decode()` throwing synchronously (malformed base64) — it
does **not** catch the image failing to decode as an actual picture, which
Flutter does asynchronously at the paint layer. A listing whose stored photo
bytes are valid base64 but not a decodable image (truncated upload, an
unsupported format, corrupted data, etc.) would pass `base64Decode()` fine
and then silently paint nothing, with no exception for the `catch` block to
catch. Card text/price/CTA would still show — it's only the image itself
that vanished, which matches a card rendering with an empty background.

Fixed in both places by adding `errorBuilder` directly to the `Image.memory`
call, so a bad decode now falls back to the same gradient+emoji placeholder
used when a listing has no photo at all, instead of rendering blank.

Note: several other `Image.memory` calls elsewhere (profile photos, chat/
seller avatars) have this same missing-`errorBuilder` gap and could show the
same symptom under bad data — left alone for now since only listing images
were reported, happy to sweep the rest on request.

## 2. English voice: Kenyan → American accent

`EDGE_VOICES["english"]` (backend `tts.py`) changed from
`en-KE-AsiliaNeural` to `en-US-AriaNeural` — both are Microsoft Edge TTS
neural voices, both **female**, only the accent changes. Updated the
Flutter-side device-TTS fallback locale (`broka_tts.dart`, only used if the
cloud `/tts/speak` call itself fails) from `en-KE` to `en-US` to match, so
the rare fallback case doesn't suddenly sound Kenyan again.

Swahili's voice, and the speech-*recognition* locale used for the mic input
button on the Zeno screen (`zeno_screen.dart`'s `ttsLocale`, actually an STT
setting despite the name), were left untouched — different feature, and
changing what the recognizer expects to hear wasn't asked for.

## What you'll need to do

- Nothing beyond the usual deploy — no new dependency, no migration.
- Worth clearing the TTS in-memory cache expectation: the first time each
  cached English phrase is spoken after this deploy it'll re-fetch (new
  voice = new cache key implicitly, since old audio bytes simply age out of
  the 40-item in-memory cache on restart).

# BROKA — Removed video from listings (mobile data usage)

Product listings are photo-only now. This was a deliberate data-usage fix: the
home feed was autoplaying a promotional "advert video" per card, falling back
to the mandatory verification video when a listing had no advert video — so
almost every card in the feed was silently downloading and decoding video
just to render, which is expensive for the mobile-data-first user base this
app targets, and drives up storage costs as more listings accumulate.

## What changed

- **Sell flow** (`sell_screen.dart`): removed the optional "Advert Video"
  capture entirely — its picker bottom sheet, draft-persistence keys, and the
  `advert_video` payload field. The mandatory **Verification Video** capture
  is untouched — still required at listing creation as possession/fraud
  proof, it's just no longer rendered anywhere for buyers to watch.
- **Home feed** (`home_screen.dart`): cards never play video now.
  `_buildBackground()` always renders the first verified photo (or the emoji
  placeholder on the rare listing with none).
- **Listing detail** (`product_screen.dart`): same change — the photo
  gallery is the only media view; the video player and the secondary
  photo-strip-under-video widget are gone.
- **Models** (`models/listing.dart`,
  `features/listings/domain/models/listing.dart`): dropped the now-unused
  `verifiedVideo`/`advertVideo` fields and the `feedVideo` getter.
- **Buyer tips**: reworded the "request verification photos/video" tip to
  photos only — the app has no way to receive a video from a seller anymore.
- **`pubspec.yaml`**: removed the `video_player` dependency; nothing imports
  it anymore.

## What was deliberately left alone

- **Backend** `advert_video` column/field (`database.py`, `schemas.py`, both
  listings routers, migration `0001`) — left in place rather than migrated
  away. It's already `nullable`/`Optional`, so it's harmless dead weight now
  that Flutter stops sending it, and dropping a column is a riskier change
  than just not using it. Happy to add a proper drop-column migration on
  request.
- **Verification video capture itself** — still required, still uploaded
  once per listing. That's a one-time seller→server cost, not the
  many-buyers × feed-scrolling cost that was actually driving data usage, so
  it wasn't the target of this change.

## What you'll need to do

- `flutter pub get` (dependency removed from `pubspec.yaml`).
- Full rebuild, not a hot reload — removes a native-backed plugin.
- No backend changes, no migration, no manual deploy step.

# BROKA — Video Calls, Ringtone & Screen-Off Call Drop Fix

## 1. Video calls

- New video-call button next to the existing audio-call button in the direct-chat header.
- `WebRtcService` now negotiates a video track when `callType == 'video'` (front camera by default), with front/back camera switching and video on/off toggle mid-call.
- Call screen: full-screen remote video once connected, small local camera preview (tap it to flip camera), extra controls (video toggle, flip camera) alongside the existing mute/end/speaker.
- Call type is threaded end-to-end: initiate → FCM push payload → pending-call poll → incoming-call dialog → call screen → call-history log → call-back (calling back a missed video call opens with video, not just audio).
- New `call_type` column on `negotiation_messages` (migration `0009_call_type.py`). Runs automatically on your next deploy since your Dockerfile already does `alembic upgrade head` before starting uvicorn — no manual step needed.

## 2. Ringtone for incoming calls (audio or video)

- New `RingtoneService` loops a short, original two-tone chime (`assets/audio/ringtone.mp3` — synthesized from scratch, not sampled) for as long as an incoming-call dialog/screen is showing, for both call types.
- Routed through Android's ringtone audio usage so it respects the phone's ringer volume/silent/vibrate state, the way an incoming call should.
- Has a built-in 45-second safety timeout so it can never ring forever (e.g. if the caller cancels before your device's next poll notices).
- Also wired the same sound in as a real Android notification-channel sound (`res/raw/ringtone.mp3`) for the OS-level "Incoming Calls" notification.
  - **Note:** the channel ID changed from `broka_calls` → `broka_calls_v2`. Android locks in a channel's sound once it's been created on a device, so keeping the old ID would have meant nobody who already had the app installed would ever hear the new sound. The new ID guarantees it takes effect for everyone on the next update, no reinstall needed.

## 3. Screen-off call-drop fix

Root cause was two separate things stacking on top of each other:

1. **Android's background mic/camera restriction.** From Android 9+, an app that isn't in the foreground — and isn't running a foreground service — loses microphone/camera access outright. Locking the screen mid-call is exactly this situation.
2. **A `main.dart` side-effect.** The app force-navigates back to `/home` on resume if it had been backgrounded for 5+ minutes — which would have yanked you straight out of any call that had the screen off for that long, whether or not #1 had already killed the audio.

Fixed both:

- **`CallForegroundService.kt`** (new) — a real Android foreground service that runs for the duration of a call. It holds a partial wake lock (CPU keeps running; the screen is still allowed to lock/turn off as normal, exactly like a real phone call) and declares the microphone/camera foreground-service types Android 14+ requires. Started/stopped from `voip_call_screen.dart` over a MethodChannel (`call_foreground_service.dart`) the instant a call begins/ends.
- **`main.dart`** — the resume-triggered redirect-to-home now explicitly excludes the `/voip-call` route.

## What you'll need to do

- `flutter pub get` (new asset entry in `pubspec.yaml`).
- Full rebuild/reinstall on your test device — this includes a new native Kotlin file and new manifest permissions, so a hot reload won't pick it up.
- On the backend, nothing manual — the migration runs automatically on deploy.
- Worth specifically testing: place a call, lock the screen for a couple of minutes, unlock, confirm audio (and for video calls, camera) is still flowing.

## Files touched

**Backend:** `database.py`, `routers/calls.py`, `routers/negotiate.py`, `routers/media.py`, `migrations/versions/0009_call_type.py` (new)

**Flutter:** `pubspec.yaml`, `main.dart`, `models/models.dart`, `services/api_service.dart`, `services/webrtc_service.dart`, `services/notification_service.dart`, `services/global_poller_service.dart`, `services/ringtone_service.dart` (new), `services/call_foreground_service.dart` (new), `screens/voip_call_screen.dart`, `screens/negotiation_screen.dart`, `assets/audio/ringtone.mp3` (new)

**Android:** `AndroidManifest.xml`, `MainActivity.kt`, `CallForegroundService.kt` (new), `res/raw/ringtone.mp3` (new)

Everything else in this archive is untouched, carried over as-is from your upload.

---

# BROKA — Inbox Offline Persistence & Read Receipts

## 1. Inbox wasn't actually using the offline cache

The Inbox *list* screen (`inbox_screen.dart`) was calling the network directly with no fallback at all — on any failure (like the DNS lookup error in your screenshot) it just dumped the raw exception on screen with nothing to look at but a Retry button. `LocalChatStore` (the on-device cache) was already correctly wired into the individual chat *threads* (`negotiation_screen.dart`) — it just was never connected to the inbox list itself, which is what you were actually looking at in the screenshot.

Fixed by giving the inbox the same cache-first pattern the threads already use:
- On open, instantly paints whatever was cached on-device, before the network call even starts.
- On a successful refresh, replaces it with live data and re-caches.
- On a failed refresh: if something's already showing (fresh or cached), it now stays on screen instead of being replaced by an error page — you just get a small "You're offline" banner. The full-screen error only appears if there's truly nothing cached yet (e.g. very first launch with no connection).
- Also replaced the raw `ClientException`/`SocketException` dump with a plain "No internet connection" message for the genuine no-cache case.

## 2. Read receipts ("seen" ticks)

Added real read tracking, backed by a new `thread_read_state` table (migration `0010`) — one row per (listing, buyer, side) holding "read up to this timestamp," the same watermark approach WhatsApp/Telegram use rather than flagging every individual message.

- Two new endpoints: `POST /negotiate/{listing_id}/mark-read` (called whenever you open or actively view a thread) and `GET /negotiate/{listing_id}/read-status` (returns when each side last read it).
- In the chat thread itself: every message you sent now shows a tick — single grey (sent) or double tick, grey (sent, not yet seen) vs blue (seen) — updated live as the other person reads your messages.
- In the inbox list: the same real seen-status now drives the tick next to your last message, and only shows when you actually sent that last message (previously this icon was a bit of a fake — it just meant "I have nothing unread," not "they saw what I sent").
- **Bonus fix:** the inbox `unread` count was hardcoded to `0` server-side the whole time — the UI (badges, bold text) was already built for it, it just never had real data. That's now wired up off the same read-state table.

## You'll need to
- Nothing manual on the backend — migration `0010` runs automatically on deploy, same as `0009`.
- `flutter pub get` isn't needed this time (no new packages), but this does touch several screens, so a full rebuild is still the safer bet over hot-reload.

## Files touched this round
**Backend:** `database.py`, `routers/negotiate.py`, `migrations/versions/0010_thread_read_state.py` (new)
**Flutter:** `services/api_service.dart`, `screens/inbox_screen.dart`, `screens/negotiation_screen.dart`

---

# Build fix — GitHub Actions failure

Your CI run failed at the Flutter compile step:

```
lib/services/ringtone_service.dart:40:14: Error: Cannot invoke a non-'const' constructor where a const expression is expected.
lib/services/ringtone_service.dart:32:43: Error: Cannot invoke a non-'const' constructor where a const expression is expected.
```

`ringtone_service.dart` was marking `AudioContext(...)` (from `audioplayers`) as `const`, but that class isn't actually const-constructible in `audioplayers` 6.4.0 (the version your `^6.1.0` constraint resolved to). Removed the `const` there - functionally identical, just not a compile-time constant.

While I was at it, I found and pre-emptively fixed the same risk in two spots in `notification_service.dart` that hadn't yet failed a build but were relying on the same unverified assumption (`RawResourceAndroidNotificationSound` and `DarwinNotificationDetails`, both added for the ringtone-as-notification-sound feature) - swept the whole diff for anything similar, and confirmed those were the only three spots.

**Files touched:** `services/ringtone_service.dart`, `services/notification_service.dart`

---

# Sell flow — photo capture kicking you back to Home

## What was actually happening

"Directed to the splash screen, like I'd just clicked the app icon" was the right read - that's exactly what it was. Taking a photo hands the foreground over to the system camera app, and on a memory-constrained phone Android can, and does, kill BROKA's process in the background to free that memory. When you back out of the camera, Android relaunches BROKA from nothing - a brand new process, a fresh splash screen - and since Flutter keeps no memory of the old screen, the entire in-progress listing (every field, every photo already taken) was just gone. Splash screen then saw you were still logged in and sent you to Home, since as far as the app could tell, that's a completely fresh launch - it has no way to know you were actually mid-task.

This also explains why video never did this: `pickVideo` just hands back a file path, no extra processing. `pickImage` (with `maxWidth`/`imageQuality` set, so it compresses on the way in) does noticeably more work exactly when the app is most memory-starved - not the sole reason this class of kill happens, but a real contributor.

This can't be prevented outright - Android is explicit that any backgrounded process is fair game to kill - so instead of chasing the root cause, I made the flow resilient to it, which is the standard way this gets handled.

## The fix

- New `SellDraftStore` (same on-device pattern as the chat cache) snapshots the whole in-progress listing - every field, plus the photos/video already taken - right before every single camera/video launch, which is the highest-risk moment.
- `SellScreen` restores it automatically on open, with a small "Draft restored" banner and a Discard option if you don't want it.
- **Splash screen now checks for a pending draft before deciding where to send you** - if one exists, it opens straight back into the listing instead of Home. This is the part that directly fixes what you were seeing.
- Also autosaves (debounced) on ordinary field edits and photo/video removals, so the same protection covers more than just the camera moment.
- Draft is cleared automatically once the listing is successfully submitted.

One honest caveat: the brief splash-screen flash itself can still happen sometimes - that's just how a cold process restart works on Android, and isn't something an app can skip. What's fixed is landing back in your listing with everything intact afterward, instead of losing it all at Home.

**Files touched:** `services/sell_draft_store.dart` (new), `screens/sell_screen.dart`, `screens/splash_screen.dart`


---

# Build fix — backend CI test failure (`test_traders.py`)

Your CI run failed on the backend test suite:

```
FAILED tests/test_traders.py::TestTraders::test_specialization_derived_from_listings_not_self_declared - AssertionError: assert 'cat-electronics-2' in []
```

with this underneath it in the captured logs:

```
ERROR    api.core.events  [events] handler on_listing_created_update_specialization raised for event ListingCreated: Multiple rows were found when one or none was required
```

Root cause turned out to be bigger than that one test. `api/database.py` builds its DB engine once, the moment it's first imported - but every test file tries to sandbox itself with its own `monkeypatch.setenv("DATABASE_URL", ...)` inside a fixture, which runs *after* that first import already happened. Since CI runs the whole suite in one process (`pytest tests/ -v`, `DATABASE_URL=sqlite+aiosqlite:///:memory:`), every test file was actually sharing that one in-memory database the whole time, regardless of which "isolated" sqlite path each file's own fixture thought it was pointing at. `test_categories.py` seeds a Category named "Electronics"; `test_traders.py` seeds a second, differently-`id`'d Category also named "Electronics" - both landed in the same shared db, so `Category.name == "Electronics"` matched two rows, and `scalar_one_or_none()` raised instead of returning one.

(You'd actually already run into a symptom of this exact bug once before - see the phone-uniqueness comment in `tokens()` in `test_escrow.py`.)

## The fix

- `api/database.py`: added `reset_engine()`, and turned `AsyncSessionLocal` into a function that always resolves the *current* engine/session factory, instead of a `sessionmaker` object frozen at import time. Every existing `AsyncSessionLocal()` call site keeps working unchanged - nothing else needed to change.
- All 10 test files that touch the DB now call `reset_engine()` right after `monkeypatch.setenv("DATABASE_URL", ...)`, so each module actually gets its own isolated db, like its own fixture already claimed it did.
- `trader_specialization_subscribers.py`: the Category lookup no longer assumes `Category.name` is unique - it isn't, no constraint enforces that. It now orders top-level-categories-first and picks deterministically instead of crashing if two rows ever do share a name, whether that's a test-isolation artifact or a real duplicate in production.

Couldn't run `pytest` myself to confirm green (no network/deps in this environment) - worth a run on your end before merging.

**Files touched:** `backend/api/database.py`, `backend/api/core/trader_specialization_subscribers.py`, `backend/tests/test_auctions.py`, `backend/tests/test_auth.py`, `backend/tests/test_buy_agent.py`, `backend/tests/test_categories.py`, `backend/tests/test_deal_ws.py`, `backend/tests/test_escrow.py`, `backend/tests/test_interest_nudges.py`, `backend/tests/test_listings.py`, `backend/tests/test_traders.py`, `backend/tests/test_trending.py`
