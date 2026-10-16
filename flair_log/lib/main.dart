import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_scope.dart';
import 'scale/scale_manager.dart';
import 'storage/settings.dart';
import 'storage/shot_repository.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The gauge reader assumes portrait orientation.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  final settings = await Settings.load();
  final shots = await ShotRepository.open();
  final scales = ScaleManager(settings);
  scales.reconnectLast();

  runApp(AppScope(
    settings: settings,
    scales: scales,
    shots: shots,
    child: const FlairLogApp(),
  ));
}

class FlairLogApp extends StatelessWidget {
  const FlairLogApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF6F4E37); // coffee
    return MaterialApp(
      title: 'Flair Log',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
