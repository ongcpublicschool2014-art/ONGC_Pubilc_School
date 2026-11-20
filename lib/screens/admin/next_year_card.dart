import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';

/// Year End Process, when the next academic year is not registered yet:
/// create it here with an activation code from the office, the same way the
/// institution was registered. Server side: create_next_year_secure
/// (school_next_year.sql). [currentYear] is the session's year, e.g.
/// 2026-2027; [onCreated] reloads Year End, which then offers the new year.
class NextYearCard extends StatefulWidget {
  final String currentYear;
  final VoidCallback onCreated;
  const NextYearCard({super.key, required this.currentYear, required this.onCreated});

  @override
  State<NextYearCard> createState() => _NextYearCardState();
}

class _NextYearCardState extends State<NextYearCard> {
  final _code = TextEditingController();
  late String _next;
  late DateTime _start, _end;
  bool _requesting = false, _creating = false, _requested = false;
  String? _error;
  // set from the card's width in build(): fields stack, the button drops under
  // its text and the decoration hides on a narrow window
  bool _narrow = false, _compact = false;

  @override
  void initState() {
    super.initState();
    final p = widget.currentYear.split('-');
    final y1 = int.tryParse(p.isNotEmpty ? p[0] : '') ?? DateTime.now().year;
    final y2 = int.tryParse(p.length > 1 ? p[1] : '') ?? y1 + 1;
    _next = '${y1 + 1}-${y2 + 1}';
    // the school year runs June to May, as the current one does
    _start = DateTime(y1 + 1, 6, 1);
    _end = DateTime(y2 + 1, 5, 31);
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  static String _dmy(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
  static String _ymd(DateTime d) => d.toIso8601String().split('T').first;

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  Future<void> _pick(bool start) async {
    final cur = start ? _start : _end;
    final d = await showDatePicker(
      context: context,
      initialDate: cur,
      firstDate: DateTime(cur.year - 1),
      lastDate: DateTime(cur.year + 2),
    );
    if (d == null || !mounted) return;
    setState(() {
      if (start) {
        _start = d;
      } else {
        _end = d;
      }
    });
  }

  /// Ask the office for a code: the same Edge Function the registration form
  /// uses; it stores a new code and emails it to the office to forward.
  Future<void> _request() async {
    final auth = context.read<AuthProvider>();
    setState(() {
      _requesting = true;
      _error = null;
    });
    try {
      await SupabaseService.client.functions.invoke('request-activation-code', body: {
        'purpose': 'newyear',
        'insName': '${auth.insName ?? ''} - new academic year $_next',
        'inscode': auth.inscode ?? '',
        'contact': auth.userName ?? '',
        'mobile': '',
        'email': auth.userEmail ?? '',
      });
      if (!mounted) return;
      setState(() => _requested = true);
      _snack('Request sent. The office will email you the activation code for $_next.', AppColors.success);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not send the request. ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Future<void> _create() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the activation code the office sent you.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Create $_next?'),
        content: Text('The academic year $_next (${_dmy(_start)} to ${_dmy(_end)}) is created with this activation code. '
            'The code is used up. Then run Year End Process to move the students, fees and balances into it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create Year')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      await SupabaseService.client.rpc('create_next_year_secure', params: {
        'p_token': SupabaseService.sessionToken,
        'p_license_key': code,
        'p_yrlabel': _next,
        'p_start': _ymd(_start),
        'p_end': _ymd(_end),
      });
      _snack('Academic year $_next created. You can now run Year End Process.', AppColors.success);
      widget.onCreated();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Widget _dateBox(String label, DateTime d, bool start) => _cell(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AppUI.fieldLabel(label, required: true),
          InkWell(
            onTap: _creating ? null : () => _pick(start),
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            child: InputDecorator(
              decoration: AppUI.field(context, '', leadingIcon: 'calendar-1'),
              child: Text(_dmy(d), style: AppUI.fieldText(context)),
            ),
          ),
        ]),
      );

  /// A field in the year row: shares the row on a wide card, full width when stacked.
  Widget _cell(Widget child) => _narrow ? child : Expanded(child: child);

  // ── pieces of the card ────────────────────────────────────────────────

  /// A numbered section on a soft cream panel (the mockup's 1 / 2 blocks).
  Widget _section(String n, String title, String sub, Widget child) => Container(
        padding: _compact ? const EdgeInsets.fromLTRB(12, 14, 12, 14) : EdgeInsets.fromLTRB(20.w, 18.h, 20.w, 20.h),
        decoration: BoxDecoration(
          color: AppColors.goldTint.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(AppUI.cardRadius),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: _compact ? 34 : 46,
            height: _compact ? 34 : 46,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: AppColors.goldSoft, shape: BoxShape.circle),
            child: Text(n, style: AppFonts.body(size: _compact ? 17 : 22, weight: FontWeight.w800, color: AppColors.goldInk)),
          ),
          SizedBox(width: _compact ? 10 : 16.w),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppUI.label.copyWith(fontSize: 16.sp, fontWeight: FontWeight.w700)),
              SizedBox(height: 2.h),
              Text(sub, style: AppUI.muted),
              SizedBox(height: 14.h),
              child,
            ]),
          ),
        ]),
      );

  /// One sub-step of section 2: a round icon on a dotted rail, a numbered
  /// title and a line of help, with [trailing] on the right or [below] under it.
  Widget _subStep({required IconData icon, required String n, required String title, required String text,
      Widget? trailing, Widget? below, bool rail = false}) {
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: _compact ? 38 : 52,
          child: Column(children: [
            Container(
              width: _compact ? 36 : 50,
              height: _compact ? 36 : 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.10), shape: BoxShape.circle),
              child: Icon(icon, size: _compact ? 18 : 22, color: AppColors.primary),
            ),
            if (rail)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: CustomPaint(painter: _DotRail(AppColors.primary.withValues(alpha: 0.30))),
                ),
              ),
          ]),
        ),
        SizedBox(width: _compact ? 10 : 14.w),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: rail ? 14.h : 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text.rich(TextSpan(children: [
                      TextSpan(text: '$n.  ', style: AppUI.label.copyWith(color: AppColors.textLight)),
                      TextSpan(text: title, style: AppUI.label.copyWith(fontWeight: FontWeight.w700)),
                    ])),
                    SizedBox(height: 2.h),
                    Text(text, style: AppUI.muted),
                  ]),
                ),
                if (trailing != null && !_narrow) ...[SizedBox(width: 12.w), trailing],
              ]),
              if (trailing != null && _narrow) ...[SizedBox(height: 10.h), trailing],
              if (below != null) ...[SizedBox(height: 10.h), below],
            ]),
          ),
        ),
      ]),
    );
  }

  /// The small decoration top-right: a tilted card with a graduation cap.
  Widget _illustration() => SizedBox(
        width: 190,
        height: 120,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(right: 0, top: -8, child: _blob(78, 118, AppColors.primary.withValues(alpha: 0.10))),
          Positioned(left: 8, top: 10, child: _dot(9, AppColors.gold.withValues(alpha: 0.55))),
          Positioned(left: 32, top: 34, child: _dot(6, AppColors.primary.withValues(alpha: 0.25))),
          Positioned(left: 16, top: 64, child: _dot(14, AppColors.primary.withValues(alpha: 0.18))),
          Positioned(right: 4, bottom: 4, child: _dot(7, AppColors.primary.withValues(alpha: 0.18))),
          Positioned(
            right: 34,
            top: 8,
            child: Transform.rotate(
              angle: -0.17,
              child: Container(
                width: 96,
                height: 104,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 14, offset: const Offset(0, 6))],
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.school_rounded, size: 34, color: AppColors.primary),
                  ),
                  const SizedBox(height: 8),
                  Container(height: 4, width: 60, decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 5),
                  Container(height: 4, width: 44, decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(2))),
                ]),
              ),
            ),
          ),
        ]),
      );

  static Widget _dot(double d, Color c) => Container(width: d, height: d, decoration: BoxDecoration(color: c, shape: BoxShape.circle));
  static Widget _blob(double w, double h, Color c) =>
      Container(width: w, height: h, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(w)));

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final w = math.min(box.maxWidth, 1180.0);
        _narrow = w < 820; // the three year fields and the request button no longer fit a row
        _compact = w < 560; // phone-sized
        return _card(showArt: w >= 980);
      });

  Widget _card({required bool showArt}) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(vertical: 8.h),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Container(
            padding: _compact ? const EdgeInsets.all(16) : EdgeInsets.fromLTRB(28.w, 26.h, 28.w, 26.h),
            decoration: AppUI.card(),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // header
              Row(children: [
                Container(
                  width: _compact ? 56 : 92,
                  height: _compact ? 56 : 92,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.10), shape: BoxShape.circle),
                  child: AppIcon('calendar-add', size: _compact ? 26 : 40, color: AppColors.primary),
                ),
                SizedBox(width: _compact ? 12 : 22.w),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Create the Next Academic Year', style: AppFonts.body(size: _compact ? 21 : 28.sp, weight: FontWeight.w700).copyWith(height: 1.15)),
                    SizedBox(height: 6.h),
                    Text(
                      'Year End moves ${widget.currentYear} into the next year, so create $_next first.${_narrow ? ' ' : '\n'}'
                      'Like registering the institution, it needs an activation code from the office.',
                      style: AppUI.muted.copyWith(fontSize: 15.sp, height: 1.45),
                    ),
                  ]),
                ),
                if (showArt) _illustration(),
              ]),
              SizedBox(height: 18.h),

              // 1. the year
              _section(
                '1',
                'Set academic year details',
                'Enter the new academic year and date range.',
                Flex(
                  direction: _narrow ? Axis.vertical : Axis.horizontal,
                  // side by side the boxes line up at the bottom, whatever their labels
                  crossAxisAlignment: _narrow ? CrossAxisAlignment.stretch : CrossAxisAlignment.end,
                  children: [
                    _cell(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      AppUI.fieldLabel('New Year'),
                      InputDecorator(
                        decoration: AppUI.field(context, '', leadingIcon: 'calendar-tick'),
                        child: Text(_next, style: AppUI.fieldText(context)),
                      ),
                    ])),
                    _narrow ? SizedBox(height: 12.h) : SizedBox(width: 20.w),
                    _dateBox('Start Date', _start, true),
                    _narrow ? SizedBox(height: 12.h) : SizedBox(width: 20.w),
                    _dateBox('End Date', _end, false),
                  ],
                ),
              ),
              SizedBox(height: 16.h),

              // 2. the code
              _section(
                '2',
                'Get activation code and create',
                'Request the activation code from the office, then enter it below to create the year.',
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _subStep(
                    icon: Icons.send_rounded,
                    n: '1',
                    title: 'Get an activation code',
                    text: _requested
                        ? 'Requested. The office will email the code; it can take a little while.'
                        : 'The office will email you a code for $_next.',
                    rail: true,
                    trailing: OutlinedButton.icon(
                      onPressed: _requesting || _creating ? null : _request,
                      icon: _requesting
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send_rounded, size: 16),
                      label: Text(_requested ? 'Request Again' : 'Request Activation Code'),
                    ),
                  ),
                  _subStep(
                    icon: Icons.key_rounded,
                    n: '2',
                    title: 'Enter the code and create the year',
                    text: 'The code is used up once the year is created.',
                    below: TextField(
                      controller: _code,
                      enabled: !_creating,
                      textCapitalization: TextCapitalization.characters,
                      onChanged: (_) => setState(() => _error = null),
                      onSubmitted: (_) => _create(),
                      style: AppUI.fieldText(context).copyWith(letterSpacing: 1),
                      decoration: AppUI.field(context, 'Activation Code (EDU-XXXXXX-XXXXXX)', leadingIcon: 'key'),
                    ),
                  ),
                ]),
              ),

              if (_error != null) ...[
                SizedBox(height: 12.h),
                Container(
                  padding: EdgeInsets.all(12.w),
                  decoration: BoxDecoration(
                    color: AppColors.errorBg,
                    borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.error_outline, size: 18, color: AppColors.error),
                    SizedBox(width: 8.w),
                    Expanded(child: Text(_error!, style: AppUI.body.copyWith(color: AppColors.error))),
                  ]),
                ),
              ],
              SizedBox(height: 18.h),
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: _compact ? double.infinity : null,
                  height: AppUI.controlHeight(context) + 6,
                  child: ElevatedButton.icon(
                    onPressed: _creating ? null : _create,
                    style: AppUI.primary(context),
                    icon: _creating
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.add_circle_outline, size: 18),
                    label: Text('Create $_next'),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The dotted line linking the two sub-steps.
class _DotRail extends CustomPainter {
  final Color color;
  const _DotRail(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    final x = size.width / 2;
    for (var y = 0.0; y < size.height; y += 6) {
      canvas.drawLine(Offset(x, y), Offset(x, (y + 3).clamp(0, size.height)), paint);
    }
  }

  @override
  bool shouldRepaint(_DotRail old) => old.color != color;
}
