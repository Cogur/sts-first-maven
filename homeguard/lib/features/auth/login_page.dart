import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/device.dart';
import '../../theme/app_theme.dart';
import 'auth_controller.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _remote = TextEditingController();
  final _template = TextEditingController();
  bool _remember = true;
  bool _biometric = false;
  bool _obscure = true;
  bool _showRemote = false;
  RemoteMode _remoteMode = RemoteMode.vpn;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthController>();
    final r = auth.remembered;
    if (r != null) {
      _host.text = r.host;
      _user.text = r.username;
    }
    _biometric = auth.biometricAvailable && (r?.biometricEnabled ?? false);
    if (auth.status == AuthStatus.locked) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _biometricUnlock());
    }
  }

  @override
  void dispose() {
    _host.dispose();
    _user.dispose();
    _pass.dispose();
    _remote.dispose();
    _template.dispose();
    super.dispose();
  }

  Future<void> _biometricUnlock() async {
    setState(() => _error = null);
    final ok = await context.read<AuthController>().unlockWithBiometrics();
    if (!ok && mounted) setState(() => _error = 'Biometric unlock failed. Sign in with your password.');
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AuthController>().signIn(
        host: _host.text,
        username: _user.text,
        password: _pass.text,
        remember: _remember,
        enableBiometrics: _biometric,
        remoteHost: _showRemote ? _remote.text : '',
        remoteMode: _remoteMode,
        cameraPathTemplate: _template.text,
      );
    } on LoginException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Sign-in failed: $e');
    } finally {
      _pass.clear();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.shield_moon_outlined, size: 56, color: AppColors.primary),
                      const SizedBox(height: 12),
                      Text('HomeGuard', textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
                      const SizedBox(height: 4),
                      const Text(
                        'Local-first access to your NVR, cameras and door station',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                      const SizedBox(height: 28),
                      if (auth.status == AuthStatus.locked && auth.canUseBiometricUnlock) ...[
                        FilledButton.icon(
                          onPressed: _busy ? null : _biometricUnlock,
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('Unlock with biometrics'),
                        ),
                        const SizedBox(height: 16),
                        const Row(
                          children: [
                            Expanded(child: Divider()),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 8),
                              child: Text('or', style: TextStyle(color: AppColors.textMuted)),
                            ),
                            Expanded(child: Divider()),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                      TextFormField(
                        controller: _host,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'NVR local IP / hostname',
                          hintText: '192.168.1.100 or 192.168.1.100:554',
                          prefixIcon: Icon(Icons.lan_outlined),
                        ),
                        validator: (v) =>
                            (v ?? '').trim().isEmpty && _remote.text.trim().isEmpty ? 'Required' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _user,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.username],
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _pass,
                        obscureText: _obscure,
                        enableSuggestions: false,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.password],
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? 'Show password' : 'Hide password',
                            icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) => (v ?? '').isEmpty ? 'Required' : null,
                      ),
                      const SizedBox(height: 8),
                      _AdvancedSection(controller: _template),
                      const SizedBox(height: 8),
                      _RemoteSection(
                        expanded: _showRemote,
                        controller: _remote,
                        mode: _remoteMode,
                        onExpanded: (v) => setState(() => _showRemote = v),
                        onMode: (m) => setState(() => _remoteMode = m),
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: _remember,
                        onChanged: (v) => setState(() => _remember = v),
                        title: const Text('Remember me'),
                        subtitle: const Text('Keeps username and host on this device'),
                      ),
                      if (auth.biometricAvailable)
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          value: _biometric,
                          onChanged: (v) => setState(() => _biometric = v),
                          title: const Text('Face ID / fingerprint sign-in'),
                          subtitle: const Text('Password stays in the secure keystore'),
                        ),
                      if (_error != null) ...[const SizedBox(height: 8), _ErrorBanner(message: _error!)],
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy || auth.lockoutRemaining != null ? null : _submit,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        child: _busy
                            ? const SizedBox.square(
                                dimension: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.5),
                              )
                            : const Text('Connect securely'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.tune),
          title: const Text('Advanced'),
          subtitle: const Text('Camera stream path for non-standard firmware or the simulator'),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            TextFormField(
              controller: controller,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Camera RTSP path template',
                hintText: DeviceConfig.tvtRtspTemplate,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Leave empty for Techson/TVT recorders. Placeholders: {channel}, {stream} (main/sub). '
              'A custom RTSP port can be typed after the IP, e.g. 192.168.1.50:8554.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoteSection extends StatelessWidget {
  const _RemoteSection({
    required this.expanded,
    required this.controller,
    required this.mode,
    required this.onExpanded,
    required this.onMode,
  });

  final bool expanded;
  final TextEditingController controller;
  final RemoteMode mode;
  final ValueChanged<bool> onExpanded;
  final ValueChanged<RemoteMode> onMode;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: expanded,
          onExpansionChanged: onExpanded,
          leading: const Icon(Icons.public),
          title: const Text('Remote access (optional)'),
          subtitle: const Text('Used only when the LAN address is unreachable'),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            TextFormField(
              controller: controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Remote host / domain',
                hintText: '10.8.0.2 or nvr.example.com',
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<RemoteMode>(
              segments: const [
                ButtonSegment(value: RemoteMode.vpn, label: Text('VPN tunnel'), icon: Icon(Icons.vpn_lock)),
                ButtonSegment(value: RemoteMode.tls, label: Text('TLS only'), icon: Icon(Icons.https)),
              ],
              selected: {mode},
              onSelectionChanged: (s) => onMode(s.first),
            ),
            const SizedBox(height: 8),
            Text(
              mode == RemoteMode.vpn
                  ? 'Recommended. Traffic is encrypted by your WireGuard/Tailscale/IPsec tunnel.'
                  : 'Only rtsps:// and https:// are used. Plain RTSP/HTTP over the internet is refused.',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.danger.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: AppColors.danger),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ],
    ),
  );
}
