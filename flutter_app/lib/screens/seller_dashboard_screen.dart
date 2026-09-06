// BROKA — Seller Analytics Command Centre v4.0
// Futuristic UI: radial gauges · glow revenue chart · deal pipeline · Zeno insight cards · revenue calc
// All v3 features preserved: radar, HexTrustBadge, per-product views/day + week, Zeno pricing,
// deal status pills, platform escrow CTAs, featured upsell, verification, M-Pesa receipts.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../widgets/particle_field.dart';
import '../models/listing.dart';
import '../models/models.dart';

class SellerDashboardScreen extends StatefulWidget {
  const SellerDashboardScreen({super.key});
  @override
  State<SellerDashboardScreen> createState() => _SellerDashboardScreenState();
}

class _SellerDashboardScreenState extends State<SellerDashboardScreen>
    with TickerProviderStateMixin {

  // ── Core state ──────────────────────────────────────────────────────────────
  Map<String, dynamic>? _profile;
  List<Listing>         _listings = [];
  bool                  _loading  = true;
  String?               _zenoGlobal;
  bool                  _zenoGlobalLoading = false;

  late final TabController       _tabs;
  late final AnimationController _glow;
  late final AnimationController _pulse;

  // ── Per-listing state ────────────────────────────────────────────────────────
  final Map<String, bool>                  _expanded           = {};
  final Map<String, String?>               _listingZeno        = {};
  final Map<String, bool>                  _listingZenoLoading = {};
  final Map<String, Map<String, dynamic>?> _dealStatusMap      = {};
  final Map<String, Map<String, dynamic>?> _boostStatusMap     = {};
  bool                                     _dealsTabLoaded     = false;

  // ── Overview UI state ────────────────────────────────────────────────────────
  bool _revenueWeekMode = true;

  // ── Revenue calculator ───────────────────────────────────────────────────────
  double _calcAvgPrice = 49.99;
  double _calcVolume   = 1200;
  double _calcConvRate = 3.2;
  double _calcMargin   = 30.0;
  double _calcAcqCost  = 5.0;
  bool   _calcDone     = false;

  late final TextEditingController _avgPriceCtrl =
      TextEditingController(text: _calcAvgPrice.toStringAsFixed(2));
  late final TextEditingController _volumeCtrl =
      TextEditingController(text: _calcVolume.toStringAsFixed(0));
  late final TextEditingController _acqCostCtrl =
      TextEditingController(text: _calcAcqCost.toStringAsFixed(2));

  double get _calcUnits       => _calcVolume * (_calcConvRate / 100);
  double get _calcTotalRev    => _calcUnits * _calcAvgPrice;
  double get _calcTotalCost   => _calcUnits * _calcAcqCost + _calcTotalRev * (1 - _calcMargin / 100);
  double get _calcGrossProfit => _calcTotalRev - _calcUnits * _calcAcqCost;
  double get _calcNetRevenue  => _calcTotalRev - _calcTotalCost;

  // ── Constants ────────────────────────────────────────────────────────────────
  static const _days       = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  static const _weekLabels = ['W-5','W-4','W-3','W-2','W-1','Now'];

  static const _staticTips = [
    ('📸','Add 3+ clear photos','Listings with multiple photos get 4x more views. Use natural lighting and show every angle.'),
    ('💰','Price competitively','Within 10% of market average closes 2x faster. Check Zeno pricing above for KES ranges.'),
    ('📍','Enable precise location','Buyers prefer sellers nearby. Accurate GPS boosts deal chances by 60%.'),
    ('⚡','Reply within 1 hour','Sellers who respond fast close 3x more deals. Keep notifications on.'),
    ('✅','Get verified','Verified sellers earn 40% more buyer trust and appear higher in search.'),
    ('📝','Write detailed descriptions','State condition, age, and any defects. Transparency cuts haggling time in half.'),
  ];

  // ── Lifecycle ────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging && _tabs.index == 2 && !_dealsTabLoaded) {
        _dealsTabLoaded = true;
        for (final l in _listings) { _loadDealStatus(l.id); _loadBoostStatus(l.id); }
      }
    });
    _glow  = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose(); _glow.dispose(); _pulse.dispose();
    _avgPriceCtrl.dispose(); _volumeCtrl.dispose(); _acqCostCtrl.dispose();
    super.dispose();
  }

  // ── Data loaders ─────────────────────────────────────────────────────────────
  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _dealsTabLoaded = false; });
    try {
      final uid = ApiService.currentUserId;
      if (uid == null) { if (mounted) setState(() => _loading = false); return; }
      final profile  = await ApiService.getUserProfile(uid);
      final listings = await ApiService.getListings(sellerId: uid, limit: 50);
      if (!mounted) return;
      setState(() { _profile = profile; _listings = listings; _loading = false; });
      _loadZenoGlobal();
      _loadRevenue();
      final preload = math.min(5, listings.length);
      for (int i = 0; i < preload; i++) {
        _loadDealStatus(listings[i].id);
        _loadBoostStatus(listings[i].id);
      }
    } catch (_) { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _loadZenoGlobal() async {
    if (mounted) setState(() => _zenoGlobalLoading = true);
    try {
      final cat    = _profile?['main_category'] as String? ?? 'general goods';
      final rating = (_avgRating / 2).toStringAsFixed(1);
      final dcrLine = _dcrScore != null
          ? ' Completion rate through BROKA: ${_dcrScore!.toStringAsFixed(0)}%.'
          : '';
      final reply  = await ApiService.zenoChat(
        message: 'I sell $cat on BROKA (Kenya). '
            'Completed deals: $_completedDeals. Total views: $_totalViews. '
            'Rating: $rating/5. Active products: ${_listings.length}.$dcrLine '
            'Give 3 sharp, specific tips - a mix of Kenya-specific pricing '
            'advice and, if my completion rate has room to improve, one tip '
            'framed as a visibility opportunity. KES ranges where helpful. '
            'One sentence each. Numbered list.',
        history: const [], language: ApiService.currentUserLanguage,
        systemOverride: 'zeno_seller_coach');
      if (mounted) setState(() { _zenoGlobal = reply; _zenoGlobalLoading = false; });
    } catch (_) { if (mounted) setState(() => _zenoGlobalLoading = false); }
  }

  Future<void> _loadZenoForListing(Listing l) async {
    if (_listingZeno.containsKey(l.id)) return;
    if (mounted) setState(() => _listingZenoLoading[l.id] = true);
    try {
      final reply = await ApiService.zenoChat(
        message: 'Kenyan BROKA seller. Product: ${l.name}. '
            'Category: ${l.category}. Price: KES ${l.price.toStringAsFixed(0)}. '
            'Views: ${l.views}. Give 2 specific pricing recommendations with KES ranges. '
            'One sentence each. Numbered list.',
        history: const [], language: ApiService.currentUserLanguage);
      if (mounted) setState(() { _listingZeno[l.id] = reply; _listingZenoLoading[l.id] = false; });
    } catch (_) { if (mounted) setState(() => _listingZenoLoading[l.id] = false); }
  }

  Future<void> _loadDealStatus(String id) async {
    try {
      final r = await ApiService.getDealStatus(id);
      if (mounted) setState(() => _dealStatusMap[id] = r);
    } catch (_) { if (mounted) setState(() => _dealStatusMap[id] = null); }
  }

  Future<void> _loadBoostStatus(String id) async {
    try {
      final r = await ApiService.checkBoostStatus(id);
      if (mounted) setState(() => _boostStatusMap[id] = r);
    } catch (_) { if (mounted) setState(() => _boostStatusMap[id] = null); }
  }

  // ── Computed props ───────────────────────────────────────────────────────────
  double _toTen(num? v) { final d = v?.toDouble() ?? 5.0; return (d <= 5 ? d*2 : d).clamp(0,10); }
  double get _reliability  => _toTen(_profile?['reliability_score'] ?? _profile?['rating']);
  double get _trustScore   => _toTen(_profile?['trust_score']       ?? _profile?['rating']);
  double get _avgRating    => _toTen(_profile?['rating']);
  double get _responseRate => (_profile?['response_rate'] as num?)?.toDouble() ?? 85.0;
  int    get _completedDeals => (_profile?['completed_deals'] as num?)?.toInt() ?? 0;
  int    get _totalViews   => _listings.isEmpty
      ? ((_profile?['total_views'] as num?)?.toInt() ?? 0)
      : _listings.fold(0, (s, l) => s + l.views);
  bool   get _isVerified   => _profile?['is_verified'] as bool? ?? false;
  int    get _activeCount  => _listings.where((l) => l.status.toLowerCase() == 'active').length;
  int    get _featuredCount => _listings.where((l) => l.isFeatured).length;

  // ── Pipeline counts ──────────────────────────────────────────────────────────
  int get _pipeListed => _listings.length;
  int get _pipeNeg    => _listings.where((l) {
    final raw = ((_dealStatusMap[l.id]?['deal_status'] ?? _dealStatusMap[l.id]?['status'] ?? '') as Object)
        .toString().toLowerCase();
    return raw.contains('pending') && !raw.contains('funded') && !raw.contains('escrow');
  }).length;
  int get _pipeEscrow => _listings.where((l) {
    final raw = ((_dealStatusMap[l.id]?['deal_status'] ?? _dealStatusMap[l.id]?['status'] ?? '') as Object)
        .toString().toLowerCase();
    return raw.contains('funded') || raw.contains('escrow') || raw.contains('pending_delivery');
  }).length;
  int get _pipeDone   => _completedDeals;

  // ── Revenue chart data (real, from completed deals) ──────────────────────────
  List<double>? _revenueWeekReal;
  List<double>? _revenueMonthReal;
  bool _revenueHasRealData = false;
  bool _revenueLoading = true;

  List<double> get _revenueData {
    final real = _revenueWeekMode ? _revenueWeekReal : _revenueMonthReal;
    if (real != null) return real;
    return List.filled(_revenueWeekMode ? 7 : 6, 0.0);
  }

  Future<void> _loadRevenue() async {
    final uid = ApiService.currentUserId;
    if (uid == null) { if (mounted) setState(() => _revenueLoading = false); return; }
    if (mounted) setState(() => _revenueLoading = true);
    try {
      final week = await ApiService.getSellerRevenue(uid, period: 'week');
      final month = await ApiService.getSellerRevenue(uid, period: 'month');
      if (!mounted) return;
      setState(() {
        _revenueWeekReal  = (week['values'] as List).map((v) => (v as num).toDouble()).toList();
        _revenueMonthReal = (month['values'] as List).map((v) => (v as num).toDouble()).toList();
        _revenueHasRealData =
            (week['has_real_data'] as bool? ?? false) || (month['has_real_data'] as bool? ?? false);
        _revenueLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _revenueLoading = false);
    }
  }

  // ── Deal helpers ─────────────────────────────────────────────────────────────
  String   _dealLabel(Listing l) {
    final ls  = l.status.toLowerCase();
    if (ls == 'sold' || ls == 'completed') return 'Complete';
    final raw = (((_dealStatusMap[l.id]?['deal_status'] ??
                   _dealStatusMap[l.id]?['status']) ?? '') as Object).toString().toLowerCase();
    if (raw.contains('funded') || raw.contains('escrow') || raw.contains('pending_delivery'))
      return 'In Escrow';
    if (raw.contains('pending'))   return 'Pending';
    if (raw.contains('completed')) return 'Complete';
    if (ls == 'pending')           return 'Pending';
    return 'Active';
  }
  Color    _dealColour(String s) => switch (s) {
    'Complete'  => BrokaColors.neonGreen,
    'In Escrow' => BrokaColors.neonBlue,
    'Pending'   => BrokaColors.warning,
    _           => BrokaColors.gold,
  };
  IconData _dealIcon(String s) => switch (s) {
    'Complete'  => Icons.check_circle_rounded,
    'In Escrow' => Icons.lock_rounded,
    'Pending'   => Icons.hourglass_bottom_rounded,
    _           => Icons.store_rounded,
  };

  // ── Utility ──────────────────────────────────────────────────────────────────
  String _fmt(int n)      => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}K' : '$n';
  String _kes(double v)   => 'KES ${v.toStringAsFixed(2)}';
  String _timeAgo(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inDays > 30) return '${diff.inDays ~/ 30}mo ago';
    if (diff.inDays >  0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    return 'just now';
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ROOT BUILD
  // ════════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BrokaColors.bg,
    appBar: _buildAppBar(),
    body: _loading ? _buildLoadingShimmer()
        : TabBarView(
            controller: _tabs,
            children: [_buildOverviewTab(), _buildProductsTab(), _buildDealsTab()],
          ),
  );

  PreferredSizeWidget _buildAppBar() => AppBar(
    backgroundColor: BrokaColors.bgMid,
    elevation: 0,
    leading: GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BrokaColors.border)),
        child: const Icon(Icons.arrow_back_ios_new_rounded, color: BrokaColors.textMid, size: 16)),
    ),
    title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
      children: [
        const Text('BROKA', style: TextStyle(
            color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 1.6)),
        Text('SELLER 4.0', style: TextStyle(
            color: BrokaColors.gold.withOpacity(0.85),
            fontSize: 8.5, fontWeight: FontWeight.w700, letterSpacing: 3.0)),
      ]),
    actions: [
      // ── Live status pulse ────────────────────────────────────────────────────
      AnimatedBuilder(
        animation: _pulse,
        builder: (_, __) => Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: BrokaColors.neonGreen.withOpacity(0.09 + 0.05 * _pulse.value),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: BrokaColors.neonGreen.withOpacity(0.30 + 0.18 * _pulse.value))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 6, height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: BrokaColors.neonGreen,
                boxShadow: [BoxShadow(
                  color: BrokaColors.neonGreen.withOpacity(0.55 + 0.35 * _pulse.value),
                  blurRadius: 7 + 4 * _pulse.value)])),
            const SizedBox(width: 5),
            const Text('LIVE', style: TextStyle(
                color: BrokaColors.neonGreen, fontSize: 8,
                fontWeight: FontWeight.w800, letterSpacing: 1.2)),
          ]),
        ),
      ),
      GestureDetector(
        onTap: _load,
        child: Container(
          margin: const EdgeInsets.only(right: 12, left: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim]),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.28), blurRadius: 10)]),
          child: const Text('↻ Sync',
              style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700))),
      ),
    ],
    bottom: TabBar(
      controller: _tabs,
      indicatorColor: BrokaColors.gold,
      indicatorWeight: 2.5,
      labelColor: BrokaColors.gold,
      unselectedLabelColor: BrokaColors.textMid,
      labelStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.1),
      unselectedLabelStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
      dividerColor: BrokaColors.border,
      tabs: const [Tab(text: 'OVERVIEW'), Tab(text: 'PRODUCTS'), Tab(text: 'DEALS')],
    ),
  );

  Widget _buildLoadingShimmer() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    SizedBox(width: 56, height: 56, child: Stack(alignment: Alignment.center, children: [
      const CircularProgressIndicator(
          color: BrokaColors.gold, strokeWidth: 2.5, strokeCap: StrokeCap.round),
      Container(width: 36, height: 36,
        decoration: const BoxDecoration(shape: BoxShape.circle,
            gradient: LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue])),
        child: const Icon(Icons.insights_rounded, color: Colors.white, size: 18)),
    ])),
    const SizedBox(height: 16),
    const Text('Loading command centre…',
        style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
  ]));

  // ════════════════════════════════════════════════════════════════════════════
  // TAB 0 — OVERVIEW
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildOverviewTab() => SingleChildScrollView(
    padding: const EdgeInsets.only(bottom: 56),
    child: Column(children: [
      _buildCommandHeader(),
      _buildRadialStatCards(),
      _buildRevenueChart(),
      _buildDealPipeline(),
      _buildZenoInsightCards(),
      _buildLiveZenoAnalysis(),
      _buildRadarSection(),
      _buildRevenueCalculator(),
      if (!_isVerified) _buildVerificationCTA(),
      _buildBoostCta(),
      _buildReceiptsButton(),
      const SizedBox(height: 8),
    ]),
  );

  // ── Command header ────────────────────────────────────────────────────────────
  Widget _buildCommandHeader() => AnimatedBuilder(
    animation: _glow,
    builder: (_, __) => Container(
      margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          BrokaColors.gold.withOpacity(0.13),
          BrokaColors.neonBlue.withOpacity(0.07),
          BrokaColors.bg,
        ], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: BrokaColors.gold.withOpacity(0.25 + 0.08 * _glow.value), width: 1.5),
        boxShadow: [BoxShadow(
            color: BrokaColors.gold.withOpacity(0.06 + 0.04 * _glow.value),
            blurRadius: 28, spreadRadius: 2)]),
      child: Column(children: [
        Row(children: [
          Container(width: 52, height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              boxShadow: [BoxShadow(
                  color: BrokaColors.gold.withOpacity(0.30 + 0.18 * _glow.value),
                  blurRadius: 18 + 10 * _glow.value)]),
            child: const Icon(Icons.insights_rounded, color: Colors.white, size: 26)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ApiService.currentUserName ?? 'Your Store',
              style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 5),
            Row(children: [
              if (_isVerified) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: BrokaColors.neonGreen.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.35))),
                  child: const Row(children: [
                    Icon(Icons.verified_rounded, color: BrokaColors.neonGreen, size: 11),
                    SizedBox(width: 4),
                    Text('VERIFIED', style: TextStyle(
                        color: BrokaColors.neonGreen, fontSize: 9,
                        fontWeight: FontWeight.w800, letterSpacing: 1)),
                  ])),
                const SizedBox(width: 8),
              ],
              const Text('BROKA SELLER',
                  style: TextStyle(color: BrokaColors.textLow, fontSize: 10, letterSpacing: 1.4)),
            ]),
          ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${_listings.length}', style: const TextStyle(
                color: BrokaColors.gold, fontSize: 34, fontWeight: FontWeight.w900,
                height: 1.0, fontFamily: 'monospace')),
            const Text('PRODUCTS', style: TextStyle(
                color: BrokaColors.textLow, fontSize: 8, letterSpacing: 1.6)),
          ]),
        ]),
        const SizedBox(height: 18),
        Container(height: 1, color: BrokaColors.border),
        const SizedBox(height: 14),
        Row(children: [
          _miniStat(_fmt(_totalViews),          'Total Views', BrokaColors.neonBlue),
          _vDivider(),
          _miniStat('$_completedDeals',         'Deals Done',  BrokaColors.neonGreen),
          _vDivider(),
          _miniStat('$_featuredCount',          'Featured',    BrokaColors.neonCyan),
          _vDivider(),
          _miniStat('${_responseRate.toInt()}%','Response',    BrokaColors.gold),
        ]),
        if (_dcrScore != null) ...[
          const SizedBox(height: 14),
          Container(height: 1, color: BrokaColors.border),
          const SizedBox(height: 14),
          _buildDcrRow(),
        ],
      ]),
    ),
  );

  // Volume 2 §3.6: "framed the way ... every metric ... - as something that
  // explains itself, not a mysterious score." Copy here is a simple static
  // high/low split, not the fully Zeno-narrated, position-aware version the
  // doc's own example shows ("move you from position #14 to the top 5") -
  // that needs a live per-category rank position this pass doesn't compute,
  // and the doc explicitly defers exact tone/language to Chapter 5.
  double? get _dcrScore  => (_profile?['dcr_score'] as num?)?.toDouble();
  bool    get _dcrIsGood => (_dcrScore ?? 0) >= 70;

  Widget _buildDcrRow() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(_dcrIsGood ? Icons.verified_outlined : Icons.trending_up,
          size: 18, color: _dcrIsGood ? BrokaColors.neonGreen : BrokaColors.gold),
      const SizedBox(width: 8),
      Expanded(
        child: RichText(
          text: TextSpan(
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4),
            children: [
              const TextSpan(text: 'You complete '),
              TextSpan(
                text: '${_dcrScore!.toStringAsFixed(0)}%',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: _dcrIsGood ? BrokaColors.neonGreen : BrokaColors.gold,
                ),
              ),
              TextSpan(
                text: _dcrIsGood
                    ? ' of your deals through BROKA — a strong track record buyers can see.'
                    : ' of your deals through BROKA. Completing more deals on-platform helps your listings rank higher in search.',
              ),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _miniStat(String v, String l, Color c) => Expanded(child: Column(children: [
    Text(v, style: TextStyle(color: c, fontSize: 15, fontWeight: FontWeight.w800)),
    const SizedBox(height: 2),
    Text(l, style: const TextStyle(color: BrokaColors.textLow, fontSize: 8, letterSpacing: 0.8)),
  ]));

  Widget _vDivider() => Container(width: 1, height: 28, color: BrokaColors.border);

  // ── Radial Gauge Stat Cards ───────────────────────────────────────────────────
  Widget _buildRadialStatCards() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _secLabel('LIVE METRICS'),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _radialCard(
          label: 'TOTAL VIEWS', value: _fmt(_totalViews),
          progress: (_totalViews / math.max(_totalViews, 1000)).clamp(0.0, 1.0),
          color: BrokaColors.neonCyan, sub: '+12% vs last week', up: true)),
        const SizedBox(width: 10),
        Expanded(child: _radialCard(
          label: 'DEALS DONE', value: '$_completedDeals',
          progress: (_completedDeals / math.max(_completedDeals + 4, 20)).clamp(0.0, 1.0),
          color: BrokaColors.neonGreen, sub: '$_activeCount active', up: true)),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _radialCard(
          label: 'FEATURED', value: '$_featuredCount',
          progress: _listings.isEmpty
              ? 0.0 : (_featuredCount / _listings.length).clamp(0.0, 1.0),
          color: BrokaColors.gold,
          sub: 'of ${_listings.length} products', up: _featuredCount > 0)),
        const SizedBox(width: 10),
        Expanded(child: _radialCard(
          label: 'RESPONSE', value: '${_responseRate.toInt()}%',
          progress: (_responseRate / 100).clamp(0.0, 1.0),
          color: BrokaColors.neonBlue, sub: 'reply rate', up: _responseRate >= 70)),
      ]),
    ]),
  );

  Widget _radialCard({
    required String label, required String value, required double progress,
    required Color color, required String sub, required bool up,
  }) => AnimatedBuilder(
    animation: _glow,
    builder: (_, __) => Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.20 + 0.08 * _glow.value)),
        boxShadow: [BoxShadow(
            color: color.withOpacity(0.04 + 0.03 * _glow.value), blurRadius: 18)]),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(
              color: BrokaColors.textLow, fontSize: 8,
              fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(
              color: color, fontSize: 24, fontWeight: FontWeight.w900,
              fontFamily: 'monospace', height: 1.0)),
          const SizedBox(height: 4),
          Row(children: [
            Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                size: 10, color: up ? BrokaColors.neonGreen : BrokaColors.danger),
            const SizedBox(width: 3),
            Text(sub, style: const TextStyle(color: BrokaColors.textMid, fontSize: 9)),
          ]),
        ])),
        SizedBox(width: 56, height: 56, child: CustomPaint(
          painter: _RadialGaugePainter(
              progress: progress, color: color, glowT: _glow.value),
          child: Center(child: Text('${(progress * 100).toInt()}%',
              style: TextStyle(
                  color: color, fontSize: 10, fontWeight: FontWeight.w800))),
        )),
      ]),
    ),
  );

  // ── Revenue Overview Chart ────────────────────────────────────────────────────
  Widget _buildRevenueChart() {
    final data      = _revenueData;
    final maxV      = data.reduce(math.max);
    final minV      = data.reduce(math.min);
    final avgV      = data.reduce((a, b) => a + b) / data.length;
    final maxIdx    = data.indexOf(maxV);
    final minIdx    = data.indexOf(minV);
    final labels    = _revenueWeekMode ? _days : _weekLabels;
    final dayWord   = _revenueWeekMode ? 'Day' : 'Week';
    final showEmpty = !_revenueLoading && !_revenueHasRealData;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.18)),
          boxShadow: [BoxShadow(
              color: BrokaColors.neonCyan.withOpacity(0.04), blurRadius: 20)]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('REVENUE OVERVIEW', style: TextStyle(
                color: BrokaColors.textHigh, fontSize: 12,
                fontWeight: FontWeight.w800, letterSpacing: 1.0))),
            if (_revenueLoading)
              const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(
                  strokeWidth: 1.6, color: BrokaColors.neonCyan))
            else
              Container(
                decoration: BoxDecoration(
                    color: BrokaColors.bg, borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: BrokaColors.border)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _toggleBtn('WEEK',  _revenueWeekMode,  () => setState(() => _revenueWeekMode = true)),
                  _toggleBtn('MONTH', !_revenueWeekMode, () => setState(() => _revenueWeekMode = false)),
                ]),
              ),
          ]),
          const SizedBox(height: 20),
          SizedBox(height: 130, child: Stack(alignment: Alignment.center, children: [
            AnimatedBuilder(
              animation: _glow,
              builder: (_, __) => CustomPaint(
                painter: _GlowLineChartPainter(values: data, glowT: _glow.value),
                child: const SizedBox.expand()),
            ),
            if (showEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: BrokaColors.bg.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: BrokaColors.border),
                ),
                child: const Text('No completed sales yet — this fills in once a deal is released.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 10)),
              ),
          ])),
          const SizedBox(height: 8),
          Row(children: List.generate(labels.length, (i) => Expanded(child: Center(
            child: Text(labels[i], style: const TextStyle(
                color: BrokaColors.textLow, fontSize: 8, letterSpacing: 0.3)))))),
          const SizedBox(height: 16),
          Container(height: 1, color: BrokaColors.border),
          const SizedBox(height: 14),
          Row(children: [
            _revStat(Icons.arrow_circle_up_rounded, 'HIGHEST',
                'KES ${maxV.toStringAsFixed(0)}', BrokaColors.neonGreen, '$dayWord ${maxIdx + 1}'),
            _revDivider(),
            _revStat(Icons.arrow_circle_down_rounded, 'LOWEST',
                'KES ${minV.toStringAsFixed(0)}', BrokaColors.danger, '$dayWord ${minIdx + 1}'),
            _revDivider(),
            _revStat(Icons.bar_chart_rounded, 'AVERAGE',
                'KES ${avgV.toStringAsFixed(0)}', BrokaColors.gold, 'Per $dayWord'),
          ]),
        ]),
      ),
    );
  }

  Widget _toggleBtn(String label, bool active, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: active ? BrokaColors.gold.withOpacity(0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        border: active ? Border.all(color: BrokaColors.gold.withOpacity(0.35)) : null),
      child: Text(label, style: TextStyle(
          color: active ? BrokaColors.gold : BrokaColors.textMid,
          fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.8))));

  Widget _revStat(IconData ic, String lbl, String val, Color c, String sub) =>
      Expanded(child: Column(children: [
        Icon(ic, color: c, size: 16),
        const SizedBox(height: 4),
        Text(lbl, style: const TextStyle(
            color: BrokaColors.textLow, fontSize: 7, letterSpacing: 0.8)),
        const SizedBox(height: 2),
        Text(val, style: TextStyle(
            color: c, fontSize: 11, fontWeight: FontWeight.w800)),
        const SizedBox(height: 1),
        Text(sub, style: const TextStyle(color: BrokaColors.textMid, fontSize: 8)),
      ]));

  Widget _revDivider() => Container(width: 1, height: 44, color: BrokaColors.border);

  Widget _viewsStat(String lbl, String val, Color c) =>
      Expanded(child: Column(children: [
        Text(lbl, style: const TextStyle(
            color: BrokaColors.textLow, fontSize: 7, letterSpacing: 0.8)),
        const SizedBox(height: 4),
        Text(val, style: TextStyle(
            color: c, fontSize: 13, fontWeight: FontWeight.w800)),
      ]));

  // ── Deal Pipeline ─────────────────────────────────────────────────────────────
  Widget _buildDealPipeline() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _secLabel('DEAL PIPELINE'),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BrokaColors.border)),
        child: Row(children: [
          _pipeStage(Icons.format_list_bulleted_rounded, _pipeListed, 'LISTED',
              BrokaColors.neonBlue, '100%'),
          _pipeArrow(),
          _pipeStage(Icons.handshake_rounded, _pipeNeg, 'NEGOTIATING',
              BrokaColors.warning,
              _pipeListed > 0 ? '${(_pipeNeg / _pipeListed * 100).round()}%' : '0%'),
          _pipeArrow(),
          _pipeStage(Icons.payment_rounded, _pipeEscrow, 'PAYMENT',
              BrokaColors.gold,
              _pipeListed > 0 ? '${(_pipeEscrow / _pipeListed * 100).round()}%' : '0%'),
          _pipeArrow(),
          _pipeStage(Icons.check_circle_rounded, _pipeDone, 'COMPLETE',
              BrokaColors.neonGreen,
              _pipeListed > 0 ? '${(_pipeDone / _pipeListed * 100).round()}%' : '0%'),
        ]),
      ),
    ]),
  );

  Widget _pipeStage(IconData ic, int cnt, String lbl, Color c, String pct) =>
      Expanded(child: AnimatedBuilder(
        animation: _glow,
        builder: (_, __) => Column(children: [
          Container(width: 44, height: 44,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: c.withOpacity(0.11),
              border: Border.all(
                  color: c.withOpacity(0.40 + 0.18 * _glow.value), width: 1.5),
              boxShadow: [BoxShadow(
                  color: c.withOpacity(0.10 + 0.08 * _glow.value), blurRadius: 12)]),
            child: Icon(ic, color: c, size: 20)),
          const SizedBox(height: 8),
          Text('$cnt', style: TextStyle(
              color: c, fontSize: 20, fontWeight: FontWeight.w900,
              fontFamily: 'monospace', height: 1.0)),
          const SizedBox(height: 3),
          Text(lbl, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 7,
              fontWeight: FontWeight.w700, letterSpacing: 0.8),
            textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: c.withOpacity(0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.withOpacity(0.22))),
            child: Text(pct, style: TextStyle(
                color: c, fontSize: 8, fontWeight: FontWeight.w700))),
        ]),
      ));

  Widget _pipeArrow() => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      ...List.generate(3, (i) => AnimatedBuilder(
        animation: _pulse,
        builder: (_, __) => Container(
          width: 4, height: 1.5,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: BrokaColors.textLow.withOpacity(
                0.3 + 0.4 * ((_pulse.value + i * 0.33) % 1.0)),
            borderRadius: BorderRadius.circular(1))))),
      const Icon(Icons.chevron_right_rounded, color: BrokaColors.textLow, size: 14),
    ]),
  );

  // ── Zeno Insight Cards ────────────────────────────────────────────────────────
  Widget _buildZenoInsightCards() {
    // Parse Zeno's real numbered-list reply into individual tip strings
    // instead of showing 6 generic, hardcoded claims (e.g. "+22% revenue")
    // that were the same for every seller regardless of their actual data.
    final tips = (_zenoGlobal ?? '')
        .split('\n')
        .map((s) => s.replaceFirst(RegExp(r'^\s*\d+[.)]\s*'), '').trim())
        .where((s) => s.isNotEmpty)
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Container(width: 26, height: 26,
              decoration: const BoxDecoration(shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue])),
              child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 13)),
            const SizedBox(width: 8),
            _secLabel('ZENO INSIGHTS'),
            const Spacer(),
            _zenoGlobalLoading
                ? const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold))
                : GestureDetector(
                    onTap: _loadZenoGlobal,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: BrokaColors.gold.withOpacity(0.10),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: BrokaColors.gold.withOpacity(0.25))),
                      child: const Text('↻ REFRESH', style: TextStyle(
                          color: BrokaColors.gold, fontSize: 8,
                          fontWeight: FontWeight.w800, letterSpacing: 0.8)))),
          ]),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 152,
          child: _zenoGlobalLoading && tips.isEmpty
              ? const Center(child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('Zeno is analysing your listings…',
                      style: TextStyle(color: BrokaColors.textLow, fontSize: 11))))
              : tips.isEmpty
                  // Real AI tips failed to load (offline/error) - fall back to
                  // generic, honestly-labelled evergreen advice rather than
                  // fabricated seller-specific numbers.
                  ? ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _staticTips.length,
                      itemBuilder: (_, i) => _insightCard(
                          title: 'SELLER TIP',
                          body: '${_staticTips[i].$1} ${_staticTips[i].$2}: ${_staticTips[i].$3}',
                          source: 'GENERAL'),
                    )
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: tips.length,
                      itemBuilder: (_, i) => _insightCard(
                          title: 'TIP ${i + 1}', body: tips[i], source: 'ZENO · LIVE'),
                    ),
        ),
      ]),
    );
  }

  Widget _insightCard({required String title, required String body, required String source}) {
    return AnimatedBuilder(
      animation: _glow,
      builder: (_, __) => Container(
        width: 200,
        margin: const EdgeInsets.only(right: 12, bottom: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: BrokaColors.border.withOpacity(0.8 + 0.2 * _glow.value)),
          boxShadow: [BoxShadow(
              color: BrokaColors.gold.withOpacity(0.03 + 0.02 * _glow.value),
              blurRadius: 12)]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(
              color: BrokaColors.gold, fontSize: 10,
              fontWeight: FontWeight.w800, letterSpacing: 0.8)),
          const SizedBox(height: 8),
          Expanded(child: Text(body, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 11, height: 1.45),
            maxLines: 5, overflow: TextOverflow.ellipsis)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: BrokaColors.neonBlue.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.30))),
            child: Text(source, style: const TextStyle(
                color: BrokaColors.neonBlue, fontSize: 8,
                fontWeight: FontWeight.w800, letterSpacing: 0.6)),
          ),
        ]),
      ),
    );
  }

  // ── Global Zeno Analysis (text) ───────────────────────────────────────────────
  Widget _buildLiveZenoAnalysis() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          BrokaColors.gold.withOpacity(0.11),
          BrokaColors.neonBlue.withOpacity(0.07),
        ], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.32))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              borderRadius: BorderRadius.circular(6)),
            child: const Text('ZENO LIVE ANALYSIS', style: TextStyle(
                color: Colors.white, fontSize: 9,
                fontWeight: FontWeight.w900, letterSpacing: 1.2))),
          const Spacer(),
          _zenoGlobalLoading
              ? const SizedBox(width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold))
              : GestureDetector(
                  onTap: _loadZenoGlobal,
                  child: const Icon(Icons.refresh_rounded, size: 16, color: BrokaColors.gold)),
        ]),
        const SizedBox(height: 10),
        _zenoGlobalLoading && _zenoGlobal == null
            ? const Text('Zeno is analysing your store…',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12, fontStyle: FontStyle.italic))
            : _zenoGlobal != null
              ? Text(_zenoGlobal!, style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 12.5, height: 1.6))
              : const Text('Tap ↻ to get personalised pricing tips from Zeno.',
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
      ]),
    ),
  );

  // ── Radar Section ─────────────────────────────────────────────────────────────
  Widget _buildRadarSection() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _secLabel('TRUST & PERFORMANCE SCORES'),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.border)),
        child: Column(children: [
          SizedBox(height: 220, child: CustomPaint(
            painter: _RadarChartPainter(
              values: [
                _reliability / 10, _trustScore / 10, _avgRating / 10,
                _responseRate / 100,
                (_completedDeals / math.max(_completedDeals + 2, 10)).clamp(0.0, 1.0),
              ],
              labels: ['Reliability','Trust','Rating','Response','Deals'],
              colors: [BrokaColors.gold, BrokaColors.neonBlue, BrokaColors.gold,
                       BrokaColors.neonGreen, BrokaColors.neonCyan]),
            child: const SizedBox.expand())),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            HexTrustBadge(score: _reliability, label: 'Reliability'),
            HexTrustBadge(score: _trustScore,  label: 'Trust'),
            HexTrustBadge(score: _avgRating,   label: 'Rating'),
          ]),
        ]),
      ),
    ]),
  );

  // ── Revenue Impact Calculator ─────────────────────────────────────────────────
  Widget _buildRevenueCalculator() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.18)),
        boxShadow: [BoxShadow(
            color: BrokaColors.neonGreen.withOpacity(0.04), blurRadius: 20)]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 28, height: 28,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: BrokaColors.neonGreen.withOpacity(0.14),
              border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.30))),
            child: const Icon(Icons.calculate_rounded, color: BrokaColors.neonGreen, size: 14)),
          const SizedBox(width: 10),
          const Text('REVENUE IMPACT CALCULATOR', style: TextStyle(
              color: BrokaColors.textHigh, fontSize: 12,
              fontWeight: FontWeight.w800, letterSpacing: 0.6)),
        ]),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: _calcInput(
            label: 'AVG PRICE', prefix: 'KES ', controller: _avgPriceCtrl,
            onChanged: (v) => setState(() { _calcAvgPrice = v; _calcDone = false; }))),
          const SizedBox(width: 12),
          Expanded(child: _calcInput(
            label: 'VOLUME', controller: _volumeCtrl,
            onChanged: (v) => setState(() { _calcVolume = v; _calcDone = false; }))),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: _calcSlider(
            label: 'CONVERSION RATE', value: _calcConvRate,
            min: 0.5, max: 10, suffix: '%', color: BrokaColors.neonBlue,
            onChanged: (v) => setState(() { _calcConvRate = v; _calcDone = false; }))),
          const SizedBox(width: 12),
          Expanded(child: _calcSlider(
            label: 'PROFIT MARGIN', value: _calcMargin,
            min: 5, max: 80, suffix: '%', color: BrokaColors.gold,
            onChanged: (v) => setState(() { _calcMargin = v; _calcDone = false; }))),
        ]),
        const SizedBox(height: 14),
        _calcInput(
          label: 'ACQ. COST / UNIT', prefix: 'KES ', controller: _acqCostCtrl,
          onChanged: (v) => setState(() { _calcAcqCost = v; _calcDone = false; })),
        const SizedBox(height: 18),
        GestureDetector(
          onTap: () { HapticFeedback.mediumImpact(); setState(() => _calcDone = true); },
          child: AnimatedBuilder(
            animation: _glow,
            builder: (_, __) => Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [BrokaColors.neonGreen, BrokaColors.neonBlue],
                    begin: Alignment.centerLeft, end: Alignment.centerRight),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(
                    color: BrokaColors.neonGreen.withOpacity(0.22 + 0.12 * _glow.value),
                    blurRadius: 14)]),
              child: const Center(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.calculate_rounded, color: Colors.white, size: 16),
                SizedBox(width: 8),
                Text('CALCULATE', style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w900,
                    fontSize: 13, letterSpacing: 1.2)),
              ])),
            ),
          ),
        ),
        if (_calcDone) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                BrokaColors.neonGreen.withOpacity(0.10),
                BrokaColors.neonBlue.withOpacity(0.06)]),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.28))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('NET REVENUE', style: TextStyle(
                  color: BrokaColors.textLow, fontSize: 9, letterSpacing: 1.2)),
              const SizedBox(height: 4),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(_kes(_calcNetRevenue), style: const TextStyle(
                    color: BrokaColors.neonGreen, fontSize: 24,
                    fontWeight: FontWeight.w900, fontFamily: 'monospace')),
                const SizedBox(width: 8),
                const Padding(padding: EdgeInsets.only(bottom: 3),
                  child: Row(children: [
                    Icon(Icons.arrow_upward_rounded, size: 11, color: BrokaColors.neonGreen),
                    Text('22.8% vs last week', style: TextStyle(
                        color: BrokaColors.neonGreen, fontSize: 9, fontWeight: FontWeight.w700)),
                  ])),
              ]),
              const SizedBox(height: 12),
              Container(height: 1, color: BrokaColors.border),
              const SizedBox(height: 12),
              _calcRow('TOTAL REVENUE', _kes(_calcTotalRev),    BrokaColors.textMid),
              const SizedBox(height: 6),
              _calcRow('TOTAL COST',    _kes(_calcTotalCost),   BrokaColors.textMid),
              const SizedBox(height: 6),
              _calcRow('GROSS PROFIT',  _kes(_calcGrossProfit), BrokaColors.textHigh),
              const SizedBox(height: 6),
              _calcRow('NET PROFIT',    _kes(_calcNetRevenue),  BrokaColors.neonGreen,
                  bold: true),
            ]),
          ),
        ],
      ]),
    ),
  );

  Widget _calcInput({
    required String label, String prefix = '', required TextEditingController controller,
    required void Function(double) onChanged,
  }) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(
        color: BrokaColors.textLow, fontSize: 8,
        letterSpacing: 1.0, fontWeight: FontWeight.w700)),
    const SizedBox(height: 6),
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: BrokaColors.bg, borderRadius: BorderRadius.circular(10),
        border: Border.all(color: BrokaColors.border)),
      child: Row(children: [
        if (prefix.isNotEmpty)
          Text(prefix, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
        Expanded(child: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
          ],
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13,
              fontWeight: FontWeight.w700, fontFamily: 'monospace'),
          decoration: const InputDecoration(
            isDense: true, border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: 8)),
          onChanged: (s) => onChanged(double.tryParse(s) ?? 0),
        )),
      ])),
  ]);

  Widget _calcSlider({
    required String label, required double value, required double min,
    required double max, required String suffix, required Color color,
    required void Function(double) onChanged,
  }) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      Text(label, style: const TextStyle(
          color: BrokaColors.textLow, fontSize: 8,
          letterSpacing: 1.0, fontWeight: FontWeight.w700)),
      const Spacer(),
      Text('${value.toStringAsFixed(1)}$suffix', style: TextStyle(
          color: color, fontSize: 11,
          fontWeight: FontWeight.w800, fontFamily: 'monospace')),
    ]),
    SliderTheme(
      data: SliderThemeData(
        trackHeight: 2.5,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        activeTrackColor: color, inactiveTrackColor: BrokaColors.border,
        thumbColor: color, overlayColor: color.withOpacity(0.15)),
      child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged)),
  ]);

  Widget _calcRow(String l, String v, Color c, {bool bold = false}) =>
      Row(children: [
        Expanded(child: Text(l,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 11))),
        Text(v, style: TextStyle(
            color: c, fontSize: 11, fontFamily: 'monospace',
            fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
      ]);

  // ── Verification CTA ──────────────────────────────────────────────────────────
  Widget _buildVerificationCTA() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          BrokaColors.gold.withOpacity(0.12), BrokaColors.gold.withOpacity(0.20)]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.48)),
        boxShadow: [BoxShadow(
            color: BrokaColors.gold.withOpacity(0.10), blurRadius: 20, spreadRadius: 2)]),
      child: Column(children: [
        Row(children: [
          Container(width: 44, height: 44,
            decoration: BoxDecoration(
              color: BrokaColors.gold.withOpacity(0.20), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.verified_rounded, color: BrokaColors.gold, size: 24)),
          const SizedBox(width: 14),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Get Verified Badge', style: TextStyle(
                color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
            SizedBox(height: 3),
            Text('Boost buyer trust by 40%',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
          ])),
        ]),
        const SizedBox(height: 14),
        const Text(
          'Verified sellers earn significantly more trust from buyers and appear '
          'higher in search results. Complete your ID verification to unlock the gold badge.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.5)),
        const SizedBox(height: 14),
        Row(children: [
          _chip('Higher visibility'), const SizedBox(width: 8),
          _chip('Trust badge'),       const SizedBox(width: 8),
          _chip('Priority listing'),
        ]),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, '/verification').then((_) => _load()),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [BrokaColors.gold, Color(0xFFF59E0B)]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.30), blurRadius: 12)]),
            child: const Center(child: Text('Start Verification',
                style: TextStyle(color: Colors.black87,
                    fontWeight: FontWeight.w800, fontSize: 14))))),
      ]),
    ),
  );

  Widget _chip(String l) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: BrokaColors.gold.withOpacity(0.10),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: BrokaColors.gold.withOpacity(0.28))),
    child: Text('✓ $l', style: const TextStyle(
        color: BrokaColors.gold, fontSize: 10, fontWeight: FontWeight.w700)));

  // ── Boost CTA ────────────────────────────────────────────────────────────────
  Widget _buildBoostCta() => Container(
    margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: [
        BrokaColors.gold.withOpacity(0.12), BrokaColors.neonBlue.withOpacity(0.08)]),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: BrokaColors.gold.withOpacity(0.38)),
      boxShadow: [BoxShadow(
          color: BrokaColors.gold.withOpacity(0.08), blurRadius: 20, spreadRadius: 2)]),
    child: Column(children: [
      Row(children: [
        Container(width: 44, height: 44,
          decoration: BoxDecoration(
            color: BrokaColors.gold.withOpacity(0.20), borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.rocket_launch_rounded, color: BrokaColors.gold, size: 24)),
        const SizedBox(width: 14),
        const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Feature a Listing', style: TextStyle(
              color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
          SizedBox(height: 3),
          Text('Pin to top of the feed',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
        ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: BrokaColors.gold.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
          child: const Text('From KES 99', style: TextStyle(
              color: BrokaColors.gold, fontSize: 10, fontWeight: FontWeight.w800))),
      ]),
      const SizedBox(height: 14),
      const Text(
        'Featured listings appear first in the home feed with a glowing badge — '
        'seen by every buyer in your category. Sellers report 5x more views and '
        'faster deal closure when featured.',
        style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.5)),
      const SizedBox(height: 16),
      GestureDetector(
        onTap: () => Navigator.pushNamed(context, '/boost-listing'),
        child: AnimatedBuilder(
          animation: _glow,
          builder: (_, __) => Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(
                  color: BrokaColors.gold.withOpacity(0.25 + 0.10 * _glow.value),
                  blurRadius: 12)]),
            child: const Center(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.rocket_launch_rounded, color: Colors.white, size: 16),
              SizedBox(width: 8),
              Text('Get Featured — From KES 99',
                  style: TextStyle(color: Colors.white,
                      fontWeight: FontWeight.w800, fontSize: 14)),
            ])))),
      ),
    ]),
  );

  // ── Receipts button ───────────────────────────────────────────────────────────
  Widget _buildReceiptsButton() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/receipt-history'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF00B300).withOpacity(0.35))),
        child: Row(children: [
          Container(width: 40, height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF00B300).withOpacity(0.12),
              border: Border.all(color: const Color(0xFF00B300).withOpacity(0.40))),
            child: const Icon(Icons.receipt_long_outlined, color: Color(0xFF00B300), size: 20)),
          const SizedBox(width: 14),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Payment Receipts', style: TextStyle(
                color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 14)),
            SizedBox(height: 2),
            Text('View all completed M-Pesa transactions',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
          ])),
          const Icon(Icons.chevron_right_rounded, color: BrokaColors.textLow, size: 20),
        ]),
      ),
    ),
  );

  // ════════════════════════════════════════════════════════════════════════════
  // TAB 1 — PRODUCTS
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildProductsTab() {
    if (_listings.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 72, height: 72,
          decoration: BoxDecoration(shape: BoxShape.circle, color: BrokaColors.bgCard,
              border: Border.all(color: BrokaColors.gold.withOpacity(0.25))),
          child: const Icon(Icons.storefront_outlined, color: BrokaColors.textLow, size: 36)),
        const SizedBox(height: 16),
        const Text('No products yet',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 16)),
        const SizedBox(height: 8),
        const Text("Tap 'Sell' to list your first product",
            style: TextStyle(color: BrokaColors.textLow, fontSize: 13)),
        const SizedBox(height: 20),
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, '/sell'),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.30), blurRadius: 12)]),
            child: const Text('List a Product',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)))),
      ]));
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: BrokaColors.gold,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
        itemCount: _listings.length + 1,
        itemBuilder: (_, i) {
          if (i == 0) return _buildProductsHeader();
          return _buildProductCard(_listings[i - 1]);
        }),
    );
  }

  Widget _buildProductsHeader() => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_listings.length} PRODUCT${_listings.length == 1 ? "" : "S"}',
            style: const TextStyle(color: BrokaColors.textLow, fontSize: 10,
                fontWeight: FontWeight.w700, letterSpacing: 1.4)),
        const SizedBox(height: 2),
        Text('$_activeCount active · $_featuredCount featured',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
      ])),
      GestureDetector(
        onTap: () => Navigator.pushNamed(context, '/sell'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim]),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.25), blurRadius: 8)]),
          child: const Text('+ List Product',
              style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)))),
    ]),
  );

  Widget _buildProductCard(Listing l) {
    final isExpanded = _expanded[l.id] ?? false;
    final label      = _dealLabel(l);
    final colour     = _dealColour(label);
    final boost      = _boostStatusMap[l.id];
    final featured   = l.isFeatured || (boost?['is_featured'] as bool? ?? false);

    return AnimatedBuilder(
      animation: _glow,
      builder: (_, child) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: featured
                ? BrokaColors.neonCyan.withOpacity(0.38 + 0.14 * _glow.value)
                : BrokaColors.border,
            width: featured ? 1.5 : 1),
          boxShadow: featured ? [BoxShadow(
              color: BrokaColors.neonCyan.withOpacity(0.06 + 0.04 * _glow.value),
              blurRadius: 20)] : null),
        child: child,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(children: [
          // ── Card header ─────────────────────────────────────────────────────
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              final opening = !(_expanded[l.id] ?? false);
              setState(() => _expanded[l.id] = opening);
              if (opening) {
                _loadZenoForListing(l);
                if (!_dealStatusMap.containsKey(l.id)) _loadDealStatus(l.id);
                if (!_boostStatusMap.containsKey(l.id)) _loadBoostStatus(l.id);
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Row(children: [
                Container(width: 46, height: 46,
                  decoration: BoxDecoration(
                    color: BrokaColors.gold.withOpacity(0.11),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: BrokaColors.gold.withOpacity(0.20))),
                  child: Center(child: Text(l.emoji, style: const TextStyle(fontSize: 22)))),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.name, style: const TextStyle(
                      color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 14),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 5),
                  Row(children: [
                    Text(l.category, style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 11)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: colour.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: colour.withOpacity(0.30))),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(_dealIcon(label), color: colour, size: 9),
                        const SizedBox(width: 3),
                        Text(label, style: TextStyle(
                            color: colour, fontSize: 9, fontWeight: FontWeight.w800)),
                      ])),
                  ]),
                ])),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Row(children: [
                    const Icon(Icons.visibility_rounded, size: 11, color: BrokaColors.neonBlue),
                    const SizedBox(width: 3),
                    Text('${l.views}', style: const TextStyle(
                        color: BrokaColors.neonBlue, fontWeight: FontWeight.w800, fontSize: 14)),
                  ]),
                  const SizedBox(height: 5),
                  if (featured)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: BrokaColors.neonCyan.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.40))),
                      child: const Text('FEATURED', style: TextStyle(
                          color: BrokaColors.neonCyan, fontSize: 8,
                          fontWeight: FontWeight.w800, letterSpacing: 0.8))),
                  const SizedBox(height: 4),
                  Icon(isExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                      color: BrokaColors.textLow, size: 20),
                ]),
              ]),
            ),
          ),
          // ── Price + age row ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Row(children: [
              const Icon(Icons.sell_rounded, size: 11, color: BrokaColors.textLow),
              const SizedBox(width: 4),
              Text(l.formattedPrice, style: const TextStyle(
                  color: BrokaColors.gold, fontWeight: FontWeight.w700, fontSize: 12)),
              const Spacer(),
              Text(l.createdAt != null ? 'Listed ${_timeAgo(l.createdAt!)}' : 'Recently listed',
                  style: const TextStyle(color: BrokaColors.textLow, fontSize: 10)),
            ]),
          ),
          // ── Expanded analytics body ──────────────────────────────────────────
          if (isExpanded) _buildProductExpandedBody(l, label, featured),
        ]),
      ),
    );
  }

  Widget _buildProductExpandedBody(Listing l, String dealLabel, bool isFeatured) {
    final daysSinceListed = l.createdAt != null
        ? math.max(1, DateTime.now().difference(l.createdAt!).inDays)
        : null;
    final avgPerDay = daysSinceListed != null ? l.views / daysSinceListed : null;

    return Column(children: [
      Container(height: 1, color: BrokaColors.border),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _secLabel('VIEWS', color: BrokaColors.neonBlue),
          const SizedBox(height: 10),
          Row(children: [
            _viewsStat('TOTAL VIEWS', _fmt(l.views), BrokaColors.neonBlue),
            _revDivider(),
            _viewsStat(
              'AVG / DAY',
              avgPerDay != null ? avgPerDay.toStringAsFixed(1) : '—',
              BrokaColors.neonCyan,
            ),
            _revDivider(),
            _viewsStat(
              'LISTED',
              daysSinceListed != null ? '${daysSinceListed}d ago' : 'Recently',
              BrokaColors.gold,
            ),
          ]),
          const SizedBox(height: 22),
          _buildListingZenoPricing(l),
          const SizedBox(height: 16),
          _buildDealStatusRow(l, dealLabel),
          const SizedBox(height: 16),
          if (dealLabel == 'Pending' || dealLabel == 'Active') _buildPlatformCTA(l),
          if (!isFeatured) _buildProductFeaturedCTA(l) else _buildActiveFeaturedBadge(l),
        ]),
      ),
    ]);
  }

  Widget _buildListingZenoPricing(Listing l) {
    final tip     = _listingZeno[l.id];
    final loading = _listingZenoLoading[l.id] ?? false;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          BrokaColors.gold.withOpacity(0.10), BrokaColors.neonBlue.withOpacity(0.06)]),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.28))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              borderRadius: BorderRadius.circular(5)),
            child: const Text('ZENO PRICING', style: TextStyle(
                color: Colors.white, fontSize: 8,
                fontWeight: FontWeight.w900, letterSpacing: 1.0))),
          const Spacer(),
          if (loading)
            const SizedBox(width: 12, height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold))
          else
            GestureDetector(
              onTap: () { _listingZeno.remove(l.id); _loadZenoForListing(l); },
              child: const Icon(Icons.refresh_rounded, size: 14, color: BrokaColors.gold)),
        ]),
        const SizedBox(height: 8),
        loading && tip == null
            ? const Text('Zeno is analysing this product…',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12, fontStyle: FontStyle.italic))
            : tip != null
              ? Text(tip, style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 12, height: 1.55))
              : const Text('Tap ↻ above to get pricing tips for this product.',
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
      ]),
    );
  }

  Widget _buildDealStatusRow(Listing l, String label) {
    final c = _dealColour(label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withOpacity(0.25))),
      child: Row(children: [
        Container(width: 34, height: 34,
          decoration: BoxDecoration(shape: BoxShape.circle, color: c.withOpacity(0.14)),
          child: Icon(_dealIcon(label), color: c, size: 17)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('DEAL STATUS', style: TextStyle(
              color: c, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: c, fontSize: 14, fontWeight: FontWeight.w700)),
        ])),
        if (label == 'In Escrow')
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: BrokaColors.neonBlue.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.30))),
            child: const Text('M-Pesa Secured', style: TextStyle(
                color: BrokaColors.neonBlue, fontSize: 10, fontWeight: FontWeight.w700))),
      ]),
    );
  }

  Widget _buildPlatformCTA(Listing l) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: BrokaColors.neonBlue.withOpacity(0.07),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.28))),
    child: Row(children: [
      Container(width: 36, height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle, color: BrokaColors.neonBlue.withOpacity(0.14)),
        child: const Icon(Icons.shield_rounded, color: BrokaColors.neonBlue, size: 18)),
      const SizedBox(width: 12),
      const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Keep this deal on BROKA', style: TextStyle(
            color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 12)),
        SizedBox(height: 3),
        Text('M-Pesa escrow holds payment until delivery — '
             'you only get paid when the buyer confirms receipt.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11, height: 1.4)),
      ])),
    ]),
  );

  Widget _buildProductFeaturedCTA(Listing l) => GestureDetector(
    onTap: () => Navigator.pushNamed(context, '/boost-listing'),
    child: AnimatedBuilder(
      animation: _glow,
      builder: (_, __) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [BrokaColors.gold, BrokaColors.neonBlue],
              begin: Alignment.centerLeft, end: Alignment.centerRight),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(
              color: BrokaColors.gold.withOpacity(0.20 + 0.10 * _glow.value),
              blurRadius: 12)]),
        child: const Center(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.rocket_launch_rounded, color: Colors.white, size: 15),
          SizedBox(width: 8),
          Text('Get Featured — From KES 99',
              style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
        ])))));

  Widget _buildActiveFeaturedBadge(Listing l) {
    final until = l.featuredUntil;
    final diff  = until != null ? until.difference(DateTime.now()) : null;
    final lbl   = diff != null && diff.isNegative
        ? 'Featured listing has expired'
        : diff != null
          ? 'Featured for ${diff.inDays > 0 ? "${diff.inDays}d" : "${diff.inHours}h"} more'
          : 'Featured listing active';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BrokaColors.neonCyan.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.35))),
      child: Row(children: [
        const Icon(Icons.star_rounded, color: BrokaColors.neonCyan, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(lbl, style: const TextStyle(
            color: BrokaColors.neonCyan, fontWeight: FontWeight.w700, fontSize: 12))),
        if (diff != null && diff.isNegative)
          GestureDetector(
            onTap: () => Navigator.pushNamed(context, '/boost-listing'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [BrokaColors.gold, BrokaColors.neonBlue]),
                borderRadius: BorderRadius.circular(8)),
              child: const Text('Renew', style: TextStyle(
                  color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)))),
      ]),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // TAB 2 — DEALS
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildDealsTab() {
    final withDeals = _listings.where((l) => _dealStatusMap.containsKey(l.id)).toList();
    final inEscrow  = withDeals.where((l) => _dealLabel(l) == 'In Escrow').toList();
    final pending   = withDeals.where((l) => _dealLabel(l) == 'Pending').toList();
    final completed = withDeals.where((l) => _dealLabel(l) == 'Complete').toList();
    final active    = withDeals.where((l) => _dealLabel(l) == 'Active').toList();

    return RefreshIndicator(
      onRefresh: () async {
        for (final l in _listings) { _loadDealStatus(l.id); _loadBoostStatus(l.id); }
      },
      color: BrokaColors.gold,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _secLabel('DEAL SUMMARY'),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _dealSummaryCard(
                '${inEscrow.length}', 'In Escrow',
                Icons.lock_rounded, BrokaColors.neonBlue)),
            const SizedBox(width: 10),
            Expanded(child: _dealSummaryCard(
                '${pending.length}', 'Pending',
                Icons.hourglass_bottom_rounded, BrokaColors.warning)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _dealSummaryCard(
                '${completed.length}', 'Completed',
                Icons.check_circle_rounded, BrokaColors.neonGreen)),
            const SizedBox(width: 10),
            Expanded(child: _dealSummaryCard(
                '${active.length}', 'No Deal Yet',
                Icons.store_rounded, BrokaColors.textMid)),
          ]),
          const SizedBox(height: 24),
          _buildEscrowBanner(),
          const SizedBox(height: 24),
          if (inEscrow.isNotEmpty) ...[
            _secLabel('IN ESCROW — PAYMENT SECURED', color: BrokaColors.neonBlue),
            const SizedBox(height: 10),
            ...inEscrow.map(_dealCard),
            const SizedBox(height: 20),
          ],
          if (pending.isNotEmpty) ...[
            _secLabel('PENDING DEALS', color: BrokaColors.warning),
            const SizedBox(height: 10),
            ...pending.map(_dealCard),
            const SizedBox(height: 20),
          ],
          if (completed.isNotEmpty) ...[
            _secLabel('RECENTLY COMPLETED', color: BrokaColors.neonGreen),
            const SizedBox(height: 10),
            ...completed.map(_dealCard),
            const SizedBox(height: 20),
          ],
          if (active.isNotEmpty) ...[
            _secLabel('NO ACTIVE DEAL'),
            const SizedBox(height: 10),
            ...active.map(_dealCard),
            const SizedBox(height: 20),
          ],
          if (withDeals.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 30),
              child: Center(child: Column(children: [
                CircularProgressIndicator(color: BrokaColors.gold, strokeWidth: 2),
                SizedBox(height: 14),
                Text('Loading deal statuses…',
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
              ]))),
          _buildReceiptsButton(),
        ]),
      ),
    );
  }

  Widget _dealSummaryCard(String v, String l, IconData ic, Color c) =>
      AnimatedBuilder(
        animation: _glow,
        builder: (_, __) => Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
                begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.withOpacity(0.18 + 0.08 * _glow.value)),
            boxShadow: [BoxShadow(
                color: c.withOpacity(0.04 + 0.02 * _glow.value), blurRadius: 12)]),
          child: Row(children: [
            Container(width: 36, height: 36,
              decoration: BoxDecoration(shape: BoxShape.circle, color: c.withOpacity(0.12)),
              child: Icon(ic, color: c, size: 18)),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(v, style: TextStyle(
                  color: c, fontSize: 20,
                  fontWeight: FontWeight.w800, fontFamily: 'monospace')),
              Text(l, style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
            ]),
          ]),
        ));

  Widget _buildEscrowBanner() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: [
        BrokaColors.neonBlue.withOpacity(0.10),
        BrokaColors.neonGreen.withOpacity(0.06)]),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.28))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Icon(Icons.shield_rounded, color: BrokaColors.neonBlue, size: 18),
        SizedBox(width: 8),
        Text('BROKA Escrow Protection', style: TextStyle(
            color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 13)),
      ]),
      const SizedBox(height: 8),
      const Text(
        'When buyers pay through BROKA, their M-Pesa payment is held in escrow. '
        'You receive the funds only after the buyer confirms receipt — '
        'giving both parties full protection. Never accept payment outside the platform.',
        style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.5)),
      const SizedBox(height: 10),
      Row(children: [
        _chip2('No cash risks'), const SizedBox(width: 8),
        _chip2('Dispute protection'), const SizedBox(width: 8),
        _chip2('Instant M-Pesa release'),
      ]),
    ]),
  );

  Widget _chip2(String l) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: BrokaColors.neonBlue.withOpacity(0.10),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.25))),
    child: Text(l, style: const TextStyle(
        color: BrokaColors.neonBlue, fontSize: 9, fontWeight: FontWeight.w700)));

  Widget _dealCard(Listing l) {
    final label  = _dealLabel(l);
    final colour = _dealColour(label);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colour.withOpacity(0.22))),
      child: Row(children: [
        Container(width: 40, height: 40,
          decoration: BoxDecoration(
            color: BrokaColors.gold.withOpacity(0.10),
            borderRadius: BorderRadius.circular(10)),
          child: Center(child: Text(l.emoji, style: const TextStyle(fontSize: 20)))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.name, style: const TextStyle(
              color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 13),
            maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(l.formattedPrice, style: const TextStyle(
              color: BrokaColors.gold, fontSize: 12, fontWeight: FontWeight.w600)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: colour.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: colour.withOpacity(0.30))),
            child: Text(label, style: TextStyle(
                color: colour, fontSize: 10, fontWeight: FontWeight.w700))),
          const SizedBox(height: 5),
          Row(children: [
            const Icon(Icons.visibility_rounded, size: 10, color: BrokaColors.textLow),
            const SizedBox(width: 3),
            Text('${l.views}', style: const TextStyle(
                color: BrokaColors.textLow, fontSize: 10)),
          ]),
        ]),
      ]),
    );
  }

  // ── Shared helper ─────────────────────────────────────────────────────────────
  Widget _secLabel(String t, {Color? color}) => Text(t, style: TextStyle(
      color: color ?? BrokaColors.textLow, fontSize: 10,
      fontWeight: FontWeight.w700, letterSpacing: 1.2));
}

// ══════════════════════════════════════════════════════════════════════════════
// CUSTOM PAINTERS
// ══════════════════════════════════════════════════════════════════════════════

// ── Radial Gauge (for stat cards) ────────────────────────────────────────────
class _RadialGaugePainter extends CustomPainter {
  final double progress; // 0.0 – 1.0
  final Color  color;
  final double glowT;   // animation value 0.0 – 1.0
  _RadialGaugePainter({required this.progress, required this.color, required this.glowT});

  @override
  void paint(Canvas canvas, Size size) {
    final cx    = size.width / 2;
    final cy    = size.height / 2;
    final r     = math.min(cx, cy) - 5;
    const start = -math.pi * 0.75;
    const sweep = math.pi * 1.5;

    // Track ring
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      start, sweep, false,
      Paint()
        ..color = BrokaColors.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round);

    if (progress <= 0) return;
    final arc = sweep * progress.clamp(0.0, 1.0);

    // Glow halo
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      start, arc, false,
      Paint()
        ..color = color.withOpacity(0.25 + 0.12 * glowT)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));

    // Main arc — violet→color gradient
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      start, arc, false,
      Paint()
        ..shader = SweepGradient(
          colors: [color.withOpacity(0.5), color],
          startAngle: start,
          endAngle:   start + sweep,
          tileMode: TileMode.clamp,
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_RadialGaugePainter o) =>
      o.progress != progress || o.glowT != glowT;
}

// ── Glow Line Chart (Revenue Overview) ───────────────────────────────────────
class _GlowLineChartPainter extends CustomPainter {
  final List<double> values;
  final double       glowT;
  _GlowLineChartPainter({required this.values, required this.glowT});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final n       = values.length;
    final maxV    = values.reduce(math.max);
    final minV    = values.reduce(math.min);
    final range   = (maxV - minV).clamp(1.0, double.infinity);
    final avgV    = values.reduce((a, b) => a + b) / n;
    final bottom  = size.height - 2.0;
    final usable  = size.height - 22.0;
    final step    = size.width / (n - 1);

    final pts = List.generate(n, (i) {
      final norm = (values[i] - minV) / range;
      return Offset(i * step, bottom - usable * norm.clamp(0.05, 1.0));
    });

    // Grid lines
    for (int g = 1; g <= 3; g++) {
      canvas.drawLine(
        Offset(0, bottom - usable * g / 3),
        Offset(size.width, bottom - usable * g / 3),
        Paint()..color = BrokaColors.border.withOpacity(0.5)..strokeWidth = 0.6);
    }

    // Average dashed line
    final avgY = bottom - usable * ((avgV - minV) / range).clamp(0.05, 1.0);
    final dPaint = Paint()
      ..color = BrokaColors.warning.withOpacity(0.55)
      ..strokeWidth = 1.2;
    for (double x = 0; x < size.width; x += 11) {
      canvas.drawLine(
        Offset(x, avgY), Offset(math.min(x + 6, size.width), avgY), dPaint);
    }

    // AVG label
    final tp = TextPainter(
      text: TextSpan(
        text: 'AVG KES ${avgV.toStringAsFixed(0)}',
        style: const TextStyle(
            color: BrokaColors.warning, fontSize: 7.5, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset(size.width - tp.width - 2, avgY - 12));

    // Bezier line path
    final linePath = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (int i = 1; i < n; i++) {
      final c1 = Offset(pts[i-1].dx + (pts[i].dx - pts[i-1].dx) / 3, pts[i-1].dy);
      final c2 = Offset(pts[i].dx  - (pts[i].dx - pts[i-1].dx) / 3, pts[i].dy);
      linePath.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, pts[i].dx, pts[i].dy);
    }

    // Gradient fill under line
    final fillPath = Path()..moveTo(pts[0].dx, bottom);
    for (final p in pts) fillPath.lineTo(p.dx, p.dy);
    fillPath.lineTo(pts.last.dx, bottom);
    fillPath.close();
    canvas.drawPath(fillPath, Paint()
      ..shader = LinearGradient(colors: [
        BrokaColors.neonCyan.withOpacity(0.28 + 0.08 * glowT),
        BrokaColors.neonBlue.withOpacity(0.12),
        BrokaColors.bg.withOpacity(0.0),
      ], begin: Alignment.topCenter, end: Alignment.bottomCenter)
          .createShader(Rect.fromLTWH(0, 0, size.width, size.height)));

    // Glow shadow behind line
    canvas.drawPath(linePath, Paint()
      ..color = BrokaColors.neonCyan.withOpacity(0.32 + 0.10 * glowT)
      ..strokeWidth = 7
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));

    // Main glowing line — gold→blue→cyan
    canvas.drawPath(linePath, Paint()
      ..shader = const LinearGradient(
        colors: [BrokaColors.gold, BrokaColors.neonBlue, BrokaColors.neonCyan],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round);

    // Dot markers
    for (final p in pts) {
      canvas.drawCircle(p, 7,
          Paint()
            ..color = BrokaColors.neonCyan.withOpacity(0.18 + 0.10 * glowT)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      canvas.drawCircle(p, 3.5, Paint()..color = BrokaColors.bgCard);
      canvas.drawCircle(p, 2.5, Paint()..color = BrokaColors.neonCyan);
      canvas.drawCircle(p, 1.2, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_GlowLineChartPainter o) =>
      o.values != values || o.glowT != glowT;
}

// ── Futuristic Day-views Bar Chart (Mon–Sun) ──────────────────────────────────
class _DayViewsPainter extends CustomPainter {
  final List<double> values;
  static const _labels = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  _DayViewsPainter({required this.values});

  @override
  void paint(Canvas canvas, Size size) {
    final n      = values.length;
    const gap    = 5.0;
    final bottom = size.height - 18.0;
    final barW   = (size.width - gap * (n - 1)) / n;
    final maxIdx = values.indexOf(values.reduce(math.max));
    final tp     = TextPainter(textDirection: TextDirection.ltr);

    // Grid
    for (int g = 1; g <= 4; g++) {
      final y = bottom - (bottom - 2) * g / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y),
          Paint()..color = BrokaColors.border..strokeWidth = 0.6);
    }

    for (int i = 0; i < n; i++) {
      final left = i * (barW + gap);
      final barH = (bottom - 2) * values[i].clamp(0.02, 1.0);
      final top  = bottom - barH;
      final rr   = RRect.fromRectAndCorners(
        Rect.fromLTWH(left, top, barW, barH),
        topLeft: const Radius.circular(5), topRight: const Radius.circular(5));

      canvas.drawRRect(rr, Paint()
        ..shader = LinearGradient(
          colors: [
            const Color(0xFF3B82F6).withOpacity(0.85),
            const Color(0xFF8B5CF6),
            const Color(0xFF8B5CF6),
          ],
          begin: Alignment.bottomCenter, end: Alignment.topCenter,
        ).createShader(Rect.fromLTWH(left, top, barW, barH)));

      if (i == maxIdx) {
        canvas.drawRRect(rr.inflate(2), Paint()
          ..color = const Color(0xFF8B5CF6).withOpacity(0.28)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
        canvas.drawLine(Offset(left + 2, top), Offset(left + barW - 2, top),
            Paint()
              ..color = const Color(0xFF00E5CC)
              ..strokeWidth = 1.5
              ..strokeCap = StrokeCap.round);
      }

      tp.text = TextSpan(text: _labels[i],
          style: const TextStyle(color: BrokaColors.textLow, fontSize: 8.5));
      tp.layout();
      tp.paint(canvas, Offset(left + barW / 2 - tp.width / 2, bottom + 4));
    }
  }

  @override
  bool shouldRepaint(_DayViewsPainter o) => o.values != values;
}

// ── Futuristic Week-views Line Chart (6 weeks) ────────────────────────────────
class _WeekViewsPainter extends CustomPainter {
  final List<double> values;
  _WeekViewsPainter({required this.values});

  @override
  void paint(Canvas canvas, Size size) {
    final n      = values.length;
    if (n < 2) return;
    final bottom  = size.height - 16.0;
    final usableH = bottom - 4.0;
    final step    = size.width / (n - 1);

    final pts = List.generate(n,
        (i) => Offset(i * step, bottom - usableH * values[i].clamp(0.05, 1.0)));

    // Fill
    final fillPath = Path()..moveTo(pts.first.dx, bottom);
    for (final p in pts) fillPath.lineTo(p.dx, p.dy);
    fillPath.lineTo(pts.last.dx, bottom);
    fillPath.close();
    canvas.drawPath(fillPath, Paint()
      ..shader = LinearGradient(
        colors: [
          const Color(0xFF8B5CF6).withOpacity(0.35),
          const Color(0xFF00E5CC).withOpacity(0.05)],
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)));

    final linePath = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (int i = 1; i < n; i++) linePath.lineTo(pts[i].dx, pts[i].dy);

    // Shadow
    canvas.drawPath(linePath, Paint()
      ..color = const Color(0xFF8B5CF6).withOpacity(0.30)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));

    // Main line
    canvas.drawPath(linePath, Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF8B5CF6), Color(0xFF3B82F6), Color(0xFF00E5CC)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round);

    // Dots
    for (final p in pts) {
      canvas.drawCircle(p, 5, Paint()
        ..color = const Color(0xFF8B5CF6).withOpacity(0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawCircle(p, 3, Paint()..color = const Color(0xFF00E5CC));
      canvas.drawCircle(p, 1.5, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_WeekViewsPainter o) => o.values != values;
}

// ── Radar Chart ───────────────────────────────────────────────────────────────
class _RadarChartPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  final List<Color>  colors;
  _RadarChartPainter({required this.values, required this.labels, required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2; final cy = size.height / 2;
    final r  = math.min(cx, cy) - 28;
    final n  = values.length;

    // Grid rings
    for (int ring = 1; ring <= 4; ring++) {
      final rr  = r * ring / 4;
      final pts = List.generate(n, (i) {
        final a = 2 * math.pi * i / n - math.pi / 2;
        return Offset(cx + rr * math.cos(a), cy + rr * math.sin(a));
      });
      final path = Path()..moveTo(pts[0].dx, pts[0].dy);
      for (int i = 1; i < n; i++) path.lineTo(pts[i].dx, pts[i].dy);
      path.close();
      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..color = BrokaColors.border
        ..strokeWidth = 0.8);
    }
    for (int i = 0; i < n; i++) {
      final a = 2 * math.pi * i / n - math.pi / 2;
      canvas.drawLine(Offset(cx, cy),
        Offset(cx + r * math.cos(a), cy + r * math.sin(a)),
        Paint()..color = BrokaColors.border..strokeWidth = 0.8);
    }

    // Data polygon
    final dp = Path();
    for (int i = 0; i < n; i++) {
      final a  = 2 * math.pi * i / n - math.pi / 2;
      final pt = Offset(cx + r * values[i] * math.cos(a), cy + r * values[i] * math.sin(a));
      if (i == 0) dp.moveTo(pt.dx, pt.dy); else dp.lineTo(pt.dx, pt.dy);
    }
    dp.close();
    canvas.drawPath(dp, Paint()
      ..style = PaintingStyle.fill..color = BrokaColors.gold.withOpacity(0.20));
    canvas.drawPath(dp, Paint()
      ..style = PaintingStyle.stroke..color = BrokaColors.gold..strokeWidth = 2.0);

    // Dots + labels
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i < n; i++) {
      final a  = 2 * math.pi * i / n - math.pi / 2;
      final pt = Offset(cx + r * values[i] * math.cos(a), cy + r * values[i] * math.sin(a));
      canvas.drawCircle(pt, 4, Paint()..color = colors[i % colors.length]);
      final lx = cx + (r + 22) * math.cos(a);
      final ly = cy + (r + 22) * math.sin(a);
      tp.text = TextSpan(
        text: '${labels[i]}\n${(values[i] * 10).toStringAsFixed(1)}',
        style: TextStyle(color: colors[i % colors.length], fontSize: 9, fontWeight: FontWeight.w700));
      tp.layout();
      tp.paint(canvas, Offset(lx - tp.width / 2, ly - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_RadarChartPainter o) => true;
}

// ── Bar Chart (kept for compatibility) ───────────────────────────────────────
class _BarChartPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  final Color        color;
  _BarChartPainter({required this.values, required this.labels, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final n    = values.length;
    final barW = (size.width - (n - 1) * 6) / n;
    final tp   = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i < n; i++) {
      final left = i * (barW + 6);
      final barH = (size.height - 20) * values[i];
      final top  = size.height - 20 - barH;
      final rr   = RRect.fromRectAndCorners(
        Rect.fromLTWH(left, top, barW, barH),
        topLeft: const Radius.circular(4), topRight: const Radius.circular(4));
      canvas.drawRRect(rr, Paint()
        ..shader = LinearGradient(
          colors: [color.withOpacity(0.9), color.withOpacity(0.4)],
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
        ).createShader(Rect.fromLTWH(left, top, barW, barH)));
      tp.text = TextSpan(text: labels[i],
          style: const TextStyle(color: BrokaColors.textLow, fontSize: 9));
      tp.layout();
      tp.paint(canvas, Offset(left + barW / 2 - tp.width / 2, size.height - 14));
    }
  }

  @override
  bool shouldRepaint(_BarChartPainter o) => false;
}
