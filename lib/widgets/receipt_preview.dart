import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/receipt_format_service.dart';
import 'receipt_widget.dart';

/// The receipt as it will print: on the school's own format (Setup > Receipt
/// Format) when one is in use, else the built-in design ([ReceiptWidget]).
/// Every receipt dialog shows this, so the screen and the paper agree.
class ReceiptPreview extends StatefulWidget {
  final ReceiptData data;
  const ReceiptPreview({super.key, required this.data});

  @override
  State<ReceiptPreview> createState() => _ReceiptPreviewState();
}

class _ReceiptPreviewState extends State<ReceiptPreview> {
  late final Future<List<Uint8List>?> _pages = _render();

  /// The school's format, rendered as images; null = the built-in design.
  Future<List<Uint8List>?> _render() async {
    try {
      final doc = await ReceiptFormatService.build(widget.data);
      if (doc == null) return null;
      final out = <Uint8List>[];
      await for (final r in Printing.raster(await doc.save(), dpi: 144)) {
        out.add(await r.toPng());
      }
      return out.isEmpty ? null : out;
    } catch (e) {
      debugPrint('Receipt preview: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Uint8List>?>(
      future: _pages,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Container(
            width: ReceiptWidget.b5Width,
            height: ReceiptWidget.b5Height,
            color: Colors.white,
            alignment: Alignment.center,
            child: const CircularProgressIndicator(),
          );
        }
        final pages = snap.data;
        if (pages == null) return ReceiptWidget(data: widget.data);
        return Column(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < pages.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            Container(
              width: ReceiptWidget.b5Width,
              color: Colors.white,
              child: Image.memory(pages[i], fit: BoxFit.fitWidth, filterQuality: FilterQuality.medium),
            ),
          ],
        ]);
      },
    );
  }
}
