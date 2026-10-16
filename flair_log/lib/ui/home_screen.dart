import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/shot.dart';
import 'brew_screen.dart';
import 'scale_screen.dart';
import 'settings_screen.dart';
import 'shot_detail_screen.dart';
import 'widgets/brew_chart.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flair Log'),
        actions: [
          IconButton(
            tooltip: 'Scale',
            icon: const Icon(Icons.scale_outlined),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const ScaleScreen())),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const BrewScreen())),
        icon: const Icon(Icons.coffee),
        label: const Text('Brew'),
      ),
      body: ListenableBuilder(
        listenable: app.shots,
        builder: (context, _) {
          final shots = app.shots.shots;
          if (shots.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No shots yet.\n\nTap Brew, point the camera at the Flair 58 '
                  'gauge and pull a shot. Turn on demo mode in settings to try '
                  'it without the machine.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: shots.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _ShotTile(shot: shots[i]),
          );
        },
      ),
    );
  }
}

class _ShotTile extends StatelessWidget {
  const _ShotTile({required this.shot});
  final Shot shot;

  @override
  Widget build(BuildContext context) {
    final d = shot.startedAt;
    String two(int v) => v.toString().padLeft(2, '0');
    final parts = <String>[
      '${shot.duration.toStringAsFixed(0)} s',
      if (shot.yieldWeight != null) '${shot.yieldWeight!.toStringAsFixed(1)} g',
      if (shot.ratio != null) '1:${shot.ratio!.toStringAsFixed(1)}',
      if (shot.peakPressure != null) 'peak ${shot.peakPressure!.toStringAsFixed(1)} bar',
    ];
    return ListTile(
      title: Text(shot.beans.isNotEmpty
          ? shot.beans
          : '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}'),
      subtitle: Text(parts.join(' · ')),
      trailing: SizedBox(
        width: 72,
        height: 32,
        child: CustomPaint(
          painter: _Sparkline(shot, ChartColors.pressure(Theme.of(context).brightness)),
        ),
      ),
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => ShotDetailScreen(shot: shot))),
    );
  }
}

class _Sparkline extends CustomPainter {
  _Sparkline(this.shot, this.color);
  final Shot shot;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = shot.samples.where((s) => s.pressure != null).toList();
    if (pts.length < 2) return;
    final tMax = math.max(1.0, shot.duration);
    final pMax = math.max(10.0, shot.peakPressure ?? 0);
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final o = Offset(pts[i].t / tMax * size.width,
          size.height - pts[i].pressure! / pMax * size.height);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant _Sparkline old) => old.shot != shot;
}
