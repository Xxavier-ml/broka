// BROKA - Home Screen
// GPS-first location, search history, tabbed layout: Goods / Brokers / House Hunting / Traders
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../models/listing.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  int _navIndex = 0;
  List<Listing> _listings = [];
  bool _loading = true;
  String? _loadError;
  Timer? _tickerTimer;
  double _tickerShift = 0;
  String? _locationLabel;
  bool _gettingLocation = false;
  late AnimationController _pulseCtrl;
  late TabController _tabCtrl;

  // Stats
  int    _totalListings = 0;
  int    _liveAuctions  = 0;
  double _marketVolume  = 0;
  bool   _statsLoaded   = false;

  // Search history
  List<String> _searchHistory = [];

  // Filters
  double _maxPrice = 5000000;
  double _priceFilter = 5000000;
  bool _showFilters = false;
  String? _locationFilter;

  static const _tabs = ['Goods', 'Brokers', 'House Hunting', 'Traders'];
  static const _tabCategories = ['', 'broker', 'Property', 'trader'];
  static const _navItems = [
    {'icon': Icons.grid_view_rounded,      'label': 'Home'},
    {'icon': Icons.inbox_outlined,         'label': 'Inbox'},
    {'icon': Icons.add_circle_outline,     'label': 'Sell'},
    {'icon': Icons.auto_awesome_rounded,   'label': 'Zeno'},
    {'icon': Icons.person_outline_rounded, 'label': 'Profile'},
  ];

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  String get _greetingText {
    final name = ApiService.currentUserName;
    if (name != null && name.isNotEmpty) return '$_greeting, ${name.split(' ').first} 👋';
    return _greeting;
  }

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _tabs.length, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) _loadListings();
    });
    _loadListings();
    _loadStats();
    _detectLocation();
    _loadSearchHistory();
    _tickerTimer = Timer.periodic(const Duration(milliseconds: 40),
        (_) { if (mounted) setState(() => _tickerShift -= 0.6); });
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    _pulseCtrl.dispose();
    _tabCtrl.dispose();
    super.dispose();
  }

  // ── Search History ────────────────────────────────────────────────────────

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('search_history') ?? [];
    if (mounted) setState(() => _searchHistory = list);
  }

  Future<void> _addSearchHistory(String query) async {
    if (query.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('search_history') ?? [];
    list.remove(query);
    list.insert(0, query);
    if (list.length > 10) list.removeRange(10, list.length);
    await prefs.setStringList('search_history', list);
    if (mounted) setState(() => _searchHistory = list);
  }

  Future<void> _clearSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('search_history');
    if (mounted) setState(() => _searchHistory = []);
  }

  // ── Stats & Listings ─────────────────────────────────────────────────────

  Future<void> _loadStats() async {
    try {
      final s = await ApiService.getStats();
      if (mounted) setState(() {
        _totalListings = (s['total_listings'] as num?)?.toInt() ?? 0;
        _liveAuctions  = (s['live_auctions']  as num?)?.toInt() ?? 0;
        _marketVolume  = (s['market_volume']  as num?)?.toDouble() ?? 0;
        _statsLoaded   = true;
      });
    } catch (_) { if (mounted) setState(() => _statsLoaded = true); }
  }

  Future<void> _loadListings() async {
    setState(() { _loading = true; _loadError = null; });
    final tabIndex = _tabCtrl.index;
    final cat = _tabCategories[tabIndex];
    try {
      final data = await ApiService.getListings(
        category: cat.isEmpty ? null : cat,
        listingType: (cat == 'broker' || cat == 'trader') ? cat : null,
      );
      final filtered = data.where((l) => l.price <= _priceFilter).toList();
      // Pin featured listings to the top of the feed
      final now = DateTime.now().toUtc();
      filtered.sort((a, b) {
        final aFeat = a.isFeatured && (a.featuredUntil?.isAfter(now) ?? false);
        final bFeat = b.isFeatured && (b.featuredUntil?.isAfter(now) ?? false);
        if (aFeat && !bFeat) return -1;
        if (!aFeat && bFeat) return 1;
        return 0;
      });
      if (mounted) setState(() { _listings = filtered; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _listings = []; _loading = false;
        _loadError = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  // ── Location Detection (IP-based, no native GPS dependency) ─────────────

  Future<void> _detectLocation() async {
    setState(() => _gettingLocation = true);
    await _ipGeolocation();
  }

  Future<void> _ipGeolocation() async {
    try {
      final response = await http.get(
        Uri.parse('https://ipapi.co/json/'),
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final lat    = (data['latitude']  as num?)?.toDouble();
        final lng    = (data['longitude'] as num?)?.toDouble();
        final city   = data['city']       as String?;
        final region = data['region']     as String?;

        if (lat != null && lng != null) {
          await ApiService.updateLocation(lat, lng);
          // Try reverse geocoding for better locality name
          final revLabel = await _reverseGeocode(lat, lng);
          final label = revLabel ?? _buildLocationLabel(city, region);
          _setLoc(label.isNotEmpty ? label : _coordLabel(lat, lng));
          return;
        }
      }
    } catch (_) {}
    _setLoc('Kenya');
  }

  Future<String?> _reverseGeocode(double lat, double lng) async {
    try {
      final url = Uri.parse(
          'https://nominatim.openstreetmap.org/reverse?format=json'
          '&lat=$lat&lon=$lng&zoom=10&addressdetails=1');
      final resp = await http.get(url,
          headers: {'User-Agent': 'BrokaApp/2.3'})
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final d = jsonDecode(resp.body) as Map<String, dynamic>;
        final addr = d['address'] as Map<String, dynamic>?;
        if (addr != null) {
          final sub  = addr['suburb']      as String?;
          final town = addr['town']        as String?
              ?? addr['city']              as String?
              ?? addr['village']           as String?;
          final county = addr['county']   as String?
              ?? addr['state_district']   as String?;
          final parts = [sub ?? town, county].where((s) => s != null && s.isNotEmpty);
          if (parts.isNotEmpty) return parts.join(', ');
        }
      }
    } catch (_) {}
    return null;
  }

  String _buildLocationLabel(String? city, String? region) {
    final parts = [city, region].where((s) => s != null && s.isNotEmpty);
    return parts.join(', ');
  }

  void _setLoc(String l) {
    if (mounted) setState(() { _locationLabel = l; _gettingLocation = false; });
  }

  String _coordLabel(double lat, double lng) {
    // Siaya County sub-localities (GPS fallback for when Nominatim is unavailable)
    if (lat >  0.03 && lat < 0.12 && lng > 34.10 && lng < 34.22) return 'Ugunja, Siaya';
    if (lat >  0.25 && lat < 0.40 && lng > 34.05 && lng < 34.20) return 'Bondo, Siaya';
    if (lat > -0.07 && lat < 0.05 && lng > 34.25 && lng < 34.40) return 'Siaya Town';
    if (lat > -0.20 && lat < 0.00 && lng > 34.43 && lng < 34.58) return 'Kisumu';
    if (lat > -0.50 && lat < 0.50 && lng > 33.80 && lng < 34.80) return 'Siaya, Kenya';
    // Major Kenyan cities
    if (lat > -1.50 && lat < -1.10 && lng > 36.60 && lng < 37.10) return 'Nairobi';
    if (lat > -0.20 && lat < 0.20  && lng > 34.60 && lng < 35.00) return 'Kisumu';
    if (lat >  0.00 && lat < 0.60  && lng > 35.00 && lng < 35.50) return 'Eldoret';
    if (lat > -4.20 && lat < -3.80 && lng > 39.50 && lng < 40.00) return 'Mombasa';
    if (lat > -0.60 && lat < -0.20 && lng > 37.00 && lng < 37.30) return 'Thika';
    if (lat > -0.45 && lat < -0.15 && lng > 36.90 && lng < 37.15) return 'Ruiru';
    if (lat > -1.10 && lat < -0.80 && lng > 37.00 && lng < 37.30) return 'Machakos';
    if (lat > -0.40 && lat < 0.00  && lng > 35.25 && lng < 35.55) return 'Nakuru';
    if (lat > -0.70 && lat < -0.35 && lng > 36.05 && lng < 36.35) return 'Naivasha';
    return '${lat.toStringAsFixed(2)}°N, ${lng.toStringAsFixed(2)}°E';
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _onNav(int i) {
    setState(() => _navIndex = i);
    if (i == 0) return;
    final routes = ['', '/inbox', '/sell', '/zeno', '/profile'];
    Navigator.pushNamed(context, routes[i]).then((_) {
      if (mounted) { setState(() => _navIndex = 0); _loadListings(); _loadStats(); }
    });
  }

  void _openSearch() {
    showSearch(
      context: context,
      delegate: _ListingSearchDelegate(
        history: _searchHistory,
        onSearch: (q) => _addSearchHistory(q),
        onClearHistory: _clearSearchHistory,
      ),
    );
  }

  String _fmtVol(double v) {
    if (v >= 1000000) return 'KES ${(v/1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return 'KES ${(v/1000).toStringAsFixed(0)}K';
    return 'KES 0';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: BrokaColors.headerGradColors,
              begin: Alignment.topCenter, end: Alignment.bottomCenter)),
        child: SafeArea(child: Column(children: [
          _buildHeader(),
          _buildLocationBar(),
          _buildTickerStrip(),
          _buildStatRow(),
          _buildTabBar(),
          if (_showFilters) _buildFilterPanel(),
          Expanded(child: _buildFeed()),
        ])),
      ),
      bottomNavigationBar: _buildNav(),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader() => Container(
    padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: BrokaColors.border.withOpacity(0.5))),
    ),
    child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 6, height: 6, decoration: const BoxDecoration(
              shape: BoxShape.circle, color: BrokaColors.neonGreen)),
          const SizedBox(width: 5),
          Text(_greetingText, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 12, letterSpacing: 0.3)),
        ]),
        const SizedBox(height: 3),
        ShaderMask(
          shaderCallback: (b) => const LinearGradient(
              colors: [BrokaColors.neonPurple, BrokaColors.neonBlue])
              .createShader(b),
          child: const Text('BROKA', style: TextStyle(
              color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900,
              letterSpacing: 2.0)),
        ),
      ])),
      // Filter toggle
      GestureDetector(
        onTap: () => setState(() => _showFilters = !_showFilters),
        child: Container(
          width: 38, height: 38, margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: _showFilters
                ? BrokaColors.neonPurple.withOpacity(0.2) : BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _showFilters
                ? BrokaColors.neonPurple : BrokaColors.border),
          ),
          child: Icon(Icons.tune_rounded,
              color: _showFilters ? BrokaColors.neonPurple : BrokaColors.textMid,
              size: 18),
        ),
      ),
      // Search
      GestureDetector(
        onTap: _openSearch,
        child: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: BrokaColors.border),
          ),
          child: const Icon(Icons.search_rounded,
              color: BrokaColors.textMid, size: 20),
        ),
      ),
    ]),
  );

  // ── Location Bar ─────────────────────────────────────────────────────────

  Widget _buildLocationBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    child: Row(children: [
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        child: _gettingLocation
            ? SizedBox(key: const ValueKey('loading'),
                width: 14, height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: BrokaColors.neonBlue.withOpacity(0.7)))
            : const Icon(Icons.location_on_rounded, key: ValueKey('icon'),
                size: 14, color: BrokaColors.neonBlue),
      ),
      const SizedBox(width: 6),
      Expanded(child: Text(
        _locationLabel ?? (_gettingLocation ? 'Detecting location...' : 'Kenya'),
        style: const TextStyle(color: BrokaColors.textMid, fontSize: 12),
        maxLines: 1, overflow: TextOverflow.ellipsis,
      )),
      // Refresh location
      GestureDetector(
        onTap: _gettingLocation ? null : _detectLocation,
        child: Icon(Icons.my_location_rounded,
            size: 14, color: _gettingLocation
                ? BrokaColors.textLow : BrokaColors.neonBlue),
      ),
    ]),
  );

  // ── Ticker ────────────────────────────────────────────────────────────────

  Widget _buildTickerStrip() {
    const items = [
      '🔥 Hot Deal: Toyota Axio 2015 · KES 1.2M',
      '🏆 #1 Marketplace in Western Kenya',
      '⚡ 247 live deals closing today',
      '🤝 AI-mediated · Escrow protected · Fair pricing',
      '📍 Deals near you updated every 30 min',
    ];
    final text = items.join('   •   ');
    return Container(
      height: 28,
      color: BrokaColors.bgMid,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      child: LayoutBuilder(builder: (ctx, constraints) {
        final textW = text.length * 7.0;
        return Transform.translate(
          offset: Offset(_tickerShift % textW, 0),
          child: Row(children: [
            Text(text, style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 11)),
            const SizedBox(width: 40),
            Text(text, style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 11)),
          ]),
        );
      }),
    );
  }

  // ── Stats Row ─────────────────────────────────────────────────────────────

  Widget _buildStatRow() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(children: [
      _statChip('${_statsLoaded ? _totalListings : '-'}', 'Listings', BrokaColors.neonPurple),
      const SizedBox(width: 8),
      _statChip('${_statsLoaded ? _liveAuctions : '-'}', 'Live', BrokaColors.danger),
      const SizedBox(width: 8),
      _statChip(_statsLoaded ? _fmtVol(_marketVolume) : '-', 'Volume', BrokaColors.neonGreen),
    ]),
  );

  Widget _statChip(String value, String label, Color color) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(children: [
        Text(value, style: TextStyle(color: color,
            fontSize: 16, fontWeight: FontWeight.w800)),
        Text(label, style: const TextStyle(
            color: BrokaColors.textLow, fontSize: 10)),
      ]),
    ),
  );

  // ── Tab Bar ───────────────────────────────────────────────────────────────

  Widget _buildTabBar() => Container(
    color: BrokaColors.bgMid,
    child: TabBar(
      controller: _tabCtrl,
      isScrollable: true,
      indicatorColor: BrokaColors.neonPurple,
      indicatorWeight: 2,
      labelColor: BrokaColors.neonPurple,
      unselectedLabelColor: BrokaColors.textMid,
      labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
      tabs: _tabs.map((t) => Tab(text: t)).toList(),
    ),
  );

  // ── Filter Panel ──────────────────────────────────────────────────────────

  Widget _buildFilterPanel() => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    decoration: BoxDecoration(
      color: BrokaColors.bgMid,
      border: Border(bottom: BorderSide(color: BrokaColors.border)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.attach_money_rounded, color: BrokaColors.neonGreen, size: 16),
        const SizedBox(width: 6),
        const Text('Max Price', style: TextStyle(
            color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w600)),
        const Spacer(),
        Text(_formatPrice(_priceFilter), style: const TextStyle(
            color: BrokaColors.neonGreen, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
      SliderTheme(
        data: SliderThemeData(
          activeTrackColor: BrokaColors.neonPurple,
          inactiveTrackColor: BrokaColors.border,
          thumbColor: BrokaColors.neonPurple,
          overlayColor: BrokaColors.neonPurple.withOpacity(0.15),
          trackHeight: 3,
        ),
        child: Slider(
          value: _priceFilter,
          min: 0,
          max: _maxPrice,
          divisions: 50,
          onChanged: (v) => setState(() => _priceFilter = v),
          onChangeEnd: (_) => _loadListings(),
        ),
      ),
      Row(children: [
        const Text('KES 0', style: TextStyle(color: BrokaColors.textLow, fontSize: 10)),
        const Spacer(),
        Text(_formatPrice(_maxPrice),
            style: const TextStyle(color: BrokaColors.textLow, fontSize: 10)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        const Icon(Icons.location_on_rounded, color: BrokaColors.neonBlue, size: 14),
        const SizedBox(width: 6),
        Expanded(
          child: GestureDetector(
            onTap: () {
              showDialog(context: context, builder: (ctx) => _LocationFilterDialog(
                current: _locationFilter,
                onSet: (v) {
                  setState(() => _locationFilter = v?.trim().isEmpty == true ? null : v);
                  _loadListings();
                },
              ));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _locationFilter != null
                    ? BrokaColors.neonBlue : BrokaColors.border),
              ),
              child: Text(
                _locationFilter ?? 'All locations',
                style: TextStyle(
                    color: _locationFilter != null
                        ? BrokaColors.neonBlue : BrokaColors.textLow,
                    fontSize: 12),
              ),
            ),
          ),
        ),
        if (_locationFilter != null) ...[
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () { setState(() => _locationFilter = null); _loadListings(); },
            child: const Icon(Icons.close_rounded,
                color: BrokaColors.textMid, size: 16),
          ),
        ],
      ]),
    ]),
  );

  String _formatPrice(double v) {
    if (v >= 1000000) return 'KES ${(v/1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return 'KES ${(v/1000).toStringAsFixed(0)}K';
    return 'KES ${v.toStringAsFixed(0)}';
  }

  // ── Feed ──────────────────────────────────────────────────────────────────

  Widget _buildFeed() {
    if (_loading) return const Center(child: CircularProgressIndicator(
        color: BrokaColors.neonPurple));
    if (_loadError != null) return _errorState();
    if (_listings.isEmpty) return _emptyState();
    return RefreshIndicator(
      onRefresh: () async { await _loadListings(); await _loadStats(); },
      color: BrokaColors.neonPurple,
      backgroundColor: BrokaColors.bgCard,
      child: PageView.builder(
        scrollDirection: Axis.vertical,
        itemCount: _listings.length,
        itemBuilder: (_, i) => _FeedCard(
          listing: _listings[i],
          onTap: () => Navigator.pushNamed(context, '/product',
              arguments: _listings[i]).then((_) => _loadListings()),
        ),
      ),
    );
  }

  Widget _errorState() => Center(child: Column(
    mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.cloud_off_rounded, color: BrokaColors.textLow, size: 48),
    const SizedBox(height: 12),
    Text('Could not load listings', style: const TextStyle(color: BrokaColors.textMid)),
    const SizedBox(height: 8),
    TextButton(onPressed: _loadListings, child: const Text('Retry',
        style: TextStyle(color: BrokaColors.neonPurple))),
  ]));

  Widget _emptyState() => Center(child: Column(
    mainAxisSize: MainAxisSize.min, children: [
    Text(_tabs[_tabCtrl.index] == 'Goods' ? '📦'
        : _tabs[_tabCtrl.index] == 'House Hunting' ? '🏠'
        : _tabs[_tabCtrl.index] == 'Brokers' ? '🤝' : '🛒',
        style: const TextStyle(fontSize: 48)),
    const SizedBox(height: 12),
    Text('No ${_tabs[_tabCtrl.index].toLowerCase()} listings yet',
        style: const TextStyle(color: BrokaColors.textMid)),
    const SizedBox(height: 4),
    const Text('Be the first to post!',
        style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
  ]));

  // ── Bottom Nav ────────────────────────────────────────────────────────────

  Widget _buildNav() => Container(
    decoration: BoxDecoration(
      color: BrokaColors.bgMid,
      border: const Border(top: BorderSide(color: BrokaColors.border)),
    ),
    child: SafeArea(top: false, child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(_navItems.length, (i) {
          final item = _navItems[i];
          final selected = _navIndex == i;
          return GestureDetector(
            onTap: () => _onNav(i),
            behavior: HitTestBehavior.opaque,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(item['icon'] as IconData,
                  size: 24,
                  color: selected ? BrokaColors.neonPurple : BrokaColors.textLow),
              const SizedBox(height: 3),
              Text(item['label'] as String,
                  style: TextStyle(
                      fontSize: 10,
                      color: selected ? BrokaColors.neonPurple : BrokaColors.textLow,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
            ]),
          );
        }),
      ),
    )),
  );
}

// ── Location Filter Dialog ────────────────────────────────────────────────────
class _LocationFilterDialog extends StatefulWidget {
  final String? current;
  final ValueChanged<String?> onSet;
  const _LocationFilterDialog({required this.current, required this.onSet});

  @override
  State<_LocationFilterDialog> createState() => _LocationFilterDialogState();
}

class _LocationFilterDialogState extends State<_LocationFilterDialog> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.current ?? '');
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: BrokaColors.bgMid,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: BrokaColors.border)),
      title: const Text('Filter by Location',
          style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
      content: TextField(
        controller: _ctrl,
        style: const TextStyle(color: BrokaColors.textHigh),
        decoration: const InputDecoration(
          hintText: 'e.g. Kisumu, Nairobi, Siaya',
          prefixIcon: Icon(Icons.location_on_rounded,
              color: BrokaColors.neonBlue, size: 18),
        ),
        onSubmitted: (v) { widget.onSet(v.isEmpty ? null : v); Navigator.pop(context); },
      ),
      actions: [
            IconButton(
              tooltip: 'Seller Dashboard',
              icon: const Icon(Icons.dashboard_rounded, color: BrokaColors.neonPurple),
              onPressed: () => Navigator.pushNamed(context, '/seller-dashboard'),
            ),
        TextButton(
          onPressed: () { widget.onSet(null); Navigator.pop(context); },
          child: const Text('Clear', style: TextStyle(color: BrokaColors.textMid)),
        ),
        ElevatedButton(
          onPressed: () { widget.onSet(_ctrl.text.isEmpty ? null : _ctrl.text);
            Navigator.pop(context); },
          style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.neonPurple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

// ── Feed Card ─────────────────────────────────────────────────────────────────
class _FeedCard extends StatefulWidget {
  final Listing listing;
  final VoidCallback onTap;
  const _FeedCard({required this.listing, required this.onTap});

  @override
  State<_FeedCard> createState() => _FeedCardState();
}

class _FeedCardState extends State<_FeedCard> {
  VideoPlayerController? _ctrl;
  bool _videoReady = false;

  bool get _hasVideo =>
      widget.listing.feedVideo?.isNotEmpty == true;

  bool get _isFeaturedActive {
    final l = widget.listing;
    if (!l.isFeatured) return false;
    final until = l.featuredUntil;
    if (until == null) return false;
    return until.isAfter(DateTime.now().toUtc());
  }

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  void _initVideo() {
    final videoData = widget.listing.feedVideo;
    if (videoData == null || videoData.isEmpty) return;
    try {
      final bytes = base64Decode(videoData);
      final uri   = Uri.dataFromBytes(bytes, mimeType: 'video/mp4');
      _ctrl = VideoPlayerController.contentUri(uri)
        ..setLooping(true)
        ..initialize().then((_) {
          if (mounted) {
            setState(() => _videoReady = true);
            _ctrl!.play();
          }
        }).catchError((_) {});
    } catch (_) {
      try {
        _ctrl = VideoPlayerController.networkUrl(Uri.parse(videoData))
          ..setLooping(true)
          ..initialize().then((_) {
            if (mounted) {
              setState(() => _videoReady = true);
              _ctrl!.play();
            }
          }).catchError((_) {});
      } catch (_) {}
    }
  }

  @override
  void dispose() { _ctrl?.dispose(); super.dispose(); }

  List<String> get _photos {
    final raw = widget.listing.verifiedPhotos;
    if (raw == null || raw.isEmpty) return [];
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.listing;
    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(fit: StackFit.expand, children: [
        _buildBackground(),
        Container(decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.transparent,
                Color(0xCC000000), Color(0xEE000000)],
            stops: [0, 0.4, 0.75, 1.0],
          ),
        )),
        Positioned(left: 0, right: 0, bottom: 0, child: _buildOverlay(l)),
        Positioned(top: 16, right: 16, child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(l.category, style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
        )),
        if (_hasVideo && !_videoReady)
          Center(child: Container(
            width: 48, height: 48,
            decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
            child: const Icon(Icons.play_circle_outline_rounded, color: Colors.white, size: 32),
          )),
        if (_hasVideo)
          Positioned(top: 16, left: 16, child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: BrokaColors.danger.withOpacity(0.85),
              borderRadius: BorderRadius.circular(6)),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.videocam_rounded, size: 10, color: Colors.white),
              SizedBox(width: 4),
              Text('VIDEO', style: TextStyle(
                  color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
            ]),
          )),
        // Featured badge - glowing purple pill shown when listing is boosted
        if (_isFeaturedActive)
          Positioned(top: _hasVideo ? 44 : 16, left: 16, child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [BoxShadow(
                  color: Color(0x88A855F7), blurRadius: 12, spreadRadius: 1)],
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.rocket_launch_rounded, size: 10, color: Colors.white),
              SizedBox(width: 4),
              Text('FEATURED', style: TextStyle(
                  color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900,
                  letterSpacing: 0.5)),
            ]),
          )),
      ]),
    );
  }

  Widget _buildBackground() {
    if (_videoReady && _ctrl != null) {
      return FittedBox(fit: BoxFit.cover,
          child: SizedBox(
            width:  _ctrl!.value.size.width,
            height: _ctrl!.value.size.height,
            child:  VideoPlayer(_ctrl!)));
    }
    final photos = _photos;
    if (photos.isNotEmpty) {
      try {
        return Image.memory(base64Decode(photos.first),
            fit: BoxFit.cover, width: double.infinity, height: double.infinity);
      } catch (_) {}
    }
    return Container(
      decoration: const BoxDecoration(
          gradient: LinearGradient(colors: BrokaColors.cardGradColors)),
      child: Center(child: Text(widget.listing.emoji,
          style: const TextStyle(fontSize: 80))),
    );
  }

  Widget _buildOverlay(Listing l) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Container(
          width: 32, height: 32,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [BrokaColors.gradStart, BrokaColors.gradMid])),
          child: Center(child: Text(
            (l.sellerName ?? 'S')[0].toUpperCase(),
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14))),
        ),
        const SizedBox(width: 8),
        Text(l.sellerName ?? 'Seller',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
        const SizedBox(width: 6),
        const Icon(Icons.verified_rounded, size: 13, color: BrokaColors.neonPurple),
      ]),
      const SizedBox(height: 8),
      Text(l.name, style: const TextStyle(
          color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
          maxLines: 2, overflow: TextOverflow.ellipsis),
      const SizedBox(height: 6),
      Row(children: [
        const Icon(Icons.location_on_outlined, size: 13, color: Colors.white70),
        const SizedBox(width: 4),
        Text(l.locationName ?? 'Kenya',
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        ShaderMask(
          shaderCallback: (b) => const LinearGradient(
            colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]).createShader(b),
          child: Text(l.formattedPrice, style: const TextStyle(
              color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFFFF4D6D), Color(0xFFFF8C42)]),
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [BoxShadow(color: Color(0x88FF4D6D), blurRadius: 12)],
          ),
          child: const Text('View Deal',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
        ),
      ]),
    ]),
  );
}

// ── Search Delegate with History ──────────────────────────────────────────────
class _ListingSearchDelegate extends SearchDelegate<String> {
  final List<String> history;
  final ValueChanged<String> onSearch;
  final VoidCallback onClearHistory;
  List<Map<String, dynamic>> _results = [];
  Timer? _debounce;

  _ListingSearchDelegate({
    required this.history,
    required this.onSearch,
    required this.onClearHistory,
  });

  @override
  String get searchFieldLabel => 'Search listings, traders, locations...';

  @override
  ThemeData appBarTheme(BuildContext context) => Theme.of(context).copyWith(
    appBarTheme: const AppBarTheme(backgroundColor: BrokaColors.bgCard),
    inputDecorationTheme: const InputDecorationTheme(
        hintStyle: TextStyle(color: BrokaColors.textLow), border: InputBorder.none),
    textTheme: const TextTheme(
        titleLarge: TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
  );

  @override
  List<Widget> buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(icon: const Icon(Icons.clear, color: BrokaColors.textMid),
          onPressed: () { query = ''; showSuggestions(context); }),
  ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back_ios_new_rounded,
        color: BrokaColors.textMid, size: 18),
    onPressed: () => close(context, ''));

  @override
  Widget buildResults(BuildContext context) {
    onSearch(query);
    return _buildBody(context);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.isEmpty) return _buildHistory(context);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final users = await ApiService.searchUsers(query.trim());
        _results = users.cast<Map<String, dynamic>>();
        showResults(context);
      } catch (_) { _results = []; }
    });
    return _buildBody(context);
  }

  Widget _buildHistory(BuildContext context) {
    if (history.isEmpty) {
      return Container(color: BrokaColors.bg,
        child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.search_rounded, size: 48, color: BrokaColors.textLow),
          SizedBox(height: 12),
          Text('Search for traders, listings, or locations',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 14),
              textAlign: TextAlign.center),
        ])));
    }
    return Container(color: BrokaColors.bg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(children: [
          const Text('RECENT SEARCHES', style: TextStyle(
              color: BrokaColors.textLow, fontSize: 10,
              fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          const Spacer(),
          GestureDetector(
            onTap: () { onClearHistory(); showSuggestions(context); },
            child: const Text('Clear', style: TextStyle(
                color: BrokaColors.neonPurple, fontSize: 12)),
          ),
        ]),
      ),
      Expanded(child: ListView.builder(
        itemCount: history.length,
        itemBuilder: (_, i) => ListTile(
          leading: const Icon(Icons.history_rounded,
              color: BrokaColors.textLow, size: 18),
          title: Text(history[i], style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 14)),
          trailing: const Icon(Icons.north_west_rounded,
              color: BrokaColors.textLow, size: 14),
          onTap: () { query = history[i]; showResults(context); },
        ),
      )),
    ]));
  }

  Widget _buildBody(BuildContext context) {
    if (_results.isEmpty && query.isNotEmpty) {
      return Container(color: BrokaColors.bg,
        child: Center(child: Text('No results for "$query"',
            style: const TextStyle(color: BrokaColors.textMid))));
    }
    return Container(color: BrokaColors.bg,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _results.length,
        itemBuilder: (_, i) {
          final u = _results[i];
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: BrokaColors.border),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: CircleAvatar(
                backgroundColor: BrokaColors.gradStart.withOpacity(0.3),
                backgroundImage: (u['profile_photo'] as String?)?.isNotEmpty == true
                    ? MemoryImage(base64Decode(u['profile_photo'] as String))
                    : null,
                child: (u['profile_photo'] as String?)?.isNotEmpty == true
                    ? null
                    : Text((u['name'] as String? ?? '?')[0].toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
              title: Text(u['name'] ?? '', style: const TextStyle(
                  color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
              subtitle: Row(children: [
                const Icon(Icons.star_rounded, size: 12, color: BrokaColors.gold),
                const SizedBox(width: 3),
                Text('${(u['rating'] as num?)?.toStringAsFixed(1) ?? '5.0'}  · ${u['completed_deals'] ?? 0} deals',
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
              ]),
              trailing: u['is_verified'] == true
                  ? const Icon(Icons.verified_rounded, color: BrokaColors.neonPurple, size: 18)
                  : null,
              onTap: () {
                close(context, u['id']?.toString() ?? '');
                Navigator.pushNamed(context, '/user-profile',
                    arguments: u['id']?.toString());
              },
            ),
          );
        },
      ),
    );
  }
}
