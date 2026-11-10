import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/phone_remote_host.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show FakeRuntime;

class _LocalConnection extends LocalConnectionController {
  _LocalConnection(this.initial);
  final HostConnection initial;
  @override
  Future<HostConnection?> build() async => initial;
  void publish(AsyncValue<HostConnection?> value) => state = value;
}

class FakePhoneHost extends PhoneRemoteHostBackend {
  PhoneRemoteHostStatus status = const PhoneRemoteHostStatus();
  Object? loginError;
  Object? disableError;
  Completer<void>? preparing;
  int logins = 0;
  int prepares = 0;

  @override
  Future<PhoneRemoteHostStatus> read() async => status;
  @override
  Future<void> prepare({required String server, required String name, required void Function() checkOwner}) async {
    prepares++;
    await preparing?.future;
    checkOwner();
    status = PhoneRemoteHostStatus(installed: true, enabled: true, server: server, name: name);
  }

  @override
  Future<void> login(String email, String password) async {
    logins++;
    if (loginError case final error?) throw error;
    status = PhoneRemoteHostStatus(
      installed: true,
      enabled: true,
      authorized: true,
      online: true,
      name: status.name,
      server: status.server,
      account: email,
    );
  }

  @override
  Future<void> disable() async {
    if (disableError case final error?) throw error;
    status = const PhoneRemoteHostStatus(installed: true);
  }

  @override
  Future<void> reconnect() async {}
}

class _Choice extends Notifier<PhoneRemoteHostBackend?> {
  @override
  PhoneRemoteHostBackend? build() => null;
  void use(PhoneRemoteHostBackend? backend) => state = backend;
}

final _choice = NotifierProvider<_Choice, PhoneRemoteHostBackend?>(_Choice.new);

class _Host {
  late HttpServer server;
  late DshClient client;
  final requests = <(String, Map)>[];
  bool installed = false;
  bool enabled = false;
  bool running = false;
  bool authorized = false;
  bool deferredDisable = false;
  bool wrongRpcId = false;
  int missingControlRoutes = 0;
  final config = <String, Object?>{
    'enabled': true,
    'role': 'host',
    'serverUrl': 'https://old.example.com',
    'deviceName': 'Old name',
    'hostControl': {'enabled': true},
  };
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
    server.listen((req) async {
      final path = req.uri.path;
      final raw = await utf8.decoder.bind(req).join();
      final body = raw.isEmpty ? <String, Object?>{} : jsonDecode(raw) as Map;
      requests.add((path, body));
      Object? value;
      if (path.startsWith('/api/')) {
        final args = (body['payload'] as Map)['args'] as Map;
        switch (path) {
          case '/api/pluginManager/listBundles':
            value = [
              if (installed)
                {'name': phoneRemotePlugin, 'installed': true, 'enabled': enabled, 'source': phoneRemotePluginSpec},
            ];
          case '/api/pluginManager/installBundle':
            installed = enabled = running = true;
            value = {'application': 'applied'};
          case '/api/pluginManager/setBundleEnabled':
            enabled = args['enabled'] == true;
            if (!deferredDisable || enabled) running = enabled;
            value = {'application': !enabled && deferredDisable ? 'restart-required' : 'applied'};
          default:
            throw StateError('Unexpected endpoint $path');
        }
      } else if (path == '/dsh-go/v1/plugin-config') {
        value = {
          'entries': [
            {'entryId': 'phone-remote', 'package': phoneRemotePlugin},
          ],
        };
      } else if (path == '/dsh-go/v1/plugin-config/phone-remote') {
        if (req.method == 'POST') {
          for (final op in body['ops'] as List) {
            config[(op['path'] as List).single as String] = op['value'];
          }
        }
        value = {
          'v': 1,
          'entryId': 'phone-remote',
          'revision': 'test-revision',
          'schema': {'type': 'object', 'dict': {}},
          'value': config,
          'writable': true,
        };
      } else if (!running || missingControlRoutes-- > 0) {
        req.response.statusCode = 405;
        await req.response.close();
        return;
      } else if (path.endsWith('/settings.get')) {
        value = {
          'config': {...config}..remove('deviceName'),
        };
      } else if (path.endsWith('/status')) {
        value = {
          'host': {'authorized': authorized, 'online': authorized, 'deviceId': 'test-phone'},
        };
      } else if (path.endsWith('/host.account.login')) {
        authorized = true;
        value = {'status': 'authorized'};
      } else {
        throw StateError('Unexpected control $path');
      }
      final response = path.startsWith('/api/') || path.startsWith('/ds-harness-remote/')
          ? {
              'type': 'server-response',
              'rpcId': wrongRpcId ? 'other' : body['rpcId'],
              'result': {'ok': true, 'value': value},
            }
          : value;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(response));
      await req.response.close();
    });
  }

  Future<void> close() async {
    await client.close();
    await server.close(force: true);
  }
}

void main() {
  group('local Host controller', () {
    late FakePhoneHost backend;
    late ProviderContainer container;
    setUp(() async {
      backend = FakePhoneHost();
      container = ProviderContainer(
        overrides: [phoneRemoteHostBackendProvider.overrideWith((ref) => ref.watch(_choice))],
      );
      container.read(_choice.notifier).use(backend);
      container.read(phoneRemoteHostProvider);
      await container.pump();
    });
    tearDown(() => container.dispose());
    Future<void> enable() => container
        .read(phoneRemoteHostProvider.notifier)
        .enable(
          server: 'https://remote.gaolin.ink',
          name: 'Spare phone',
          email: 'me@example.test',
          password: 'test-password',
        );

    test('enables and confirms actual Host authorization; disabling preserves installation', () async {
      await enable();
      final status = container.read(phoneRemoteHostProvider).status;
      expect(status.name, 'Spare phone');
      expect(status.authorized, isTrue);
      expect(status.online, isTrue);
      await container.read(phoneRemoteHostProvider.notifier).disable();
      expect(container.read(phoneRemoteHostProvider).status.enabled, isFalse);
      expect(container.read(phoneRemoteHostProvider).status.installed, isTrue);
    });
    test('failed login retains actual enabled but unauthorized status', () async {
      backend.loginError = const DshRemoteException('AUTH_INVALID', 'refused');
      await expectLater(enable(), throwsA(isA<DshRemoteException>()));
      final state = container.read(phoneRemoteHostProvider);
      expect(state.status.enabled, isTrue);
      expect(state.status.authorized, isFalse);
      expect(state.busy, isFalse);
      expect(state.error, isNotNull);
    });
    test('failed disable never reports an active Host as off', () async {
      await enable();
      backend.disableError = const DshRemoteException('phone-host/restart-required', 'restart');
      await expectLater(container.read(phoneRemoteHostProvider.notifier).disable(), throwsA(isA<DshRemoteException>()));
      expect(container.read(phoneRemoteHostProvider).status.enabled, isTrue);
      await container.read(phoneRemoteHostProvider.notifier).refresh();
      expect(
        container.read(phoneRemoteHostProvider).error,
        isA<DshRemoteException>().having((e) => e.code, 'code', 'phone-host/restart-required'),
      );
    });
    test('engine replacement during preparation stops before sending credentials', () async {
      backend.preparing = Completer<void>();
      final result = expectLater(
        enable(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'phone-host/owner-changed')),
      );
      await Future<void>.delayed(Duration.zero);
      final replacement = FakePhoneHost();
      container.read(_choice.notifier).use(replacement);
      await container.pump();
      backend.preparing!.complete();
      await result;
      expect(backend.logins, 0);
      expect(replacement.logins, 0);
      expect(container.read(phoneRemoteHostProvider).status.enabled, isFalse);
    });
    test('concurrent enable is rejected', () async {
      backend.preparing = Completer<void>();
      final first = enable();
      await expectLater(enable(), throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'phone-host/busy')));
      backend.preparing!.complete();
      await first;
      expect(backend.prepares, 1);
    });
  });

  group('real HTTP contract', () {
    late _Host host;
    late ClientPhoneRemoteHostBackend backend;
    setUp(() async {
      host = _Host();
      await host.start();
      backend = ClientPhoneRemoteHostBackend(host.client);
    });
    tearDown(() => host.close());

    test('installs pinned fork, writes only local config and registers Host through control route', () async {
      expect((await backend.read()).installed, isFalse);
      await backend.prepare(server: 'https://remote.gaolin.ink/', name: 'Spare phone', checkOwner: () {});
      await backend.login('me@example.test', 'test-password');
      final status = await backend.read();
      expect(status.online, isTrue);
      expect(status.name, 'Spare phone');
      final install = host.requests.singleWhere((r) => r.$1.endsWith('/installBundle')).$2;
      expect(((install['payload'] as Map)['args'] as Map)['spec'], phoneRemotePluginSpec);
      final auth = host.requests.singleWhere((r) => r.$1.endsWith('/host.account.login')).$2;
      expect(auth['payload'], {'email': 'me@example.test', 'password': 'test-password'});
      expect(host.config['role'], 'host');
      expect(host.config['codex'], {'enabled': false});
      await backend.disable();
      expect((await backend.read()).enabled, isFalse);
      expect(host.installed, isTrue);
      expect(host.requests.any((r) => r.$1.endsWith('/removeBundle')), isFalse);
    });
    test('deferred disable keeps reporting the running Host and requests restart', () async {
      host.installed = host.enabled = host.running = host.authorized = true;
      host.deferredDisable = true;
      await expectLater(
        backend.disable(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'phone-host/restart-required')),
      );
      expect((await backend.read()).enabled, isTrue);
      expect((await backend.read()).online, isTrue);
    });
    test('rejects a mismatched control response', () async {
      host.installed = host.enabled = host.running = true;
      host.wrongRpcId = true;
      await expectLater(backend.read(), throwsA(isA<DshProtocolException>()));
    });
    test('waits for the activated control route before allowing login', () async {
      host.missingControlRoutes = 1;
      await backend.prepare(server: 'https://remote.gaolin.ink', name: 'Old phone', checkOwner: () {});
      expect((await backend.read()).name, 'Old phone');
    });
    test('an installed client-only plugin is not shown as allowing incoming connections', () async {
      host.installed = host.enabled = host.running = true;
      host.config['role'] = 'client';
      expect((await backend.read()).enabled, isFalse);
    });
  });

  group('local engine boundary', () {
    for (final (phase, mode, isLocal, allowed) in [
      (RuntimePhase.running, EngineMode.normal, true, true),
      (RuntimePhase.running, EngineMode.safe, true, false),
      (RuntimePhase.installed, EngineMode.normal, true, false),
      (RuntimePhase.running, EngineMode.normal, false, false),
    ]) {
      test('$phase / $mode / local=$isLocal', () async {
        final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:1')));
        final local = _LocalConnection(HostConnection(client: client, isLocal: isLocal));
        final container = ProviderContainer(
          overrides: [
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(
                LocalRuntimeState(
                  loaded: true,
                  status: RuntimeStatus(phase: phase, mode: mode),
                ),
              ),
            ),
            localConnectionProvider.overrideWith(() => local),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(client.close);
        await container.read(localConnectionProvider.future);
        expect(container.read(phoneRemoteHostBackendProvider) != null, allowed);
        if (allowed) {
          // Model Riverpod retaining the old connection during a rebuild.
          // ignore: invalid_use_of_internal_member
          local.publish(const AsyncLoading<HostConnection?>().copyWithPrevious(AsyncData(local.initial)));
          expect(container.read(phoneRemoteHostBackendProvider), isNull);
          final failed = AsyncError<HostConnection?>(StateError('stale'), StackTrace.current);
          // ignore: invalid_use_of_internal_member
          local.publish(failed.copyWithPrevious(AsyncData(local.initial)));
          expect(container.read(phoneRemoteHostBackendProvider), isNull);
        }
      });
    }
  });
}
