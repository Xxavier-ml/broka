// BROKA - Domain Models (MatchResult, Message, Bid)
// NOTE: Listing model lives in listing.dart

// ── MatchResult ───────────────────────────────────────────────────────────────

class MatchResult {
  final String buyerId;
  final String buyerName;
  final double score;
  final double distanceKm;
  final double priceGap;

  const MatchResult({
    required this.buyerId,
    required this.buyerName,
    required this.score,
    required this.distanceKm,
    required this.priceGap,
  });

  factory MatchResult.fromJson(Map<String, dynamic> j) => MatchResult(
        buyerId:    j['buyer_id']     as String,
        buyerName:  j['buyer_name']   as String,
        score:      (j['score']       as num).toDouble(),
        distanceKm: (j['distance_km'] as num).toDouble(),
        priceGap:   (j['price_gap']   as num).toDouble(),
      );

  String get initials =>
      buyerName.trim().split(' ').map((w) => w.isEmpty ? '' : w[0]).take(2).join().toUpperCase();
}

// ── Message ───────────────────────────────────────────────────────────────────

class Message {
  final String role;    // "seller" | "buyer" | "broker"
  final String content;
  final int?   dealProbability; // 0-100, from broker sentiment analysis

  const Message({required this.role, required this.content, this.dealProbability});

  factory Message.fromJson(Map<String, dynamic> j) => Message(
    role:            j['role']             as String,
    content:         j['content']          as String,
    dealProbability: j['deal_probability'] as int?,
  );

  bool get isBroker => role == 'broker';
  bool get isSeller => role == 'seller';
  bool get isBuyer  => role == 'buyer';
}

// ── Bid ───────────────────────────────────────────────────────────────────────

class Bid {
  final int    rank;
  final String bidderName;
  final double amount;
  final String timeAgo;

  const Bid({
    required this.rank,
    required this.bidderName,
    required this.amount,
    required this.timeAgo,
  });

  factory Bid.fromJson(Map<String, dynamic> j) => Bid(
        rank:       (j['rank']        as num).toInt(),
        bidderName: j['bidder_name']  as String,
        amount:     (j['amount']      as num).toDouble(),
        timeAgo:    j['time_ago']     as String,
      );

  String get formattedAmount => fmt(amount);

  static String fmt(double v) =>
      'KES ${v.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';}
