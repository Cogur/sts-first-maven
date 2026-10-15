import 'network/connection_manager.dart';
import 'network/device_http_client.dart';
import 'security/biometric_service.dart';
import 'security/secure_store.dart';
import 'services/device_registry.dart';
import 'services/door_relay_service.dart';
import 'services/event_store.dart';
import 'services/intercom_service.dart';
import 'services/monitor_sync_service.dart';

/// Composition root. Widgets get these through Provider; FlutterFlow custom
/// actions (which receive only primitive arguments) use [AppServices.instance].
class AppServices {
  AppServices({
    SecureStore? store,
    BiometricService? biometrics,
    ConnectionManager? connections,
    DeviceHttpClient? http,
    EventStore? events,
  }) : store = store ?? SecureStore(),
       biometrics = biometrics ?? BiometricService(),
       connections = connections ?? ConnectionManager(),
       http = http ?? DeviceHttpClient(),
       events = events ?? EventStore() {
    registry = DeviceRegistry(this.store, this.connections);
    relay = DoorRelayService(registry, this.connections, this.http, this.events);
    intercom = IntercomService(registry, this.connections);
    monitorSync = MonitorSyncService(registry, this.connections, this.http, this.events);
  }

  static late AppServices instance;

  final SecureStore store;
  final BiometricService biometrics;
  final ConnectionManager connections;
  final DeviceHttpClient http;
  final EventStore events;
  late final DeviceRegistry registry;
  late final DoorRelayService relay;
  late final IntercomService intercom;
  late final MonitorSyncService monitorSync;
}
