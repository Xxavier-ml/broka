import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../models/models.dart';

class AuctionScreen extends StatefulWidget {
  const AuctionScreen({super.key});
  @override
  State<AuctionScreen> createState() => _AuctionScreenState();
}

class _AuctionScreenState extends State<AuctionScreen> {
  final _bidCtrl = TextEditingController();
  int _secondsLeft = 14 * 60 + 32;
  Timer? _timer;
  Timer? _refreshTimer;
  List<Bid> _bids = [];
  bool _loadingBids = true;
  bool _placingBid = false;
  String? _bidError;
  static const _demoListingId = 'd3';

  final _demoBids = const [
    Bid(rank: 1, bidderName: 'Peter Otieno',  amount: 85000, timeAgo: '2m ago'),
    Bid(rank: 2, bidderName: 'Grace Wanjiru', amount: 80000, timeAgo: '5m ago'),
    Bid(rank: 3, bidderName: 'David Njoroge', amount: 78000, timeAgo: '8m ago'),
    Bid(rank: 4, bidderName: 'Amina Hassan',  amount: 75000, timeAgo: '12m ago'),
    Bid(rank: 5, bidderName: 'John Mwangi',   amount: 70000, timeAgo: '18m ago'),
  ];

  double get _topBid => _bids.isEmpty ? 0 : _bids.first.amount;

  @override
  void initState() {
    super.initState();
    _loadLeaderboard();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_secondsLeft > 0 && mounted) setState(() => _secondsLeft--);
    });
    _refreshTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => _loadLeaderboard());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _refreshTimer?.cancel();
    _bidCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLeaderboard() async {
    try {
      final b = await ApiService.getLeaderboard(_demoListingId);
      if (mounted) setState(() {
        // fixed: cast List<dynamic> to List<Bid>
        _bids = b
            .map((e) => Bid.fromJson(e as Map<String, dynamic>))
            .toList();
        _loadingBids = false;
      });
    } catch (_) {
      if (mounted) setState(() {
        _bids = List<Bid>.from(_demoBids);
        _loadingBids = false;
      });
    }
  }

  Future<void> _placeBid() async {
    final amount = double.tryParse(_bidCtrl.text);
    if (amount == null) {
      setState(() => _bidError = 'Enter a valid amount');
      return;
    }
    if (amount <= _topBid) {
      setState(() => _bidError = 'Must exceed ${Bid.fmt(_topBid)}');
      return;
    }
    setState(() { _placingBid = true; _bidError = null; });
    try {
      await ApiService.placeBid(listingId: _demoListingId, amount: amount);
      _bidCtrl.clear();
      await _loadLeaderboard();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bid placed: ${Bid.fmt(amount)}')));
    } catch (_) {
      // Optimistic local update if API fails
      if (mounted) setState(() {
        final nb = Bid(rank: 1, bidderName: 'You', amount: amount, timeAgo: 'just now');
        final updated = [nb, ..._bids];
        _bids = List.generate(updated.length, (i) => Bid(
          rank: i + 1,
          bidderName: updated[i].bidderName,
          amount: updated[i].amount,
          timeAgo: updated[i].timeAgo,
        ));
        _bidError = null;
      });
      _bidCtrl.clear();
    } finally {
      if (mounted) setState(() => _placingBid = false);
    }
  }

  String get _countdown {
    final m = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final s = (_secondsLeft % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Color get _timerColor => _secondsLeft < 120
      ? BrokaColors.danger
      : _secondsLeft < 300
          ? BrokaColors.warning
          : BrokaColors.neonPurple;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: BrokaColors.headerGradColors,
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: BrokaColors.bgCard,
                        border: Border.all(color: BrokaColors.border)),
                    child: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: BrokaColors.textMid, size: 16)),
                ),
                const SizedBox(width: 12),
                const Text('LIVE AUCTION', style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w800,
                    color: BrokaColors.textHigh)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: BrokaColors.danger.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: BrokaColors.danger.withOpacity(0.4)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 7, height: 7, decoration: const BoxDecoration(
                        color: BrokaColors.danger, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    const Text('LIVE', style: TextStyle(color: BrokaColors.danger,
                        fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1)),
                  ]),
                ),
              ]),
            ),

            Expanded(child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                _buildAuctionCard(),
                const SizedBox(height: 14),
                _buildBidInput(),
                const SizedBox(height: 20),
                _buildLeaderboard(),
              ]),
            )),
          ]),
        ),
      ),
    );
  }

  Widget _buildAuctionCard() => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: BrokaColors.cardGradColors,
        begin: Alignment.topLeft, end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: BrokaColors.border),
      boxShadow: const [BrokaColors.glowPurple],
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('🏠 3-Bed Penthouse, Kileleshwa',
        style: TextStyle(color: BrokaColors.textHigh,
            fontWeight: FontWeight.w700, fontSize: 16)),
      const SizedBox(height: 3),
      const Row(children: [
        Icon(Icons.location_on_outlined, size: 12, color: BrokaColors.textLow),
        SizedBox(width: 3),
        Text('Kileleshwa, Nairobi County',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
      ]),
      const SizedBox(height: 18),

      Row(children: [
        _metric(Bid.fmt(_topBid > 0 ? _topBid : 10500000), 'CURRENT BID', BrokaColors.neonPurple),
        _vDivider(),
        _metric('KES 10M', 'RESERVE', null),
        _vDivider(),
        _metric('8 / 10', 'BIDDERS', BrokaColors.success),
      ]),
      const SizedBox(height: 18),
      Container(height: 1, color: BrokaColors.border),
      const SizedBox(height: 16),

      Row(children: [
        const Text('TIME REMAINING', style: TextStyle(color: BrokaColors.textLow,
            fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
        const Spacer(),
        ShaderMask(
          shaderCallback: (b) => LinearGradient(
            colors: [_timerColor, _timerColor.withOpacity(0.7)]).createShader(b),
          child: Text(_countdown, style: const TextStyle(
            color: Colors.white, fontSize: 30,
            fontWeight: FontWeight.w900, letterSpacing: 3)),
        ),
      ]),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: _secondsLeft / (14 * 60 + 32),
          backgroundColor: BrokaColors.bgCard,
          valueColor: AlwaysStoppedAnimation(_timerColor),
          minHeight: 4,
        ),
      ),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            BrokaColors.gradStart.withOpacity(0.1),
            BrokaColors.gradMid.withOpacity(0.05),
          ]),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.2)),
        ),
        child: const Row(children: [
          Icon(Icons.smart_toy_outlined, size: 13, color: BrokaColors.neonPurple),
          SizedBox(width: 8),
          Expanded(child: Text(
            'AI Broker: "A bid above KES 12M is competitive. Reserve already met."',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11, height: 1.4))),
        ]),
      ),
    ]),
  );

  Widget _metric(String v, String l, Color? c) =>
    Expanded(child: Column(children: [
      Text(v, style: TextStyle(
        color: c ?? BrokaColors.textHigh,
        fontWeight: FontWeight.w800, fontSize: 14),
        textAlign: TextAlign.center),
      const SizedBox(height: 3),
      Text(l, style: const TextStyle(color: BrokaColors.textLow,
          fontSize: 9, letterSpacing: 0.8, fontWeight: FontWeight.w600),
          textAlign: TextAlign.center),
    ]));

  Widget _vDivider() => Container(
      width: 1, height: 32, color: BrokaColors.border,
      margin: const EdgeInsets.symmetric(horizontal: 8));

  Widget _buildBidInput() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: BrokaColors.cardGradColors),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('PLACE YOUR BID', style: TextStyle(color: BrokaColors.textLow,
          fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: TextField(
          controller: _bidCtrl,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: BrokaColors.neonPurple,
              fontWeight: FontWeight.w800, fontSize: 16),
          decoration: const InputDecoration(
            hintText: 'Enter amount (KES)',
            prefixText: 'KES ',
            prefixStyle: TextStyle(color: BrokaColors.textLow, fontSize: 13),
          ),
        )),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: _placingBid ? null : _placeBid,
          child: Container(
            width: 80, height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                  colors: [BrokaColors.gradStart, BrokaColors.gradMid]),
              boxShadow: const [BrokaColors.glowPurple],
            ),
            child: Center(child: _placingBid
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('BID', style: TextStyle(color: Colors.white,
                    fontWeight: FontWeight.w900, letterSpacing: 1))),
          ),
        ),
      ]),
      if (_bidError != null) ...[
        const SizedBox(height: 8),
        Text(_bidError!, style: const TextStyle(
            color: BrokaColors.danger, fontSize: 12)),
      ],
    ]),
  );

  Widget _buildLeaderboard() => Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('BID LEADERBOARD', style: TextStyle(color: BrokaColors.textLow,
        fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
    const SizedBox(height: 10),
    if (_loadingBids)
      const Center(child: Padding(padding: EdgeInsets.all(24),
        child: CircularProgressIndicator(
            strokeWidth: 1.5, color: BrokaColors.neonPurple)))
    else
      Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Column(children: List.generate(_bids.length, (i) {
          final b = _bids[i];
          final isTop = b.rank == 1;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              gradient: isTop ? LinearGradient(colors: [
                BrokaColors.gradStart.withOpacity(0.15),
                BrokaColors.gradMid.withOpacity(0.05),
              ]) : null,
              borderRadius: i == 0
                  ? const BorderRadius.vertical(top: Radius.circular(16))
                  : i == _bids.length - 1
                      ? const BorderRadius.vertical(bottom: Radius.circular(16))
                      : BorderRadius.zero,
              border: i < _bids.length - 1
                  ? const Border(bottom: BorderSide(color: BrokaColors.border))
                  : null,
            ),
            child: Row(children: [
              SizedBox(width: 32, child: Text('#${b.rank}', style: TextStyle(
                fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 0.5,
                color: isTop ? BrokaColors.neonPurple : BrokaColors.textLow))),
              Text(b.bidderName, style: const TextStyle(
                  color: BrokaColors.textHigh,
                  fontWeight: FontWeight.w600, fontSize: 13)),
              const Spacer(),
              ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                  colors: [BrokaColors.neonPurple, BrokaColors.neonBlue])
                    .createShader(r),
                child: Text(b.formattedAmount, style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800, fontSize: 13))),
              const SizedBox(width: 10),
              Text(b.timeAgo, style: const TextStyle(
                  color: BrokaColors.textLow, fontSize: 11)),
            ]),
          );
        })),
      ),
  ]);
}
