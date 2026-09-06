// BROKA - Notification Service (local notifications + FCM foreground/tap handling)
//
// Uses flutter_local_notifications to surface heads-up notifications for:
//   • new negotiation/chat messages (detected by GlobalPollerService or the
//     in-app screen-level pollers)
//   • incoming VoIP calls (detected by GlobalPollerService, the seller's
//     in-screen call poller, or now an FCM data message - see
//     handleForegroundFcmMessage below and firebaseMessagingBackgroundHandler
//     in main.dart)
//
// FCM client integration is wired up (main.dart initializes Firebase,
// registers the background/foreground/tap handlers) but only takes effect
// once a real Firebase project + google-services.json exist - see
// FCM_SETUP_REMAINING.md for exactly what's still externally configurable.
// Until then, Firebase.initializeApp() throws, main.dart catches that, and
// this service works exactly as it always has: local notifications only,
// while the app process is alive (foreground or backgrounded).
//
// One shared call-routing mechanism regardless of source: local-notification
// taps, FCM message taps (onMessageOpenedApp/getInitialMessage), foreground
// FCM messages, and the pollers all ultimately go through
// navigateFromPayload/showIncomingCall below.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'api_service.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  GlobalKey<NavigatorState>? navigatorKey;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  // Two channels so calls can be more intrusive (sound + high importance) than
  // ordinary message notifications.
  static const AndroidNotificationChannel _messageChannel =
      AndroidNotificationChannel(
    'broka_messages',
    'Messages',
    description: 'New negotiation and chat messages',
    importance: Importance.high,
  );

  static final AndroidNotificationChannel _callChannel =
      AndroidNotificationChannel(
    // NOTE: bumped from 'broka_calls' -> 'broka_calls_v2'. Android channel
    // settings (including sound) are immutable once created on a device, so
    // adding a custom ringtone to the old channel ID would silently do
    // nothing on installs that already had it. A new ID guarantees the
    // ringtone takes effect for everyone, including existing installs.
    'broka_calls_v2',
    'Incoming Calls',
    description: 'Incoming BROKA in-app calls',
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('ringtone'),
  );

  Future<void> initialize({
    required GlobalKey<NavigatorState> navKey,
  }) async {
    navigatorKey = navKey;

    const androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings =
        InitializationSettings(android: androidInit, iOS: iosInit);

    try {
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: _onTap,
      );

      // Register channels (Android 8+). No-op elsewhere.
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(_messageChannel);
      await android?.createNotificationChannel(_callChannel);
      // Android 13+ runtime permission.
      await android?.requestNotificationsPermission();

      _ready = true;
      debugPrint('[Notifications] Local notifications ready.');
    } catch (e) {
      debugPrint('[Notifications] init failed: $e');
    }
  }

  int _idFor(String key) => key.hashCode & 0x7fffffff;

  void _onTap(NotificationResponse response) {
    final raw = response.payload;
    if (raw == null || raw.isEmpty) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      navigateFromPayload(data);
    } catch (e) {
      debugPrint('[Notifications] payload decode failed: $e');
    }
  }

  /// Handles an FCM data message that arrived while the app was in the
  /// foreground (FirebaseMessaging.onMessage in main.dart). FCM never
  /// auto-displays anything on any platform while the app is frontmost, so
  /// without this the user would see nothing at all for a foreground
  /// incoming call. Deliberately reuses showIncomingCall - the same call
  /// the poller already makes - rather than a separate foreground-only
  /// code path, so behavior is identical no matter which mechanism
  /// detected the call.
  Future<void> handleForegroundFcmMessage(Map<String, dynamic> data) async {
    if (data['type'] != 'incoming_call') return;
    final roomId = data['roomId'] as String?;
    if (roomId == null) return;
    await showIncomingCall(
      roomId: roomId,
      callerName: data['callerName'] as String? ?? 'Someone',
      listingName: data['listingName'] as String? ?? 'your listing',
      isVideo: data['callType'] == 'video',
      payload: data,
    );
  }

  /// Shared navigation logic for local-notification taps AND real FCM
  /// message taps (onMessageOpenedApp / getInitialMessage in main.dart) -
  /// same payload shape, same destinations, one call-routing mechanism.
  Future<void> navigateFromPayload(Map<String, dynamic> data) async {
    final nav = navigatorKey?.currentState;
    if (nav == null) return;
    final type = data['type'] as String?;

    if (type == 'incoming_call') {
      final listingId = data['listingId'] as String?;
      final buyerId = data['buyerId'] as String? ?? '';
      final iAmBuyer = ApiService.currentUserId != null &&
          ApiService.currentUserId == buyerId;
      if (listingId == null) return;
      // This may be tapped long after it was posted (app backgrounded or
      // fully killed in between), so the payload itself only carries
      // enough to identify *which listing* - re-check the call's live
      // status here and get a fresh, still-valid room-scoped call token
      // the same way the in-app poller does, rather than trusting
      // anything time-sensitive that was baked in when the notification
      // was first shown. If it's no longer pending (already answered on
      // another device, missed, or cancelled by the time this is tapped),
      // land on the conversation instead of a dead call screen.
      final callInfo = await ApiService.checkIncomingCall(listingId);
      final roomId = callInfo?['room_id'] as String?;
      if (callInfo == null || roomId == null) {
        nav.pushNamed('/direct-chat', arguments: {
          'listingId': listingId,
          'role':      iAmBuyer ? 'buyer' : 'seller',
          'buyer_id':  buyerId,
        });
        return;
      }
      nav.pushNamed('/voip-call', arguments: {
        'roomId':      roomId,
        'userId':      ApiService.currentUserId ?? '',
        'callToken':   callInfo['call_token'] as String? ?? '',
        'isCaller':    false,
        'peerName':    callInfo['caller_name'] as String? ?? 'Someone',
        'listingName': data['listingName'] as String? ?? 'your listing',
        'listingId':   listingId,
        'buyerId':     buyerId,
        'callerRole':  iAmBuyer ? 'seller' : 'buyer',
        'callType':    callInfo['call_type'] as String? ?? 'audio',
      });
      return;
    }
    if (type == 'new_message') {
      final role = data['myRole'] as String? ?? 'buyer';
      nav.pushNamed('/direct-chat', arguments: {
        'listingId': data['listingId'] as String?,
        'role':      role,
        'buyer_id':  data['buyerId'] as String?,
      });
      return;
    }
  }

  /// Show a notification for a newly received message in a thread.
  Future<void> showNewMessage({
    required String fromName,
    required String preview,
    String threadKey = 'chat',
    Map<String, dynamic>? payload,
  }) async {
    if (!_ready) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'broka_messages',
        'Messages',
        channelDescription: 'New negotiation and chat messages',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
      iOS: DarwinNotificationDetails(),
    );
    try {
      await _plugin.show(
        _idFor(threadKey),
        fromName,
        preview,
        details,
        payload: payload != null ? jsonEncode(payload) : null,
      );
    } catch (e) {
      debugPrint('[Notifications] showNewMessage failed: $e');
    }
  }

  /// Show an incoming-call notification (more intrusive channel).
  Future<void> showIncomingCall({
    required String roomId,
    required String callerName,
    required String listingName,
    bool isVideo = false,
    Map<String, dynamic>? payload,
  }) async {
    if (!_ready) return;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'broka_calls_v2',
        'Incoming Calls',
        channelDescription: 'Incoming BROKA in-app calls',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('ringtone'),
        icon: '@mipmap/ic_launcher',
      ),
      iOS: DarwinNotificationDetails(
        sound: 'ringtone.mp3',
        presentSound: true,
      ),
    );
    try {
      await _plugin.show(
        // Room-scoped, not a fixed constant - two different incoming calls
        // (rare, but possible: two different people calling in quick
        // succession) get distinct notification slots instead of the
        // second silently replacing the first. The *same* call detected
        // through more than one path (FCM data message, poller) still
        // correctly collapses into one, since both resolve to this same id.
        _idFor('call_$roomId'),
        isVideo
            ? '📹 Incoming video call from $callerName'
            : '📞 Incoming call from $callerName',
        'About: $listingName',
        details,
        payload: payload != null ? jsonEncode(payload) : null,
      );
    } catch (e) {
      debugPrint('[Notifications] showIncomingCall failed: $e');
    }
  }

  // Kept for backward-compatibility with existing callers. Now surfaces a real
  // local notification instead of being a no-op.
  Future<void> sendCallNotification({
    required String targetUserId,
    required String roomId,
    required String callerName,
    required String listingName,
  }) async {
    await showIncomingCall(roomId: roomId, callerName: callerName, listingName: listingName);
  }
}

