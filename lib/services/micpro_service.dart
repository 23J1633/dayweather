import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../brand_icon.dart';
import '../models.dart';
import 'native_bridge.dart';

class MicProService {
  MicProService(this._nativeBridge);

  final NativeCameraBridge _nativeBridge;

  Future<String> buildWallpaper({
    required WeatherNode node,
    required bool dark,
  }) async {
    const width = 240.0;
    const height = 208.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final background = dark
        ? const ui.Color(0xFF16191E)
        : const ui.Color(0xFFF6F1E8);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, width, height),
      ui.Paint()..color = background,
    );

    final accent = ui.Color(node.kind.colorValue);
    final outlinePaint = ui.Paint()
      ..color = dark ? const ui.Color(0xFFEDE7D9) : const ui.Color(0xFF282B32)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 3;

    // Brand mark stays small in the corner; the weather glyph carries the mood.
    await _drawBrandIcon(canvas);
    // The panel has only six inks, so colour emoji cannot render. The weather mark
    // is therefore drawn as vector geometry using the measured palette colours.
    _drawWeatherGlyph(canvas, node.kind, const ui.Rect.fromLTWH(14, 36, 104, 104));
    _drawText(
      canvas,
      node.mood,
      const ui.Offset(128, 46),
      19,
      accent,
      true,
    );
    _drawText(
      canvas,
      '强度 ${node.intensity}',
      const ui.Offset(128, 76),
      16,
      outlinePaint.color,
      true,
    );
    _drawText(
      canvas,
      node.kind.chineseName,
      const ui.Offset(128, 100),
      16,
      accent,
      false,
    );
    _drawText(
      canvas,
      'dayweather',
      const ui.Offset(16, 180),
      13,
      outlinePaint.color,
      true,
    );
    _drawText(
      canvas,
      formatOffset(node.startMs).substring(0, 5),
      const ui.Offset(176, 180),
      14,
      accent,
      true,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('Unable to encode Mic Pro wallpaper');
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/dayweather_${node.kind.name}_${node.startMs}.png',
    );
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    image.dispose();
    return file.path;
  }

  /// Converts the generated card into the Mic Pro payloads and pushes them over
  /// BLE. Requires [codes] derived from a capture of the official app, because the
  /// numeric command ids are not published in the SDK.
  Future<Map<String, dynamic>> preparePayloads({
    required String cardPath,
    String? cacheKey,
  }) async {
    final raw = await _nativeBridge.prepareMicProPayloads(
      cardPath: cardPath,
      cacheKey: cacheKey,
    );
    return raw;
  }

  /// Pushes prepared payloads to the transmitter. Returns true when the device
  /// acknowledged the transfer.
  Future<bool> pushToDevice({
    required String bitmapPath,
    required String metaPath,
    required Map<String, int> codes,
    String? address,
  }) async {
    try {
      await _nativeBridge.pushMicProWallpaper(
        bitmapPath: bitmapPath,
        metaPath: metaPath,
        codes: codes,
        address: address,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> shareToOfficialPath(String filePath) {
    return _nativeBridge.shareWallpaper(filePath);
  }

  Future<void> _drawBrandIcon(ui.Canvas canvas) async {
    final data = await rootBundle.load(BrandIcon.assetPath);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final frame = await codec.getNextFrame();
    canvas.drawImageRect(
      frame.image,
      ui.Rect.fromLTWH(
        0,
        0,
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      ),
      const ui.Rect.fromLTWH(186, 12, 40, 28),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    frame.image.dispose();
    codec.dispose();
  }

  /// Paints a weather mark with plain geometry. Six-ink panels cannot show colour
  /// emoji, so each mood becomes simple shapes drawn from the measured palette.
  void _drawWeatherGlyph(ui.Canvas canvas, WeatherKind kind, ui.Rect box) {
    const sun = ui.Color(0xFFA0A000);
    const cloud = ui.Color(0xFFA0A0A0);
    const rain = ui.Color(0xFF005096);
    const storm = ui.Color(0xFF1E1E1E);
    const warm = ui.Color(0xFF821414);
    final centre = box.center;
    final radius = box.width / 4;

    void drawSun(ui.Offset at, double r, ui.Color color) {
      canvas.drawCircle(at, r, ui.Paint()..color = color);
      final ray = ui.Paint()
        ..color = color
        ..strokeWidth = 4
        ..strokeCap = ui.StrokeCap.round;
      for (var i = 0; i < 8; i++) {
        final angle = i * math.pi / 4;
        final from = at + ui.Offset(math.cos(angle) * (r + 5), math.sin(angle) * (r + 5));
        final to = at + ui.Offset(math.cos(angle) * (r + 13), math.sin(angle) * (r + 13));
        canvas.drawLine(from, to, ray);
      }
    }

    void drawCloud(ui.Offset at, double scale, ui.Color color) {
      final paint = ui.Paint()..color = color;
      canvas.drawCircle(at + ui.Offset(-scale * 0.7, 0), scale * 0.62, paint);
      canvas.drawCircle(at + ui.Offset(0, -scale * 0.28), scale * 0.78, paint);
      canvas.drawCircle(at + ui.Offset(scale * 0.72, 0.0), scale * 0.6, paint);
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromLTWH(
            at.dx - scale * 1.32,
            at.dy - scale * 0.05,
            scale * 2.64,
            scale * 0.72,
          ),
          ui.Radius.circular(scale * 0.3),
        ),
        paint,
      );
    }

    switch (kind) {
      case WeatherKind.sunny:
        drawSun(centre, radius * 0.9, sun);
      case WeatherKind.cloudy:
        drawSun(centre + ui.Offset(-radius * 0.75, -radius * 0.8), radius * 0.6, sun);
        drawCloud(centre + ui.Offset(radius * 0.15, radius * 0.25), radius, cloud);
      case WeatherKind.rain:
        drawCloud(centre + ui.Offset(0, -radius * 0.35), radius, cloud);
        final drop = ui.Paint()
          ..color = rain
          ..strokeWidth = 4
          ..strokeCap = ui.StrokeCap.round;
        for (var i = -1; i <= 1; i++) {
          final x = centre.dx + i * radius * 0.7;
          final top = centre.dy + radius * 0.42;
          canvas.drawLine(
            ui.Offset(x, top),
            ui.Offset(x - radius * 0.22, top + radius * 0.68),
            drop,
          );
        }
      case WeatherKind.storm:
        drawCloud(centre + ui.Offset(0, -radius * 0.4), radius, cloud);
        final bolt = ui.Path()
          ..moveTo(centre.dx + radius * 0.15, centre.dy + radius * 0.28)
          ..lineTo(centre.dx - radius * 0.4, centre.dy + radius * 1.05)
          ..lineTo(centre.dx + radius * 0.05, centre.dy + radius * 1.0)
          ..lineTo(centre.dx - radius * 0.18, centre.dy + radius * 1.65)
          ..lineTo(centre.dx + radius * 0.55, centre.dy + radius * 0.75)
          ..lineTo(centre.dx + radius * 0.12, centre.dy + radius * 0.8)
          ..close();
        canvas.drawPath(bolt, ui.Paint()..color = storm);
      case WeatherKind.rainbow:
        final bands = <ui.Color>[warm, sun, rain, cloud];
        final stroke = box.width / 12;
        for (var i = 0; i < bands.length; i++) {
          final r = radius * 1.45 - i * stroke;
          canvas.drawArc(
            ui.Rect.fromCircle(center: centre + ui.Offset(0, radius * 0.5), radius: r),
            math.pi,
            math.pi,
            false,
            ui.Paint()
              ..color = bands[i]
              ..style = ui.PaintingStyle.stroke
              ..strokeWidth = stroke,
          );
        }
        drawCloud(centre + ui.Offset(0, radius * 0.55), radius * 0.8, cloud);
    }
  }

  void _drawText(
    ui.Canvas canvas,
    String text,
    ui.Offset offset,
    double size,
    ui.Color color,
    bool bold,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }
}






