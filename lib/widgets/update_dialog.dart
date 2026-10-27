import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/update_service.dart';
import '../utils/app_theme.dart';
import 'app_ui.dart';

/// Checks for an update and, if one exists, shows the prompt. Call once after
/// login (e.g. from the dashboard). No-op on failure or when already current.
Future<void> maybePromptUpdate(BuildContext context) async {
  final info = await UpdateService.checkForUpdate();
  if (info == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: !info.mandatory,
    builder: (_) => _UpdateDialog(info: info),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});
  final UpdateInfo info;
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;
  double _progress = 0;
  String? _error;

  Future<void> _downloadAndInstall() async {
    setState(() {
      _downloading = true;
      _error = null;
      _progress = 0;
    });
    try {
      final client = http.Client();
      final resp = await client.send(http.Request('GET', Uri.parse(widget.info.url)));
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
      final total = resp.contentLength ?? 0;
      final path =
          '${Directory.systemTemp.path}${Platform.pathSeparator}EduCore360-Setup-${widget.info.version}.exe';
      final file = File(path);
      final sink = file.openWrite();
      int received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && mounted) setState(() => _progress = received / total);
      }
      await sink.close();
      client.close();
      // Launch the installer detached, then quit so it can replace the running
      // app. The Inno installer closes/reopens EduCore360.
      await Process.start(path, [], mode: ProcessStartMode.detached, runInShell: true);
      await Future.delayed(const Duration(milliseconds: 400));
      exit(0);
    } catch (_) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = 'Could not download the update. Check your internet connection and try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    // Same guard as the parent app: barrierDismissible alone leaves the route
    // poppable (Esc, a system back gesture), so a mandatory update could still
    // be waved away. Also held shut while a download is running.
    return PopScope(
      // ... UNLESS the download has already failed. A mandatory update whose
      // URL 404s would otherwise seal every counter PC behind a dialog it
      // cannot dismiss, over a dashboard it cannot reach, and force-closing
      // does not help -- the check runs again at the next launch. That is
      // exactly what happened to the parent app on 1.1.3.
      //
      // The update is still mandatory: the prompt returns on the next launch.
      // All this buys is a till that can keep taking cash while the manifest
      // is being fixed.
      canPop: (!i.mandatory || _error != null) && !_downloading,
      child: AlertDialog(
      title: Row(children: [
        const Icon(Icons.system_update_rounded, color: AppColors.primary),
        const SizedBox(width: 10),
        Expanded(child: Text('Update Available', style: AppUI.cardTitle)),
      ]),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version ${i.version} is ready to install.',
                style: AppUI.body.copyWith(fontWeight: FontWeight.w600)),
            if (i.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Text(i.notes.trim(), style: AppUI.body),
              ),
            ],
            if (_downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress > 0 ? _progress : null, color: AppColors.primary),
              const SizedBox(height: 6),
              Text(
                _progress > 0 ? 'Downloading… ${(_progress * 100).toStringAsFixed(0)}%' : 'Starting download…',
                style: AppUI.muted.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 4),
              Text('The app will close and reopen once the installer runs.',
                  style: AppUI.muted),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: AppUI.muted.copyWith(color: AppColors.error)),
            ],
          ],
        ),
      ),
      actions: _downloading
          ? const []
          : [
              // Shown for an optional update, and for a mandatory one that
              // could not be downloaded -- see the PopScope above.
              if (!i.mandatory || _error != null)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(i.mandatory ? 'Continue Without Updating' : 'Later'),
                ),
              ElevatedButton.icon(
                onPressed: _downloadAndInstall,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Download & Install'),
              ),
            ],
    ),
    );
  }
}
