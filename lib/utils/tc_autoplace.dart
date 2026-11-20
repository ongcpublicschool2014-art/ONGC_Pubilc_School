import 'dart:convert';
import 'dart:io';

import 'tc_pdf.dart';

/// A blank on a Word TC format: the label in front of it and where its value
/// goes on the page (PDF points from the top-left, as [TcPdfField]).
class TcBlank {
  final String label;
  final int page;
  final double x, y, w;
  const TcBlank(this.label, this.page, this.x, this.y, this.w);
}

/// Places the TC fields on a Word format automatically: Word reports where
/// each blank is (an empty table cell after a label, or a "Label ______"
/// line) and the label says which field it is ("Name of the pupil" ->
/// Student Name). Blanks whose label means nothing to the app are left for
/// the office to place by hand.
class TcAutoPlace {
  TcAutoPlace._();

  static const _script = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$w = $null
$out = New-Object System.Collections.ArrayList
function Clean($t) { (($t -replace '[\r\a\x07\x0b]', ' ') -replace '\s+', ' ').Trim() }
function IsBlank($t) { $t -eq '' -or $t -match '^[_\.\s:\-]+$' }
# A value cell holding ":   (Class In words) :" -- two blanks on one line:
# the row's own value after the first colon, a second value after the inner
# label. A further line of the cell ("If so, to which class") is the row's
# follow-up item.
function SplitCell($lab, $n) {
  $i = 0
  foreach ($p in $n.Range.Paragraphs) {
    $t = $p.Range.Text -replace '[\r\a\x07]', ''
    $plab = if ($i -eq 0) { $lab } elseif ($lab -match 'to which class') { 'to which class (In figures)' } else { "$lab (contd)" }
    $ipre = if ($i -eq 0) { '' } else { 'to which class ' }
    $m = [regex]::Match($t, '^(\s*:\s*)(\S.*?\S)\s*:\s*$')
    if ($m.Success) {
      $s = $p.Range.Start + $t.IndexOf(':') + 1
      $r = $d.Range($s, $s)
      $e = $d.Range($p.Range.Start + $m.Groups[2].Index, $p.Range.Start + $m.Groups[2].Index)
      Add $plab $r ([math]::Max(30, $e.Information(5) - $r.Information(5) - 6))
      $s2 = $p.Range.Start + $t.LastIndexOf(':') + 1
      Add ($ipre + $m.Groups[2].Value) $d.Range($s2, $s2) 120
    } elseif ($t -match '^\s*:\s*$') {
      $s = $p.Range.Start + $t.IndexOf(':') + 1
      $cw = 150
      try { $cw = $n.Width - 14 } catch {}
      Add $plab $d.Range($s, $s) $cw
    }
    $i++
  }
}
function Add($label, $r, $width) {
  [void]$out.Add([pscustomobject]@{ label = $label; page = $r.Information(3) - 1; x = $r.Information(5); y = $r.Information(6); w = $width })
}
try {
  $w = New-Object -ComObject Word.Application
  $w.Visible = $false
  $w.DisplayAlerts = 0
  $d = $w.Documents.Open($env:TC_IN, $false, $true, $false)
  $d.Repaginate()
  foreach ($t in $d.Tables) {
    $cells = @{}
    foreach ($c in $t.Range.Cells) { $cells["$($c.RowIndex),$($c.ColumnIndex)"] = $c }
    foreach ($c in $t.Range.Cells) {
      $lab = Clean $c.Range.Text
      if (IsBlank $lab) { continue }
      # the item number in the column before ("3.") belongs to the label
      $pc = $cells["$($c.RowIndex),$($c.ColumnIndex - 1)"]
      if ($null -ne $pc) {
        $pt = Clean $pc.Range.Text
        if ($pt -match '^\d+\.?$') { $lab = "$pt $lab" }
      }
      $n = $cells["$($c.RowIndex),$($c.ColumnIndex + 1)"]
      if ($null -eq $n) { continue }
      if (-not (IsBlank (Clean $n.Range.Text))) {
        if ((Clean $n.Range.Text) -match '^:') { SplitCell $lab $n }
        continue
      }
      $r = $n.Range
      $r.Collapse(1)
      # A blank written as ":" (label | ": value" layouts): the value goes
      # after the colon, not over it.
      $lead = ([regex]::Match($n.Range.Text, '^[: \t]*')).Length
      if ($lead -gt 0) { [void]$r.Move(1, $lead) }
      $cw = 150
      try { $cw = $n.Width - 8 - 6 * $lead } catch {}
      Add $lab $r $cw
    }
  }
  # "Label ______", "Label : ......" or "Label: [      ]" -- in or out of a
  # table (a header cell can hold several such lines). Several per line.
  foreach ($p in $d.Paragraphs) {
    $txt = $p.Range.Text
    foreach ($m in [regex]::Matches($txt, '([^_\t\[\]\|]{2,}?)\s*[:\-]?\s*(_{3,}|\.{4,}|\[[  ]*\])')) {
      $g = $m.Groups[2]
      $start = $p.Range.Start + $g.Index
      $len = $g.Length
      if ($g.Value.StartsWith('[')) { $start = $start + 1; $len = $len - 2 }
      $r = $d.Range($start, $start)
      $e = $d.Range($start + $len, $start + $len)
      $bw = $e.Information(5) - $r.Information(5)
      if ($g.Value.StartsWith('[')) { if ($bw -lt 45) { $bw = 45 } }
      elseif ($bw -lt 30) { $bw = 90 }
      Add (Clean $m.Groups[1].Value) $r $bw
    }
  }
  $d.Close(0)
} finally {
  if ($w) { $w.Quit() }
}
ConvertTo-Json -InputObject @($out) -Compress
''';

  /// The blanks of a Word format, read through Microsoft Word on this PC.
  /// Empty when Word is not available or the file has no recognisable blanks.
  static Future<List<TcBlank>> blanks(List<int> docx) async {
    final dir = await Directory.systemTemp.createTemp('tc_auto_');
    try {
      final sep = Platform.pathSeparator;
      final input = File('${dir.path}${sep}format.docx');
      final script = File('${dir.path}${sep}blanks.ps1');
      await input.writeAsBytes(docx, flush: true);
      await script.writeAsString(_script, flush: true);
      final res = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script.path],
        environment: {'TC_IN': input.path},
        stdoutEncoding: utf8,
      ).timeout(const Duration(seconds: 90));
      final text = '${res.stdout}'.trim();
      if (res.exitCode != 0 || text.isEmpty) return const [];
      double n(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
      return [
        for (final r in (jsonDecode(text) as List))
          if (r is Map) TcBlank('${r['label'] ?? ''}', n(r['page']).toInt(), n(r['x']), n(r['y']), n(r['w'])),
      ];
    } catch (_) {
      return const [];
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Label wording -> field, first match wins (so "mother" is tried before
  /// "father / guardian", "present" before "working days").
  static final List<(RegExp, String)> _rules = [
    for (final (p, k) in const [
      (r'affiliation', 'Affiliation No'),
      (r'udise', 'UDISE Code'),
      (r'school\s*code', 'School Code'),
      (r'phone|mobile|contact\s*no', 'School Phone'),
      (r'e-?\s*mail', 'School Email'),
      (r'web\s*site', 'School Website'),
      (r'book\s*no', 'Book No'),
      (r'cert\.?\s*sl', 'Cert Sl No'),
      (r'to which class.*in words', 'Promoted Class in Words'),
      (r'class in words', 'Standard Ordinal'),
      (r'\bpen\b', 'Student PEN'),
      (r'\bt\.?\s*c\.?\s*no|\bs\.\s*no\b|\bsl\.?\s*no|serial', 'TC No'),
      (r'admission\s*no|\badm\.?\s*no|admission\s*number', 'Admission No'),
      (r'apaar|emis', 'EMIS No'),
      (r'aadha?a?r', 'Aadhar No'),
      (r'block letters', 'Student Name (Block Letters)'),
      (r'தமிழ', 'Student Name (Tamil)'),
      (r'name of the school', 'School Name'),
      (r'educational district|revenue district', 'Educational District'),
      (r'date of the transfer certificate', 'TC Date'),
      (r'date of application|application for', 'Date of Application'),
      (r'actually left', 'Leaving Date'),
      (r'struck off|date of leaving|left the school', 'Date Struck Off'),
      (r'name of (the )?(pupil|student|candidate)|(pupil|student).?s? name', 'Student Name'),
      (r'mother', 'Mother Name'),
      (r'father|parent', 'Father Name'),
      (r'guardian', 'Guardian Name'),
      (r'proof', 'Proof of DOB'),
      (r'birth.*figures.*words', 'DOB in Figures and Words'),
      (r'birth.*word', 'DOB in Words'),
      (r'birth', 'DOB'),
      (r'nationality.*religion.*caste', 'Nationality, Religion and Caste'),
      (r'nationality.*religion|religion.*nationality', 'Nationality and Religion'),
      (r'nationality', 'Nationality'),
      (r'scheduled caste|scheduled tribe|\bobc\b|\bsc\s*/\s*st\b|community category', 'Community Category'),
      (r'religion', 'Religion'),
      (r'communit', 'Community'),
      (r'caste', 'Caste'),
      (r'\bsex\b|gender', 'Gender'),
      (r'date of (first )?admission|admitted', 'Date of Admission'),
      (r'studying.*leaving|leaving.*in words', 'Standard in Words'),
      (r'last studied|class.*studying|standard.*studying', 'Standard'),
      (r'course i\.?e|general education or vocational', 'Course Offered'),
      (r'vocational subject', 'Part III Group B Subjects'),
      (r'general education.*subjects|subjects offered', 'Part III Group A Subjects'),
      (r'part\s*-?\s*i\b|language offered', 'Part I Language'),
      (r'whether failed', 'Whether Failed'),
      (r'examination|\bexam\b|result', 'Last Exam Result'),
      (r'subject', 'Subjects Studied'),
      (r'qualified|promotion', 'Qualified for Promotion'),
      (r'to which class', 'Promoted Class'),
      (r'paid all the fees', 'All Fees Paid'),
      (r'dues|fees? paid', 'Fees Paid Up To'),
      (r'scholarship', 'Scholarship'),
      (r'concession', 'Fee Concession'),
      (r'present|attendance', 'Days Present'),
      (r'working days', 'Total Working Days'),
      (r'\bncc\b|scout|guide', 'NCC / Scout / Guide'),
      (r'games|extra.?curricular|co.?curricular', 'Extra Curricular Activities'),
      (r'govt|minority|independent', 'School Category'),
      (r'conduct', 'General Conduct'),
      (r'date of issue|issue of', 'TC Date'),
      (r'reason', 'Reason for Leaving'),
      (r'remark', 'Remarks'),
      (r'medium', 'Medium'),
      (r'identification', 'Identification Mark 1'),
      (r'medical', 'Medical Inspection'),
      (r'^date$', 'Print Date'),
    ])
      (RegExp(p, caseSensitive: false), k),
  ];

  /// The field a label stands for, or null.
  static String? keyFor(String label) {
    final l = label.trim();
    for (final (re, key) in _rules) {
      if (re.hasMatch(l)) return key;
    }
    return null;
  }

  /// Fields for [blanks] whose label is understood. Each field is placed once
  /// (a second "Identification" blank becomes Identification Mark 2).
  static List<TcPdfField> fields(List<TcBlank> blanks, {double size = 10}) {
    final used = <String>{};
    final out = <TcPdfField>[];
    for (final b in blanks) {
      var key = keyFor(b.label);
      if (key == null) continue;
      if (key == 'Identification Mark 1' && used.contains(key)) key = 'Identification Mark 2';
      if (!used.add(key)) continue;
      out.add(TcPdfField(key: key, page: b.page, x: b.x, y: b.y + 1, w: b.w < 30 ? 120 : b.w, size: size, label: b.label));
    }
    return out;
  }
}
