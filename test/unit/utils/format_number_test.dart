import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/utils/formatters.dart';

void main() {
  group('formatIndianNumber', () {
    test('numbers under 1000 unchanged', () {
      expect(formatIndianNumber(0), '0');
      expect(formatIndianNumber(1), '1');
      expect(formatIndianNumber(100), '100');
      expect(formatIndianNumber(999), '999');
    });

    test('1,000 grouped 3-digit', () {
      expect(formatIndianNumber(1000), '1,000');
      expect(formatIndianNumber(9999), '9,999');
    });

    test('Indian lakh grouping (5 digits)', () {
      expect(formatIndianNumber(12345), '12,345');
      expect(formatIndianNumber(99999), '99,999');
    });

    test('Indian lakh grouping (6 digits)', () {
      expect(formatIndianNumber(123456), '1,23,456');
      expect(formatIndianNumber(999999), '9,99,999');
    });

    test('Indian crore grouping (8 digits)', () {
      expect(formatIndianNumber(12345678), '1,23,45,678');
    });

    test('decimals retained when present', () {
      expect(formatIndianNumber(1234.5), '1,234.50');
      expect(formatIndianNumber(123456.78), '1,23,456.78');
    });

    test('negative numbers keep sign', () {
      expect(formatIndianNumber(-1234), '-1,234');
      expect(formatIndianNumber(-100000), '-1,00,000');
    });

    test('integer doubles formatted without decimals', () {
      expect(formatIndianNumber(1000.0), '1,000');
    });
  });

  group('formatCurrency', () {
    test('no rupee symbol by default (on-screen UI)', () {
      expect(formatCurrency(1234), '1,234');
    });

    test('with symbol when withSymbol=true (PDF / Excel)', () {
      expect(formatCurrency(1234, withSymbol: true), '₹1,234');
    });

    test('handles 0', () {
      expect(formatCurrency(0), '0');
    });

    test('handles large lakh value', () {
      expect(formatCurrency(1234567), '12,34,567');
    });
  });
}
