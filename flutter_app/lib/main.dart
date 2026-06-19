import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/splash_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'screens/sell_screen.dart';
import 'screens/broker_screen.dart';
import 'screens/auction_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/inbox_screen.dart';
import 'screens/negotiation_screen.dart';
import 'screens/ai_assistant_screen.dart';
import 'screens/product_screen.dart';
import 'screens/zeno_screen.dart';
import 'screens/listing_map_screen.dart';
import 'screens/selfie_camera_screen.dart';
import 'screens/user_profile_screen.dart';
import 'screens/search_screen.dart';
import 'screens/seller_dashboard_screen.dart';
import 'screens/mpesa_confirmation_screen.dart';
import 'screens/deal_receipt_history_screen.dart';
import 'screens/voip_call_screen.dart';
import 'screens/dispute_screen.dart';
import 'screens/verification_screen.dart';
import 'screens/boost_screen.dart';
import 'screens/review_screen.dart';
import 'services/api_service.dart';
import 'services/notification_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF03000A),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  await ApiService.loadSavedSession();
  await NotificationService.instance.initialize(navKey: navigatorKey);
  runApp(const BrokaApp());
}

// ─── Design Tokens ─────────────────────────────────────────────────────────
class BrokaColors {
  static const bg        = Color(0xFF03000A);
  static const bgMid     = Color(0xFF07021A);
  static const bgCard    = Color(0xFF0D0828);
  static const bgGlass   = Color(0x1A8B5CF6);

  static const gradStart = Color(0xFF7C3AED);
  static const gradMid   = Color(0xFF4F46E5);
  static const gradEnd   = Color(0xFF1E1B4B);

  static const neonPurple = Color(0xFFA78BFA);
  static const neonBlue   = Color(0xFF38BDF8);
  static const neonGreen  = Color(0xFF34D399);
  static const neonPink   = Color(0xFFF472B6);
  static const neonCyan   = Color(0xFF22D3EE);

  static const gold    = Color(0xFFFBBF24);
  static const success = Color(0xFF10B981);
  static const danger  = Color(0xFFEF4444);
  static const warning = Color(0xFFF59E0B);

  static const textHigh = Color(0xFFF8F7FF);
  static const textMid  = Color(0xFF8B7EC8);
  static const textLow  = Color(0xFF3D3468);

  static const border     = Color(0xFF1E1648);
  static const borderGlow = Color(0xFF7C3AED);

  static const List<Color> headerGradColors = [Color(0xFF0F0830), Color(0xFF03000A)];
  static const List<Color> cardGradColors   = [Color(0xFF130D35), Color(0xFF080520)];

  static const bool isDark = true;

  static const primaryGradient = LinearGradient(
    colors: [gradStart, gradMid],
    begin: Alignment.topLeft, end: Alignment.bottomRight,
  );
  static const cardGradient = LinearGradient(
    colors: cardGradColors,
    begin: Alignment.topLeft, end: Alignment.bottomRight,
  );
  static const glowPurple = BoxShadow(
      color: Color(0x507C3AED), blurRadius: 28, spreadRadius: 0);
  static const glowBlue = BoxShadow(
      color: Color(0x4038BDF8), blurRadius: 20, spreadRadius: 0);
  static const glowCyan = BoxShadow(
      color: Color(0x4022D3EE), blurRadius: 20, spreadRadius: 0);
}

class BrokaApp extends StatelessWidget {
  const BrokaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'BROKA',
      theme: _buildTheme(),
      initialRoute: '/splash',
      routes: {
        '/splash':           (_) => const SplashScreen(),
        '/auth':             (_) => const AuthScreen(),
        '/home':             (_) => const HomeScreen(),
        '/sell':             (_) => const SellScreen(),
        '/broker':           (_) => const BrokerScreen(),
        '/auction':          (_) => const AuctionScreen(),
        '/profile':          (_) => const ProfileScreen(),
        '/inbox':            (_) => const InboxScreen(),
        '/negotiate':        (_) => const NegotiationScreen(),
        '/assistant':        (_) => const AiAssistantScreen(),
        '/product':          (_) => const ProductScreen(),
        '/zeno':             (_) => const ZenoScreen(),
        '/xxeno':            (_) => const ZenoScreen(), // legacy deep-link compat - routes to Zeno
        '/listing-map':      (_) => const ListingMapScreen(),
        '/selfie':           (_) => const SelfieCameraScreen(),
        '/user-profile':     (_) => const UserProfileScreen(),
        '/search':           (_) => const SearchScreen(),
        '/seller-dashboard': (_) => const SellerDashboardScreen(),
        '/mpesa-confirm':     (_) => const MpesaConfirmationScreen(),
        '/receipt-history':   (_) => const DealReceiptHistoryScreen(),
        '/voip-call':         (_) => const VoipCallScreen(),
        '/dispute':           (_) => const DisputeScreen(),
        '/verification':      (_) => const VerificationScreen(),
        '/boost-listing':     (_) => const BoostScreen(),
        '/review':            (_) => const ReviewScreen(),
      },
    );
  }

  ThemeData _buildTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: BrokaColors.bg,
      colorScheme: const ColorScheme.dark(
        primary:   BrokaColors.neonPurple,
        secondary: BrokaColors.neonBlue,
        surface:   BrokaColors.bgCard,
        error:     BrokaColors.danger,
      ),
      fontFamily: 'sans-serif',
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
            color: BrokaColors.textHigh, fontSize: 18,
            fontWeight: FontWeight.w800, letterSpacing: 0.3),
        iconTheme: IconThemeData(color: BrokaColors.textMid),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: BrokaColors.bgCard,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: BrokaColors.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: BrokaColors.border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: BrokaColors.neonPurple, width: 1.5)),
        labelStyle: const TextStyle(color: BrokaColors.textMid, fontSize: 13),
        hintStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 13),
      ),
      dividerTheme: const DividerThemeData(color: BrokaColors.border, thickness: 1),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: BrokaColors.bgCard,
        contentTextStyle: const TextStyle(color: BrokaColors.textHigh),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

// ─── Gradient Button ──────────────────────────────────────────────────────
class GradientButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final double height;
  final List<Color> colors;

  const GradientButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.height = 56,
    this.colors = const [BrokaColors.gradStart, BrokaColors.gradMid],
  });

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    decoration: BoxDecoration(
      gradient: LinearGradient(
          colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
      borderRadius: BorderRadius.circular(16),
      boxShadow: const [BrokaColors.glowPurple],
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        splashColor: Colors.white10,
        child: Center(child: child),
      ),
    ),
  );
}

// ─── Glass Card ───────────────────────────────────────────────────────────
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final VoidCallback? onTap;
  final bool glowing;

  const GlassCard({super.key, required this.child,
      this.padding, this.onTap, this.glowing = false});

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      gradient: BrokaColors.cardGradient,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: glowing
            ? BrokaColors.neonPurple.withOpacity(0.5) : BrokaColors.border),
      boxShadow: glowing ? const [BrokaColors.glowPurple] : null,
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        splashColor: BrokaColors.neonPurple.withOpacity(0.05),
        child: Padding(
            padding: padding ?? const EdgeInsets.all(16),
            child: child),
      ),
    ),
  );
}
