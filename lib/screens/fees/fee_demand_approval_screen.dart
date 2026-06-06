import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../utils/friendly_error.dart';
import '../../utils/formatters.dart';
class FeeDemandApprovalScreen extends StatefulWidget {
  const FeeDemandApprovalScreen({super.key});

  @override
  State<FeeDemandApprovalScreen> createState() =>
      _FeeDemandApprovalScreenState();
}

class _FeeDemandApprovalScreenState extends State<FeeDemandApprovalScreen> {
  List<Map<String, dynamic>> _demands = [];
  bool _loading = false;
  String? _errorMsg;

  // selected by dem_id (as String)
  final Set<String> _selected = {};

  bool _approving = false;

  final _searchController = TextEditingController();
  String _searchQuery = '';
  String? _selectedClass; // null = All Classes

  final _hScrollController = ScrollController();
  // Vertical scroll for the body rows — its scrollbar sits in a pinned lane
  // so it stays reachable without scrolling the table horizontally.
  final _vScrollController = ScrollController();

  // Pagination
  int _currentPage = 1;
  static const int _pageSize = 25;

  // Predefined class order
  static const _classOrder = [
    'PKG', 'LKG', 'UKG',
    'I', 'II', 'III', 'IV', 'V', 'VI',
    'VII', 'VIII', 'IX', 'X', 'XI', 'XII',
  ];

  // Unique class list sorted by predefined order (unknowns appended at end)
  List<String> get _classList {
    final present = _demands
        .map((d) => d['stuclass']?.toString() ?? '')
        .where((c) => c.isNotEmpty && c != '-')
        .toSet();
    final ordered = _classOrder.where(present.contains).toList();
    final rest = present.difference(ordered.toSet()).toList()..sort();
    return [...ordered, ...rest];
  }

  @override
  void initState() {
    super.initState();
    _loadDemands();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _hScrollController.dispose();
    _vScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadDemands() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() {
      _loading = true;
      _errorMsg = null;
      _selected.clear();
    });

    try {
      final raw = await SupabaseService.getFeeDemandsPending(insId);
      // Stamp each row with a guaranteed unique key (_idx) as fallback
      final demands = raw.asMap().entries.map((e) {
        return {...e.value, '_idx': e.key.toString()};
      }).toList();
      if (mounted) {
        setState(() {
          _demands = demands;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMsg = friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> get _filteredDemands {
    return _demands.where((d) {
      if (_selectedClass != null) {
        if ((d['stuclass']?.toString() ?? '') != _selectedClass) return false;
      }
      if (_searchQuery.isNotEmpty) {
        final admNo = d['stuadmno']?.toString().toLowerCase() ?? '';
        final name =
            (d['stuname'] ?? d['studentname'] ?? '').toString().toLowerCase();
        if (!admNo.contains(_searchQuery) && !name.contains(_searchQuery)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  int get _totalPages {
    final count = _filteredDemands.length;
    return count == 0 ? 1 : ((count + _pageSize - 1) ~/ _pageSize);
  }

  List<Map<String, dynamic>> get _pagedDemands {
    final filtered = _filteredDemands;
    final start = (_currentPage - 1) * _pageSize;
    if (start >= filtered.length) return [];
    final end = (start + _pageSize).clamp(0, filtered.length);
    return filtered.sublist(start, end);
  }

  void _goToPage(int page) {
    final clamped = page.clamp(1, _totalPages);
    if (clamped != _currentPage) setState(() => _currentPage = clamped);
  }

  // Use temp_id (from tempfeedemand) with _idx fallback
  String _demKey(Map<String, dynamic> d) {
    final tempId = d['temp_id']?.toString() ?? '';
    return tempId.isNotEmpty ? tempId : (d['_idx']?.toString() ?? '');
  }

  bool _isApproved(Map<String, dynamic> d) {
    final v = d['isapproved'] ?? d['approved'];
    return v == true;
  }

  void _toggleSelectAll(bool? value) {
    final keys = _filteredDemands
        .where((d) => !_isApproved(d))
        .map(_demKey)
        .where((k) => k.isNotEmpty)
        .toSet();
    setState(() {
      if (value == true) {
        _selected.addAll(keys);
      } else {
        _selected.removeAll(keys);
      }
    });
  }

  void _toggleOne(String key, bool? value) {
    setState(() {
      if (value == true) {
        _selected.add(key);
      } else {
        _selected.remove(key);
      }
    });
  }

  Future<void> _approve() async {
    if (_selected.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
        title: Text('Confirm Approval',
            style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700)),
        content: Text(
          'Approve ${_selected.length} fee demand${_selected.length == 1 ? '' : 's'}?',
          style: TextStyle(fontSize: 14.sp),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10.r)),
            ),
            child: const Text('Approve'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _approving = true);

    try {
      final tempIds = _selected
          .map((k) => int.tryParse(k))
          .whereType<int>()
          .toList();

      if (tempIds.isNotEmpty) {
        final auth = context.read<AuthProvider>();
        await SupabaseService.fromSchema('tempfeedemand')
            .update({'isapproved': true})
            .eq('ins_id', auth.insId!)
            .inFilter('temp_id', tempIds);
      }

      if (mounted) {
        setState(() {
          _selected.clear();
          _approving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Fee demands approved successfully'),
            backgroundColor: AppColors.success,
          ),
        );
        _loadDemands();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _approving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error approving. ${friendlyError(e)}'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Card container — matches Bank Reconciliation layout
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                // Title bar with selected count + Approve + Refresh
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: _buildActionBar(),
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _errorMsg != null
                          ? _buildError()
                          : _buildTable(),
                ),
                if (!_loading && _errorMsg == null && _filteredDemands.isNotEmpty)
                  _buildPagination(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionBar() {
    final allFiltered = _filteredDemands.where((d) => !_isApproved(d)).toList();
    final allSelected = allFiltered.isNotEmpty &&
        allFiltered.every((d) => _selected.contains(_demKey(d)));
    final someSelected = _selected.isNotEmpty && !allSelected;

    return Row(
      children: [
        // Select All checkbox + label
        Row(
          children: [
            Checkbox(
              value: allSelected ? true : (someSelected ? null : false),
              tristate: true,
              onChanged: (_) => _toggleSelectAll(!allSelected),
              activeColor: AppColors.accent,
            ),
            Text(
              'Select All',
              style: TextStyle(
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary),
            ),
          ],
        ),
        SizedBox(width: 16.w),

        // Approve button
        ElevatedButton.icon(
          onPressed: _selected.isEmpty || _approving ? null : _approve,
          icon: _approving
              ? SizedBox(
                  width: 14.w,
                  height: 14.h,
                  child: const CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : AppIcon.linear('tick-circle', size: 18),
          label: Text(_approving
              ? 'Approving...'
              : 'Approve (${_selected.length})'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFFE0E0E0),
            disabledForegroundColor: const Color(0xFF9E9E9E),
            padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
            textStyle:
                TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
          ),
        ),
        SizedBox(width: 16.w),

        // Refresh
        SizedBox(
          height: AppBtn.height(context),
          child: ElevatedButton.icon(
            onPressed: _loading ? null : _loadDemands,
            icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
            label: const Text('Refresh'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              disabledBackgroundColor: AppColors.accent,
              disabledForegroundColor: Colors.white,
              elevation: 0,
            ),
          ),
        ),
        SizedBox(width: 4.w),
        Text(
          '${_filteredDemands.length} record${_filteredDemands.length == 1 ? '' : 's'}',
          style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary),
        ),

        const Spacer(),

        // Search
        AppSearchField(
          controller: _searchController,
          hintText: 'Search by student name or ad...',
          onChanged: (v) {
            setState(() {
              _searchQuery = v.trim().toLowerCase();
              _currentPage = 1;
            });
          },
          width: 300.w,
          suffixIcon: _searchQuery.isNotEmpty
              ? Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: IconButton(
                    icon: const AppIcon('close-circle', size: 14),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                    splashRadius: 12,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                )
              : null,
        ),
        SizedBox(width: 12.w),

        // Class filter dropdown
        Container(
          height: 36.h,
          padding: EdgeInsets.symmetric(horizontal: 12.w),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(color: AppColors.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              value: _selectedClass,
              hint: Text('All Sections',
                  style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              style: TextStyle(
                  fontSize: 13.sp, color: AppColors.textPrimary),
              icon: AppIcon.linear('Chevron Down',
                  size: 18, color: AppColors.textSecondary),
              isDense: true,
              onChanged: (v) => setState(() {
                _selectedClass = v;
                _selected.clear();
                _currentPage = 1;
              }),
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All Sections',
                      style: TextStyle(fontSize: 13.sp)),
                ),
                ..._classList.map((cls) => DropdownMenuItem<String?>(
                      value: cls,
                      child: Text('Class $cls',
                          style: TextStyle(fontSize: 13.sp)),
                    )),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon.linear('info-circle',
              size: 48.sp, color: AppColors.error),
          SizedBox(height: 8.h),
          Text(_errorMsg!,
              style: const TextStyle(color: AppColors.textSecondary)),
          SizedBox(height: 12.h),
          OutlinedButton(onPressed: _loadDemands, child: const Text('Retry')),
        ],
      ),
    );
  }

  // ── Column width constants ────────────────────────────────────────────────
  static const double _wAdmNo = 90.0;
  static const double _wName = 150.0;
  static const double _wClass = 70.0;
  static const double _wYear = 80.0;
  static const double _wTerm = 90.0;
  static const double _wType = 100.0;
  static const double _wCategory = 90.0;
  static const double _wFeeAmt = 90.0;
  static const double _wConcession = 90.0;
  static const double _wBalance = 115.0;
  static const double _wCreatedBy = 120.0;
  static const double _wStatus = 85.0;

  static const double _colGap = 16.0; // gap between Balance Due & Created By

  // Total table width: horizontal padding(16) + checkbox(40) + all columns + gap
  static const double _tableWidth = 16 +
      40 +
      _wAdmNo +
      _wName +
      _wClass +
      _wYear +
      _wTerm +
      _wType +
      _wFeeAmt +
      _wConcession +
      _wBalance +
      _colGap +
      _wCreatedBy +
      _wStatus;

  Widget _buildTable() {
    final demands = _pagedDemands;

    if (_filteredDemands.isEmpty) {
      // Match the Bank Reconciliation empty-state look: a bordered white
      // card with a single centered line of text — no icon stack.
      return Padding(
        padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8.r),
            border: Border.all(color: AppColors.border),
          ),
          child: Center(
            child: Text(
              _searchQuery.isNotEmpty
                  ? 'No matching records'
                  : 'No fee demands found',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(color: AppColors.border),
        ),
        child: LayoutBuilder(
        builder: (context, constraints) {
          final tableH = constraints.maxHeight;
          final viewportW = constraints.maxWidth;
          const contentW = 1200.0;
          final effectiveW = contentW > viewportW ? contentW : viewportW;
          const scrollbarH = 18.0;
          return Stack(
            children: [
              // ── Table (header + rows) ──────────────────────────────────
              SizedBox(
                height: tableH,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                  Expanded(
                  child: SingleChildScrollView(
                  controller: _hScrollController,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: effectiveW,
                    child: Column(
                      children: [
                        // Header
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 16.w, vertical: 8.h),
                          color: AppColors.tableHeadBg,
                          child: Row(
                            children: [
                              SizedBox(width: 40.w),
                              _headerCell('Admission No', 3),
                              _headerCell('Student Name', 5),
                              _headerCell('Section', 3),
                              _headerCell('Year', 3, center: true),
                              _headerCell('Term', 3, center: true),
                              _headerCell('Fee Type', 3),
                              _headerCell('Fee Amount', 3, right: true),
                              SizedBox(width: 16.w),
                              _headerCell('Concession', 3, center: true),
                              _headerCell('Balance Due', 3, right: true),
                              SizedBox(width: 32.w),
                              _headerCell('Created By', 3),
                              _headerCell('Status', 3, center: true),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        // Rows
                        Expanded(
                          child: RefreshIndicator(
                            onRefresh: _loadDemands,
                            child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                            child: ListView.separated(
                              controller: _vScrollController,
                              padding: EdgeInsets.zero,
                              itemCount: demands.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, i) =>
                                  _buildRow(demands[i], i),
                            ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                ),
                Column(
                  children: [
                    Container(width: 16, color: AppColors.tableHeadBg, child: SizedBox(height: 12.h * 2 + 18)),
                    Expanded(child: AppScrollbarBar(controller: _vScrollController)),
                  ],
                ),
                  ],
                ),
              ),
              // ── Horizontal scrollbar ───────────────────────────────────
              Positioned(
                left: 0, right: 16, bottom: 0,
                child: ClassicHScrollbar(
                  controller: _hScrollController,
                  contentWidth: effectiveW,
                  viewportWidth: viewportW,
                ),
              ),
            ],
          );
        },
        ),
      ),
    );
  }

  Widget _buildWinScrollbar(
      double viewportW, double contentW, double barH) {
    return ListenableBuilder(
      listenable: _hScrollController,
      builder: (context, _) {
        final canScroll = contentW > viewportW;
        if (!canScroll) return const SizedBox.shrink();
        final maxScroll = canScroll ? contentW - viewportW : 1.0;
        final offset = (_hScrollController.hasClients && canScroll)
            ? _hScrollController.offset.clamp(0.0, maxScroll)
            : 0.0;
        final ratio = canScroll ? offset / maxScroll : 0.0;

        // Track width = viewport minus two arrow buttons
        const btnW = 18.0;
        final trackW = viewportW - btnW * 2;
        final thumbW =
            canScroll ? (viewportW / contentW * trackW).clamp(30.0, trackW) : trackW;
        final thumbLeft = ratio * (trackW - thumbW);

        void scrollBy(double delta) {
          if (!_hScrollController.hasClients) return;
          _hScrollController.jumpTo(
              (_hScrollController.offset + delta).clamp(0.0, maxScroll));
        }

        return Container(
          height: barH,
          decoration: BoxDecoration(
            color: const Color(0xFFB0B0B0),
            border: const Border(top: BorderSide(color: Color(0xFF555555))),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(13.r)),
          ),
          child: Row(
            children: [
              // Left arrow
              _winArrowBtn(
                  '◄', canScroll ? () => scrollBy(-60) : null, btnW, barH),

              // Track + thumb
              Expanded(
                child: GestureDetector(
                  onTapDown: (d) {
                    if (!canScroll) return;
                    final newScroll =
                        (d.localPosition.dx / trackW * maxScroll)
                            .clamp(0.0, maxScroll);
                    _hScrollController.jumpTo(newScroll);
                  },
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      // Track
                      Positioned.fill(
                        child: Container(color: const Color(0xFFB0B0B0)),
                      ),
                      // Thumb
                      if (canScroll)
                        Positioned(
                          left: thumbLeft,
                          top: 1,
                          bottom: 1,
                          width: thumbW,
                          child: GestureDetector(
                            onHorizontalDragUpdate: (d) {
                              final scale =
                                  maxScroll / (trackW - thumbW);
                              scrollBy(d.delta.dx * scale);
                            },
                            child: _winThumb(thumbW),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // Right arrow
              _winArrowBtn(
                  '►', canScroll ? () => scrollBy(60) : null, btnW, barH),
            ],
          ),
        );
      },
    );
  }

  Widget _winArrowBtn(
      String label, VoidCallback? onTap, double w, double h) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: w,
        height: h,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFB0B0B0),
          border: Border.all(color: const Color(0xFF555555), width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
              fontSize: 9.sp,
              color: onTap != null ? Colors.black87 : Colors.grey),
        ),
      ),
    );
  }

  Widget _winThumb(double w) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFB0B0B0),
        border: Border.all(color: const Color(0xFF555555), width: 0.5),
      ),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            3,
            (_) => Container(
              width: 1,
              height: 8,
              margin: EdgeInsets.symmetric(horizontal: 2.w),
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: Colors.white, width: 1),
                  right: BorderSide(color: Color(0xFF555555), width: 1),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _headerCell(String label, int flex,
      {bool center = false, bool right = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 12.sp,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
            letterSpacing: 0.3),
        textAlign: right
            ? TextAlign.right
            : center
                ? TextAlign.center
                : TextAlign.left,
      ),
    );
  }

  Widget _buildRow(Map<String, dynamic> d, int index) {
    final key = _demKey(d);
    final isSelected = _selected.contains(key);

    final isApproved = _isApproved(d);

    final admNo = d['stuadmno']?.toString() ?? '-';
    // stuname comes from students join; fallback to inline field
    final name = (d['stuname'] ?? d['studentname'] ?? '').toString();
    final cls = d['stuclass']?.toString() ?? '-';
    // tempfeedemand stores year as demfeeyear (text label)
    final year = (d['demfeeyear'] ?? d['acayear'] ?? d['academicyear'] ?? d['year'] ?? '-').toString();
    // tempfeedemand: demfeeterm
    final term = (d['demfeeterm'] ?? d['feeterm'] ?? d['feetermname'] ?? d['termname'] ?? '-').toString();
    // tempfeedemand: demfeetype
    final type = (d['demfeetype'] ?? d['feetype'] ?? d['feetypename'] ?? d['typename'] ?? '-').toString();
    final feeAmt = (d['feeamount'] as num?)?.toDouble() ?? 0;
    final conAmt = (d['conamount'] as num?)?.toDouble() ?? 0;
    final concessionName = (d['stucondesc'] ?? '-').toString();
    // use stored balancedue if available
    final balance = (d['balancedue'] as num?)?.toDouble() ?? (feeAmt - conAmt);
    final createdBy =
        (d['createdby'] ?? d['created_by'] ?? d['createdbyname'] ?? '-')
            .toString();
    // isapproved is boolean in tempfeedemand
    final approvedVal = d['isapproved'] ?? d['approved'];
    final status = approvedVal == true ? 'A'
        : (approvedVal == false || approvedVal == 'False' || approvedVal == 'false') ? 'P'
        : (d['approvalstatus']?.toString() ?? 'P');

    return InkWell(
      onTap: (key.isNotEmpty && !isApproved) ? () => _toggleOne(key, !isSelected) : null,
      child: Container(
        color: isApproved
            ? Colors.grey.shade50
            : isSelected
                ? AppColors.accent.withValues(alpha: 0.06)
                : index.isOdd
                    ? AppColors.surface
                    : Colors.white,
        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
        child: Row(
            children: [
              SizedBox(
                width: 40.w,
                child: Checkbox(
                  value: isApproved ? false : isSelected,
                  onChanged: (key.isNotEmpty && !isApproved) ? (v) => _toggleOne(key, v) : null,
                  activeColor: AppColors.accent,
                ),
              ),
              // Admission No
              Expanded(
                flex: 3,
                child: Text(admNo,
                    style: TextStyle(
                        fontSize: 13.sp,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent)),
              ),
              // Student Name
              Expanded(
                flex: 5,
                child: Text(name.isNotEmpty ? name : '-',
                    style: TextStyle(
                        fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                    overflow: TextOverflow.ellipsis),
              ),
              // Class
              Expanded(
                flex: 3,
                child: Text(cls,
                    style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                    textAlign: TextAlign.left,
                    overflow: TextOverflow.ellipsis),
              ),
              // Year
              Expanded(
                flex: 3,
                child: Text(year,
                    style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis),
              ),
              // Fee Term
              Expanded(
                flex: 3,
                child: Text(term,
                    style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis),
              ),
              // Fee Type
              Expanded(
                flex: 3,
                child: Text(type,
                    style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                    overflow: TextOverflow.ellipsis),
              ),
              // Fee Amount
              Expanded(
                flex: 3,
                child: Text('${_fmt(feeAmt)}',
                    style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                    textAlign: TextAlign.right),
              ),
              SizedBox(width: 16.w),
              // Concession
              Expanded(
                flex: 3,
                child: Text(concessionName,
                    style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis),
              ),
              // Balance Due
              Expanded(
                flex: 3,
                child: Text('${_fmt(balance)}',
                    style: TextStyle(
                        fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                    textAlign: TextAlign.right),
              ),
              SizedBox(width: 32.w),
              // Created By
              Expanded(
                flex: 3,
                child: Text(createdBy,
                    style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                    overflow: TextOverflow.ellipsis),
              ),
              // Status
              Expanded(
                flex: 3,
                child: _statusBadge(status),
              ),
            ],
          ),
        ),
    );
  }

  Widget _buildPagination() {
    final total = _filteredDemands.length;
    final totalPages = _totalPages;
    final start = (_currentPage - 1) * _pageSize + 1;
    final end = (_currentPage * _pageSize).clamp(0, total);

    // Build list of page numbers to show (max 7 buttons with ellipsis)
    List<int?> pages = [];
    if (totalPages <= 7) {
      pages = List.generate(totalPages, (i) => i + 1);
    } else {
      pages.add(1);
      if (_currentPage > 3) pages.add(null); // ellipsis
      for (int i = (_currentPage - 1).clamp(2, totalPages - 1);
          i <= (_currentPage + 1).clamp(2, totalPages - 1);
          i++) {
        pages.add(i);
      }
      if (_currentPage < totalPages - 2) pages.add(null); // ellipsis
      pages.add(totalPages);
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 4.w, vertical: 8.h),
      child: Row(
        children: [
          Text(
            'Showing $start–$end of $total records',
            style: TextStyle(
                fontSize: 13.sp, color: AppColors.textSecondary),
          ),
          const Spacer(),
          // Prev button
          _pageBtn(
            label: '‹',
            onTap: _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
          ),
          SizedBox(width: 4.w),
          // Page number buttons
          ...pages.map((p) {
            if (p == null) {
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: 4.w),
                child: Text('…',
                    style: TextStyle(
                        fontSize: 13.sp, color: AppColors.textSecondary)),
              );
            }
            final isActive = p == _currentPage;
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: 2.w),
              child: _pageBtn(
                label: '$p',
                onTap: isActive ? null : () => _goToPage(p),
                active: isActive,
              ),
            );
          }),
          SizedBox(width: 4.w),
          // Next button
          _pageBtn(
            label: '›',
            onTap: _currentPage < totalPages
                ? () => _goToPage(_currentPage + 1)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _pageBtn(
      {required String label, VoidCallback? onTap, bool active = false}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 30.w,
        height: 30.h,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppColors.primaryDark : AppColors.surface,
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(
            color: active ? AppColors.primaryDark : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13.sp,
            fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            color: active
                ? Colors.white
                : onTap != null
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _statusBadge(String status) {
    final (label, bg, fg) = switch (status.toUpperCase()) {
      'A' => ('Approved', const Color(0xFFE6F4EA), AppColors.success),
      'R' => ('Rejected', const Color(0xFFFCE8E6), AppColors.error),
      'P' || _ => ('Pending', const Color(0xFFFFF8E1), const Color(0xFFE65100)),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 3.h),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.sp, fontWeight: FontWeight.w600, color: fg),
          textAlign: TextAlign.center),
    );
  }

  String _fmt(double v) => formatIndianNumber(v);
}
