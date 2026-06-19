// BROKA - Seller Dashboard Screen
// Shows ratings, trust/reliability scores, listing analytics, Zeno tips, verification CTA.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../models/models.dart';

class SellerDashboardScreen extends StatefulWidget {
  const SellerDashboardScreen({super.key});
  @override
  State<SellerDashboardScreen> createState() => _SellerDashboardScreenState();
}

class _SellerDashboardScreenState extends State<SellerDashboardScreen> {
  Map<String, dynamic>? _profile;
  bool _loading = true;
  String? _zenoAnalysis;
  bool   _zenoLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uid = ApiService.currentUserId;
      if (uid != null) {
        final p = await ApiService.getUserProfile(uid);
        if (mounted) setState(() { _profile = p; _loading = false; });
        _loadZenoAnalysis();
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadZenoAnalysis() async {
    if (mounted) setState(() => _zenoLoading = true);
    try {
      final cat    = _profile?['main_category'] as String? ?? 'general goods';
      final deals  = _completedDeals;
      final views  = _totalViews;
      final rating = (_avgRating / 2).toStringAsFixed(1);
      final prompt = 'I am a seller on BROKA (Kenyan marketplace). '
          'My category: $cat. Completed deals: $deals. Profile views: $views. '
          'Rating: $rating/5. Give me exactly 3 sharp, Kenya-specific pricing tips '
          'to help me close more deals. Mention realistic KES ranges where helpful. '
          'Each tip: one sentence max. Format as a numbered list.';
      final reply = await ApiService.zenoChat(
        message: prompt,
        history: const [],
        language: ApiService.currentUserLanguage,
      );
      if (mounted) setState(() { _zenoAnalysis = reply; _zenoLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _zenoLoading = false);
    }
  }

  double get _reliability {
    final raw = (_profile?['reliability_score'] as num?)?.toDouble()
        ?? (_profile?['rating'] as num?)?.toDouble() ?? 5.0;
    // Convert from 5-scale to 10-scale if needed
    return raw <= 5.0 ? raw * 2 : raw.clamp(0.0, 10.0);
  }

  double get _trustScore {
    final raw = (_profile?['trust_score'] as num?)?.toDouble()
        ?? (_profile?['rating'] as num?)?.toDouble() ?? 5.0;
    return raw <= 5.0 ? raw * 2 : raw.clamp(0.0, 10.0);
  }

  double get _avgRating {
    final raw = (_profile?['rating'] as num?)?.toDouble() ?? 5.0;
    return raw <= 5.0 ? raw * 2 : raw.clamp(0.0, 10.0);
  }

  double get _responseRate =>
      (_profile?['response_rate'] as num?)?.toDouble() ?? 85.0;

  int get _completedDeals => (_profile?['completed_deals'] as num?)?.toInt() ?? 0;
  int get _totalViews => (_profile?['total_views'] as num?)?.toInt() ?? 0;
  int get _activeListings => (_profile?['active_listings'] as num?)?.toInt() ?? 0;
  bool get _isVerified => _profile?['is_verified'] as bool? ?? false;

  static const _zenoTips = [
    ('📸', 'Add 3+ clear photos', 'Listings with multiple photos get 4x more views on BROKA. Use natural lighting and show the item from multiple angles.'),
    ('💰', 'Price competitively', 'Research similar items in your area. Listings priced within 10% of market average close 2x faster.'),
    ('📍', 'Enable precise location', 'Buyers prefer sellers nearby. Accurate location increases your chances of completing a deal by 60%.'),
    ('⚡', 'Respond quickly', 'Sellers who respond within 1 hour close 3x more deals. Enable notifications to stay on top of offers.'),
    ('✅', 'Get verified', 'Verified sellers earn 40% more trust from buyers. Complete your verification to unlock the badge.'),
    ('📝', 'Write detailed descriptions', 'Include condition, age, reason for selling, and any defects. Transparency builds trust and reduces haggling.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: CustomScrollView(slivers: [
        _buildAppBar(),
        if (_loading)
          const SliverFillRemaining(child: Center(
              child: CircularProgressIndicator(color: BrokaColors.neonPurple)))
        else ...[
          SliverToBoxAdapter(child: Column(children: [
            _buildOverviewCards(),
            _buildRadarSection(),
            _buildViewsSection(),
            _buildLiveZenoAnalysis(),
            _buildZenoTips(),
            if (!_isVerified) _buildVerificationCTA(),
            _buildBoostCta(),
            _buildReceiptsButton(),
            const SizedBox(height: 40),
          ])),
        ],
      ]),
    );
  }

  Widget _buildAppBar() => SliverAppBar(
    backgroundColor: BrokaColors.bgMid,
    pinned: true,
    expandedHeight: 0,
    leading: GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BrokaColors.border),
        ),
        child: const Icon(Icons.arrow_back_ios_new_rounded,
            color: BrokaColors.textMid, size: 16),
      ),
    ),
    title: const Text('Seller Dashboard',
        style: TextStyle(color: BrokaColors.textHigh,
            fontSize: 16, fontWeight: FontWeight.w800)),
    actions: [
      Container(
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [BrokaColors.gradStart, BrokaColors.gradMid]),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text('Analytics', style: TextStyle(
            color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
      ),
    ],
  );

  // ── Overview Cards ──────────────────────────────────────────────────────────

  Widget _buildOverviewCards() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('OVERVIEW', style: TextStyle(
          color: BrokaColors.textLow, fontSize: 10,
          fontWeight: FontWeight.w700, letterSpacing: 1.2)),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _overviewCard('${_activeListings}', 'Active Listings',
            Icons.store_rounded, BrokaColors.neonPurple)),
        const SizedBox(width: 10),
        Expanded(child: _overviewCard('${_completedDeals}', 'Deals Done',
            Icons.handshake_rounded, BrokaColors.neonGreen)),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _overviewCard('${_totalViews}', 'Total Views',
            Icons.visibility_rounded, BrokaColors.neonBlue)),
        const SizedBox(width: 10),
        Expanded(child: _overviewCard('${_responseRate.toStringAsFixed(0)}%',
            'Response Rate', Icons.speed_rounded, BrokaColors.gold)),
      ]),
    ]),
  );

  Widget _overviewCard(String value, String label, IconData icon, Color color) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(height: 10),
          Text(value, style: TextStyle(
              color: color, fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 12)),
        ]),
      );

  // ── Radar / Score Section ───────────────────────────────────────────────────

  Widget _buildRadarSection() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('TRUST & PERFORMANCE SCORES', style: TextStyle(
          color: BrokaColors.textLow, fontSize: 10,
          fontWeight: FontWeight.w700, letterSpacing: 1.2)),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Column(children: [
          SizedBox(
            height: 220,
            child: CustomPaint(
              painter: _RadarChartPainter(
                values: [
                  _reliability / 10,
                  _trustScore / 10,
                  _avgRating / 10,
                  _responseRate / 100,
                  (_completedDeals / math.max(_completedDeals + 2, 10)).clamp(0.0, 1.0),
                ],
                labels: ['Reliability', 'Trust', 'Rating', 'Response', 'Deals'],
                colors: [
                  BrokaColors.neonPurple,
                  BrokaColors.neonBlue,
                  BrokaColors.gold,
                  BrokaColors.neonGreen,
                  BrokaColors.neonCyan,
                ],
              ),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _scorePill('Reliability', _reliability, BrokaColors.neonPurple),
            _scorePill('Trust', _trustScore, BrokaColors.neonBlue),
            _scorePill('Avg Rating', _avgRating, BrokaColors.gold),
          ]),
        ]),
      ),
    ]),
  );

  Widget _scorePill(String label, double value, Color color) => Column(children: [
    Text(value.toStringAsFixed(1), style: TextStyle(
        color: color, fontSize: 22, fontWeight: FontWeight.w800)),
    const SizedBox(height: 2),
    Text('/10', style: const TextStyle(color: BrokaColors.textLow, fontSize: 10)),
    const SizedBox(height: 4),
    Text(label, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
  ]);

  // ── Listing Views Chart ─────────────────────────────────────────────────────

  Widget _buildViewsSection() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('LISTING PERFORMANCE', style: TextStyle(
          color: BrokaColors.textLow, fontSize: 10,
          fontWeight: FontWeight.w700, letterSpacing: 1.2)),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Column(children: [
          Row(children: [
            const Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Views This Week', style: TextStyle(
                  color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
              SizedBox(height: 2),
              Text('Compared to market average', style: TextStyle(
                  color: BrokaColors.textMid, fontSize: 11)),
            ])),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: BrokaColors.neonGreen.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.4)),
              ),
              child: const Text('+12% vs avg', style: TextStyle(
                  color: BrokaColors.neonGreen, fontSize: 11,
                  fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 20),
          SizedBox(
            height: 100,
            child: CustomPaint(
              painter: _BarChartPainter(
                values: const [0.4, 0.6, 0.5, 0.8, 0.7, 0.9, 0.75],
                labels: const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
                color: BrokaColors.neonPurple,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 16),
          _priceCompRow(),
        ]),
      ),
    ]),
  );

  Widget _priceCompRow() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: BrokaColors.bg,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Column(children: [
      Row(children: [
        const Icon(Icons.compare_arrows_rounded,
            color: BrokaColors.neonBlue, size: 16),
        const SizedBox(width: 8),
        const Text('Price vs Market',
            style: TextStyle(color: BrokaColors.textHigh,
                fontWeight: FontWeight.w700, fontSize: 13)),
      ]),
      const SizedBox(height: 10),
      _priceCompBar('Your Avg Price', 0.72, BrokaColors.neonPurple, 'KES 45K'),
      const SizedBox(height: 8),
      _priceCompBar('Market Avg', 0.65, BrokaColors.textMid, 'KES 38K'),
    ]),
  );

  Widget _priceCompBar(String label, double pct, Color color, String amt) =>
      Row(children: [
        SizedBox(width: 90,
            child: Text(label, style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 11))),
        Expanded(child: Stack(children: [
          Container(height: 8, decoration: BoxDecoration(
              color: BrokaColors.bgMid,
              borderRadius: BorderRadius.circular(4))),
          FractionallySizedBox(
            widthFactor: pct,
            child: Container(height: 8, decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(4))),
          ),
        ])),
        const SizedBox(width: 8),
        Text(amt, style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w700)),
      ]);

  // ── Zeno Tips ───────────────────────────────────────────────────────────────

  Widget _buildLiveZenoAnalysis() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            BrokaColors.neonPurple.withOpacity(0.12),
            BrokaColors.neonBlue.withOpacity(0.08),
          ],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text('⚡ ZENO LIVE ANALYSIS',
                style: TextStyle(color: Colors.white,
                    fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
          ),
          const Spacer(),
          if (_zenoLoading)
            const SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: BrokaColors.neonPurple))
          else
            GestureDetector(
              onTap: _loadZenoAnalysis,
              child: const Icon(Icons.refresh_rounded,
                  size: 16, color: BrokaColors.neonPurple),
            ),
        ]),
        const SizedBox(height: 10),
        if (_zenoLoading && _zenoAnalysis == null)
          const Text('Zeno is analysing your listings…',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 12,
                  fontStyle: FontStyle.italic))
        else if (_zenoAnalysis != null)
          Text(_zenoAnalysis!,
              style: const TextStyle(color: BrokaColors.textHigh,
                  fontSize: 12.5, height: 1.6))
        else
          const Text('Tap ↻ to get personalised pricing tips from Zeno.',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
      ]),
    ),
  );

  Widget _buildZenoTips() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 28, height: 28,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
                colors: [BrokaColors.gradStart, BrokaColors.neonBlue]),
          ),
          child: const Icon(Icons.auto_awesome_rounded,
              color: Colors.white, size: 14),
        ),
        const SizedBox(width: 8),
        const Text('ZENO MARKETING TIPS', style: TextStyle(
            color: BrokaColors.textLow, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 1.2)),
      ]),
      const SizedBox(height: 12),
      ..._zenoTips.map((t) => _tipCard(t.$1, t.$2, t.$3)),
    ]),
  );

  Widget _buildReceiptsButton() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/receipt-history'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF00B300).withOpacity(0.35)),
        ),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF00B300).withOpacity(0.12),
              border: Border.all(
                  color: const Color(0xFF00B300).withOpacity(0.4)),
            ),
            child: const Icon(Icons.receipt_long_outlined,
                color: Color(0xFF00B300), size: 20),
          ),
          const SizedBox(width: 14),
          const Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Payment Receipts', style: TextStyle(
                color: BrokaColors.textHigh,
                fontWeight: FontWeight.w700, fontSize: 14)),
            SizedBox(height: 2),
            Text('View all completed M-Pesa transactions',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
          ])),
          const Icon(Icons.chevron_right_rounded,
              color: BrokaColors.textLow, size: 20),
        ]),
      ),
    ),
  );

  Widget _tipCard(String emoji, String title, String body) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
          colors: BrokaColors.cardGradColors,
          begin: Alignment.topLeft, end: Alignment.bottomRight),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(emoji, style: const TextStyle(fontSize: 24)),
      const SizedBox(width: 12),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: BrokaColors.textHigh,
            fontWeight: FontWeight.w700, fontSize: 13)),
        const SizedBox(height: 4),
        Text(body, style: const TextStyle(color: BrokaColors.textMid,
            fontSize: 12, height: 1.5)),
      ])),
    ]),
  );

  // ── Verification CTA ────────────────────────────────────────────────────────

  Widget _buildVerificationCTA() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          BrokaColors.gold.withOpacity(0.15),
          BrokaColors.gradStart.withOpacity(0.2),
        ]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.5)),
        boxShadow: [BoxShadow(
            color: BrokaColors.gold.withOpacity(0.1),
            blurRadius: 20, spreadRadius: 2)],
      ),
      child: Column(children: [
        Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: BrokaColors.gold.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.verified_rounded,
                color: BrokaColors.gold, size: 24),
          ),
          const SizedBox(width: 14),
          const Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Get Verified Badge', style: TextStyle(
                color: BrokaColors.textHigh, fontSize: 16,
                fontWeight: FontWeight.w800)),
            SizedBox(height: 3),
            Text('Boost buyer trust by 40%', style: TextStyle(
                color: BrokaColors.textMid, fontSize: 12)),
          ])),
        ]),
        const SizedBox(height: 16),
        const Text(
          'Verified sellers earn significantly more trust from buyers. Complete your ID verification to unlock the gold badge and close more deals.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 16),
        Row(children: [
          _benefitChip('✓ Higher visibility'),
          const SizedBox(width: 8),
          _benefitChip('✓ Trust badge'),
          const SizedBox(width: 8),
          _benefitChip('✓ Priority listing'),
        ]),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, '/verification').then((_) => _load()),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [BrokaColors.gold, Color(0xFFF59E0B)]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(
                  color: BrokaColors.gold.withOpacity(0.3), blurRadius: 12)],
            ),
            child: const Center(child: Text('Start Verification',
                style: TextStyle(color: Colors.black87,
                    fontWeight: FontWeight.w800, fontSize: 14))),
          ),
        ),
      ]),
    ),
  );

  Widget _buildBoostCta() => Container(
    margin: const EdgeInsets.only(top: 20),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: [
        BrokaColors.neonPurple.withOpacity(0.12),
        BrokaColors.neonBlue.withOpacity(0.08),
      ]),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.4)),
      boxShadow: [BoxShadow(
          color: BrokaColors.neonPurple.withOpacity(0.08),
          blurRadius: 20, spreadRadius: 2)],
    ),
    child: Column(children: [
      Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: BrokaColors.neonPurple.withOpacity(0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.rocket_launch_rounded,
              color: BrokaColors.neonPurple, size: 24),
        ),
        const SizedBox(width: 14),
        const Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Boost a Listing', style: TextStyle(
              color: BrokaColors.textHigh, fontSize: 16,
              fontWeight: FontWeight.w800)),
          SizedBox(height: 3),
          Text('Pin to the top of the feed', style: TextStyle(
              color: BrokaColors.textMid, fontSize: 12)),
        ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: BrokaColors.neonPurple.withOpacity(0.15),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text('From KES 99',
              style: TextStyle(color: BrokaColors.neonPurple,
                  fontSize: 10, fontWeight: FontWeight.w800)),
        ),
      ]),
      const SizedBox(height: 14),
      const Text(
        'Featured listings appear first in the home feed with a glowing badge - '
        'seen by every buyer browsing your category. Get 5× more views.',
        style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.5),
      ),
      const SizedBox(height: 16),
      GestureDetector(
        onTap: () => Navigator.pushNamed(context, '/boost-listing'),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(
                color: BrokaColors.neonPurple.withOpacity(0.35), blurRadius: 12)],
          ),
          child: const Center(child: Row(
            mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.rocket_launch_rounded, color: Colors.white, size: 16),
            SizedBox(width: 8),
            Text('Boost a Listing',
                style: TextStyle(color: Colors.white,
                    fontWeight: FontWeight.w800, fontSize: 14)),
          ])),
        ),
      ),
    ]),
  );

  Widget _benefitChip(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: BrokaColors.gold.withOpacity(0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: BrokaColors.gold.withOpacity(0.3)),
    ),
    child: Text(label, style: const TextStyle(
        color: BrokaColors.gold, fontSize: 10, fontWeight: FontWeight.w700)),
  );
}

// ── Radar Chart Painter ─────────────────────────────────────────────────────
class _RadarChartPainter extends CustomPainter {
  final List<double> values;   // 0.0 - 1.0
  final List<String> labels;
  final List<Color> colors;

  _RadarChartPainter({
    required this.values,
    required this.labels,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r  = math.min(cx, cy) - 28;
    final n  = values.length;

    // Grid rings
    for (int ring = 1; ring <= 4; ring++) {
      final rr = r * ring / 4;
      final pts = <Offset>[];
      for (int i = 0; i < n; i++) {
        final angle = 2 * math.pi * i / n - math.pi / 2;
        pts.add(Offset(cx + rr * math.cos(angle), cy + rr * math.sin(angle)));
      }
      final path = Path()..moveTo(pts[0].dx, pts[0].dy);
      for (int i = 1; i < pts.length; i++) path.lineTo(pts[i].dx, pts[i].dy);
      path.close();
      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..color = BrokaColors.border
        ..strokeWidth = 0.8);
    }

    // Axes
    for (int i = 0; i < n; i++) {
      final angle = 2 * math.pi * i / n - math.pi / 2;
      canvas.drawLine(
        Offset(cx, cy),
        Offset(cx + r * math.cos(angle), cy + r * math.sin(angle)),
        Paint()..color = BrokaColors.border..strokeWidth = 0.8,
      );
    }

    // Data polygon
    final dataPath = Path();
    for (int i = 0; i < n; i++) {
      final angle = 2 * math.pi * i / n - math.pi / 2;
      final rv = r * values[i];
      final pt = Offset(cx + rv * math.cos(angle), cy + rv * math.sin(angle));
      if (i == 0) dataPath.moveTo(pt.dx, pt.dy);
      else dataPath.lineTo(pt.dx, pt.dy);
    }
    dataPath.close();

    canvas.drawPath(dataPath, Paint()
      ..style = PaintingStyle.fill
      ..color = BrokaColors.neonPurple.withOpacity(0.2));
    canvas.drawPath(dataPath, Paint()
      ..style = PaintingStyle.stroke
      ..color = BrokaColors.neonPurple
      ..strokeWidth = 2.0);

    // Data points
    for (int i = 0; i < n; i++) {
      final angle = 2 * math.pi * i / n - math.pi / 2;
      final rv = r * values[i];
      final pt = Offset(cx + rv * math.cos(angle), cy + rv * math.sin(angle));
      canvas.drawCircle(pt, 4, Paint()..color = colors[i % colors.length]);
    }

    // Labels
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i < n; i++) {
      final angle = 2 * math.pi * i / n - math.pi / 2;
      final lx = cx + (r + 22) * math.cos(angle);
      final ly = cy + (r + 22) * math.sin(angle);
      tp.text = TextSpan(
        text: '${labels[i]}\n${(values[i] * 10).toStringAsFixed(1)}',
        style: TextStyle(
          color: colors[i % colors.length],
          fontSize: 9, fontWeight: FontWeight.w700,
        ),
      );
      tp.layout();
      tp.paint(canvas, Offset(lx - tp.width / 2, ly - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_RadarChartPainter old) => true;
}

// ── Bar Chart Painter ───────────────────────────────────────────────────────
class _BarChartPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  final Color color;

  _BarChartPainter({
    required this.values,
    required this.labels,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = values.length;
    final barW = (size.width - (n - 1) * 6) / n;
    final tp = TextPainter(textDirection: TextDirection.ltr);

    for (int i = 0; i < n; i++) {
      final left = i * (barW + 6);
      final barH = (size.height - 20) * values[i];
      final top  = size.height - 20 - barH;

      final rr = RRect.fromRectAndCorners(
        Rect.fromLTWH(left, top, barW, barH),
        topLeft: const Radius.circular(4), topRight: const Radius.circular(4),
      );

      canvas.drawRRect(rr, Paint()
        ..shader = LinearGradient(colors: [
          color.withOpacity(0.9), color.withOpacity(0.4),
        ], begin: Alignment.topCenter, end: Alignment.bottomCenter)
            .createShader(Rect.fromLTWH(left, top, barW, barH)));

      tp.text = TextSpan(text: labels[i],
          style: const TextStyle(color: BrokaColors.textLow, fontSize: 9));
      tp.layout();
      tp.paint(canvas, Offset(
          left + barW / 2 - tp.width / 2, size.height - 14));
    }
  }

  @override
  bool shouldRepaint(_BarChartPainter old) => false;
}
