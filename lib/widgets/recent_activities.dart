import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../utils/app_theme.dart';
import '../utils/auth_provider.dart';
import '../services/supabase_service.dart';
import '../models/payment_model.dart';

import './app_ui.dart';
import '../utils/formatters.dart';
class RecentActivitiesWidget extends StatefulWidget {
  const RecentActivitiesWidget({super.key});

  @override
  State<RecentActivitiesWidget> createState() => _RecentActivitiesWidgetState();
}

class _RecentActivitiesWidgetState extends State<RecentActivitiesWidget> {
  List<PaymentModel> _payments = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPayments();
  }

  Future<void> _loadPayments() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) {
      setState(() => _isLoading = false);
      return;
    }

    final payments = await SupabaseService.getRecentPayments(insId, limit: 6);
    if (mounted) {
      setState(() {
        _payments = payments;
        _isLoading = false;
      });
    }
  }

  String _timeAgo(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} mins ago';
    if (diff.inHours < 24) return '${diff.inHours} hours ago';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${date.day}/${date.month}/${date.year}';
  }

  Color _statusColor(String? status) {
    switch (status) {
      case 'C':
        return AppColors.success;
      case 'F':
        return AppColors.error;
      case 'R':
        return AppColors.warning;
      default:
        return AppColors.info;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Recent Payments', style: AppUI.cardTitle),
              TextButton(
                onPressed: () {},
                child: const Text('View All'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_payments.isEmpty)
            AppUI.empty(
              title: 'No recent payments found',
              why: 'Receipts appear here once fees are collected.',
              icon: 'wallet-money',
            )
          else
            ..._payments.asMap().entries.map((entry) {
              final payment = entry.value;
              final isLast = entry.key == _payments.length - 1;
              final color = _statusColor(payment.paystatus);
              final initial =
                  (payment.createdby ?? 'P')[0].toUpperCase();

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: color.withValues(alpha: 0.12),
                          child: Text(
                            initial,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: 'Payment #${payment.payId}',
                                      style: AppUI.label,
                                    ),
                                    TextSpan(
                                      text:
                                          ' — ${formatIndianNumber(payment.amount)} (${payment.statusText})',
                                      style: AppUI.body.copyWith(color: AppColors.textSecondary),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _timeAgo(payment.createdat),
                                style: AppUI.muted,
                              ),
                            ],
                          ),
                        ),
                        AppUI.iconTile('wallet-money', color: color, size: 16),
                      ],
                    ),
                  ),
                  if (!isLast)
                    Divider(
                      color: AppColors.divider,
                      height: 1,
                    ),
                ],
              );
            }),
        ],
      ),
    );
  }
}
