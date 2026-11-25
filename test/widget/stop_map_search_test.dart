import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/screens/transport/stop_map_picker.dart';

/// The stop map's search (Routes & Stops > stop form): coordinates and
/// Google Maps links are read without any lookup; a name is searched, and the
/// place picked fills the stop's Latitude / Longitude.
void main() {
  group('trParseCoordinates', () {
    TrPlace? p(String s) => trParseCoordinates(s);

    test('a typed or pasted pair', () {
      expect(p('10.5920, 77.2440')?.lat, 10.592);
      expect(p('10.5920 77.2440')?.lon, 77.244);
      expect(p('  10.5920,77.2440  ')?.lat, 10.592);
    });

    test('Google Maps links', () {
      expect(p('https://www.google.com/maps/@10.5920,77.2440,17z')?.lat, 10.592);
      expect(p('https://maps.google.com/?q=10.5920,77.2440')?.lon, 77.244);
      // a place link: the place itself (!3d/!4d), not the map's centre (@)
      final place = p('https://www.google.com/maps/place/Bus+Stand/@10.59,77.24,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d10.5921!4d77.2441');
      expect(place?.lat, 10.5921);
      expect(place?.lon, 77.2441);
    });

    test('names and impossible positions are not coordinates', () {
      expect(p('SV Puram Udumalpet'), isNull);
      expect(p('90, 90'), isNull); // the old placeholder
      expect(p('0, 0'), isNull);
      expect(p('100, 77'), isNull);
      expect(p(''), isNull);
    });
  });

  testWidgets('search a place, pick it: the stop position fills in', (t) async {
    StopMapPicker.tilesEnabled = false;
    addTearDown(() => StopMapPicker.searchPlaces = trNominatimSearch);
    final lat = TextEditingController(text: '90'), lon = TextEditingController(text: '90');
    addTearDown(lat.dispose);
    addTearDown(lon.dispose);
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: SizedBox(width: 800, child: StopMapPicker(lat: lat, lon: lon))),
        ),
      ),
    ));
    await t.pump();
    final box = find.byType(TextField).first;

    // a name: searched, the results listed, the one picked fills the position
    var asked = '';
    StopMapPicker.searchPlaces = (q, {near}) async {
      asked = q;
      return const [TrPlace('Udumalpet Railway Station, Tiruppur, Tamil Nadu, India', 10.5813, 77.2475)];
    };
    await t.enterText(box, 'udumalpet railway');
    await t.tap(find.text('Search'));
    await t.pump();
    expect(asked, 'udumalpet railway');
    expect(find.textContaining('Udumalpet Railway Station, Tiruppur'), findsOneWidget);
    await t.tap(find.textContaining('Udumalpet Railway Station, Tiruppur'));
    await t.pump();
    expect(lat.text, '10.581300');
    expect(lon.text, '77.247500');
    expect(find.textContaining('Placed at Udumalpet Railway Station'), findsOneWidget);

    // coordinates: straight there, no search
    asked = '';
    await t.enterText(box, '10.5920, 77.2440');
    await t.tap(find.text('Search'));
    await t.pump();
    expect(asked, '');
    expect(lat.text, '10.592000');
    expect(lon.text, '77.244000');

    // nothing found, and no internet
    StopMapPicker.searchPlaces = (q, {near}) async => const [];
    await t.enterText(box, 'nowhere at all');
    await t.tap(find.text('Search'));
    await t.pump();
    expect(find.textContaining('No place found for "nowhere at all"'), findsOneWidget);
    StopMapPicker.searchPlaces = (q, {near}) async => throw Exception('offline');
    await t.enterText(box, 'anything');
    await t.tap(find.text('Search'));
    await t.pump();
    expect(find.textContaining('Could not search right now'), findsOneWidget);
    expect(lat.text, '10.592000', reason: 'a failed search leaves the position as it was');
    expect(t.takeException(), isNull);
  });
}
