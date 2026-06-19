// BROKA - Polished In-App VoIP Call Screen
// Multi-ring ripple animation · call quality badge · per-state gradients
// Incoming call full-screen takeover · smooth state transitions

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../services/webrtc_service.dart';

class VoipCallScreen extends StatefulWidget {
  const VoipCallScreen({super.key});
  @override
  State<VoipCallScreen> createState() => _VoipCallScreenState();
}

class _VoipCallScreenState extends State<VoipCallScreen>
    with TickerProviderStateMixin {

  late WebRtcService _svc;
  String _peerName    = '';
  String _listingName = '';
  bool   _isCaller    = true;
  bool   _argsLoaded  = false;

  CallState _callState = CallState.connecting;
  Duration  _duration  = Duration.zero;
  bool      _muted     = false;
  bool      _speaker   = false;
  String?   _errorMsg;
  bool      _accepted  = false;   // callee tapped Accept

  // ── Animations ────────────────────────────────────────────────────────────
  late AnimationController _ringCtrl;     // ripple rings
  late AnimationController _fadeCtrl;     // state fade
  late AnimationController _connectedCtrl;// bounce in when connected

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

    _ringCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400))
      ..forward();
    _connectedCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsLoaded) return;
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    if (args == null) return;
    _argsLoaded  = true;
    final roomId = args['roomId']      as String? ?? '';
    final userId = args['userId']      as String? ?? '';
    _peerName    = args['peerName']    as String? ?? 'User';
    _listingName = args['listingName'] as String? ?? '';
    _isCaller    = args['isCaller']    as bool?   ?? true;

    _svc = WebRtcService(
      roomId: roomId, isCaller: _isCaller, userId: userId,
    );

    _svc.onStateChange = (s) {
      if (!mounted) return;
      setState(() => _callState = s);
      if (s == CallState.connected) {
        HapticFeedback.mediumImpact();
        _ringCtrl.stop();
        _connectedCtrl.forward(from: 0);
      }
      if (s == CallState.ended || s == CallState.failed) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
      }
    };
    _svc.onDurationTick = (d) {
      if (mounted) setState(() => _duration = d);
    };
    _svc.onError = (msg) {
      if (mounted) setState(() => _errorMsg = msg);
    };

    // Caller starts immediately; callee waits for Accept tap
    if (_isCaller) _svc.start();
  }

  @override
  void dispose() {
    _ringCtrl.dispose();
    _fadeCtrl.dispose();
    _connectedCtrl.dispose();
    _svc.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String get _durationLabel {
    final m = _duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get _initials => _peerName.trim().split(' ')
      .map((w) => w.isEmpty ? '' : w[0].toUpperCase()).take(2).join();

  Color get _stateColor {
    switch (_callState) {
      case CallState.connected: return BrokaColors.neonGreen;
      case CallState.failed:    return Colors.redAccent;
      case CallState.ended:     return BrokaColors.textLow;
      case CallState.ringing:   return BrokaColors.neonBlue;
      default:                  return BrokaColors.neonPurple;
    }
  }

  String get _stateLabel {
    if (_callState == CallState.connected) return _durationLabel;
    if (_callState == CallState.ringing && !_isCaller) return 'Incoming call';
    switch (_callState) {
      case CallState.connecting: return 'Connecting…';
      case CallState.calling:    return 'Calling…';
      case CallState.ended:      return 'Call ended';
      case CallState.failed:     return _errorMsg ?? 'Call failed';
      default:                   return '';
    }
  }

  bool get _isRinging => _callState == CallState.calling ||
      _callState == CallState.ringing ||
      _callState == CallState.connecting;

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 600),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _stateColor.withOpacity(0.10),
              BrokaColors.bg,
              BrokaColors.bg,
              BrokaColors.bg,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(children: [
            _buildTopBar(),
            const Spacer(flex: 2),
            _buildRippleAvatar(),
            const SizedBox(height: 22),
            _buildPeerInfo(),
            const SizedBox(height: 20),
            _buildStateRow(),
            const Spacer(flex: 3),
            _buildControls(),
            const SizedBox(height: 48),
          ]),
        ),
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Row(children: [
      // Secure badge
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: BrokaColors.border),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_outline_rounded,
              size: 10, color: BrokaColors.neonGreen),
          SizedBox(width: 5),
          Text('END-TO-END ENCRYPTED',
              style: TextStyle(color: BrokaColors.neonGreen,
                  fontSize: 8, fontWeight: FontWeight.w800,
                  letterSpacing: 1.1)),
        ]),
      ),
      const Spacer(),
      // Live / quality badge
      if (_callState == CallState.connected)
        _QualityBadge(duration: _duration),
    ]),
  );

  // ── Ripple avatar ─────────────────────────────────────────────────────────

  Widget _buildRippleAvatar() {
    return AnimatedBuilder(
      animation: Listenable.merge([_ringCtrl, _connectedCtrl]),
      builder: (_, __) {
        return SizedBox(
          width: 180, height: 180,
          child: Stack(alignment: Alignment.center, children: [
            // 3 expanding ripple rings (only while not connected)
            if (_isRinging) ...[
              for (int i = 0; i < 3; i++)
                _RippleRing(
                  progress: (_ringCtrl.value + i / 3) % 1.0,
                  color: _stateColor,
                  maxRadius: 88,
                ),
            ],
            // Static outer ring (connected state)
            if (_callState == CallState.connected)
              Container(
                width: 150, height: 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: BrokaColors.neonGreen.withOpacity(0.2), width: 2),
                ),
              ),
            // Avatar bounce-in on connect
            ScaleTransition(
              scale: CurvedAnimation(
                parent: _callState == CallState.connected
                    ? _connectedCtrl : kAlwaysCompleteAnimation,
                curve: Curves.elasticOut,
              ),
              child: Container(
                width: 100, height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      _stateColor.withOpacity(0.35),
                      _stateColor.withOpacity(0.12),
                    ],
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                  ),
                  border: Border.all(
                      color: _stateColor.withOpacity(0.7), width: 2),
                  boxShadow: [BoxShadow(
                      color: _stateColor.withOpacity(0.25),
                      blurRadius: 24, spreadRadius: 6)],
                ),
                child: Center(
                  child: _callState == CallState.failed
                      ? const Icon(Icons.call_end_rounded,
                          color: Colors.redAccent, size: 36)
                      : Text(_initials, style: TextStyle(
                          color: _stateColor,
                          fontSize: 32, fontWeight: FontWeight.w900)),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }

  // ── Peer info ─────────────────────────────────────────────────────────────

  Widget _buildPeerInfo() => Column(children: [
    Text(_peerName,
        style: const TextStyle(color: BrokaColors.textHigh,
            fontSize: 26, fontWeight: FontWeight.w800)),
    if (_listingName.isNotEmpty) ...[
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Text(_listingName,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 11),
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ],
  ]);

  // ── State label row ───────────────────────────────────────────────────────

  Widget _buildStateRow() {
    final isConnected = _callState == CallState.connected;
    return AnimatedDefaultTextStyle(
      duration: const Duration(milliseconds: 300),
      style: TextStyle(
        color: _callState == CallState.failed
            ? Colors.redAccent : _stateColor,
        fontSize:     isConnected ? 22 : 14,
        fontWeight:   isConnected ? FontWeight.w900 : FontWeight.w500,
        letterSpacing: isConnected ? 3.0 : 0.5,
        fontFamily:   'monospace',
      ),
      child: Text(_stateLabel, textAlign: TextAlign.center),
    );
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  Widget _buildControls() {
    if (_callState == CallState.ended || _callState == CallState.failed) {
      return _CallBtn(
        icon:  Icons.call_end_rounded,
        color: Colors.redAccent,
        label: _callState == CallState.ended ? 'Call Ended' : 'Call Failed',
        onTap: () => Navigator.pop(context),
        large: true,
      );
    }

    // Incoming call: full-screen style accept / decline
    if (!_isCaller && !_accepted &&
        (_callState == CallState.ringing ||
         _callState == CallState.connecting)) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(children: [
              _CallBtn(
                icon:  Icons.call_end_rounded,
                color: Colors.redAccent,
                label: 'Decline',
                onTap: () => _svc.hangup(),
                large: true,
              ),
            ]),
            // Accept - green with animated ring
            AnimatedBuilder(
              animation: _ringCtrl,
              builder: (_, child) => Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: (1.0 - _ringCtrl.value).clamp(0.0, 0.4),
                    child: Container(
                      width: 90 + _ringCtrl.value * 20,
                      height: 90 + _ringCtrl.value * 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: BrokaColors.neonGreen, width: 1.5),
                      ),
                    ),
                  ),
                  child!,
                ],
              ),
              child: _CallBtn(
                icon:  Icons.call_rounded,
                color: BrokaColors.neonGreen,
                label: 'Accept',
                onTap: () {
                  setState(() => _accepted = true);
                  _svc.start();
                },
                large: true,
              ),
            ),
          ],
        ),
      );
    }

    // In-call controls: mute · end · speaker
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _CallBtn(
          icon:     _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
          color:    _muted ? Colors.orange : BrokaColors.bgCard,
          label:    _muted ? 'Unmute' : 'Mute',
          onTap:    () { _svc.toggleMute(); setState(() => _muted = !_muted); },
          outlined: true,
          active:   _muted,
        ),
        const SizedBox(width: 24),
        _CallBtn(
          icon:  Icons.call_end_rounded,
          color: Colors.redAccent,
          label: 'End',
          onTap: () => _svc.hangup(),
          large: true,
        ),
        const SizedBox(width: 24),
        _CallBtn(
          icon:     _speaker ? Icons.volume_up_rounded : Icons.volume_down_rounded,
          color:    _speaker ? BrokaColors.neonBlue : BrokaColors.bgCard,
          label:    _speaker ? 'Speaker' : 'Earpiece',
          onTap:    () { _svc.toggleSpeaker(); setState(() => _speaker = !_speaker); },
          outlined: true,
          active:   _speaker,
        ),
      ],
    );
  }
}

// ── Ripple ring painter ────────────────────────────────────────────────────────

class _RippleRing extends StatelessWidget {
  final double progress;
  final Color  color;
  final double maxRadius;
  const _RippleRing({required this.progress, required this.color,
      required this.maxRadius});

  @override
  Widget build(BuildContext context) {
    final r = maxRadius * progress;
    final opacity = (1.0 - progress).clamp(0.0, 0.35);
    return Container(
      width: r * 2, height: r * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color.withOpacity(opacity), width: 1.5),
      ),
    );
  }
}

// ── Quality badge ──────────────────────────────────────────────────────────────

class _QualityBadge extends StatelessWidget {
  final Duration duration;
  const _QualityBadge({required this.duration});

  @override
  Widget build(BuildContext context) {
    // After 30s connected we show "Good"; under 5s show "Connecting"
    final label  = duration.inSeconds < 5  ? 'Connecting'
                 : duration.inSeconds < 30 ? 'Good'
                 : 'Excellent';
    final color  = duration.inSeconds < 5
        ? BrokaColors.neonPurple : BrokaColors.neonGreen;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        // 3 signal bars
        for (int i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 3,
            height: 6.0 + i * 3,
            decoration: BoxDecoration(
              color: color.withOpacity(duration.inSeconds > i * 5 ? 1.0 : 0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
        const SizedBox(width: 6),
        Text(label, style: TextStyle(
            color: color, fontSize: 9, fontWeight: FontWeight.w800,
            letterSpacing: 0.8)),
      ]),
    );
  }
}

// ── Call button ────────────────────────────────────────────────────────────────

class _CallBtn extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final String   label;
  final VoidCallback onTap;
  final bool     large;
  final bool     outlined;
  final bool     active;

  const _CallBtn({
    required this.icon, required this.color,
    required this.label, required this.onTap,
    this.large = false, this.outlined = false, this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = large ? 72.0 : 60.0;
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: size, height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: outlined
                ? (active ? color.withOpacity(0.15) : Colors.transparent)
                : color,
            border: outlined
                ? Border.all(
                    color: active ? color : BrokaColors.border,
                    width: active ? 2.0 : 1.5)
                : null,
            boxShadow: large
                ? [BoxShadow(color: color.withOpacity(0.40),
                    blurRadius: 24, spreadRadius: 4)]
                : null,
          ),
          child: Icon(icon,
              color: outlined
                  ? (active ? color : BrokaColors.textMid)
                  : Colors.white,
              size: large ? 30 : 24),
        ),
        const SizedBox(height: 8),
        Text(label,
            style: const TextStyle(
                color: BrokaColors.textLow, fontSize: 10)),
      ]),
    );
  }
}
