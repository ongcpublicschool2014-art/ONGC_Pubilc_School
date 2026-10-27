-- ============================================================================
-- Seed data: public.modules + public.activitytype   (institution 1)
--
-- These two tables are the ERP-style catalogue the document-sequence design was
-- built around: modules -> activitytype -> sequence, with seqapplicable saying
-- whether an activity issues a numbered document.
--
-- NOTE: nothing reads them today. The app writes sequence.mod_id = 0 hard-coded
-- (settings_screen, admission_master_screen, fee_master_screen), so this is a
-- catalogue for reference/reporting until that is wired up. Inserting it changes
-- no behaviour and breaks nothing.
--
-- 'COLLEGE FEES' below is spelled to match the actname already on the live
-- sequence row, so a future link-up matches without renaming anything.
--
-- modtype: 'A' = administrative, 'C' = collection (money). CHECK allows only
-- these two; the original meaning is not recorded anywhere, so this is an
-- assumption -- adjust before running if it should be something else.
--
-- mod_id / act_id are GENERATED ALWAYS AS IDENTITY, so ids cannot be supplied;
-- activities look their module up by modshort.
--
-- SAFE TO RE-RUN: every insert is guarded by NOT EXISTS.
-- ============================================================================

-- ── Modules ─────────────────────────────────────────────────────────────────
INSERT INTO public.modules (ins_id, modtype, modname, modshort, activestatus)
SELECT v.ins_id, v.modtype, v.modname, v.modshort, 1
FROM (VALUES
  (1, 'A', 'Admission',       'ADM'),
  (1, 'A', 'Student Details', 'STU'),
  (1, 'C', 'Fees',            'FEE'),
  (1, 'C', 'Banking',         'BANK'),
  (1, 'A', 'Reports',         'RPT'),
  (1, 'A', 'Setup',           'SETUP'),
  (1, 'A', 'General',         'GEN')
) AS v(ins_id, modtype, modname, modshort)
WHERE NOT EXISTS (
  SELECT 1 FROM public.modules m
   WHERE m.ins_id = v.ins_id AND m.modshort = v.modshort);

-- ── Activities ──────────────────────────────────────────────────────────────
-- seqapplicable 'Y' = the activity issues a numbered document (receipt, TC,
-- admission no); 'N' = it does not.
INSERT INTO public.activitytype (ins_id, mod_id, actname, actshort, seqapplicable, activestatus)
SELECT m.ins_id, m.mod_id, v.actname, v.actshort, v.seqapplicable, 1
FROM (VALUES
  -- Admission
  ('ADM',   'Admission Entry',        'ADMENTRY',   'Y'),
  ('ADM',   'Fast Admission',         'FASTADM',    'Y'),
  ('ADM',   'Admission Master',       'ADMMAST',    'N'),
  ('ADM',   'Class Allocation',       'CLSALLOC',   'N'),
  ('ADM',   'Section Transfer',       'SECTRANS',   'N'),
  ('ADM',   'Interim Promotion',      'INTPROMO',   'N'),
  ('ADM',   'TC Entry',               'TCENTRY',    'Y'),
  -- Student Details
  ('STU',   'Student Master',         'STUMAST',    'N'),
  ('STU',   'Student Import',         'STUIMPORT',  'N'),
  ('STU',   'Roll No Change',         'ROLLCHG',    'N'),
  -- Fees
  ('FEE',   'College Fees',           'COLLFEE',    'Y'),
  ('FEE',   'Misc Collection',        'MISCCOLL',   'Y'),
  ('FEE',   'Fee Refund',             'FEEREFUND',  'Y'),
  ('FEE',   'Fee Cancel Receipt',     'FEECANCEL',  'N'),
  ('FEE',   'Fee Concession',         'FEECONC',    'N'),
  ('FEE',   'Fee Demand',             'FEEDEMAND',  'N'),
  ('FEE',   'Fee Demand Approval',    'FEEDMNDAPR', 'N'),
  ('FEE',   'Fee Master',             'FEEMAST',    'N'),
  ('FEE',   'Fee Collection Import',  'FEEIMPORT',  'N'),
  -- Banking
  ('BANK',  'Transactions',           'TXN',        'N'),
  ('BANK',  'Bank Reconciliation',    'BANKRECON',  'N'),
  ('BANK',  'Bank Accounts',          'BANKACC',    'N'),
  -- Reports
  ('RPT',   'Daily Collection',       'DAILYCOLL',  'N'),
  ('RPT',   'Student Ledger',         'STULEDGER',  'N'),
  ('RPT',   'Pending Payment',        'PENDPAY',    'N'),
  ('RPT',   'Pending Details',        'PENDDET',    'N'),
  ('RPT',   'Consolidated Status',    'CONSOL',     'N'),
  ('RPT',   'DCB Register',           'DCB',        'N'),
  ('RPT',   'Export',                 'EXPORT',     'N'),
  -- Setup
  ('SETUP', 'Master Data',            'MASTDATA',   'N'),
  ('SETUP', 'Master Import',          'MASTIMPORT', 'N'),
  ('SETUP', 'Roles & Access',         'ROLES',      'N'),
  ('SETUP', 'Settings',               'SETTINGS',   'N'),
  ('SETUP', 'Utilities',              'UTIL',       'N'),
  -- General
  ('GEN',   'Notices',                'NOTICE',     'N'),
  ('GEN',   'Notifications',          'NOTIFY',     'N')
) AS v(modshort, actname, actshort, seqapplicable)
JOIN public.modules m
  ON m.modshort = v.modshort AND m.ins_id = 1 AND m.activestatus = 1
WHERE NOT EXISTS (
  SELECT 1 FROM public.activitytype a
   WHERE a.ins_id = m.ins_id AND a.actshort = v.actshort);

-- ── Verify ──────────────────────────────────────────────────────────────────
SELECT m.modshort, m.modname, m.modtype,
       count(a.act_id)                                   AS activities,
       count(*) FILTER (WHERE a.seqapplicable = 'Y')      AS numbered
FROM public.modules m
LEFT JOIN public.activitytype a ON a.mod_id = m.mod_id
WHERE m.ins_id = 1
GROUP BY m.mod_id, m.modshort, m.modname, m.modtype
ORDER BY m.mod_id;
