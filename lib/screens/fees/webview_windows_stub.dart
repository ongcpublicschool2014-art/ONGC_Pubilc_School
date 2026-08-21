import 'dart:async';
import 'package:flutter/material.dart';

class WebviewController {
  Future<void> initialize() async => throw UnsupportedError('Webview is not available on this platform.');
  Future<void> setBackgroundColor(Color color) async {}
  Future<void> loadUrl(String url) async {}
  Stream<String> get url => const Stream<String>.empty();
  Stream<dynamic> get webMessage => const Stream<dynamic>.empty();
  void dispose() {}
}

class Webview extends StatelessWidget {
  final WebviewController controller;
  const Webview(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Online payments are not available on the web build. '
          'Please use the desktop app.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
