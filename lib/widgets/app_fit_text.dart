import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// One line of text that shrinks a little (never below [minScale] of its
/// size) to fit its width, and only then ends in "…". It keeps the full
/// line height, so it stays centred where it sits (e.g. a field hint).
///
/// A render object rather than a LayoutBuilder, so it also works inside
/// IntrinsicHeight / IntrinsicWidth and anything else that measures first.
class AppFitText extends LeafRenderObjectWidget {
  const AppFitText(this.text, {super.key, this.style, this.minScale = 0.8});

  final String text;
  final TextStyle? style;
  final double minScale;

  TextStyle _style(BuildContext context) => DefaultTextStyle.of(context).style.merge(style);

  @override
  RenderAppFitText createRenderObject(BuildContext context) => RenderAppFitText(
        text: text,
        style: _style(context),
        minScale: minScale,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      );

  @override
  void updateRenderObject(BuildContext context, RenderAppFitText renderObject) {
    renderObject
      ..text = text
      ..style = _style(context)
      ..minScale = minScale
      ..textDirection = Directionality.of(context)
      ..textScaler = MediaQuery.textScalerOf(context);
  }
}

class RenderAppFitText extends RenderBox {
  RenderAppFitText({
    required String text,
    required TextStyle style,
    required double minScale,
    required TextDirection textDirection,
    required TextScaler textScaler,
  })  : _text = text,
        _style = style,
        _minScale = minScale,
        _textDirection = textDirection,
        _textScaler = textScaler;

  String _text;
  set text(String v) {
    if (v == _text) return;
    _text = v;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  TextStyle _style;
  set style(TextStyle v) {
    if (v == _style) return;
    _style = v;
    markNeedsLayout();
  }

  double _minScale;
  set minScale(double v) {
    if (v == _minScale) return;
    _minScale = v;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection v) {
    if (v == _textDirection) return;
    _textDirection = v;
    markNeedsLayout();
  }

  TextScaler _textScaler;
  set textScaler(TextScaler v) {
    if (v == _textScaler) return;
    _textScaler = v;
    markNeedsLayout();
  }

  final TextPainter _painter = TextPainter(maxLines: 1, ellipsis: '…');

  /// The font size used in the last layout (for tests).
  double usedFontSize = 0;

  TextPainter _measure(double fontSize) {
    final tp = TextPainter(
      text: TextSpan(text: _text, style: _style.copyWith(fontSize: fontSize)),
      maxLines: 1,
      textDirection: _textDirection,
      textScaler: _textScaler,
    )..layout();
    return tp;
  }

  double get _baseSize => _style.fontSize ?? 14;

  // Asked for its narrowest width (e.g. by IntrinsicWidth or a dropdown),
  // it answers the most it can shrink to, not 0.
  @override
  double computeMinIntrinsicWidth(double height) => computeMaxIntrinsicWidth(height) * _minScale;

  @override
  double computeMaxIntrinsicWidth(double height) {
    final tp = _measure(_baseSize);
    final w = tp.width;
    tp.dispose();
    return w;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    final tp = _measure(_baseSize);
    final h = tp.height;
    tp.dispose();
    return h;
  }

  @override
  double computeMaxIntrinsicHeight(double width) => computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final tp = _measure(_baseSize);
    final size = constraints.constrain(Size(tp.width, tp.height));
    tp.dispose();
    return size;
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final top = (size.height - _painter.height) / 2;
    return top + _painter.computeDistanceToActualBaseline(baseline);
  }

  @override
  void performLayout() {
    final full = _measure(_baseSize);
    final fullW = full.width;
    final lineH = full.height;
    full.dispose();
    var scale = 1.0;
    if (constraints.hasBoundedWidth && fullW > constraints.maxWidth && fullW > 0) {
      scale = (constraints.maxWidth / fullW * 0.98).clamp(_minScale, 1.0);
    }
    usedFontSize = _baseSize * scale;
    _painter
      ..text = TextSpan(text: _text, style: _style.copyWith(fontSize: usedFontSize))
      ..textDirection = _textDirection
      ..textScaler = _textScaler
      ..layout(maxWidth: constraints.hasBoundedWidth ? constraints.maxWidth : double.infinity);
    size = constraints.constrain(Size(_painter.width, lineH));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final dy = (size.height - _painter.height) / 2;
    final overflows = _painter.width > size.width || _painter.height > size.height;
    if (overflows) {
      context.canvas
        ..save()
        ..clipRect(offset & size);
    }
    _painter.paint(context.canvas, offset + Offset(0, dy));
    if (overflows) context.canvas.restore();
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..label = _text
      ..textDirection = _textDirection;
  }

  @override
  void dispose() {
    _painter.dispose();
    super.dispose();
  }
}
