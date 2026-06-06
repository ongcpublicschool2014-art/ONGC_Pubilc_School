import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../utils/friendly_error.dart';
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
      return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
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
      if (diff.inMinutes > 0) return '${diff.inMinutes} min ago';
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

  @override
  Widget build(BuildContext context) {
    if (_showCreateForm) return _buildCreateForm();
    if (_selectedNotice != null) return _buildNoticeDetail(_selectedNotice!);
    return _buildNoticeList();
  }

  Widget _buildNoticeList() {
    Widget headerBar() => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              AppIcon('volume-high', color: AppColors.accent, size: 18),
              SizedBox(width: 10.w),
              Text('Notices & Announcements', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: Text('${_notices.length} notices', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
              ),
              SizedBox(width: AppBtn.gap(context)),
              SizedBox(
                height: AppBtn.height(context),
                child: ElevatedButton.icon(
                  onPressed: () => setState(() => _showCreateForm = true),
                  icon: AppIcon('add', size: AppBtn.iconSize(context), color: Colors.white),
                  label: Text('Create Notice', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                  ),
                ),
              ),
              SizedBox(width: AppBtn.gap(context)),
              SizedBox(
                height: AppBtn.height(context),
                child: ElevatedButton.icon(
                  onPressed: _fetchNotices,
                  icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                  label: const Text('Refresh'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        );

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          headerBar(),
          // Inner card holding zebra-striped notice rows. Same outer/inner
          // card layout as the report-page tables and the Notifications page.
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(12.w, 0, 12.w, 12.h),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10.r),
                  border: Border.all(color: AppColors.border),
                ),
                child: AppVerticalScrollbar(
                  builder: (context, controller) => _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _notices.isEmpty
                        ? _buildEmptyState()
                        : ListView.separated(
                            controller: controller,
                            padding: EdgeInsets.zero,
                            itemCount: _notices.length,
                            separatorBuilder: (_, __) => Divider(height: 1, thickness: 1, color: AppColors.border.withValues(alpha: 0.6)),
                            itemBuilder: (context, index) => _buildNoticeCard(_notices[index], index),
                          ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon('notification-bing', size: 64, color: AppColors.textSecondary.withValues(alpha: 0.3)),
          SizedBox(height: 16.h),
          Text('No notices yet', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
          SizedBox(height: 6.h),
          Text('Notices and announcements will appear here', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
          SizedBox(height: 20.h),
          ElevatedButton.icon(
            onPressed: () => setState(() => _showCreateForm = true),
            icon: const AppIcon('add', size: 18),
            label: const Text('Create First Notice'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoticeCard(Map<String, dynamic> notice, [int index = 0]) {
    final title = notice['noticetitle']?.toString() ?? notice['title']?.toString() ?? 'Untitled';
    final desc = notice['noticedesc']?.toString() ?? notice['description']?.toString() ?? '';
    final date = notice['createdat']?.toString() ?? notice['noticedate']?.toString();
    final priority = notice['noticepriority']?.toString() ?? notice['priority']?.toString();
    final category = notice['noticecategory']?.toString() ?? notice['category']?.toString();

    final pColor = _priorityColor(priority);
    return InkWell(
      onTap: () => setState(() => _selectedNotice = notice),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 14.h),
        color: index.isEven ? Colors.white : AppColors.surface,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Soft circular icon
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.border.withValues(alpha: 0.6)),
              ),
              child: AppIcon.linear(_categoryIcon(category), size: 18, color: AppColors.textSecondary),
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
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(color: pColor, shape: BoxShape.circle),
                              ),
                              SizedBox(width: 6.w),
                            ],
                            Flexible(
                              child: Text(
                                title,
                                style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, height: 1.2),
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
                        style: TextStyle(
                          fontSize: 11.sp,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                  if (desc.isNotEmpty) ...[
                    SizedBox(height: 4.h),
                    Text(
                      desc,
                      style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary, height: 1.4),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(width: 10.w),
            Padding(
              padding: EdgeInsets.only(top: 2.h),
              child: const AppIcon.linear('Chevron Right', size: 16, color: AppColors.textSecondary),
            ),
          ],
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Back header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const AppIcon.linear('Chevron Left', size: 20),
                onPressed: () => setState(() => _selectedNotice = null),
                tooltip: 'Back to notices',
              ),
              SizedBox(width: 4.w),
              Text('Notice Details', style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (priority != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _priorityColor(priority).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  child: Text(priority, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: _priorityColor(priority))),
                ),
            ],
          ),
        ),
        SizedBox(height: 16.h),

        // Detail card
        Expanded(
          child: SingleChildScrollView(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10.r),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title row
                  Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: _priorityColor(priority).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6.r),
                        ),
                        child: AppIcon(_categoryIcon(category), size: 12, color: _priorityColor(priority)),
                      ),
                      SizedBox(width: 16.w),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: TextStyle(fontSize: 18.sp, fontWeight: FontWeight.w700)),
                            SizedBox(height: 4.h),
                            Row(
                              children: [
                                if (category != null) ...[
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppColors.accent.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(6.r),
                                    ),
                                    child: Text(category, style: TextStyle(fontSize: 10.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
                                  ),
                                  SizedBox(width: 10.w),
                                ],
                                Text(_formatDate(date), style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                                SizedBox(width: 8.w),
                                Text(_timeAgo(date), style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary.withValues(alpha: 0.6))),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 32, color: AppColors.border),

                  // Description
                  Text(desc, style: TextStyle(fontSize: 14.sp, height: 1.7, color: AppColors.textPrimary)),

                  if (target != null && target.isNotEmpty) ...[
                    SizedBox(height: 20.h),
                    Row(
                      children: [
                        const AppIcon('people', size: 16, color: AppColors.textSecondary),
                        SizedBox(width: 6.w),
                        Text('Target: ', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                        Text(target, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ],

                  if (createdBy != null && createdBy.isNotEmpty) ...[
                    SizedBox(height: 12.h),
                    const Divider(color: AppColors.border),
                    SizedBox(height: 12.h),
                    Row(
                      children: [
                        const AppIcon('user', size: 16, color: AppColors.textSecondary),
                        SizedBox(width: 6.w),
                        Text('Posted by: ', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                        Text(createdBy, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ],
                ],
              ),
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
  String _priority = 'Normal';
  String _category = 'General';
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

  Widget _buildCourseFilterDropdown() {
    final courses = _courseClassMap.keys.toList()..sort();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: _selectedCourse,
          isExpanded: true,
          hint: Text('All Standards', style: TextStyle(fontSize: 13.sp)),
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
          icon: const AppIcon.linear('Chevron Down', size: 18),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('All Standards')),
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
      final demands = await SupabaseService.getFeeDemands(insId);
      final terms = <String>{};
      for (final d in demands) {
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
                borderRadius: BorderRadius.circular(8),
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
                            const Expanded(
                              child: Text('Select Fee Terms', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                            ),
                            InkWell(
                              onTap: () => setLocalState(() => tempSelected
                                ..clear()
                                ..addAll(_availableFeeTerms)),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                child: Text('Select All', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                              ),
                            ),
                            InkWell(
                              onTap: () => setLocalState(tempSelected.clear),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                child: Text('Clear', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
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
                                    title: Text(t, style: const TextStyle(fontSize: 12)),
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
        const SnackBar(content: Text('Please select at least one class'), backgroundColor: AppColors.error),
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
      final insertedNotice = await SupabaseService.fromSchema('notice').insert({
        'ins_id': insId,
        'noticetitle': title,
        'noticedesc': desc,
        'noticepriority': _priority,
        'noticecategory': _category,
        'noticetarget': targetLabel,
        'createdby': userName,
        'createdat': DateTime.now().toIso8601String(),
        'noticefromdate': _fromDate?.toIso8601String().split('T').first,
        'noticetodate': _toDate?.toIso8601String().split('T').first,
        'activestatus': 1,
      }).select('notice_id').single();
      final newNoticeId = insertedNotice['notice_id'] as int?;

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
        // term and / or course / classes.
        final demands = await SupabaseService.getFeeDemands(insId);
        final pendingStuIds = <int>{};
        for (final d in demands) {
          final balance = (d['balancedue'] as num?)?.toDouble() ?? 0;
          if (balance > 0) {
            if (_pendingFeeTerms.isNotEmpty && !_pendingFeeTerms.contains(d['demfeeterm']?.toString() ?? '')) continue;
            final stuId = d['stu_id'] as int?;
            if (stuId != null) pendingStuIds.add(stuId);
          }
        }
        if (pendingStuIds.isNotEmpty) {
          final allStudents = await SupabaseService.getStudents(insId);
          targetStudents = allStudents
              .where((s) => pendingStuIds.contains(s.stuId))
              .where((s) => _selectedCourse == null || s.clagrpname == _selectedCourse)
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
            .where((s) => _selectedCourse == null || s.clagrpname == _selectedCourse)
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
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const AppIcon.linear('Chevron Left', size: 20),
                onPressed: widget.onBack,
                tooltip: 'Back to notices',
              ),
              SizedBox(width: 4.w),
              const AppIcon('notification-bing', size: 20, color: AppColors.accent),
              SizedBox(width: 8.w),
              Text('Create Notice', style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (_isSending)
                SizedBox(width: 20.w, height: 20.h, child: CircularProgressIndicator(strokeWidth: 2))
              else
                ElevatedButton.icon(
                  onPressed: _submitNotice,
                  icon: const AppIcon('send-2', size: 16),
                  label: Text('Send Notice', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                    elevation: 0,
                    textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(height: 16.h),

        // Form
        Expanded(
          child: SingleChildScrollView(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10.r),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  Text('Notice Title', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                  SizedBox(height: 8.h),
                  TextField(
                    controller: _titleController,
                    decoration: InputDecoration(
                      hintText: 'Enter notice title...',
                      hintStyle: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.5), fontSize: 13),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10.r), borderSide: const BorderSide(color: AppColors.border)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10.r), borderSide: const BorderSide(color: AppColors.border)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10.r), borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    style: TextStyle(fontSize: 14.sp),
                  ),
                  SizedBox(height: 20.h),

                  // Target Audience
                  Text('Target Audience', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                  SizedBox(height: 8.h),
                  Row(
                    children: _targetTypes.map((t) {
                      final isSelected = _targetType == t;
                      return Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: GestureDetector(
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
                              color: isSelected ? AppColors.accent : Colors.white,
                              borderRadius: BorderRadius.circular(8.r),
                              border: Border.all(color: isSelected ? AppColors.accent : AppColors.border),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AppIcon(
                                  t == 'All Students' ? 'profile-2user' : t == 'Staff' ? 'personalcard' : t == 'Pending Fees' ? 'timer' : 'book-1',
                                  size: 16,
                                  color: isSelected ? Colors.white : AppColors.textSecondary,
                                ),
                                SizedBox(width: 6.w),
                                Text(t, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: isSelected ? Colors.white : AppColors.textSecondary)),
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
                        borderRadius: BorderRadius.circular(10.r),
                        border: Border.all(color: AppColors.border),
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
                              'Select a standard above to choose classes.',
                              style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary, fontStyle: FontStyle.italic),
                            ),
                          ] else ...[
                          SizedBox(height: 12.h),
                          Row(
                            children: [
                              Text('Select Classes', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                              const Spacer(),
                              if (_selectedClasses.isNotEmpty)
                                GestureDetector(
                                  onTap: () => setState(() => _selectedClasses.clear()),
                                  child: Text('Clear all', style: TextStyle(fontSize: 13.sp, color: AppColors.error, fontWeight: FontWeight.w500)),
                                ),
                              SizedBox(width: 12.w),
                              GestureDetector(
                                onTap: () => setState(() => _selectedClasses = List.from(_classesInScope)),
                                child: Text('Select all', style: TextStyle(fontSize: 13.sp, color: AppColors.accent, fontWeight: FontWeight.w500)),
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
                                    return GestureDetector(
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
                                          color: isSelected ? AppColors.accent.withValues(alpha: 0.1) : Colors.white,
                                          borderRadius: BorderRadius.circular(8.r),
                                          border: Border.all(color: isSelected ? AppColors.accent : AppColors.border),
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
                            Text('${_selectedClasses.length} class${_selectedClasses.length > 1 ? 'es' : ''} selected',
                                style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.accent)),
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
                        borderRadius: BorderRadius.circular(10.r),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Course narrows the class chips below; class chips
                          // narrow which pending-fee students get the notice.
                          Text('Filter by Standard', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                          SizedBox(height: 8.h),
                          _buildCourseFilterDropdown(),
                          if (_selectedCourse != null) ...[
                            SizedBox(height: 12.h),
                            Row(
                              children: [
                                Text('Filter by Class', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                                const Spacer(),
                                if (_selectedClasses.isNotEmpty)
                                  GestureDetector(
                                    onTap: () => setState(() => _selectedClasses.clear()),
                                    child: Text('Clear', style: TextStyle(fontSize: 13.sp, color: AppColors.error, fontWeight: FontWeight.w500)),
                                  ),
                              ],
                            ),
                            SizedBox(height: 8.h),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _classesInScope.map((cls) {
                                final isSelected = _selectedClasses.contains(cls);
                                return GestureDetector(
                                  onTap: () => setState(() {
                                    if (isSelected) {
                                      _selectedClasses.remove(cls);
                                    } else {
                                      _selectedClasses.add(cls);
                                    }
                                  }),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: isSelected ? AppColors.accent.withValues(alpha: 0.1) : Colors.white,
                                      borderRadius: BorderRadius.circular(8.r),
                                      border: Border.all(color: isSelected ? AppColors.accent : AppColors.border),
                                    ),
                                    child: Text(cls, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: isSelected ? AppColors.accent : AppColors.textPrimary)),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                          SizedBox(height: 12.h),
                          Text('Filter by Fee Term', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                          SizedBox(height: 8.h),
                          _isLoadingFeeTerms
                              ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                              : InkWell(
                                  key: _feeTermPickerKey,
                                  borderRadius: BorderRadius.circular(8.r),
                                  onTap: _openFeeTermPicker,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(8.r),
                                      border: Border.all(color: AppColors.border),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _pendingFeeTerms.isEmpty
                                                ? 'All Terms'
                                                : _pendingFeeTerms.length == 1
                                                    ? _pendingFeeTerms.first
                                                    : '${_pendingFeeTerms.length} terms',
                                            style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary, fontWeight: FontWeight.w500),
                                          ),
                                        ),
                                        const AppIcon.linear('Chevron Down', size: 18),
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
                  Text('Description', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                  SizedBox(height: 8.h),
                  TextField(
                    controller: _descController,
                    maxLines: 5,
                    decoration: InputDecoration(
                      hintText: 'Enter notice description...',
                      hintStyle: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.5), fontSize: 13),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10.r), borderSide: const BorderSide(color: AppColors.border)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10.r), borderSide: const BorderSide(color: AppColors.border)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10.r), borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    style: TextStyle(fontSize: 14.sp),
                  ),
                  SizedBox(height: 20.h),

                  // Priority & Category row
                  Row(
                    children: [
                      Expanded(child: _buildDropdown('Priority', _priority, _priorities, (v) => setState(() => _priority = v!))),
                      SizedBox(width: 16.w),
                      Expanded(child: _buildDropdown('Category', _category, _categories, (v) => setState(() => _category = v!))),
                    ],
                  ),
                  SizedBox(height: 20.h),

                  // From Date & To Date row
                  Row(
                    children: [
                      Expanded(child: _buildDatePicker('From Date', _fromDate, (d) => setState(() => _fromDate = d))),
                      SizedBox(width: 16.w),
                      Expanded(child: _buildDatePicker('To Date', _toDate, (d) => setState(() => _toDate = d))),
                    ],
                  ),

                  SizedBox(height: 20.h),

                  // From / To Date
                  Text('Notice Period', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                  SizedBox(height: 8.h),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _pickDate(true),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              border: Border.all(color: _fromDate != null ? AppColors.accent : AppColors.border),
                              borderRadius: BorderRadius.circular(10.r),
                              color: AppColors.surface,
                            ),
                            child: Row(
                              children: [
                                AppIcon('calendar-1', size: 15, color: _fromDate != null ? AppColors.accent : AppColors.textSecondary),
                                SizedBox(width: 8.w),
                                Text(
                                  _fromDate != null
                                      ? '${_fromDate!.day.toString().padLeft(2,'0')}/${_fromDate!.month.toString().padLeft(2,'0')}/${_fromDate!.year}'
                                      : 'From Date',
                                  style: TextStyle(fontSize: 13.sp, color: _fromDate != null ? AppColors.textPrimary : AppColors.textSecondary),
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
                        child: GestureDetector(
                          onTap: () => _pickDate(false),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              border: Border.all(color: _toDate != null ? AppColors.error : AppColors.border),
                              borderRadius: BorderRadius.circular(10.r),
                              color: AppColors.surface,
                            ),
                            child: Row(
                              children: [
                                AppIcon('calendar-remove', size: 15, color: _toDate != null ? AppColors.error : AppColors.textSecondary),
                                SizedBox(width: 8.w),
                                Text(
                                  _toDate != null
                                      ? '${_toDate!.day.toString().padLeft(2,'0')}/${_toDate!.month.toString().padLeft(2,'0')}/${_toDate!.year}'
                                      : 'To Date (Auto-expire)',
                                  style: TextStyle(fontSize: 13.sp, color: _toDate != null ? AppColors.textPrimary : AppColors.textSecondary),
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
                    'Notice will be automatically removed after the To Date.',
                    style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary),
                  ),

                  SizedBox(height: 28.h),

                  // Preview section
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(10.r),
                      border: Border.all(color: AppColors.accent.withValues(alpha: 0.15)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const AppIcon('eye', size: 16, color: AppColors.accent),
                            SizedBox(width: 6.w),
                            Text('Preview', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.accent)),
                          ],
                        ),
                        const Divider(height: 20, color: AppColors.border),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: _priorityColorForPreview.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6.r),
                              ),
                              child: Text(_priority, style: TextStyle(fontSize: 10.sp, fontWeight: FontWeight.w600, color: _priorityColorForPreview)),
                            ),
                            SizedBox(width: 8.w),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(6.r),
                              ),
                              child: Text(_category, style: TextStyle(fontSize: 10.sp, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
                            ),
                            SizedBox(width: 8.w),
                            AppIcon('people', size: 12, color: AppColors.textSecondary.withValues(alpha: 0.6)),
                            SizedBox(width: 4.w),
                            Text(
                              _targetType == 'All Students' ? 'All Students' : _targetType == 'Staff' ? 'Staff' : _targetType == 'Pending Fees' ? 'Pending Fees${_pendingFeeTerms.isNotEmpty ? ' - ${_pendingFeeTerms.join(', ')}' : ''}' : '${_selectedClasses.length} classes',
                              style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary.withValues(alpha: 0.7)),
                            ),
                          ],
                        ),
                        SizedBox(height: 10.h),
                        Text(
                          _titleController.text.isEmpty ? 'Notice title...' : _titleController.text,
                          style: TextStyle(
                            fontSize: 14.sp,
                            fontWeight: FontWeight.w700,
                            color: _titleController.text.isEmpty ? AppColors.textSecondary.withValues(alpha: 0.4) : AppColors.textPrimary,
                          ),
                        ),
                        SizedBox(height: 6.h),
                        Text(
                          _descController.text.isEmpty ? 'Notice description...' : _descController.text,
                          style: TextStyle(
                            fontSize: 13.sp,
                            height: 1.4,
                            color: _descController.text.isEmpty ? AppColors.textSecondary.withValues(alpha: 0.4) : AppColors.textSecondary,
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
      ],
    );
  }

  Color get _priorityColorForPreview {
    switch (_priority.toLowerCase()) {
      case 'high':
      case 'urgent':
        return AppColors.error;
      case 'medium':
        return AppColors.warning;
      default:
        return AppColors.accent;
    }
  }

  String _formatDateDisplay(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  Widget _buildDatePicker(String label, DateTime? selectedDate, ValueChanged<DateTime> onSelected) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
        SizedBox(height: 8.h),
        GestureDetector(
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10.r),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    selectedDate != null ? _formatDateDisplay(selectedDate) : 'Select date...',
                    style: TextStyle(
                      fontSize: 13.sp,
                      color: selectedDate != null ? AppColors.textPrimary : AppColors.textSecondary.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                AppIcon('calendar-1', size: 16, color: AppColors.textSecondary.withValues(alpha: 0.6)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDropdown(String label, String value, List<String> items, ValueChanged<String?> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
        SizedBox(height: 8.h),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(color: AppColors.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
              items: items.map((i) => DropdownMenuItem(value: i, child: Text(i))).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
