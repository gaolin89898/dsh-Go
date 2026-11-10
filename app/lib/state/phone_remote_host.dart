import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart' show normalizeServerUrl;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import 'app_info.dart';
import 'connection_state.dart';

const phoneRemotePlugin = 'ds-harness-remote';
const phoneRemotePluginSpec =
    'git+https://github.com/gaolin89898/ds-harness-remote.git#51eed7e1cfb73d3482a04c25cd8e13a00b52a7a1';

class PhoneRemoteHostStatus {
  const PhoneRemoteHostStatus({
    this.installed = false,
    this.enabled = false,
    this.online = false,
    this.authorized = false,
    this.server = AppInfo.remoteServer,
    this.name = 'DSH Go',
    this.account,
    this.deviceId,
  });

  final bool installed;
  final bool enabled;
  final bool online;
  final bool authorized;
  final String server;
  final String name;
  final String? account;
  final String? deviceId;
}

abstract class PhoneRemoteHostBackend {
  Future<PhoneRemoteHostStatus> read();
  Future<void> prepare({required String server, required String name, required void Function() checkOwner});
  Future<void> login(String email, String password);
  Future<void> disable();
  Future<void> reconnect();
}

/// Only constructed from the local engine's authenticated HTTP connection.
class ClientPhoneRemoteHostBackend implements PhoneRemoteHostBackend {
  ClientPhoneRemoteHostBackend(this.client);

  final DshClient client;
  int _requestId = 0;

  Future<PluginBundle?> _bundle() async =>
      (await client.listBundles()).where((b) => b.name == phoneRemotePlugin).singleOrNull;

  Future<PluginConfigEntryDetail> _configuration(void Function() checkOwner) async {
    final entries = await client.listPluginConfig();
    checkOwner();
    final entry = entries?.where((e) => e.package == phoneRemotePlugin).singleOrNull;
    if (entry == null) {
      throw const DshRemoteException('phone-host/config-unavailable', 'Phone Remote configuration unavailable');
    }
    final detail = await client.readPluginConfig(entry.entryId);
    checkOwner();
    return detail;
  }

  Future<Object?> _control(String method, [Map<String, Object?> payload = const {}]) async {
    final id = 'phone-host-${++_requestId}';
    final response = await client.connection.postJson('/$phoneRemotePlugin/$method', {
      'type': 'client-request',
      'rpcId': id,
      'method': method,
      'payload': payload,
    }, timeout: const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw DshHttpException(response.statusCode, 'Phone Remote control unavailable');
    }
    final wire = jsonDecode(response.text);
    if (wire is! Map || wire['type'] != 'server-response' || wire['rpcId'] != id || wire['result'] is! Map) {
      throw const DshProtocolException('Invalid Phone Remote response');
    }
    final result = wire['result'] as Map;
    if (result['ok'] != true) {
      final error = result['error'];
      throw DshRemoteException(
        error is Map && error['code'] is String ? error['code'] as String : 'phone-host/control-failed',
        'Phone Remote control failed',
      );
    }
    return result['value'];
  }

  @override
  Future<PhoneRemoteHostStatus> read() async {
    final bundle = await _bundle();
    if (bundle == null) return const PhoneRemoteHostStatus();
    final Object? settings;
    try {
      settings = await _control('settings.get');
    } on DshHttpException catch (error) {
      if (!bundle.enabled && (error.statusCode == 404 || error.statusCode == 405)) {
        return const PhoneRemoteHostStatus(installed: true);
      }
      rethrow;
    }
    final status = await _control('status');
    if (settings is! Map || settings['config'] is! Map || status is! Map) {
      throw const DshProtocolException('Invalid Phone Remote status');
    }
    if (status['startupError'] != null) {
      throw const DshRemoteException('phone-host/startup-failed', 'Phone Remote startup failed');
    }
    final config = settings['config'] as Map;
    // The plugin deliberately omits deviceName from its settings.get view.
    final detail = await _configuration(() {});
    final host = status['host'] is Map ? status['host'] as Map : const {};
    final policy = config['hostControl'];
    return PhoneRemoteHostStatus(
      installed: true,
      enabled:
          config['enabled'] != false && config['role'] != 'client' && (policy is! Map || policy['enabled'] != false),
      online: host['online'] == true,
      authorized: host['authorized'] == true && host['accountRequired'] != true,
      server: config['serverUrl'] is String ? config['serverUrl'] as String : AppInfo.remoteServer,
      name: detail.value['deviceName'] is String ? detail.value['deviceName'] as String : 'DSH Go',
      account: host['account'] is String ? host['account'] as String : null,
      deviceId: host['deviceId'] is String ? host['deviceId'] as String : null,
    );
  }

  void _applied(PluginOperationResult result, {bool allowRestart = false}) {
    if (result.needsRestart && !allowRestart) {
      throw const DshRemoteException('phone-host/restart-required', 'Restart the local engine to continue');
    }
    if (result.application != PluginApplication.applied && !(allowRestart && result.needsRestart)) {
      throw DshRemoteException(result.error?.code ?? 'phone-host/plugin-failed', 'Phone Remote plugin change failed');
    }
  }

  @override
  Future<void> prepare({required String server, required String name, required void Function() checkOwner}) async {
    final origin = normalizeServerUrl(server).toString();
    if (name.trim().isEmpty || name.trim().length > 100) {
      throw const DshRemoteException('phone-host/invalid-name', 'Invalid device name');
    }
    final bundle = await _bundle();
    checkOwner();
    final fresh = bundle == null;
    if (fresh || !(bundle.source?.contains('gaolin89898/ds-harness-remote') ?? false)) {
      _applied(await client.installBundle(phoneRemotePluginSpec, enabled: true, saveExact: true));
      checkOwner();
    } else if (!bundle.enabled) {
      _applied(await client.setBundleEnabled(phoneRemotePlugin, true));
      checkOwner();
    }
    final detail = await _configuration(checkOwner);
    if (!detail.writable) {
      throw const DshRemoteException('phone-host/config-fixed', 'Phone Remote configuration is fixed');
    }
    final policy = detail.value['hostControl'];
    final changed =
        detail.value['enabled'] != true ||
        detail.value['role'] != 'host' ||
        detail.value['serverUrl'] != origin ||
        detail.value['deviceName'] != name.trim() ||
        policy is! Map ||
        policy['enabled'] != true;
    if (changed) {
      await client.writePluginConfig(
        detail.entryId,
        revision: detail.revision,
        ops: [
          const SettingsOp.set(['enabled'], true),
          const SettingsOp.set(['role'], 'host'),
          SettingsOp.set(['serverUrl'], origin),
          SettingsOp.set(['deviceName'], name.trim()),
          const SettingsOp.set(['hostControl'], {'enabled': true}),
          if (fresh) ...[
            const SettingsOp.set(['codex'], {'enabled': false}),
            const SettingsOp.set(['cursor'], {'enabled': false}),
            const SettingsOp.set(['acp'], {'enabled': false}),
          ],
        ],
      );
      checkOwner();
      // The plugin's volatile config persists immediately; recreating its runtime
      // also applies role, device name and Server to the existing Host service.
      final disabled = await client.setBundleEnabled(phoneRemotePlugin, false);
      _applied(disabled, allowRestart: true);
      checkOwner();
      final enabled = await client.setBundleEnabled(phoneRemotePlugin, true);
      _applied(enabled, allowRestart: true);
      checkOwner();
      if (disabled.needsRestart || enabled.needsRestart) {
        throw const DshRemoteException('phone-host/restart-required', 'Restart the local engine to continue');
      }
    }
    // A newly activated bundle can briefly precede its HTTP route registration.
    PhoneRemoteHostStatus? confirmed;
    for (var attempt = 0; ; attempt++) {
      checkOwner();
      try {
        confirmed = await read();
        break;
      } on DshHttpException catch (error) {
        if (attempt >= 9 || ![404, 405, 503].contains(error.statusCode)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    checkOwner();
    if (!confirmed.enabled || confirmed.server != origin || confirmed.name != name.trim()) {
      throw const DshRemoteException('phone-host/config-unconfirmed', 'Phone Remote configuration was not applied');
    }
  }

  @override
  Future<void> login(String email, String password) async {
    await _control('host.account.login', {'email': email.trim(), 'password': password});
  }

  @override
  Future<void> disable() async => _applied(await client.setBundleEnabled(phoneRemotePlugin, false));

  @override
  Future<void> reconnect() async {
    await _control('host.reconnect');
  }
}

final phoneRemoteHostBackendProvider = Provider<PhoneRemoteHostBackend?>((ref) {
  final runtime = ref.watch(localRuntimeProvider.select((s) => (s.status.phase, s.status.inSafeMode)));
  if (runtime.$1 != RuntimePhase.running || runtime.$2) return null;
  final connection = ref.watch(localConnectionProvider);
  if (connection.isLoading || connection.hasError) return null;
  final local = connection.value;
  if (local == null || !local.isLocal || local.client.carrier is! DshHttpCarrier) return null;
  return ClientPhoneRemoteHostBackend(local.client);
});

class PhoneRemoteHostState {
  const PhoneRemoteHostState({
    this.status = const PhoneRemoteHostStatus(),
    this.loading = true,
    this.busy = false,
    this.error,
  });
  final PhoneRemoteHostStatus status;
  final bool loading;
  final bool busy;
  final Object? error;
}

class PhoneRemoteHostController extends Notifier<PhoneRemoteHostState> {
  int _epoch = 0;
  int _read = 0;

  @override
  PhoneRemoteHostState build() {
    final backend = ref.watch(phoneRemoteHostBackendProvider);
    final epoch = ++_epoch;
    if (backend != null) {
      Future.microtask(() {
        if (ref.mounted && epoch == _epoch) unawaited(refresh());
      });
    }
    return PhoneRemoteHostState(loading: backend != null);
  }

  Future<void> refresh() async {
    if (state.busy) return;
    final backend = ref.read(phoneRemoteHostBackendProvider);
    if (backend == null) return;
    final epoch = _epoch;
    final read = ++_read;
    try {
      final status = await backend.read();
      if (ref.mounted && epoch == _epoch && read == _read) {
        final restart = state.error;
        state = PhoneRemoteHostState(
          status: status,
          loading: false,
          error: restart is DshRemoteException && restart.code == 'phone-host/restart-required' ? restart : null,
        );
      }
    } catch (error) {
      if (ref.mounted && epoch == _epoch && read == _read) {
        state = PhoneRemoteHostState(status: state.status, loading: false, error: error);
      }
    }
  }

  Future<void> _change(Future<void> Function(PhoneRemoteHostBackend backend, void Function() check) action) async {
    if (state.busy) throw const DshRemoteException('phone-host/busy', 'Phone Remote operation in progress');
    final backend = ref.read(phoneRemoteHostBackendProvider);
    if (backend == null) throw const DshRemoteException('phone-host/engine-offline', 'Local engine unavailable');
    final epoch = _epoch;
    ++_read;
    void check() {
      if (!ref.mounted || epoch != _epoch || !identical(backend, ref.read(phoneRemoteHostBackendProvider))) {
        throw const DshRemoteException('phone-host/owner-changed', 'Local engine changed');
      }
    }

    state = PhoneRemoteHostState(status: state.status, loading: false, busy: true);
    try {
      await action(backend, check);
      check();
      final status = await backend.read();
      check();
      state = PhoneRemoteHostState(status: status, loading: false);
    } catch (error) {
      if (ref.mounted && epoch == _epoch) {
        // Re-read after a partial install/write; a failed disable must never
        // make the switch claim that an active Host has stopped.
        var status = state.status;
        try {
          status = await backend.read();
        } catch (_) {}
        if (ref.mounted && epoch == _epoch) state = PhoneRemoteHostState(status: status, loading: false, error: error);
      }
      rethrow;
    }
  }

  Future<void> enable({
    required String server,
    required String name,
    required String email,
    required String password,
  }) => _change((backend, check) async {
    await backend.prepare(server: server, name: name, checkOwner: check);
    check();
    await backend.login(email, password);
    check();
    if (!(await backend.read()).authorized) {
      throw const DshRemoteException('phone-host/login-unconfirmed', 'Host authorization was not confirmed');
    }
  });

  Future<void> disable() => _change((backend, check) async {
    await backend.disable();
    check();
    if ((await backend.read()).enabled) {
      throw const DshRemoteException('phone-host/disable-unconfirmed', 'Phone Remote remains enabled');
    }
  });

  Future<void> reconnect() => _change((backend, check) => backend.reconnect());
}

final phoneRemoteHostProvider = NotifierProvider<PhoneRemoteHostController, PhoneRemoteHostState>(
  PhoneRemoteHostController.new,
);
