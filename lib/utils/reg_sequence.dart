/// Which admission number sequence an admission takes when the school keeps
/// them division-wise (Setup -> Sequence Master -> Admission No., user
/// 2026-11-18). Shared by Admission Entry and Fast Admission.
library;

/// What [regSeqFor] decided.
class RegSeqChoice {
  /// The sequence to number from; null = none can be used.
  final Map<String, dynamic>? seq;

  /// Said to the user when the division has no sequence of its own.
  final String? notice;
  const RegSeqChoice(this.seq, [this.notice]);

  /// The admission cannot be numbered until a sequence is created.
  bool get blocked => seq == null;
}

String _norm(Object? v) => (v?.toString() ?? '').trim().toUpperCase();

/// At least one sequence belongs to a division.
bool regSeqDivisionWise(List<Map<String, dynamic>> seqs) => seqs.any((s) => _norm(s['division']).isNotEmpty);

/// The division's own sequence; otherwise the general one (no division), with
/// a notice when the division should have had its own.
RegSeqChoice regSeqFor(List<Map<String, dynamic>> seqs, String? division) {
  const where = 'Create one in Setup → Sequence Master → Admission No.';
  final div = _norm(division);
  if (div.isNotEmpty) {
    for (final s in seqs) {
      if (_norm(s['division']) == div) return RegSeqChoice(s);
    }
  }
  Map<String, dynamic>? general;
  for (final s in seqs) {
    if (_norm(s['division']).isEmpty) {
      general = s;
      break;
    }
  }
  if (div.isEmpty) {
    return general != null
        ? RegSeqChoice(general)
        : const RegSeqChoice(null, 'This standard has no division and there is no general admission number sequence. $where');
  }
  final name = division!.trim();
  return general != null
      ? RegSeqChoice(general, '$name has no admission number sequence, so ${general['seqname']} is used. $where')
      : RegSeqChoice(null, '$name has no admission number sequence. $where');
}
