import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/app_theme.dart';
import 'app_ui.dart';

/// One choice of [AppSearchPickField]: the value, its name, and a muted
/// second line (employee code, designation ...) that is searched too.
class AppSearchPickItem<T> {
  final T value;
  final String label;
  final String? detail;
  const AppSearchPickItem(this.value, this.label, {this.detail});
}

/// A one-choice field whose list opens just under it with a search box
/// (user, 2026-11-24: "search option to fetch the teacher easily"): type part
/// of a name, code or designation, then click a row or press Enter for the
/// first match. [noneLabel] adds a first row that clears the choice.
class AppSearchPickField<T> extends StatelessWidget {
  final T? value;
  final List<AppSearchPickItem<T>> items;
  final ValueChanged<T?> onChanged;
  final String hint;
  final String title;
  final String? noneLabel;
  final bool enabled;
  final bool dense;
  final String searchHint;

  const AppSearchPickField({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint = 'Select',
    this.title = 'Select',
    this.noneLabel,
    this.enabled = true,
    this.dense = true,
    this.searchHint = 'Search name or code',
  });

  String? get _label {
    for (final i in items) {
      if (i.value == value) return i.label;
    }
    return value == null ? noneLabel : null;
  }

  @override
  Widget build(BuildContext context) {
    final label = _label;
    final filled = value != null;
    return Builder(
      builder: (field) => InkWell(
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        onTap: !enabled
            ? null
            : () async {
                final r = await showAppSearchPick<T>(context,
                    anchor: field, title: title, items: items, selected: value, noneLabel: noneLabel, searchHint: searchHint);
                if (r != null) onChanged(r.value);
              },
        child: InputDecorator(
          isEmpty: label == null,
          decoration: AppUI.field(context, hint, filled: filled, dense: dense,
              suffix: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary)),
          child: Text(label ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppUI.fieldText(context, filled: filled).copyWith(color: enabled ? null : AppColors.ink3)),
        ),
      ),
    );
  }
}

/// Opens the searchable list under [anchor]. Returns the picked value in a
/// record (its value may be null: [noneLabel]), or null when dismissed.
Future<({T? value})?> showAppSearchPick<T>(
  BuildContext context, {
  BuildContext? anchor,
  required String title,
  required List<AppSearchPickItem<T>> items,
  T? selected,
  String? noneLabel,
  String searchHint = 'Search',
}) {
  final overlay = Overlay.of(context, rootOverlay: true).context.findRenderObject() as RenderBox?;
  final box = anchor?.findRenderObject() as RenderBox?;
  final at = box != null && box.attached && box.hasSize ? box.localToGlobal(Offset.zero, ancestor: overlay) & box.size : null;
  return showDialog<({T? value})>(
    context: context,
    barrierColor: Colors.transparent,
    useSafeArea: false,
    builder: (ctx) => LayoutBuilder(builder: (ctx, c) {
      final screen = c.biggest;
      final width = (at?.width ?? 320.0).clamp(280.0, 460.0).clamp(0.0, screen.width - 16);
      final left = (at?.left ?? (screen.width - width) / 2).clamp(8.0, (screen.width - width - 8).clamp(8.0, screen.width));
      final top = at == null ? 120.0 : at.bottom + 4;
      final roomBelow = screen.height - top - 12;
      final roomAbove = (at?.top ?? 0) - 16;
      final above = at != null && roomBelow < 260 && roomAbove > roomBelow;
      final maxHeight = (above ? roomAbove : roomBelow).clamp(180.0, 420.0);
      return Stack(children: [
        Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => Navigator.pop(ctx))),
        Positioned(
          left: left,
          width: width,
          top: above ? null : top,
          bottom: above ? screen.height - at.top + 4 : null,
          child: _SearchPickPanel<T>(
            title: title,
            items: items,
            selected: selected,
            noneLabel: noneLabel,
            searchHint: searchHint,
            maxHeight: maxHeight,
          ),
        ),
      ]);
    }),
  );
}

class _SearchPickPanel<T> extends StatefulWidget {
  final String title;
  final List<AppSearchPickItem<T>> items;
  final T? selected;
  final String? noneLabel;
  final String searchHint;
  final double maxHeight;
  const _SearchPickPanel({
    required this.title,
    required this.items,
    required this.selected,
    required this.noneLabel,
    required this.searchHint,
    required this.maxHeight,
  });

  @override
  State<_SearchPickPanel<T>> createState() => _SearchPickPanelState<T>();
}

class _SearchPickPanelState<T> extends State<_SearchPickPanel<T>> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Every word typed must appear in the name, code or designation.
  List<AppSearchPickItem<T>> get _shown {
    final words = _search.text.trim().toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return widget.items;
    return [
      for (final i in widget.items)
        if (words.every((w) => '${i.label} ${i.detail ?? ''}'.toLowerCase().contains(w))) i,
    ];
  }

  void _pick(T? v) => Navigator.pop(context, (value: v));

  Widget _row({required String label, String? detail, required bool selected, required VoidCallback onTap, Key? key}) => InkWell(
        key: key,
        onTap: onTap,
        child: Container(
          color: selected ? AppColors.primarySoft : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(label, style: AppUI.body.copyWith(fontWeight: selected ? FontWeight.w700 : FontWeight.w500), overflow: TextOverflow.ellipsis),
                if (detail != null && detail.isNotEmpty) Text(detail, style: AppUI.muted, overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (selected) const Icon(Icons.check, size: 16, color: AppColors.primary),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final searching = _search.text.trim().isNotEmpty;
    return Material(
      elevation: 6,
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
              },
              child: TextField(
                key: const ValueKey('search-pick-field'),
                controller: _search,
                autofocus: true,
                style: AppUI.fieldText(context),
                onChanged: (_) => setState(() {}),
                // Enter takes the first match
                onSubmitted: (_) {
                  if (shown.isNotEmpty) _pick(shown.first.value);
                },
                decoration: AppUI.field(context, widget.searchHint, dense: true, leadingIcon: 'search-normal'),
              ),
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 4), children: [
              if (widget.noneLabel != null && !searching)
                _row(
                  key: const ValueKey('search-pick-none'),
                  label: widget.noneLabel!,
                  selected: widget.selected == null,
                  onTap: () => _pick(null),
                ),
              for (final i in shown)
                _row(label: i.label, detail: i.detail, selected: i.value == widget.selected, onTap: () => _pick(i.value)),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
                  child: Text('Nothing matches.', textAlign: TextAlign.center, style: AppUI.muted),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
