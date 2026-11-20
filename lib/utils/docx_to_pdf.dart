import 'dart:io';
import 'dart:typed_data';

/// Turns a Word (.docx) file into a PDF on this PC, so a school's Word TC can
/// be used like a PDF one: fields placed on the page on TC Format.
///
/// Uses Microsoft Word when it is installed (it lays the page out exactly as
/// the school sees it), else LibreOffice. Throws [DocxToPdfException] with a
/// message for the office when neither can do it.
class DocxToPdf {
  static const _wordScript = r'''
$ErrorActionPreference = 'Stop'
$w = $null
try {
  $w = New-Object -ComObject Word.Application
  $w.Visible = $false
  $w.DisplayAlerts = 0
  $d = $w.Documents.Open($env:TC_IN, $false, $true, $false)
  $d.ExportAsFixedFormat($env:TC_OUT, 17)
  $d.Close(0)
} finally {
  if ($w) { $w.Quit() }
}
''';

  static Future<Uint8List> convert(List<int> docx) async {
    final dir = await Directory.systemTemp.createTemp('tc_format_');
    try {
      final input = File('${dir.path}${Platform.pathSeparator}format.docx');
      final output = File('${dir.path}${Platform.pathSeparator}format.pdf');
      await input.writeAsBytes(docx, flush: true);

      // 1) Microsoft Word. The paths go in through the environment so no
      // quoting can break the script.
      final script = File('${dir.path}${Platform.pathSeparator}convert.ps1');
      await script.writeAsString(_wordScript, flush: true);
      try {
        await Process.run(
          'powershell',
          ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script.path],
          environment: {'TC_IN': input.path, 'TC_OUT': output.path},
        ).timeout(const Duration(seconds: 90));
      } catch (_) {/* fall through to LibreOffice */}
      if (await _isPdf(output)) return output.readAsBytes();

      // 2) LibreOffice, if installed.
      for (final soffice in [
        r'C:\Program Files\LibreOffice\program\soffice.exe',
        r'C:\Program Files (x86)\LibreOffice\program\soffice.exe',
      ]) {
        if (!File(soffice).existsSync()) continue;
        try {
          await Process.run(soffice, ['--headless', '--convert-to', 'pdf', '--outdir', dir.path, input.path])
              .timeout(const Duration(seconds: 90));
        } catch (_) {}
        if (await _isPdf(output)) return output.readAsBytes();
      }

      throw const DocxToPdfException(
          'This PC could not turn the Word file into a PDF (Microsoft Word or LibreOffice is needed). '
          'Open it in Word, choose File > Save As > PDF, and upload the PDF instead.');
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<bool> _isPdf(File f) async {
    if (!await f.exists() || await f.length() < 5) return false;
    final head = await f.openRead(0, 5).fold<List<int>>([], (a, b) => a..addAll(b));
    return String.fromCharCodes(head) == '%PDF-';
  }
}

class DocxToPdfException implements Exception {
  final String message;
  const DocxToPdfException(this.message);
  @override
  String toString() => message;
}
