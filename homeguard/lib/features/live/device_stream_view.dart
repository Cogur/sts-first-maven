import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/device.dart';
import '../../core/network/connection_manager.dart';
import '../../core/services/device_registry.dart';
import '../../custom_code/widgets/rtsp_player_widget.dart';
import '../../theme/app_theme.dart';

/// Resolves a device to its best route (LAN → remote) and hosts the RTSP
/// player. Re-resolves when the network changes.
class DeviceStreamView extends StatefulWidget {
  const DeviceStreamView({
    super.key,
    required this.deviceId,
    required this.quality,
    this.muted = true,
    this.fit = BoxFit.cover,
    this.playerTag,
    this.showRouteBadge = true,
  });

  final String deviceId;
  final StreamQuality quality;
  final bool muted;
  final BoxFit fit;
  final String? playerTag;
  final bool showRouteBadge;

  @override
  State<DeviceStreamView> createState() => _DeviceStreamViewState();
}

class _DeviceStreamViewState extends State<DeviceStreamView> {
  Future<ResolvedRoute>? _route;
  ConnectionManager? _connections;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.read<ConnectionManager>();
    if (!identical(c, _connections)) {
      _connections?.removeListener(_onNetwork);
      _connections = c..addListener(_onNetwork);
      _resolve();
    }
  }

  void _onNetwork() {
    // Cache was invalidated (network change) → resolve again.
    if (_connections!.cached(widget.deviceId) == null) _resolve();
  }

  void _resolve({bool force = false}) {
    setState(() => _route = _connections!.resolve(widget.deviceId, force: force));
  }

  @override
  void dispose() {
    _connections?.removeListener(_onNetwork);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registry = context.watch<DeviceRegistry>();
    final device = registry.byId(widget.deviceId);
    if (device == null) return const _Placeholder(icon: Icons.help_outline, text: 'Unknown device');

    return FutureBuilder<ResolvedRoute>(
      future: _route,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _Placeholder(icon: Icons.radar, text: 'Locating device…', busy: true);
        }
        final route = snap.data;
        if (route == null || !route.reachable) {
          return _Placeholder(
            icon: Icons.portable_wifi_off,
            text: 'Device unreachable',
            onRetry: () => _resolve(force: true),
          );
        }
        final url = route.rtspUrl(
          route.streamPath(device, widget.quality),
          registry.credentialsFor(device.id),
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            RtspPlayerWidget(
              key: ValueKey('${widget.deviceId}-${widget.quality.name}-${route.host}'),
              rtspUrl: url,
              muted: widget.muted,
              fit: widget.fit,
              playerTag: widget.playerTag,
            ),
            if (widget.showRouteBadge) Positioned(top: 8, right: 8, child: RouteBadge(route: route)),
          ],
        );
      },
    );
  }
}

class RouteBadge extends StatelessWidget {
  const RouteBadge({super.key, required this.route});
  final ResolvedRoute route;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (route.kind) {
      RouteKind.lan => ('LAN', AppColors.secure, Icons.lan),
      RouteKind.remote when route.bridge => ('P2P', AppColors.warning, Icons.hub_outlined),
      RouteKind.remote => (route.secure ? 'TLS' : 'VPN', AppColors.warning, Icons.vpn_lock),
      RouteKind.unreachable => ('OFF', AppColors.danger, Icons.link_off),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.text, this.busy = false, this.onRetry});
  final IconData icon;
  final String text;
  final bool busy;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          busy
              ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon, color: Colors.white54),
          const SizedBox(height: 8),
          Text(text, style: const TextStyle(color: Colors.white60, fontSize: 12)),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}
