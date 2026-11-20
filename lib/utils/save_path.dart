import 'package:file_picker/file_picker.dart';

/// The Save dialog, returning a path that always ends in the right extension.
///
/// Windows returns the name exactly as typed. Renaming the file in the dialog
/// easily drops the ".xlsx" / ".pdf" (or its dot), and the file was then saved
/// without one -- Excel or the PDF viewer could not open it, so the download
/// looked broken. Same parameters as FilePicker.platform.saveFile.
Future<String?> pickSavePath({
  String? dialogTitle,
  String? fileName,
  String? initialDirectory,
  FileType type = FileType.any,
  List<String>? allowedExtensions,
  bool lockParentWindow = false,
}) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    initialDirectory: initialDirectory,
    type: type,
    allowedExtensions: allowedExtensions,
    lockParentWindow: lockParentWindow,
  );
  if (path == null || path.trim().isEmpty) return path;
  return withExtension(path, allowedExtensions, fileName);
}

/// [path] with an allowed extension: kept if it already has one, otherwise
/// the first allowed one (or the suggested file name's) is added.
String withExtension(String path, List<String>? allowed, [String? suggested]) {
  final exts = [
    for (final e in allowed ?? const <String>[]) e.toLowerCase().replaceFirst(RegExp(r'^\.'), ''),
  ];
  if (exts.isEmpty && suggested != null && suggested.contains('.')) {
    exts.add(suggested.split('.').last.toLowerCase());
  }
  if (exts.isEmpty) return path;
  final lower = path.toLowerCase();
  if (exts.any((e) => lower.endsWith('.$e'))) return path;
  // "templatexlsx" (the dot deleted) -> "template.xlsx", not "templatexlsx.xlsx"
  final e = exts.first;
  final base = lower.endsWith(e) && path.length > e.length ? path.substring(0, path.length - e.length) : path;
  return '${base.endsWith('.') ? base.substring(0, base.length - 1) : base}.$e';
}
