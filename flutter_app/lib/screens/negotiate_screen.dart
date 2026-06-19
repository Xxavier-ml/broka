import 'dart:async';
import 'dart:convert';
// BROKA - Negotiation Room
// Persistent chat history stored per listing_id.
// AI Broker knows both buyer and seller by name.
// TTS reads broker responses aloud.
import 'package:flutter/material.dart';
import '../services/broka_tts.dart';
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
  int    _dealProbability = 50;
  Timer? _heartbeatTimer;

  // TTS
  final _tts = BrokaTts.instance;
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
      // Heartbeat to keep last_seen fresh
      ApiService.updateLastSeen();
      _heartbeatTimer = Timer.periodic(
          const Duration(seconds: 60), (_) => ApiService.updateLastSeen());
    }
  }

  Future<void> _initTts() async {
    await _tts.init();
    _tts.onStart = () { if (mounted) setState(() => _speaking = true);  };
    _tts.onDone  = () { if (mounted) setState(() => _speaking = false); };
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
          'I\'m your AI Broker - I know both you and the seller. '
          'I\'ll help reach a fair deal for everyone. What\'s your opening move?';
    setState(() => _messages = [Message(role: 'broker', content: greeting)]);
    if (_ttsEnabled) _speak(greeting);
  }

  @override
  void dispose() {
    _msgCtrl.dispose(); _scrollCtrl.dispose();
    _tts.stop(); _speech.stop();
    _heartbeatTimer?.cancel();
    super.dispose();
  }

  Future<void> _speak(String text) async {
    if (!_ttsEnabled) return;
    await _tts.speak(text, language: ApiService.currentUserLanguage);
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
          if (mounted) {
            setState(() {
              _msgCtrl.text = r.recognizedWords;
              _msgCtrl.selection = TextSelection.fromPosition(
                TextPosition(offset: _msgCtrl.text.length),
              );
            });
          }
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        cancelOnError: false,
        partialResults: true,
      );
    }
  }

  Future<void> _send([String? quickText]) async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      // Small delay to let the final speech result settle into the controller
      await Future.delayed(const Duration(milliseconds: 150));
    }
    final text = (quickText ?? _msgCtrl.text).trim();
    if (text.isEmpty) return;
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
        setState(() {
          _typing = false;
          _messages.add(reply);
          if (reply.dealProbability != null) _dealProbability = reply.dealProbability!;
        });
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

  bool get _counterIsOnline =>
      (_sellerInfo?['is_online'] as bool?) ?? false;

  String? get _counterLastSeenText {
    final ls = _sellerInfo?['last_seen'] as String?;
    if (ls == null) return null;
    try {
      final dt   = DateTime.parse(ls).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1)  return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours   < 24) return '${diff.inHours}h ago';
      return '${diff.inDays}d ago';
    } catch (_) { return null; }
  }

  double? get _distKm {
    final d = _sellerInfo?['distance_km'];
    return d != null ? (d as num).toDouble() : null;
  }
  String? get _sellerLoc   => _sellerInfo?['location_name'] as String?;
  String? get _sellerPhoto => _sellerInfo?['profile_photo']  as String?;
  String? get _myPhoto     => ApiService.currentUserPhoto;

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
        _buildStatusBar(),
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
    final cName    = _counterName;
    final cDist    = _distKm;
    final cLoc     = _sellerLoc;
    final cPhoto   = _sellerPhoto;
    final rating   = (_sellerInfo?['rating'] as num?)?.toStringAsFixed(1);
    final deals    = _sellerInfo?['completed_deals'] as int?;
    final ver      = _sellerInfo?['is_verified'] as bool? ?? false;
    final isOnline = _counterIsOnline;
    final lastSeen = _counterLastSeenText;
    final sellerId = _sellerInfo?['id'] as String? ?? _listing?.sellerId;

    return GestureDetector(
      // Tap strip to view the other party's full profile
      onTap: sellerId != null
          ? () => Navigator.pushNamed(context, '/user-profile',
              arguments: sellerId)
          : null,
      child: Container(
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
          // Avatar with online dot
          Stack(children: [
            Container(
              width: 40, height: 40,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                    colors: [BrokaColors.gradStart, BrokaColors.gradMid])),
              child: ClipOval(
                child: cPhoto != null && cPhoto.isNotEmpty
                    ? Image.memory(base64Decode(cPhoto), fit: BoxFit.cover)
                    : Center(child: Text(cName[0].toUpperCase(),
                        style: const TextStyle(color: Colors.white,
                            fontWeight: FontWeight.w800, fontSize: 16))),
              ),
            ),
            Positioned(bottom: 1, right: 1,
              child: Container(
                width: 11, height: 11,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOnline ? BrokaColors.neonGreen : BrokaColors.textLow,
                  border: Border.all(color: BrokaColors.bg, width: 1.5),
                ),
              ),
            ),
          ]),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(cName, style: const TextStyle(
                  color: BrokaColors.textHigh,
                  fontWeight: FontWeight.w700, fontSize: 13),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (ver) ...[const SizedBox(width: 4),
                const Icon(Icons.verified_rounded,
                    color: BrokaColors.neonPurple, size: 13)],
            ]),
            Text(
              isOnline ? 'Online now'
                  : lastSeen != null ? 'Last seen $lastSeen' : 'Offline',
              style: TextStyle(
                  fontSize: 10,
                  color: isOnline ? BrokaColors.neonGreen : BrokaColors.textLow,
                  fontWeight: FontWeight.w600),
            ),
            if (rating != null)
              Row(children: [
                const Icon(Icons.star_rounded, size: 10, color: BrokaColors.gold),
                const SizedBox(width: 2),
                Text('$rating  · ${deals ?? 0} deals',
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
              ]),
          ])),
          // Right side: distance + map button
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (cDist != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
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
                          fontSize: 10, fontWeight: FontWeight.w700)),
                ]),
              ),
            const SizedBox(height: 4),
            // Map button - available to both buyer and seller
            GestureDetector(
              onTap: () => Navigator.pushNamed(context, '/map',
                  arguments: _listing),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: BrokaColors.neonGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.3)),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.map_outlined, size: 10, color: BrokaColors.neonGreen),
                  SizedBox(width: 3),
                  Text('Map', style: TextStyle(color: BrokaColors.neonGreen,
                      fontSize: 10, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  // ── Deal probability + online bar ──────────────────────────────────────────
  Widget _buildStatusBar() {
    final isOnline = _counterIsOnline;
    final prob     = _dealProbability;
    final probColor = prob >= 70
        ? BrokaColors.neonGreen
        : prob >= 40 ? Colors.orangeAccent : BrokaColors.danger;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Row(children: [
        Container(width: 7, height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isOnline ? BrokaColors.neonGreen : BrokaColors.textLow,
            boxShadow: isOnline ? [BoxShadow(
                color: BrokaColors.neonGreen.withOpacity(0.7),
                blurRadius: 6)] : null,
          ),
        ),
        const SizedBox(width: 5),
        Text(isOnline ? 'Online' : 'Offline',
            style: TextStyle(
                color: isOnline ? BrokaColors.neonGreen : BrokaColors.textLow,
                fontSize: 10, fontWeight: FontWeight.w600)),
        const Spacer(),
        const Text('Deal probability: ',
            style: TextStyle(color: BrokaColors.textLow, fontSize: 10)),
        SizedBox(
          width: 70, height: 5,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: prob / 100,
              backgroundColor: BrokaColors.border,
              valueColor: AlwaysStoppedAnimation<Color>(probColor),
            ),
          ),
        ),
        const SizedBox(width: 5),
        Text('$prob%', style: TextStyle(
            color: probColor, fontSize: 10, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _buildChat() => ListView.builder(
    controller: _scrollCtrl,
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    itemCount: _messages.length + (_typing ? 1 : 0),
    itemBuilder: (_, i) {
      if (_typing && i == _messages.length) return _typingBubble();
      return _Bubble(
        msg:         _messages[i],
        role:        _role,
        myName:      _myFirst,
        myPhoto:     _myPhoto,
        counterPhoto: _sellerPhoto,
        counterName:  _counterName,
      );
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

  Future<void> _acceptDeal() async {
    final listing = _listing;
    if (listing == null) return;
    final agreedPrice = _currentOffer ?? listing.price;
    final buyerId     = ApiService.currentUserId ?? '';
    await _send('I accept this deal. How do we proceed with payment?');
    try {
      final deal = await ApiService.finalizeDeal(
        listingId:   listing.id,
        buyerId:     buyerId,
        agreedPrice: agreedPrice,
      );
      if (!mounted) return;
      Navigator.pushReplacementNamed(
        context, '/negotiate',
        arguments: {'listing': listing, 'role': 'buyer', 'deal': deal},
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not finalize deal: $e',
              style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.redAccent,
        ));
      }
    }
  }

  Widget _buildActionBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    child: Row(children: [
      _actionBtn(Icons.local_offer_outlined, 'Make Offer',
          BrokaColors.neonPurple, _showOfferDialog),
      const SizedBox(width: 8),
      _actionBtn(Icons.check_circle_outline, 'Accept',
          BrokaColors.success,
          _acceptDeal),
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
  final Message  msg;
  final String   role;
  final String   myName;
  final String?  myPhoto;
  final String?  counterPhoto;
  final String   counterName;
  const _Bubble({
    required this.msg,
    required this.role,
    required this.myName,
    this.myPhoto,
    this.counterPhoto,
    this.counterName = 'User',
  });

  @override
  Widget build(BuildContext context) {
    final isBroker = msg.isBroker;
    final isMe     = !isBroker && msg.role == role;
    final color    = isBroker ? BrokaColors.neonPurple
        : isMe ? BrokaColors.success : BrokaColors.neonBlue;

    // Instagram style: avatar on the LEFT of the message bubble for others
    if (isBroker) return _brokerBubble();

    final photo    = isMe ? myPhoto : counterPhoto;
    final initials = isMe
        ? (myName.isNotEmpty ? myName[0].toUpperCase() : 'M')
        : (counterName.isNotEmpty ? counterName[0].toUpperCase() : 'U');

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Avatar on the left for the other party
          if (!isMe) ...[
            _avatar(photo, initials, color),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(
                      left: isMe ? 0 : 4, right: isMe ? 4 : 0, bottom: 3),
                  child: Text(
                    isMe ? myName : counterName,
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: color, letterSpacing: 0.3),
                  ),
                ),
                Container(
                  constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.68),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isMe
                        ? (role == 'buyer'
                            ? const Color(0xFF0D47A1)
                            : const Color(0xFF1B5E20))
                        : BrokaColors.bgCard,
                    borderRadius: BorderRadius.only(
                      topLeft:     const Radius.circular(16),
                      topRight:    const Radius.circular(16),
                      bottomLeft:  Radius.circular(isMe ? 16 : 4),
                      bottomRight: Radius.circular(isMe ? 4 : 16),
                    ),
                    border: Border.all(color: color.withOpacity(0.2)),
                  ),
                  child: Text(msg.content, style: const TextStyle(
                      color: BrokaColors.textHigh, fontSize: 13, height: 1.45)),
                ),
              ],
            ),
          ),
          // Avatar on the right for me
          if (isMe) ...[
            const SizedBox(width: 8),
            _avatar(photo, initials, color),
          ],
        ],
      ),
    );
  }

  Widget _avatar(String? photo, String initials, Color color) {
    return Container(
      width: 30, height: 30,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
            colors: [BrokaColors.gradStart, BrokaColors.gradMid]),
        border: Border.all(color: color.withOpacity(0.5), width: 1.5),
      ),
      child: ClipOval(
        child: photo != null && photo.isNotEmpty
            ? Image.memory(base64Decode(photo), fit: BoxFit.cover)
            : Center(child: Text(initials, style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12))),
      ),
    );
  }

  Widget _brokerBubble() => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30, height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
                colors: [BrokaColors.gradStart, BrokaColors.neonBlue]),
            boxShadow: const [BrokaColors.glowPurple],
          ),
          child: const Icon(Icons.smart_toy_rounded, color: Colors.white, size: 14),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 3),
                child: Text('🤖 AI BROKER', style: TextStyle(
                    fontSize: 9, fontWeight: FontWeight.w800,
                    color: BrokaColors.neonPurple, letterSpacing: 1.2)),
              ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Color(0xFF2A1560), Color(0xFF150A35)]),
                  borderRadius: const BorderRadius.only(
                    topLeft:     Radius.circular(4),
                    topRight:    Radius.circular(16),
                    bottomLeft:  Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                  border: Border.all(
                      color: BrokaColors.neonPurple.withOpacity(0.3)),
                  boxShadow: const [BrokaColors.glowPurple],
                ),
                child: Text(msg.content, style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 13, height: 1.45)),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
