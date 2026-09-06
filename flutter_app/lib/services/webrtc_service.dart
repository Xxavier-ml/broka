// BROKA - WebRTC Service
// Manages one P2P audio or video call via WebSocket signaling on the BROKA
// backend. Caller/callee exchange SDP + ICE through /calls/ws/{roomId}.
// Media goes peer-to-peer where possible; Cloudflare Realtime TURN relays
// it when direct connectivity isn't available (see _fetchIceConfiguration()
// below and GET /calls/turn-credentials on the backend).
//
// Hardening pass (production MVP): every async step below that resumes
// after an `await` checks _generation before touching _pc/_ws again, so a
// stale continuation from a call that's already been hung up/disposed
// can't crash on a null-checked reference or corrupt a state that's moved
// on. State transitions go through _setState()'s explicit table instead
// of being set unconditionally, so a duplicated/out-of-order signaling
// message (e.g. a stray "connected" callback after hangup) can't move the
// call backwards. ICE candidates that arrive before the remote
// description is set are queued, not dropped. A dropped WebSocket
// attempts bounded, backed-off reconnection instead of failing the call
// immediately - see _scheduleReconnect(). Once connected, a best-effort
// connection-path check (direct/STUN/TURN) runs once via getStats() -
// see ConnectionDiagnostics and _reportDiagnosticsOnceConnected().

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_service.dart';

enum CallState {
  idle,
  connecting,
  calling,     // caller: sent offer, waiting for answer
  ringing,     // callee: received offer, waiting for user to accept
  connected,
  recovering,  // was connected, transient WebRTC disconnect - attempting ICE restart before giving up (Section 6)
  ended,
  failed,
}

// Lightweight, best-effort connection diagnostics (Sections 13-15) - built
// once, when the call actually connects, never streamed continuously.
// connectionPath answers the question Section 30 cares about most: was
// this call actually relayed through Cloudflare TURN, or did it connect
// directly/via STUN? Determined from RTCPeerConnection.getStats()'s
// selected candidate-pair - see _reportDiagnosticsOnceConnected(). Exposed
// via onDiagnostics for the UI (or a future backend-reporting call) to use;
// this file itself doesn't report anywhere yet - see that method's doc
// comment for the current scope boundary.
class ConnectionDiagnostics {
  final String connectionPath; // 'direct' | 'stun' | 'turn' | 'unknown'
  final Duration? timeToConnect;
  final int reconnectCount;
  final int iceRestartCount;
  const ConnectionDiagnostics({
    required this.connectionPath,
    this.timeToConnect,
    required this.reconnectCount,
    required this.iceRestartCount,
  });

  @override
  String toString() => 'ConnectionDiagnostics(path: $connectionPath, '
      'timeToConnect: $timeToConnect, reconnects: $reconnectCount, '
      'iceRestarts: $iceRestartCount)';
}

// Which transitions are legal from each state - mirrors the server-side
// state machine in api/core/call_state.py (kept intentionally simpler,
// since the client only ever tracks ITS OWN side of one call). Every
// terminal state (ended, failed) has an empty transition set, so nothing
// can move a call "backwards" out of it - the exact class of bug this
// guards against is a stale async callback (e.g. RTCPeerConnection
// reporting "connected" a moment after hangup() already ran) trying to
// resurrect a call that's already over.
const Map<CallState, Set<CallState>> _kAllowedTransitions = {
  CallState.idle:       {CallState.connecting},
  CallState.connecting: {CallState.calling, CallState.ringing, CallState.failed, CallState.ended},
  CallState.calling:    {CallState.connected, CallState.failed, CallState.ended},
  CallState.ringing:    {CallState.connected, CallState.failed, CallState.ended},
  CallState.connected:  {CallState.recovering, CallState.failed, CallState.ended},
  // A successful ICE restart brings this straight back to `connected`;
  // exhausting the retry budget (see _attemptIceRestart()) is what
  // actually reaches `failed` from here.
  CallState.recovering: {CallState.connected, CallState.failed, CallState.ended},
  CallState.failed:     {},
  CallState.ended:      {},
};

class WebRtcService {
  final String roomId;
  final bool   isCaller;
  final String userId;
  final String callToken; // short-lived, room-scoped - see GET /calls/turn-credentials's
                           // sibling auth endpoints and _connectWs() below
  final String callType; // 'audio' | 'video'

  WebRtcService({
    required this.roomId,
    required this.isCaller,
    required this.userId,
    required this.callToken,
    this.callType = 'audio',
  });

  bool get isVideo => callType == 'video';

  // ── Callbacks ─────────────────────────────────────────────────────────────
  ValueChanged<CallState>? onStateChange;
  ValueChanged<String>?    onError;
  // Fires once the remote party's media is flowing - for a video call this
  // is also the cue that remoteRenderer now has a live feed attached.
  VoidCallback?            onRemoteStreamConnected;
  // Fires once the local mic/camera stream is ready (localRenderer has a
  // feed attached, for video calls) - lets the UI show the self-preview the
  // instant it's available instead of waiting for the next state change.
  VoidCallback?            onLocalMediaReady;
  ValueChanged<Duration>?  onDurationTick;
  // Fires once, shortly after the call reaches `connected` - see
  // ConnectionDiagnostics doc comment above.
  ValueChanged<ConnectionDiagnostics>? onDiagnostics;

  // ── Video renderers (initialized only when callType == 'video') ──────────
  final RTCVideoRenderer localRenderer  = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;
  bool get renderersReady => _renderersReady;

  // ── Private state ─────────────────────────────────────────────────────────
  RTCPeerConnection? _pc;
  MediaStream?       _local;
  WebSocketChannel?  _ws;
  Timer?             _durationTimer;
  Duration           _duration = Duration.zero;
  CallState          _state    = CallState.idle;
  bool               _muted    = false;
  bool               _speaker  = false;
  bool               _videoEnabled = true;
  bool               _offerSent = false;

  // Signaling recovery (Section 5): cached once we successfully
  // setLocalDescription, so a fresh 'ready' after a WS reconnect can
  // resend the SAME sdp instead of either assuming _offerSent means
  // "the callee actually received it" (it doesn't - only that we tried)
  // or silently doing nothing. Cleared implicitly by _remoteDescriptionSet
  // becoming true - once negotiation actually completes, there's nothing
  // left to resend.
  RTCSessionDescription? _lastLocalOffer;
  RTCSessionDescription? _lastLocalAnswer;

  // Bumped by _cleanup() - any async continuation captured before that
  // point (via `final gen = _generation;`) can tell it's now stale and
  // must not touch _pc/_ws or push a state change for a call that's
  // already torn down. See class doc comment above.
  int _generation = 0;

  // Duplicate-signaling guard (Section 8): once the remote description is
  // set, a second offer/answer for the same call must not be reprocessed.
  bool _remoteDescriptionSet = false;

  // ICE candidates that arrive before setRemoteDescription() has actually
  // been called are queued here instead of being handed to
  // RTCPeerConnection.addCandidate(), which throws if called too early -
  // flushed by _flushPendingIce() the moment the remote description lands.
  final List<RTCIceCandidate> _pendingIce = [];

  CallState get state    => _state;
  bool get muted         => _muted;
  bool get speakerOn     => _speaker;
  bool get videoEnabled  => _videoEnabled;
  Duration get duration  => _duration;

  // ── ICE config: STUN (direct P2P discovery) + TURN (relay fallback) ──────
  // TURN is essential for real-world mobile networks - STUN-only ICE often
  // fails silently on carrier-grade NAT (very common on Kenyan mobile data),
  // which looks exactly like "call connects/rings but no audio flows".
  // TURN relay credentials now come from Cloudflare Realtime - short-lived,
  // fetched per-call via GET /calls/turn-credentials (see
  // _fetchIceConfiguration() below) - instead of a hardcoded third-party
  // credential. If that fetch fails for any reason, calls fall back to
  // this STUN-only config so direct P2P connectivity can still be
  // attempted rather than failing the call outright.
  static const _fallbackIceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  // Set once ICE configuration is fetched for this call - checked in
  // _attemptIceRestart() (Phase 7) so a restart refreshes stale TURN
  // credentials via RTCPeerConnection.setConfiguration() first rather than
  // risking an expired credential on the restarted ICE path. Deliberately
  // NOT a continuous mid-call refresh loop: BROKA's calls are short 1-to-1
  // sessions well under Cloudflare's TTL, so anything beyond a pre-restart
  // check isn't justified yet.
  DateTime? _iceCredentialsExpireAt;

  // ── Connect timeout (Section 6) ───────────────────────────────────────────
  // Distinct from the 45s ring timer the VoIP screen already owns (that
  // one covers "nobody answered yet"): this covers "SDP/ICE exchange
  // itself has started but is stuck" - armed the moment we enter
  // calling/ringing, disarmed on any other transition (see _setState()).
  Timer? _connectTimeoutTimer;
  static const _connectTimeout = Duration(seconds: 30);

  // ── WebSocket reconnection (Section 7) ────────────────────────────────────
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 4;
  Timer? _reconnectTimer;

  // ── WebSocket watchdog (Phase 5) ──────────────────────────────────────────
  // The server pings every WS_HEARTBEAT_INTERVAL_SECONDS (15s); if NOTHING
  // arrives - not even a ping - for a full window beyond that, the
  // connection is silently dead (e.g. a mobile radio drop with no clean
  // FIN/RST) and waiting on WebSocketChannel's own onError/onDone would
  // otherwise mean waiting on the OS/transport's own, often much slower,
  // dead-peer detection. Reset on every inbound message, not just pings.
  Timer? _wsWatchdogTimer;
  static const _wsWatchdogTimeout = Duration(seconds: 25);

  void _armWsWatchdog() {
    _wsWatchdogTimer?.cancel();
    _wsWatchdogTimer = Timer(_wsWatchdogTimeout, () {
      if (_state == CallState.ended || _state == CallState.failed) return;
      _onWsDisrupted('No signaling activity for ${_wsWatchdogTimeout.inSeconds}s');
    });
  }

  // ── ICE restart (Section 6) ───────────────────────────────────────────────
  // A transient RTCPeerConnectionStateDisconnected doesn't mean the call
  // failed - ICE can and often does self-heal (a brief Wi-Fi/cell handoff,
  // a momentary NAT rebind) without any action here. Only if it's STILL
  // unhealthy after a short grace period do we attempt an ICE restart, and
  // only up to a bounded number of times before giving up for real.
  int _iceRestartAttempts = 0;
  static const _maxIceRestartAttempts = 2;
  static const _disconnectGracePeriod = Duration(seconds: 6);
  Timer? _disconnectGraceTimer;
  bool _iceRestartInProgress = false;

  // For ConnectionDiagnostics.timeToConnect - set once, when start() begins.
  DateTime? _connectingStartedAt;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Start: get mic/camera → open WebSocket → create peer connection.
  /// Caller then sends an offer; callee waits for one.
  Future<void> start() async {
    final gen = _generation;
    _connectingStartedAt = DateTime.now();
    debugPrint('WebRTC: ${isCaller ? "CALL_INITIATED" : "CALL_ACCEPTED"} room=$roomId role=${isCaller ? "caller" : "callee"} type=$callType');
    _setState(CallState.connecting);
    try {
      if (isVideo) {
        await localRenderer.initialize();
        await remoteRenderer.initialize();
        _renderersReady = true;
      }
      debugPrint('WebRTC: LOCAL_MEDIA_REQUESTED room=$roomId');
      await _initMedia();
      if (gen != _generation) return;
      debugPrint('WebRTC: LOCAL_MEDIA_READY room=$roomId');
      onLocalMediaReady?.call();
      await _createPc();
      if (gen != _generation) return;
      debugPrint('WebRTC: WEBSOCKET_CONNECTING room=$roomId');
      await _connectWs();
      if (gen != _generation) return;
      // NOTE: the caller must NOT send its SDP offer here - at this point the
      // room may still be empty (the callee hasn't joined). An offer sent now
      // is relayed to nobody and lost, leaving the call stuck on "Calling…".
      // Instead we wait for the backend's "ready" signal (fired once BOTH
      // peers are in the room) and send the offer from _onSignal(). We only
      // flip the UI to "calling" so the caller sees feedback immediately.
      if (isCaller) {
        _setState(CallState.calling);
      }
    } catch (e) {
      if (gen == _generation) _fail('Could not start call: $e');
    }
  }

  Future<void> hangup() async {
    _ws?.sink.add(jsonEncode({'type': 'hangup', 'room_id': roomId}));
    await _cleanup();
    _setState(CallState.ended);
  }

  void toggleMute() {
    _muted = !_muted;
    _local?.getAudioTracks().forEach((t) => t.enabled = !_muted);
  }

  void toggleSpeaker() {
    _speaker = !_speaker;
    Helper.setSpeakerphoneOn(_speaker);
  }

  /// Turns the local camera feed on/off mid-call (audio keeps flowing).
  /// No-op for audio calls.
  void toggleVideo() {
    if (!isVideo) return;
    _videoEnabled = !_videoEnabled;
    _local?.getVideoTracks().forEach((t) => t.enabled = _videoEnabled);
  }

  /// Flips between front/back camera mid-call. No-op for audio calls.
  Future<void> switchCamera() async {
    if (!isVideo || _local == null) return;
    final tracks = _local!.getVideoTracks();
    if (tracks.isNotEmpty) {
      try { await Helper.switchCamera(tracks.first); } catch (_) {}
    }
  }

  void dispose() {
    _durationTimer?.cancel();
    _cleanup();
    if (_renderersReady) {
      localRenderer.dispose();
      remoteRenderer.dispose();
    }
  }

  // ── WebSocket signaling ───────────────────────────────────────────────────

  Future<void> _connectWs() async {
    final raw  = ApiService.baseUrl;
    final base = raw.startsWith('https://')
        ? raw.replaceFirst('https://', 'wss://')
        : raw.replaceFirst('http://', 'ws://');
    // Short-lived, room-scoped call_token (from POST /calls/initiate or
    // GET /calls/pending/{listingId} / /calls/{roomId}/token) - not the
    // normal long-lived access token, which used to sit in this URL where
    // it could end up in proxy/server access logs.
    final uri = Uri.parse('$base/calls/ws/$roomId?token=$callToken');

    _ws = WebSocketChannel.connect(uri);
    _ws!.stream.listen(
      _onSignal,
      onError: (e) => _onWsDisrupted('Signal error: $e'),
      onDone:  () => _onWsDisrupted(null),
    );

    // Announce presence
    _ws!.sink.add(jsonEncode({
      'type':    'join',
      'room_id': roomId,
      'user_id': userId,
      'role':    isCaller ? 'caller' : 'callee',
    }));
    debugPrint('WebRTC: WEBSOCKET_CONNECTED room=$roomId');

    // A connection just succeeded (we got far enough to send on it without
    // throwing) - a fresh drop later deserves a fresh set of retry budget,
    // not whatever was left over from an earlier, unrelated blip.
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _armWsWatchdog();
  }

  void _onSignal(dynamic raw) {
    _armWsWatchdog();
    try {
      final m    = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = m['type'] as String?;

      switch (type) {
        case 'ping':
          // Server-side heartbeat (Phase 5) - just confirms this socket is
          // still alive; nothing else to do on our end.
          _ws?.sink.add(jsonEncode({'type': 'pong', 'room_id': roomId}));
          break;
        case 'ready':
          // Both peers in room - caller sends offer now. Also fires again
          // on a WS reconnect (server re-sends 'ready' once room membership
          // reaches 2 again), which is what makes resend-on-reconnect work:
          // this is the ONE signal both sides can use to notice "signaling
          // just came back" without a separate reconnect-specific message.
          debugPrint('WebRTC: SIGNALING_READY room=$roomId');
          if (isCaller) {
            if (_lastLocalOffer != null && !_remoteDescriptionSet) {
              // We already created+sent an offer, but the callee never
              // answered - most likely it never reached them (the WS
              // dropped in between). Resend the SAME sdp rather than
              // creating a fresh one: idempotent, no renegotiation loop.
              _ws?.sink.add(jsonEncode({
                'type': 'offer', 'room_id': roomId, 'sdp': _lastLocalOffer!.sdp,
              }));
              debugPrint('WebRTC: OFFER_SENT room=$roomId (resend after reconnect)');
            } else if (!_offerSent) {
              _sendOffer();
            }
            // else: _remoteDescriptionSet is already true - negotiation
            // finished before this 'ready' arrived (e.g. a late-arriving
            // duplicate); nothing to resend.
          } else if (_lastLocalAnswer != null) {
            // Callee side: we already answered once - resend in case it
            // never reached the caller before signaling dropped.
            _ws?.sink.add(jsonEncode({
              'type': 'answer', 'room_id': roomId, 'sdp': _lastLocalAnswer!.sdp,
            }));
            debugPrint('WebRTC: ANSWER_SENT room=$roomId (resend after reconnect)');
          }
          break;
        case 'offer':
          _handleOffer(m['sdp'] as String, isRestart: m['restart'] == true);
          break;
        case 'answer':
          _handleAnswer(m['sdp'] as String);
          break;
        case 'ice':
          _addIce(m['candidate'] as Map<String, dynamic>);
          break;
        case 'hangup':
          debugPrint('WebRTC: CALL_ENDED room=$roomId reason=remote_hangup');
          _cleanup();
          _setState(CallState.ended);
          break;
        case 'busy':
          _cleanup();
          _setState(CallState.failed);
          onError?.call('Other party is busy');
          break;
        case 'error':
          _fail(m['message'] as String? ?? 'Unknown signaling error');
          break;
      }
    } catch (e) {
      debugPrint('WebRTC signal parse error: $e');
    }
  }

  /// Fired on both a clean WS close and a transport error - either way the
  /// signaling channel is down. If the call is already over there's
  /// nothing to reconnect for; otherwise try bounded, backed-off
  /// reconnection before giving up on the call.
  void _onWsDisrupted(String? errorMsg) {
    debugPrint('WebRTC: ${errorMsg != null ? "WEBSOCKET_ERROR" : "WEBSOCKET_DISCONNECTED"} room=$roomId ${errorMsg ?? ""}');
    if (_state == CallState.ended || _state == CallState.failed) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _fail(errorMsg ?? 'Connection lost - could not reconnect');
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    final gen = _generation;
    _reconnectAttempts++;
    // Exponential backoff with jitter: ~1s, 2s, 4s, 8s +/- 30%, clamped to
    // a sane range - bounded by _maxReconnectAttempts so a genuinely dead
    // network fails the call cleanly instead of retrying forever.
    final baseMs   = 1000 * (1 << (_reconnectAttempts - 1));
    final jitterMs = (baseMs * 0.3 * (Random().nextDouble() * 2 - 1)).round();
    final delay    = Duration(milliseconds: (baseMs + jitterMs).clamp(500, 30000));
    debugPrint('WebRTC: WS disrupted, reconnect attempt '
        '$_reconnectAttempts/$_maxReconnectAttempts in ${delay.inMilliseconds}ms');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      if (gen != _generation) return;
      if (_state == CallState.ended || _state == CallState.failed) return;
      try {
        await _connectWs();
      } catch (_) {
        if (gen == _generation) _onWsDisrupted('Reconnect failed');
      }
    });
    // KNOWN LIMITATION: the backend caps a room at 2 WebSocket peers: if
    // the server hasn't yet noticed our OLD connection died (WS death
    // detection has some inherent lag), an early reconnect attempt can be
    // rejected as "room full" (a 'busy' message - see _onSignal above,
    // which currently fails the call immediately rather than treating it
    // as a retryable case during reconnection specifically). The backoff
    // above gives the server some time to catch up before the next
    // attempt, but this isn't a guaranteed-safe race today.
  }

  // ── ICE restart (Section 6) ───────────────────────────────────────────────

  void _armDisconnectGraceTimer() {
    final gen = _generation;
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = Timer(_disconnectGracePeriod, () {
      if (gen != _generation) return;
      // Only the caller drives restart attempts (see _attemptIceRestart()'s
      // doc comment) - the callee just waits in `recovering`, relying on
      // the caller's restart offer arriving normally through _handleOffer,
      // or on native WebRTC's own eventual RTCPeerConnectionStateFailed as
      // a backstop if it truly can't recover. Running an independent
      // grace/attempt loop on both sides would let the callee's own
      // counter exhaust and fail the call while the caller's restart was
      // still legitimately in progress.
      if (_state == CallState.recovering && isCaller) {
        _attemptIceRestart();
      }
    });
  }

  Future<void> _attemptIceRestart() async {
    if (_iceRestartInProgress) return; // never run two restarts concurrently
    if (_pc == null) return;
    if (_iceRestartAttempts >= _maxIceRestartAttempts) {
      _fail('Connection could not recover after $_maxIceRestartAttempts attempt(s)');
      return;
    }
    _iceRestartInProgress = true;
    _iceRestartAttempts++;
    final gen = _generation;
    debugPrint('WebRTC: ICE_RESTART_STARTED room=$roomId attempt=$_iceRestartAttempts/$_maxIceRestartAttempts');
    try {
      // Refresh TURN credentials first if they're at or near expiry (Phase
      // 7) - restarting ICE with an expired TURN username/credential would
      // just fail relay candidates silently, defeating the point of
      // restarting at all. Cloudflare's TTL is long relative to a normal
      // call, so this is rarely live in practice, but a long-running call
      // (or one that's already been through an earlier restart) could
      // otherwise hit it. This intentionally does NOT do continuous
      // mid-call refresh (not justified for BROKA's short 1-to-1 calls per
      // the design note above) - only a pre-restart check, per the
      // spec's own "if full mid-call refresh isn't justified, do a safe
      // pre-restart refresh" allowance.
      // DEVICE-VERIFICATION-REQUIRED: setConfiguration() on an already-live
      // RTCPeerConnection is standard WebRTC/flutter_webrtc API, but this
      // exact path hasn't been exercised on a real call in this sandbox
      // (no Flutter toolchain here) - hence the broad catch below, which
      // falls through to restarting with whatever configuration is
      // already active if this fails for any reason, matching today's
      // exact (never-refreshed) behavior rather than aborting recovery.
      final margin = const Duration(minutes: 2);
      final stale = _iceCredentialsExpireAt == null ||
          DateTime.now().isAfter(_iceCredentialsExpireAt!.subtract(margin));
      if (stale && _pc != null) {
        try {
          final freshConfig = await _fetchIceConfiguration();
          if (gen == _generation && _pc != null) {
            await _pc!.setConfiguration(freshConfig);
            debugPrint('WebRTC: ICE_CONFIG_REFRESHED room=$roomId');
          }
        } catch (e) {
          debugPrint('WebRTC: ICE config refresh failed, restarting with existing config: $e');
        }
      }

      // Only the offering side initiates a restart - flutter_webrtc/native
      // WebRTC picks up a fresh ICE ufrag/pwd from the 'iceRestart' offer
      // constraint. The answering side doesn't initiate anything here; it
      // just receives the resulting offer through the normal 'offer'
      // signaling path (see _handleOffer()'s isRestart param below, which
      // is what lets a restart offer through even though a remote
      // description was already set once).
      if (isCaller && _pc != null) {
        final offer = await _pc!.createOffer(
            {'iceRestart': true, 'offerToReceiveAudio': true, 'offerToReceiveVideo': isVideo});
        if (gen != _generation || _pc == null) return;
        await _pc!.setLocalDescription(offer);
        _lastLocalOffer = offer;
        if (gen != _generation || _ws == null) return;
        _ws!.sink.add(jsonEncode({
          'type': 'offer', 'room_id': roomId, 'sdp': offer.sdp, 'restart': true,
        }));
        debugPrint('WebRTC: ICE_RESTART_OFFER_SENT room=$roomId');
      }
      // If we're still in `recovering` after another grace period (the
      // restart offer went out but negotiation hasn't completed, or -
      // callee side - no restart offer has arrived yet), arm another
      // grace window; onConnectionState's connected case resets
      // _iceRestartAttempts and cancels this the moment it actually works.
      _armDisconnectGraceTimer();
    } catch (e, st) {
      debugPrint('WebRTC: ICE restart failed: $e\n$st');
      if (gen == _generation) _fail('Could not restart the connection: $e');
    } finally {
      _iceRestartInProgress = false;
    }
  }

  // ── SDP exchange ──────────────────────────────────────────────────────────

  Future<void> _sendOffer() async {
    final gen = _generation;
    try {
      if (_pc == null) return;
      _offerSent = true;
      debugPrint('WebRTC: OFFER_CREATED room=$roomId');
      final offer = await _pc!.createOffer(
          {'offerToReceiveAudio': true, 'offerToReceiveVideo': isVideo});
      if (gen != _generation || _pc == null) return;
      await _pc!.setLocalDescription(offer);
      _lastLocalOffer = offer; // cache for resend - see 'ready' handler in _onSignal
      debugPrint('WebRTC: OFFER_SET_LOCAL room=$roomId');
      if (gen != _generation || _ws == null) return;
      _ws!.sink.add(jsonEncode({
        'type': 'offer', 'room_id': roomId, 'sdp': offer.sdp,
      }));
      debugPrint('WebRTC: OFFER_SENT room=$roomId');
    } catch (e, st) {
      // FORENSIC FIX: this used to be called fire-and-forget from
      // _onSignal's synchronous 'ready' case with no error handling of
      // its own - Dart's try/catch only guards the synchronous prefix of
      // an async function up to its first `await`, so any failure in
      // createOffer()/setLocalDescription() (both very possible on a real
      // device - codec negotiation, native platform-channel errors, etc.)
      // became a truly unhandled Future rejection, which is very likely
      // what was surfacing as "the app closes" on a real device. Now it's
      // caught, logged with the full stack trace, and fails the call
      // cleanly instead.
      if (gen == _generation) {
        debugPrint('WebRTC: _sendOffer failed: $e\n$st');
        _fail('Could not create call offer: $e');
      }
    }
  }

  Future<void> _handleOffer(String sdp, {bool isRestart = false}) async {
    final gen = _generation;
    // Duplicate-offer guard (Section 8): once the remote description is
    // already set, a second 'offer' (a duplicated/replayed signaling
    // message) must not re-run the answer flow from scratch. A genuine
    // ICE-restart offer (Section 6) is the one deliberate exception - it's
    // a legitimate renegotiation, not a duplicate, so it's allowed through.
    if (_remoteDescriptionSet && !isRestart) {
      debugPrint('WebRTC: ignoring duplicate offer');
      return;
    }
    try {
      if (!isRestart) {
        // A restart offer arrives mid-call - moving to `ringing` would be
        // wrong (we're not receiving a new incoming call, just
        // renegotiating an existing one). recovering -> connected is
        // reached the normal way, via onConnectionState once ICE
        // reconnects, not through a state change here.
        _setState(CallState.ringing);
      }
      debugPrint('WebRTC: ${isRestart ? "ICE_RESTART_OFFER_RECEIVED" : "OFFER_RECEIVED"} room=$roomId');
      if (_pc == null) return;
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      debugPrint('WebRTC: REMOTE_DESCRIPTION_SET room=$roomId (offer)');
      if (gen != _generation || _pc == null) return;
      _remoteDescriptionSet = true;
      await _flushPendingIce();
      if (gen != _generation || _pc == null) return;
      final answer = await _pc!.createAnswer(
          {'offerToReceiveAudio': true, 'offerToReceiveVideo': isVideo});
      debugPrint('WebRTC: ANSWER_CREATED room=$roomId');
      if (gen != _generation || _pc == null) return;
      await _pc!.setLocalDescription(answer);
      _lastLocalAnswer = answer; // cache for resend - see 'ready' handler in _onSignal
      debugPrint('WebRTC: ANSWER_SET_LOCAL room=$roomId');
      if (gen != _generation || _ws == null) return;
      _ws!.sink.add(jsonEncode({
        'type': 'answer', 'room_id': roomId, 'sdp': answer.sdp,
      }));
      debugPrint('WebRTC: ANSWER_SENT room=$roomId');
    } catch (e, st) {
      // Same fix as _sendOffer() above - see that method's comment.
      if (gen == _generation) {
        debugPrint('WebRTC: _handleOffer failed: $e\n$st');
        _fail('Could not answer the call: $e');
      }
    }
  }

  Future<void> _handleAnswer(String sdp) async {
    final gen = _generation;
    // Duplicate-answer guard (Section 8) - same reasoning as _handleOffer.
    if (_remoteDescriptionSet) {
      debugPrint('WebRTC: ignoring duplicate answer');
      return;
    }
    try {
      debugPrint('WebRTC: ANSWER_RECEIVED room=$roomId');
      if (_pc == null) return;
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      debugPrint('WebRTC: REMOTE_DESCRIPTION_SET room=$roomId (answer)');
      if (gen != _generation) return;
      _remoteDescriptionSet = true;
      await _flushPendingIce();
    } catch (e, st) {
      // Same fix as _sendOffer() above - see that method's comment.
      if (gen == _generation) {
        debugPrint('WebRTC: _handleAnswer failed: $e\n$st');
        _fail('Could not complete the call connection: $e');
      }
    }
  }

  void _addIce(Map<String, dynamic> c) {
    RTCIceCandidate candidate;
    try {
      candidate = RTCIceCandidate(
        c['candidate']     as String,
        c['sdpMid']        as String?,
        c['sdpMLineIndex'] as int?,
      );
    } catch (e) {
      debugPrint('WebRTC: malformed ICE candidate payload: $e');
      return;
    }
    debugPrint('WebRTC: ICE_CANDIDATE_RECEIVED room=$roomId');
    if (!_remoteDescriptionSet || _pc == null) {
      // Candidates can legitimately arrive before the offer/answer that
      // establishes the remote description, depending on network timing -
      // queue instead of calling addCandidate() too early, which throws.
      // Flushed by _flushPendingIce() once the remote description lands.
      debugPrint('WebRTC: ICE_CANDIDATE_QUEUED room=$roomId');
      _pendingIce.add(candidate);
      return;
    }
    _addIceNow(candidate);
  }

  Future<void> _addIceNow(RTCIceCandidate candidate) async {
    try {
      // FORENSIC FIX: this used to call addCandidate() without awaiting
      // it, which meant the try/catch around it was decorative - it could
      // only ever catch a synchronous throw, never the async rejection
      // addCandidate() actually produces on a real device when a
      // candidate is malformed or arrives in the wrong peer-connection
      // state (a very real, common WebRTC failure, and ICE candidates
      // flow frequently - many per call - so this was a high-probability
      // unhandled-exception source, consistent with the crash being
      // reported as happening "eventually", not immediately).
      await _pc?.addCandidate(candidate);
    } catch (e) {
      // Recorded, not silently swallowed (Section 9) - deliberately logs
      // only the exception, never the candidate/SDP content itself.
      debugPrint('WebRTC: failed to add ICE candidate: $e');
    }
  }

  Future<void> _flushPendingIce() async {
    if (_pendingIce.isEmpty) return;
    final queued = List<RTCIceCandidate>.from(_pendingIce);
    _pendingIce.clear();
    for (final c in queued) {
      await _addIceNow(c);
    }
    debugPrint('WebRTC: ICE_CANDIDATES_FLUSHED room=$roomId count=${queued.length}');
  }

  // ── Peer connection ───────────────────────────────────────────────────────

  /// Fetches short-lived Cloudflare TURN credentials from the BROKA backend
  /// and builds the ICE configuration for createPeerConnection(). Falls
  /// back to STUN-only (_fallbackIceConfig) if the fetch fails for any
  /// reason - direct P2P connectivity can still work without TURN, just
  /// not for callers behind carrier-grade NAT.
  Future<Map<String, dynamic>> _fetchIceConfiguration() async {
    final creds = await ApiService.getTurnCredentials();
    final iceServers = creds?['ice_servers'];
    if (creds == null || iceServers is! List || iceServers.isEmpty) {
      debugPrint('WebRTC: TURN credentials unavailable, using STUN-only ICE');
      return _fallbackIceConfig;
    }
    final expiresIn = creds['expires_in'];
    if (expiresIn is int) {
      _iceCredentialsExpireAt = DateTime.now().add(Duration(seconds: expiresIn));
    }
    return {
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    };
  }

  Future<void> _createPc() async {
    final gen = _generation;
    final iceConfig = await _fetchIceConfiguration();
    if (gen != _generation) return;
    _pc = await createPeerConnection(iceConfig);
    debugPrint('WebRTC: PEER_CONNECTION_CREATED room=$roomId');
    if (gen != _generation) { try { await _pc?.close(); } catch (_) {} return; }

    // Add local audio (+ video, for video calls) tracks
    _local?.getTracks().forEach((t) {
      _pc!.addTrack(t, _local!);
      debugPrint('WebRTC: ${t.kind == "video" ? "LOCAL_VIDEO_TRACK_ADDED" : "LOCAL_AUDIO_TRACK_ADDED"} room=$roomId');
    });

    // Send ICE candidates to remote peer
    _pc!.onIceCandidate = (c) {
      // FORENSIC FIX: this callback fires directly from the native
      // flutter_webrtc plugin with no error handling at all - any failure
      // in jsonEncode()/the WS sink's add() (e.g. StateError if the sink
      // happens to be closed/reconnecting right at this moment) became an
      // unhandled exception escaping a native platform-channel callback,
      // a plausible contributor to the reported crash. Both operations
      // here are synchronous, so a plain try/catch is sufficient - no
      // await needed.
      if (gen != _generation) return;
      if (c.candidate == null) return;
      try {
        _ws?.sink.add(jsonEncode({
          'type': 'ice', 'room_id': roomId,
          'candidate': {
            'candidate':     c.candidate,
            'sdpMid':        c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          },
        }));
        debugPrint('WebRTC: ICE_CANDIDATE_SENT room=$roomId');
      } catch (e) {
        debugPrint('WebRTC: failed to send local ICE candidate: $e');
      }
    };

    // Connection state machine - the ONLY thing allowed to move CallState
    // to `connected` (Section 13/Phase 10: WS/ICE-gathering/etc. state
    // changes are diagnostic-only below, never call _setState()).
    _pc!.onConnectionState = (s) {
      if (gen != _generation) return; // stale callback from a torn-down call
      try {
        debugPrint('WebRTC: PEER_CONNECTION_STATE room=$roomId state=$s');
        switch (s) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _disconnectGraceTimer?.cancel();
            _disconnectGraceTimer = null;
            _iceRestartAttempts = 0; // reset - this is either the first connect or a successful recovery
            _setState(CallState.connected);
            debugPrint('WebRTC: CALL_CONNECTED room=$roomId');
            _startTimer();
            onRemoteStreamConnected?.call();
            _reportDiagnosticsOnceConnected();
            _reportWebRtcState('connected');
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            debugPrint('WebRTC: CALL_FAILED room=$roomId reason=peer_connection_failed');
            _reportWebRtcState('failed');
            _fail('WebRTC connection failed');
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            if (_state == CallState.connected) {
              // Don't fail immediately - ICE frequently self-heals from a
              // brief disconnect (Wi-Fi/cell handoff, momentary NAT
              // rebind) with no action needed. Give it a short grace
              // period; only attempt an ICE restart - and only then
              // eventually fail - if it's still unhealthy once that
              // expires.
              _reportWebRtcState('disconnected');
              _setState(CallState.recovering);
              debugPrint('WebRTC: entering recovery grace period (${_disconnectGracePeriod.inSeconds}s)');
              _armDisconnectGraceTimer();
            }
            break;
          default: break;
        }
      } catch (e, st) {
        // A caller-supplied callback (onRemoteStreamConnected, set by
        // VoipCallScreen) could in principle throw - e.g. if it isn't
        // careful about calling setState() after the widget's disposed.
        // This callback fires directly from native code, so let nothing
        // escape it uncaught.
        debugPrint('WebRTC: onConnectionState handler failed: $e\n$st');
      }
    };

    // Diagnostic-only (Section 13/Phase 10) - never drives CallState on
    // their own. "ICE gathering complete" is not "connected", and neither
    // is a lone ICE-connection-state change - onConnectionState above
    // (the overall peer connection state) is the only thing allowed to
    // move CallState, exactly to avoid the failure mode Section 13/Phase
    // 10 call out explicitly.
    _pc!.onIceGatheringState = (s) {
      if (gen != _generation) return;
      debugPrint('WebRTC: ICE_GATHERING_STATE room=$roomId state=$s');
    };
    _pc!.onIceConnectionState = (s) {
      if (gen != _generation) return;
      debugPrint('WebRTC: ICE_CONNECTION_STATE room=$roomId state=$s');
    };
    _pc!.onSignalingState = (s) {
      if (gen != _generation) return;
      debugPrint('WebRTC: signaling state = $s');
    };

    // Remote track received. For video calls this stream carries both the
    // audio and video tracks together, so attaching it to the renderer here
    // is correct regardless of which specific track fired the event.
    _pc!.onTrack = (event) {
      if (gen != _generation) return;
      try {
        debugPrint('WebRTC: ${event.track.kind == "video" ? "REMOTE_VIDEO_TRACK_RECEIVED" : "REMOTE_AUDIO_TRACK_RECEIVED"} room=$roomId');
        if (event.streams.isNotEmpty) {
          if (isVideo) {
            remoteRenderer.srcObject = event.streams[0];
          }
          onRemoteStreamConnected?.call();
        }
      } catch (e, st) {
        // Same reasoning as onConnectionState above - never let a native
        // callback propagate an uncaught exception.
        debugPrint('WebRTC: onTrack handler failed: $e\n$st');
      }
    };
  }

  Future<void> _initMedia() async {
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl':  true,
      },
      'video': isVideo
          ? {
              'facingMode': 'user',
              'width':  {'ideal': 640},
              'height': {'ideal': 480},
            }
          : false,
    });
    if (isVideo) {
      localRenderer.srcObject = _local;
    }
  }

  // ── Diagnostics (Sections 13-15) ──────────────────────────────────────────

  /// Best-effort connection-path detection via getStats() - answers "did
  /// this call actually use Cloudflare TURN, or connect directly/via
  /// STUN?" (Section 14/30). Called once, right after the peer connection
  /// reports `connected`; never polled/streamed continuously (Section 35).
  /// Parsing WebRTC stats reports varies subtly by platform/version, so
  /// this is wrapped defensively throughout - any parsing miss just
  /// leaves connectionPath as 'unknown' rather than throwing. NOT
  /// verified against a real call in this environment - the diagnostic
  /// itself (this method existing, being called at the right time, never
  /// crashing) is solid; the exact stats field names it looks for should
  /// be double-checked against a real getStats() dump on a live call.
  Future<void> _reportDiagnosticsOnceConnected() async {
    final gen = _generation;
    if (_pc == null) return;
    String path = 'unknown';
    try {
      final stats = await _pc!.getStats();
      Map<String, dynamic>? selectedPair;
      for (final report in stats) {
        final v = report.values;
        if (report.type == 'candidate-pair' &&
            v['state'] == 'succeeded' &&
            (v['nominated'] == true || v['selected'] == true)) {
          // report.values comes back as Map<dynamic, dynamic> from
          // flutter_webrtc - not assignable to Map<String, dynamic>?
          // without an explicit conversion, even though every key here is
          // always a String (a WebRTC stats field name).
          selectedPair = Map<String, dynamic>.from(v);
          break;
        }
      }
      final localId = selectedPair?['localCandidateId'];
      if (localId != null) {
        for (final report in stats) {
          if (report.id == localId && report.type == 'local-candidate') {
            final candidateType = report.values['candidateType'] as String?;
            if (candidateType == 'relay') {
              path = 'turn';
            } else if (candidateType == 'srflx' || candidateType == 'prflx') {
              path = 'stun';
            } else if (candidateType == 'host') {
              path = 'direct';
            }
            break;
          }
        }
      }
    } catch (e) {
      // Never crashes the call over a diagnostics-only failure - see
      // Section 9's "don't silently swallow, but don't let it break
      // anything either" spirit, applied here too.
      debugPrint('WebRTC: could not determine connection path: $e');
    }
    if (gen != _generation) return;
    debugPrint('WebRTC: connection path = $path');
    onDiagnostics?.call(ConnectionDiagnostics(
      connectionPath: path,
      timeToConnect: _connectingStartedAt != null
          ? DateTime.now().difference(_connectingStartedAt!)
          : null,
      reconnectCount: _reconnectAttempts,
      iceRestartCount: _iceRestartAttempts,
    ));
  }

  /// Tells the backend which WebRTC peer-connection state we just reached
  /// (Sections 5, 33) - the server can't observe this on its own, since it
  /// only relays opaque SDP/ICE messages. Best-effort: if the WS happens
  /// to be down right when this fires, the state simply isn't recorded
  /// server-side this time - never worth failing the call over.
  void _reportWebRtcState(String webrtcState) {
    try {
      _ws?.sink.add(jsonEncode({
        'type': 'state', 'state': webrtcState, 'room_id': roomId,
      }));
    } catch (_) {}
  }

  // ── Duration timer ────────────────────────────────────────────────────────
  void _startTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _duration += const Duration(seconds: 1);
      onDurationTick?.call(_duration);
    });
  }

  // ── Cleanup ───────────────────────────────────────────────────────────────

  Future<void> _cleanup() async {
    debugPrint('WebRTC: DISPOSE_STARTED room=$roomId');
    _generation++; // invalidate any in-flight async continuation - see class doc comment
    _durationTimer?.cancel();
    _connectTimeoutTimer?.cancel();
    _reconnectTimer?.cancel();
    _disconnectGraceTimer?.cancel();
    _wsWatchdogTimer?.cancel();
    try { await _pc?.close();  } catch (_) {}
    try {
      _local?.getTracks().forEach((t) => t.stop());
      await _local?.dispose();
    } catch (_) {}
    try { await _ws?.sink.close(); } catch (_) {}
    _pc = null; _local = null; _ws = null;
    _iceCredentialsExpireAt = null;
    _pendingIce.clear();
    debugPrint('WebRTC: DISPOSE_COMPLETED room=$roomId');
  }

  void _setState(CallState s) {
    if (_state == s) return; // idempotent no-op - a duplicated signal re-asserting the same state isn't an error
    final allowed = _kAllowedTransitions[_state] ?? const {};
    if (!allowed.contains(s)) {
      // e.g. a stale "connected" callback arriving after the call already
      // moved to ended/failed - see the class doc comment on _generation
      // for why this can happen, and why it must be a no-op, not a crash.
      debugPrint('WebRTC: ignored invalid state transition ${_state.name} -> ${s.name}');
      return;
    }
    _state = s;
    if (s == CallState.calling || s == CallState.ringing) {
      _armConnectTimeout();
    } else {
      _disarmConnectTimeout();
    }
    onStateChange?.call(s);
  }

  void _armConnectTimeout() {
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = Timer(_connectTimeout, () {
      // Distinct failure reason from the VoIP screen's own 45s "nobody
      // answered" ring timeout - this fires only once SDP exchange has
      // actually started (calling/ringing) and then stalled.
      if (_state == CallState.calling || _state == CallState.ringing) {
        _fail('Call timed out while connecting');
      }
    });
  }

  void _disarmConnectTimeout() {
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = null;
  }

  void _fail(String msg) {
    debugPrint('WebRTC: CALL_FAILED room=$roomId reason=$msg');
    _cleanup();
    _setState(CallState.failed);
    onError?.call(msg);
  }
}
