// BROKA - WebRTC Service
// Manages one P2P audio call via WebSocket signaling on the BROKA backend.
// Caller/callee exchange SDP + ICE through /calls/ws/{roomId}.
// Audio goes peer-to-peer after the handshake (STUN-only; no TURN needed on LAN).

import 'dart:async';
import 'dart:convert';
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
  ended,
  failed,
}

class WebRtcService {
  final String roomId;
  final bool   isCaller;
  final String userId;

  WebRtcService({
    required this.roomId,
    required this.isCaller,
    required this.userId,
  });

  // ── Callbacks ─────────────────────────────────────────────────────────────
  ValueChanged<CallState>? onStateChange;
  ValueChanged<String>?    onError;
  VoidCallback?            onRemoteAudioConnected;
  ValueChanged<Duration>?  onDurationTick;

  // ── Private state ─────────────────────────────────────────────────────────
  RTCPeerConnection? _pc;
  MediaStream?       _local;
  WebSocketChannel?  _ws;
  Timer?             _durationTimer;
  Duration           _duration = Duration.zero;
  CallState          _state    = CallState.idle;
  bool               _muted    = false;
  bool               _speaker  = false;
  bool               _offerSent = false;

  CallState get state   => _state;
  bool get muted        => _muted;
  bool get speakerOn    => _speaker;
  Duration get duration => _duration;

  // ── ICE config: public STUN servers (no account needed) ──────────────────
  static const _iceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  // ── Public API ────────────────────────────────────────────────────────────

  /// Start: get mic → open WebSocket → create peer connection.
  /// Caller then sends an offer; callee waits for one.
  Future<void> start() async {
    _setState(CallState.connecting);
    try {
      await _initMic();
      await _createPc();
      await _connectWs();
      if (isCaller && !_offerSent) {
        await _sendOffer();
        _setState(CallState.calling);
      }
    } catch (e) {
      _fail('Could not start call: $e');
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

  void dispose() {
    _durationTimer?.cancel();
    _cleanup();
  }

  // ── WebSocket signaling ───────────────────────────────────────────────────

  Future<void> _connectWs() async {
    final raw  = ApiService.baseUrl;
    final base = raw.startsWith('https://')
        ? raw.replaceFirst('https://', 'wss://')
        : raw.replaceFirst('http://', 'ws://');
    final token = ApiService.authToken ?? '';
    final uri   = Uri.parse(
        '$base/calls/ws/$roomId?token=$token&user_id=$userId');

    _ws = WebSocketChannel.connect(uri);
    _ws!.stream.listen(
      _onSignal,
      onError: (e) => _fail('Signal error: $e'),
      onDone:  _onWsClosed,
    );

    // Announce presence
    _ws!.sink.add(jsonEncode({
      'type':    'join',
      'room_id': roomId,
      'user_id': userId,
      'role':    isCaller ? 'caller' : 'callee',
    }));
  }

  void _onSignal(dynamic raw) {
    try {
      final m    = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = m['type'] as String?;

      switch (type) {
        case 'ready':
          // Both peers in room - caller sends offer now
          if (isCaller && !_offerSent) _sendOffer();
          break;
        case 'offer':
          _handleOffer(m['sdp'] as String);
          break;
        case 'answer':
          _handleAnswer(m['sdp'] as String);
          break;
        case 'ice':
          _addIce(m['candidate'] as Map<String, dynamic>);
          break;
        case 'hangup':
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

  void _onWsClosed() {
    if (_state == CallState.connected || _state == CallState.calling) {
      _fail('Connection lost');
    }
  }

  // ── SDP exchange ──────────────────────────────────────────────────────────

  Future<void> _sendOffer() async {
    _offerSent = true;
    final offer = await _pc!.createOffer(
        {'offerToReceiveAudio': true, 'offerToReceiveVideo': false});
    await _pc!.setLocalDescription(offer);
    _ws!.sink.add(jsonEncode({
      'type': 'offer', 'room_id': roomId, 'sdp': offer.sdp,
    }));
  }

  Future<void> _handleOffer(String sdp) async {
    _setState(CallState.ringing);
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final answer = await _pc!.createAnswer(
        {'offerToReceiveAudio': true, 'offerToReceiveVideo': false});
    await _pc!.setLocalDescription(answer);
    _ws!.sink.add(jsonEncode({
      'type': 'answer', 'room_id': roomId, 'sdp': answer.sdp,
    }));
  }

  Future<void> _handleAnswer(String sdp) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  void _addIce(Map<String, dynamic> c) {
    try {
      _pc?.addCandidate(RTCIceCandidate(
        c['candidate']    as String,
        c['sdpMid']       as String?,
        c['sdpMLineIndex'] as int?,
      ));
    } catch (_) {}
  }

  // ── Peer connection ───────────────────────────────────────────────────────

  Future<void> _createPc() async {
    _pc = await createPeerConnection(_iceConfig);

    // Add local audio track
    _local?.getTracks().forEach((t) => _pc!.addTrack(t, _local!));

    // Send ICE candidates to remote peer
    _pc!.onIceCandidate = (c) {
      if (c.candidate != null) {
        _ws?.sink.add(jsonEncode({
          'type': 'ice', 'room_id': roomId,
          'candidate': {
            'candidate':     c.candidate,
            'sdpMid':        c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          },
        }));
      }
    };

    // Connection state machine
    _pc!.onConnectionState = (s) {
      switch (s) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _setState(CallState.connected);
          _startTimer();
          onRemoteAudioConnected?.call();
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _fail('WebRTC connection failed');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          if (_state == CallState.connected) _fail('Call dropped');
          break;
        default: break;
      }
    };

    // Remote audio track received
    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) onRemoteAudioConnected?.call();
    };
  }

  Future<void> _initMic() async {
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl':  true,
      },
      'video': false,
    });
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
    _durationTimer?.cancel();
    try { await _pc?.close();  } catch (_) {}
    try {
      _local?.getTracks().forEach((t) => t.stop());
      await _local?.dispose();
    } catch (_) {}
    try { await _ws?.sink.close(); } catch (_) {}
    _pc = null; _local = null; _ws = null;
  }

  void _setState(CallState s) {
    if (_state == s) return;
    _state = s;
    onStateChange?.call(s);
  }

  void _fail(String msg) {
    debugPrint('WebRTC: $msg');
    _cleanup();
    _setState(CallState.failed);
    onError?.call(msg);
  }
}
