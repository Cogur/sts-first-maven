// Writes the printable marker sheet, assets/marker_sheet.pdf (A4).
//
//     dart run tool/marker_sheet.dart
//
// The marker geometry must match lib/vision/marker.dart (bands as fractions
// of the outer radius R): black dot 0-0.2, white 0.2-0.4, black 0.4-0.6,
// white 0.6-0.8 with a black 40° wedge pointing up, black 0.8-1.0, white
// paper beyond. The dashed cut line is at 1.4 R.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const double mm = 72 / 25.4; // PDF points per millimetre
const double pageW = 210, pageH = 297; // A4, mm

final _ops = StringBuffer();

// Page coordinates in mm from the top left; PDF wants points from the
// bottom left.
double _x(double x) => x * mm;
double _y(double y) => (pageH - y) * mm;
String _n(double v) => v.toStringAsFixed(2);

void _circle(double cx, double cy, double r) {
  const k = 0.5522847498;
  final x = _x(cx), y = _y(cy), p = r * mm, q = k * p;
  _ops
    ..writeln('${_n(x + p)} ${_n(y)} m')
    ..writeln('${_n(x + p)} ${_n(y + q)} ${_n(x + q)} ${_n(y + p)} ${_n(x)} ${_n(y + p)} c')
    ..writeln('${_n(x - q)} ${_n(y + p)} ${_n(x - p)} ${_n(y + q)} ${_n(x - p)} ${_n(y)} c')
    ..writeln('${_n(x - p)} ${_n(y - q)} ${_n(x - q)} ${_n(y - p)} ${_n(x)} ${_n(y - p)} c')
    ..writeln('${_n(x + q)} ${_n(y - p)} ${_n(x + p)} ${_n(y - q)} ${_n(x + p)} ${_n(y)} c');
}

void _disc(double cx, double cy, double r, double grey) {
  _ops.writeln('${_n(grey)} g');
  _circle(cx, cy, r);
  _ops.writeln('f');
}

/// Pie slice of radius [r] spanning [half] either side of "up" on the page.
void _slice(double cx, double cy, double r, double half) {
  final x = _x(cx), y = _y(cy), p = r * mm;
  const up = math.pi / 2;
  final a0 = up - half, a1 = up + half;
  final h = 4 / 3 * math.tan((a1 - a0) / 4) * p;
  final x0 = x + p * math.cos(a0), y0 = y + p * math.sin(a0);
  final x1 = x + p * math.cos(a1), y1 = y + p * math.sin(a1);
  _ops
    ..writeln('0 g')
    ..writeln('${_n(x)} ${_n(y)} m')
    ..writeln('${_n(x0)} ${_n(y0)} l')
    ..writeln('${_n(x0 - h * math.sin(a0))} ${_n(y0 + h * math.cos(a0))} '
        '${_n(x1 + h * math.sin(a1))} ${_n(y1 - h * math.cos(a1))} ${_n(x1)} ${_n(y1)} c')
    ..writeln('h f');
}

/// One marker; [d] is the diameter of the outer black ring in mm.
void _marker(double cx, double cy, double d) {
  final r = d / 2;
  _disc(cx, cy, 1.3 * r, 1); // keep the paper margin white
  _disc(cx, cy, r, 0);
  _disc(cx, cy, 0.8 * r, 1);
  _slice(cx, cy, 0.8 * r, 20 * math.pi / 180);
  _disc(cx, cy, 0.6 * r, 0);
  _disc(cx, cy, 0.4 * r, 1);
  _disc(cx, cy, 0.2 * r, 0);
  // Cut line.
  _ops.writeln('q 0.6 G 0.4 w [2 2] 0 d');
  _circle(cx, cy, 1.4 * r);
  _ops.writeln('S Q');
}

void _text(double x, double y, String s, {double size = 10, bool bold = false}) {
  final esc = s.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');
  _ops.writeln('0 g BT /${bold ? 'F2' : 'F1'} ${_n(size)} Tf ${_n(_x(x))} ${_n(_y(y))} Td ($esc) Tj ET');
}

void _line(double x0, double y0, double x1, double y1, {double width = 0.5}) {
  _ops.writeln('0 G ${_n(width)} w ${_n(_x(x0))} ${_n(_y(y0))} m ${_n(_x(x1))} ${_n(_y(y1))} l S');
}

void main() {
  _text(20, 22, 'Flair Log gauge marker', size: 18, bold: true);
  _text(20, 31, 'Print at 100 % (actual size, not "fit to page"). The ruler must measure 50 mm.');

  // Ruler.
  const rx = 20.0, ry = 42.0;
  _line(rx, ry, rx + 50, ry);
  for (var i = 0; i <= 50; i++) {
    final len = i % 10 == 0 ? 3.0 : (i % 5 == 0 ? 2.0 : 1.0);
    _line(rx + i, ry, rx + i, ry - len, width: 0.3);
  }
  for (var i = 0; i <= 50; i += 10) {
    _text(rx + i - (i == 0 ? 0.8 : 1.6), ry + 4, '$i', size: 7);
  }
  _text(rx + 53, ry + 1, 'mm', size: 8);

  var top = 56.0;
  for (final (d, label) in [
    (16.0, '16 mm - start with this one'),
    (12.0, '12 mm - phone close to the machine, or little room on the gauge'),
    (20.0, '20 mm - phone far away (gauge small in the picture)'),
  ]) {
    _text(20, top, label, size: 11, bold: true);
    final pitch = 1.4 * d + 8;
    final n = ((170 + 8) / pitch).floor();
    final cy = top + 6 + 0.7 * d;
    for (var i = 0; i < n; i++) {
      _marker(20 + 0.7 * d + i * pitch, cy, d);
    }
    top = cy + 0.7 * d + 12;
  }

  final steps = [
    '1. Cut one marker out along the dashed circle. Keep the white border: the',
    '    app needs it to see the edge of the black ring.',
    '2. Stick it flat, facing the phone, at the lower right of the gauge: on the',
    '    rubber guard or the gauge housing, so it moves down with the gauge.',
    '    On the machine next to the gauge works too.',
    '3. It must stay in view during the whole shot: not under the lever or your',
    '    hand, and without glare (plain paper; no glossy tape over it).',
    '4. The wedge may point any way, but the marker must not move afterwards.',
    '5. Calibrate again (Brew > target icon). The app says "Marker found".',
    '    Not found: use a bigger size, or bring the phone a little closer.',
  ];
  _text(20, top, 'How to use it', size: 11, bold: true);
  for (var i = 0; i < steps.length; i++) {
    _text(20, top + 7 + i * 5.2, steps[i], size: 9.5);
  }

  final content = _ops.toString();
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${_n(pageW * mm)} ${_n(pageH * mm)}] '
        '/Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> >>',
    '<< /Length ${latin1.encode(content).length} >>\nstream\n${content}endstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>',
  ];
  final out = BytesBuilder();
  final offsets = <int>[];
  void add(String s) => out.add(latin1.encode(s));
  add('%PDF-1.4\n');
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    add('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  add('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    add('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  add('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  final file = File('assets/marker_sheet.pdf');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(out.toBytes());
  stdout.writeln('Wrote ${file.path}');
}
