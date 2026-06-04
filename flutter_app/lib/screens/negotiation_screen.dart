import 'package:flutter/material.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../models/models.dart';
import '../models/listing.dart';

/// Full buyer-seller negotiation screen with real-time AI broker mediation.
/// Navigate to this screen with a [Listing] as the route argument,
/// or as a Map with keys 'listing' and 'role'.
///
/// PRIVACY MODEL:
///   - Role is auto-detected: if currentUserId == listing.sellerId → seller, else → buyer.
///   - Each user only sees: their own messages + broker messages.
///     The other party's raw messages are NEVER shown; the broker relays intent.
class NegotiationScreen extends StatefulWidget {
  const NegotiationScreen({super.key});
  @override
  State<NegotiationScreen> createState() => _NegotiationScreenState();
}

class _NegotiationScreenState extends State<NegotiationScreen> {
  final _msgCtrl    = TextEditingController();
  final _scrollCtrl = ScrollController();

  Listing?       _listing;
  List<Message>  _messages  = [];
  bool           _loading   = true;
  bool           _sending   = false;
  String         _role      = 'buyer'; // auto-set in didChangeDependencies

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_listing == null) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        final listingArg = args['listing'];
        if (listingArg is Listing) {
          _listing = listingArg;
        } else if (listingArg is Map) {
          _listing = Listing.fromJson(Map<String, dynamic>.from(listingArg));
        }
        // If role is explicitly passed (e.g. from inbox), honour it.
        // Otherwise auto-detect from current user vs seller.
        final passedRole = args['role'] as String?;
        if (passedRole != null) {
          _role = passedRole;
        } else {
          _role = _detectRole();
        }
      } else if (args is Listing) {
        _listing = args;
        _role = _detectRole();
      }
      if (_listing != null) _loadHistory();
    }
  }

  /// Auto-detect whether the current user is the seller or a buyer.
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
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final history = await ApiService.getNegotiationHistory(_listing!.id);
      if (mounted) setState(() { _messages = history; _loading = false; });
      _scrollDown();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
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

    try {
      final reply = await ApiService.sendNegotiationMessage(
        listingId:   _listing!.id,
        senderRole:  _role,
        senderId:    ApiService.currentUserId ?? 'anon',
        content:     text,
        buyerLat:    _role == 'buyer'  ? ApiService.currentUserLat  : null,
        buyerLng:    _role == 'buyer'  ? ApiService.currentUserLng  : null,
        sellerLat:   _role == 'seller' ? ApiService.currentUserLat  : null,
        sellerLng:   _role == 'seller' ? ApiService.currentUserLng  : null,
        buyerName:   _role == 'buyer'  ? ApiService.currentUserName : null,
        sellerName:  _role == 'seller' ? ApiService.currentUserName : null,
      );
      if (mounted) setState(() => _messages.add(reply));
      _scrollDown();
    } catch (e) {
      if (mounted) {
        setState(() => _messages.add(const Message(
            role: 'broker', content: '⚠️ Could not reach broker — retry.')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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

  /// Messages are already filtered server-side by role via the history endpoint.
  /// On the local list we only need to hide the other party's non-broker messages
  /// that were optimistically added before the server response arrived.
  List<Message> get _visibleMessages => _messages.where((m) {
    if (m.isBroker)      return true; // broker messages — server already filtered
    if (m.role == _role) return true; // own messages
    return false;                     // hide any stale other-party messages
  }).toList();

  @override
  Widget build(BuildContext context) {
    if (_listing == null) {
      return const Scaffold(
        backgroundColor: BrokaColors.bg,
        body: Center(child: Text('No listing provided.',
            style: TextStyle(color: BrokaColors.textMid))),
      );
    }

    final isBuyer  = _role == 'buyer';
    final roleColor = isBuyer ? BrokaColors.neonBlue : BrokaColors.neonGreen;

    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bgMid,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: BrokaColors.textMid, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Negotiate: ${_listing!.name}',
                style: const TextStyle(fontSize: 14,
                    fontWeight: FontWeight.w800, color: BrokaColors.textHigh),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(_listing!.formattedPrice,
                style: const TextStyle(
                    fontSize: 11, color: BrokaColors.neonGreen)),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            // Role badge — display only, no tap to switch
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: roleColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: roleColor.withOpacity(0.5)),
              ),
              child: Text(
                isBuyer ? '🛒 Buyer' : '🏷️ Seller',
                style: TextStyle(
                  color: roleColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Privacy notice banner
          _buildPrivacyBanner(),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: BrokaColors.neonPurple))
                : _visibleMessages.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.all(12),
                        itemCount: _visibleMessages.length,
                        itemBuilder: (_, i) => _NegotiationBubble(
                            message: _visibleMessages[i],
                            userRole: _role),
                      ),
          ),
          if (_sending) _buildTypingBar(),
          _buildInputBar(),
        ],
      ),
    );
  }

  /// Thin banner reminding the user that messages are private via the broker.
  Widget _buildPrivacyBanner() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    color: BrokaColors.bgCard,
    child: Row(
      children: [
        const Icon(Icons.shield_outlined,
            size: 13, color: BrokaColors.neonPurple),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _role == 'buyer'
                ? 'BROKA mediates on your behalf — the seller sees only what the broker shares.'
                : 'BROKA mediates on your behalf — the buyer sees only what the broker shares.',
            style: const TextStyle(
                color: BrokaColors.textLow, fontSize: 10.5),
          ),
        ),
      ],
    ),
  );

  Widget _buildEmptyState() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.handshake_outlined,
            color: BrokaColors.textLow, size: 48),
        const SizedBox(height: 12),
        const Text('No messages yet',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 15,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text('Start the negotiation as $_role',
            style: const TextStyle(color: BrokaColors.textLow, fontSize: 13)),
      ],
    ),
  );

  Widget _buildTypingBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    color: BrokaColors.bgMid,
    child: Row(
      children: [
        Container(
          width: 24, height: 24,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [BrokaColors.gradStart, BrokaColors.neonBlue],
            ),
          ),
          child: const Icon(Icons.smart_toy_rounded,
              color: Colors.white, size: 12),
        ),
        const SizedBox(width: 8),
        const Text('BROKA is mediating...',
            style: TextStyle(color: BrokaColors.neonPurple,
                fontSize: 12, fontStyle: FontStyle.italic)),
      ],
    ),
  );

  Widget _buildInputBar() => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
    decoration: const BoxDecoration(
      color: BrokaColors.bgMid,
      border: Border(top: BorderSide(color: BrokaColors.border)),
    ),
    child: Row(
      children: [
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
                hintText: _role == 'buyer'
                    ? 'Message as Buyer...'
                    : 'Message as Seller...',
                hintStyle: const TextStyle(
                    color: BrokaColors.textLow, fontSize: 13),
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
                    : [BrokaColors.gradStart, BrokaColors.neonBlue],
              ),
            ),
            child: const Icon(Icons.send_rounded,
                color: Colors.white, size: 20),
          ),
        ),
      ],
    ),
  );
}

// ── Negotiation Bubble ────────────────────────────────────────────────────────
class _NegotiationBubble extends StatelessWidget {
  final Message  message;
  final String   userRole; // the role of the person currently viewing
  const _NegotiationBubble({required this.message, required this.userRole});

  @override
  Widget build(BuildContext context) {
    final isBroker = message.isBroker;
    // "isMe" means this message was sent by the current viewer
    final isMe     = !isBroker && message.role == userRole;

    // Colour per role
    Color roleColor() {
      if (isBroker)        return BrokaColors.neonPurple;
      if (userRole == 'buyer')  return BrokaColors.neonBlue;
      return BrokaColors.neonGreen;
    }

    // Label shown above the bubble
    String roleLabel() {
      if (isBroker) return '🤖 BROKA';
      // Only the user's own label is shown (other party messages are filtered out)
      return userRole == 'buyer' ? '🛒 You (Buyer)' : '🏷️ You (Seller)';
    }

    // Alignment
    CrossAxisAlignment alignment() {
      if (isBroker) return CrossAxisAlignment.center;
      return CrossAxisAlignment.end; // own messages always on the right
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: alignment(),
        children: [
          if (!isBroker)
            Padding(
              padding: const EdgeInsets.only(bottom: 4, right: 4),
              child: Text(
                roleLabel(),
                style: TextStyle(
                    color: roleColor(),
                    fontSize: 11,
                    fontWeight: FontWeight.w700),
              ),
            ),
          if (isBroker)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 18, height: 18,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                          colors: [BrokaColors.gradStart, BrokaColors.neonBlue]),
                    ),
                    child: const Icon(Icons.smart_toy_rounded,
                        color: Colors.white, size: 10),
                  ),
                  const SizedBox(width: 5),
                  Text('BROKA',
                      style: TextStyle(
                          color: BrokaColors.neonPurple,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.0)),
                ],
              ),
            ),
          Container(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width *
                    (isBroker ? 0.88 : 0.72)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              gradient: isBroker
                  ? LinearGradient(colors: [
                      BrokaColors.neonPurple.withOpacity(0.1),
                      BrokaColors.bgCard,
                    ])
                  : userRole == 'buyer'
                      ? const LinearGradient(
                          colors: [Color(0xFF0D47A1), Color(0xFF1565C0)])
                      : const LinearGradient(
                          colors: [Color(0xFF1B5E20), Color(0xFF2E7D32)]),
              borderRadius: isBroker
                  ? BorderRadius.circular(14)
                  : const BorderRadius.only(
                      topLeft:     Radius.circular(14),
                      topRight:    Radius.circular(4),
                      bottomLeft:  Radius.circular(14),
                      bottomRight: Radius.circular(14),
                    ),
              border: Border.all(
                  color: roleColor().withOpacity(isBroker ? 0.3 : 0.2),
                  width: isBroker ? 1 : 1.5),
              boxShadow: [
                BoxShadow(
                  color: roleColor().withOpacity(0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              message.content,
              style: const TextStyle(
                  color: BrokaColors.textHigh,
                  fontSize: 14,
                  height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
