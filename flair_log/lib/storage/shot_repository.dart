import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/shot.dart';

/// Stores each shot as a JSON file in the app documents directory.
class ShotRepository extends ChangeNotifier {
  ShotRepository._(this._dir);

  static Future<ShotRepository> open() async {
    final docs = await getApplicationDocumentsDirectory();
    return openAt(Directory('${docs.path}/shots'));
  }

  static Future<ShotRepository> openAt(Directory dir) async {
    await dir.create(recursive: true);
    final repo = ShotRepository._(dir);
    await repo._loadAll();
    return repo;
  }

  final Directory _dir;
  final List<Shot> _shots = [];

  /// Newest first.
  List<Shot> get shots => List.unmodifiable(_shots);

  Future<void> _loadAll() async {
    _shots.clear();
    await for (final e in _dir.list()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      try {
        _shots.add(Shot.fromJson(
            jsonDecode(await e.readAsString()) as Map<String, dynamic>));
      } catch (err) {
        debugPrint('Skipping unreadable shot ${e.path}: $err');
      }
    }
    _shots.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    notifyListeners();
  }

  File _file(String id) => File('${_dir.path}/$id.json');

  Future<void> save(Shot shot) async {
    await _file(shot.id).writeAsString(jsonEncode(shot.toJson()));
    _shots.removeWhere((s) => s.id == shot.id);
    _shots.add(shot);
    _shots.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    notifyListeners();
  }

  Future<void> delete(Shot shot) async {
    final f = _file(shot.id);
    if (await f.exists()) await f.delete();
    _shots.removeWhere((s) => s.id == shot.id);
    notifyListeners();
  }

  /// Writes JSON + CSV exports to a temp dir and returns the files.
  Future<List<File>> exportFiles(Shot shot) async {
    final tmp = await getTemporaryDirectory();
    final base = 'shot_${shot.startedAt.toIso8601String().replaceAll(':', '-').split('.').first}';
    final json = File('${tmp.path}/$base.json');
    final csv = File('${tmp.path}/$base.csv');
    await json.writeAsString(const JsonEncoder.withIndent('  ').convert(shot.toJson()));
    await csv.writeAsString(shot.toCsv());
    return [csv, json];
  }
}
