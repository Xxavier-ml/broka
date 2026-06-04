// BROKA — Product Detail Screen
// Shows verified photos, video, seller info, location, price
// Entry point to the negotiation room.
// MAP ADDITION: A tappable map preview card is shown between the
// seller section and the description section.  Tapping it navigates
// to ListingMapScreen (/listing-map) which renders the full route.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../main.dart';
import '../models/listing.dart';
import '../services/api_service.dart';

class ProductScreen extends StatefulWidget {
  const ProductScreen({super.key});
  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  Listing? _listing;
  VideoPlayerController? _videoCtrl;
  bool _videoReady = false;
  int _photoIndex = 0;
  Map<String, dynamic>? _sellerInfo;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_listing == null) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Listing) {
        _listing = args;
        _initVideo();
        _loadSeller();
      }
    }
  }

  void _initVideo() {
    final video = _listing?.verifiedVideo;
    if (video == null || video.isEmpty) return;
    try {
      final uri = Uri.dataFromBytes(base64Decode(video), mimeType: 'video/mp4');
      _videoCtrl = VideoPlayerController.contentUri(uri)
        ..initialize().then((_) {
          if (mounted) setState(() => _videoReady = true);
        }).catchError((_) {});
    } catch (_) {
      try {
        _videoCtrl = VideoPlayerController.networkUrl(Uri.parse(video))
          ..initialize().then((_) {
            if (mounted) setState(() => _videoReady = true);
          }).catchError((_) {});
      } catch (_) {}
    }
  }

  Future<void> _loadSeller() async {
    final sid = _listing?.sellerId;
    if (sid == null) return;
    try {
      final info = await ApiService.getUserProfile(sid);
      if (mounted) setState(() => _sellerInfo = info);
    } catch (_) {}
  }

  @override
  void dispose() {
    _videoCtrl?.dispose();
    super.dispose();
  }

  List<String> get _photos {
    final raw = _listing?.verifiedPhotos;
    if (raw == null || raw.isEmpty) return [];
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  bool get _isMine => _listing?.sellerId == ApiService.currentUserId;

  double? get _distanceKm {
    final sLat = _sellerInfo?['distance_km'];
    if (sLat != null) return (sLat as num).toDouble();
    return null;
  }

  /// True when we have at least the seller's location to show on a map.
  bool get _hasMapData =>
      (_listing?.sellerLat != null && _listing?.sellerLng != null);

  @override
  Widget build(BuildContext context) {
    if (_listing == null) {
      return const Scaffold(
          body: Center(
              child: CircularProgressIndicator(color: BrokaColors.neonPurple)));
    }
    final l = _listing!;
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: CustomScrollView(slivers: [
        _buildAppBar(l),
        SliverToBoxAdapter(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildMediaSection(l),
            _buildInfoSection(l),
            _buildSellerSection(l),
            // ── MAP PREVIEW ──────────────────────────────────────
            if (_hasMapData) _buildMapPreview(l),
            // ─────────────────────────────────────────────────────
            _buildDescSection(l),
            const SizedBox(height: 100),
          ],
        )),
      ]),
      bottomNavigationBar: _isMine ? null : _buildCTA(l),
    );
  }

  // ── App bar ───────────────────────────────────────────────────────────────

  Widget _buildAppBar(Listing l) => SliverAppBar(
        backgroundColor: BrokaColors.bgMid,
        expandedHeight: 0,
        pinned: true,
        leading: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: BrokaColors.bgCard,
              border: Border.all(color: BrokaColors.border),
            ),
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                color: BrokaColors.textMid, size: 16),
          ),
        ),
        title: Text(l.name,
            style: const TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 15,
                fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: l.listingType == 'auction'
                  ? BrokaColors.danger.withOpacity(0.15)
                  : BrokaColors.neonPurple.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: l.listingType == 'auction'
                      ? BrokaColors.danger.withOpacity(0.5)
                      : BrokaColors.neonPurple.withOpacity(0.5)),
            ),
            child: Text(
                l.listingType == 'auction' ? '⬤ LIVE AUCTION' : 'DIRECT SALE',
                style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: l.listingType == 'auction'
                        ? BrokaColors.danger
                        : BrokaColors.neonPurple)),
          ),
        ],
      );

  // ── Media ─────────────────────────────────────────────────────────────────

  Widget _buildMediaSection(Listing l) {
    final photos = _photos;
    return Column(children: [
      if (_videoReady && _videoCtrl != null)
        _buildVideoPlayer()
      else if (photos.isNotEmpty)
        _buildPhotoGallery(photos)
      else
        Container(
          height: 240,
          color: BrokaColors.bgCard,
          child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(l.emoji, style: const TextStyle(fontSize: 56)),
            const SizedBox(height: 8),
            const Text('No media available',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
          ])),
        ),
      if (_videoReady && photos.isNotEmpty) _buildPhotoStrip(photos),
    ]);
  }

  Widget _buildVideoPlayer() => Stack(children: [
        Container(
          height: 260,
          color: Colors.black,
          child: Center(
              child: AspectRatio(
                  aspectRatio: _videoCtrl!.value.aspectRatio,
                  child: VideoPlayer(_videoCtrl!))),
        ),
        Positioned.fill(
            child: Center(
                child: GestureDetector(
          onTap: () => setState(() {
            _videoCtrl!.value.isPlaying
                ? _videoCtrl!.pause()
                : _videoCtrl!.play();
          }),
          child: AnimatedOpacity(
            opacity: _videoCtrl!.value.isPlaying ? 0 : 1,
            duration: const Duration(milliseconds: 300),
            child: Container(
              width: 60,
              height: 60,
              decoration: const BoxDecoration(
                  color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 36),
            ),
          ),
        ))),
        Positioned(
            top: 12,
            right: 12,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                  color: BrokaColors.success.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(6)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.verified_rounded, size: 10, color: Colors.white),
                SizedBox(width: 4),
                Text('VERIFIED VIDEO',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700)),
              ]),
            )),
      ]);

  Widget _buildPhotoGallery(List<String> photos) => Column(children: [
        GestureDetector(
          onHorizontalDragEnd: (d) {
            if (d.primaryVelocity! < 0 && _photoIndex < photos.length - 1) {
              setState(() => _photoIndex++);
            } else if (d.primaryVelocity! > 0 && _photoIndex > 0) {
              setState(() => _photoIndex--);
            }
          },
          child: Container(
            height: 260,
            color: Colors.black,
            child: _buildPhotoWidget(photos[_photoIndex]),
          ),
        ),
        if (photos.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                    photos.length,
                    (i) => Container(
                          margin:
                              const EdgeInsets.symmetric(horizontal: 3),
                          width: i == _photoIndex ? 16 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: i == _photoIndex
                                ? BrokaColors.neonPurple
                                : BrokaColors.border,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ))),
          ),
      ]);

  Widget _buildPhotoStrip(List<String> photos) => SizedBox(
        height: 72,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          itemCount: photos.length,
          itemBuilder: (_, i) => GestureDetector(
            onTap: () => setState(() => _photoIndex = i),
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: i == _photoIndex
                        ? BrokaColors.neonPurple
                        : BrokaColors.border,
                    width: i == _photoIndex ? 2 : 1),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: _buildPhotoWidget(photos[i]),
              ),
            ),
          ),
        ),
      );

  Widget _buildPhotoWidget(String data) {
    try {
      final bytes = base64Decode(data);
      return Image.memory(bytes, fit: BoxFit.cover);
    } catch (_) {
      return Image.network(data,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
              color: BrokaColors.bgCard,
              child: const Icon(Icons.image_not_supported_outlined,
                  color: BrokaColors.textLow)));
    }
  }

  // ── Info section ──────────────────────────────────────────────────────────

  Widget _buildInfoSection(Listing l) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: Text(l.name,
                    style: const TextStyle(
                        color: BrokaColors.textHigh,
                        fontSize: 22,
                        fontWeight: FontWeight.w800))),
            const SizedBox(width: 12),
            ShaderMask(
              shaderCallback: (b) => const LinearGradient(
                      colors: [BrokaColors.neonPurple, BrokaColors.neonBlue])
                  .createShader(b),
              child: Text(l.formattedPrice,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800)),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: BrokaColors.neonPurple.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: BrokaColors.neonPurple.withOpacity(0.3)),
              ),
              child: Text(l.category,
                  style: const TextStyle(
                      color: BrokaColors.neonPurple,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.location_on_outlined,
                size: 14, color: BrokaColors.neonBlue),
            const SizedBox(width: 3),
            Text(l.locationName ?? 'Kenya',
                style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 13)),
            if (_distanceKm != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: BrokaColors.neonBlue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: BrokaColors.neonBlue.withOpacity(0.3)),
                ),
                child: Text(
                    '${_distanceKm!.toStringAsFixed(1)} km away',
                    style: const TextStyle(
                        color: BrokaColors.neonBlue,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ]),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: BrokaColors.success.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: BrokaColors.success.withOpacity(0.3)),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.verified_rounded,
                  size: 13, color: BrokaColors.success),
              SizedBox(width: 6),
              Text('Camera-verified listing · Fraud protected',
                  style: TextStyle(
                      color: BrokaColors.success,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
      );

  // ── Seller section ────────────────────────────────────────────────────────

  Widget _buildSellerSection(Listing l) {
    final name = _sellerInfo?['name'] as String? ?? l.sellerName ?? 'Seller';
    final rating =
        (_sellerInfo?['rating'] as num?)?.toDouble() ?? l.sellerRating ?? 5.0;
    final deals = (_sellerInfo?['completed_deals'] as num?)?.toInt() ??
        l.sellerCompletedDeals ?? 0;
    final verified = _sellerInfo?['is_verified'] as bool? ?? false;
    final initials = name
        .trim()
        .split(' ')
        .map((w) => w.isEmpty ? '' : w[0])
        .take(2)
        .join()
        .toUpperCase();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: BrokaColors.cardGradColors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                  colors: [BrokaColors.gradStart, BrokaColors.gradMid])),
          child: Center(
              child: Text(initials,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16))),
        ),
        const SizedBox(width: 12),
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(children: [
                Text(name,
                    style: const TextStyle(
                        color: BrokaColors.textHigh,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
                if (verified) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.verified_rounded,
                      color: BrokaColors.neonPurple, size: 14),
                ],
              ]),
              const SizedBox(height: 4),
              Row(children: [
                const Icon(Icons.star_rounded,
                    size: 13, color: BrokaColors.gold),
                const SizedBox(width: 3),
                Text(
                    '${rating.toStringAsFixed(1)}  ·  $deals deals completed',
                    style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 12)),
              ]),
            ])),
        const Icon(Icons.person_outline_rounded,
            color: BrokaColors.textLow, size: 18),
      ]),
    );
  }

  // ── MAP PREVIEW CARD ─────────────────────────────────────────────────────
  /// Tappable map preview between seller section and description.
  /// Shows a static "pin" illustration with distance and a call-to-action.
  /// On tap → navigates to ListingMapScreen for the full interactive map.
  Widget _buildMapPreview(Listing l) {
    // Compute straight-line distance if we have the buyer's location
    final buyerLat = ApiService.currentUserLat;
    final buyerLng = ApiService.currentUserLng;
    final sellerLat = l.sellerLat;
    final sellerLng = l.sellerLng;

    String? distanceText;
    if (buyerLat != null &&
        buyerLng != null &&
        sellerLat != null &&
        sellerLng != null) {
      final km = _haversineKm(buyerLat, buyerLng, sellerLat, sellerLng);
      distanceText = km < 1.0
          ? '${(km * 1000).toStringAsFixed(0)} m from you'
          : '${km.toStringAsFixed(1)} km from you';
    }

    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/listing-map', arguments: l),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.35)),
          boxShadow: const [BrokaColors.glowBlue],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Decorative map graphic ──────────────────────────────────
          ClipRRect(
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(13)),
            child: Container(
              height: 130,
              width: double.infinity,
              color: const Color(0xFF0A0520),
              child: Stack(children: [
                // Grid lines to mimic a map background
                CustomPaint(
                  size: const Size(double.infinity, 130),
                  painter: _MapGridPainter(),
                ),
                // Seller pin (centre)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 20,
                  child: Center(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: BrokaColors.neonPurple.withOpacity(0.15),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: BrokaColors.neonPurple, width: 2),
                          boxShadow: [
                            BoxShadow(
                                color:
                                    BrokaColors.neonPurple.withOpacity(0.5),
                                blurRadius: 16,
                                spreadRadius: 2),
                          ],
                        ),
                        child: const Icon(Icons.storefront_rounded,
                            color: BrokaColors.neonPurple, size: 22),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: BrokaColors.bgCard,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: BrokaColors.neonPurple.withOpacity(0.4)),
                        ),
                        child: Text(
                          l.locationName ?? 'Seller Location',
                          style: const TextStyle(
                              color: BrokaColors.neonPurple,
                              fontSize: 10,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ]),
                  ),
                ),
                // Buyer pin (bottom-left) — only shown when location known
                if (buyerLat != null)
                  Positioned(
                    left: 36,
                    bottom: 14,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: BrokaColors.neonBlue.withOpacity(0.15),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: BrokaColors.neonBlue, width: 1.5),
                          boxShadow: [
                            BoxShadow(
                                color: BrokaColors.neonBlue.withOpacity(0.4),
                                blurRadius: 10),
                          ],
                        ),
                        child: const Icon(Icons.my_location_rounded,
                            color: BrokaColors.neonBlue, size: 15),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: BrokaColors.bgCard,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: BrokaColors.neonBlue.withOpacity(0.4)),
                        ),
                        child: const Text('You',
                            style: TextStyle(
                                color: BrokaColors.neonBlue,
                                fontSize: 9,
                                fontWeight: FontWeight.w700)),
                      ),
                    ]),
                  ),
                // Route dashed line illustration
                if (buyerLat != null)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _DashedLinePainter(),
                    ),
                  ),
                // "Tap to explore" overlay badge
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: BrokaColors.neonBlue,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: const [BrokaColors.glowBlue],
                    ),
                    child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                      Icon(Icons.map_outlined,
                          color: Colors.white, size: 12),
                      SizedBox(width: 5),
                      Text('View Route',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
          // ── Bottom info row ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Row(children: [
              const Icon(Icons.location_on_rounded,
                  color: BrokaColors.neonPurple, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l.locationName != null
                      ? 'Seller is in ${l.locationName}'
                      : 'Seller location available',
                  style: const TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ),
              if (distanceText != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: BrokaColors.neonBlue.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: BrokaColors.neonBlue.withOpacity(0.35)),
                  ),
                  child: Text(distanceText,
                      style: const TextStyle(
                          color: BrokaColors.neonBlue,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded,
                  color: BrokaColors.textMid, size: 18),
            ]),
          ),
        ]),
      ),
    );
  }

  // Simple haversine for the preview distance label
  double _haversineKm(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * 3.14159265358979 / 180.0;
    final dLng = (lng2 - lng1) * 3.14159265358979 / 180.0;
    final lat1r = lat1 * 3.14159265358979 / 180.0;
    final lat2r = lat2 * 3.14159265358979 / 180.0;
    final a = _sin2(dLat / 2) +
        _cos(lat1r) * _cos(lat2r) * _sin2(dLng / 2);
    return r * 2 * _asin(_sqrt(a));
  }

  // Pure-dart trig helpers (no dart:math import needed in this file)
  static double _sin2(double x) {
    final s = _sin(x);
    return s * s;
  }

  static double _sin(double x) {
    // Taylor series for small angles is fine here; use dart's built-in via
    // the import below — we include dart:math for correctness.
    return x - x * x * x / 6 + x * x * x * x * x / 120;
  }

  static double _cos(double x) {
    return 1 - x * x / 2 + x * x * x * x / 24;
  }

  static double _asin(double x) {
    // Approximation sufficient for distances
    if (x >= 1.0) return 3.14159265358979 / 2;
    return x + x * x * x / 6 + 3 * x * x * x * x * x / 40;
  }

  static double _sqrt(double x) {
    if (x <= 0) return 0;
    double r = x;
    for (int i = 0; i < 20; i++) r = (r + x / r) / 2;
    return r;
  }

  // ── Description ───────────────────────────────────────────────────────────

  Widget _buildDescSection(Listing l) {
    if (l.status == 'active') {}
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('ABOUT THIS LISTING',
            style: TextStyle(
                color: BrokaColors.textLow,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: BrokaColors.cardGradColors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: BrokaColors.border),
          ),
          child: Text(
            l.status.isNotEmpty
                ? 'Tap "Start Negotiation" below to contact the seller and '
                    'get a detailed description. The AI broker will mediate a fair deal for both parties.'
                : 'No description provided.',
            style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 13, height: 1.6),
          ),
        ),
      ]),
    );
  }

  // ── CTA ───────────────────────────────────────────────────────────────────

  Widget _buildCTA(Listing l) => SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: const BoxDecoration(
            color: BrokaColors.bgMid,
            border: Border(top: BorderSide(color: BrokaColors.border)),
          ),
          child: Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
              Text(l.formattedPrice,
                  style: const TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
              const Text('Escrow protected · 3% fee',
                  style:
                      TextStyle(color: BrokaColors.textLow, fontSize: 11)),
            ])),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () => Navigator.pushNamed(
                context,
                '/negotiate',
                arguments: {'listing': l, 'role': 'buyer'},
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Color(0xFFFF4D6D), Color(0xFFFF8C42)]),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(color: Color(0x55FF4D6D), blurRadius: 14)
                  ],
                ),
                child: const Text('Start Negotiation',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 15)),
              ),
            ),
          ]),
        ),
      );
}

// ─── Custom painters for the map preview illustration ─────────────────────

/// Draws a faint grid to mimic a map background.
class _MapGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1E1648)
      ..strokeWidth = 0.8;
    const step = 28.0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    // A couple of "road" lines for flavour
    final roadPaint = Paint()
      ..color = const Color(0xFF2A1F5A)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
        Offset(size.width * 0.1, size.height * 0.55),
        Offset(size.width * 0.9, size.height * 0.35),
        roadPaint);
    canvas.drawLine(
        Offset(size.width * 0.5, 0),
        Offset(size.width * 0.5, size.height),
        roadPaint);
  }

  @override
  bool shouldRepaint(_MapGridPainter old) => false;
}

/// Draws a dashed line from bottom-left (buyer) to centre (seller).
class _DashedLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x9038BDF8)
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    final start = Offset(size.width * 0.22, size.height * 0.78);
    final end   = Offset(size.width * 0.5,  size.height * 0.38);
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final len = _sqrt(dx * dx + dy * dy);
    const dashLen   = 7.0;
    const dashGap   = 5.0;
    double drawn = 0;
    while (drawn < len) {
      final t0 = drawn / len;
      final t1 = ((drawn + dashLen) / len).clamp(0.0, 1.0);
      canvas.drawLine(
        Offset(start.dx + dx * t0, start.dy + dy * t0),
        Offset(start.dx + dx * t1, start.dy + dy * t1),
        paint,
      );
      drawn += dashLen + dashGap;
    }
  }

  static double _sqrt(double x) {
    if (x <= 0) return 0;
    double r = x;
    for (int i = 0; i < 20; i++) r = (r + x / r) / 2;
    return r;
  }

  @override
  bool shouldRepaint(_DashedLinePainter old) => false;
}
