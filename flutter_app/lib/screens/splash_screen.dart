import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../main.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _orbit1, _orbit2, _orbit3, _pulse, _fade, _slide;
  late Animation<double> _pulseAnim, _fadeAnim, _slideAnim;

  @override
  void initState() {
    super.initState();
    _orbit1 = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();
    _orbit2 = AnimationController(vsync: this, duration: const Duration(seconds: 10))..repeat();
    _orbit3 = AnimationController(vsync: this, duration: const Duration(seconds: 15))..repeat(reverse: false);
    _pulse  = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))..repeat(reverse: true);
    _fade   = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _slide  = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

    _pulseAnim = Tween<double>(begin: 0.7, end: 1.0)
        .animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
    _fadeAnim  = Tween<double>(begin: 0.0, end: 1.0)
        .animate(CurvedAnimation(parent: _fade, curve: Curves.easeOut));
    _slideAnim = Tween<double>(begin: 40.0, end: 0.0)
        .animate(CurvedAnimation(parent: _slide, curve: Curves.easeOutCubic));

    _fade.forward();
    Future.delayed(const Duration(milliseconds: 300), () => _slide.forward());
    Future.delayed(const Duration(milliseconds: 3800), () {
      if (mounted) Navigator.pushReplacementNamed(context, '/auth');
    });
  }

  @override
  void dispose() {
    _orbit1.dispose(); _orbit2.dispose(); _orbit3.dispose();
    _pulse.dispose(); _fade.dispose(); _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.2),
            radius: 1.4,
            colors: [Color(0xFF1A0848), Color(0xFF08011E), Color(0xFF03000A)],
            stops: [0, 0.5, 1],
          ),
        ),
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Stack(children: [
            // Outer slow orbit ring
            Center(child: AnimatedBuilder(
              animation: _orbit3,
              builder: (_, __) => Transform.rotate(
                angle: _orbit3.value * 2 * pi,
                child: SizedBox(
                  width: size.width * 0.85,
                  height: size.width * 0.85,
                  child: CustomPaint(painter: _OrbitPainter(
                    dotCount: 24, dotRadius: 2,
                    color: BrokaColors.neonPurple.withOpacity(0.08),
                  )),
                ),
              ),
            )),
            // Middle orbit ring
            Center(child: AnimatedBuilder(
              animation: _orbit2,
              builder: (_, __) => Transform.rotate(
                angle: -_orbit2.value * 2 * pi,
                child: SizedBox(
                  width: size.width * 0.60,
                  height: size.width * 0.60,
                  child: CustomPaint(painter: _OrbitPainter(
                    dotCount: 16, dotRadius: 2.5,
                    color: BrokaColors.neonBlue.withOpacity(0.2),
                  )),
                ),
              ),
            )),
            // Inner fast orbit ring
            Center(child: AnimatedBuilder(
              animation: _orbit1,
              builder: (_, __) => Transform.rotate(
                angle: _orbit1.value * 2 * pi,
                child: SizedBox(
                  width: size.width * 0.38,
                  height: size.width * 0.38,
                  child: CustomPaint(painter: _OrbitPainter(
                    dotCount: 8, dotRadius: 3.5,
                    color: BrokaColors.neonPurple.withOpacity(0.5),
                  )),
                ),
              ),
            )),
            // Pulsing core glow
            Center(child: AnimatedBuilder(
              animation: _pulseAnim,
              builder: (_, __) => Container(
                width: 160 * _pulseAnim.value,
                height: 160 * _pulseAnim.value,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    BrokaColors.gradStart.withOpacity(0.6 * _pulseAnim.value),
                    BrokaColors.gradMid.withOpacity(0.3 * _pulseAnim.value),
                    Colors.transparent,
                  ]),
                ),
              ),
            )),
            // Core logo container
            Center(child: Container(
              width: 90, height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Color(0xFF7C3AED), Color(0xFF4F46E5)],
                  begin: Alignment.topLeft, end: Alignment.bottomRight),
                boxShadow: [
                  BoxShadow(color: const Color(0xFF7C3AED).withOpacity(0.7),
                    blurRadius: 40, spreadRadius: 8),
                ],
              ),
              child: const Center(child: Text('B', style: TextStyle(
                  fontSize: 44, fontWeight: FontWeight.w900,
                  color: Colors.white, letterSpacing: -2))),
            )),
            // Bottom text
            Positioned(
              bottom: 90, left: 0, right: 0,
              child: AnimatedBuilder(
                animation: _slideAnim,
                builder: (_, child) => Transform.translate(
                  offset: Offset(0, _slideAnim.value),
                  child: child,
                ),
                child: Column(children: [
                  ShaderMask(
                    shaderCallback: (b) => const LinearGradient(
                      colors: [BrokaColors.neonPurple, BrokaColors.neonBlue, BrokaColors.neonCyan],
                    ).createShader(b),
                    child: const Text('BROKA', style: TextStyle(
                      fontSize: 38, fontWeight: FontWeight.w900,
                      color: Colors.white, letterSpacing: 8)),
                  ),
                  const SizedBox(height: 8),
                  const Text('THE FUTURE OF INTELLIGENT COMMERCE',
                    style: TextStyle(
                      fontSize: 9, letterSpacing: 3.5,
                      fontWeight: FontWeight.w500,
                      color: BrokaColors.textLow)),
                  const SizedBox(height: 28),
                  // Scanning line animation
                  SizedBox(width: 120, child: AnimatedBuilder(
                    animation: _pulse,
                    builder: (_, __) => LinearProgressIndicator(
                      value: null,
                      backgroundColor: BrokaColors.border,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          BrokaColors.neonPurple.withOpacity(0.7 * _pulseAnim.value)),
                      minHeight: 1,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  )),
                  const SizedBox(height: 12),
                  const Text('INITIALISING AI SYSTEMS...',
                    style: TextStyle(fontSize: 9, letterSpacing: 2,
                        color: BrokaColors.textLow)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  final int dotCount;
  final double dotRadius;
  final Color color;
  const _OrbitPainter({required this.dotCount, required this.dotRadius, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - dotRadius;
    // Draw orbit circle faintly
    canvas.drawCircle(center, radius,
        Paint()..color = color.withOpacity(0.15)..style = PaintingStyle.stroke..strokeWidth = 0.5);
    for (int i = 0; i < dotCount; i++) {
      final angle = (i / dotCount) * 2 * pi;
      final x = center.dx + radius * cos(angle);
      final y = center.dy + radius * sin(angle);
      final r = i % 4 == 0 ? dotRadius * 1.6 : dotRadius;
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }
  @override
  bool shouldRepaint(_) => false;
}
