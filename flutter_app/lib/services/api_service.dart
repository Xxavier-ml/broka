// BROKA — API Service
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
  static String? currentUserEmail;
  static double? currentUserLat;
  static double? currentUserLng;
  static String  currentUserLanguage = 'english'; // preferred language

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  static Future<void> loadSavedSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token           = prefs.getString('auth_token');
    currentUserId    = prefs.getString('user_id');
    currentUserName  = prefs.getString('user_name');
    currentUserEmail = prefs.getString('user_email');
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
    String? email,
    String? password,
    double? lat,
    double? lng,
  }) async {
    _token           = token;
    currentUserId    = userId;
    currentUserName  = name;
    currentUserEmail = email;
    currentUserLat   = lat;
    currentUserLng   = lng;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    await prefs.setString('user_id', userId);
    if (name     != null) await prefs.setString('user_name',     name);
    if (email    != null) await prefs.setString('user_email',    email);
    if (password != null) await prefs.setString('user_password', password);
    if (lat      != null) await prefs.setDouble('user_lat',      lat);
    if (lng      != null) await prefs.setDouble('user_lng',      lng);
  }

  static Future<void> clearSession() async {
    _token              = null;
    currentUserId       = null;
    currentUserName     = null;
    currentUserEmail    = null;
    currentUserLat      = null;
    currentUserLng      = null;
    currentUserLanguage = 'english';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('user_id');
    await prefs.remove('user_name');
    await prefs.remove('user_email');
    await prefs.remove('user_password');
    await prefs.remove('user_lat');
    await prefs.remove('user_lng');
    await prefs.remove('user_language');
  }

  /// Save language preference locally and sync to backend.
  static Future<void> setLanguage(String language) async {
    currentUserLanguage = language;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_language', language);
    try {
      await http.patch(
        Uri.parse('$baseUrl/auth/language?language=$language'),
        headers: _headers,
      );
    } catch (_) {
      // Language saved locally even if server sync fails
    }
  }

  static bool get isLoggedIn => _token != null;

  static void setDemoSession() {
    _token           = 'demo-token';
    currentUserId    = 'demo-user';
    currentUserName  = 'Demo User';
    currentUserEmail = 'demo@broka.ke';
  }

  // ── Silent re-login (called automatically when token expires) ─────────────

  static Future<bool> _tryRelogin() async {
    try {
      final prefs   = await SharedPreferences.getInstance();
      final email   = prefs.getString('user_email');
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
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/register'),
      headers: _headers,
      body: jsonEncode({
        'name': name, 'email': email, 'phone': phone,
        'password': password, 'lat': lat, 'lng': lng,
      }),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 201) {
      await _saveSession(
        data['access_token'], data['user_id'],
        name: data['name'],
        email: email,
        password: password,
        lat: lat,
        lng: lng,
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
        email: email,
        password: password,
        lat: (data['lat'] as num?)?.toDouble(),
        lng: (data['lng'] as num?)?.toDouble(),
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
      // Push to backend so other users see correct distance
      await http.patch(
        Uri.parse('$baseUrl/auth/location').replace(
          queryParameters: {'lat': lat.toString(), 'lng': lng.toString()},
        ),
        headers: _headers,
      );
    } catch (_) {} // non-fatal — local update still saved
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

      // Token expired — silently re-login and retry once
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
    return Message.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

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
        'system_override': 'xxeno',
        'language':        language ?? currentUserLanguage,
      }),
    );
    return Message.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
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
    return Message.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  static Future<List<Message>> getNegotiationHistory(String listingId) async {
    // Role is derived server-side from the JWT — no need to pass it explicitly.
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
}
