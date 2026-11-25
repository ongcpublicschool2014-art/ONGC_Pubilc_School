import 'package:flutter/material.dart';

import '../utils/app_text.dart';
import '../utils/app_theme.dart';
import 'app_ui.dart';

/// One heading of [showAppMultiPick] and its (value, label) items. An empty
/// heading lists the items without one.
typedef AppPickGroup<T> = (String, List<(T, String)>);

/// The reports' many-choice filter (user, 2026-11-24: "drop down should be in
/// same style on all reports"): a panel opened just under the field that was
/// tapped ([anchor], that field's context), as Daily Collection's Fee Type --
/// not a dialog in the middle of the screen. Title, Select All / Clear (on the
/// items shown), a search box for a long list, ticks (a group heading ticks its
/// group), Cancel / Apply.
///
/// Returns the ticked values, or null when cancelled. With [requireOne],
/// Apply needs at least one tick.
Future<Set<T>?> showAppMultiPick<T>(
  BuildContext context, {
  BuildContext? anchor,
  required String title,
  required List<AppPickGroup<T>> groups,
  required Set<T> selected,
  bool requireOne = false,
  String searchHint = 'Search',
}) {
  // The field's place in the overlay the panel is drawn in.
  final overlay = Overlay.of(context, rootOverlay: true).context.findRenderObject() as RenderBox?;
  final box = anchor?.findRenderObject() as RenderBox?;
  final at = box != null && box.attached && box.hasSize ? box.localToGlobal(Offset.zero, ancestor: overlay) & box.size : null;

  return showDialog<Set<T>>(
    context: context,
    barrierColor: Colors.transparent,
    useSafeArea: false,
    builder: (ctx) => LayoutBuilder(builder: (ctx, c) {
      final screen = c.biggest;
      final width = (at?.width ?? 320.0).clamp(280.0, 420.0).clamp(0.0, screen.width - 16);
      final left = (at?.left ?? (screen.width - width) / 2).clamp(8.0, (screen.width - width - 8).clamp(8.0, screen.width));
      final top = at == null ? 120.0 : at.bottom + 4;
      final roomBelow = screen.height - top - 12;
      final roomAbove = (at?.top ?? 0) - 16;
      // Above the field only when it is low on the screen and there is more room up there.
      final above = at != null && roomBelow < 260 && roomAbove > roomBelow;
      final maxHeight = (above ? roomAbove : roomBelow).clamp(180.0, 440.0);
      return Stack(children: [
        Positioned.fill(
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => Navigator.pop(ctx)),
        ),
        Positioned(
          left: left,
          width: width,
          top: above ? null : top,
          bottom: above ? screen.height - at.top + 4 : null,
          child: _MultiPickPanel<T>(
            title: title,
            groups: groups,
            selected: selected,
            requireOne: requireOne,
            searchHint: searchHint,
            maxHeight: maxHeight,
          ),
        ),
      ]);
    }),
  );
}

class _MultiPickPanel<T> extends StatefulWidget {
  final String title;
  final List<AppPickGroup<T>> groups;
  final Set<T> selected;
  final bool requireOne;
  final String searchHint;
  final double maxHeight;
  const _MultiPickPanel({
    required this.title,
    required this.groups,
    required this.selected,
    required this.requireOne,
    required this.searchHint,
    required this.maxHeight,
  });

  @override
  State<_MultiPickPanel<T>> createState() => _MultiPickPanelState<T>();
}

class _MultiPickPanelState<T> extends State<_MultiPickPanel<T>> {
  late final Set<T> _draft = Set<T>.from(widget.selected);
  final _search = TextEditingController();

  int get _total => widget.groups.fold(0, (n, g) => n + g.$2.length);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The groups with only the items matching the search (a heading that
  /// matches keeps its whole group).
  List<AppPickGroup<T>> get _visible {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return widget.groups;
    return [
      for (final g in widget.groups)
        if (g.$1.toLowerCase().contains(q) && g.$1.isNotEmpty)
          g
        else
          (g.$1, [for (final i in g.$2) if (i.$2.toLowerCase().contains(q)) i]),
    ].where((g) => g.$2.isNotEmpty).toList();
  }

  Widget _link(String text, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(text, style: AppUI.label.copyWith(color: AppColors.primary)),
        ),
      );

  Widget _tick({required bool? value, required String label, required VoidCallback onTap, bool tristate = false, bool heading = false, double indent = 0}) =>
      CheckboxListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        tristate: tristate,
        value: value,
        activeColor: AppColors.primary,
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.only(left: 8 + indent, right: 12),
        title: Text(label, style: heading ? AppUI.label : AppUI.body),
        onChanged: (_) => setState(onTap),
      );

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final shown = [for (final g in visible) for (final i in g.$2) i.$1];
    final searching = _total > 8;
    return Material(
      elevation: 6,
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
            child: Row(children: [
              Expanded(child: Text(widget.title, style: AppUI.label, overflow: TextOverflow.ellipsis)),
              // both act on what is shown: with a search, on the matches
              _link('Select All', () => setState(() => _draft.addAll(shown))),
              _link(AppText.clear, () => setState(() => _draft.removeAll(shown))),
            ]),
          ),
          if (searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                controller: _search,
                autofocus: true,
                style: AppUI.fieldText(context),
                onChanged: (_) => setState(() {}),
                decoration: AppUI.field(
                  context,
                  widget.searchHint,
                  dense: true,
                  leadingIcon: 'search-normal',
                  suffix: _search.text.isEmpty
                      ? null
                      : InkWell(onTap: () => setState(_search.clear), child: const Icon(Icons.close, size: 15)),
                ).copyWith(suffixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 28)),
              ),
            ),
          const Divider(height: 1),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              child: Text(_total == 0 ? 'Nothing to choose from.' : 'Nothing matches.', textAlign: TextAlign.center, style: AppUI.muted),
            )
          else
            Flexible(
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 4), children: [
                for (final g in visible) ...[
                  if (g.$1.isNotEmpty)
                    _tick(
                      heading: true,
                      tristate: true,
                      label: g.$1,
                      value: g.$2.every((i) => _draft.contains(i.$1)) ? true : (g.$2.any((i) => _draft.contains(i.$1)) ? null : false),
                      onTap: () {
                        final all = g.$2.every((i) => _draft.contains(i.$1));
                        for (final i in g.$2) {
                          all ? _draft.remove(i.$1) : _draft.add(i.$1);
                        }
                      },
                    ),
                  for (final i in g.$2)
                    _tick(
                      label: i.$2,
                      indent: g.$1.isEmpty ? 0 : 24,
                      value: _draft.contains(i.$1),
                      onTap: () => _draft.contains(i.$1) ? _draft.remove(i.$1) : _draft.add(i.$1),
                    ),
                ],
              ]),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(children: [
              if (widget.requireOne && _draft.isEmpty)
                Expanded(child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text('Tick at least one.', style: AppUI.muted, overflow: TextOverflow.ellipsis),
                ))
              else
                const Spacer(),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text(AppText.cancel)),
              const SizedBox(width: 4),
              ElevatedButton(
                key: const ValueKey('multi-pick-apply'),
                style: AppUI.primary(context),
                onPressed: widget.requireOne && _draft.isEmpty ? null : () => Navigator.pop(context, _draft),
                child: const Text('Apply'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
