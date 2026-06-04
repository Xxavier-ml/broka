import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../main.dart';
import '../services/api_service.dart';

class SellScreen extends StatefulWidget {
  const SellScreen({super.key});
  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  final _formKey      = GlobalKey<FormState>();
  final _nameCtrl     = TextEditingController();
  final _priceCtrl    = TextEditingController();
  final _locCtrl      = TextEditingController();
  final _descCtrl     = TextEditingController();
  final _reserveCtrl  = TextEditingController();
  String _category    = 'Vehicles';
  String _type        = 'direct';
  bool _loading       = false;
  String? _error;

  // Media
  final List<File> _verifiedPhotos = [];
  File? _verifiedVideo;
  File? _advertVideo;

  static const _categories = ['Vehicles', 'Property', 'Electronics', 'Livestock', 'General'];
  final _picker = ImagePicker();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    _locCtrl.dispose();
    _descCtrl.dispose();
    _reserveCtrl.dispose();
    super.dispose();
  }

  // ── Camera capture methods ────────────────────────────────────────────────

  Future<void> _takeCameraPhoto() async {
    if (_verifiedPhotos.length >= 6) {
      _showSnack('Maximum 6 photos allowed');
      return;
    }
    final xfile = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 75,
      maxWidth: 1080,
    );
    if (xfile != null && mounted) {
      setState(() => _verifiedPhotos.add(File(xfile.path)));
    }
  }

  Future<void> _takeCameraVideo() async {
    final xfile = await _picker.pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(minutes: 2),
    );
    if (xfile != null && mounted) {
      setState(() => _verifiedVideo = File(xfile.path));
    }
  }

  Future<void> _pickAdvertVideo() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: BrokaColors.bgCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Advert Video Source', style: TextStyle(
              color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 20),
          _sheetBtn(Icons.videocam_rounded, 'Record Now (Camera)',
              () async {
            Navigator.pop(context);
            final xfile = await _picker.pickVideo(
                source: ImageSource.camera,
                maxDuration: const Duration(minutes: 5));
            if (xfile != null && mounted) setState(() => _advertVideo = File(xfile.path));
          }),
          const SizedBox(height: 10),
          _sheetBtn(Icons.photo_library_outlined, 'Upload from Gallery (AI-generated OK)',
              () async {
            Navigator.pop(context);
            final xfile = await _picker.pickVideo(source: ImageSource.gallery);
            if (xfile != null && mounted) setState(() => _advertVideo = File(xfile.path));
          }),
        ]),
      ),
    );
  }

  Widget _sheetBtn(IconData icon, String label, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        decoration: BoxDecoration(
          color: BrokaColors.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(children: [
          Icon(icon, color: BrokaColors.neonPurple, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: TextStyle(
              color: BrokaColors.textHigh, fontSize: 13))),
        ]),
      ),
    );

  // ── Convert files to base64 ───────────────────────────────────────────────

  Future<String?> _fileToBase64(File f, {bool isVideo = false}) async {
    try {
      final bytes = await f.readAsBytes();
      if (isVideo && bytes.length > 15 * 1024 * 1024) {
        setState(() => _error =
            'Video is too large (max 15 MB). Please record a shorter clip.');
        return null;
      }
      return base64Encode(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    if (_verifiedPhotos.isEmpty) {
      setState(() => _error = 'Please take at least one verified photo (camera required).');
      return;
    }

    if (_verifiedVideo == null) {
      setState(() => _error = 'Please record the mandatory verification video.');
      return;
    }

    setState(() { _loading = true; _error = null; });

    try {
      final photoBase64List = <String>[];
      for (final f in _verifiedPhotos) {
        final b = await _fileToBase64(f);
        if (b != null) photoBase64List.add(b);
      }

      final verifiedVideoB64 = await _fileToBase64(_verifiedVideo!, isVideo: true);
      if (verifiedVideoB64 == null) {
        setState(() => _loading = false);
        return; // error already set inside _fileToBase64
      }

      String? advertVideoB64;
      if (_advertVideo != null) {
        advertVideoB64 = await _fileToBase64(_advertVideo!, isVideo: true);
        if (advertVideoB64 == null) {
          setState(() => _loading = false);
          return;
        }
      }

      await ApiService.createListing({
        'name':            _nameCtrl.text.trim(),
        'category':        _category,
        'price':           double.parse(_priceCtrl.text),
        'lat':             ApiService.currentUserLat ?? -1.286389,
        'lng':             ApiService.currentUserLng ?? 36.817223,
        'location_name':   _locCtrl.text.trim(),
        'listing_type':    _type,
        'description':     _descCtrl.text.trim(),
        'verified_photos': photoBase64List.join(','),
        'verified_video':  verifiedVideoB64,
        if (advertVideoB64 != null) 'advert_video': advertVideoB64,
        if (_type == 'auction' && _reserveCtrl.text.isNotEmpty)
          'reserve_price': double.parse(_reserveCtrl.text),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Listing created! Your verified listing is now live.')));
      Navigator.pop(context);
    } on TimeoutException {
      setState(() => _error =
          'Request timed out — your connection may be slow. Please try again.');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: BrokaColors.bgCard));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: BrokaColors.headerGradColors,
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: BrokaColors.bgCard,
                    border: Border.all(color: BrokaColors.border),
                  ),
                  child: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: BrokaColors.textMid, size: 16),
                ),
              ),
              const SizedBox(width: 12),
              const Text('NEW LISTING', style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w800,
                  color: BrokaColors.textHigh)),
            ]),
          ),

          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Form(key: _formKey, child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [

              // Info strip — futuristic
              Container(
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    BrokaColors.neonPurple.withOpacity(0.07),
                    BrokaColors.neonBlue.withOpacity(0.03),
                  ], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.2)),
                ),
                child: Row(children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [BrokaColors.gradStart, BrokaColors.gradMid]),
                      boxShadow: const [BrokaColors.glowPurple],
                    ),
                    child: const Icon(Icons.smart_toy_outlined,
                        color: Colors.white, size: 17),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('AI-POWERED LISTING', style: TextStyle(
                          color: BrokaColors.neonPurple, fontSize: 10,
                          fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                      SizedBox(height: 3),
                      Text('BROKA AI will match you with vetted buyers. 3% commission — fully transparent.',
                          style: TextStyle(color: BrokaColors.textMid,
                              fontSize: 11, height: 1.4)),
                    ],
                  )),
                ]),
              ),

              // ── Verified Photos ───────────────────────────────────────────
              _label('VERIFIED PHOTOS  (camera only — required)'),
              const SizedBox(height: 6),
              _fraudNote('📷 Photos must be taken directly from your camera. '
                  'This prevents fake/AI-generated images and builds buyer trust.'),
              const SizedBox(height: 10),
              _buildPhotoRow(),
              const SizedBox(height: 20),

              // ── Verification Video ────────────────────────────────────────
              _label('VERIFICATION VIDEO  (camera only — required)'),
              const SizedBox(height: 6),
              _fraudNote('🎥 This video proves the item is real and in your possession. '
                  'Must be recorded live — no uploads from gallery allowed. Max 15 MB.'),
              const SizedBox(height: 10),
              _buildVerificationVideoRow(),
              const SizedBox(height: 20),

              // ── Advert Video ──────────────────────────────────────────────
              _label('ADVERT VIDEO  (optional — AI-generated OK)'),
              const SizedBox(height: 6),
              _fraudNote('📣 This is your promotional video shown in the discovery feed. '
                  'You can record it or upload from gallery. AI-generated is fine here. Max 15 MB.'),
              const SizedBox(height: 10),
              _buildAdvertVideoRow(),
              const SizedBox(height: 24),

              // ── Listing type ──────────────────────────────────────────────
              _label('LISTING TYPE'),
              const SizedBox(height: 10),
              Row(children: [
                _typeBtn('direct',  Icons.handshake_outlined, 'Direct Sale'),
                const SizedBox(width: 10),
                _typeBtn('auction', Icons.gavel_rounded, 'Auction'),
              ]),
              const SizedBox(height: 20),

              _label('PRODUCT NAME'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _nameCtrl,
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: const InputDecoration(
                    hintText: 'e.g. Toyota Land Cruiser 2018'),
                validator: (v) =>
                    v!.trim().length < 3 ? 'Min 3 characters' : null,
              ),
              const SizedBox(height: 16),

              _label('CATEGORY'),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _category,
                dropdownColor: BrokaColors.bgCard,
                style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 13),
                decoration: const InputDecoration(),
                items: _categories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setState(() => _category = v!),
              ),
              const SizedBox(height: 16),

              _label('ASKING PRICE (KES)'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _priceCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(
                    color: BrokaColors.neonPurple,
                    fontWeight: FontWeight.w800),
                decoration: const InputDecoration(hintText: 'e.g. 2500000'),
                validator: (v) {
                  final n = double.tryParse(v ?? '');
                  return n == null || n <= 0 ? 'Enter a valid price' : null;
                },
              ),
              const SizedBox(height: 16),

              _label('LOCATION'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _locCtrl,
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: const InputDecoration(
                    hintText: 'e.g. Westlands, Nairobi'),
                validator: (v) =>
                    v!.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),

              _label('DESCRIPTION  (optional)'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _descCtrl,
                maxLines: 3,
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: const InputDecoration(
                    hintText: 'Condition, features, reason for selling...'),
              ),

              if (_type == 'auction') ...[
                const SizedBox(height: 16),
                _label('RESERVE PRICE (KES)  optional'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _reserveCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: BrokaColors.textHigh),
                  decoration: const InputDecoration(
                      hintText: 'Minimum acceptable bid'),
                ),
              ],

              const SizedBox(height: 28),

              if (_error != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: BrokaColors.danger.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: BrokaColors.danger.withOpacity(0.3)),
                  ),
                  child: Text(_error!,
                      style: const TextStyle(
                          color: BrokaColors.danger, fontSize: 12)),
                ),

              GradientButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('ACTIVATE LISTING',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
              ),

              const SizedBox(height: 20),
            ])),
          )),
        ])),
      ),
    );
  }

  // ── Media Widgets ─────────────────────────────────────────────────────────

  Widget _buildPhotoRow() => Column(children: [
    if (_verifiedPhotos.isNotEmpty) ...[
      SizedBox(
        height: 90,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: _verifiedPhotos.length,
          itemBuilder: (_, i) => Stack(
            children: [
              Container(
                margin: const EdgeInsets.only(right: 8),
                width: 90, height: 90,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.5)),
                  image: DecorationImage(
                    image: FileImage(_verifiedPhotos[i]),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              Positioned(top: 4, right: 12,
                child: GestureDetector(
                  onTap: () => setState(() => _verifiedPhotos.removeAt(i)),
                  child: Container(
                    width: 20, height: 20,
                    decoration: const BoxDecoration(
                      color: BrokaColors.danger,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, size: 12, color: Colors.white),
                  ),
                )),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
    ],
    _mediaButton(
      icon: Icons.camera_alt_rounded,
      label: 'Take Photo with Camera',
      sublabel: 'Gallery not allowed — camera only',
      color: BrokaColors.neonPurple,
      onTap: _takeCameraPhoto,
    ),
  ]);

  Widget _buildVerificationVideoRow() => Column(children: [
    if (_verifiedVideo != null) ...[
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: BrokaColors.success.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BrokaColors.success.withOpacity(0.4)),
        ),
        child: Row(children: [
          const Icon(Icons.check_circle_rounded, color: BrokaColors.success, size: 18),
          const SizedBox(width: 8),
          const Expanded(child: Text('Verification video recorded ✓',
              style: TextStyle(color: BrokaColors.success, fontSize: 12))),
          GestureDetector(
            onTap: () => setState(() => _verifiedVideo = null),
            child: const Icon(Icons.close, color: BrokaColors.textMid, size: 16),
          ),
        ]),
      ),
      const SizedBox(height: 8),
    ],
    _mediaButton(
      icon: Icons.videocam_rounded,
      label: _verifiedVideo == null ? 'Record Verification Video' : 'Re-record Video',
      sublabel: 'Must be recorded live — no gallery upload',
      color: BrokaColors.neonBlue,
      onTap: _takeCameraVideo,
    ),
  ]);

  Widget _buildAdvertVideoRow() => Column(children: [
    if (_advertVideo != null) ...[
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: BrokaColors.warning.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BrokaColors.warning.withOpacity(0.4)),
        ),
        child: Row(children: [
          const Icon(Icons.movie_outlined, color: BrokaColors.warning, size: 18),
          const SizedBox(width: 8),
          const Expanded(child: Text('Advert video added ✓',
              style: TextStyle(color: BrokaColors.warning, fontSize: 12))),
          GestureDetector(
            onTap: () => setState(() => _advertVideo = null),
            child: const Icon(Icons.close, color: BrokaColors.textMid, size: 16),
          ),
        ]),
      ),
      const SizedBox(height: 8),
    ],
    _mediaButton(
      icon: Icons.add_box_outlined,
      label: _advertVideo == null ? 'Add Advert Video  (optional)' : 'Change Advert Video',
      sublabel: 'Camera or gallery — AI-generated OK',
      color: BrokaColors.warning,
      onTap: _pickAdvertVideo,
    ),
  ]);

  Widget _mediaButton({
    required IconData icon,
    required String label,
    required String sublabel,
    required Color color,
    required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: color,
              fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 2),
          Text(sublabel, style: const TextStyle(
              color: BrokaColors.textLow, fontSize: 10)),
        ])),
        Icon(Icons.arrow_forward_ios_rounded, color: color.withOpacity(0.5), size: 14),
      ]),
    ),
  );

  Widget _fraudNote(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Text(text, style: const TextStyle(
        color: BrokaColors.textLow, fontSize: 11, height: 1.4)),
  );

  Widget _typeBtn(String type, IconData icon, String label) {
    final active = _type == type;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _type = type),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            gradient: active
                ? const LinearGradient(
                    colors: [Color(0xFF2A1560), Color(0xFF150A35)])
                : null,
            color: active ? null : BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? BrokaColors.neonPurple : BrokaColors.border,
              width: active ? 1.5 : 1,
            ),
            boxShadow: active ? [BrokaColors.glowPurple] : null,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 22,
                color: active ? BrokaColors.neonPurple : BrokaColors.textMid),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: active ? BrokaColors.neonPurple : BrokaColors.textMid)),
          ]),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(
          color: BrokaColors.textLow,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2));
}
