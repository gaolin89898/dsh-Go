import 'dart:io';

import 'package:dsh_app/state/phone_remote_host.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart' show RemoteAccount, MemorySecretStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Run only against a disposable local engine and Server with synthetic accounts.
void main() {
  final env = Platform.environment;
  final enabled = env['DSH_PHONE_HOST_LIVE_URL'] != null;
  test(
    'native Host backend installs, authorizes, reloads and disables the real fork',
    () async {
      final client = await DshClient.connect(
        baseUri: Uri.parse(env['DSH_PHONE_HOST_LIVE_URL']!),
        token: env['DSH_PHONE_HOST_LIVE_TOKEN']!,
        startMux: false,
      );
      addTearDown(client.close);
      final backend = ClientPhoneRemoteHostBackend(client);
      expect((await backend.read()).installed, isFalse);
      final container = ProviderContainer(overrides: [phoneRemoteHostBackendProvider.overrideWithValue(backend)]);
      addTearDown(container.dispose);
      container.read(phoneRemoteHostProvider);
      await container.pump();
      await container
          .read(phoneRemoteHostProvider.notifier)
          .enable(
            server: env['DSH_PHONE_HOST_LIVE_SERVER']!,
            name: 'Spare phone',
            email: env['DSH_PHONE_HOST_LIVE_EMAIL']!,
            password: env['DSH_PHONE_HOST_LIVE_PASSWORD']!,
          );
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!(await backend.read()).online && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final online = await backend.read();
      expect(online.authorized, isTrue);
      expect(online.online, isTrue);
      expect(online.name, 'Spare phone');
      final session = await client.createSession();
      final account = RemoteAccount(
        secrets: MemorySecretStore(),
        serverUrl: env['DSH_PHONE_HOST_LIVE_SERVER']!,
        deviceName: 'Another client',
        platform: 'dsh-app-test',
      );
      addTearDown(account.close);
      await account.loginWithPassword(env['DSH_PHONE_HOST_LIVE_EMAIL']!, env['DSH_PHONE_HOST_LIVE_PASSWORD']!);
      final host = (await account.listHosts()).singleWhere((h) => h.id == online.deviceId);
      expect(host.name, 'Spare phone');
      final remote = await account.connectHost(host);
      addTearDown(remote.close);
      expect((await remote.listSessions()).any((s) => s.sessionId == session.sessionId), isTrue);
      await remote.renameSession(session.sessionId, 'Continued remotely');
      expect(
        (await client.listSessions()).singleWhere((s) => s.sessionId == session.sessionId).title,
        'Continued remotely',
      );
      await remote.close();
      await account.logout();
      await backend.prepare(server: env['DSH_PHONE_HOST_LIVE_SERVER']!, name: 'Renamed phone', checkOwner: () {});
      expect((await backend.read()).name, 'Renamed phone');
      await backend.disable();
      final off = await backend.read();
      expect(off.enabled, isFalse);
      expect(off.installed, isTrue);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
