import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/phone_remote_host.dart';
import 'package:dsh_app/ui/engine/phone_remote_host_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'phone_remote_host_test.dart' show FakePhoneHost;

void main() {
  for (final locale in AppLocale.supported) {
    for (final brightness in Brightness.values) {
      final name = 'phone_host_${locale.languageCode}_${brightness.name}';
      testWidgets(name, (tester) async {
        AppLocale.use(locale);
        addTearDown(() => AppLocale.use(AppLocale.zhCN));
        usePhoneSurface(tester);
        tester.view.physicalSize = const Size(320 * 2, 640 * 2);
        await tester.pumpWidget(
          goldenApp(
            home: const Scaffold(body: PhoneRemoteHostSettings()),
            brightness: brightness,
            overrides: [
              phoneRemoteHostBackendProvider.overrideWithValue(FakePhoneHost()),
              localRuntimeProvider.overrideWith(
                () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));

        tester.view.viewInsets = const FakeViewPadding(bottom: 250 * 2);
        await tester.showKeyboard(find.byType(TextField).last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(FilledButton));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(FilledButton).hitTestable(), findsOneWidget);
      });
    }
  }
}
