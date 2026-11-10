import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show DshRemoteException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/engine_control.dart';
import '../../state/phone_remote_host.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../settings/settings_widgets.dart';
import '../theme/theme.dart';
import '../theme/app_icons.dart';

String phoneRemoteHostError(Object error, L10n l10n) => switch (error) {
  DshRemoteException(code: 'phone-host/restart-required') => l10n.phoneRemoteHostRestartRequired,
  DshRemoteException(code: 'phone-host/owner-changed' || 'phone-host/engine-offline') => l10n.phoneRemoteHostEngineOff,
  DshRemoteException(code: 'phone-host/config-fixed' || 'phone-host/config-unconfirmed') =>
    l10n.phoneRemoteHostConfigFailed,
  DshRemoteException(code: 'AUTH_INVALID' || 'INVALID_CREDENTIALS' || 'ACCOUNT_AUTH_REQUIRED' || 'UNAUTHORIZED') =>
    l10n.remoteErrSignIn,
  _ => l10n.phoneRemoteHostFailed,
};

class PhoneRemoteHostSettings extends ConsumerStatefulWidget {
  const PhoneRemoteHostSettings({super.key});

  @override
  ConsumerState<PhoneRemoteHostSettings> createState() => _PhoneRemoteHostSettingsState();
}

class _PhoneRemoteHostSettingsState extends ConsumerState<PhoneRemoteHostSettings> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (ModalRoute.of(context)?.isCurrent != false) unawaited(ref.read(phoneRemoteHostProvider.notifier).refresh());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _setup() => showAppSheet<void>(
    context,
    isScrollControlled: true,
    dismissal: SheetDismissal.button,
    builder: (_) => const PhoneRemoteHostSetupSheet(),
  );

  Future<void> _disable() async {
    try {
      await ref.read(phoneRemoteHostProvider.notifier).disable();
    } catch (_) {}
  }

  Future<void> _reconnect() async {
    try {
      await ref.read(phoneRemoteHostProvider.notifier).reconnect();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final runtime = ref.watch(localRuntimeProvider).status;
    final state = ref.watch(phoneRemoteHostProvider);
    final backend = ref.watch(phoneRemoteHostBackendProvider);
    final status = state.status;
    final ready = backend != null && !state.loading && !state.busy;
    final subtitle = state.busy
        ? l10n.phoneRemoteHostWorking
        : runtime.inSafeMode
        ? l10n.phoneRemoteHostSafeMode
        : runtime.phase != RuntimePhase.running
        ? l10n.phoneRemoteHostEngineOff
        : backend == null || state.loading
        ? l10n.phoneRemoteHostChecking
        : state.error != null
        ? phoneRemoteHostError(state.error!, l10n)
        : !status.enabled
        ? l10n.phoneRemoteHostOff
        : !status.authorized
        ? l10n.phoneRemoteHostSignInRequired
        : status.online
        ? l10n.phoneRemoteHostOnline(status.name)
        : l10n.phoneRemoteHostOffline;
    return SettingsSection(
      title: l10n.phoneRemoteHostTitle,
      children: [
        SettingsSwitchTile(
          key: const ValueKey('phone-remote-host-switch'),
          icon: AppIcons.remoteHost,
          title: l10n.phoneRemoteHostAllow,
          subtitle: subtitle,
          value: status.enabled,
          onChanged: ready ? (enabled) => unawaited(enabled ? _setup() : _disable()) : null,
        ),
        if (status.enabled && ready) ...[
          SettingsTile(
            icon: AppIcons.account,
            title: status.name,
            subtitle: [status.account, status.server].nonNulls.join(' · '),
            onTap: _setup,
          ),
          if (!status.online)
            SettingsTile(
              icon: status.authorized ? AppIcons.refresh : AppIcons.account,
              title: status.authorized ? l10n.remoteReconnect : l10n.commonSignIn,
              onTap: status.authorized ? _reconnect : _setup,
            ),
        ],
        if (state.error is DshRemoteException &&
            (state.error as DshRemoteException).code == 'phone-host/restart-required')
          SettingsTile(
            icon: AppIcons.restart,
            title: l10n.phoneEngineRestart,
            onTap: () => EngineControl.restart(ProviderScope.containerOf(context, listen: false)),
          ),
        if (state.error != null && ready)
          SettingsTile(
            icon: AppIcons.refresh,
            title: l10n.commonRetry,
            onTap: () => ref.read(phoneRemoteHostProvider.notifier).refresh(),
          ),
      ],
    );
  }
}

class PhoneRemoteHostSetupSheet extends ConsumerStatefulWidget {
  const PhoneRemoteHostSetupSheet({super.key});

  @override
  ConsumerState<PhoneRemoteHostSetupSheet> createState() => _PhoneRemoteHostSetupSheetState();
}

class _PhoneRemoteHostSetupSheetState extends ConsumerState<PhoneRemoteHostSetupSheet> {
  late final _server = TextEditingController(text: ref.read(phoneRemoteHostProvider).status.server);
  late final _name = TextEditingController(text: ref.read(phoneRemoteHostProvider).status.name);
  late final _email = TextEditingController(text: ref.read(phoneRemoteHostProvider).status.account ?? '');
  final _password = TextEditingController();
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _server.dispose();
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _enable() async {
    if (_busy) return;
    if ([_server.text, _name.text, _email.text].any((v) => v.trim().isEmpty) || _password.text.isEmpty) {
      setState(() => _error = const DshRemoteException('phone-host/required', 'Required fields missing'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await ref
          .read(phoneRemoteHostProvider.notifier)
          .enable(server: _server.text, name: _name.text, email: _email.text, password: _password.text);
      _password.clear();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restart() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    _password.clear();
    try {
      if (!await EngineControl.restart(ProviderScope.containerOf(context, listen: false))) {
        throw const DshRemoteException('phone-host/restart-required', 'Local engine did not stop');
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(phoneRemoteHostProvider);
    final ready = ref.watch(phoneRemoteHostBackendProvider) != null && !state.busy;
    final restart =
        _error is DshRemoteException && (_error as DshRemoteException).code == 'phone-host/restart-required';
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.phoneRemoteHostAllow, maxLines: null),
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 8, SheetTitleBar.inset, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    TextField(
                      controller: _server,
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(labelText: l10n.remoteServerAddress),
                    ),
                    TextField(
                      controller: _name,
                      enabled: !_busy,
                      maxLength: 100,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(labelText: l10n.phoneRemoteHostName, counterText: ''),
                    ),
                    TextField(
                      controller: _email,
                      enabled: !_busy,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      decoration: InputDecoration(labelText: l10n.remoteEmail),
                    ),
                    TextField(
                      controller: _password,
                      enabled: !_busy,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) {
                        if (ready) unawaited(_enable());
                      },
                      decoration: InputDecoration(labelText: l10n.remotePassword),
                    ),
                    if (_error case final error?)
                      Text(
                        error is DshRemoteException && error.code == 'phone-host/required'
                            ? l10n.phoneRemoteHostRequired
                            : phoneRemoteHostError(error, l10n),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).danger),
                      ),
                    if (restart)
                      FilledButton.icon(
                        onPressed: _busy ? null : _restart,
                        icon: const Icon(AppIcons.restart),
                        label: Text(l10n.phoneEngineRestart),
                      )
                    else
                      FilledButton.icon(
                        onPressed: _busy || !ready ? null : _enable,
                        icon: _busy
                            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(AppIcons.remoteHost),
                        label: Text(_busy ? l10n.phoneRemoteHostWorking : l10n.phoneRemoteHostEnable),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
