// BROKA - Ringtone Service
//
// Plays a short, original looping ringtone while an incoming audio/video
// call is awaiting an answer. Centralised here (rather than duplicated in
// negotiation_screen.dart's incoming-call dialog AND voip_call_screen.dart's
// own ringing state) so there is exactly one place that can ever be playing
// the tone, and exactly one safety-timeout implementation - no risk of two
// overlapping copies of the sound, and no risk of it ringing forever.
//
// The tone itself (assets/audio/ringtone.mp3) is a synthesised two-tone
// chime generated from scratch for BROKA - not a sampled/copyrighted sound.

import 'dart:async';
import 'package:audioplayers/audioplayers.dart';

class RingtoneService {
  RingtoneService._();
  static final RingtoneService instance = RingtoneService._();

  final AudioPlayer _player = AudioPlayer(playerId: 'broka_ringtone');
  bool _playing = false;
  bool _contextConfigured = false;
  Timer? _autoStopTimer;

  Future<void> _ensureAudioContext() async {
    if (_contextConfigured) return;
    _contextConfigured = true;
    try {
      // Route through the RINGTONE audio usage on Android so the tone
      // respects the phone's ringer volume/silent/vibrate state the way a
      // real incoming call should, rather than playing at media volume.
      await _player.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: true,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notificationRingtone,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: {AVAudioSessionOptions.mixWithOthers},
        ),
      ));
    } catch (_) {
      // Non-fatal - ringtone still plays fine through the default context.
    }
  }

  /// Starts looping the ringtone. Safe to call repeatedly - calling it
  /// again while already ringing just refreshes the auto-stop timer.
  ///
  /// [autoStopAfter] guarantees the tone can never ring forever - e.g. if
  /// the caller cancels before this device's next poll notices. Once it
  /// elapses, [onTimeout] fires so the screen can dismiss its own
  /// incoming-call UI in step with the sound stopping.
  Future<void> play({Duration? autoStopAfter, void Function()? onTimeout}) async {
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
    if (autoStopAfter != null) {
      _autoStopTimer = Timer(autoStopAfter, () {
        stop();
        onTimeout?.call();
      });
    }
    if (_playing) return;
    _playing = true;
    await _ensureAudioContext();
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource('audio/ringtone.mp3'));
    } catch (_) {
      _playing = false;
    }
  }

  Future<void> stop() async {
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
    if (!_playing) return;
    _playing = false;
    try {
      await _player.stop();
    } catch (_) {}
  }

  bool get isPlaying => _playing;
}
