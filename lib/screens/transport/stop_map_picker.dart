import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../utils/app_theme.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';

/// A place found by the stop map's search.
class TrPlace {
  final String name;
  final double lat;
  final double lon;
  const TrPlace(this.name, this.lat, this.lon);
}

/// Coordinates typed or pasted into the search: "10.5920, 77.2440",
/// "10.5920 77.2440", or a Google Maps link (…/@10.59,77.24,17z, ?q=10.59,77.24,
/// ll=…, or a place link's !3d10.59!4d77.24). Null when it is not one.
TrPlace? trParseCoordinates(String text) {
  final s = Uri.decodeFull(text.trim());
  const n = r'(-?\d{1,3}(?:\.\d+)?)';
  final patterns = [
    RegExp('!3d$n!4d$n'),
    RegExp('@$n,\\s*$n'),
    RegExp('[?&](?:q|query|ll|destination|center)=$n,\\s*$n'),
    RegExp('^$n\\s*[, ]\\s*$n\$'),
  ];
  for (final p in patterns) {
    final m = p.firstMatch(s);
    if (m == null) continue;
    final lat = double.tryParse(m.group(1)!), lon = double.tryParse(m.group(2)!);
    if (trUsablePosition(lat, lon)) return TrPlace('${lat!.toStringAsFixed(6)}, ${lon!.toStringAsFixed(6)}', lat, lon);
  }
  return null;
}

/// Place search by name: OpenStreetMap's Nominatim (no key). Its rules: one
/// search when the user asks (never as they type), and an app name in the
/// User-Agent. Places near [near] (the map's view) come first; India only.
Future<List<TrPlace>> trNominatimSearch(String query, {LatLngBounds? near}) async {
  final params = <String, String>{
    'q': query,
    'format': 'jsonv2',
    'limit': '6',
    'countrycodes': 'in',
    'accept-language': 'en',
    if (near != null) 'viewbox': '${near.west},${near.north},${near.east},${near.south}',
  };
  final res = await http
      .get(Uri.https('nominatim.openstreetmap.org', '/search', params),
          headers: {'User-Agent': 'FIT-School-Admin/1.0 (school transport stop map)'})
      .timeout(const Duration(seconds: 12));
  if (res.statusCode != 200) throw Exception('search answered ${res.statusCode}');
  final list = jsonDecode(res.body) as List;
  return [
    for (final e in list)
      if (e is Map && double.tryParse('${e['lat']}') != null && double.tryParse('${e['lon']}') != null)
        TrPlace('${e['display_name']}', double.parse('${e['lat']}'), double.parse('${e['lon']}')),
  ];
}

/// Another stop of the route, shown on the stop map for orientation.
class TrMapPoint {
  final double lat;
  final double lon;
  final String label;
  const TrMapPoint(this.lat, this.lon, this.label);
}

/// A real position: not empty, not the 90 / 90 placeholder, not 0 / 0.
bool trUsablePosition(double? lat, double? lon) =>
    lat != null && lon != null && lat.abs() < 85 && lon.abs() <= 180 && !(lat == 0 && lon == 0);

/// The stop form's map (OpenStreetMap, no key): click to place the stop, which
/// fills [lat] / [lon]; typing them moves the pin. The route's other stops
/// show numbered, joined in order, so the new one is easy to place.
class StopMapPicker extends StatefulWidget {
  const StopMapPicker({
    super.key,
    required this.lat,
    required this.lon,
    this.others = const [],
    this.enabled = true,
    this.onChanged,
  });

  final TextEditingController lat;
  final TextEditingController lon;
  final List<TrMapPoint> others;
  final bool enabled;
  final VoidCallback? onChanged;

  /// False in widget tests: no map tiles are fetched.
  static bool tilesEnabled = true;

  /// The name search (replaced in tests).
  static Future<List<TrPlace>> Function(String query, {LatLngBounds? near}) searchPlaces = trNominatimSearch;

  @override
  State<StopMapPicker> createState() => _StopMapPickerState();
}

class _StopMapPickerState extends State<StopMapPicker> {
  final _map = MapController();
  bool _ready = false;
  final _query = TextEditingController();
  List<TrPlace> _found = const [];
  bool _searching = false;
  String? _searchNote;

  // Tamil Nadu, for a school with no stop on the map yet
  static const _fallback = LatLng(10.9, 78.4);

  @override
  void initState() {
    super.initState();
    widget.lat.addListener(_typed);
    widget.lon.addListener(_typed);
  }

  @override
  void dispose() {
    widget.lat.removeListener(_typed);
    widget.lon.removeListener(_typed);
    _map.dispose();
    _query.dispose();
    super.dispose();
  }

  /// Coordinates / a Google Maps link go straight there; a name is searched.
  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty || _searching) return;
    final direct = trParseCoordinates(q);
    if (direct != null) {
      _go(direct);
      return;
    }
    setState(() {
      _searching = true;
      _searchNote = null;
      _found = const [];
    });
    try {
      final found = await StopMapPicker.searchPlaces(q, near: _ready ? _map.camera.visibleBounds : null);
      if (!mounted) return;
      setState(() {
        _found = found;
        _searchNote = found.isEmpty ? 'No place found for "$q". Try a nearby landmark or the town name.' : null;
      });
    } catch (_) {
      if (mounted) setState(() => _searchNote = 'Could not search right now. Check the internet connection, or paste the coordinates.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// A place picked: the map goes there and the stop's pin is put on it.
  void _go(TrPlace p) {
    final at = LatLng(p.lat, p.lon);
    if (_ready) _map.move(at, 17);
    _place(at);
    setState(() {
      _found = const [];
      _searchNote = 'Placed at ${p.name.split(',').first}. Click the map to move the pin to the exact spot.';
    });
  }

  Widget _searchBox() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(
          child: TextField(
            controller: _query,
            enabled: widget.enabled,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            style: AppUI.fieldText(context),
            decoration: AppUI.field(context, '', dense: true, leadingIcon: 'search-normal')
                .copyWith(hintText: 'Search a place, or paste coordinates / a Google Maps link'),
          ),
        ),
        SizedBox(width: 8.w),
        OutlinedButton.icon(
          onPressed: widget.enabled && !_searching ? _search : null,
          style: AppUI.secondary(context),
          icon: _searching
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : AppIcon('search-normal', size: AppBtn.iconSize(context), color: AppColors.primaryText),
          label: const Text('Search'),
        ),
      ]),
      if (_found.isNotEmpty) ...[
        SizedBox(height: 6.h),
        Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < _found.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: AppColors.divider),
              InkWell(
                onTap: () => _go(_found[i]),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                  child: Row(children: [
                    const AppIcon('location', size: 16, color: AppColors.primary),
                    SizedBox(width: 10.w),
                    Expanded(
                      child: Text(_found[i].name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppUI.cell),
                    ),
                  ]),
                ),
              ),
            ],
          ]),
        ),
      ],
      if (_searchNote != null) ...[
        SizedBox(height: 4.h),
        Text(_searchNote!, style: AppUI.muted),
      ],
      SizedBox(height: 8.h),
    ]);
  }

  void _typed() {
    if (mounted) setState(() {}); // the pin follows the typed numbers
  }

  LatLng? get _pin {
    final lat = double.tryParse(widget.lat.text.trim()), lon = double.tryParse(widget.lon.text.trim());
    return trUsablePosition(lat, lon) ? LatLng(lat!, lon!) : null;
  }

  List<LatLng> get _others => [
        for (final p in widget.others)
          if (trUsablePosition(p.lat, p.lon)) LatLng(p.lat, p.lon),
      ];

  CameraFit? _fitAll() {
    final pts = [..._others, if (_pin != null) _pin!];
    if (pts.length < 2) return null;
    return CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(40), maxZoom: 17);
  }

  void _place(LatLng p) {
    if (!widget.enabled) return;
    widget.lat.text = p.latitude.toStringAsFixed(6);
    widget.lon.text = p.longitude.toStringAsFixed(6);
    widget.onChanged?.call();
  }

  void _zoom(double by) {
    if (!_ready) return;
    final cam = _map.camera;
    _map.move(cam.center, (cam.zoom + by).clamp(3, 19));
  }

  @override
  Widget build(BuildContext context) {
    final pin = _pin;
    final others = [for (final p in widget.others) if (trUsablePosition(p.lat, p.lon)) p];
    final fit = _fitAll();
    final start = pin ?? (others.isNotEmpty ? LatLng(others.first.lat, others.first.lon) : _fallback);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (widget.enabled) _searchBox(),
      Container(
        height: 300.h,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.segmentBg,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.fieldBorder),
        ),
        child: Stack(children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: start,
              initialZoom: pin != null ? 16 : (others.isNotEmpty ? 14 : 7),
              initialCameraFit: pin == null ? fit : null,
              backgroundColor: AppColors.segmentBg,
              onMapReady: () => _ready = true,
              onTap: (_, p) => _place(p),
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            ),
            children: [
              if (StopMapPicker.tilesEnabled)
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.fitschool.school_admin',
                ),
              if (others.length > 1)
                PolylineLayer(polylines: [
                  Polyline(
                    points: [for (final p in others) LatLng(p.lat, p.lon)],
                    strokeWidth: 3,
                    color: AppColors.primary.withValues(alpha: 0.55),
                  ),
                ]),
              MarkerLayer(markers: [
                for (final p in others)
                  Marker(
                    point: LatLng(p.lat, p.lon),
                    width: 26,
                    height: 26,
                    child: Tooltip(message: p.label, child: _dot(p.label)),
                  ),
                if (pin != null)
                  Marker(
                    point: pin,
                    width: 34,
                    height: 34,
                    alignment: Alignment.topCenter,
                    child: const Tooltip(message: 'This stop', child: _Pin()),
                  ),
              ]),
              if (StopMapPicker.tilesEnabled) const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
            ],
          ),
          Positioned(
            right: 8,
            top: 8,
            child: Column(children: [
              _button('add', 'Zoom in', () => _zoom(1)),
              SizedBox(height: 6.h),
              _button('minus', 'Zoom out', () => _zoom(-1)),
              if (fit != null) ...[
                SizedBox(height: 6.h),
                _button('routing', 'Show the whole route', () {
                  if (_ready) _map.fitCamera(fit);
                }),
              ],
              if (pin != null) ...[
                SizedBox(height: 6.h),
                _button('location', 'Go to this stop', () {
                  if (_ready) _map.move(pin, 17);
                }),
              ],
            ]),
          ),
        ]),
      ),
      SizedBox(height: 6.h),
      Text(
        widget.enabled
            ? 'Click the map where the bus stops: Latitude and Longitude fill in. Drag to move, scroll to zoom.'
            : 'Where the stop is.',
        style: AppUI.muted,
      ),
    ]);
  }

  Widget _dot(String label) {
    final n = RegExp(r'^\d+').firstMatch(label)?.group(0) ?? '';
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.card,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.primary, width: 2),
      ),
      child: Text(n, style: AppUI.label.copyWith(fontSize: 10, color: AppColors.primaryText, fontWeight: FontWeight.w700)),
    );
  }

  Widget _button(String icon, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: Material(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.line)),
              child: AppIcon(icon, size: 16, color: AppColors.primaryText),
            ),
          ),
        ),
      );
}

/// This stop: a marigold pin, its point at the bottom.
class _Pin extends StatelessWidget {
  const _Pin();

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppColors.gold,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2))],
        ),
        alignment: Alignment.center,
        child: const AppIcon('location', size: 16, color: Colors.white),
      );
}
