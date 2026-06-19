// BROKA - Negotiation Screen
// WhatsApp-style direct chat as primary mode.
// • Availability check dialog before chatting
// • Language compatibility check → AI-assisted mode if mismatch
// • Toggle between Direct Chat and AI-Assisted modes
// • Audio call button (opens phone dialler)
// • M-Pesa payment flow
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/webrtc_service.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../models/models.dart';
import '../models/listing.dart';

class NegotiationScreen extends StatefulWidget {
  const NegotiationScreen({super.key});
  @override
  State<NegotiationScreen> createState() => _NegotiationScreenState();
}

class _NegotiationScreenState extends State<NegotiationScreen> {
  Listing?      _listing;
  List<Message> _messages = [];
  bool          _loading  = true;
  bool          _sending  = false;
  String        _role     = 'buyer';

  // Chat mode
  bool _aiMode = false;   // false = direct chat (default), true = AI-assisted

  // Availability state
  bool? _itemAvailable;       // null = not checked, true = available, false = no
  bool  _availabilityChecked = false;

  // Language compatibility
  String _buyerLang  = 'english';
  String _sellerLang = 'english';
  bool   _langCheckDone = false;

  // M-Pesa state
  Map<String, dynamic>? _dealInfo;
  String  _mpesaPaymentStatus = 'idle';
  String? _checkoutRequestId;
  String? _mpesaReceipt;
  Timer?  _pollTimer;
  Timer?  _heartbeatTimer;
  int     _dealProbability = 50;

  final _msgCtrl    = TextEditingController();
  final _scrollCtrl = ScrollController();

  // Language switcher
  static const _langs = [
    ('english', 'EN',  '🇬🇧'),
    ('swahili', 'SW',  '🇰🇪'),
    ('luo',     'LUO', '🟡'),
    ('kikuyu',  'KIK', '🟤'),
    ('luganda', 'LUG', '🇺🇬'),
    ('sheng',   'SHG', '🔥'),
  ];
  late String _selectedLang;

  @override
  void initState() {
    super.initState();
    _selectedLang = ApiService.currentUserLanguage;
    _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => ApiService.updateLastSeen());
    ApiService.updateLastSeen();
    // Poll for new direct messages every 3s (real-time feel without WebSocket)
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_listing != null && mounted) {
        if (!_aiMode) _pollDirectMessages();
        _pollIncomingCall();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_listing == null) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        final la = args['listing'];
        if (la is Listing) _listing = la;
        else if (la is Map) _listing = Listing.fromJson(Map<String, dynamic>.from(la));
        final passedRole = args['role'] as String?;
        _role = passedRole ?? _detectRole();
        final dealArg = args['deal'] as Map<String, dynamic>?;
        if (dealArg != null) _dealInfo = dealArg;
      } else if (args is Listing) {
        _listing = args;
        _role = _detectRole();
      }
      if (_listing != null) {
        _loadHistory();
        _checkLanguageCompatibility();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showAvailabilityCheck();
        });
      }
    }
  }

  String _detectRole() {
    final uid = ApiService.currentUserId;
    if (uid != null && _listing?.sellerId != null && uid == _listing!.sellerId) {
      return 'seller';
    }
    return 'buyer';
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
    super.dispose();
  }

  // ── Availability Check ────────────────────────────────────────────────────

  Future<void> _showAvailabilityCheck() async {
    if (_availabilityChecked || _role == 'seller') return;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: BrokaColors.neonBlue, width: 1),
        ),
        title: const Row(children: [
          Text('🛒', style: TextStyle(fontSize: 22)),
          SizedBox(width: 10),
          Text('Check Availability', style: TextStyle(
              color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Before starting your negotiation, would you like to first ask the seller if this item is still available?',
            style: TextStyle(color: BrokaColors.textMid, height: 1.5),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BrokaColors.border),
            ),
            child: Row(children: [
              Text(_listing!.emoji, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_listing!.name, style: const TextStyle(
                    color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
                Text(_listing!.formattedPrice, style: const TextStyle(
                    color: BrokaColors.neonPurple, fontWeight: FontWeight.w800)),
              ])),
            ]),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Skip', style: TextStyle(color: BrokaColors.textLow)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.neonBlue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Ask Seller', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    setState(() => _availabilityChecked = true);
    if (result == true && mounted) {
      _sendAvailabilityMessage();
    }
  }

  void _sendAvailabilityMessage() {
    final question = 'Hi! Is this item still available?';
    _msgCtrl.text = question;
    _send();
  }

  // ── Language Check ────────────────────────────────────────────────────────

  Future<void> _checkLanguageCompatibility() async {
    if (_langCheckDone) return;
    _buyerLang  = ApiService.currentUserLanguage;
    // Seller lang from profile if available
    try {
      if (_listing?.sellerId != null) {
        final profile = await ApiService.getUserProfile(_listing!.sellerId!);
        _sellerLang = profile['preferred_language'] as String? ?? 'english';
      }
    } catch (_) {}

    setState(() => _langCheckDone = true);

    if (_buyerLang != _sellerLang && mounted) {
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) _showLanguageMismatchDialog();
    }
  }

  Future<void> _showLanguageMismatchDialog() async {
    final langName = (lang) {
      switch (lang) {
        case 'swahili': return 'Kiswahili';
        case 'luo':     return 'Dholuo';
        case 'kikuyu':  return 'Kikuyu';
        case 'luganda': return 'Luganda';
        case 'sheng':   return 'Sheng';
        default:        return 'English';
      }
    };

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: BrokaColors.neonPurple, width: 1),
        ),
        title: const Row(children: [
          Text('🌍', style: TextStyle(fontSize: 20)),
          SizedBox(width: 10),
          Text('Language Mismatch', style: TextStyle(
              color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'You speak ${langName(_buyerLang)} and the seller prefers ${langName(_sellerLang)}. '
            'Zeno AI can translate and mediate your conversation.',
            style: const TextStyle(color: BrokaColors.textMid, height: 1.5),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                BrokaColors.gradStart.withOpacity(0.2), BrokaColors.bgCard]),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.4)),
            ),
            child: const Row(children: [
              Icon(Icons.auto_awesome_rounded,
                  color: BrokaColors.neonPurple, size: 18),
              SizedBox(width: 10),
              Expanded(child: Text(
                'Zeno AI will translate messages in real-time so both parties understand each other.',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4),
              )),
            ]),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay Direct', style: TextStyle(color: BrokaColors.textLow)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.gradStart,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Use AI Translation',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (result == true && mounted) setState(() => _aiMode = true);
  }

  // ── Messaging ─────────────────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    try {
      final history = await ApiService.getNegotiationHistory(_listing!.id);
      if (mounted) setState(() { _messages = history; _loading = false; });
      _scrollDown();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pollIncomingCall() async {
    // Check if there's an active call room for this listing
    try {
      final callInfo = await ApiService.checkIncomingCall(_listing!.id);
      if (!mounted) return;
      if (callInfo != null && _role == 'seller') {
        final roomId    = callInfo['room_id'] as String?;
        final callerName = callInfo['caller_name'] as String? ?? 'Buyer';
        if (roomId != null) {
          // Show incoming call dialog
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => AlertDialog(
              backgroundColor: BrokaColors.bgMid,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Row(children: [
                Icon(Icons.call_rounded, color: BrokaColors.neonGreen),
                SizedBox(width: 10),
                Text('Incoming Call', style: TextStyle(color: BrokaColors.textHigh)),
              ]),
              content: Text('$callerName is calling about ${_listing?.name ?? 'your listing'}',
                  style: const TextStyle(color: BrokaColors.textMid)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Decline',
                      style: TextStyle(color: BrokaColors.danger)),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.call_rounded, size: 16),
                  label: const Text('Answer'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: BrokaColors.neonGreen),
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.pushNamed(context, '/voip-call', arguments: {
                      'roomId':      roomId,
                      'isCaller':    false,
                      'callerName':  callerName,
                      'listingName': _listing?.name ?? '',
                      'listingId':   _listing?.id ?? '',
                    });
                  },
                ),
              ],
            ),
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _pollDirectMessages() async {
    try {
      final history = await ApiService.getNegotiationHistory(_listing!.id);
      if (!mounted) return;
      // Only update if there are new messages
      if (history.length != _messages.length) {
        setState(() => _messages = history);
        _scrollDown();
      }
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _messages.add(Message(role: _role, content: text));
      _sending = true;
    });
    _msgCtrl.clear();
    _scrollDown();

    if (_aiMode) {
      // AI-assisted: send to broker backend
      try {
        final reply = await ApiService.sendNegotiationMessage(
          listingId:  _listing!.id,
          senderRole: _role,
          senderId:   ApiService.currentUserId ?? 'anon',
          content:    text,
          buyerLat:   _role == 'buyer'  ? ApiService.currentUserLat  : null,
          buyerLng:   _role == 'buyer'  ? ApiService.currentUserLng  : null,
          sellerLat:  _role == 'seller' ? ApiService.currentUserLat  : null,
          sellerLng:  _role == 'seller' ? ApiService.currentUserLng  : null,
          buyerName:  _role == 'buyer'  ? ApiService.currentUserName : null,
          sellerName: _role == 'seller' ? ApiService.currentUserName : null,
        );
        if (mounted) {
          final prob = reply.dealProbability;
          setState(() {
            _messages.add(reply);
            if (prob != null) _dealProbability = prob;
          });
        }
        _scrollDown();
      } catch (e) {
        if (mounted) setState(() => _messages.add(const Message(
            role: 'broker', content: '⚠️ Zeno is unavailable - retry.')));
      }
    } else {
      // Direct chat mode: store message, no AI response
      try {
        await ApiService.sendDirectMessage(
          listingId:  _listing!.id,
          senderRole: _role,
          senderId:   ApiService.currentUserId ?? 'anon',
          content:    text,
        );
      } catch (_) {}
    }

    if (mounted) setState(() => _sending = false);
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  List<Message> get _visibleMessages => _messages.where((m) {
    if (m.isBroker)      return _aiMode;
    if (m.role == _role) return true;
    if (!_aiMode)        return true;  // In direct mode, show both sides
    return false;
  }).toList();

  // ── Audio Call (in-app WebRTC VoIP) ───────────────────────────────────────

  Future<void> _initiateAudioCall() async {
    final listing = _listing;
    if (listing == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: BrokaColors.neonGreen, width: 1),
        ),
        title: const Row(children: [
          Icon(Icons.call_rounded, color: BrokaColors.neonGreen, size: 22),
          SizedBox(width: 10),
          Text('In-App Call', style: TextStyle(
              color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Start a secure in-app call with '
              '${listing.sellerName ?? "the seller"}?',
              style: const TextStyle(color: BrokaColors.textMid, height: 1.5)),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: BrokaColors.neonGreen.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.25)),
            ),
            child: const Row(children: [
              Icon(Icons.lock_outline_rounded,
                  color: BrokaColors.neonGreen, size: 14),
              SizedBox(width: 8),
              Expanded(child: Text(
                  'End-to-end encrypted · No phone number needed · '
                  'Confirm terms in chat after the call.',
                  style: TextStyle(
                      color: BrokaColors.neonGreen, fontSize: 10, height: 1.4))),
            ]),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: BrokaColors.textLow))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.neonGreen,
              foregroundColor: Colors.black87,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Call Now',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      // Room ID: listing_id + buyer_id (unique per negotiation session)
      final buyerId  = ApiService.currentUserId ?? 'anon';
      final roomId   = 'broka_\${listing.id}_\$buyerId';
      // Notify seller via FCM before navigating (fire-and-forget, non-blocking)
      unawaited(ApiService.initiateCall(
        roomId:      roomId,
        listingId:   listing.id,
        listingName: listing.name,
      ));
      Navigator.pushNamed(context, '/voip-call', arguments: {
        'roomId':      roomId,
        'userId':      buyerId,
        'peerName':    listing.sellerName ?? 'Seller',
        'listingName': listing.name,
        'isCaller':    true,
      });
    }
  }

  Map<String, dynamic>? get _sellerInfo => null; // stub - loaded via UserProfile

  // ── M-Pesa Deal Finalization ──────────────────────────────────────────────

  Future<void> _finalizeDeal() async {
    final listing = _listing;
    if (listing == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: BrokaColors.neonBlue, width: 1),
        ),
        title: const Text('Finalize Deal?',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Listing: ${listing.name}',
              style: const TextStyle(color: BrokaColors.textMid)),
          const SizedBox(height: 8),
          Text('Price: ${listing.formattedPrice}',
              style: const TextStyle(color: BrokaColors.neonGreen,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text('BROKA commission: 3%',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel',
                  style: TextStyle(color: BrokaColors.textLow))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.neonBlue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Confirm',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    try {
      final deal = await ApiService.finalizeDeal(
        listingId:   listing.id,
        buyerId:     ApiService.currentUserId ?? '',
        agreedPrice: listing.price,
      );
      if (mounted) setState(() => _dealInfo = deal);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not finalize deal: $e',
            style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.redAccent,
      ));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: Column(children: [
        _buildHeader(),
        _buildModeBanner(),
        if (_dealProbability > 0 && _aiMode) _buildDealMeter(),
        if (_dealInfo != null) _buildPaymentPanel(),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(
                color: BrokaColors.neonPurple))
            : _buildMessages()),
        _buildLangRow(),
        _buildInputBar(),
      ]),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader() => SafeArea(
    bottom: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: const BoxDecoration(
        color: BrokaColors.bgMid,
        border: Border(bottom: BorderSide(color: BrokaColors.border)),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BrokaColors.border),
            ),
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                color: BrokaColors.textMid, size: 16),
          ),
        ),
        const SizedBox(width: 12),
        // Avatar
        Container(
          width: 38, height: 38,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
                colors: [BrokaColors.gradStart, BrokaColors.gradMid]),
          ),
          child: Center(child: Text(
            (_listing?.sellerName ?? 'S')[0].toUpperCase(),
            style: const TextStyle(color: Colors.white,
                fontWeight: FontWeight.w800, fontSize: 16))),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_listing?.sellerName ?? 'Seller',
              style: const TextStyle(color: BrokaColors.textHigh,
                  fontWeight: FontWeight.w700, fontSize: 15)),
          Text(_listing?.name ?? '', style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 11),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        // Audio call button
        GestureDetector(
          onTap: _initiateAudioCall,
          child: Container(
            width: 36, height: 36, margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: BrokaColors.neonGreen.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.3)),
            ),
            child: const Icon(Icons.call_rounded,
                color: BrokaColors.neonGreen, size: 18),
          ),
        ),
        // AI mode toggle
        GestureDetector(
          onTap: () => setState(() => _aiMode = !_aiMode),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _aiMode
                  ? BrokaColors.neonPurple.withOpacity(0.2)
                  : BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _aiMode
                  ? BrokaColors.neonPurple : BrokaColors.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(_aiMode ? Icons.auto_awesome_rounded : Icons.chat_bubble_outline_rounded,
                  size: 14,
                  color: _aiMode ? BrokaColors.neonPurple : BrokaColors.textMid),
              const SizedBox(width: 5),
              Text(_aiMode ? 'AI' : 'Direct',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                      color: _aiMode ? BrokaColors.neonPurple : BrokaColors.textMid)),
            ]),
          ),
        ),
      ]),
    ),
  );

  // ── Mode Banner ───────────────────────────────────────────────────────────

  Widget _buildModeBanner() => AnimatedContainer(
    duration: const Duration(milliseconds: 300),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    color: _aiMode
        ? BrokaColors.neonPurple.withOpacity(0.08)
        : BrokaColors.neonGreen.withOpacity(0.06),
    child: Row(children: [
      Icon(
        _aiMode ? Icons.auto_awesome_rounded : Icons.chat_bubble_rounded,
        size: 14,
        color: _aiMode ? BrokaColors.neonPurple : BrokaColors.neonGreen,
      ),
      const SizedBox(width: 8),
      Expanded(child: Text(
        _aiMode
            ? 'AI-Assisted mode - Zeno translates & mediates your negotiation'
            : 'Direct Chat - messages go straight to the seller',
        style: TextStyle(
            color: _aiMode ? BrokaColors.neonPurple : BrokaColors.neonGreen,
            fontSize: 11),
      )),
      GestureDetector(
        onTap: () => setState(() => _aiMode = !_aiMode),
        child: Text(_aiMode ? 'Switch to Direct' : 'Use AI',
            style: const TextStyle(color: BrokaColors.textMid,
                fontSize: 11, decoration: TextDecoration.underline)),
      ),
    ]),
  );

  // ── Deal Meter (AI mode only) ─────────────────────────────────────────────

  Widget _buildDealMeter() {
    final color = _dealProbability > 70 ? BrokaColors.neonGreen
        : _dealProbability > 40 ? BrokaColors.warning : BrokaColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        const Text('Deal', style: TextStyle(
            color: BrokaColors.textLow, fontSize: 10)),
        const SizedBox(width: 8),
        Expanded(child: Stack(children: [
          Container(height: 6, decoration: BoxDecoration(
              color: BrokaColors.border, borderRadius: BorderRadius.circular(3))),
          FractionallySizedBox(
            widthFactor: _dealProbability / 100,
            child: Container(height: 6, decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(3))),
          ),
        ])),
        const SizedBox(width: 8),
        Text('$_dealProbability%',
            style: TextStyle(color: color, fontSize: 10,
                fontWeight: FontWeight.w700)),
      ]),
    );
  }

  // ── Payment Panel ─────────────────────────────────────────────────────────

  Widget _buildPaymentPanel() {
    final deal = _dealInfo;
    if (deal == null) return const SizedBox();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.neonGreen.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.4)),
      ),
      child: Row(children: [
        const Icon(Icons.check_circle_rounded,
            color: BrokaColors.neonGreen, size: 20),
        const SizedBox(width: 10),
        const Expanded(child: Text('Deal agreed! Pay commission to complete.',
            style: TextStyle(color: BrokaColors.neonGreen, fontSize: 12,
                fontWeight: FontWeight.w600))),
        GestureDetector(
          onTap: _showPaymentDialog,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: BrokaColors.neonGreen,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text('Pay', style: TextStyle(
                color: Colors.black87, fontWeight: FontWeight.w800,
                fontSize: 12)),
          ),
        ),
      ]),
    );
  }

  Future<void> _showPaymentDialog() async {
    final deal = _dealInfo;
    if (deal == null) return;
    final phoneCtrl    = TextEditingController();
    final passwordCtrl = TextEditingController();
    bool  obscure      = true;
    bool  paying       = false;
    String? errorMsg;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        final commission = (deal['commission'] as num?)?.toDouble() ?? 0.0;
        return AlertDialog(
          backgroundColor: BrokaColors.bgMid,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: BrokaColors.neonGreen, width: 1),
          ),
          title: const Row(children: [
            Text('M', style: TextStyle(color: BrokaColors.neonGreen,
                fontWeight: FontWeight.w900, fontSize: 20)),
            SizedBox(width: 8),
            Text('Pay via M-Pesa',
                style: TextStyle(color: BrokaColors.textHigh,
                    fontSize: 16, fontWeight: FontWeight.w800)),
          ]),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard, borderRadius: BorderRadius.circular(10),
                border: Border.all(color: BrokaColors.border),
              ),
              child: Column(children: [
                _row('BROKA Commission', 'KES ${commission.toStringAsFixed(0)}',
                    BrokaColors.neonGreen),
              ]),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: const InputDecoration(
                labelText: 'M-Pesa Phone', hintText: '07XXXXXXXX',
                prefixIcon: Icon(Icons.phone_android_rounded,
                    color: BrokaColors.neonGreen, size: 20),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passwordCtrl,
              obscureText: obscure,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: InputDecoration(
                labelText: 'BROKA Password',
                prefixIcon: const Icon(Icons.lock_outline_rounded,
                    color: BrokaColors.neonPurple, size: 20),
                suffixIcon: IconButton(
                  icon: Icon(obscure ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                      color: BrokaColors.textLow, size: 18),
                  onPressed: () => setDlg(() => obscure = !obscure),
                ),
              ),
            ),
            if (errorMsg != null) ...[
              const SizedBox(height: 10),
              Text(errorMsg!, style: const TextStyle(
                  color: Colors.redAccent, fontSize: 12)),
            ],
          ])),
          actions: [
            TextButton(
              onPressed: paying ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel',
                  style: TextStyle(color: BrokaColors.textLow)),
            ),
            ElevatedButton(
              onPressed: paying ? null : () async {
                final phone    = phoneCtrl.text.trim();
                final password = passwordCtrl.text;
                if (phone.isEmpty) { setDlg(() => errorMsg = 'Enter your phone number'); return; }
                if (password.isEmpty) { setDlg(() => errorMsg = 'Enter your password'); return; }
                setDlg(() { paying = true; errorMsg = null; });
                try {
                  final pushResult = await ApiService.mpesaStkPush(
                    dealId:      (deal['id'] ?? deal['deal_id']) as String,
                    phoneNumber: phone,
                    password:    password,
                  );
                  final checkoutId = pushResult['checkout_request_id'] as String?
                      ?? pushResult['CheckoutRequestID'] as String? ?? '';
                  if (mounted) {
                    Navigator.pop(ctx);
                    Navigator.pushNamed(context, '/mpesa-confirm', arguments: {
                      'checkoutRequestId': checkoutId,
                      'dealId':       (deal['id'] ?? deal['deal_id']) as String,
                      'amount':       _listing?.price ?? 0.0,
                      'phone':        phone,
                      'listingName':  _listing?.name ?? '',
                    });
                  }
                } catch (e) {
                  setDlg(() {
                    paying   = false;
                    errorMsg = e.toString().replaceAll('Exception: ', '');
                  });
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: BrokaColors.neonGreen,
                foregroundColor: Colors.black87,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: paying
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black87))
                  : const Text('Pay', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        );
      }),
    );
  }

  Widget _row(String label, String val, Color color) => Row(children: [
    Expanded(child: Text(label, style: const TextStyle(
        color: BrokaColors.textMid, fontSize: 12))),
    Text(val, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
  ]);

  // ── Messages ──────────────────────────────────────────────────────────────

  Widget _buildMessages() {
    final visible = _visibleMessages;
    if (visible.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_listing?.emoji ?? '💬',
            style: const TextStyle(fontSize: 48)),
        const SizedBox(height: 12),
        const Text('Start your negotiation below',
            style: TextStyle(color: BrokaColors.textMid)),
        const SizedBox(height: 4),
        Text(_aiMode
            ? 'Zeno AI will mediate your conversation'
            : 'Messages go directly to the seller',
            style: const TextStyle(color: BrokaColors.textLow, fontSize: 12)),
      ]));
    }
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      itemCount: visible.length,
      itemBuilder: (_, i) => _ChatBubble(
          message: visible[i], userRole: _role, aiMode: _aiMode),
    );
  }

  // ── Lang Row ──────────────────────────────────────────────────────────────

  Widget _buildLangRow() => Container(
    height: 44,
    color: BrokaColors.bgMid,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      children: [
        // Finalize deal button
        if (_role == 'buyer' && _dealInfo == null)
          GestureDetector(
            onTap: _finalizeDeal,
            child: Container(
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: BrokaColors.neonGreen.withOpacity(0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.5)),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.handshake_rounded, size: 12, color: BrokaColors.neonGreen),
                SizedBox(width: 5),
                Text('Finalize', style: TextStyle(
                    color: BrokaColors.neonGreen, fontSize: 11,
                    fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        // Lang chips
        ..._langs.map((l) {
          final key = l.$1; final short = l.$2; final flag = l.$3;
          return GestureDetector(
            onTap: () { setState(() => _selectedLang = key);
              ApiService.currentUserLanguage = key; },
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _selectedLang == key
                    ? BrokaColors.neonPurple.withOpacity(0.2) : BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _selectedLang == key
                      ? BrokaColors.neonPurple : BrokaColors.border,
                  width: _selectedLang == key ? 1.5 : 1,
                ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(flag, style: const TextStyle(fontSize: 11)),
                const SizedBox(width: 4),
                Text(short, style: TextStyle(
                    fontSize: 11,
                    fontWeight: _selectedLang == key
                        ? FontWeight.w800 : FontWeight.w500,
                    color: _selectedLang == key
                        ? Colors.white : BrokaColors.textMid)),
              ]),
            ),
          );
        }),
      ],
    ),
  );

  // ── Input Bar ─────────────────────────────────────────────────────────────

  Widget _buildInputBar() => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: BrokaColors.bgMid,
        border: Border(top: BorderSide(color: BrokaColors.border)),
      ),
      child: Row(children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: BrokaColors.border),
            ),
            child: TextField(
              controller: _msgCtrl,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
              maxLines: 3, minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: _role == 'buyer' ? 'Message seller...' : 'Message buyer...',
                hintStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 13),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _sending ? null : _send,
          child: Container(
            width: 46, height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: _sending
                    ? [BrokaColors.textLow, BrokaColors.textLow]
                    : _aiMode
                        ? [BrokaColors.gradStart, BrokaColors.neonBlue]
                        : [BrokaColors.neonGreen, const Color(0xFF059669)],
              ),
            ),
            child: _sending
                ? const Center(child: SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white)))
                : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
          ),
        ),
      ]),
    ),
  );
}

// ── Chat Bubble ─────────────────────────────────────────────────────────────
class _ChatBubble extends StatelessWidget {
  final Message message;
  final String  userRole;
  final bool    aiMode;
  const _ChatBubble({required this.message, required this.userRole, required this.aiMode});

  @override
  Widget build(BuildContext context) {
    final isBroker = message.isBroker;
    final isMe     = !isBroker && message.role == userRole;

    Color roleColor() {
      if (isBroker)            return BrokaColors.neonPurple;
      if (message.role == 'buyer')  return BrokaColors.neonBlue;
      return BrokaColors.neonGreen;
    }

    String roleLabel() {
      if (isBroker) return '🤖 Zeno AI';
      if (message.role == 'buyer') return isMe ? '🛒 You' : '🛒 Buyer';
      return isMe ? '🏷️ You' : '🏷️ Seller';
    }

    if (isBroker) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 18, height: 18,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [
                    BrokaColors.gradStart, BrokaColors.neonBlue]),
                ),
                child: const Icon(Icons.auto_awesome_rounded,
                    color: Colors.white, size: 10),
              ),
              const SizedBox(width: 5),
              const Text('ZENO',
                  style: TextStyle(color: BrokaColors.neonPurple, fontSize: 10,
                      fontWeight: FontWeight.w800, letterSpacing: 1.0)),
            ]),
          ),
          Container(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.88),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                BrokaColors.neonPurple.withOpacity(0.1), BrokaColors.bgCard]),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.3)),
            ),
            child: Text(message.content, style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 14, height: 1.5)),
          ),
        ]),
      );
    }

    // Buyer / Seller bubble - WhatsApp style
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: isMe
            ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[
            Container(
              width: 28, height: 28, margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: roleColor().withOpacity(0.2),
              ),
              child: Center(child: Icon(
                message.role == 'buyer' ? Icons.shopping_cart_rounded : Icons.store_rounded,
                color: roleColor(), size: 14)),
            ),
          ],
          Flexible(child: Column(
            crossAxisAlignment: isMe
                ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
            Container(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.72),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isMe
                    ? (message.role == 'buyer'
                        ? const Color(0xFF1565C0)
                        : const Color(0xFF2E7D32))
                    : BrokaColors.bgCard,
                borderRadius: BorderRadius.only(
                  topLeft:     Radius.circular(isMe ? 14 : 4),
                  topRight:    Radius.circular(isMe ? 4 : 14),
                  bottomLeft:  const Radius.circular(14),
                  bottomRight: const Radius.circular(14),
                ),
                border: Border.all(
                    color: roleColor().withOpacity(0.2), width: 1),
              ),
              child: Text(message.content, style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 14, height: 1.4)),
            ),
            const SizedBox(height: 2),
            Text(roleLabel(),
                style: TextStyle(color: roleColor(), fontSize: 9,
                    fontWeight: FontWeight.w600)),
          ])),
          if (isMe) const SizedBox(width: 6),
        ],
      ),
    );
  }
}
