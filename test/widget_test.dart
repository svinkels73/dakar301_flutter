// Basic Flutter widget test for DAKAR 301

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dakar301/main.dart';

void main() {
  testWidgets('App launches successfully', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const Dakar301App());

    // Verify that the app shows DAKAR 301 title
    expect(find.text('DAKAR 301'), findsWidgets);
  });
}
