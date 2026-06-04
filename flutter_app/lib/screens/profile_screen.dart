import 'package:flutter/material.dart';
import '../main.dart';
import '../services/api_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _notificationsEnabled = true;
  bool _darkMode             = true;
  bool _loadingStats         = true;

  // Real data from backend
  int    _listingCount   = 0;
  int    _dealsCount     = 0;
  double _rating         = 5.0;
  double _volumeTraded   = 0;
  bool   _isVerified     = false;

  String get _name     => ApiService.currentUserName  ?? 'BROKA User';
  String get _email    => ApiService.currentUserEmail ?? 'user@broka.ke';
  String get _initials {
    final parts = _name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return _name.isNotEmpty ? _name[0].toUpperCase() : 'B';
  }

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() => _loadingStats = true);
    try {
      final data = await ApiService.getMe();
      if (mounted) {
        setState(() {
          _listingCount = (data['listing_count']   as num?)?.toInt()    ?? 0;
          _dealsCount   = (data['completed_deals'] as num?)?.toInt()    ?? 0;
          _rating       = (data['rating']          as num?)?.toDouble() ?? 5.0;
          _volumeTraded = (data['volume_traded']   as num?)?.toDouble() ?? 0;
          _isVerified   = data['is_verified']      as bool?             ?? false;
          _loadingStats = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingStats = false);
    }
  }

  String _formatVolume(double v) {
    if (v >= 1000000) return 'KES ${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return 'KES ${(v / 1000).toStringAsFixed(0)}K';
    if (v == 0)       return 'KES 0';
    return 'KES ${v.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bgMid,
        title: const Text('Profile',
            style: TextStyle(
                color: BrokaColors.textHigh,
                fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded,
                color: BrokaColors.textMid, size: 20),
            tooltip: 'Sign out',
            onPressed: _confirmSignOut,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        color: BrokaColors.neonPurple,
        backgroundColor: BrokaColors.bgCard,
        onRefresh: _loadProfile,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildAvatar(),
            const SizedBox(height: 24),
            _buildStatsRow(),
            const SizedBox(height: 24),
            _buildSectionLabel('Account'),
            _buildInfoTile(Icons.person_outline_rounded, 'Name', _name),
            _buildInfoTile(Icons.email_outlined, 'Email', _email),
            const SizedBox(height: 20),
            _buildSectionLabel('Preferences'),
            _buildToggleTile(
              icon: Icons.notifications_outlined,
              label: 'Push notifications',
              value: _notificationsEnabled,
              onChanged: (v) => setState(() => _notificationsEnabled = v),
            ),
            _buildToggleTile(
              icon: Icons.dark_mode_outlined,
              label: 'Dark mode',
              subtitle: 'Light mode coming soon',
              value: _darkMode,
              onChanged: (_) {},
            ),
            _buildLanguagePicker(),
            const SizedBox(height: 20),
            _buildSectionLabel('Support'),
            _buildNavTile(Icons.help_outline_rounded, 'Help & FAQ',
                () => _showComingSoon('Help & FAQ')),
            _buildNavTile(Icons.shield_outlined, 'Privacy policy',
                () => _showComingSoon('Privacy policy')),
            _buildNavTile(Icons.star_outline_rounded, 'Rate BROKA',
                () => _showComingSoon('Rate BROKA')),
            const SizedBox(height: 28),
            _buildSignOutButton(),
            const SizedBox(height: 32),
            const Center(
              child: Text('BROKA v2.1.0',
                  style: TextStyle(
                      color: BrokaColors.textLow, fontSize: 11)),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar() => Center(
    child: Column(children: [
      Container(
        width: 88, height: 88,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: BrokaColors.headerGradColors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [BrokaColors.glowPurple],
        ),
        child: Center(child: Text(_initials,
            style: const TextStyle(
                color: Colors.white, fontSize: 30,
                fontWeight: FontWeight.w800))),
      ),
      const SizedBox(height: 14),
      Text(_name, style: const TextStyle(
          color: BrokaColors.textHigh,
          fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text(_email, style: const TextStyle(
          color: BrokaColors.textMid, fontSize: 13)),
      const SizedBox(height: 10),
      if (_isVerified)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: BrokaColors.neonGreen.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.4)),
          ),
          child: const Text('✓ Verified Seller',
              style: TextStyle(color: BrokaColors.neonGreen,
                  fontSize: 11, fontWeight: FontWeight.w700)),
        )
      else
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: BrokaColors.textLow.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: BrokaColors.border),
          ),
          child: const Text('Unverified',
              style: TextStyle(color: BrokaColors.textLow,
                  fontSize: 11, fontWeight: FontWeight.w700)),
        ),
    ]),
  );

  Widget _buildStatsRow() {
    if (_loadingStats) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: BrokaColors.cardGradColors),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.border),
        ),
        child: const Center(child: SizedBox(
          width: 20, height: 20,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: BrokaColors.neonPurple),
        )),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: BrokaColors.cardGradColors,
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildStat('$_listingCount', 'Listings'),
          _buildDivider(),
          _buildStat('$_dealsCount', 'Deals'),
          _buildDivider(),
          _buildStat('${_rating.toStringAsFixed(1)}★', 'Rating'),
          _buildDivider(),
          _buildStat(_formatVolume(_volumeTraded), 'Traded'),
        ],
      ),
    );
  }

  Widget _buildStat(String value, String label) => Column(children: [
    Text(value, style: const TextStyle(
        color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
    const SizedBox(height: 2),
    Text(label, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
  ]);

  Widget _buildDivider() =>
      Container(width: 1, height: 32, color: BrokaColors.border);

  Widget _buildSectionLabel(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(label.toUpperCase(),
        style: const TextStyle(color: BrokaColors.textLow,
            fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
  );

  Widget _buildInfoTile(IconData icon, String label, String value) =>
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(children: [
          Icon(icon, color: BrokaColors.neonPurple, size: 18),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(
                  color: BrokaColors.textLow, fontSize: 11)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 14,
                  fontWeight: FontWeight.w600)),
            ])),
        ]),
      );

  Widget _buildToggleTile({
    required IconData icon,
    required String label,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
          colors: BrokaColors.cardGradColors,
          begin: Alignment.topLeft, end: Alignment.bottomRight),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Row(children: [
      Icon(icon, color: BrokaColors.neonPurple, size: 18),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 14,
              fontWeight: FontWeight.w600)),
          if (subtitle != null)
            Text(subtitle, style: const TextStyle(
                color: BrokaColors.textLow, fontSize: 11)),
        ])),
      Switch(
        value: value, onChanged: onChanged,
        activeColor: BrokaColors.neonPurple,
        trackColor: MaterialStateProperty.resolveWith((s) =>
          s.contains(MaterialState.selected)
              ? BrokaColors.neonPurple.withOpacity(0.3)
              : BrokaColors.border),
        thumbColor: MaterialStateProperty.resolveWith((s) =>
          s.contains(MaterialState.selected)
              ? BrokaColors.neonPurple : BrokaColors.textLow),
      ),
    ]),
  );


  Widget _buildLanguagePicker() {
    const langs = [
      ('english', 'English',   '🇬🇧'),
      ('swahili', 'Kiswahili', '🇰🇪'),
      ('luo',     'Dholuo',    '🟡'),
      ('kikuyu',  'Kikuyu',    '🟤'),
      ('luganda', 'Luganda',   '🇺🇬'),
      ('sheng',   'Sheng',     '🔥'),
    ];
    final current = ApiService.currentUserLanguage;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: BrokaColors.cardGradColors,
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.language_rounded, color: BrokaColors.neonPurple, size: 18),
          const SizedBox(width: 12),
          const Text('Language', style: TextStyle(
              color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text('AI + Voice', style: TextStyle(
              color: BrokaColors.textLow, fontSize: 11)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (key, name, flag) in langs)
            GestureDetector(
              onTap: () async {
                await ApiService.setLanguage(key);
                if (mounted) setState(() {});
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: current == key
                      ? BrokaColors.neonPurple.withOpacity(0.2)
                      : BrokaColors.bgCard,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: current == key
                        ? BrokaColors.neonPurple
                        : BrokaColors.border,
                    width: current == key ? 1.5 : 1,
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(flag, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 5),
                  Text(name, style: TextStyle(
                      fontSize: 12,
                      fontWeight: current == key
                          ? FontWeight.w700 : FontWeight.w500,
                      color: current == key
                          ? Colors.white : BrokaColors.textMid)),
                ]),
              ),
            ),
        ]),
      ]),
    );
  }

  Widget _buildNavTile(IconData icon, String label, VoidCallback onTap) =>
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BrokaColors.border),
        ),
        child: ListTile(
          onTap: onTap,
          leading: Icon(icon, color: BrokaColors.neonPurple, size: 18),
          title: Text(label, style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 14,
              fontWeight: FontWeight.w600)),
          trailing: const Icon(Icons.chevron_right_rounded,
              color: BrokaColors.textLow, size: 20),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
      );

  Widget _buildSignOutButton() => GradientButton(
    colors: const [BrokaColors.danger, Color(0xFF8B0000)],
    onPressed: _confirmSignOut,
    child: const Text('Sign Out', style: TextStyle(
        fontWeight: FontWeight.w700, fontSize: 15, color: Colors.white)),
  );

  void _showComingSoon(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$feature coming soon!'),
      backgroundColor: BrokaColors.bgCard,
    ));
  }

  void _confirmSignOut() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Sign Out?', style: TextStyle(
            color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        content: const Text('You will need to log in again.',
            style: TextStyle(color: BrokaColors.textMid)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel',
                style: TextStyle(color: BrokaColors.textMid)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await ApiService.clearSession();
              if (mounted) {
                Navigator.pushNamedAndRemoveUntil(
                    context, '/auth', (_) => false);
              }
            },
            child: const Text('Sign Out',
                style: TextStyle(color: BrokaColors.danger,
                    fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}
