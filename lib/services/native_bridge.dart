import 'package:flutter/services.dart';

import '../models.dart';

class MediaInfo {
  const MediaInfo({
    required this.durationMs,
    required this.hasVideo,
    required this.hasAudio,
    this.width,
    this.height,
    this.frameRate,
    this.recordedAtMs,
  });

  final int durationMs;
  final bool hasVideo;
  final bool hasAudio;
  final int? width;
  final int? height;
  final double? frameRate;
  final int? recordedAtMs;

  MediaInfo copyWith({int? recordedAtMs}) => MediaInfo(
    durationMs: durationMs,
    hasVideo: hasVideo,
    hasAudio: hasAudio,
    width: width,
    height: height,
    frameRate: frameRate,
    recordedAtMs: recordedAtMs ?? this.recordedAtMs,
  );
}

class MediaSyncResult {
  const MediaSyncResult({
    required this.path,
    required this.name,
    this.durationMs,
    this.creationTimeMs,
  });

  final String path;
  final String name;
  final int? durationMs;
  final int? creationTimeMs;
}

/// One selectable video stored on the camera card.
class CameraVideo {
  const CameraVideo({
    required this.key,
    required this.name,
    required this.durationMs,
    this.sizeBytes,
    this.creationTimeMs,
  });

  final String key;
  final String name;
  final int durationMs;
  final int? sizeBytes;
  final int? creationTimeMs;
}

class NativeCameraBridge {
  NativeCameraBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dayweather/native'),
      _events = const EventChannel('dayweather/native_events');

  final MethodChannel _channel;
  final EventChannel _events;

  Stream<Map<String, dynamic>> get connectionEvents => _events
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .map((event) => Map<String, dynamic>.from(event as Map));

  /// Events for cloud AI sockets that are pinned to the mobile-data network.
  Stream<Map<String, dynamic>> get aiEvents =>
      const EventChannel('dayweather/ai_events')
          .receiveBroadcastStream()
          .where((event) => event is Map)
          .map((event) => Map<String, dynamic>.from(event as Map));

  /// Probes whether a non-camera network with internet access is reachable.
  /// Returns false when only the camera Wi-Fi is available, in which case AI
  /// requests must share the process default network.
  Future<bool> hasSeparateInternetNetwork() async {
    try {
      final handle = await _channel.invokeMethod<int>('beginInternetTask');
      await _channel.invokeMethod<void>('endInternetTask');
      return handle != null && handle >= 0;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<Map<String, dynamic>?> aiHttpPost({
    required Uri url,
    required Map<String, String> headers,
    required String body,
  }) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'aiHttpPost',
      {'url': url.toString(), 'headers': headers, 'body': body},
    );
    return raw == null ? null : Map<String, dynamic>.from(raw);
  }

  Future<void> aiWebSocketOpen({
    required Uri url,
    required Map<String, String> headers,
  }) async {
    await _channel.invokeMethod<void>('aiWsOpen', {
      'url': url.toString(),
      'headers': headers,
    });
  }

  Future<bool> aiWebSocketSend({String? text, Uint8List? data}) async {
    final ok = await _channel.invokeMethod<bool>('aiWsSend', {
      'text': text,
      'data': data,
    });
    return ok ?? false;
  }

  Future<void> aiWebSocketClose() async {
    try {
      await _channel.invokeMethod<void>('aiWsClose');
    } on MissingPluginException {
      return;
    }
  }

  /// Attaches the SDK directly to the Wi-Fi network currently joined by Android.
  Future<DeviceRecord?> connectCurrentWifiCamera() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'connectCurrentWifiCamera',
      );
      return raw == null ? null : _deviceFromMap(raw);
    } on MissingPluginException {
      return null;
    }
  }

  /// Scans nearby Wi-Fi from inside the app for GO Ultra camera access points.
  Future<List<Map<String, dynamic>>> scanCameraWifi() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('scanCameraWifi');
      return (raw ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } on MissingPluginException {
      return const [];
    }
  }

  /// Requests a selected camera Wi-Fi network inside the app, then connects the
  /// Insta360 SDK over ConnectType.WIFI.
  Future<DeviceRecord?> connectCameraWifi({
    required String ssid,
    required String password,
  }) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'connectCameraWifi',
      {'ssid': ssid, 'password': password},
    );
    return raw == null ? null : _deviceFromMap(raw);
  }

  Future<void> disconnectCamera() async {
    try {
      await _channel.invokeMethod<void>('disconnectCamera');
    } on MissingPluginException {
      return;
    }
  }

  Future<MediaInfo?> inspectMedia(String path) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'inspectMedia',
        {'path': path},
      );
      if (raw == null) return null;
      return MediaInfo(
        durationMs: _number(raw['durationMs']).round(),
        hasVideo: raw['hasVideo'] == true,
        hasAudio: raw['hasAudio'] == true,
        width: _numberOrNull(raw['width'])?.round(),
        height: _numberOrNull(raw['height'])?.round(),
        frameRate: _numberOrNull(raw['frameRate'])?.toDouble(),
        recordedAtMs: _numberOrNull(raw['recordedAtMs'])?.round(),
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<String?> extractAudioChunk({
    required String path,
    required int startMs,
    required int endMs,
  }) async {
    try {
      return await _channel.invokeMethod<String>('extractAudioChunk', {
        'path': path,
        'startMs': startMs,
        'endMs': endMs,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<List<VideoFrameSample>> extractVideoFrames({
    required String path,
    required int startMs,
    required int endMs,
    int count = 6,
  }) async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'extractVideoFrames',
        {'path': path, 'startMs': startMs, 'endMs': endMs, 'count': count},
      );
      return (raw ?? const [])
          .whereType<Map>()
          .map((item) {
            final data = item['data'];
            if (data is! Uint8List) return null;
            return VideoFrameSample(
              timestampMs:
                  _numberOrNull(item['timestampMs'])?.round() ?? startMs,
              data: data,
            );
          })
          .whereType<VideoFrameSample>()
          .toList();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Scans for the Insta360 Mic Pro transmitter over BLE. This is an independent
  /// channel: the e-ink display can be driven without any camera involvement.
  Future<List<Map<String, dynamic>>> scanMicPro() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('scanMicPro');
      return (raw ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Opens a GATT connection to the transmitter and reports its services.
  Future<Map<String, dynamic>?> connectMicPro(String address) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'connectMicPro',
      {'address': address},
    );
    return raw == null ? null : Map<String, dynamic>.from(raw);
  }

  /// Sweeps candidate protocol frames and returns whatever the display replies, so
  /// the numeric command ids can be recovered from real device behaviour.
  Future<Map<String, dynamic>> probeMicPro(String address) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'probeMicPro',
      {'address': address},
    );
    return raw == null ? const {} : Map<String, dynamic>.from(raw);
  }

  /// Converts a 240x208 weather card into the Mic Pro payloads on-device.
  Future<Map<String, dynamic>> prepareMicProPayloads({
    required String cardPath,
    String? cacheKey,
  }) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'prepareMicProPayloads',
      {'cardPath': cardPath, if (cacheKey != null) 'cacheKey': cacheKey},
    );
    return raw == null ? const {} : Map<String, dynamic>.from(raw);
  }

  /// Pushes a prepared weather card straight to a Mic Pro over BLE.
  /// [codes] must come from a capture of the official app (derive_codes.py).
  Future<void> pushMicProWallpaper({
    required String bitmapPath,
    required String metaPath,
    required Map<String, int> codes,
    String? address,
  }) async {
    await _channel.invokeMethod<void>('pushMicProWallpaper', {
      'bitmapPath': bitmapPath,
      'metaPath': metaPath,
      'codes': codes,
      'address': address,
    });
  }

  Future<void> shareWallpaper(String path) async {
    try {
      await _channel.invokeMethod<void>('shareWallpaper', {'path': path});
    } on MissingPluginException {
      return;
    }
  }

  Future<void> useInternetNetwork() async {
    try {
      await _channel.invokeMethod<void>('useInternetNetwork');
    } on MissingPluginException {
      return;
    }
  }

  Future<void> useCameraNetwork() async {
    try {
      await _channel.invokeMethod<void>('useCameraNetwork');
    } on MissingPluginException {
      return;
    }
  }

  Future<void> openPreview() async {
    try {
      await _channel.invokeMethod<void>('startPreview');
    } on MissingPluginException {
      return;
    }
  }

  Future<void> startRecording() async {
    await _channel.invokeMethod<void>('startRecording');
  }

  Future<void> stopRecording() async {
    await _channel.invokeMethod<void>('stopRecording');
  }

  /// Diagnostics: how much preview audio has arrived so far.
  Future<Map<String, dynamic>> recordingAudioProbe() async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'recordingAudioProbe',
    );
    return raw == null ? const {} : Map<String, dynamic>.from(raw);
  }

  /// Cuts a real sub-clip from [path] covering [startMs, endMs) and returns it.
  Future<String?> exportVideoClip({
    required String path,
    required int startMs,
    required int endMs,
    String? fileName,
  }) async {
    try {
      return await _channel.invokeMethod<String>('exportVideoClip', {
        'path': path,
        'startMs': startMs,
        'endMs': endMs,
        if (fileName != null) 'fileName': fileName,
      });
    } on MissingPluginException {
      return null;
    }
  }

  /// Lists the videos available on the currently connected camera.
  Future<List<CameraVideo>> listCameraVideos() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'listCameraVideos',
      );
      return (raw ?? const [])
          .whereType<Map>()
          .map((item) {
            final map = Map<dynamic, dynamic>.from(item);
            return CameraVideo(
              key: map['key']?.toString() ?? '',
              name: map['name']?.toString() ?? 'GO Ultra video',
              durationMs: _numberOrNull(map['durationMs'])?.round() ?? 0,
              sizeBytes: _numberOrNull(map['sizeBytes'])?.round(),
              creationTimeMs: _numberOrNull(map['creationTimeMs'])?.round(),
            );
          })
          .where((video) => video.key.isNotEmpty)
          .toList();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Downloads one selected camera video by its card key.
  Future<MediaSyncResult?> syncCameraVideo(String key) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'syncCameraVideo',
      {'key': key},
    );
    if (raw == null || raw['path'] == null) return null;
    return MediaSyncResult(
      path: raw['path'].toString(),
      name: raw['name']?.toString() ?? 'GO Ultra video',
      durationMs: _numberOrNull(raw['durationMs'])?.round(),
      creationTimeMs: _numberOrNull(raw['creationTimeMs'])?.round(),
    );
  }

  Future<MediaSyncResult?> syncLatestMedia() async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'syncLatestMedia',
    );
    if (raw == null || raw['path'] == null) return null;
    return MediaSyncResult(
      path: raw['path'].toString(),
      name: raw['name']?.toString() ?? 'GO Ultra video',
      durationMs: _numberOrNull(raw['durationMs'])?.round(),
      creationTimeMs: _numberOrNull(raw['creationTimeMs'])?.round(),
    );
  }

  static DeviceRecord _deviceFromMap(Map<dynamic, dynamic> raw) {
    return DeviceRecord(
      id: raw['id']?.toString() ?? raw['address']?.toString() ?? 'go-ultra',
      name: raw['name']?.toString() ?? 'GO Ultra',
      model: raw['model']?.toString() ?? 'GO Ultra',
      connection: raw['connection']?.toString() ?? 'BLE / Wi‑Fi',
      isConnected: raw['isConnected'] == true,
      battery: _numberOrNull(raw['battery'])?.round(),
      storage: raw['storage']?.toString(),
      address: raw['address']?.toString(),
    );
  }

  static num _number(dynamic value) =>
      value is num ? value : num.tryParse('$value') ?? 0;

  static num? _numberOrNull(dynamic value) =>
      value is num ? value : num.tryParse('$value');
}
