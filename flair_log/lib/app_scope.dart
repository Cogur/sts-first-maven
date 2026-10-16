import 'package:flutter/widgets.dart';

import 'scale/scale_manager.dart';
import 'storage/settings.dart';
import 'storage/shot_repository.dart';

/// Hands the app-wide services down the widget tree.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.settings,
    required this.scales,
    required this.shots,
    required super.child,
  });

  final Settings settings;
  final ScaleManager scales;
  final ShotRepository shots;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) => false;
}
