// BROKA - API Service
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/listing.dart';
import '../models/models.dart';

class ApiService {
  static const String baseUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'https://broka-dbjd.onrender.com',
  );

  static String? _token;
  static String? currentUserId;
  static String? currentUserName;
  static String? currentUserNickname;
  static String? currentUserEmail;
  static String? currentUserPhone;
  static double? currentUserLat;
  static double? currentUserLng;
  static String  currentUserLanguage = 'english';
  static String? currentUserPhoto;   // base64 selfie

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  static Future<void> loadSavedSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token                = prefs.getString('auth_token');
    currentUserId         = prefs.getString('user_id');
    currentUserName       = prefs.getString('user_name');
    currentUserNickname   = prefs.getString('user_nickname');
    currentUserEmail      = prefs.getString('user_email');
    currentUserPhoto      = prefs.getString('user_photo');
    final lat = prefs.getDouble('user_lat');
    final lng = prefs.getDouble('user_lng');
    if (lat != null) currentUserLat = lat;
    if (lng != null) currentUserLng = lng;
    currentUserLanguage = prefs.getString('user_language') ?? 'english';
  }

  static Future<void> _saveSession(
    String token,
    String userId, {
    String? name,
    String? nickname,
    String? email,
    String? password,
    double? lat,
    double? lng,
    String? photo,
  }) async {
    _token                = token;
    currentUserId         = userId;
    currentUserName       = name;
    currentUserNickname   = nickname;
    currentUserEmail      = email;
    currentUserLat        = lat;
    currentUserLng        = lng;
    if (photo != null) currentUserPhoto = photo;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    await prefs.setString('user_id', userId);
    if (name     != null) await prefs.setString('user_name',     name);
    if (nickname != null) await prefs.setString('user_nickname', nickname);
    if (email    != null) await prefs.setString('user_email',    email);
    if (password != null) await prefs.setString('user_password', password);
    if (lat      != null) await prefs.setDouble('user_lat',      lat);
    if (lng      != null) await prefs.setDouble('user_lng',      lng);
    if (photo    != null) await prefs.setString('user_photo',    photo);
  }

  static Future<void> clearSession() async {
    _token                = null;
    currentUserId         = null;
    currentUserName       = null;
    currentUserNickname   = null;
    currentUserEmail      = null;
    currentUserLat        = null;
    currentUserLng        = null;
    currentUserLanguage   = 'english';
    currentUserPhoto      = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('user_id');
    await prefs.remove('user_name');
    await prefs.remove('user_nickname');
    await prefs.remove('user_email');
    await prefs.remove('user_password');
    await prefs.remove('user_lat');
    await prefs.remove('user_lng');
    await prefs.remove('user_language');
    await prefs.remove('user_photo');
  }

  static Future<void> setLanguage(String language) async {
    currentUserLanguage = language;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_language', language);
    try {
      await http.patch(
        Uri.parse('\$baseUrl/auth/language?language=\$language'),
        headers: _headers,
      );
    } catch (_) {}
  }

  static Future<void> enrollBiometric(String biometricType) async {
    try {
      await http.patch(
        Uri.parse('\$baseUrl/auth/biometric-enroll?biometric_type=\$biometricType'),
        headers: _headers,
      );
    } catch (_) {}
  }

  static Future<void> setLocationVisible(bool visible) async {
    try {
      await http.patch(
        Uri.parse('\$baseUrl/auth/location-visibility?visible=\$visible'),
        headers: _headers,
      );
    } catch (_) {}
  }

  static bool   get isLoggedIn => _token != null;
  static String? get authToken  => _token;

  static Future<bool> _tryRelogin() async {
    try {
      final prefs    = await SharedPreferences.getInstance();
      final email    = prefs.getString('user_email');
      final password = prefs.getString('user_password');
      if (email == null || password == null) return false;
      await login(email: email, password: password);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Auth ───────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String phone,
    required String password,
    required double lat,
    required double lng,
    String? nickname,
    String? profilePhoto,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/register'),
      headers: _headers,
      body: jsonEncode({
        'name': name, 'email': email, 'phone': phone,
        'password': password, 'lat': lat, 'lng': lng,
        if (nickname     != null) 'nickname':      nickname,
        if (profilePhoto != null) 'profile_photo': profilePhoto,
      }),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 201) {
      await _saveSession(
        data['access_token'], data['user_id'],
        name: data['name'],
        nickname: data['nickname'] as String?,
        email: email,
        password: password,
        lat: lat,
        lng: lng,
        photo: data['profile_photo'] as String?,
      );
    }
    return data;
  }

  static Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: _headers,
      body: jsonEncode({'email': email, 'password': password}),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      await _saveSession(
        data['access_token'], data['user_id'],
        name: data['name'],
        nickname: data['nickname'] as String?,
        email: email,
        password: password,
        lat: (data['lat'] as num?)?.toDouble(),
        lng: (data['lng'] as num?)?.toDouble(),
        photo: data['profile_photo'] as String?,
      );
    }
    return data;
  }

  static Future<Map<String, dynamic>> getMe() async {
    final response = await http.get(
      Uri.parse('$baseUrl/auth/me'),
      headers: _headers,
    ).timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<void> updateProfile({
    String? nickname,
    String? profilePhoto,
  }) async {
    await http.patch(
      Uri.parse('$baseUrl/auth/profile'),
      headers: _headers,
      body: jsonEncode({
        if (nickname     != null) 'nickname':      nickname,
        if (profilePhoto != null) 'profile_photo': profilePhoto,
      }),
    ).timeout(const Duration(seconds: 30));
    if (nickname     != null) currentUserNickname = nickname;
    if (profilePhoto != null) {
      currentUserPhoto = profilePhoto;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_photo', profilePhoto);
    }
  }

  static Future<List<dynamic>> searchUsers(String q) async {
    final lat = currentUserLat;
    final lng = currentUserLng;
    final uri = Uri.parse('$baseUrl/auth/search').replace(queryParameters: {
      'q': q,
      if (lat != null) 'lat': lat.toString(),
      if (lng != null) 'lng': lng.toString(),
    });
    final response = await http.get(uri, headers: _headers)
        .timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as List<dynamic>;
  }

  static Future<Map<String, dynamic>> getUserProfile(String userId) async {
    final lat = currentUserLat;
    final lng = currentUserLng;
    final uri = Uri.parse('$baseUrl/auth/user/$userId').replace(queryParameters: {
      if (lat != null) 'lat': lat.toString(),
      if (lng != null) 'lng': lng.toString(),
    });
    final response = await http.get(uri, headers: _headers)
        .timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // ── Location ──────────────────────────────────────────────────────────────

  static Future<void> updateLocation(double lat, double lng) async {
    try {
      currentUserLat = lat;
      currentUserLng = lng;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('user_lat', lat);
      await prefs.setDouble('user_lng', lng);
      await http.patch(
        Uri.parse('$baseUrl/auth/location').replace(
          queryParameters: {'lat': lat.toString(), 'lng': lng.toString()},
        ),
        headers: _headers,
      );
    } catch (_) {}
  }

  // ── Inbox ──────────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getInbox() async {
    final uid = currentUserId;
    if (uid == null) return [];
    final response = await http.get(
      Uri.parse('$baseUrl/negotiate/inbox/$uid'),
      headers: _headers,
    );
    if (response.statusCode == 200) {
      final List data = jsonDecode(response.body);
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  // ── Listings ───────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getStats() async {
    final response = await http.get(
      Uri.parse('$baseUrl/listings/stats'),
      headers: _headers,
    ).timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<List<Listing>> getListings({
    String? category,
    String? listingType,
    String? sellerId,
    int limit = 20,
    int offset = 0,
  }) async {
    final uri = Uri.parse('$baseUrl/listings/').replace(queryParameters: {
      if (category    != null) 'category':     category,
      if (listingType != null) 'listing_type': listingType,
      if (sellerId    != null) 'seller_id':    sellerId,
      'limit':  limit.toString(),
      'offset': offset.toString(),
    });
    final response = await http.get(uri, headers: _headers)
        .timeout(const Duration(seconds: 30));
    final List data = jsonDecode(response.body);
    return data.map((e) => Listing.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<Listing> getListing(String listingId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/listings/$listingId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 30));
    return Listing.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  static Future<Map<String, dynamic>> createListing(
      Map<String, dynamic> payload) async {
    final client = http.Client();
    try {
      var response = await client.post(
        Uri.parse('$baseUrl/listings/'),
        headers: _headers,
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 120));
      if (response.statusCode == 401) {
        final relogged = await _tryRelogin();
        if (relogged) {
          response = await client.post(
            Uri.parse('$baseUrl/listings/'),
            headers: _headers,
            body: jsonEncode(payload),
          ).timeout(const Duration(seconds: 120));
        }
      }
      if (response.statusCode != 201) {
        throw Exception(
            'Failed to create listing: ${response.statusCode} ${response.body}');
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  static Future<List<MatchResult>> getMatches(String listingId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/listings/$listingId/matches'),
      headers: _headers,
    ).timeout(const Duration(seconds: 30));
    final List data = jsonDecode(response.body);
    return data.map((e) => MatchResult.fromJson(e)).toList();
  }

  static Future<Map<String, dynamic>> expressInterest(
      String listingId, double? offerPrice) async {
    final response = await http.post(
      Uri.parse('$baseUrl/listings/$listingId/interest'),
      headers: _headers,
      body: jsonEncode({'offer_price': offerPrice}),
    ).timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // ── Negotiate ──────────────────────────────────────────────────────────────

  static Future<Message> freeChat({
    required String content,
    required List<Map<String, String>> history,
    String? userName,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/negotiate/chat'),
      headers: _headers,
      body: jsonEncode({
        'content':   content,
        'history':   history,
        'user_name': userName ?? currentUserName,
      }),
    ).timeout(const Duration(seconds: 60));
    return Message.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  // Legacy alias - calls the backend with the updated 'zeno' system override.
  // Kept for any callers not yet migrated to zenoChat().
  static Future<Message> xxenoChat({
    required String content,
    required List<Map<String, String>> history,
    String? userName,
    String? language,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/negotiate/chat'),
      headers: _headers,
      body: jsonEncode({
        'content':         content,
        'history':         history,
        'user_name':       userName ?? currentUserName,
        'system_override': 'zeno',  // updated: was 'xxeno'
        'language':        language ?? currentUserLanguage,
      }),
    ).timeout(const Duration(seconds: 60));
    return Message.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  static Future<Message> sendNegotiationMessage({
    required String listingId,
    required String senderRole,
    required String senderId,
    required String content,
    String? buyerName,
    String? sellerName,
    double? buyerLat,
    double? buyerLng,
    double? sellerLat,
    double? sellerLng,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/negotiate/message'),
      headers: _headers,
      body: jsonEncode({
        'listing_id':  listingId,
        'sender_role': senderRole,
        'sender_id':   senderId,
        'content':     content,
        if (buyerName  != null) 'buyer_name':  buyerName,
        if (sellerName != null) 'seller_name': sellerName,
        if (buyerLat   != null) 'buyer_lat':   buyerLat,
        if (buyerLng   != null) 'buyer_lng':   buyerLng,
        if (sellerLat  != null) 'seller_lat':  sellerLat,
        if (sellerLng  != null) 'seller_lng':  sellerLng,
        'language': currentUserLanguage,
      }),
    ).timeout(const Duration(seconds: 60));
    return Message.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  static Future<List<Message>> getNegotiationHistory(String listingId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/negotiate/$listingId/history'),
      headers: _headers,
    ).timeout(const Duration(seconds: 30));
    final List data = jsonDecode(response.body);
    return data.map((e) => Message.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ── Auction ────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> placeBid({
    required String listingId,
    required double amount,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auction/bid'),
      headers: _headers,
      body: jsonEncode({'listing_id': listingId, 'amount': amount}),
    ).timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<List<dynamic>> getLeaderboard(String listingId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/auction/$listingId/leaderboard'),
      headers: _headers,
    ).timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as List<dynamic>;
  }

  // ── Deal ───────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> finalizeDeal({
    required String listingId,
    required String buyerId,
    required double agreedPrice,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/deal/finalize'),
      headers: _headers,
      body: jsonEncode({
        'listing_id':   listingId,
        'buyer_id':     buyerId,
        'agreed_price': agreedPrice,
      }),
    ).timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // ── M-Pesa ─────────────────────────────────────────────────────────────────

  /// Initiates STK Push. Requires the user's BROKA password for authorization.
  /// Returns checkout_request_id on success.
  static Future<Map<String, dynamic>> mpesaStkPush({
    required String dealId,
    required String phoneNumber,
    required String password,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/mpesa/stk-push'),
      headers: _headers,
      body: jsonEncode({
        'deal_id':      dealId,
        'phone_number': phoneNumber,
        'password':     password,
      }),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['detail'] ?? 'STK push failed');
    }
    return data;
  }

  /// Polls Safaricom for the payment result.
  static Future<Map<String, dynamic>> mpesaQuery({
    required String checkoutRequestId,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/mpesa/query'),
      headers: _headers,
      body: jsonEncode({'checkout_request_id': checkoutRequestId}),
    ).timeout(const Duration(seconds: 20));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Gets the latest payment status for a deal.
  static Future<Map<String, dynamic>> mpesaStatus(String dealId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/mpesa/status/$dealId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 20));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
  // ── Zeno AI Chat ────────────────────────────────────────────────────────────
  static Future<String> zenoChat({
    required String message,
    required List<Map<String, String>> history,
    String? language,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/negotiate/chat'),
      headers: _headers,
      body: jsonEncode({
        'content':         message,
        'history':         history,
        'user_name':       currentUserName,
        'system_override': 'zeno',
        'language':        language ?? currentUserLanguage,
      }),
    ).timeout(const Duration(seconds: 60));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['content'] as String? ?? data['message'] as String? ?? '';
  }

  // ── Direct Chat (no AI mediation) ───────────────────────────────────────────
  static Future<void> sendDirectMessage({
    required String listingId,
    required String senderRole,
    required String senderId,
    required String content,
  }) async {
    try {
      await http.post(
        Uri.parse('$baseUrl/negotiate/direct-message'),
        headers: _headers,
        body: jsonEncode({
          'listing_id':  listingId,
          'sender_role': senderRole,
          'sender_id':   senderId,
          'content':     content,
        }),
      ).timeout(const Duration(seconds: 30));
    } catch (_) {}
  }

  // ── Online presence ────────────────────────────────────────────────────────
  /// Call this periodically to update the user's last_seen timestamp.
  static Future<void> updateLastSeen() async {
    try {
      await http.post(
        Uri.parse('$baseUrl/auth/heartbeat'),
        headers: _headers,
      ).timeout(const Duration(seconds: 5));
    } catch (_) {} // non-fatal
  }

  // ── FCM / Push Notifications ───────────────────────────────────────────────

  /// Register this device's FCM token with the backend so we can receive
  /// incoming-call push notifications.
  static Future<void> registerFcmToken(String token) async {
    try {
      await http.post(
        Uri.parse('$baseUrl/calls/register-token'),
        headers: _headers,
        body: jsonEncode({'fcm_token': token}),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// Notify the seller (via FCM) that a call is incoming.
  /// Called by the buyer just before navigating to the VoIP screen.
  static Future<void> initiateCall({
    required String roomId,
    required String listingId,
    required String listingName,
  }) async {
    try {
      await http.post(
        Uri.parse('$baseUrl/calls/initiate'),
        headers: _headers,
        body: jsonEncode({
          'room_id':      roomId,
          'listing_id':   listingId,
          'caller_name':  currentUserName ?? 'Buyer',
          'listing_name': listingName,
        }),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {} // non-fatal - call proceeds even if push fails
  }


  // ── Reviews ────────────────────────────────────────────────────────────────

  static Future<void> submitReview({
    required String dealId,
    required int    rating,
    String          comment = '',
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/reviews/'),
      headers: _headers,
      body: jsonEncode({'deal_id': dealId, 'rating': rating, 'comment': comment}),
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
  }

  static Future<Map<String, dynamic>> getReviewSummary(String sellerId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/reviews/summary/$sellerId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<List<Map<String, dynamic>>> getSellerReviews(
      String sellerId, {int limit = 20, int offset = 0}) async {
    final uri = Uri.parse('$baseUrl/reviews/$sellerId').replace(
        queryParameters: {'limit': '$limit', 'offset': '$offset'});
    final res = await http.get(uri, headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(data['reviews'] as List);
  }

  static Future<List<Map<String, dynamic>>> getMyReviewableDeals() async {
    final res = await http.get(
      Uri.parse('$baseUrl/reviews/my-deals'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(data['deals'] as List);
  }

  static Future<bool> checkAlreadyReviewed(String dealId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/reviews/check/$dealId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return false;
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return data['already_reviewed'] as bool? ?? false;
  }

  // ── Featured Listing Boost ─────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getMyBoostableListings() async {
    final res = await http.get(
      Uri.parse('$baseUrl/featured/my-listings'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(data['listings'] as List);
  }

  static Future<Map<String, dynamic>> boostListing({
    required String listingId,
    required String plan,
    required String phone,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/featured/boost'),
      headers: _headers,
      body: jsonEncode({
        'listing_id':   listingId,
        'plan':         plan,
        'phone_number': phone,
      }),
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> checkBoostStatus(String listingId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/featured/status/$listingId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ── Seller Verification ────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> buyVerification({
    required String tier,
    required String phone,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/verify/purchase'),
      headers: _headers,
      body: jsonEncode({
        'tier':         tier,
        'phone_number': phone,
      }),
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> checkVerificationStatus() async {
    final res = await http.get(
      Uri.parse('$baseUrl/verify/status'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ── Dispute Assistant ──────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> openDispute({
    required String dealId,
    required String issueType,
    required String description,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/disputes/open'),
      headers: _headers,
      body: jsonEncode({
        'deal_id':     dealId,
        'issue_type':  issueType,
        'description': description,
      }),
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception(_extractError(res.body));
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> mediateDispute({
    required String disputeId,
    String? buyerReply,
    String? mpesaReceipt,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/disputes/mediate'),
      headers: _headers,
      body: jsonEncode({
        'dispute_id':  disputeId,
        if (buyerReply    != null) 'buyer_reply':   buyerReply,
        if (mpesaReceipt  != null) 'mpesa_receipt': mpesaReceipt,
      }),
    ).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw Exception(_extractError(res.body));
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> disputeChat({
    required String disputeId,
    required String message,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/disputes/chat'),
      headers: _headers,
      body: jsonEncode({
        'dispute_id': disputeId,
        'message':    message,
      }),
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception(_extractError(res.body));
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> executeDispute({
    required String disputeId,
    required String zacCode,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/disputes/execute'),
      headers: _headers,
      body: jsonEncode({
        'dispute_id': disputeId,
        'zac_code':   zacCode,
      }),
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception(_extractError(res.body));
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }



  // ──────────────────────────────────────────────────────────────────────
  // Speech-to-Text (Whisper)
  // ──────────────────────────────────────────────────────────────────────

  /// Uploads a recorded audio file to /stt/transcribe and returns the text.
  /// [audioBytes] should be raw bytes (m4a/mp3/wav/ogg/webm). [filename] is the
  /// hint shown to the server (used for the multipart filename field).
  static Future<String> transcribeAudio({
    required List<int> audioBytes,
    String filename = 'audio.m4a',
    String language = 'english',
  }) async {
    final uri = Uri.parse('$baseUrl/stt/transcribe');
    final req = http.MultipartRequest('POST', uri);
    if (_token != null) {
      req.headers['Authorization'] = 'Bearer $_token';
    }
    req.fields['language'] = language;
    req.files.add(http.MultipartFile.fromBytes('file', audioBytes, filename: filename));
    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode != 200) {
      throw Exception(_extractError(res.body));
    }
    final m = jsonDecode(res.body) as Map<String, dynamic>;
    return (m['text'] ?? '').toString();
  }

  // ──────────────────────────────────────────────────────────────────────
  // Escrow
  // ──────────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> confirmDelivery(String dealId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/escrow/confirm-delivery/$dealId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getEscrowState(String dealId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/escrow/state/$dealId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> freezeForDispute(String dealId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/escrow/open-dispute/$dealId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Admin (only callable by users with is_admin=true on the backend)
  // ──────────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> adminSummary() async {
    final res = await http.get(
      Uri.parse('$baseUrl/admin/summary'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static String _extractError(String body) {
    try {
      final m = jsonDecode(body) as Map;
      return m['detail']?.toString() ?? 'Unknown error';
    } catch (_) {
      return body.length > 120 ? '${body.substring(0, 120)}…' : body;
    }
  }
  // ── Incoming call check (polls for active call rooms) ─────────────────────
  static Future<Map<String, dynamic>?> checkIncomingCall(String listingId) async {
    try {
      final response = await http.get(
        Uri.parse('\$baseUrl/calls/pending/\$listingId'),
        headers: _headers,
      ).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['has_call'] == true) return data;
      }
    } catch (_) {}
    return null;
  }

}


