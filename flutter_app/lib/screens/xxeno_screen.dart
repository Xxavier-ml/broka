// BROKA — Xxeno AI Assistant
// Powered by Gemini 2.0 Flash. Supports English, Kiswahili, Dholuo, Kikuyu, Luganda, Sheng.
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../main.dart';
import '../services/api_service.dart';
import '../models/models.dart';

// ── Language definitions (mirroring backend) ──────────────────────────────────
class _Lang {
  final String key;
  final String name;
  final String flag;
  final String ttsLocale;
  const _Lang(this.key, this.name, this.flag, this.ttsLocale);
}

const _languages = [
  _Lang('english', 'English',   '🇬🇧', 'en-KE'),
  _Lang('swahili', 'Kiswahili', '🇰🇪', 'sw-KE'),
  _Lang('luo',     'Dholuo',    '🟡',  'en-KE'), // No native Luo TTS — fallback to en-KE
  _Lang('kikuyu',  'Kikuyu',    '🟤',  'en-KE'), // fallback
  _Lang('luganda', 'Luganda',   '🇺🇬', 'en-UG'), // fallback
  _Lang('sheng',   'Sheng',     '🔥',  'en-KE'),
];

_Lang _langByKey(String key) =>
    _languages.firstWhere((l) => l.key == key, orElse: () => _languages[0]);

class XxenoScreen extends StatefulWidget {
  const XxenoScreen({super.key});
  @override
  State<XxenoScreen> createState() => _XxenoScreenState();
}

class _XxenoScreenState extends State<XxenoScreen>
    with SingleTickerProviderStateMixin {
  final _msgCtrl    = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _typing      = false;
  List<Message> _messages = [];
  List<Map<String, String>> _history = [];

  // Language
  String get _langKey => ApiService.currentUserLanguage;

  // TTS
  final FlutterTts _tts = FlutterTts();
  bool _ttsEnabled = true;
  bool _speaking   = false;

  // STT
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _sttAvailable = false;
  bool _listening    = false;

  late AnimationController _pulseCtrl;

  String get _firstName {
    final n = ApiService.currentUserName;
    return n != null && n.isNotEmpty ? n.split(' ').first : '';
  }

  final _suggestions = const [
    ('🚗', 'Is KES 800K fair for a Toyota Axio 2012?'),
    ('📊', 'What\'s the market like for phones right now?'),
    ('🔍', 'How do I spot a fake listing?'),
    ('🤝', 'Tips to close a deal faster'),
    ('🏠', 'How does BROKA escrow work?'),
    ('📍', 'Why does location matter in a deal?'),
  ];

  @override
  void initState() {
    super.initState();
    _initTts();
    _initStt();
    _addWelcome();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
  }

  Future<void> _initTts() async {
    try {
      final engines = await _tts.getEngines;
      if (engines == null || (engines as List).isEmpty) return;
      final locale = _langByKey(_langKey).ttsLocale;
      await _tts.setLanguage(locale);
      await _tts.setSpeechRate(0.45);
      await _tts.setVolume(1.0);
      await _tts.setPitch(0.95);
      await _tts.awaitSpeakCompletion(true);
      _tts.setStartHandler(() { if (mounted) setState(() => _speaking = true); });
      _tts.setCompletionHandler(() { if (mounted) setState(() => _speaking = false); });
      _tts.setCancelHandler(() { if (mounted) setState(() => _speaking = false); });
      _tts.setErrorHandler((_) { if (mounted) setState(() => _speaking = false); });
    } catch (_) {}
  }

  Future<void> _initStt() async {
    _sttAvailable = await _speech.initialize();
    if (mounted) setState(() {});
  }

  void _addWelcome() {
    final greet = _firstName.isNotEmpty
        ? 'Habari $_firstName! Mimi ni Xxeno, msaidizi wako wa BROKA. '
          'Niulize chochote kuhusu bei za soko, ushauri wa biashara, au jukwaa. '
          'Nitakusaidia kwa lugha unayopenda!'
        : 'Habari! Mimi ni Xxeno, msaidizi wako wa BROKA. '
          'Niulize chochote. Ninasaidia kwa English, Kiswahili, Dholuo, Kikuyu, Luganda na Sheng!';
    setState(() => _messages = [Message(role: 'broker', content: greet)]);
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (_ttsEnabled && mounted) _speak(greet);
    });
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    _tts.stop();
    _speech.stop();
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _speak(String text) async {
    if (!_ttsEnabled) return;
    try {
      // Update TTS locale to match current language
      await _tts.setLanguage(_langByKey(_langKey).ttsLocale);
      String clean = text
          .replaceAll('**', '').replaceAll('*', '').replaceAll('#', '')
          .replaceAll(RegExp(r'[\u{1F600}-\u{1F64F}]', unicode: true), '')
          .replaceAll(RegExp(r'[\u{1F300}-\u{1FFFF}]', unicode: true), '')
          .replaceAll(RegExp(r'[\u{2600}-\u{27BF}]', unicode: true), '')
          .trim();
      if (clean.isEmpty) return;
      await _tts.stop();
      await _tts.speak(clean);
    } catch (_) {}
  }

  Future<void> _switchLanguage(String key) async {
    await ApiService.setLanguage(key);
    if (mounted) setState(() {});
    // Clear chat and restart with a welcome in the new language
    final lang = _langByKey(key);
    final msg = 'Language switched to ${lang.flag} ${lang.name}! '
        'I\'ll now respond in ${lang.name}. How can I help?';
    setState(() {
      _messages = [Message(role: 'broker', content: msg)];
      _history  = [];
    });
    if (_ttsEnabled) _speak(msg);
  }

  Future<void> _toggleListen() async {
    if (!_sttAvailable) return;
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
    } else {
      setState(() => _listening = true);
      final locale = _langByKey(_langKey).ttsLocale;
      await _speech.listen(
        onResult: (r) {
          if (mounted) setState(() => _msgCtrl.text = r.recognizedWords);
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 4),
        localeId: locale,
        onSoundLevelChange: null,
      );
    }
  }

  Future<void> _send([String? quick]) async {
    final text = (quick ?? _msgCtrl.text).trim();
    if (text.isEmpty) return;
    if (_listening) { await _speech.stop(); setState(() => _listening = false); }

    setState(() {
      _messages.add(Message(role: 'user', content: text));
      _typing = true;
    });
    if (quick == null) _msgCtrl.clear();
    _scrollDown();

    try {
      final response = await ApiService.xxenoChat(
        content:  text,
        history:  List.from(_history),
        userName: ApiService.currentUserName,
        language: _langKey,
      );
      _history.add({'role': 'user',      'content': text});
      _history.add({'role': 'assistant', 'content': response.content});

      if (mounted) {
        setState(() { _typing = false; _messages.add(response); });
        _scrollDown();
        if (_ttsEnabled) _speak(response.content);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _typing = false;
          _messages.add(const Message(role: 'broker',
              content: 'Connection issue. Please check your network.'));
        });
      }
    }
  }

  void _scrollDown() => Future.delayed(const Duration(milliseconds: 120), () {
    if (_scrollCtrl.hasClients) _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  });

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BrokaColors.bg,
    body: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF050112), Color(0xFF0A0520), Color(0xFF0D0728)],
          begin: Alignment.topCenter, end: Alignment.bottomCenter)),
      child: SafeArea(child: Column(children: [
        _buildHeader(),
        _buildLanguageBar(),
        Expanded(child: _buildChat()),
        if (_messages.length <= 1) _buildSuggestions(),
        _buildInputBar(),
      ])),
    ),
  );

  Widget _buildHeader() => Container(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
    decoration: const BoxDecoration(
      color: Color(0xFF06010F),
      border: Border(bottom: BorderSide(color: Color(0xFF1A0A3A))),
    ),
    child: Row(children: [
      GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(width: 36, height: 36,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
              color: BrokaColors.bgCard, border: Border.all(color: BrokaColors.border)),
          child: const Icon(Icons.arrow_back_ios_new_rounded,
              color: BrokaColors.textMid, size: 16))),
      const SizedBox(width: 12),
      AnimatedBuilder(animation: _pulseCtrl, builder: (_, __) =>
        Container(width: 42, height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [Color(0xFF6A0DAD), Color(0xFF00B4D8)],
              begin: Alignment.topLeft, end: Alignment.bottomRight),
            boxShadow: [BoxShadow(
              color: const Color(0xFF6A0DAD)
                  .withOpacity(0.3 + _pulseCtrl.value * 0.4),
              blurRadius: 8 + _pulseCtrl.value * 8)]),
          child: const Center(child: Text('X',
              style: TextStyle(color: Colors.white,
                  fontWeight: FontWeight.w900, fontSize: 20))))),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('XXENO', style: TextStyle(
            color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: 2)),
        Text(_firstName.isNotEmpty ? 'Ready to help, $_firstName' : 'Platform Intelligence',
            style: const TextStyle(color: Color(0xFF00B4D8), fontSize: 10)),
      ])),
      GestureDetector(
        onTap: () => Navigator.pushReplacementNamed(context, '/assistant'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: BrokaColors.border)),
          child: const Text('BROKER', style: TextStyle(
              color: BrokaColors.textMid, fontSize: 9,
              fontWeight: FontWeight.w800, letterSpacing: 1)))),
      // TTS toggle
      GestureDetector(
        onTap: () { setState(() => _ttsEnabled = !_ttsEnabled); if (!_ttsEnabled) _tts.stop(); },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _ttsEnabled ? const Color(0xFF6A0DAD).withOpacity(0.2) : BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _ttsEnabled
                ? const Color(0xFF6A0DAD) : BrokaColors.border)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_speaking ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                size: 14,
                color: _ttsEnabled ? const Color(0xFF6A0DAD) : BrokaColors.textLow),
            const SizedBox(width: 3),
            Text(_ttsEnabled ? 'ON' : 'OFF', style: TextStyle(
                fontSize: 9, fontWeight: FontWeight.w700,
                color: _ttsEnabled ? const Color(0xFF6A0DAD) : BrokaColors.textLow)),
          ]))),
    ]),
  );

  /// Horizontal scrollable language selector bar
  Widget _buildLanguageBar() => Container(
    height: 42,
    color: const Color(0xFF08011A),
    child: ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      itemCount: _languages.length,
      itemBuilder: (_, i) {
        final lang = _languages[i];
        final isActive = lang.key == _langKey;
        return GestureDetector(
          onTap: () => _switchLanguage(lang.key),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isActive
                  ? const Color(0xFF6A0DAD).withOpacity(0.25)
                  : BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isActive
                    ? const Color(0xFF6A0DAD)
                    : BrokaColors.border,
                width: isActive ? 1.5 : 1,
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(lang.flag, style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 5),
              Text(lang.name, style: TextStyle(
                  fontSize: 11,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                  color: isActive ? Colors.white : BrokaColors.textMid)),
            ]),
          ),
        );
      },
    ),
  );

  Widget _buildChat() => ListView.builder(
    controller: _scrollCtrl,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    itemCount: _messages.length + (_typing ? 1 : 0),
    itemBuilder: (_, i) {
      if (_typing && i == _messages.length) return _typingBubble();
      final msg = _messages[i];
      final isUser = msg.role == 'user';
      return Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 14),
          constraints: const BoxConstraints(maxWidth: 295),
          child: Column(
            crossAxisAlignment: isUser
                ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Text(
                isUser
                    ? (_firstName.isNotEmpty ? _firstName.toUpperCase() : 'YOU')
                    : 'XXENO',
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: isUser ? BrokaColors.success : const Color(0xFF00B4D8))),
              const SizedBox(height: 5),
              Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  gradient: isUser ? null : const LinearGradient(
                    colors: [Color(0xFF1A0040), Color(0xFF050112)],
                    begin: Alignment.topLeft, end: Alignment.bottomRight),
                  color: isUser ? BrokaColors.bgCard : null,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(14),
                    topRight: const Radius.circular(14),
                    bottomLeft: Radius.circular(isUser ? 14 : 4),
                    bottomRight: Radius.circular(isUser ? 4 : 14)),
                  border: Border.all(color: isUser
                      ? BrokaColors.success.withOpacity(0.3)
                      : const Color(0xFF6A0DAD).withOpacity(0.4)),
                  boxShadow: isUser ? null : [BoxShadow(
                    color: const Color(0xFF6A0DAD).withOpacity(0.15),
                    blurRadius: 12)]),
                child: Text(msg.content, style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 13, height: 1.5))),
            ]),
        ),
      );
    },
  );

  Widget _typingBubble() => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF1A0040), Color(0xFF050112)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF6A0DAD).withOpacity(0.4)),
        boxShadow: [BoxShadow(
            color: const Color(0xFF6A0DAD).withOpacity(0.15), blurRadius: 12)]),
      child: Row(mainAxisSize: MainAxisSize.min, children: const [
        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(
            strokeWidth: 1.5, color: Color(0xFF00B4D8))),
        SizedBox(width: 10),
        Text('Xxeno is thinking...', style: TextStyle(
            color: Color(0xFF00B4D8), fontSize: 12, fontStyle: FontStyle.italic)),
      ]),
    ),
  );

  Widget _buildSuggestions() => SizedBox(
    height: 44,
    child: ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _suggestions.length,
      itemBuilder: (_, i) {
        final (emoji, label) = _suggestions[i];
        return GestureDetector(
          onTap: () => _send(label),
          child: Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0D0030),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFF6A0DAD).withOpacity(0.4))),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(emoji, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 11)),
            ])));
      }),
  );

  Widget _buildInputBar() => SafeArea(top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: const BoxDecoration(
        color: Color(0xFF06010F),
        border: Border(top: BorderSide(color: Color(0xFF1A0A3A)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (_sttAvailable)
          GestureDetector(
            onTap: _toggleListen,
            child: Container(
              width: 42, height: 42, margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: _listening
                    ? BrokaColors.danger.withOpacity(0.2) : BrokaColors.bgCard,
                border: Border.all(
                    color: _listening ? BrokaColors.danger : BrokaColors.border)),
              child: Icon(_listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                  size: 20,
                  color: _listening ? BrokaColors.danger : BrokaColors.textMid))),
        Expanded(child: TextField(
          controller: _msgCtrl,
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13),
          maxLines: 6, minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: _listening ? 'Listening...'
                : _firstName.isNotEmpty
                    ? 'Ask Xxeno in ${_langByKey(_langKey).name}, $_firstName...'
                    : 'Ask Xxeno anything...',
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
          textInputAction: TextInputAction.newline)),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => _send(),
          child: Container(
            width: 46, height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                  colors: [Color(0xFF6A0DAD), Color(0xFF00B4D8)]),
              boxShadow: [BoxShadow(
                  color: const Color(0xFF6A0DAD).withOpacity(0.4), blurRadius: 12)]),
            child: const Icon(Icons.send_rounded, size: 18, color: Colors.white))),
      ])));
}
