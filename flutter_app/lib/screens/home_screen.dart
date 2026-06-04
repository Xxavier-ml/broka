import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
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
  String? _filterCat;
  String? _loadError;
  Timer? _tickerTimer;
  double _tickerShift = 0;
  String? _locationLabel;
  bool _gettingLocation = false;
  late AnimationController _pulseCtrl;

  int    _totalListings = 0;
  int    _liveAuctions  = 0;
  double _marketVolume  = 0;
  bool   _statsLoaded   = false;

  static const _categories = ['All', 'Vehicles', 'Property', 'Electronics', 'Livestock'];
  static const _navItems = [
    {'icon': Icons.grid_view_rounded,      'label': 'Home'},
    {'icon': Icons.inbox_outlined,         'label': 'Inbox'},
    {'icon': Icons.add_circle_outline,     'label': 'Sell'},
    {'icon': Icons.psychology_outlined,    'label': 'AI'},
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
    _loadListings();
    _loadStats();
    _detectLocation();
    _tickerTimer = Timer.periodic(const Duration(milliseconds: 40),
        (_) { if (mounted) setState(() => _tickerShift -= 0.6); });
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  }

  @override
  void dispose() { _tickerTimer?.cancel(); _pulseCtrl.dispose(); super.dispose(); }

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

  Future<void> _detectLocation() async {
    setState(() => _gettingLocation = true);
    try {
      bool ok = await Geolocator.isLocationServiceEnabled();
      if (!ok) { _setLoc('Nairobi, Kenya'); return; }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        _setLoc('Nairobi, Kenya'); return;
      }
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 8));
      // Sync GPS to backend so distances between users are accurate
      await ApiService.updateLocation(pos.latitude, pos.longitude);
      _setLoc(_coordLabel(pos.latitude, pos.longitude));
    } catch (_) { _setLoc('Nairobi, Kenya'); }
  }

  void _setLoc(String l) {
    if (mounted) setState(() { _locationLabel = l; _gettingLocation = false; });
  }

  String _coordLabel(double lat, double lng) {
    if (lat > -1.5 && lat < -1.1 && lng > 36.6 && lng < 37.1) return 'Nairobi';
    if (lat > -0.2 && lat < 0.2  && lng > 34.6 && lng < 35.0) return 'Kisumu';
    if (lat > 0.0  && lat < 0.6  && lng > 35.0 && lng < 35.5) return 'Eldoret';
    if (lat > -4.2 && lat < -3.8 && lng > 39.5 && lng < 40.0) return 'Mombasa';
    return '${lat.toStringAsFixed(2)}, ${lng.toStringAsFixed(2)}';
  }

  Future<void> _loadListings() async {
    setState(() { _loading = true; _loadError = null; });
    try {
      final data = await ApiService.getListings(
          category: _filterCat == 'All' ? null : _filterCat);
      if (mounted) setState(() { _listings = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _listings = []; _loading = false;
        _loadError = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  void _onNav(int i) {
    setState(() => _navIndex = i);
    if (i == 0) return;
    final routes = ['', '/inbox', '/sell', '/xxeno', '/profile'];
    Navigator.pushNamed(context, routes[i]).then((_) {
      if (mounted) { setState(() => _navIndex = 0); _loadListings(); _loadStats(); }
    });
  }

  void _openSearch() =>
      showSearch(context: context, delegate: _UserSearchDelegate());

  String _fmtVol(double v) {
    if (v >= 1000000) return 'KES ${(v/1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return 'KES ${(v/1000).toStringAsFixed(0)}K';
    return 'KES 0';
  }

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
          _buildCategoryFilter(),
          Expanded(child: _buildFeed()),
        ])),
      ),
      bottomNavigationBar: _buildNav(),
    );
  }

  Widget _buildHeader() => Container(
    padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: BrokaColors.border.withOpacity(0.5))),
    ),
    child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 6, height: 6, decoration: const BoxDecoration(
            shape: BoxShape.circle, color: BrokaColors.neonGreen),),
          const SizedBox(width: 5),
          Text(_greetingText, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 12, letterSpacing: 0.3)),
        ]),
        const SizedBox(height: 3),
        ShaderMask(
          shaderCallback: (b) => const LinearGradient(
            colors: [BrokaColors.textHigh, BrokaColors.neonPurple],
          ).createShader(b),
          child: const Text('BROKA EXCHANGE', style: TextStyle(
            fontSize: 20, fontWeight: FontWeight.w900,
            color: Colors.white, letterSpacing: 2)),
        ),
      ])),
      GestureDetector(
        onTap: _openSearch,
        child: _iconBtn(Icons.search_rounded),
      ),
      const SizedBox(width: 8),
      GestureDetector(
        onTap: () => Navigator.pushNamed(context, '/inbox'),
        child: Stack(children: [
          _iconBtn(Icons.inbox_outlined),
          Positioned(top: 5, right: 5, child: AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, __) => Container(
              width: 10, height: 10,
              decoration: BoxDecoration(
                color: BrokaColors.danger, shape: BoxShape.circle,
                border: Border.all(color: BrokaColors.bg, width: 1.5),
                boxShadow: [BoxShadow(
                  color: BrokaColors.danger.withOpacity(0.5 + _pulseCtrl.value * 0.3),
                  blurRadius: 6 + _pulseCtrl.value * 6)],
              ))),
          ),
        ]),
      ),
    ]),
  );

  Widget _iconBtn(IconData icon) => Container(
    width: 42, height: 42,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      color: BrokaColors.bgCard,
      border: Border.all(color: BrokaColors.border),
      boxShadow: [BoxShadow(
        color: BrokaColors.neonPurple.withOpacity(0.04),
        blurRadius: 8)],
    ),
    child: Icon(icon, color: BrokaColors.textMid, size: 19),
  );

  Widget _buildLocationBar() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
    child: Row(children: [
      const Icon(Icons.my_location_rounded, color: BrokaColors.neonBlue, size: 13),
      const SizedBox(width: 5),
      _gettingLocation
          ? SizedBox(width: 80, height: 10,
              child: LinearProgressIndicator(
                color: BrokaColors.neonBlue,
                backgroundColor: BrokaColors.border,
                borderRadius: BorderRadius.circular(4)))
          : Text(_locationLabel ?? 'Kenya',
              style: const TextStyle(color: BrokaColors.neonBlue,
                  fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(width: 6),
      const Text('· Listings near you',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
    ]),
  );

  Widget _buildTickerStrip() {
    const items = [
      '📊 LIVE MARKET  — Check active listings',
      '🔒 ESCROW PROTECTED  · All deals secured',
      '🤖 AI BROKER  · Fair negotiation for all',
      '📍 LOCATION AWARE  · Find nearby traders',
      '✅ VERIFIED LISTINGS  · Camera-only photos',
    ];
    final str = items.join('     ·     ') + '     ·     ';
    return Container(
      height: 32,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFF150A35), Color(0xFF0D0728)]),
        border: Border.symmetric(horizontal: BorderSide(color: BrokaColors.border)),
      ),
      child: ClipRect(child: OverflowBox(
        alignment: Alignment.centerLeft, maxWidth: double.infinity,
        child: Transform.translate(
          offset: Offset(_tickerShift % 1400, 0),
          child: Row(children: List.generate(3, (_) => Text(str,
              style: const TextStyle(color: BrokaColors.textMid,
                  fontSize: 11, letterSpacing: 0.5)))),
        ),
      )),
    );
  }

  Widget _buildStatRow() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Row(children: [
      _statCard(_statsLoaded ? _fmtVol(_marketVolume) : '—',
          'MARKET VOL', BrokaColors.neonGreen, Icons.trending_up_rounded),
      const SizedBox(width: 8),
      _statCard(_statsLoaded ? '$_totalListings' : '—',
          'LISTINGS', BrokaColors.neonPurple, Icons.grid_view_rounded),
      const SizedBox(width: 8),
      _statCard(_statsLoaded ? '$_liveAuctions' : '—',
          'AUCTIONS', BrokaColors.neonPink, Icons.gavel_rounded),
    ]),
  );

  Widget _statCard(String val, String lbl, Color color, IconData icon) =>
    Expanded(child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withOpacity(0.08), color.withOpacity(0.02)],
          begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.2)),
        boxShadow: [BoxShadow(
            color: color.withOpacity(0.05), blurRadius: 12)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 15),
        const SizedBox(height: 7),
        Text(val, style: TextStyle(color: color,
            fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: -0.5)),
        const SizedBox(height: 3),
        Text(lbl, style: TextStyle(
            color: color.withOpacity(0.5), fontSize: 8,
            fontWeight: FontWeight.w700, letterSpacing: 1)),
      ]),
    ));

  Widget _buildCategoryFilter() => SizedBox(
    height: 42,
    child: ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _categories.length,
      itemBuilder: (_, i) {
        final cat = _categories[i];
        final active = (_filterCat ?? 'All') == cat;
        return GestureDetector(
          onTap: () { setState(() => _filterCat = cat == 'All' ? null : cat); _loadListings(); },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              gradient: active ? const LinearGradient(
                  colors: [BrokaColors.gradStart, BrokaColors.gradMid]) : null,
              color: active ? null : BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: active ? BrokaColors.neonPurple : BrokaColors.border),
              boxShadow: active ? const [BrokaColors.glowPurple] : null,
            ),
            child: Center(child: Text(cat, style: TextStyle(
                color: active ? Colors.white : BrokaColors.textMid,
                fontSize: 12, fontWeight: FontWeight.w700))),
          ),
        );
      },
    ),
  );

  Widget _buildFeed() {
    if (_loading) return const Center(child: CircularProgressIndicator(
        color: BrokaColors.neonPurple, strokeWidth: 1.5));

    if (_listings.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.store_mall_directory_outlined,
            size: 56, color: BrokaColors.textLow),
        const SizedBox(height: 16),
        const Text('No listings yet', style: TextStyle(
            color: BrokaColors.textMid, fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('Be the first to post something!',
            style: TextStyle(color: BrokaColors.textLow, fontSize: 13)),
        if (_loadError != null) ...[
          const SizedBox(height: 8),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(_loadError!, textAlign: TextAlign.center,
                style: const TextStyle(color: BrokaColors.danger, fontSize: 10))),
        ],
        const SizedBox(height: 24),
        GestureDetector(
          onTap: () => _onNav(2),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [BrokaColors.gradStart, BrokaColors.gradMid]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [BrokaColors.glowPurple],
            ),
            child: const Text('Post Your First Listing',
                style: TextStyle(color: Colors.white,
                    fontWeight: FontWeight.w800, fontSize: 14)),
          ),
        ),
      ]));
    }

    return RefreshIndicator(
      color: BrokaColors.neonPurple, backgroundColor: BrokaColors.bgCard,
      onRefresh: _loadListings,
      child: PageView.builder(
        scrollDirection: Axis.vertical,
        itemCount: _listings.length,
        itemBuilder: (_, i) => _ReelCard(
          listing: _listings[i],
          onTap: () => Navigator.pushNamed(
              context, '/product', arguments: _listings[i]),
        ),
      ),
    );
  }

  Widget _buildNav() => Container(
    decoration: BoxDecoration(
      gradient: const LinearGradient(
          colors: [Color(0xFF080520), Color(0xFF03000A)],
          begin: Alignment.topCenter, end: Alignment.bottomCenter),
      border: Border(top: BorderSide(color: BrokaColors.border.withOpacity(0.7))),
      boxShadow: [BoxShadow(
          color: BrokaColors.neonPurple.withOpacity(0.06),
          blurRadius: 20, offset: const Offset(0, -4))],
    ),
    child: SafeArea(top: false,
      child: Row(children: List.generate(_navItems.length, (i) {
        final item = _navItems[i];
        final active = _navIndex == i;
        final isSell = i == 2;
        return Expanded(child: isSell
          ? GestureDetector(onTap: () => _onNav(i),
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                height: 40,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [BrokaColors.gradStart, BrokaColors.gradMid]),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [BrokaColors.glowPurple],
                ),
                child: Center(child: Icon(item['icon'] as IconData,
                    color: Colors.white, size: 22)),
              ))
          : InkWell(onTap: () => _onNav(i),
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(item['icon'] as IconData, size: 22,
                      color: active ? BrokaColors.neonPurple : BrokaColors.textLow),
                  const SizedBox(height: 4),
                  Text(item['label'] as String, style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700,
                      color: active ? BrokaColors.neonPurple : BrokaColors.textLow)),
                  if (active) ...[
                    const SizedBox(height: 4),
                    Container(width: 16, height: 2, decoration: BoxDecoration(
                      color: BrokaColors.neonPurple,
                      borderRadius: BorderRadius.circular(1),
                      boxShadow: [BoxShadow(
                          color: BrokaColors.neonPurple.withOpacity(0.8),
                          blurRadius: 6)],
                    )),
                  ],
                ]),
              )));
      })),
    ),
  );
}

// ── Reels-Style Card ──────────────────────────────────────────────────────────

class _ReelCard extends StatefulWidget {
  final Listing listing;
  final VoidCallback onTap;
  const _ReelCard({required this.listing, required this.onTap});
  @override
  State<_ReelCard> createState() => _ReelCardState();
}

class _ReelCardState extends State<_ReelCard> {
  VideoPlayerController? _ctrl;
  bool _videoReady = false;
  bool _hasVideo   = false;

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  void _initVideo() {
    final videoData = widget.listing.feedVideo;
    if (videoData == null || videoData.isEmpty) return;
    _hasVideo = true;
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
        // Background: video or photo or emoji
        _buildBackground(),
        // Gradient overlay
        Container(decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.transparent,
                Color(0xCC000000), Color(0xEE000000)],
            stops: [0, 0.4, 0.75, 1.0],
          ),
        )),
        // Content overlay
        Positioned(left: 0, right: 0, bottom: 0,
          child: _buildOverlay(l)),
        // Top right: category badge
        Positioned(top: 16, right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white24),
            ),
            child: Text(l.category, style: const TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
          )),
        // Play icon if video
        if (_hasVideo && !_videoReady)
          Center(child: Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
                color: Colors.black45, shape: BoxShape.circle),
            child: const Icon(Icons.play_circle_outline_rounded,
                color: Colors.white, size: 32),
          )),
        // Video indicator
        if (_hasVideo)
          Positioned(top: 16, left: 16,
            child: Container(
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
    // Fallback: emoji background
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
      // Seller
      Row(children: [
        Container(
          width: 32, height: 32,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
                colors: [BrokaColors.gradStart, BrokaColors.gradMid])),
          child: Center(child: Text(
            (l.sellerName ?? 'S')[0].toUpperCase(),
            style: const TextStyle(color: Colors.white,
                fontWeight: FontWeight.w800, fontSize: 14))),
        ),
        const SizedBox(width: 8),
        Text(l.sellerName ?? 'Seller',
            style: const TextStyle(color: Colors.white,
                fontWeight: FontWeight.w700, fontSize: 13)),
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
            gradient: const LinearGradient(
                colors: [Color(0xFFFF4D6D), Color(0xFFFF8C42)]),
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [BoxShadow(
                color: Color(0x88FF4D6D), blurRadius: 12)],
          ),
          child: const Text('View Deal',
              style: TextStyle(color: Colors.white,
                  fontWeight: FontWeight.w800, fontSize: 13)),
        ),
      ]),
    ]),
  );
}

// ── Search Delegate ───────────────────────────────────────────────────────────

class _UserSearchDelegate extends SearchDelegate<String> {
  List<Map<String, dynamic>> _results = [];
  Timer? _debounce;

  @override
  String get searchFieldLabel => 'Search users or listings...';

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
  Widget buildResults(BuildContext context) => _buildBody();

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.isEmpty) return _emptyPrompt();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final users = await ApiService.searchUsers(query.trim());
        _results = users.cast<Map<String, dynamic>>();
        showResults(context);
      } catch (_) { _results = []; }
    });
    return _buildBody();
  }

  Widget _emptyPrompt() => Container(color: BrokaColors.bg,
    child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.person_search_outlined, size: 48, color: BrokaColors.textLow),
      const SizedBox(height: 12),
      const Text('Search for traders by name',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 14)),
    ])));

  Widget _buildBody() {
    if (_results.isEmpty && query.isNotEmpty) {
      return Container(color: BrokaColors.bg, child: Center(
        child: Text('No users found for "$query"',
            style: const TextStyle(color: BrokaColors.textMid))));
    }
    return Container(color: BrokaColors.bg,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _results.length,
        itemBuilder: (_, i) {
          final u = _results[i];
          final dist = u['distance_km'];
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
                child: Text((u['name'] as String? ?? '?')[0].toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
              title: Text(u['name'] ?? '', style: const TextStyle(
                  color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SizedBox(height: 2),
                Row(children: [
                  const Icon(Icons.star_rounded, size: 12, color: BrokaColors.gold),
                  const SizedBox(width: 3),
                  Text('${(u['rating'] as num?)?.toStringAsFixed(1) ?? '5.0'}  · ${u['completed_deals'] ?? 0} deals',
                      style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
                ]),
                if (dist != null) ...[
                  const SizedBox(height: 2),
                  Row(children: [
                    const Icon(Icons.location_on_outlined, size: 11, color: BrokaColors.neonBlue),
                    const SizedBox(width: 2),
                    Text('$dist km away',
                        style: const TextStyle(color: BrokaColors.neonBlue, fontSize: 11)),
                  ]),
                ],
              ]),
              trailing: u['is_verified'] == true
                  ? const Icon(Icons.verified_rounded,
                      color: BrokaColors.neonPurple, size: 18) : null,
            ),
          );
        },
      ),
    );
  }
}
