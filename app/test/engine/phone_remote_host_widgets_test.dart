import 'package:dsh_app/state/phone_remote_host.dart';
import 'package:dsh_app/ui/engine/phone_remote_host_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'phone_remote_host_test.dart' show FakePhoneHost;

void main() {
  Future<void> pump(WidgetTester tester, FakePhoneHost backend) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const Scaffold(body: PhoneRemoteHostSettings()),
        brightness: Brightness.light,
        overrides: [phoneRemoteHostBackendProvider.overrideWithValue(backend)],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('native switch opens prefilled setup and enables without a terminal', (tester) async {
    final backend = FakePhoneHost();
    await pump(tester, backend);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, 'https://remote.gaolin.ink');
    await tester.enterText(fields.at(1), 'Old phone');
    await tester.enterText(fields.at(2), 'me@example.test');
    await tester.enterText(fields.at(3), 'test-password');
    await tester.tap(find.widgetWithText(FilledButton, '启用'));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneRemoteHostSetupSheet), findsNothing);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });
  testWidgets('cancelled setup does not install or enable anything', (tester) async {
    final backend = FakePhoneHost();
    await pump(tester, backend);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(backend.prepares, 0);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });
}
