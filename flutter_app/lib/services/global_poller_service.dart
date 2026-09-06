// BROKA - Global Poller Service
//
// Runs independently of any single screen's lifecycle, checking ALL of the
// user's active negotiation threads (via the same inbox the inbox screen
// uses) for two things:
//   1. New messages that arrived while the user wasn't on that exact
//      negotiation/direct-chat screen.
//   2. Incoming calls, for either role - same reason.
//
// This exists because NotificationService was previously only ever
// triggered from inside negotiation_screen.dart's own poll timer - meaning
// notifications (for both calls and messages) were invisible unless that
// specific screen, for that specific listing, was open and in the
// foreground. FCM client integration is now wired in (main.dart) as the
// PRIMARY mechanism for background/terminated-app call delivery; this
// service's role is the foreground fallback - it still works today even
// before a real Firebase project exists (see FCM_SETUP_REMAINING.md), and
// keeps working as a safety net alongside FCM afterwards.
//
// IMPORTANT: this only works while the Dart VM is alive (app open or
// recently backgrounded, depending on OS). It does NOT wake a fully-killed
// app on its own - only real push (FCM) can do that.
//
// This is also where the device's FCM token gets (re-)registered with the
// backend - start() is the one function every login/session-restore path
// already calls (auth_screen.dart x3, splash_screen.dart's session
// restore), so registering here covers all of them without duplicating
// the call at each site, and naturally re-associates the token with
// whichever user is now authenticated on this device.

import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'api_service.dart';
import 'local_chat_store.dart';
import 'notification_service.dart';

class GlobalPollerService {
  GlobalPollerService._();
  static final GlobalPollerService instance = GlobalPollerService._();

  Timer? _timer;
  bool _checking = false;

  // Listing IDs currently "owned" by an open negotiation/direct-chat screen -
  // that screen already polls live, so we skip double-checking/double-firing
  // notifications for it here.
  final Set<String> _activelyViewedListingIds = {};

  void markScreenActive(String listingId) {
    _activelyViewedListingIds.add(listingId);
  }

  void markScreenInactive(String listingId) {
    _activelyViewedListingIds.remove(listingId);
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 7), (_) => _checkAll());
    // Run once immediately rather than waiting for the first tick.
    _checkAll();
    _registerFcmTokenIfAvailable();
  }

  /// Best-effort - throws if Firebase isn't initialized (no real project
  /// configured yet, see FCM_SETUP_REMAINING.md), which main.dart's own
  /// guard around Firebase.initializeApp() already anticipates. Silently
  /// does nothing in that case, exactly like the rest of the app today.
  Future<void> _registerFcmTokenIfAvailable() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await ApiService.registerFcmToken(token);
    } catch (_) {}
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _activelyViewedListingIds.clear();
  }

  Future<void> _checkAll() async {
    if (_checking) return; // avoid overlapping runs if one is slow
    if (ApiService.currentUserId == null) return;
    _checking = true;
    try {
      final threads = await ApiService.getInbox();
      // This service already fetches the full inbox every ~7s for
      // notification purposes - piggyback on that to keep InboxScreen's
      // offline cache warm too, so going offline no longer means "blank
      // error screen" unless the user has *never* had a connection since
      // installing. Previously this cache was only written from inside
      // InboxScreen itself, right after a successful load there - so it
      // stayed empty for the whole session if the user hadn't opened the
      // Inbox tab (with a connection) at least once, even if they'd been
      // actively chatting the whole time.
      unawaited(LocalChatStore.save(LocalChatStore.inboxListScope,
          threads.length > 300 ? threads.sublist(0, 300) : threads));
      final prefs = await SharedPreferences.getInstance();
      for (final thread in threads) {
        final listingId = thread['listing_id'] as String?;
        if (listingId == null) continue;
        if (_activelyViewedListingIds.contains(listingId)) continue;

        await _checkThreadForNewMessage(thread, prefs);
        if ((thread['my_role'] as String?) == 'seller') {
          await _checkThreadForIncomingCall(thread);
        }
      }
    } catch (_) {
      // Network hiccup or not logged in - just try again next tick.
    } finally {
      _checking = false;
    }
  }

  String _seenKeyFor(Map<String, dynamic> thread) {
    final listingId = thread['listing_id'];
    final buyerId   = thread['buyer_id'] ?? '';
    return 'global_poll_seen_${listingId}_$buyerId';
  }

  Future<void> _checkThreadForNewMessage(
    Map<String, dynamic> thread, SharedPreferences prefs,
  ) async {
    final lastMessage = thread['last_message'] as String? ?? '';
    final lastRole     = thread['last_role'] as String? ?? '';
    final myRole       = thread['my_role'] as String? ?? 'buyer';
    if (lastMessage.isEmpty) return;
    // Don't notify about our own most recent message.
    if (lastRole == myRole) return;

    final key = _seenKeyFor(thread);
    final signature = '$lastRole|$lastMessage';
    final lastSeenSignature = prefs.getString(key);
    if (lastSeenSignature == signature) return; // already notified for this message

    await prefs.setString(key, signature);
    // Don't fire on the very first time we ever see this thread (would spam
    // a notification for old history the moment a new thread is detected).
    if (lastSeenSignature == null) return;

    final fromName = lastRole == 'broker'
        ? 'Zeno'
        : (thread['counterpart_name'] as String? ?? 'Someone');
    await NotificationService.instance.showNewMessage(
      fromName: fromName,
      preview: lastMessage,
      threadKey: 'thread_${thread['listing_id']}_${thread['buyer_id'] ?? ''}',
      payload: {
        'type':      'new_message',
        'listingId': thread['listing_id'],
        'buyerId':   thread['buyer_id'],
        'myRole':    myRole,
      },
    );
  }

  Future<void> _checkThreadForIncomingCall(Map<String, dynamic> thread) async {
    final listingId = thread['listing_id'] as String?;
    if (listingId == null) return;
    try {
      final callInfo = await ApiService.checkIncomingCall(listingId);
      if (callInfo == null) return;
      final roomId     = callInfo['room_id'] as String?;
      final callerName = callInfo['caller_name'] as String? ?? 'Buyer';
      final isVideo    = callInfo['call_type'] == 'video';
      // FIX (V2 hardening, 2026-09-03): caller_id is NOT always the buyer -
      // only true when I'm the seller being called. When I'm the buyer
      // being called (by the seller), the buyer is me, not the caller.
      final myRole  = thread['my_role'] as String? ?? 'buyer';
      final buyerId = myRole == 'seller'
          ? (callInfo['caller_id'] as String? ?? '')
          : (thread['buyer_id'] as String? ?? '');
      if (roomId == null) return;
      await NotificationService.instance.showIncomingCall(
        roomId: roomId,
        callerName: callerName,
        listingName: thread['listing_name'] as String? ?? 'your listing',
        isVideo: isVideo,
        payload: {
          'type':      'incoming_call',
          'roomId':    roomId,
          'listingId': listingId,
          'buyerId':   buyerId,
        },
      );
    } catch (_) {}
  }
}
