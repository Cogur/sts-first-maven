import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_scope.dart';
import '../models/shot.dart';
import 'widgets/brew_chart.dart';

class ShotDetailScreen extends StatefulWidget {
  const ShotDetailScreen({super.key, required this.shot});
  final Shot shot;

  @override
  State<ShotDetailScreen> createState() => _ShotDetailScreenState();
}

class _ShotDetailScreenState extends State<ShotDetailScreen> {
  late final _dose =
      TextEditingController(text: widget.shot.dose?.toStringAsFixed(1) ?? '');
  late final _beans = TextEditingController(text: widget.shot.beans);
  late final _grind = TextEditingController(text: widget.shot.grind);
  late final _notes = TextEditingController(text: widget.shot.notes);
  bool _dirty = false;

  @override
  void dispose() {
    _dose.dispose();
    _beans.dispose();
    _grind.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = widget.shot;
    s.dose = double.tryParse(_dose.text.replaceAll(',', '.'));
    s.beans = _beans.text.trim();
    s.grind = _grind.text.trim();
    s.notes = _notes.text.trim();
    await AppScope.of(context).shots.save(s);
    if (mounted) setState(() => _dirty = false);
  }

  Future<void> _share(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    final files = await AppScope.of(context).shots.exportFiles(widget.shot);
    await SharePlus.instance.share(ShareParams(
      files: files.map((f) => XFile(f.path)).toList(),
      subject: 'Espresso shot ${_date(widget.shot.startedAt)}',
      sharePositionOrigin: origin,
    ));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete shot?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await AppScope.of(context).shots.delete(widget.shot);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.shot;
    final theme = Theme.of(context);
    String f(double? v, int d, String unit) =>
        v == null ? '–' : '${v.toStringAsFixed(d)} $unit';
    final dose = double.tryParse(_dose.text.replaceAll(',', '.'));
    final y = s.yieldWeight;
    final ratio = (dose != null && dose > 0 && y != null) ? y / dose : null;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _dirty) _save();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_date(s.startedAt)),
          actions: [
            Builder(
              builder: (bc) => IconButton(
                tooltip: 'Export CSV / JSON',
                icon: const Icon(Icons.ios_share),
                onPressed: () => _share(bc),
              ),
            ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            SizedBox(
              height: 380,
              child: BrewChart(
                samples: s.samples,
                minSeconds: 10,
                showWeight: s.hasWeight,
                showFlow: s.hasFlow,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Stat('Time', f(s.duration, 1, 's')),
                _Stat('Yield', f(y, 1, 'g')),
                _Stat('Ratio', ratio == null ? '–' : '1:${ratio.toStringAsFixed(1)}'),
                _Stat('Peak', f(s.peakPressure, 1, 'bar')),
                _Stat('Avg >1 bar', f(s.meanPressure, 1, 'bar')),
                _Stat('First drops', f(s.timeToFirstDrop, 1, 's')),
              ],
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _dose,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Dose (g)'),
                  onChanged: (_) => setState(() => _dirty = true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _grind,
                  decoration: const InputDecoration(labelText: 'Grind'),
                  onChanged: (_) => _dirty = true,
                ),
              ),
            ]),
            TextField(
              controller: _beans,
              decoration: const InputDecoration(labelText: 'Beans'),
              onChanged: (_) => _dirty = true,
            ),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(labelText: 'Tasting notes'),
              maxLines: 3,
              onChanged: (_) => _dirty = true,
            ),
            const SizedBox(height: 12),
            Row(children: [
              Text('Rating', style: theme.textTheme.bodyMedium),
              for (var i = 1; i <= 5; i++)
                IconButton(
                  icon: Icon(i <= s.rating ? Icons.star : Icons.star_border),
                  onPressed: () {
                    setState(() => s.rating = i == s.rating ? 0 : i);
                    _save();
                  },
                ),
            ]),
            const SizedBox(height: 8),
            FilledButton.tonal(onPressed: _save, child: const Text('Save notes')),
          ],
        ),
      ),
    );
  }
}

String _date(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      width: 108,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(value, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
