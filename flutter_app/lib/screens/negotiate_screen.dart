// BROKA — Negotiation Room
// Persistent chat history stored per listing_id.
// AI Broker knows both buyer and seller by name.
// TTS reads broker responses aloud.
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../main.dart';
import '../services/api_service.dart';
import '../models/models.dart';
import '../models/listing.dart';

class NegotiateScreen extends StatefulWidget {
  const NegotiateScreen({super.key});
  @override
  State<NegotiateScreen> createState() => _NegotiateScreenState();
}

class _NegotiateScreenState extends State<NegotiateScreen> {
  final _msgCtrl    = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _typing      = false;
  bool _initialized = false;
  List<Message> _messages = [];
  Listing? _listing;
  String _role = 'buyer';
  double? _currentOffer;
  Map<String, dynamic>? _sellerInfo;

  // TTS
  final FlutterTts _tts = FlutterTts();
  bool _ttsEnabled = true;
  bool _speaking   = false;

  // STT
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _sttAvailable = false;
  bool _listening    = false;

  String get _myName     => ApiService.currentUserName ?? 'You';
  String get _myFirst    => _myName.split(' ').first;
  String get _counterName =>
      (_sellerInfo?['name'] as String?) ?? _listing?.sellerName ?? 'Seller';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        final listingArg = args['listing'];
        if (listingArg is Listing) {
          _listing = listingArg;
        } else if (listingArg is Map<String, dynamic>) {
          _listing = Listing.fromJson(listingArg);
        } else if (listingArg is Map) {
          // Convert Map<String, Object> to Map<String, dynamic>
          _listing = Listing.fromJson(Map<String, dynamic>.from(listingArg));
        }
        _role = (args['role'] as String?) ?? 'buyer';
      } else if (args is Listing) {
        _listing = args;
      }
      _initTts();
      _initStt();
      _loadHistory();
      _loadCounterparty();
    }
  }

  Future<void> _initTts() async {
    try {
      // Check TTS is available before configuring
      final engines = await _tts.getEngines;
      if (engines == null || (engines as List).isEmpty) return;
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.45);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      // Award silence between sentences for natural pacing
      await _tts.awaitSpeakCompletion(true);
      _tts.setStartHandler(() { if (mounted) setState(() => _speaking = true); });
      _tts.setCompletionHandler(() { if (mounted) setState(() => _speaking = false); });
      _tts.setCancelHandler(() { if (mounted) setState(() => _speaking = false); });
      _tts.setErrorHandler((msg) { if (mounted) setState(() => _speaking = false); });
    } catch (e) {
      // TTS init failed silently — app still works without voice
    }
  }

  Future<void> _initStt() async {
    _sttAvailable = await _speech.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _loadCounterparty() async {
    final sid = _listing?.sellerId;
    if (sid == null || sid == ApiService.currentUserId) return;
    try {
      final info = await ApiService.getUserProfile(sid);
      if (mounted) setState(() => _sellerInfo = info);
    } catch (_) {}
  }

  Future<void> _loadHistory() async {
    if (_listing == null) { _addGreeting(); return; }
    try {
      final history = await ApiService.getNegotiationHistory(_listing!.id);
      if (mounted) {
        if (history.isEmpty) {
          _addGreeting();
        } else {
          setState(() => _messages = history);
          _scrollDown();
        }
      }
    } catch (_) { _addGreeting(); }
  }

  void _addGreeting() {
    final name = _listing?.name ?? 'this item';
    final price = _listing?.formattedPrice ?? '';
    final greeting = _role == 'seller'
        ? 'Welcome back, $_myFirst! 👋\n\nYou\'re in the negotiation room for **$name** ($price). '
          'I\'ll notify you when a buyer reaches out. Ready when you are.'
        : 'Hi $_myFirst! 👋\n\nYou\'re negotiating for **$name** ($price). '
          'I\'m your AI Broker — I know both you and the seller. '
          'I\'ll help reach a fair deal for everyone. What\'s your opening move?';
    setState(() => _messages = [Message(role: 'broker', content: greeting)]);
    if (_ttsEnabled) _speak(greeting);
  }

  @override
  void dispose() {
    _msgCtrl.dispose(); _scrollCtrl.dispose();
    _tts.stop(); _speech.stop();
    super.dispose();
  }

  Future<void> _speak(String text) async {
    if (!_ttsEnabled) return;
    try {
      // Strip markdown, emoji and special chars that confuse TTS engines
      String clean = text
          .replaceAll('**', '')
          .replaceAll('*', '')
          .replaceAll('#', '')
          .replaceAll(RegExp(r'[\u{1F600}-\u{1F64F}]', unicode: true), '')
          .replaceAll(RegExp(r'[\u{1F300}-\u{1FFFF}]', unicode: true), '')
          .replaceAll(RegExp(r'[\u{2600}-\u{27BF}]', unicode: true), '')
          .replaceAll(RegExp(r'[^\x00-\x7F\u00C0-\u024F]'), '')
          .trim();
      if (clean.isEmpty) return;
      await _tts.stop();
      await _tts.speak(clean);
    } catch (e) {
      // Speak failed silently
    }
  }

  Future<void> _toggleListen() async {
    if (!_sttAvailable) return;
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
    } else {
      setState(() => _listening = true);
      await _speech.listen(
        onResult: (r) {
          if (mounted) setState(() => _msgCtrl.text = r.recognizedWords);
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 4),
        onSoundLevelChange: null,
      );
    }
  }

  Future<void> _send([String? quickText]) async {
    final text = (quickText ?? _msgCtrl.text).trim();
    if (text.isEmpty) return;
    if (_listening) { await _speech.stop(); setState(() => _listening = false); }
    setState(() {
      _messages.add(Message(role: _role, content: text));
      _typing = true;
    });
    if (quickText == null) _msgCtrl.clear();
    _scrollDown();

    try {
      Message reply;
      if (_listing != null) {
        reply = await ApiService.sendNegotiationMessage(
          listingId:  _listing!.id,
          senderRole: _role,
          senderId:   ApiService.currentUserId ?? '',
          content:    text,
          buyerName:  _role == 'buyer' ? _myName : null,
          sellerName: _role == 'seller' ? _myName : _listing!.sellerName,
          buyerLat:   _role == 'buyer' ? ApiService.currentUserLat : null,
          buyerLng:   _role == 'buyer' ? ApiService.currentUserLng : null,
          sellerLat:  _listing!.sellerLat,
          sellerLng:  _listing!.sellerLng,
        );
      } else {
        reply = await ApiService.freeChat(
          content:  text,
          history:  _messages.map((m) => {'role': m.isBroker ? 'assistant' : 'user', 'content': m.content}).toList(),
          userName: _myName,
        );
      }
      if (mounted) {
        setState(() { _typing = false; _messages.add(reply); });
        _scrollDown();
        if (_ttsEnabled) _speak(reply.content);
      }
    } catch (_) {
      if (mounted) setState(() {
        _typing = false;
        _messages.add(const Message(role: 'broker',
            content: 'Connection issue. Please try again.'));
      });
    }
  }

  void _scrollDown() => Future.delayed(const Duration(milliseconds: 120), () {
    if (_scrollCtrl.hasClients) _scrollCtrl.animateTo(
      _scrollCtrl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  });

  void _showOfferDialog() {
    final ctrl = TextEditingController(
        text: _listing?.price.toStringAsFixed(0) ?? '');
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: BrokaColors.bgCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Make an Offer',
          style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
      content: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        style: const TextStyle(color: BrokaColors.textHigh),
        decoration: const InputDecoration(
            prefixText: 'KES ',
            prefixStyle: TextStyle(color: BrokaColors.neonPurple),
            hintText: 'Enter your offer'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: BrokaColors.textMid))),
        TextButton(
          onPressed: () {
            final val = double.tryParse(ctrl.text.replaceAll(',', ''));
            if (val != null) {
              Navigator.pop(ctx);
              setState(() => _currentOffer = val);
              _send('I am offering KES ${val.toStringAsFixed(0).replaceAllMapped(
                RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')} for this item.');
            }
          },
          child: const Text('Submit',
              style: TextStyle(color: BrokaColors.neonPurple, fontWeight: FontWeight.w800)),
        ),
      ],
    ));
  }

  double? get _distKm {
    final d = _sellerInfo?['distance_km'];
    return d != null ? (d as num).toDouble() : null;
  }
  String? get _sellerLoc => _sellerInfo?['location_name'] as String?;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BrokaColors.bg,
    resizeToAvoidBottomInset: true,
    body: Container(
      decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0F0830), Color(0xFF03000A)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter)),
      child: SafeArea(child: Column(children: [
        _buildHeader(),
        if (_listing != null) _buildDealStrip(),
        _buildCounterpartyStrip(),
        Expanded(child: _buildChat()),
        _buildActionBar(),
        _buildInputBar(),
      ])),
    ),
  );

  Widget _buildHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
    child: Row(children: [
      GestureDetector(onTap: () => Navigator.pop(context),
        child: Container(width: 36, height: 36,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
              color: BrokaColors.bgCard, border: Border.all(color: BrokaColors.border)),
          child: const Icon(Icons.arrow_back_ios_new_rounded,
              color: BrokaColors.textMid, size: 16))),
      const SizedBox(width: 12),
      Container(width: 36, height: 36,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
          gradient: const LinearGradient(
              colors: [Color(0xFFFF4D6D), Color(0xFFFF8C42)]),
          boxShadow: const [BoxShadow(color: Color(0x55FF4D6D), blurRadius: 12)]),
        child: const Icon(Icons.handshake_outlined, color: Colors.white, size: 18)),
      const SizedBox(width: 10),
      const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('NEGOTIATION ROOM', style: TextStyle(
            color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w800)),
        Text('AI-MEDIATED · ESCROW PROTECTED', style: TextStyle(
            color: BrokaColors.success, fontSize: 9,
            letterSpacing: 1.4, fontWeight: FontWeight.w600)),
      ])),
      // TTS toggle
      GestureDetector(
        onTap: () { setState(() => _ttsEnabled = !_ttsEnabled); if (!_ttsEnabled) _tts.stop(); },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _ttsEnabled
                ? BrokaColors.neonPurple.withOpacity(0.15)
                : BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _ttsEnabled
                ? BrokaColors.neonPurple.withOpacity(0.5) : BrokaColors.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_speaking ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                size: 14, color: _ttsEnabled ? BrokaColors.neonPurple : BrokaColors.textLow),
            const SizedBox(width: 3),
            Text(_ttsEnabled ? 'ON' : 'OFF', style: TextStyle(
                fontSize: 9, fontWeight: FontWeight.w700,
                color: _ttsEnabled ? BrokaColors.neonPurple : BrokaColors.textLow)),
          ]),
        ),
      ),
    ]),
  );

  Widget _buildDealStrip() => Container(
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: [Color(0xFF1A0F3D), Color(0xFF0D0728)]),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Row(children: [
      Text(_listing!.emoji, style: const TextStyle(fontSize: 22)),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_listing!.name, style: const TextStyle(
            color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 13),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        Text('Asking: ${_listing!.formattedPrice}',
            style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
      ])),
      if (_currentOffer != null)
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          const Text('Your offer', style: TextStyle(color: BrokaColors.textLow, fontSize: 9)),
          ShaderMask(
            shaderCallback: (b) => const LinearGradient(
                colors: [BrokaColors.success, BrokaColors.neonBlue]).createShader(b),
            child: Text('KES ${_currentOffer!.toStringAsFixed(0).replaceAllMapped(
              RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}',
                style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.w800, fontSize: 13))),
        ]),
    ]),
  );

  Widget _buildCounterpartyStrip() {
    final cName  = _counterName;
    final cDist  = _distKm;
    final cLoc   = _sellerLoc;
    final rating = (_sellerInfo?['rating'] as num?)?.toStringAsFixed(1);
    final deals  = _sellerInfo?['completed_deals'] as int?;
    final ver    = _sellerInfo?['is_verified'] as bool? ?? false;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          BrokaColors.neonBlue.withOpacity(0.06),
          BrokaColors.neonPurple.withOpacity(0.04),
        ]),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.25)),
      ),
      child: Row(children: [
        Container(
          width: 36, height: 36,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
                colors: [BrokaColors.gradStart, BrokaColors.gradMid])),
          child: Center(child: Text(cName[0].toUpperCase(),
              style: const TextStyle(color: Colors.white,
                  fontWeight: FontWeight.w800, fontSize: 16))),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(cName, style: const TextStyle(color: BrokaColors.textHigh,
                fontWeight: FontWeight.w700, fontSize: 13)),
            if (ver) ...[const SizedBox(width: 4),
              const Icon(Icons.verified_rounded, color: BrokaColors.neonPurple, size: 13)],
          ]),
          if (rating != null)
            Row(children: [
              const Icon(Icons.star_rounded, size: 11, color: BrokaColors.gold),
              const SizedBox(width: 2),
              Text('$rating  · ${deals ?? 0} deals',
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
            ]),
        ])),
        if (cDist != null || cLoc != null)
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (cDist != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: BrokaColors.neonBlue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.3)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.near_me_rounded, size: 10, color: BrokaColors.neonBlue),
                  const SizedBox(width: 3),
                  Text('${cDist.toStringAsFixed(1)} km',
                      style: const TextStyle(color: BrokaColors.neonBlue,
                          fontSize: 11, fontWeight: FontWeight.w700)),
                ]),
              ),
            if (cLoc != null) ...[
              const SizedBox(height: 3),
              Text(cLoc, style: const TextStyle(color: BrokaColors.textLow, fontSize: 10)),
            ],
          ]),
      ]),
    );
  }

  Widget _buildChat() => ListView.builder(
    controller: _scrollCtrl,
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    itemCount: _messages.length + (_typing ? 1 : 0),
    itemBuilder: (_, i) {
      if (_typing && i == _messages.length) return _typingBubble();
      return _Bubble(msg: _messages[i], role: _role, myName: _myFirst);
    },
  );

  Widget _typingBubble() => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF2A1560), Color(0xFF150A35)]),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.3)),
        boxShadow: const [BrokaColors.glowPurple],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: const [
        SizedBox(width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: BrokaColors.neonPurple)),
        SizedBox(width: 10),
        Text('AI Broker composing...', style: TextStyle(
            color: BrokaColors.neonPurple, fontSize: 12, fontStyle: FontStyle.italic)),
      ]),
    ),
  );

  Widget _buildActionBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    child: Row(children: [
      _actionBtn(Icons.local_offer_outlined, 'Make Offer',
          BrokaColors.neonPurple, _showOfferDialog),
      const SizedBox(width: 8),
      _actionBtn(Icons.check_circle_outline, 'Accept',
          BrokaColors.success,
          () => _send('I accept this deal. How do we proceed with payment?')),
      const SizedBox(width: 8),
      _actionBtn(Icons.shield_outlined, 'Escrow',
          BrokaColors.neonBlue,
          () => _send('How does the escrow protection work for this deal?')),
    ]),
  );

  Widget _actionBtn(IconData icon, String lbl, Color color, VoidCallback onTap) =>
    Expanded(child: GestureDetector(onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(height: 3),
          Text(lbl, style: TextStyle(color: color, fontSize: 10,
              fontWeight: FontWeight.w700), textAlign: TextAlign.center),
        ]),
      ),
    ));

  Widget _buildInputBar() => Container(
    padding: EdgeInsets.fromLTRB(
      12, 10, 12,
      12 + MediaQuery.of(context).viewInsets.bottom * 0.0,
    ),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF0D0828), Color(0xFF07021A)],
        begin: Alignment.topCenter, end: Alignment.bottomCenter),
      border: Border(top: BorderSide(
          color: BrokaColors.neonPurple.withOpacity(0.2))),
      boxShadow: [BoxShadow(
          color: BrokaColors.neonPurple.withOpacity(0.06),
          blurRadius: 20, offset: const Offset(0, -4))],
    ),
    child: SafeArea(top: false,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (_sttAvailable)
          GestureDetector(
            onTap: _toggleListen,
            child: Container(
              width: 44, height: 44,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: _listening
                    ? BrokaColors.danger.withOpacity(0.15)
                    : BrokaColors.bgCard,
                border: Border.all(
                  color: _listening
                      ? BrokaColors.danger
                      : BrokaColors.border.withOpacity(0.7)),
              ),
              child: Icon(
                _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                size: 20,
                color: _listening ? BrokaColors.danger : BrokaColors.textMid),
            ),
          ),
        Expanded(child: Container(
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: BrokaColors.border),
          ),
          child: TextField(
            controller: _msgCtrl,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
            maxLines: 5, minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: _listening ? '⬤  Listening...' : 'Message...',
              hintStyle: TextStyle(color: BrokaColors.textLow.withOpacity(0.6)),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            ),
            textInputAction: TextInputAction.newline,
          ),
        )),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _send,
          child: Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(
                  colors: [BrokaColors.gradStart, BrokaColors.gradMid]),
              boxShadow: const [BrokaColors.glowPurple],
            ),
            child: const Icon(Icons.send_rounded, size: 19, color: Colors.white),
          ),
        ),
      ]),
    ),
  );
}

class _Bubble extends StatelessWidget {
  final Message msg; final String role; final String myName;
  const _Bubble({required this.msg, required this.role, required this.myName});

  @override
  Widget build(BuildContext context) {
    final isBroker = msg.isBroker;
    final isMe     = msg.role == role;
    final color = isBroker ? BrokaColors.neonPurple
        : isMe ? BrokaColors.success : BrokaColors.neonBlue;
    final label = isBroker ? '🤖 AI BROKER'
        : isMe ? myName.toUpperCase() : msg.role.toUpperCase();

    return Align(
      alignment: isBroker ? Alignment.centerLeft
          : isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        constraints: const BoxConstraints(maxWidth: 290),
        child: Column(
          crossAxisAlignment: isMe
              ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800,
                letterSpacing: 1.2, color: color)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: isBroker ? const LinearGradient(
                    colors: [Color(0xFF2A1560), Color(0xFF150A35)]) : null,
                color: isBroker ? null : BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color.withOpacity(0.3)),
                boxShadow: isBroker ? const [BrokaColors.glowPurple] : null,
              ),
              child: Text(msg.content, style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 13, height: 1.45)),
            ),
          ],
        ),
      ),
    );
  }
}
