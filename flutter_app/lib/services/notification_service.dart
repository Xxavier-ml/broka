// BROKA - Notification Service (stub)
// Firebase push notifications require google-services.json which is not
// committed to the repo. This stub allows the app to compile and run without
// Firebase. To enable push notifications:
//   1. Create a Firebase project at console.firebase.google.com
//   2. Add your Android app (package: com.broka.app)
//   3. Download google-services.json → android/app/google-services.json
//   4. Add firebase_core, firebase_messaging, flutter_local_notifications to pubspec.yaml
//   5. Uncomment the google-services plugin in android/app/build.gradle

import 'package:flutter/material.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  GlobalKey<NavigatorState>? navigatorKey;

  Future<void> initialize({
    required GlobalKey<NavigatorState> navKey,
  }) async {
    navigatorKey = navKey;
    debugPrint('[Notifications] Running without Firebase. '
        'Add google-services.json to enable push notifications.');
  }

  // Called by VoIP screen when a call is initiated to notify the other party
  // (No-op without Firebase - notifications won't be delivered remotely)
  Future<void> sendCallNotification({
    required String targetUserId,
    required String roomId,
    required String callerName,
    required String listingName,
  }) async {
    debugPrint('[Notifications] sendCallNotification: Firebase not configured.');
  }
}
