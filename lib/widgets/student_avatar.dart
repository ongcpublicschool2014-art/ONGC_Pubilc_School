import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import 'app_ui.dart';

/// The selected student's photo, used wherever a screen shows the student it
/// is working on (Fee Collection, Misc Collection, Concession, Refund, TC ...).
///
/// Shows `students.stuphoto` (a public storage URL) in a circle; with no photo,
/// or one that fails to load, the student's initial instead. When there is a
/// photo, clicking it opens a larger view so the cashier can check who is at
/// the counter.
class StudentAvatar extends StatelessWidget {
  final String? photoUrl;
  final String name;
  final double size;
  final bool enlargeOnTap;

  const StudentAvatar({
    super.key,
    required this.photoUrl,
    required this.name,
    this.size = 44,
    this.enlargeOnTap = true,
  });

  bool get _hasPhoto => (photoUrl ?? '').trim().isNotEmpty;

  Widget _initial() => Center(
        child: Text(
          name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : '?',
          style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w800, color: AppColors.primary),
        ),
      );

  void _enlarge(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(children: [
                Expanded(child: Text(name, style: AppUI.cardTitle, overflow: TextOverflow.ellipsis)),
                IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
              ]),
            ),
            Flexible(
              child: Image.network(
                photoUrl!.trim(),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text('The photo could not be loaded.', style: AppUI.muted),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final circle = Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.primaryLight,
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: _hasPhoto
          ? Image.network(
              photoUrl!.trim(),
              fit: BoxFit.cover,
              width: size,
              height: size,
              errorBuilder: (_, __, ___) => _initial(),
              loadingBuilder: (_, child, progress) => progress == null ? child : _initial(),
            )
          : _initial(),
    );
    if (!_hasPhoto || !enlargeOnTap) return circle;
    return Tooltip(
      message: 'View photo',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: () => _enlarge(context), child: circle),
      ),
    );
  }
}
