import 'package:flutter/material.dart';
import 'dart:math';
import '../main.dart';
import '../services/api_service.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with TickerProviderStateMixin {
  bool _isLogin = true;
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  final _emailCtrl    = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _nameCtrl     = TextEditingController();
  final _phoneCtrl    = TextEditingController();

  late AnimationController _bgAnim, _fadeCtrl, _formSlide;
  late Animation<double> _fade, _slide;

  @override
  void initState() {
    super.initState();
    _bgAnim    = AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat(reverse: true);
    _fadeCtrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _formSlide = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _fade  = CurvedAnimation(parent: _fadeCtrl,  curve: Curves.easeOut);
    _slide = Tween<double>(begin: 30.0, end: 0.0)
        .animate(CurvedAnimation(parent: _formSlide, curve: Curves.easeOutCubic));
    _fadeCtrl.forward();
    _formSlide.forward();
  }

  @override
  void dispose() {
    _bgAnim.dispose(); _fadeCtrl.dispose(); _formSlide.dispose();
    _emailCtrl.dispose(); _passwordCtrl.dispose();
    _nameCtrl.dispose(); _phoneCtrl.dispose();
    super.dispose();
  }

  void _switchMode(bool toLogin) {
    setState(() { _isLogin = toLogin; _error = null; });
    _formSlide.forward(from: 0);
  }

  Future<void> _submit() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (_isLogin) {
        await ApiService.login(
          email: _emailCtrl.text.trim(),
          password: _passwordCtrl.text);
      } else {
        await ApiService.register(
          name: _nameCtrl.text.trim(), email: _emailCtrl.text.trim(),
          phone: _phoneCtrl.text.trim(), password: _passwordCtrl.text,
          lat: -1.286389, lng: 36.817223,
        );
      }
      if (mounted) Navigator.pushReplacementNamed(context, '/home');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        // Animated deep space background
        Positioned.fill(child: AnimatedBuilder(
          animation: _bgAnim,
          builder: (_, __) => Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(
                  sin(_bgAnim.value * 2 * pi) * 0.3,
                  cos(_bgAnim.value * 2 * pi) * 0.2 - 0.3,
                ),
                radius: 1.6,
                colors: const [
                  Color(0xFF1E0A4E),
                  Color(0xFF0A0520),
                  Color(0xFF03000A),
                ],
              ),
            ),
          ),
        )),
        // Grid lines overlay
        Positioned.fill(child: CustomPaint(painter: _GridPainter())),
        // Content
        FadeTransition(
          opacity: _fade,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: AnimatedBuilder(
                animation: _slide,
                builder: (_, child) => Transform.translate(
                  offset: Offset(0, _slide.value), child: child),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    // Logo row
                    Row(children: [
                      Container(
                        width: 48, height: 48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: const LinearGradient(
                            colors: [BrokaColors.gradStart, BrokaColors.gradMid],
                            begin: Alignment.topLeft, end: Alignment.bottomRight),
                          boxShadow: const [BrokaColors.glowPurple],
                          border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.3)),
                        ),
                        child: const Center(child: Text('B', style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w900, fontSize: 24))),
                      ),
                      const SizedBox(width: 12),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        ShaderMask(
                          shaderCallback: (b) => const LinearGradient(
                            colors: [BrokaColors.neonPurple, BrokaColors.neonBlue],
                          ).createShader(b),
                          child: const Text('BROKA', style: TextStyle(
                              fontSize: 24, fontWeight: FontWeight.w900,
                              color: Colors.white, letterSpacing: 3)),
                        ),
                        const Text('INTELLIGENT COMMERCE',
                          style: TextStyle(fontSize: 8, letterSpacing: 3,
                              color: BrokaColors.textLow, fontWeight: FontWeight.w600)),
                      ]),
                    ]),
                    const SizedBox(height: 40),

                    // Headline
                    Text(
                      _isLogin ? 'Welcome Back' : 'Join the Future',
                      style: const TextStyle(
                          fontSize: 30, fontWeight: FontWeight.w800,
                          color: BrokaColors.textHigh, letterSpacing: -0.5),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _isLogin
                          ? 'Access the AI-powered trading network'
                          : 'Create your intelligent trading identity',
                      style: const TextStyle(
                          color: BrokaColors.textMid, fontSize: 14),
                    ),
                    const SizedBox(height: 32),

                    // Tab toggle — pill style
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: BrokaColors.bgCard,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: BrokaColors.border),
                      ),
                      child: Row(children: [
                        _tab('Login',   _isLogin,  () => _switchMode(true)),
                        _tab('Sign Up', !_isLogin, () => _switchMode(false)),
                      ]),
                    ),
                    const SizedBox(height: 28),

                    // Form fields
                    if (!_isLogin) ...[
                      _field(_nameCtrl,  'Full Name',    Icons.person_outline_rounded),
                      const SizedBox(height: 14),
                      _field(_phoneCtrl, 'Phone Number', Icons.phone_outlined,
                          type: TextInputType.phone),
                      const SizedBox(height: 14),
                    ],
                    _field(_emailCtrl, 'Email Address', Icons.alternate_email,
                        type: TextInputType.emailAddress),
                    const SizedBox(height: 14),

                    // Password
                    TextField(
                      controller: _passwordCtrl,
                      obscureText: _obscure,
                      style: const TextStyle(color: BrokaColors.textHigh),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline_rounded,
                            color: BrokaColors.textLow, size: 18),
                        suffixIcon: GestureDetector(
                          onTap: () => setState(() => _obscure = !_obscure),
                          child: Icon(_obscure
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                              color: BrokaColors.textLow, size: 18),
                        ),
                      ),
                    ),

                    if (_isLogin) ...[
                      const SizedBox(height: 12),
                      Align(alignment: Alignment.centerRight,
                        child: Text('Forgot password?',
                          style: TextStyle(color: BrokaColors.neonPurple.withOpacity(0.8),
                              fontSize: 13, fontWeight: FontWeight.w600))),
                    ],
                    const SizedBox(height: 28),

                    // Error
                    if (_error != null)
                      Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: BrokaColors.danger.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: BrokaColors.danger.withOpacity(0.3)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.error_outline,
                              color: BrokaColors.danger, size: 16),
                          const SizedBox(width: 10),
                          Expanded(child: Text(_error!, style: const TextStyle(
                              color: BrokaColors.danger, fontSize: 12))),
                        ]),
                      ),

                    // CTA
                    GradientButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(width: 22, height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(_isLogin ? 'Access Network' : 'Activate Account',
                                style: const TextStyle(fontSize: 15,
                                    fontWeight: FontWeight.w700, color: Colors.white)),
                              const SizedBox(width: 8),
                              const Icon(Icons.arrow_forward_rounded,
                                  color: Colors.white, size: 18),
                            ]),
                    ),
                    const SizedBox(height: 32),

                    // Divider
                    Row(children: [
                      Expanded(child: Container(height: 1,
                          color: BrokaColors.border.withOpacity(0.5))),
                      Padding(padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Text('or',
                          style: TextStyle(color: BrokaColors.textLow.withOpacity(0.7),
                              fontSize: 12))),
                      Expanded(child: Container(height: 1,
                          color: BrokaColors.border.withOpacity(0.5))),
                    ]),
                    const SizedBox(height: 24),

                    // Switch prompt
                    Center(child: GestureDetector(
                      onTap: () => _switchMode(!_isLogin),
                      child: RichText(text: TextSpan(
                        style: const TextStyle(fontSize: 14, color: BrokaColors.textMid),
                        children: [
                          TextSpan(text: _isLogin
                              ? "New to BROKA? " : "Already a trader? "),
                          TextSpan(
                            text: _isLogin ? 'Create account' : 'Sign in',
                            style: const TextStyle(
                                color: BrokaColors.neonPurple,
                                fontWeight: FontWeight.w700)),
                        ],
                      )),
                    )),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _tab(String label, bool active, VoidCallback onTap) => Expanded(
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          gradient: active ? const LinearGradient(
            colors: [BrokaColors.gradStart, BrokaColors.gradMid],
            begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
          borderRadius: BorderRadius.circular(12),
          boxShadow: active ? const [BrokaColors.glowPurple] : null,
        ),
        child: Text(label, textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
            color: active ? Colors.white : BrokaColors.textLow)),
      ),
    ),
  );

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType type = TextInputType.text}) =>
    TextField(
      controller: ctrl, keyboardType: type,
      style: const TextStyle(color: BrokaColors.textHigh),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: BrokaColors.textLow, size: 18),
      ),
    );
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF7C3AED).withOpacity(0.03)
      ..strokeWidth = 0.5;
    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }
  @override
  bool shouldRepaint(_) => false;
}
