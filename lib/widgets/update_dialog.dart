import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/update_service.dart';
import '../utils/app_theme.dart';

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
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = 'Download failed. Please try again or contact support. ($e)';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(children: [
        Icon(Icons.system_update_rounded, color: AppColors.accent),
        const SizedBox(width: 10),
        const Expanded(child: Text('Update available', style: TextStyle(fontWeight: FontWeight.w800))),
      ]),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version ${i.version} is ready to install.',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (i.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(i.notes.trim(), style: const TextStyle(fontSize: 13)),
              ),
            ],
            if (_downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress > 0 ? _progress : null, color: AppColors.accent),
              const SizedBox(height: 6),
              Text(
                _progress > 0 ? 'Downloading… ${(_progress * 100).toStringAsFixed(0)}%' : 'Starting download…',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 4),
              Text('The app will close and reopen once the installer runs.',
                  style: TextStyle(fontSize: 11, color: AppColors.textLight)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: _downloading
          ? const []
          : [
              if (!i.mandatory)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Later'),
                ),
              ElevatedButton.icon(
                onPressed: _downloadAndInstall,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Download & Install'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
    );
  }
}
