import 'dart:typed_data';

enum AppLanguage { chinese, english }

enum WeatherKind { sunny, cloudy, rain, storm, rainbow }

extension WeatherKindX on WeatherKind {
  String get emoji {
    switch (this) {
      case WeatherKind.sunny:
        return '☀️';
      case WeatherKind.cloudy:
        return '⛅';
      case WeatherKind.rain:
        return '🌧️';
      case WeatherKind.storm:
        return '⛈️';
      case WeatherKind.rainbow:
        return '🌈';
    }
  }

  String get chineseName {
    switch (this) {
      case WeatherKind.sunny:
        return '晴';
      case WeatherKind.cloudy:
        return '多云';
      case WeatherKind.rain:
        return '小雨';
      case WeatherKind.storm:
        return '雷雨';
      case WeatherKind.rainbow:
        return '彩虹';
    }
  }

  String get englishName {
    switch (this) {
      case WeatherKind.sunny:
        return 'Sunny';
      case WeatherKind.cloudy:
        return 'Cloudy';
      case WeatherKind.rain:
        return 'Rain';
      case WeatherKind.storm:
        return 'Storm';
      case WeatherKind.rainbow:
        return 'Rainbow';
    }
  }

  String get shortLabel {
    switch (this) {
      case WeatherKind.sunny:
        return 'Clear';
      case WeatherKind.cloudy:
        return 'Steady';
      case WeatherKind.rain:
        return 'Quiet';
      case WeatherKind.storm:
        return 'Intense';
      case WeatherKind.rainbow:
        return 'Peak';
    }
  }

  int get colorValue {
    switch (this) {
      case WeatherKind.sunny:
        return 0xFFFFB84D;
      case WeatherKind.cloudy:
        return 0xFF92A3B8;
      case WeatherKind.rain:
        return 0xFF4E8CDE;
      case WeatherKind.storm:
        return 0xFF8C6DDE;
      case WeatherKind.rainbow:
        return 0xFFFF6E92;
    }
  }
}

WeatherKind weatherKindFromStorage(String? value) {
  switch (value) {
    case 'sunny':
      return WeatherKind.sunny;
    case 'rain':
      return WeatherKind.rain;
    case 'storm':
      return WeatherKind.storm;
    case 'rainbow':
      return WeatherKind.rainbow;
    default:
      return WeatherKind.cloudy;
  }
}

class WeatherNode {
  const WeatherNode({
    required this.startMs,
    required this.endMs,
    required this.kind,
    required this.mood,
    required this.confidence,
    required this.evidence,
    required this.transcript,
    required this.intensity,
    this.sourceRef,
    this.visualSummary,
    this.absoluteStartMs,
    this.absoluteEndMs,
  });

  final int startMs;
  final int endMs;
  final WeatherKind kind;
  final String mood;
  final double confidence;
  final List<String> evidence;
  final String transcript;
  final int intensity;
  final String? sourceRef;
  final String? visualSummary;
  final int? absoluteStartMs;
  final int? absoluteEndMs;

  String get timeRange => formatTimeRange(
    startMs: startMs,
    endMs: endMs,
    absoluteStartMs: absoluteStartMs,
    absoluteEndMs: absoluteEndMs,
  );
  String get startLabel => absoluteStartMs == null
      ? formatOffset(startMs)
      : formatClock(absoluteStartMs!);
  String get endLabel =>
      absoluteEndMs == null ? formatOffset(endMs) : formatClock(absoluteEndMs!);
  String get clockRange => '$startLabel—$endLabel';

  Map<String, dynamic> toJson() => {
    'startMs': startMs,
    'endMs': endMs,
    'kind': kind.name,
    'mood': mood,
    'confidence': confidence,
    'evidence': evidence,
    'transcript': transcript,
    'intensity': intensity,
    'sourceRef': sourceRef,
    'visualSummary': visualSummary,
    'absoluteStartMs': absoluteStartMs,
    'absoluteEndMs': absoluteEndMs,
  };

  static WeatherNode? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final value = Map<String, dynamic>.from(raw);
    final startMs = _asInt(value['startMs']);
    final endMs = _asInt(value['endMs']);
    if (startMs == null || endMs == null) return null;
    return WeatherNode(
      startMs: startMs,
      endMs: endMs,
      kind: weatherKindFromStorage(value['kind']?.toString()),
      mood: value['mood']?.toString() ?? '氛围变化',
      confidence: (_asDouble(value['confidence']) ?? 0.6).clamp(0, 1),
      evidence: _asStringList(value['evidence']),
      transcript: value['transcript']?.toString() ?? '',
      intensity: (_asInt(value['intensity']) ?? 50).clamp(0, 100),
      sourceRef: value['sourceRef']?.toString(),
      visualSummary: value['visualSummary']?.toString(),
      absoluteStartMs: _asTimestamp(value['absoluteStartMs']),
      absoluteEndMs: _asTimestamp(value['absoluteEndMs']),
    );
  }

  WeatherNode copyWith({
    WeatherKind? kind,
    String? mood,
    double? confidence,
    List<String>? evidence,
    String? transcript,
    int? intensity,
    String? visualSummary,
    int? absoluteStartMs,
    int? absoluteEndMs,
  }) {
    return WeatherNode(
      startMs: startMs,
      endMs: endMs,
      kind: kind ?? this.kind,
      mood: mood ?? this.mood,
      confidence: confidence ?? this.confidence,
      evidence: evidence ?? this.evidence,
      transcript: transcript ?? this.transcript,
      intensity: intensity ?? this.intensity,
      sourceRef: sourceRef,
      visualSummary: visualSummary ?? this.visualSummary,
      absoluteStartMs: absoluteStartMs ?? this.absoluteStartMs,
      absoluteEndMs: absoluteEndMs ?? this.absoluteEndMs,
    );
  }
}

class VideoEvent {
  const VideoEvent({
    required this.startMs,
    required this.endMs,
    required this.title,
    required this.description,
    required this.confidence,
    this.sourceRef,
    this.absoluteStartMs,
    this.absoluteEndMs,
  });

  final int startMs;
  final int endMs;
  final String title;
  final String description;
  final double confidence;
  final String? sourceRef;
  final int? absoluteStartMs;
  final int? absoluteEndMs;

  String get timeRange => formatTimeRange(
    startMs: startMs,
    endMs: endMs,
    absoluteStartMs: absoluteStartMs,
    absoluteEndMs: absoluteEndMs,
  );

  String get clockRange => absoluteStartMs == null || absoluteEndMs == null
      ? '${formatOffset(startMs)}—${formatOffset(endMs)}'
      : '${formatClock(absoluteStartMs!)}—${formatClock(absoluteEndMs!)}';

  Map<String, dynamic> toJson() => {
    'startMs': startMs,
    'endMs': endMs,
    'title': title,
    'description': description,
    'confidence': confidence,
    'sourceRef': sourceRef,
    'absoluteStartMs': absoluteStartMs,
    'absoluteEndMs': absoluteEndMs,
  };

  static VideoEvent? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final value = Map<String, dynamic>.from(raw);
    final startMs = _asInt(value['startMs']);
    final endMs = _asInt(value['endMs']);
    if (startMs == null || endMs == null) return null;
    return VideoEvent(
      startMs: startMs,
      endMs: endMs,
      title: value['title']?.toString() ?? '画面事件',
      description: value['description']?.toString() ?? '',
      confidence: (_asDouble(value['confidence']) ?? 0.6).clamp(0, 1),
      sourceRef: value['sourceRef']?.toString(),
      absoluteStartMs: _asTimestamp(value['absoluteStartMs']),
      absoluteEndMs: _asTimestamp(value['absoluteEndMs']),
    );
  }

  VideoEvent copyWith({
    String? sourceRef,
    int? absoluteStartMs,
    int? absoluteEndMs,
  }) {
    return VideoEvent(
      startMs: startMs,
      endMs: endMs,
      title: title,
      description: description,
      confidence: confidence,
      sourceRef: sourceRef ?? this.sourceRef,
      absoluteStartMs: absoluteStartMs ?? this.absoluteStartMs,
      absoluteEndMs: absoluteEndMs ?? this.absoluteEndMs,
    );
  }
}

class VideoFrameSample {
  const VideoFrameSample({required this.timestampMs, required this.data});

  final int timestampMs;
  final Uint8List data;
}

class HighlightClip {
  const HighlightClip({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.kind,
    required this.title,
    required this.reason,
    required this.score,
    required this.transcript,
    required this.nodeStartMs,
    this.sourcePath,
    this.absoluteStartMs,
    this.absoluteEndMs,
    this.clipPath,
  });

  final String id;
  final int startMs;
  final int endMs;
  final WeatherKind kind;
  final String title;
  final String reason;
  final double score;
  final String transcript;
  final int nodeStartMs;
  final String? sourcePath;
  final int? absoluteStartMs;
  final int? absoluteEndMs;
  /// Path of the trimmed standalone MP4 produced for this highlight, when exported.
  final String? clipPath;

  String get timeRange => formatTimeRange(
    startMs: startMs,
    endMs: endMs,
    absoluteStartMs: absoluteStartMs,
    absoluteEndMs: absoluteEndMs,
  );
  HighlightClip copyWith({String? clipPath}) => HighlightClip(
    id: id,
    startMs: startMs,
    endMs: endMs,
    kind: kind,
    title: title,
    reason: reason,
    score: score,
    transcript: transcript,
    nodeStartMs: nodeStartMs,
    sourcePath: sourcePath,
    absoluteStartMs: absoluteStartMs,
    absoluteEndMs: absoluteEndMs,
    clipPath: clipPath ?? this.clipPath,
  );

  String get clockRange => absoluteStartMs == null || absoluteEndMs == null
      ? '${formatOffset(startMs)}—${formatOffset(endMs)}'
      : '${formatClock(absoluteStartMs!)}—${formatClock(absoluteEndMs!)}';
}

class AnalysisHistory {
  const AnalysisHistory({
    required this.id,
    required this.sourceName,
    required this.analyzedAtMs,
    required this.timeline,
    required this.videoEvents,
    this.sourcePath,
    this.durationMs,
  });

  final String id;
  final String sourceName;
  final String? sourcePath;
  final int analyzedAtMs;
  final int? durationMs;
  final List<WeatherNode> timeline;
  final List<VideoEvent> videoEvents;

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceName': sourceName,
    'sourcePath': sourcePath,
    'analyzedAtMs': analyzedAtMs,
    'durationMs': durationMs,
    'timeline': timeline.map((node) => node.toJson()).toList(),
    'videoEvents': videoEvents.map((event) => event.toJson()).toList(),
  };

  static AnalysisHistory? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final value = Map<String, dynamic>.from(raw);
    final analyzedAtMs = _asInt(value['analyzedAtMs']);
    if (analyzedAtMs == null) return null;
    final timeline = (value['timeline'] as List? ?? const [])
        .map(WeatherNode.fromJson)
        .whereType<WeatherNode>()
        .toList();
    final videoEvents = (value['videoEvents'] as List? ?? const [])
        .map(VideoEvent.fromJson)
        .whereType<VideoEvent>()
        .toList();
    if (timeline.isEmpty && videoEvents.isEmpty) return null;
    return AnalysisHistory(
      id: value['id']?.toString() ?? '$analyzedAtMs',
      sourceName: value['sourceName']?.toString() ?? 'GO Ultra video',
      sourcePath: value['sourcePath']?.toString(),
      analyzedAtMs: analyzedAtMs,
      durationMs: _asInt(value['durationMs']),
      timeline: timeline,
      videoEvents: videoEvents,
    );
  }
}

class DeviceRecord {
  const DeviceRecord({
    required this.id,
    required this.name,
    required this.model,
    required this.connection,
    required this.isConnected,
    this.battery,
    this.storage,
    this.address,
  });

  final String id;
  final String name;
  final String model;
  final String connection;
  final bool isConnected;
  final int? battery;
  final String? storage;
  final String? address;

  DeviceRecord copyWith({
    String? name,
    String? model,
    String? connection,
    bool? isConnected,
    int? battery,
    String? storage,
    String? address,
  }) {
    return DeviceRecord(
      id: id,
      name: name ?? this.name,
      model: model ?? this.model,
      connection: connection ?? this.connection,
      isConnected: isConnected ?? this.isConnected,
      battery: battery ?? this.battery,
      storage: storage ?? this.storage,
      address: address ?? this.address,
    );
  }
}

enum AnalysisStage {
  idle,
  inspecting,
  extracting,
  transcribing,
  understanding,
  ready,
  failed,
}

enum DeviceConnectionStage {
  idle,
  scanning,
  connectingBle,
  switchingWifi,
  requestingWifi,
  connectingWifi,
  connected,
  syncing,
  failed,
}

extension DeviceConnectionStageX on DeviceConnectionStage {
  bool get isBusy => switch (this) {
    DeviceConnectionStage.scanning ||
    DeviceConnectionStage.connectingBle ||
    DeviceConnectionStage.switchingWifi ||
    DeviceConnectionStage.requestingWifi ||
    DeviceConnectionStage.connectingWifi ||
    DeviceConnectionStage.syncing => true,
    _ => false,
  };
}

String formatOffset(int offsetMs) {
  final totalSeconds = (offsetMs / 1000).round().clamp(0, 24 * 60 * 60);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

String formatClock(int epochMs) {
  final date = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
  return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
}

String formatTimestamp(int epochMs) {
  final date = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
  return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${formatClock(epochMs)}';
}

String formatTimeRange({
  required int startMs,
  required int endMs,
  int? absoluteStartMs,
  int? absoluteEndMs,
}) {
  if (absoluteStartMs != null && absoluteEndMs != null) {
    return '${formatTimestamp(absoluteStartMs)}—${formatTimestamp(absoluteEndMs)}';
  }
  return '${formatOffset(startMs)}—${formatOffset(endMs)}';
}

String formatDuration(int durationMs) {
  final totalSeconds = (durationMs / 1000).round().clamp(0, 24 * 60 * 60);
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

int? _asInt(dynamic value) =>
    value is num ? value.round() : int.tryParse('$value');

double? _asDouble(dynamic value) =>
    value is num ? value.toDouble() : double.tryParse('$value');

int? _asTimestamp(dynamic value) {
  final timestamp = _asInt(value);
  if (timestamp == null ||
      timestamp < 946684800000 ||
      timestamp > 4102444800000) {
    return null;
  }
  return timestamp;
}

List<String> _asStringList(dynamic value) => value is List
    ? value
          .map((item) => item.toString())
          .where((item) => item.isNotEmpty)
          .toList()
    : <String>[];

