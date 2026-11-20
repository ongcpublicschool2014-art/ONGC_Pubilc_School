import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/focusable_tap.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../utils/app_text.dart';
class NoticesScreen extends StatefulWidget {
  const NoticesScreen({super.key});

  @override
  State<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends State<NoticesScreen> {
  bool _isLoading = false;
  List<Map<String, dynamic>> _notices = [];
  Map<String, dynamic>? _selectedNotice;
  bool _showCreateForm = false;

  @override
  void initState() {
    super.initState();
    _fetchNotices();
  }

  Future<void> _fetchNotices() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isLoading = true);
    try {
      final data = await SupabaseService.fromSchema('notice')
          .select()
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('createdat', ascending: false);

      final all = List<Map<String, dynamic>>.from(data);
      final today = DateTime.now();
      final todayStr = '${today.year}-${today.month.toString().padLeft(2,'0')}-${today.day.toString().padLeft(2,'0')}';

      // Hard-delete notices whose to-date has passed. No soft-delete retained
      // — once a notice expires it's useless and taking up DB rows.
      final expiredIds = all
          .where((n) {
            final toDate = n['noticetodate']?.toString();
            return toDate != null && toDate.isNotEmpty && toDate.compareTo(todayStr) < 0;
          })
          .map((n) => n['notice_id'] ?? n['id'])
          .where((id) => id != null)
          .toList();

      if (expiredIds.isNotEmpty) {
        try {
          // Delete child notifications first so we don't leave orphan
          // inbox rows pointing at a soon-to-be-gone notice_id.
          await SupabaseService.fromSchema('notification')
              .delete()
              .inFilter('notice_id', expiredIds);
          await SupabaseService.fromSchema('notice')
              .delete()
              .inFilter('notice_id', expiredIds);
        } catch (_) {}
      }

      final active = all.where((n) {
        final toDate = n['noticetodate']?.toString();
        if (toDate == null || toDate.isEmpty) return true;
        return toDate.compareTo(todayStr) >= 0;
      }).toList();

      if (mounted) {
        setState(() {
          _notices = active;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching notices: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return '-';
    try {
      final dt = DateTime.parse(dateStr);
      return formatDmy(dt);
    } catch (_) {
      return dateStr;
    }
  }

  String _timeAgo(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final dt = DateTime.parse(dateStr);
      final diff = DateTime.now().difference(dt);
      if (diff.inDays > 30) return '${(diff.inDays / 30).floor()} months ago';
      if (diff.inDays > 0) return '${diff.inDays} days ago';
      if (diff.inHours > 0) return '${diff.inHours} hours ago';
      if (diff.inMinutes > 0) return '${diff.inMinutes} minutes ago';
      return 'Just now';
    } catch (_) {
      return '';
    }
  }

  Color _priorityColor(String? priority) {
    switch (priority?.toLowerCase()) {
      case 'high':
      case 'urgent':
        return AppColors.error;
      case 'medium':
        return AppColors.warning;
      default:
        return AppColors.accent;
    }
  }

  AppStatus _priorityStatus(String? priority) {
    switch (priority?.toLowerCase()) {
      case 'high':
      case 'urgent':
        return AppStatus.danger;
      case 'medium':
        return AppStatus.warning;
      default:
        return AppStatus.info;
    }
  }

  String _categoryIcon(String? category) {
    switch (category?.toLowerCase()) {
      case 'exam':
        return 'message-question';
      case 'holiday':
        return 'sun-1';
      case 'event':
        return 'calendar-1';
      case 'fee':
        return 'indianrupeesign.circle.fill';
      case 'result':
        return 'chart-1';
      default:
        return 'volume-high';
    }
  }

  // ── layout ──────────────────────────────────────────────────────────────────
  // Master-detail: the notice list (searchable) on the left; the picked notice
  // -- or the Create Notice form -- on the right.
  String _query = '';

  dynamic _noticeId(Map<String, dynamic> n) => n['notice_id'] ?? n['id'];

  List<Map<String, dynamic>> get _visibleNotices {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _notices;
    return _notices.where((n) {
      final hay = [
        n['noticetitle'] ?? n['title'],
        n['noticedesc'] ?? n['description'],
        n['noticecategory'] ?? n['category'],
        n['noticetarget'],
      ].map((e) => e?.toString().toLowerCase() ?? '').join(' ');
      return hay.contains(q);
    }).toList();
  }

  void _openCreate() => setState(() {
        _showCreateForm = true;
        _selectedNotice = null;
      });

  void _closeDetail() => setState(() {
        _showCreateForm = false;
        _selectedNotice = null;
      });

  @override
  Widget build(BuildContext context) {
    final visible = _visibleNotices;
    return AppMasterDetail(
      listTitle: 'Notices',
      listIcon: 'volume-high',
      listSubtitle: 'Announcements  ·  ${_notices.length} notice${_notices.length == 1 ? '' : 's'}',
      // A little wider than the default 380: beside the Create Notice button
      // the title column was narrower than "Announcements", which then broke
      // mid-word.
      listWidth: 420,
      listActions: [
        ElevatedButton.icon(
          onPressed: _openCreate,
          icon: AppIcon('add', size: AppBtn.iconSize(context), color: Colors.white),
          label: const Text('Create Notice'),
        ),
      ],
      search: Row(children: [
        Expanded(
          child: AppSearchField(
            hintText: 'Search notices',
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SizedBox(width: 8.w),
        Tooltip(
          message: 'Refresh',
          child: OutlinedButton(
            onPressed: _fetchNotices,
            style: OutlinedButton.styleFrom(padding: EdgeInsets.symmetric(horizontal: 12.w)),
            child: AppIcon('refresh', size: AppBtn.iconSize(context), color: AppColors.primary),
          ),
        ),
      ]),
      list: _buildNoticeList(visible),
      footer: Text(AppUI.showing(visible.isEmpty ? 0 : 1, visible.length, visible.length), style: AppUI.muted),
      detail: _showCreateForm
          ? _buildCreateForm()
          : (_selectedNotice != null ? _buildNoticeDetail(_selectedNotice!) : null),
      emptyDetail: AppUI.empty(
        icon: 'notification-bing',
        title: 'Select a notice',
        why: 'Pick a notice on the left to read it, or create a new one.',
        action: ElevatedButton.icon(
          onPressed: _openCreate,
          icon: AppIcon('add', size: AppBtn.iconSize(context), color: Colors.white),
          label: const Text('Create Notice'),
        ),
      ),
      showDetail: _showCreateForm || _selectedNotice != null,
      onBack: _closeDetail,
    );
  }

  Widget _buildNoticeList(List<Map<String, dynamic>> visible) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_notices.isEmpty) return _buildEmptyState();
    if (visible.isEmpty) {
      return AppUI.empty(
        icon: 'search-normal',
        title: 'No matching notices',
        why: 'Nothing matches "$_query". Clear the search to see every notice.',
      );
    }
    return AppVerticalScrollbar(
      builder: (context, controller) => ListView.separated(
        controller: controller,
        padding: EdgeInsets.zero,
        itemCount: visible.length,
        separatorBuilder: (_, __) => const Divider(height: 1, thickness: 1, color: AppColors.divider),
        itemBuilder: (context, index) => _buildNoticeCard(visible[index], index),
      ),
    );
  }

  Widget _buildEmptyState() {
    return AppUI.empty(
      icon: 'notification-bing',
      title: 'No notices yet',
      why: 'Notices and announcements will appear here',
      action: ElevatedButton.icon(
        onPressed: _openCreate,
        icon: AppIcon('add', size: AppBtn.iconSize(context), color: Colors.white),
        label: const Text('Create First Notice'),
      ),
    );
  }

  Widget _buildNoticeCard(Map<String, dynamic> notice, [int index = 0]) {
    final title = notice['noticetitle']?.toString() ?? notice['title']?.toString() ?? 'Untitled';
    final desc = notice['noticedesc']?.toString() ?? notice['description']?.toString() ?? '';
    final date = notice['createdat']?.toString() ?? notice['noticedate']?.toString();
    final priority = notice['noticepriority']?.toString() ?? notice['priority']?.toString();
    final category = notice['noticecategory']?.toString() ?? notice['category']?.toString();
    final selected = !_showCreateForm && _selectedNotice != null && _noticeId(_selectedNotice!) == _noticeId(notice);

    final pColor = _priorityColor(priority);
    return Material(
      color: selected ? AppColors.primaryLight : Colors.white,
      child: InkWell(
        onTap: () => setState(() {
          _showCreateForm = false;
          _selectedNotice = notice;
        }),
        hoverColor: AppColors.primaryLight.withValues(alpha: 0.6),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Soft circular icon
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? Colors.white : AppColors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: AppIcon.linear(_categoryIcon(category), size: 16, color: selected ? AppColors.primary : AppColors.textSecondary),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              if (priority != null) ...[
                                Tooltip(
                                  message: '$priority priority',
                                  child: Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(color: pColor, shape: BoxShape.circle),
                                  ),
                                ),
                                SizedBox(width: 6.w),
                              ],
                              Flexible(
                                child: Text(
                                  title,
                                  style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: selected ? AppColors.primary : AppColors.textPrimary, height: 1.2),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 8.w),
                        Text(
                          _timeAgo(date),
                          style: AppUI.muted.copyWith(fontSize: 12.sp),
                        ),
                      ],
                    ),
                    if (desc.isNotEmpty) ...[
                      SizedBox(height: 4.h),
                      Text(
                        desc,
                        style: AppUI.muted.copyWith(color: AppColors.textSecondary, height: 1.4),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNoticeDetail(Map<String, dynamic> notice) {
    final title = notice['noticetitle']?.toString() ?? notice['title']?.toString() ?? 'Untitled';
    final desc = notice['noticedesc']?.toString() ?? notice['description']?.toString() ?? '';
    final date = notice['createdat']?.toString() ?? notice['noticedate']?.toString();
    final priority = notice['noticepriority']?.toString() ?? notice['priority']?.toString();
    final category = notice['noticecategory']?.toString() ?? notice['category']?.toString();
    final createdBy = notice['createdby']?.toString();
    final target = notice['noticetarget']?.toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pane header
        Padding(
          padding: EdgeInsets.fromLTRB(AppUI.cardPad, 14.h, 12.w, 14.h),
          child: Row(
            children: [
              Expanded(child: Text('Notice Details', style: AppUI.cardTitle)),
              if (priority != null) AppUI.chip(priority, _priorityStatus(priority)),
              SizedBox(width: 4.w),
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                onPressed: _closeDetail,
                tooltip: 'Close',
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.divider),

        // Detail body
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(AppUI.cardPad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title row
                Row(
                  children: [
                    AppUI.iconTile(_categoryIcon(category), color: _priorityColor(priority)),
                    SizedBox(width: 12.w),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: AppUI.cardTitle),
                          SizedBox(height: 4.h),
                          Wrap(
                            spacing: 8.w,
                            runSpacing: 4.h,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (category != null) AppUI.chip(category, AppStatus.info),
                              Text(_formatDate(date), style: AppUI.muted.copyWith(color: AppColors.textSecondary)),
                              Text(_timeAgo(date), style: AppUI.muted),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Divider(height: 32, color: AppColors.divider),

                // Description
                Text(desc, style: AppUI.body.copyWith(height: 1.7)),

                if (target != null && target.isNotEmpty) ...[
                  SizedBox(height: 20.h),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const AppIcon.linear('people', size: 16, color: AppColors.textLight),
                      SizedBox(width: 6.w),
                      Text('Audience: ', style: AppUI.muted),
                      Expanded(child: Text(target, style: AppUI.label)),
                    ],
                  ),
                ],

                if (createdBy != null && createdBy.isNotEmpty) ...[
                  SizedBox(height: 12.h),
                  const Divider(color: AppColors.divider),
                  SizedBox(height: 12.h),
                  Row(
                    children: [
                      const AppIcon.linear('user', size: 16, color: AppColors.textLight),
                      SizedBox(width: 6.w),
                      Text('Posted by: ', style: AppUI.muted),
                      Flexible(child: Text(createdBy, style: AppUI.label, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ─── Create Notice Form ──────────────────────────────────────────────────────

  Widget _buildCreateForm() {
    return _CreateNoticeForm(
      onBack: () => setState(() => _showCreateForm = false),
      onCreated: () {
        setState(() => _showCreateForm = false);
        _fetchNotices();
      },
    );
  }
}

// ─── Create Notice Form Widget ─────────────────────────────────────────────────

class _CreateNoticeForm extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onCreated;

  const _CreateNoticeForm({required this.onBack, required this.onCreated});

  @override
  State<_CreateNoticeForm> createState() => _CreateNoticeFormState();
}

class _CreateNoticeFormState extends State<_CreateNoticeForm> {
  final _titleController = TextEditingController();
  final _descController = TextEditingController();
  String? _priority;
  String? _category;
  DateTime? _fromDate;
  DateTime? _toDate;
  String _targetType = 'All Students';
  List<String> _selectedClasses = [];
  List<String> _availableClasses = [];
  bool _isLoadingClasses = false;
  bool _isSending = false;
  Set<String> _pendingFeeTerms = <String>{};
  List<String> _availableFeeTerms = [];
  bool _isLoadingFeeTerms = false;
  final GlobalKey _feeTermPickerKey = GlobalKey();
  // Course → class map. Drives the Course dropdown + scoped class chips
  // for both 'Specific Classes' and 'Pending Fees' target modes.
  Map<String, List<String>> _courseClassMap = {};
  String? _selectedCourse; // null = all courses

  static const _priorities = ['Normal', 'Medium', 'High', 'Urgent'];
  static const _categories = ['General', 'Exam', 'Holiday', 'Event', 'Fee', 'Result'];
  static const _targetTypes = ['All Students', 'Specific Classes', 'Pending Fees', 'Staff'];

  @override
  void initState() {
    super.initState();
    _loadClasses();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _pickDate(bool isFrom) async {
    final initial = isFrom ? (_fromDate ?? DateTime.now()) : (_toDate ?? DateTime.now().add(const Duration(days: 7)));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        if (isFrom) {
          _fromDate = picked;
          if (_toDate != null && _toDate!.isBefore(picked)) _toDate = null;
        } else {
          _toDate = picked;
        }
      });
    }
  }

  Future<void> _loadClasses() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isLoadingClasses = true);
    try {
      final classes = await SupabaseService.getClasses(insId);
      final courseClassMap = await SupabaseService.getCourseClassMap(insId);
      if (mounted) {
        setState(() {
          _availableClasses = classes;
          _courseClassMap = courseClassMap;
          _isLoadingClasses = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading classes: $e');
      if (mounted) setState(() => _isLoadingClasses = false);
    }
  }

  // Classes visible under the currently selected course. Falls back to
  // the full set when no course is picked.
  List<String> get _classesInScope {
    if (_selectedCourse == null) return _availableClasses;
    return _courseClassMap[_selectedCourse] ?? const [];
  }

  /// Same edge / fill / radius / height as [AppUI.field], for the tap-to-pick
  /// controls (dropdown buttons, date and term pickers) on this form.
  BoxDecoration _controlBox(bool filled) => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(color: filled ? AppColors.primary.withValues(alpha: 0.55) : AppColors.border),
      );

  Widget _buildCourseFilterDropdown() {
    final courses = _courseClassMap.keys.toList()..sort();
    final filled = _selectedCourse != null;
    return Container(
      constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: _controlBox(filled),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: _selectedCourse,
          isExpanded: true,
          hint: Text(schoolTerm('Select course'), style: AppUI.fieldText(context)),
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          style: AppUI.fieldText(context),
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
          selectedItemBuilder: (context) => [
            Align(alignment: Alignment.centerLeft, child: Text(schoolTerm('Select course'), style: AppUI.fieldText(context, filled: filled))),
            ...courses.map((c) => Align(alignment: Alignment.centerLeft, child: Text(c, style: AppUI.fieldText(context, filled: true)))),
          ],
          items: [
            DropdownMenuItem<String?>(value: null, child: Text(schoolTerm('Select course'))),
            ...courses.map((c) => DropdownMenuItem<String?>(value: c, child: Text(c))),
          ],
          onChanged: (v) => setState(() {
            _selectedCourse = v;
            // Drop any selected classes that aren't in the new course's
            // scope — otherwise they'd silently stay in `_selectedClasses`
            // even though they no longer appear in the chip list.
            final inScope = (v == null ? _availableClasses : (_courseClassMap[v] ?? const <String>[])).toSet();
            _selectedClasses = _selectedClasses.where(inScope.contains).toList();
          }),
        ),
      ),
    );
  }

  Future<void> _loadFeeTerms() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isLoadingFeeTerms = true);
    try {
      // Only the term column is needed for the dropdown — fetch just that
      // (deduped client-side) instead of pulling every full feedemand row.
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('feedemand')
          .select('demfeeterm')
          .eq('ins_id', insId)
          .eq('activestatus', 1));
      final terms = <String>{};
      for (final d in rows) {
        final term = d['demfeeterm']?.toString() ?? '';
        if (term.isNotEmpty) terms.add(term);
      }
      final termOrder = {
        'I TERM': 0, 'II TERM': 1, 'III TERM': 2,
        'JUNE': 3, 'JULY': 4, 'AUGUST': 5, 'SEPTEMBER': 6,
        'OCTOBER': 7, 'NOVEMBER': 8, 'DECEMBER': 9,
        'JANUARY': 10, 'FEBRUARY': 11, 'MARCH': 12,
        'APRIL': 13, 'MAY': 14,
      };
      final sorted = terms.toList()..sort((a, b) => (termOrder[a] ?? 99).compareTo(termOrder[b] ?? 99));
      if (mounted) setState(() { _availableFeeTerms = sorted; _isLoadingFeeTerms = false; });
    } catch (e) {
      debugPrint('Error loading fee terms: $e');
      if (mounted) setState(() => _isLoadingFeeTerms = false);
    }
  }

  /// Anchored multi-select popup for the Pending Fees term filter.
  /// Drops below the trigger button so it lines up like a dropdown.
  Future<void> _openFeeTermPicker() async {
    final renderBox = _feeTermPickerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final triggerPos = renderBox.localToGlobal(Offset.zero);
    final triggerSize = renderBox.size;
    final screen = MediaQuery.of(context).size;

    const popupWidth = 260.0;
    const popupMaxHeight = 360.0;
    final left = triggerPos.dx.clamp(8.0, (screen.width - popupWidth - 8).clamp(8.0, screen.width));
    final top = (triggerPos.dy + triggerSize.height + 4).clamp(8.0, (screen.height - 100).clamp(8.0, screen.height));

    final tempSelected = Set<String>.from(_pendingFeeTerms);
    final result = await showDialog<Set<String>>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.pop(ctx),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: popupWidth,
            child: StatefulBuilder(builder: (ctx, setLocalState) {
              return Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(12),
                color: Colors.white,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: popupMaxHeight),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text('Select Fee Terms', style: AppUI.label),
                            ),
                            InkWell(
                              onTap: () => setLocalState(() => tempSelected
                                ..clear()
                                ..addAll(_availableFeeTerms)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                child: Text('Select All', style: AppUI.label.copyWith(fontSize: 12.sp, color: AppColors.primary)),
                              ),
                            ),
                            InkWell(
                              onTap: () => setLocalState(tempSelected.clear),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                child: Text('Clear', style: AppUI.label.copyWith(fontSize: 12.sp, color: AppColors.error)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          children: _availableFeeTerms
                              .map((t) => CheckboxListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    controlAffinity: ListTileControlAffinity.leading,
                                    value: tempSelected.contains(t),
                                    title: Text(t, style: AppUI.cell.copyWith(fontSize: 13.sp)),
                                    onChanged: (v) => setLocalState(() {
                                      if (v == true) {
                                        tempSelected.add(t);
                                      } else {
                                        tempSelected.remove(t);
                                      }
                                    }),
                                  ))
                              .toList(),
                        ),
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(ctx, tempSelected),
                              child: const Text('Apply'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
    if (result != null) {
      setState(() => _pendingFeeTerms = result);
    }
  }

  Future<void> _submitNotice() async {
    final title = _titleController.text.trim();
    final desc = _descController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a notice title'), backgroundColor: AppColors.error),
      );
      return;
    }
    if (desc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a notice description'), backgroundColor: AppColors.error),
      );
      return;
    }
    if (_targetType == 'Specific Classes' && _selectedClasses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(schoolTerm('Please select at least one class')), backgroundColor: AppColors.error),
      );
      return;
    }

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final userName = auth.userName ?? 'Admin';
    if (insId == null) return;

    setState(() => _isSending = true);

    try {
      final targetLabel = _targetType == 'All Students'
          ? 'All Students'
          : _targetType == 'Staff'
              ? 'Staff'
              : _targetType == 'Pending Fees'
                  ? 'Pending Fees${_pendingFeeTerms.isNotEmpty ? ' - ${_pendingFeeTerms.join(', ')}' : ''}'
                  : _selectedClasses.join(', ');

      // Insert notice and capture its id so the child notifications can
      // carry notice_id — the cleanup sweep uses that link to delete
      // every related inbox entry when the notice expires.
      final newNoticeId = await SupabaseService.saveSchemaRow('notice', {
        'ins_id': insId,
        'noticetitle': title,
        'noticedesc': desc,
        'noticepriority': _priority ?? 'Normal',
        'noticecategory': _category ?? 'General',
        'noticetarget': targetLabel,
        'createdby': userName,
        'createdat': DateTime.now().toIso8601String(),
        'noticefromdate': _fromDate?.toIso8601String().split('T').first,
        'noticetodate': _toDate?.toIso8601String().split('T').first,
        'activestatus': 1,
      }, pkCol: 'notice_id');

      // Send notification to targeted audience
      List<Map<String, dynamic>> targetStudents = [];
      if (_targetType == 'Staff') {
        // Send to institution users (staff)
        final users = await SupabaseService.getInstitutionUsers(insId);
        if (users.isNotEmpty) {
          final staffNotifications = users.map((u) => {
            'ins_id': insId,
            'stu_id': null,
            'notice_id': newNoticeId,
            'notititle': title,
            'notibody': desc,
            'notitype': 'notice',
            'isread': 0,
            'activestatus': 1,
          }).toList();
          await SupabaseService.fromSchema('notification').insert(staffNotifications);
        }
      } else if (_targetType == 'Pending Fees') {
        // Get students with pending fee balance, optionally filtered by
        // term and / or course / classes. Fetch only the two needed columns
        // and let the server filter balancedue>0 (was: pull every full demand).
        final rows = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('feedemand')
            .select('stu_id, demfeeterm')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .gt('balancedue', 0));
        final pendingStuIds = <int>{};
        for (final d in rows) {
          if (_pendingFeeTerms.isNotEmpty && !_pendingFeeTerms.contains(d['demfeeterm']?.toString() ?? '')) continue;
          final stuId = (d['stu_id'] as num?)?.toInt();
          if (stuId != null) pendingStuIds.add(stuId);
        }
        if (pendingStuIds.isNotEmpty) {
          final allStudents = await SupabaseService.getStudents(insId);
          targetStudents = allStudents
              .where((s) => pendingStuIds.contains(s.stuId))
              .where((s) => _selectedCourse == null || s.courname == _selectedCourse)
              .where((s) => _selectedClasses.isEmpty || _selectedClasses.contains(s.stuclass))
              .map((s) => {'stu_id': s.stuId, 'stuname': s.stuname})
              .toList();
        }
      } else if (_targetType == 'All Students') {
        final allStudents = await SupabaseService.getStudents(insId);
        targetStudents = allStudents.map((s) => {'stu_id': s.stuId, 'stuname': s.stuname}).toList();
      } else {
        // Specific Classes target. If a course was picked, scope to it
        // — otherwise "I Year" matches across all courses, which is
        // almost never what the admin intended in a multi-course school.
        final allStudents = await SupabaseService.getStudents(insId);
        targetStudents = allStudents
            .where((s) => _selectedClasses.contains(s.stuclass))
            .where((s) => _selectedCourse == null || s.courname == _selectedCourse)
            .map((s) => {'stu_id': s.stuId, 'stuname': s.stuname})
            .toList();
      }

      // Batch insert notifications for each student
      if (targetStudents.isNotEmpty) {
        final notifications = targetStudents.map((s) => {
          'ins_id': insId,
          'stu_id': s['stu_id'],
          'notice_id': newNoticeId,
          'notititle': title,
          'notibody': desc,
          'notitype': 'notice',
          'isread': 0,
          'createdat': DateTime.now().toIso8601String(),
          'activestatus': 1,
        }).toList();

        // Insert in batches of 500
        for (var i = 0; i < notifications.length; i += 500) {
          final batch = notifications.sublist(i, i + 500 > notifications.length ? notifications.length : i + 500);
          try {
            await SupabaseService.fromSchema('notification').insert(batch);
          } catch (e) {
            debugPrint('Error inserting notification batch: $e');
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Notice sent to ${targetStudents.length} students'),
            backgroundColor: AppColors.accent,
          ),
        );
        widget.onCreated();
      }
    } catch (e) {
      debugPrint('Error creating notice: $e');
      if (mounted) {
        setState(() => _isSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Lives in the right pane of the notices master-detail: pane header, the
    // scrolling form, then a Cancel + Send footer.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pane header
        Padding(
          padding: EdgeInsets.fromLTRB(AppUI.cardPad, 14.h, AppUI.cardPad, 14.h),
          child: AppUI.cardHeader(icon: 'notification-bing', title: 'Create Notice'),
        ),
        const Divider(height: 1, color: AppColors.divider),

        // Form
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(AppUI.cardPad),
              child: FocusTraversalGroup(
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppUI.sectionLabel('Notice'),
                  // Title
                  AppUI.fieldLabel('Notice Title', required: true),
                  Builder(builder: (context) {
                    final filled = _titleController.text.trim().isNotEmpty;
                    return TextField(
                      controller: _titleController,
                      onChanged: (_) => setState(() {}),
                      decoration: AppUI.field(context, 'Enter notice title', filled: filled),
                      style: AppUI.fieldText(context, filled: filled),
                    );
                  }),
                  SizedBox(height: 20.h),

                  // Target Audience
                  AppUI.sectionLabel('Audience'),
                  AppUI.fieldLabel('Target Audience'),
                  Wrap(
                    runSpacing: 10,
                    children: _targetTypes.map((t) {
                      final isSelected = _targetType == t;
                      return Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: FocusableTap(
                          borderRadius: BorderRadius.circular(8.r),
                          onTap: () {
                            setState(() {
                              _targetType = t;
                              if (t != 'Specific Classes' && t != 'Pending Fees') {
                                _selectedClasses.clear();
                                _selectedCourse = null;
                              }
                              if (t != 'Pending Fees') _pendingFeeTerms.clear();
                            });
                            if (t == 'Pending Fees' && _availableFeeTerms.isEmpty) _loadFeeTerms();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: isSelected ? AppColors.primaryLight : Colors.white,
                              borderRadius: BorderRadius.circular(AppUI.controlRadius),
                              border: Border.all(color: isSelected ? AppColors.primary : AppColors.border),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AppIcon(
                                  t == 'All Students' ? 'profile-2user' : t == 'Staff' ? 'personalcard' : t == 'Pending Fees' ? 'timer' : 'book-1',
                                  size: 16,
                                  color: isSelected ? AppColors.primary : AppColors.textSecondary,
                                ),
                                SizedBox(width: 6.w),
                                Text(schoolTerm(t), style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: isSelected ? AppColors.primary : AppColors.textSecondary)),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),

                  // Class selection (shown when Specific Classes is selected)
                  if (_targetType == 'Specific Classes') ...[
                    SizedBox(height: 12.h),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Course dropdown — narrows the class chips below
                          // so admins of multi-course institutions don't
                          // pick the wrong "I Year" by accident.
                          _buildCourseFilterDropdown(),
                          // Hide the class chip list until a specific course
                          // is picked — showing every class up front (from
                          // every course) is overwhelming and invites picking
                          // the wrong "Year I" across courses.
                          if (_selectedCourse == null) ...[
                            SizedBox(height: 12.h),
                            Text(
                              schoolTerm('Select a course above to choose classes.'),
                              style: AppUI.muted,
                            ),
                          ] else ...[
                          SizedBox(height: 12.h),
                          Row(
                            children: [
                              Text(schoolTerm('Select Classes'), style: AppUI.label),
                              const Spacer(),
                              if (_selectedClasses.isNotEmpty)
                                FocusableTap(
                                  onTap: () => setState(() => _selectedClasses.clear()),
                                  child: Text('Clear All', style: AppUI.label.copyWith(color: AppColors.error)),
                                ),
                              SizedBox(width: 12.w),
                              FocusableTap(
                                onTap: () => setState(() => _selectedClasses = List.from(_classesInScope)),
                                child: Text('Select All', style: AppUI.label.copyWith(color: AppColors.primary)),
                              ),
                            ],
                          ),
                          SizedBox(height: 12.h),
                          _isLoadingClasses
                              ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                              : Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: _classesInScope.map((cls) {
                                    final isSelected = _selectedClasses.contains(cls);
                                    return FocusableTap(
                                      borderRadius: BorderRadius.circular(8.r),
                                      onTap: () {
                                        setState(() {
                                          if (isSelected) {
                                            _selectedClasses.remove(cls);
                                          } else {
                                            _selectedClasses.add(cls);
                                          }
                                        });
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: isSelected ? AppColors.primaryLight : Colors.white,
                                          borderRadius: BorderRadius.circular(AppUI.controlRadius),
                                          border: Border.all(color: isSelected ? AppColors.primary : AppColors.border),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            AppIcon(
                                              isSelected ? 'tick-square' : 'stop',
                                              size: 16,
                                              color: isSelected ? AppColors.accent : AppColors.textSecondary,
                                            ),
                                            SizedBox(width: 6.w),
                                            Text(cls, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: isSelected ? AppColors.accent : AppColors.textPrimary)),
                                          ],
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                          if (_selectedClasses.isNotEmpty) ...[
                            SizedBox(height: 10.h),
                            Text(schoolTerm('${_selectedClasses.length} class${_selectedClasses.length > 1 ? 'es' : ''} selected'),
                                style: AppUI.label.copyWith(color: AppColors.primary)),
                          ],
                          ],
                        ],
                      ),
                    ),
                  ],

                  // Fee term + course/class filter (Pending Fees target)
                  if (_targetType == 'Pending Fees') ...[
                    SizedBox(height: 12.h),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Course narrows the class chips below; class chips
                          // narrow which pending-fee students get the notice.
                          AppUI.fieldLabel(schoolTerm('Filter by Course')),
                          _buildCourseFilterDropdown(),
                          if (_selectedCourse != null) ...[
                            SizedBox(height: 12.h),
                            Row(
                              children: [
                                Text(schoolTerm('Filter by Class'), style: AppUI.label),
                                const Spacer(),
                                if (_selectedClasses.isNotEmpty)
                                  FocusableTap(
                                    onTap: () => setState(() => _selectedClasses.clear()),
                                    child: Text('Clear', style: AppUI.label.copyWith(color: AppColors.error)),
                                  ),
                              ],
                            ),
                            SizedBox(height: 8.h),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _classesInScope.map((cls) {
                                final isSelected = _selectedClasses.contains(cls);
                                return FocusableTap(
                                  borderRadius: BorderRadius.circular(8.r),
                                  onTap: () => setState(() {
                                    if (isSelected) {
                                      _selectedClasses.remove(cls);
                                    } else {
                                      _selectedClasses.add(cls);
                                    }
                                  }),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: isSelected ? AppColors.primaryLight : Colors.white,
                                      borderRadius: BorderRadius.circular(AppUI.controlRadius),
                                      border: Border.all(color: isSelected ? AppColors.primary : AppColors.border),
                                    ),
                                    child: Text(cls, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: isSelected ? AppColors.primary : AppColors.textPrimary)),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                          SizedBox(height: 12.h),
                          AppUI.fieldLabel('Filter by Fee Term'),
                          _isLoadingFeeTerms
                              ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                              : InkWell(
                                  key: _feeTermPickerKey,
                                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                                  onTap: _openFeeTermPicker,
                                  child: Container(
                                    constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    decoration: _controlBox(_pendingFeeTerms.isNotEmpty),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _pendingFeeTerms.isEmpty
                                                ? 'All Terms'
                                                : _pendingFeeTerms.length == 1
                                                    ? _pendingFeeTerms.first
                                                    : '${_pendingFeeTerms.length} terms',
                                            style: AppUI.fieldText(context, filled: _pendingFeeTerms.isNotEmpty),
                                          ),
                                        ),
                                        const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                                      ],
                                    ),
                                  ),
                                ),
                        ],
                      ),
                    ),
                  ],
                  SizedBox(height: 20.h),

                  // Description
                  AppUI.sectionLabel('Details'),
                  AppUI.fieldLabel('Description', required: true),
                  Builder(builder: (context) {
                    final filled = _descController.text.trim().isNotEmpty;
                    return TextField(
                      controller: _descController,
                      maxLines: 5,
                      onChanged: (_) => setState(() {}),
                      decoration: AppUI.field(context, 'Enter notice description', filled: filled),
                      style: AppUI.fieldText(context, filled: filled),
                    );
                  }),
                  SizedBox(height: 20.h),

                  // Priority & Category row
                  Row(
                    children: [
                      Expanded(child: _buildDropdown('Priority', _priority, _priorities, (v) => setState(() => _priority = v))),
                      SizedBox(width: 16.w),
                      Expanded(child: _buildDropdown('Category', _category, _categories, (v) => setState(() => _category = v))),
                    ],
                  ),
                  SizedBox(height: 20.h),

                  // From Date & To Date row
                  AppUI.sectionLabel('Schedule'),
                  Row(
                    children: [
                      Expanded(child: _buildDatePicker('Start Date', _fromDate, (d) => setState(() => _fromDate = d), hint: 'Select start date')),
                      SizedBox(width: 16.w),
                      Expanded(child: _buildDatePicker('End Date', _toDate, (d) => setState(() => _toDate = d), hint: 'Select end date')),
                    ],
                  ),

                  SizedBox(height: 20.h),

                  // From / To Date
                  AppUI.fieldLabel('Notice Period'),
                  Row(
                    children: [
                      Expanded(
                        child: FocusableTap(
                          onTap: () => _pickDate(true),
                          child: Container(
                            constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: _controlBox(_fromDate != null),
                            child: Row(
                              children: [
                                AppIcon.linear('calendar-1', size: 16, color: _fromDate != null ? AppColors.primary : AppColors.textLight),
                                SizedBox(width: 8.w),
                                Text(
                                  _fromDate != null
                                      ? formatDmy(_fromDate)
                                      : 'Select start date',
                                  style: _fromDate != null ? AppUI.fieldText(context, filled: true) : AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('—', style: TextStyle(color: AppColors.textSecondary)),
                      ),
                      Expanded(
                        child: FocusableTap(
                          onTap: () => _pickDate(false),
                          child: Container(
                            constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: _controlBox(_toDate != null),
                            child: Row(
                              children: [
                                AppIcon.linear('calendar-remove', size: 16, color: _toDate != null ? AppColors.primary : AppColors.textLight),
                                SizedBox(width: 8.w),
                                Text(
                                  _toDate != null
                                      ? formatDmy(_toDate)
                                      : 'Select end date (notice expires after it)',
                                  style: _toDate != null ? AppUI.fieldText(context, filled: true) : AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 6.h),
                  Text(
                    'The notice is removed automatically after the end date.',
                    style: AppUI.muted,
                  ),

                  SizedBox(height: AppUI.gap),

                  // Preview section
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.cardBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppUI.sectionLabel('Preview'),
                        const Divider(height: 1, color: AppColors.divider),
                        SizedBox(height: 12.h),
                        Row(
                          children: [
                            AppUI.chip(_priority ?? 'Normal', _priorityStatusForPreview),
                            SizedBox(width: 8.w),
                            AppUI.chip(_category ?? 'General', AppStatus.neutral),
                            SizedBox(width: 8.w),
                            const AppIcon.linear('people', size: 14, color: AppColors.textLight),
                            SizedBox(width: 4.w),
                            Flexible(
                              child: Text(
                                _targetType == 'All Students' ? 'All Students' : _targetType == 'Staff' ? 'Staff' : _targetType == 'Pending Fees' ? 'Pending Fees${_pendingFeeTerms.isNotEmpty ? ' - ${_pendingFeeTerms.join(', ')}' : ''}' : schoolTerm('${_selectedClasses.length} classes'),
                                style: AppUI.muted,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 10.h),
                        Text(
                          _titleController.text.isEmpty ? 'Notice title...' : _titleController.text,
                          style: TextStyle(
                            fontSize: 14.sp,
                            fontWeight: FontWeight.w700,
                            color: _titleController.text.isEmpty ? AppColors.textLight : AppColors.textPrimary,
                          ),
                        ),
                        SizedBox(height: 6.h),
                        Text(
                          _descController.text.isEmpty ? 'Notice description...' : _descController.text,
                          style: TextStyle(
                            fontSize: 13.sp,
                            height: 1.4,
                            color: _descController.text.isEmpty ? AppColors.textLight : AppColors.textSecondary,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              ),
          ),
        ),

        // Footer: Cancel (= the old Back) + Send Notice
        AppFormFooter(
          note: AppText.requiredNote,
          onCancel: _isSending ? null : widget.onBack,
          actions: [
            ElevatedButton.icon(
              onPressed: _isSending ? null : _submitNotice,
              icon: _isSending
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : AppIcon('send-2', size: AppBtn.iconSize(context), color: Colors.white),
              label: const Text('Send Notice'),
            ),
          ],
        ),
      ],
    );
  }

  AppStatus get _priorityStatusForPreview {
    switch ((_priority ?? 'Normal').toLowerCase()) {
      case 'high':
      case 'urgent':
        return AppStatus.danger;
      case 'medium':
        return AppStatus.warning;
      default:
        return AppStatus.info;
    }
  }

  String _formatDateDisplay(DateTime date) => formatDmy(date);

  Widget _buildDatePicker(String label, DateTime? selectedDate, ValueChanged<DateTime> onSelected, {String hint = 'Select date'}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppUI.fieldLabel(label),
        FocusableTap(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: selectedDate ?? DateTime.now(),
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
            );
            if (picked != null) onSelected(picked);
          },
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: _controlBox(selectedDate != null),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    selectedDate != null ? _formatDateDisplay(selectedDate) : hint,
                    style: selectedDate != null
                        ? AppUI.fieldText(context, filled: true)
                        : AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight),
                  ),
                ),
                AppIcon.linear('calendar-1', size: 16, color: selectedDate != null ? AppColors.primary : AppColors.textLight),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDropdown(String label, String? value, List<String> items, ValueChanged<String?> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppUI.fieldLabel(label),
        Container(
          constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: _controlBox(value != null),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              hint: Text('Select ${label.toLowerCase()}', style: AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight)),
              icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              style: AppUI.fieldText(context),
              selectedItemBuilder: (context) => items.map((i) => Align(alignment: Alignment.centerLeft, child: Text(i, style: AppUI.fieldText(context, filled: true)))).toList(),
              items: items.map((i) => DropdownMenuItem(value: i, child: Text(i))).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
