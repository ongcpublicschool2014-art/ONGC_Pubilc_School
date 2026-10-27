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
class NotificationScreen extends StatefulWidget {
  final VoidCallback? onReadChanged;
  const NotificationScreen({super.key, this.onReadChanged});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  bool _isLoading = false;
  List<Map<String, dynamic>> _notifications = [];
  String _filter = 'All'; // All, Unread, Read
  Map<String, dynamic>? _selectedNotification;

  @override
  void initState() {
    super.initState();
    _fetchNotifications();
  }

  Future<void> _fetchNotifications() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isLoading = true);
    try {
      final data = await SupabaseService.fromSchema('notification')
          .select()
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .isFilter('stu_id', null)
          .order('createdat', ascending: false);
      final allNotifications = List<Map<String, dynamic>>.from(data);
      // Deduplicate: group by title+body+type, show unique notifications only
      final seen = <String>{};
      final unique = <Map<String, dynamic>>[];
      // Track which unique entries are read
      final Map<String, bool> readStatus = {};
      for (final n in allNotifications) {
        final key = '${n['notititle']}|${n['notibody']}|${n['notitype']}';
        final isRead = n['isread'] == true || n['isread'] == 1;
        if (!seen.contains(key)) {
          seen.add(key);
          unique.add(n);
          readStatus[key] = isRead;
        } else {
          // If unique entry is read but this duplicate is unread, mark it as read in DB
          if (readStatus[key] == true && !isRead) {
            final id = n['noti_id'];
            if (id != null) {
              SupabaseService.fromSchema('notification').update({'isread': 1}).eq('noti_id', id).eq('ins_id', insId).then((_) {});
            }
          }
        }
      }
      if (mounted) {
        setState(() {
          _notifications = unique;
          _isLoading = false;
        });
        // Refresh dashboard badge after syncing duplicates
        widget.onReadChanged?.call();
      }
    } catch (e) {
      debugPrint('Error fetching notifications: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<Map<String, dynamic>> get _filteredNotifications {
    if (_filter == 'Unread') return _notifications.where((n) => n['isread'] != true && n['isread'] != 1).toList();
    if (_filter == 'Read') return _notifications.where((n) => n['isread'] == true || n['isread'] == 1).toList();
    return _notifications;
  }

  int get _unreadCount => _notifications.where((n) => n['isread'] != true && n['isread'] != 1).length;

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
      if (diff.inDays > 30) return '${(diff.inDays / 30).floor()}mo ago';
      if (diff.inDays > 0) return '${diff.inDays}d ago';
      if (diff.inHours > 0) return '${diff.inHours}h ago';
      if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
      return 'Just now';
    } catch (_) {
      return '';
    }
  }

  String _typeIcon(String? type) {
    switch (type?.toLowerCase()) {
      case 'fee':
      case 'payment':
        return 'indianrupeesign.circle.fill';
      case 'exam':
        return 'message-question';
      case 'attendance':
        return 'clipboard-tick';
      case 'notice':
        return 'volume-high';
      case 'alert':
        return 'warning-2';
      case 'message':
        return 'message';
      default:
        return 'notification';
    }
  }

  Color _typeColor(String? type) {
    switch (type?.toLowerCase()) {
      case 'fee':
      case 'payment':
        return AppColors.accent;
      case 'alert':
        return AppColors.error;
      case 'exam':
        return AppColors.warning;
      case 'attendance':
        return AppColors.demand;
      case 'notice':
        return AppColors.info;
      default:
        return AppColors.textSecondary;
    }
  }

  AppStatus _typeStatus(String? type) {
    switch (type?.toLowerCase()) {
      case 'alert':
        return AppStatus.danger;
      case 'exam':
        return AppStatus.warning;
      case 'fee':
      case 'payment':
      case 'notice':
        return AppStatus.info;
      default:
        return AppStatus.neutral;
    }
  }

  Future<void> _markAsRead(Map<String, dynamic> notif) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      // Always mark the tapped row by its noti_id first — this guarantees
      // the row the user actually opened is marked read even if its
      // title/body/type are NULL or differ from siblings.
      final notiId = notif['noti_id'];
      if (notiId != null) {
        await SupabaseService.fromSchema('notification')
            .update({'isread': 1})
            .eq('noti_id', notiId)
            .eq('ins_id', insId);
      }
      // Also mark all duplicates with same title+body+type so the list
      // doesn't show the same item again as unread on next fetch.
      var query = SupabaseService.fromSchema('notification').update({'isread': 1}).eq('ins_id', insId).eq('activestatus', 1);
      final title = notif['notititle']?.toString();
      final body = notif['notibody']?.toString();
      final type = notif['notitype']?.toString();
      if (title != null) query = query.eq('notititle', title);
      if (body != null) query = query.eq('notibody', body);
      if (type != null) query = query.eq('notitype', type);
      await query;
      await _fetchNotifications();
      widget.onReadChanged?.call();
    } catch (e) {
      debugPrint('Error marking as read: $e');
    }
  }

  Future<void> _markAllAsRead() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      await SupabaseService.fromSchema('notification').update({'isread': 1}).eq('ins_id', insId).eq('activestatus', 1);
      await _fetchNotifications();
      widget.onReadChanged?.call();
    } catch (e) {
      debugPrint('Error marking all as read: $e');
    }
  }

  // ── layout ──────────────────────────────────────────────────────────────────
  // Master-detail: the notification list (search + All/Unread/Read) on the
  // left, the opened notification on the right.
  String _query = '';

  List<Map<String, dynamic>> get _visibleNotifications {
    final q = _query.trim().toLowerCase();
    final base = _filteredNotifications;
    if (q.isEmpty) return base;
    return base.where((n) {
      final hay = [
        n['notititle'] ?? n['title'],
        n['notibody'] ?? n['body'] ?? n['notidesc'],
        n['notitype'] ?? n['type'],
      ].map((e) => e?.toString().toLowerCase() ?? '').join(' ');
      return hay.contains(q);
    }).toList();
  }

  bool _isSelected(Map<String, dynamic> n) {
    final sel = _selectedNotification;
    if (sel == null) return false;
    final a = sel['noti_id'], b = n['noti_id'];
    return a != null ? a == b : identical(sel, n);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleNotifications;
    return AppMasterDetail(
      listTitle: 'Notifications',
      listIcon: 'notification',
      listSubtitle: _unreadCount > 0 ? '$_unreadCount unread' : 'All caught up',
      listActions: [
        if (_unreadCount > 0) AppUI.chip('$_unreadCount new', AppStatus.danger),
      ],
      search: Row(children: [
        Expanded(
          child: AppSearchField(
            hintText: 'Search notifications',
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SizedBox(width: 8.w),
        Tooltip(
          message: 'Refresh',
          child: OutlinedButton(
            onPressed: _fetchNotifications,
            style: OutlinedButton.styleFrom(padding: EdgeInsets.symmetric(horizontal: 12.w)),
            child: AppIcon('refresh', size: AppBtn.iconSize(context), color: AppColors.primary),
          ),
        ),
      ]),
      filters: [
        Wrap(
          spacing: 6.w,
          runSpacing: 6.h,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ...['All', 'Unread', 'Read'].map((f) {
              final isActive = _filter == f;
              return InkWell(
                onTap: () => setState(() => _filter = f),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
                  decoration: BoxDecoration(
                    color: isActive ? AppColors.primaryLight : Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: isActive ? AppColors.primary : AppColors.border),
                  ),
                  child: Text(f, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: isActive ? AppColors.primary : AppColors.textSecondary)),
                ),
              );
            }),
            if (_unreadCount > 0)
              TextButton.icon(
                onPressed: _markAllAsRead,
                icon: AppIcon('task-square', size: AppBtn.iconSize(context), color: AppColors.primary),
                label: const Text('Mark all read'),
              ),
          ],
        ),
      ],
      list: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : visible.isEmpty
              ? _buildEmptyState()
              : AppVerticalScrollbar(
                  builder: (context, controller) => ListView.separated(
                    controller: controller,
                    padding: EdgeInsets.zero,
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, thickness: 1, color: AppColors.divider),
                    itemBuilder: (context, index) => _buildNotificationTile(visible[index], index),
                  ),
                ),
      footer: Text(AppUI.showing(visible.isEmpty ? 0 : 1, visible.length, visible.length), style: AppUI.muted),
      detail: _selectedNotification == null
          ? null
          : (_isLoading ? const Center(child: CircularProgressIndicator()) : _buildNotificationDetail(_selectedNotification!)),
      emptyDetail: AppUI.empty(
        icon: 'notification-bing',
        title: 'Select a notification',
        why: 'Pick a notification on the left to read it. Opening an unread one marks it read.',
      ),
      showDetail: _selectedNotification != null,
      onBack: () => setState(() => _selectedNotification = null),
    );
  }

  Widget _buildEmptyState() {
    if (_query.trim().isNotEmpty && _filteredNotifications.isNotEmpty) {
      return AppUI.empty(
        icon: 'search-normal',
        title: 'No matching notifications',
        why: 'Nothing matches "$_query". Clear the search to see them all.',
      );
    }
    return AppUI.empty(
      icon: 'notification-bing',
      title: _filter == 'Unread' ? 'No unread notifications' : _filter == 'Read' ? 'No read notifications' : 'No notifications yet',
      why: 'You\'re all caught up!',
    );
  }

  Widget _buildNotificationTile(Map<String, dynamic> notif, [int index = 0]) {
    final title = notif['notititle']?.toString() ?? notif['title']?.toString() ?? 'Notification';
    final body = notif['notibody']?.toString() ?? notif['body']?.toString() ?? notif['notidesc']?.toString() ?? '';
    final date = notif['createdat']?.toString();
    final type = notif['notitype']?.toString() ?? notif['type']?.toString();
    final isRead = notif['isread'] == true || notif['isread'] == 1;
    final selected = _isSelected(notif);

    final tColor = _typeColor(type);
    // Unread state is conveyed by the inline accent dot before the title (and
    // a bolder title); the selected row takes the accent tint.
    return Material(
      color: selected ? AppColors.primaryLight : Colors.white,
      child: InkWell(
        onTap: () {
          if (!isRead) _markAsRead(notif);
          setState(() => _selectedNotification = notif);
        },
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
                child: AppIcon.linear(_typeIcon(type), size: 16, color: selected ? AppColors.primary : AppColors.textSecondary),
              ),
              SizedBox(width: 12.w),
              // Title (with inline unread dot) + body
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
                              if (!isRead) ...[
                                Tooltip(
                                  message: 'Unread',
                                  child: Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(color: tColor, shape: BoxShape.circle),
                                  ),
                                ),
                                SizedBox(width: 6.w),
                              ],
                              Flexible(
                                child: Text(
                                  title,
                                  style: TextStyle(
                                    fontSize: 14.sp,
                                    fontWeight: isRead ? FontWeight.w600 : FontWeight.w800,
                                    color: selected ? AppColors.primary : AppColors.textPrimary,
                                    height: 1.2,
                                  ),
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
                    if (body.isNotEmpty) ...[
                      SizedBox(height: 4.h),
                      Text(
                        body,
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

  Widget _buildNotificationDetail(Map<String, dynamic> notif) {
    final title = notif['notititle']?.toString() ?? notif['title']?.toString() ?? 'Notification';
    final body = notif['notibody']?.toString() ?? notif['body']?.toString() ?? notif['notidesc']?.toString() ?? '';
    final date = notif['createdat']?.toString();
    final type = notif['notitype']?.toString() ?? notif['type']?.toString();
    final createdBy = notif['createdby']?.toString();
    final target = notif['notitarget']?.toString() ?? notif['target']?.toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pane header — matches the notice "Notice Details" header
        Padding(
          padding: EdgeInsets.fromLTRB(AppUI.cardPad, 14.h, 12.w, 14.h),
          child: Row(
            children: [
              Expanded(child: Text('Notification Details', style: AppUI.cardTitle)),
              if (type != null) AppUI.chip(type, _typeStatus(type)),
              SizedBox(width: 4.w),
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                onPressed: () => setState(() => _selectedNotification = null),
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
                    AppUI.iconTile(_typeIcon(type), color: _typeColor(type)),
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
                              if (type != null) AppUI.chip(type, _typeStatus(type)),
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

                // Body
                if (body.isNotEmpty)
                  Text(body, style: AppUI.body.copyWith(height: 1.7)),

                if (target != null && target.isNotEmpty) ...[
                  SizedBox(height: 20.h),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const AppIcon.linear('people', size: 16, color: AppColors.textLight),
                      SizedBox(width: 6.w),
                      Text('Target: ', style: AppUI.muted),
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
}
