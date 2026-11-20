import 'package:flutter/material.dart';

import '../utils/payment_gateways.dart';
import 'app_ui.dart';

/// Where a fee group's online money goes, as one chip; the tooltip says it in
/// a full sentence. Used by Fee Master -> Fee Group and Setup -> Payment
/// Gateways so both always say the same thing.
Widget onlineRouteChip(OnlineRoute r) {
  final status = switch (r.kind) {
    OnlineRouteKind.main || OnlineRouteKind.subAccount || OnlineRouteKind.ownMerchant => AppStatus.success,
    OnlineRouteKind.noGateway => AppStatus.neutral,
    OnlineRouteKind.cashOnly => AppStatus.warning,
    OnlineRouteKind.problem => AppStatus.danger,
  };
  return Tooltip(
    message: r.detail,
    child: Align(
      alignment: Alignment.centerLeft,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: AppUI.chip(r.text, status),
      ),
    ),
  );
}
