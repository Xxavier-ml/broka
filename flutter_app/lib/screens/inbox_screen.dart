// BROKA - Inbox Screen
// Grouped by listing: general inbox -> per-listing sub-inbox
// Seller selling 5 items sees 5 groups; each group contains all buyer threads.
import 'dart:convert';
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
  // Map of listing_id -> list of threads for that listing
  Map<String, List<Map<String, dynamic>>> _grouped = {};
  List<Map<String, dynamic>> _threads = [];
  bool    _loading = true;
  String? _error;

  // Currently expanded listing group (null = all collapsed)
  String? _expanded;

  @override
  void initState() {
    super.initState();
    _loadInbox();
  }

  Future<void> _loadInbox() async {
    setState(() { _loading = true; _error = null; });
    try {
      final data = await ApiService.getInbox();
      if (mounted) {
        // Group threads by listing_id
        final Map<String, List<Map<String, dynamic>>> grouped = {};
        for (final t in data) {
          final lid = t['listing_id'] as String;
          grouped.putIfAbsent(lid, () => []).add(t);
        }
        setState(() {
          _threads = data;
          _grouped = grouped;
          _loading = false;
          // Auto-expand if only one listing group
          if (grouped.length == 1) _expanded = grouped.keys.first;
        });
      }
    } catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error   = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  int get _totalUnread =>
      _threads.fold(0, (s, t) => s + ((t['unread'] as int?) ?? 0));

  void _openThread(Map<String, dynamic> t) {
    final listing = Listing(
      id:           t['listing_id']       as String,
      name:         t['listing_name']     as String,
      category:     t['listing_category'] as String,
      price:        (t['listing_price']   as num).toDouble(),
      locationName: t['location_name']    as String?,
      listingType:  t['listing_type']     as String,
      status:       'active',
      views:        0,
      sellerId:     t['seller_id']        as String?,
      sellerName:   t['seller_name']      as String?,
    );
    Navigator.pushNamed(context, '/negotiate', arguments: {
      'listing': listing,
      'role':    t['my_role'] as String,
    }).then((_) => _loadInbox());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bgMid,
        title: Row(children: [
          const Text('Inbox', style: TextStyle(
              color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
          if (_totalUnread > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: BrokaColors.danger,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$_totalUnread', style: const TextStyle(
                  color: Colors.white, fontSize: 11,
                  fontWeight: FontWeight.w800)),
            ),
          ],
        ]),
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
        GradientButton(onPressed: _loadInbox,
          child: const Text('Retry', style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700))),
      ],
    ));

    if (_grouped.isEmpty) return _buildEmpty();

    final listingIds = _grouped.keys.toList();
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: listingIds.length,
      itemBuilder: (_, i) {
        final lid     = listingIds[i];
        final threads = _grouped[lid]!;
        final first   = threads.first;
        final unread  = threads.fold(0, (s, t) => s + ((t['unread'] as int?) ?? 0));
        final isExpanded = _expanded == lid;

        return _ListingGroup(
          listingId:   lid,
          listingName: first['listing_name'] as String,
          category:    first['listing_category'] as String,
          price:       (first['listing_price'] as num).toDouble(),
          unreadCount: unread,
          threadCount: threads.length,
          isExpanded:  isExpanded,
          onToggle: () => setState(() =>
              _expanded = isExpanded ? null : lid),
          threads:     threads,
          onThreadTap: _openThread,
        );
      },
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
          child: Text('Browse Listings', style: TextStyle(
              fontWeight: FontWeight.w700, fontSize: 14, color: Colors.white)),
        ),
      ),
    ],
  ));
}

// ── Listing Group (accordion) ─────────────────────────────────────────────────

class _ListingGroup extends StatelessWidget {
  final String  listingId;
  final String  listingName;
  final String  category;
  final double  price;
  final int     unreadCount;
  final int     threadCount;
  final bool    isExpanded;
  final VoidCallback onToggle;
  final List<Map<String, dynamic>> threads;
  final void Function(Map<String, dynamic>) onThreadTap;

  const _ListingGroup({
    required this.listingId, required this.listingName,
    required this.category,  required this.price,
    required this.unreadCount, required this.threadCount,
    required this.isExpanded,  required this.onToggle,
    required this.threads,     required this.onThreadTap,
  });

  String _emoji(String cat) {
    switch (cat) {
      case 'Vehicles':    return '🚗';
      case 'Property':    return '🏠';
      case 'Electronics': return '📱';
      case 'Livestock':   return '🐄';
      default:            return '📦';
    }
  }

  String _fmt(double v) => 'KES ${v.toStringAsFixed(0).replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: unreadCount > 0
              ? BrokaColors.neonPurple.withOpacity(0.5)
              : BrokaColors.border,
          width: unreadCount > 0 ? 1.5 : 1,
        ),
      ),
      child: Column(children: [
        // ── Group header (tap to expand/collapse) ──
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(children: [
              // Listing icon
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: unreadCount > 0
                      ? [BrokaColors.gradStart, BrokaColors.gradMid]
                      : [BrokaColors.bgMid, BrokaColors.bgMid]),
                  border: Border.all(
                    color: unreadCount > 0
                        ? BrokaColors.neonPurple : BrokaColors.border),
                ),
                child: Center(child: Text(_emoji(category),
                    style: const TextStyle(fontSize: 22))),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(listingName, style: TextStyle(
                    color: unreadCount > 0
                        ? BrokaColors.textHigh : BrokaColors.textMid,
                    fontWeight: unreadCount > 0
                        ? FontWeight.w800 : FontWeight.w600,
                    fontSize: 14),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Row(children: [
                  Text(_fmt(price), style: const TextStyle(
                      color: BrokaColors.neonGreen,
                      fontSize: 11, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Text('$threadCount conversation${threadCount == 1 ? '' : 's'}',
                      style: const TextStyle(
                          color: BrokaColors.textLow, fontSize: 11)),
                ]),
              ])),
              // Unread badge
              if (unreadCount > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: BrokaColors.danger,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('$unreadCount', style: const TextStyle(
                      color: Colors.white, fontSize: 11,
                      fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 8),
              ],
              AnimatedRotation(
                turns: isExpanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.keyboard_arrow_down_rounded,
                    color: BrokaColors.textMid, size: 22),
              ),
            ]),
          ),
        ),
        // ── Thread list (expanded) ──
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: isExpanded
              ? Column(children: [
                  const Divider(color: BrokaColors.border, height: 1),
                  ...threads.map((t) => _ThreadRow(
                    thread: t,
                    onTap: () => onThreadTap(t),
                  )),
                ])
              : const SizedBox.shrink(),
        ),
      ]),
    );
  }
}

// ── Thread row inside a group ─────────────────────────────────────────────────

class _ThreadRow extends StatelessWidget {
  final Map<String, dynamic> thread;
  final VoidCallback onTap;
  const _ThreadRow({required this.thread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final lastMsg    = thread['last_message']  as String;
    final lastRole   = thread['last_role']     as String;
    final unread     = (thread['unread']       as int?) ?? 0;
    final timeAgo    = thread['time_ago']      as String;
    final myRole     = thread['my_role']       as String;
    final sellerName = thread['seller_name']   as String?;
    final buyerName  = thread['buyer_name']    as String?;
    final avatarB64  = thread['counterpart_avatar'] as String?;
    final isOnline   = thread['is_online']     as bool? ?? false;

    // Show name of the OTHER party
    final otherName = myRole == 'seller'
        ? (buyerName ?? 'Buyer')
        : (sellerName ?? 'Seller');

    final initials = otherName.isNotEmpty ? otherName[0].toUpperCase() : '?';

    final roleColor = lastRole == 'broker'
        ? BrokaColors.neonPurple
        : lastRole == 'buyer' ? BrokaColors.neonBlue : BrokaColors.neonGreen;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(children: [
          // Avatar with online dot
          Stack(children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: unread > 0
                    ? [BrokaColors.gradStart, BrokaColors.gradMid]
                    : [BrokaColors.bgMid, BrokaColors.bgMid]),
                border: Border.all(
                  color: unread > 0 ? BrokaColors.neonPurple : BrokaColors.border,
                  width: unread > 0 ? 2 : 1,
                ),
              ),
              child: ClipOval(
                child: avatarB64 != null && avatarB64.isNotEmpty
                    ? Image.memory(base64Decode(avatarB64), fit: BoxFit.cover)
                    : Center(child: Text(initials, style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700,
                        fontSize: 16))),
              ),
            ),
            Positioned(bottom: 1, right: 1,
              child: Container(
                width: 11, height: 11,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOnline ? BrokaColors.neonGreen : BrokaColors.textLow,
                  border: Border.all(color: BrokaColors.bgCard, width: 1.5),
                ),
              ),
            ),
            if (unread > 0)
              Positioned(top: 0, right: 0, child: Container(
                width: 16, height: 16,
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: BrokaColors.danger),
                child: Center(child: Text('$unread', style: const TextStyle(
                    color: Colors.white, fontSize: 9,
                    fontWeight: FontWeight.w800))),
              )),
          ]),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(otherName, style: TextStyle(
                  color: unread > 0 ? BrokaColors.textHigh : BrokaColors.textMid,
                  fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 13),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              Text(timeAgo, style: const TextStyle(
                  color: BrokaColors.textLow, fontSize: 10)),
            ]),
            const SizedBox(height: 3),
            Row(children: [
              Container(width: 5, height: 5, decoration: BoxDecoration(
                  shape: BoxShape.circle, color: roleColor)),
              const SizedBox(width: 5),
              Expanded(child: Text(lastMsg, style: TextStyle(
                  color: unread > 0 ? BrokaColors.textMid : BrokaColors.textLow,
                  fontSize: 12,
                  fontWeight: unread > 0 ? FontWeight.w500 : FontWeight.normal),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (unread == 0)
                const Icon(Icons.done_all_rounded,
                    size: 13, color: BrokaColors.neonBlue),
            ]),
          ])),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_right_rounded,
              color: BrokaColors.textLow, size: 18),
        ]),
      ),
    );
  }
}
