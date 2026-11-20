import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../utils/app_theme.dart';
import '../../utils/tc_fields.dart';
import '../../utils/tc_pdf.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_dropdown_field.dart';

/// Values used by "Test print" so the placed fields can be checked on paper.
const Map<String, String> kTcPdfSamples = {
  'School Name': 'ONGC PUBLIC SCHOOL',
  'Student Name': 'ARUN KUMAR S',
  'Father Name': 'SURESH KUMAR R',
  'Mother Name': 'LATHA S',
  'Admission No': 'ADM00012',
  'TC No': 'TC0001',
  'DOB': '05-06-2015',
  'DOB in Words': 'Fifth June Two Thousand Fifteen',
  'Nationality': 'INDIAN',
  'Copy': 'ORIGINAL',
  'Standard': 'V',
  'Standard in Words': 'Fifth',
};

/// PDF format (TC, fee receipt): place each field on the page. Click the page
/// to set a marker, pick a field and Add; drag a box to move it, drag its
/// right edge to change the width, arrow keys nudge (Shift = 5 pt), Delete
/// removes. [keys]/[samples] default to the TC's; [listKey] is the field that
/// prints as a list (the receipt's fee lines), [bookName] names the stationery.
class TcPdfDesigner extends StatefulWidget {
  final Uint8List pdf;
  final TcPdfLayout layout;
  final Future<bool> Function(TcPdfLayout layout) onSave;
  final Future<void> Function(TcPdfLayout layout) onTest;
  final List<String>? keys;
  final Map<String, String>? samples;
  final String? listKey;
  final String bookName;

  const TcPdfDesigner({
    super.key,
    required this.pdf,
    required this.layout,
    required this.onSave,
    required this.onTest,
    this.keys,
    this.samples,
    this.listKey,
    this.bookName = 'TC books',
  });

  @override
  State<TcPdfDesigner> createState() => _TcPdfDesignerState();
}

class _TcPdfDesignerState extends State<TcPdfDesigner> {
  static const _custom = '__custom__';

  late TcPdfLayout _layout;
  List<TcPdfPage>? _pages;
  String? _err;
  int _page = 0;
  int? _sel;
  Offset? _marker; // in PDF points, on _page
  bool _dirty = false, _saving = false, _testing = false;
  String? _addKey;
  double _zoom = 1;
  int _gen = 0; // bumped when a position changes outside the number boxes
  final _customCtl = TextEditingController();
  final _focus = FocusNode(debugLabel: 'tc-pdf-page');
  final _vCtl = ScrollController(), _hCtl = ScrollController();

  @override
  void initState() {
    super.initState();
    _layout = TcPdfLayout.fromJson(widget.layout.toJson());
    TcPdf.pages(widget.pdf).then((p) {
      if (mounted) setState(() => _pages = p);
    }).catchError((Object _) {
      if (mounted) setState(() => _err = 'The PDF could not be opened. It may be damaged or password-protected; upload it again in TC Format.');
    });
  }

  @override
  void dispose() {
    _customCtl.dispose();
    _focus.dispose();
    _vCtl.dispose();
    _hCtl.dispose();
    super.dispose();
  }

  List<String> get _allKeys => widget.keys ?? [for (final f in kTcFields) f.key, ...kTcPrintTimeKeys];
  Map<String, String> get _samples => widget.samples ?? kTcPdfSamples;

  /// Rows the designer shows for a list block.
  List<String> _listRows(TcPdfField f) {
    final r = (_samples[f.key] ?? '').split('\n').where((l) => l.trim().isNotEmpty).toList();
    return r.isEmpty ? [f.key] : r;
  }

  double _boxH(TcPdfField f) => f.isList ? f.rowH * _listRows(f).length : f.size * 1.35;

  TcPdfField? get _selField => _sel == null || _sel! >= _layout.fields.length ? null : _layout.fields[_sel!];

  void _change(VoidCallback fn, {bool moved = false}) {
    setState(() {
      fn();
      _dirty = true;
      if (moved) _gen++;
    });
  }

  void _add() {
    final key = _addKey == _custom ? _customCtl.text.trim().replaceAll(RegExp(r'[{}]'), '') : (_addKey ?? '');
    if (key.isEmpty) return;
    final p = _pages![_page];
    final at = _marker ?? Offset(40, 40 + 18.0 * _layout.fields.where((f) => f.page == _page).length);
    final w = (p.wPt - at.dx - 20).clamp(40.0, 260.0);
    _change(() {
      _layout.fields.add(key == widget.listKey
          ? TcPdfField(key: key, page: _page, x: at.dx, y: at.dy, w: (p.wPt - at.dx - 20).clamp(80.0, 400.0), size: 10, rowH: 16, amtW: 80)
          : TcPdfField(key: key, page: _page, x: at.dx, y: at.dy, w: w));
      _sel = _layout.fields.length - 1;
      _marker = null;
    }, moved: true);
    _focus.requestFocus();
  }

  void _goPage(int i) => setState(() {
        _page = i;
        _sel = null;
        _marker = null;
      });

  void _remove() {
    if (_sel == null) return;
    _change(() {
      _layout.fields.removeAt(_sel!);
      _sel = null;
    }, moved: true);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    final f = _selField;
    if (f == null || e is KeyUpEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.delete) {
      _remove();
      return KeyEventResult.handled;
    }
    final step = HardwareKeyboard.instance.isShiftPressed ? 5.0 : 1.0;
    final d = switch (e.logicalKey) {
      LogicalKeyboardKey.arrowLeft => Offset(-step, 0),
      LogicalKeyboardKey.arrowRight => Offset(step, 0),
      LogicalKeyboardKey.arrowUp => Offset(0, -step),
      LogicalKeyboardKey.arrowDown => Offset(0, step),
      _ => null,
    };
    if (d == null) return KeyEventResult.ignored;
    _change(() {
      f.x += d.dx;
      f.y += d.dy;
    }, moved: true);
    return KeyEventResult.handled;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final ok = await widget.onSave(_layout);
      if (ok && mounted) setState(() => _dirty = false);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    try {
      await widget.onTest(_layout);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_err != null) {
      return AppUI.empty(title: 'This PDF could not be shown', why: _err, icon: 'document-text');
    }
    if (_pages == null) {
      return const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()));
    }
    final h = (MediaQuery.of(context).size.height - 220).clamp(520.0, 1400.0);
    return SizedBox(
      height: h,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: _preview()),
        SizedBox(width: 16.w),
        SizedBox(width: 340, child: _panel()),
      ]),
    );
  }

  // ── the page ──────────────────────────────────────────────────────────
  Widget _preview() {
    final p = _pages![_page];
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.cardBorder),
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(children: [
            if (_pages!.length > 1) ...[
              IconButton(
                tooltip: 'Previous page',
                onPressed: _page == 0 ? null : () => _goPage(_page - 1),
                icon: const Icon(Icons.chevron_left),
              ),
              Text('Page ${_page + 1} of ${_pages!.length}', style: AppUI.label),
              IconButton(
                tooltip: 'Next page',
                onPressed: _page >= _pages!.length - 1 ? null : () => _goPage(_page + 1),
                icon: const Icon(Icons.chevron_right),
              ),
            ] else
              Text('${p.wPt.round()} x ${p.hPt.round()} pt', style: AppUI.muted),
            const Spacer(),
            for (final z in const [1.0, 1.5, 2.0])
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: ChoiceChip(
                  label: Text(z == 1 ? 'Fit' : '${(z * 100).round()}%'),
                  selected: _zoom == z,
                  onSelected: (_) => setState(() => _zoom = z),
                ),
              ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final s = (c.maxWidth - 32) / p.wPt * _zoom;
            return Scrollbar(
              controller: _vCtl,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _vCtl,
                child: Scrollbar(
                  controller: _hCtl,
                  thumbVisibility: _zoom > 1,
                  notificationPredicate: (n) => n.depth == 0,
                  child: SingleChildScrollView(
                    controller: _hCtl,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(16),
                    child: Focus(focusNode: _focus, onKeyEvent: _onKey, child: _pageView(p, s)),
                  ),
                ),
              ),
            );
          }),
        ),
      ]),
    );
  }

  Widget _pageView(TcPdfPage p, double s) {
    final sel = _selField;
    return Container(
      width: p.wPt * s,
      height: p.hPt * s,
      decoration: BoxDecoration(color: Colors.white, boxShadow: [
        BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 10, offset: const Offset(0, 2)),
      ]),
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              setState(() {
                _marker = d.localPosition / s;
                _sel = null;
              });
              _focus.requestFocus();
            },
            child: Image.memory(p.png, fit: BoxFit.fill, gaplessPlayback: true),
          ),
        ),
        if (_marker != null)
          Positioned(
            left: _marker!.dx * s - 9,
            top: _marker!.dy * s - 9,
            child: const IgnorePointer(child: Icon(Icons.add_circle_outline, size: 18, color: AppColors.error)),
          ),
        for (var i = 0; i < _layout.fields.length; i++)
          if (_layout.fields[i].page == _page) _box(i, s),
        if (sel != null && sel.page == _page)
          Positioned(
            left: (sel.x + sel.w) * s - 5,
            top: sel.y * s,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
                onPanUpdate: (d) => _change(() => sel.w = (sel.w + d.delta.dx / s).clamp(20.0, p.wPt), moved: true),
                child: Container(
                  width: 10,
                  height: (_boxH(sel) * s).clamp(12.0, 2000.0),
                  decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(3)),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _box(int i, double s) {
    final f = _layout.fields[i];
    final on = _sel == i;
    final p = _pages![_page];
    return Positioned(
      left: f.x * s,
      top: f.y * s,
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          onTap: () {
            setState(() => _sel = i);
            _focus.requestFocus();
          },
          onPanStart: (_) {
            setState(() => _sel = i);
            _focus.requestFocus();
          },
          onPanUpdate: (d) => _change(() {
            f.x = (f.x + d.delta.dx / s).clamp(0.0, p.wPt - 10);
            f.y = (f.y + d.delta.dy / s).clamp(0.0, p.hPt - 6);
          }, moved: true),
          child: Tooltip(
            message: '{${f.key}}',
            waitDuration: const Duration(milliseconds: 600),
            child: Container(
              width: f.w * s,
              height: f.isList ? _boxH(f) * s : null,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: on ? 0.16 : 0.07),
                border: Border.all(color: AppColors.primary.withValues(alpha: on ? 1 : 0.45), width: on ? 1.5 : 1),
              ),
              // A long value shrinks to the box width, as it prints.
              child: f.isList ? _listPreview(f, s) : FittedBox(
                fit: BoxFit.scaleDown,
                alignment: f.align == 'center' ? Alignment.center : (f.align == 'right' ? Alignment.centerRight : Alignment.centerLeft),
                child: Text(
                  _samples[f.key] ?? f.key,
                  maxLines: 1,
                  textAlign: f.align == 'center' ? TextAlign.center : (f.align == 'right' ? TextAlign.right : TextAlign.left),
                  style: TextStyle(
                    fontSize: f.size * s,
                    height: 1.2,
                    fontWeight: f.bold ? FontWeight.w700 : FontWeight.w400,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _listPreview(TcPdfField f, double s) {
    final st = TextStyle(fontSize: f.size * s, height: 1.2, fontWeight: f.bold ? FontWeight.w700 : FontWeight.w400, color: AppColors.textPrimary);
    final amtW = f.amtW.clamp(0.0, f.w) * s;
    // the box's border takes a pixel or two: the rows are clipped, not overflowed
    return ClipRect(
        child: OverflowBox(
            alignment: Alignment.topLeft,
            maxHeight: double.infinity,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final l in _listRows(f))
        SizedBox(
          height: f.rowH * s,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(l.split('\t').first, maxLines: 1, overflow: TextOverflow.clip, style: st)),
            if (amtW > 0)
              SizedBox(
                width: amtW,
                child: Text(l.contains('\t') ? l.split('\t').last : '', maxLines: 1, textAlign: TextAlign.right, overflow: TextOverflow.clip, style: st),
              ),
          ]),
        ),
    ])));
  }

  // ── the side panel ────────────────────────────────────────────────────
  Widget _panel() {
    final f = _selField;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.cardBorder),
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.all(14), children: [
            AppUI.sectionLabel('Add a field'),
            Text(
              _marker == null
                  ? 'Click the page where the value should start, then choose the field and click Add Field.'
                  : 'Marker set. Choose the field, then click Add at Marker.',
              style: AppUI.muted,
            ),
            const SizedBox(height: 8),
            // TYPE TO FIND IT: the list runs to 70-odd fields, so a plain
            // dropdown meant scrolling for each one. Matches the field name
            // or its on-screen label ("Date of Birth" finds {DOB}).
            LayoutBuilder(
              builder: (context, box) => Autocomplete<String>(
                initialValue: TextEditingValue(text: _addKey == null || _addKey == _custom ? '' : '{$_addKey}'),
                displayStringForOption: (k) => k == _custom ? '' : '{$k}',
                optionsBuilder: (v) {
                  final q = v.text.trim().toLowerCase().replaceAll(RegExp(r'[{}]'), '');
                  final hits = _allKeys.where((k) => q.isEmpty || k.toLowerCase().contains(q) || tcFieldLabel(k).toLowerCase().contains(q));
                  return [...hits, if (widget.keys == null) _custom];
                },
                onSelected: (k) => setState(() => _addKey = k),
                fieldViewBuilder: (context, ctl, focus, onSubmit) => TextField(
                  controller: ctl,
                  focusNode: focus,
                  style: AppUI.fieldText(context),
                  decoration: AppUI.field(context, 'Search field, e.g. name, date of birth', leadingIcon: 'search-normal', dense: true),
                  // Typing over a chosen field un-chooses it until a new one is picked.
                  onChanged: (t) {
                    if (_addKey != null && _addKey != _custom && t != '{$_addKey}') setState(() => _addKey = null);
                  },
                  onSubmitted: (_) => onSubmit(),
                ),
                optionsViewBuilder: (context, onSelected, options) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 6,
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: 320, maxWidth: box.maxWidth),
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (context, i) {
                          final k = options.elementAt(i);
                          final label = tcFieldLabel(k);
                          return InkWell(
                            onTap: () => onSelected(k),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              child: k == _custom
                                  ? Text('Other field (type a name)...', style: AppUI.body.copyWith(color: AppColors.primary))
                                  : Row(children: [
                                      Expanded(child: Text('{$k}', style: AppUI.body, overflow: TextOverflow.ellipsis)),
                                      if (label != k) Text(label, style: AppUI.muted, overflow: TextOverflow.ellipsis),
                                    ]),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_addKey == _custom) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _customCtl,
                decoration: AppUI.field(context, 'Enter field name, e.g. Book No', dense: true),
                style: AppUI.fieldText(context),
                onSubmitted: (_) => _add(),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _addKey == null ? null : _add,
              icon: const Icon(Icons.add, size: 16),
              label: Text(_marker == null ? 'Add Field' : 'Add at Marker'),
            ),
            const SizedBox(height: 16),
            if (f != null) ...[
              AppUI.sectionLabel('Selected: {${f.key}}'),
              Row(children: [
                _num('Left (pt)', f.x, (v) => f.x = v),
                const SizedBox(width: 8),
                _num('Top (pt)', f.y, (v) => f.y = v),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                _num('Width (pt)', f.w, (v) => f.w = v.clamp(20, 2000)),
                const SizedBox(width: 8),
                _num('Font Size', f.size, (v) => f.size = v.clamp(5, 48)),
              ]),
              if (f.isList) ...[
                const SizedBox(height: 8),
                Row(children: [
                  _num('Line Gap (pt)', f.rowH, (v) => f.rowH = v.clamp(6, 100)),
                  const SizedBox(width: 8),
                  _num('Amount Width (pt)', f.amtW, (v) => f.amtW = v.clamp(0, f.w)),
                ]),
                const SizedBox(height: 6),
                Text('One line per fee. The amount prints right-aligned in the last part of the box (0 = no amount).', style: AppUI.muted),
              ],
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'left', icon: Icon(Icons.format_align_left, size: 16), tooltip: 'Align left'),
                      ButtonSegment(value: 'center', icon: Icon(Icons.format_align_center, size: 16), tooltip: 'Align centre'),
                      ButtonSegment(value: 'right', icon: Icon(Icons.format_align_right, size: 16), tooltip: 'Align right'),
                    ],
                    selected: {f.align},
                    onSelectionChanged: (v) => _change(() => f.align = v.first),
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Bold'),
                  selected: f.bold,
                  onSelected: (v) => _change(() => f.bold = v),
                ),
              ]),
              const SizedBox(height: 8),
              Text('Drag the box to move it, its blue right edge to resize. Arrow keys nudge (Shift = 5 pt).', style: AppUI.muted),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _remove,
                  style: TextButton.styleFrom(foregroundColor: AppColors.error),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Remove Field'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            AppUI.sectionLabel('Fields placed (${_layout.fields.length})'),
            if (_layout.fields.isEmpty)
              Text('No fields placed yet.', style: AppUI.muted)
            else
              for (var i = 0; i < _layout.fields.length; i++)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    setState(() {
                      _sel = i;
                      _page = _layout.fields[i].page.clamp(0, _pages!.length - 1);
                      _marker = null;
                    });
                    _focus.requestFocus();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    decoration: BoxDecoration(
                      color: _sel == i ? AppColors.primary.withValues(alpha: 0.08) : null,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children: [
                      Expanded(child: Text('{${_layout.fields[i].key}}', style: AppUI.body, overflow: TextOverflow.ellipsis)),
                      if (_pages!.length > 1) Text('Page ${_layout.fields[i].page + 1}', style: AppUI.muted),
                    ]),
                  ),
                ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _layout.background,
              onChanged: (v) => _change(() => _layout.background = v),
              title: Text('Print Form Background', style: AppUI.label),
              subtitle: Text('Turn off for ${widget.bookName} that already have the form printed -- only the values print.', style: AppUI.muted),
            ),
            const SizedBox(height: 8),
            AppUI.fieldLabel('Paper Size'),
            AppDropdownField<String>(
              initialValue: _layout.paper,
              isExpanded: true,
              decoration: AppUI.field(context, '', dense: true),
              style: AppUI.fieldText(context),
              items: [for (final e in kTcPapers.entries) DropdownMenuItem(value: e.key, child: Text(e.value.$1))],
              onChanged: (v) => _change(() => _layout.paper = v ?? 'FORMAT'),
            ),
            const SizedBox(height: 12),
            AppUI.sectionLabel('Printer Adjustment (mm)'),
            Row(children: [
              _mm('Move Right', _layout.offX, (v) => _layout.offX = v),
              const SizedBox(width: 8),
              _mm('Move Down', _layout.offY, (v) => _layout.offY = v),
            ]),
            const SizedBox(height: 6),
            Text('If every value prints a little off on the ${widget.bookName}, shift them all here: e.g. 3 = 3 mm right / down, '
                '-2 = 2 mm left / up. Field places on the page above stay as they are.', style: AppUI.muted),
          ]),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            if (_dirty) Expanded(child: AppUI.chip('Unsaved changes', AppStatus.warning)) else const Spacer(),
            OutlinedButton(
              onPressed: _testing || _layout.fields.isEmpty ? null : _test,
              child: _testing
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Test Print'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _saving || !_dirty ? null : _save,
              child: _saving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Save Layout'),
            ),
          ]),
        ),
      ]),
    );
  }

  /// A signed mm box (the printer adjustment), -50..50.
  Widget _mm(String label, double v, void Function(double) set) {
    final txt = v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppUI.fieldLabel(label),
        TextFormField(
          initialValue: txt,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?[0-9]*\.?[0-9]*'))],
          decoration: AppUI.field(context, '0', dense: true),
          style: AppUI.fieldText(context),
          onChanged: (t) {
            final d = t.trim().isEmpty || t.trim() == '-' ? 0.0 : double.tryParse(t);
            if (d != null) _change(() => set(d.clamp(-50, 50).toDouble()));
          },
        ),
      ]),
    );
  }

  Widget _num(String label, double v, void Function(double) set) {
    final txt = v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppUI.fieldLabel(label),
        TextFormField(
          key: ValueKey('$_sel-$label-$_gen'),
          initialValue: txt,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: AppUI.field(context, '', dense: true),
          style: AppUI.fieldText(context),
          onChanged: (t) {
            final d = double.tryParse(t);
            if (d != null) _change(() => set(d));
          },
        ),
      ]),
    );
  }
}
