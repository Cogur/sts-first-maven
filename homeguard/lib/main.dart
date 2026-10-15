import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/app_services.dart';
import 'core/utils/log.dart';
import 'features/auth/auth_controller.dart';
import 'features/settings/settings_controller.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    MediaKit.ensureInitialized();
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);

    FlutterError.onError = (details) {
      Log.e('flutter', details.exceptionAsString());
      FlutterError.presentError(details);
    };

    final services = AppServices.instance = AppServices();
    final settings = SettingsController(services.store);
    final auth = AuthController(
      store: services.store,
      biometrics: services.biometrics,
      registry: services.registry,
      connections: services.connections,
    );

    runApp(HomeGuardApp(services: services, auth: auth, settings: settings));

    await Future.wait([settings.load(), services.events.load()]);
    await auth.init();
  }, (error, stack) => Log.e('zone', '$error'));
}
