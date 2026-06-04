// BROKA — Listing Model

class Listing {
  final String  id;
  final String  name;
  final String  category;
  final double  price;
  final String? locationName;
  final double? lat;
  final double? lng;
  final String  listingType;
  final String  status;
  final int     views;
  // Media
  final String? verifiedPhotos;  // comma-separated base64 or URLs
  final String? verifiedVideo;
  final String? advertVideo;
  // Seller info
  final String? sellerId;
  final String? sellerName;
  final double? sellerRating;
  final int?    sellerCompletedDeals;
  final double? sellerLat;
  final double? sellerLng;

  Listing({
    required this.id,
    required this.name,
    required this.category,
    required this.price,
    this.locationName,
    this.lat,
    this.lng,
    required this.listingType,
    required this.status,
    required this.views,
    this.verifiedPhotos,
    this.verifiedVideo,
    this.advertVideo,
    this.sellerId,
    this.sellerName,
    this.sellerRating,
    this.sellerCompletedDeals,
    this.sellerLat,
    this.sellerLng,
  });

  factory Listing.fromJson(Map<String, dynamic> j) => Listing(
        id:                   j['id']            as String,
        name:                 j['name']          as String,
        category:             j['category']      as String,
        price:                (j['price']        as num).toDouble(),
        locationName:         j['location_name'] as String?,
        lat:                  (j['lat']          as num?)?.toDouble(),
        lng:                  (j['lng']          as num?)?.toDouble(),
        listingType:          j['listing_type']  as String,
        status:               j['status']        as String,
        views:                ((j['views'] ?? 0) as num).toInt(),
        verifiedPhotos:       j['verified_photos'] as String?,
        verifiedVideo:        j['verified_video']  as String?,
        advertVideo:          j['advert_video']    as String?,
        sellerId:             j['seller_id']        as String?,
        sellerName:           j['seller_name']      as String?,
        sellerRating:         (j['seller_rating']   as num?)?.toDouble(),
        sellerCompletedDeals: (j['seller_completed_deals'] as num?)?.toInt(),
        sellerLat:            (j['seller_lat']      as num?)?.toDouble(),
        sellerLng:            (j['seller_lng']      as num?)?.toDouble(),
      );

  String get emoji {
    switch (category) {
      case 'Vehicles':    return '🚗';
      case 'Property':    return '🏠';
      case 'Electronics': return '📱';
      case 'Livestock':   return '🐄';
      default:            return '📦';
    }
  }

  String get formattedPrice => 'KES ${price.toStringAsFixed(0).replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},',
      )}';

  /// Returns the best video to show in the discovery feed.
  /// Prefers advert video; falls back to verified video.
  String? get feedVideo => advertVideo?.isNotEmpty == true ? advertVideo : verifiedVideo;

  bool get hasMedia =>
      (verifiedPhotos?.isNotEmpty ?? false) || (verifiedVideo?.isNotEmpty ?? false);
}
