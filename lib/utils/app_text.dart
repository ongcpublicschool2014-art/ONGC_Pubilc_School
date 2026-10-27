/// Shared user-facing wording, so the same action or term reads the same on
/// every screen. Display text only -- never use these as keys, column names
/// or values compared in code.
///
/// Conventions (see the UX text audit):
///  * Title Case for titles, headings, field labels and buttons; sentence
///    case for placeholders, helper text and messages.
///  * Buttons are a verb or verb + object.
///  * Messages are polite and specific, with no "!", no ALL CAPS and no raw
///    error text: say what went wrong and how to fix it.
///  * Dates read DD-MM-YYYY (see [formatDmy]).
library;

class AppText {
  AppText._();

  // ── buttons ───────────────────────────────────────────────────────────
  static const save = 'Save';
  static const update = 'Update';
  static const clear = 'Clear';
  static const clearFilters = 'Clear Filters';
  static const cancel = 'Cancel';
  static const delete = 'Delete';
  static const close = 'Close';
  static const import = 'Import';
  static const chooseFile = 'Choose File';
  static const downloadTemplate = 'Download Template';
  static const downloadSample = 'Download Sample Data';
  static const exportExcel = 'Export Excel';
  static const exportPdf = 'Export PDF';
  static const print = 'Print';
  static const search = 'Search';
  static const addRow = 'Add Row';
  static const deleteRow = 'Delete Row';

  // ── fields ────────────────────────────────────────────────────────────
  static const requiredNote = '* Required fields';
  static const autoFilled = 'Auto-filled';
  static const generated = 'Generated automatically';
  static const dateHint = 'DD-MM-YYYY';

  // ── one term per concept ──────────────────────────────────────────────
  static const admissionNo = 'Admission No.';
  static const dateOfBirth = 'Date of Birth';
  static const dateOfAdmission = 'Date of Admission';
  static const dayScholar = 'Day Scholar';
  static const hosteller = 'Hosteller';
  static const serialNo = 'S. No.';
  static const paymentMode = 'Payment Mode';

  // ── messages ──────────────────────────────────────────────────────────
  /// "Could not save the fee group. Check your connection and try again."
  static String couldNot(String what, [String? fix]) => 'Could not $what.${fix == null || fix.isEmpty ? '' : ' $fix'}';

  /// "Enter the IFSC code" / "Select a section".
  static String enter(String what) => 'Enter $what';
  static String select(String what) => 'Select $what';
}

/// DD-MM-YYYY for display ('' for null).
String formatDmy(DateTime? d) =>
    d == null ? '' : '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
