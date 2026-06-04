// BROKA — Inbox Screen
// Shows REAL negotiation threads from the backend.
// Seller sees threads from buyers on their listings.
// Buyer sees threads they've started.
import 'package:flutter/material.dart';
import '../main.dart';
import '../models/listing.dart';
import '../services/api_service.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});
  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  List<Map<String, dynamic>> _threads = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadInbox();
  }

  Future<void> _loadInbox() async {
    setState(() { _loading = true; _error = null; });
    try {
      final data = await ApiService.getInbox();
      if (mounted) setState(() { _threads = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  int get _unreadCount =>
      _threads.fold(0, (sum, t) => sum + ((t['unread'] as int?) ?? 0));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bgMid,
        title: const Text('Inbox', style: TextStyle(
            color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        actions: [
          if (_unreadCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: BrokaColors.neonPurple.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.3)),
                ),
                child: Text('$_unreadCount new', style: const TextStyle(
                    color: BrokaColors.neonPurple,
                    fontSize: 11, fontWeight: FontWeight.w700)),
              )),
            ),
        ],
      ),
      body: RefreshIndicator(
        color: BrokaColors.neonPurple,
        backgroundColor: BrokaColors.bgCard,
        onRefresh: _loadInbox,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator(
        color: BrokaColors.neonPurple, strokeWidth: 1.5));

    if (_error != null) return Center(child: Column(
      mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline, color: BrokaColors.danger, size: 40),
        const SizedBox(height: 12),
        Text(_error!, textAlign: TextAlign.center,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
        const SizedBox(height: 16),
        GradientButton(
          onPressed: _loadInbox,
          child: const Text('Retry',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        ),
      ],
    ));

    if (_threads.isEmpty) return _buildEmpty();

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _threads.length,
      separatorBuilder: (_, __) =>
          const Divider(color: BrokaColors.border, height: 1),
      itemBuilder: (_, i) => _ThreadTile(
        thread: _threads[i],
        onTap: () {
          final t = _threads[i];
          final listing = Listing(
            id:           t['listing_id'] as String,
            name:         t['listing_name'] as String,
            category:     t['listing_category'] as String,
            price:        (t['listing_price'] as num).toDouble(),
            locationName: t['location_name'] as String?,
            listingType:  t['listing_type'] as String,
            status:       'active',
            views:        0,
            sellerId:     t['seller_id'] as String?,
            sellerName:   t['seller_name'] as String?,
          );
          Navigator.pushNamed(context, '/negotiate', arguments: {
            'listing': listing,
            'role':    t['my_role'] as String,
          }).then((_) => _loadInbox());
        },
      ),
    );
  }

  Widget _buildEmpty() => Center(child: Column(
    mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.inbox_outlined, color: BrokaColors.textLow, size: 52),
      const SizedBox(height: 14),
      const Text('No conversations yet', style: TextStyle(
          color: BrokaColors.textMid, fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      const Text('Browse listings and start a deal',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 13)),
      const SizedBox(height: 20),
      GradientButton(
        onPressed: () => Navigator.pushNamedAndRemoveUntil(
            context, '/home', (_) => false),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Text('Browse Listings',
              style: TextStyle(fontWeight: FontWeight.w700,
                  fontSize: 14, color: Colors.white)),
        ),
      ),
    ],
  ));
}

// ── Thread Tile ───────────────────────────────────────────────────────────────

class _ThreadTile extends StatelessWidget {
  final Map<String, dynamic> thread;
  final VoidCallback onTap;
  const _ThreadTile({required this.thread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name     = thread['listing_name'] as String;
    final lastMsg  = thread['last_message'] as String;
    final lastRole = thread['last_role']    as String;
    final unread   = (thread['unread']      as int?) ?? 0;
    final timeAgo  = thread['time_ago']     as String;
    final myRole   = thread['my_role']      as String;
    final category = thread['listing_category'] as String;
    final price    = (thread['listing_price'] as num).toDouble();
    final sellerName = thread['seller_name'] as String?;

    final emoji = _emoji(category);
    final roleColor = lastRole == 'broker'
        ? BrokaColors.neonPurple
        : lastRole == 'buyer'
            ? BrokaColors.neonBlue
            : BrokaColors.neonGreen;

    // Role label to show context
    final roleLabel = myRole == 'seller' ? 'You\'re selling' : 'You\'re buying from ${sellerName ?? 'seller'}';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(children: [
          // Avatar with unread indicator
          Stack(children: [
            Container(
              width: 50, height: 50,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: unread > 0
                    ? const LinearGradient(
                        colors: [BrokaColors.gradStart, BrokaColors.gradMid])
                    : null,
                color: unread > 0 ? null : BrokaColors.bgCard,
                border: Border.all(
                  color: unread > 0 ? BrokaColors.neonPurple : BrokaColors.border,
                  width: unread > 0 ? 2 : 1,
                ),
              ),
              child: Center(child: Text(emoji,
                  style: const TextStyle(fontSize: 22))),
            ),
            if (unread > 0)
              Positioned(top: 0, right: 0, child: Container(
                width: 18, height: 18,
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: BrokaColors.danger),
                child: Center(child: Text('$unread',
                    style: const TextStyle(color: Colors.white,
                        fontSize: 10, fontWeight: FontWeight.w800))),
              )),
          ]),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(name, style: TextStyle(
                  color: unread > 0 ? BrokaColors.textHigh : BrokaColors.textMid,
                  fontWeight: unread > 0 ? FontWeight.w800 : FontWeight.w600,
                  fontSize: 14),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              Text(timeAgo, style: const TextStyle(
                  color: BrokaColors.textLow, fontSize: 11)),
            ]),
            const SizedBox(height: 3),
            // Role context
            Text(roleLabel, style: const TextStyle(
                color: BrokaColors.textLow, fontSize: 10,
                fontStyle: FontStyle.italic)),
            const SizedBox(height: 3),
            Row(children: [
              // Role dot
              Container(width: 6, height: 6, decoration: BoxDecoration(
                  shape: BoxShape.circle, color: roleColor)),
              const SizedBox(width: 5),
              Expanded(child: Text(lastMsg, style: TextStyle(
                  color: unread > 0 ? BrokaColors.textHigh : BrokaColors.textMid,
                  fontSize: 12,
                  fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.normal),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (unread == 0)
                const Icon(Icons.done_all_rounded,
                    size: 14, color: BrokaColors.neonBlue),
            ]),
            const SizedBox(height: 4),
            Text(_fmtPrice(price), style: const TextStyle(
                color: BrokaColors.neonGreen,
                fontSize: 11, fontWeight: FontWeight.w700)),
          ])),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right_rounded,
              color: BrokaColors.textLow, size: 20),
        ]),
      ),
    );
  }

  String _emoji(String cat) {
    switch (cat) {
      case 'Vehicles':    return '🚗';
      case 'Property':    return '🏠';
      case 'Electronics': return '📱';
      case 'Livestock':   return '🐄';
      default:            return '📦';
    }
  }

  String _fmtPrice(double v) =>
      'KES ${v.toStringAsFixed(0).replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';
}
