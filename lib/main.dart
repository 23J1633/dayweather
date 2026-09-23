import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models.dart';
import 'pages.dart';
import 'services/micpro_service.dart';
import 'services/native_bridge.dart';
import 'services/qwen_service.dart';

const brandBlue = Color(0xFF4263EB);
const brandCoral = Color(0xFFFF715B);
const ink = Color(0xFF20242B);
const realtimeAnalysisWindowMs = 3 * 60 * 1000;
const realtimeBoundaryHoldMs = 15 * 1000;
const realtimeVideoSampleIntervalMs = 20 * 1000;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(DayWeatherApp(controller: AppController()));
}

class DayWeatherApp extends StatelessWidget {
  const DayWeatherApp({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return ShadcnApp(
          title: 'dayweather',
          home: RootShell(controller: controller),
          theme: ThemeData(
            colorScheme: ColorSchemes.lightSlate,
            radius: 0.85,
            scaling: 1.0,
          ),
          darkTheme: ThemeData.dark(
            colorScheme: ColorSchemes.darkSlate,
            radius: 0.85,
            scaling: 1.0,
          ),
          themeMode: controller.darkMode ? ThemeMode.dark : ThemeMode.light,
          debugShowCheckedModeBanner: false,
          supportedLocales: const [Locale('en', 'US')],
          locale: const Locale('en', 'US'),
        );
      },
    );
  }
}

class AppController extends ChangeNotifier {
  AppController() : qwen = QwenService(), native = NativeCameraBridge() {
    micPro = MicProService(native);
    if (Platform.isAndroid) {
      nativeEventSubscription = native.connectionEvents.listen(
        _handleNativeEvent,
      );
    }
    unawaited(_loadPreferences());
  }

  final QwenService qwen;
  final NativeCameraBridge native;
  late final MicProService micPro;
  StreamSubscription<Map<String, dynamic>>? nativeEventSubscription;
  StreamSubscription<RealtimeTranscript>? realtimeAsrSubscription;
  Timer? autoSyncTimer;
  Timer? realtimeRetryTimer;
  Timer? realtimeWindowTimer;

  int selectedTab = 0;
  bool darkMode = false;
  AppLanguage language = AppLanguage.chinese;
  bool settingsOpen = false;
  bool showOnlyGo = true;
  bool scanning = false;
  DeviceConnectionStage connectionStage = DeviceConnectionStage.idle;
  String connectionStatus = '等待连接 GO Ultra';
  String? connectingDeviceId;
  String? connectedDeviceName;
  bool previewReady = false;
  bool realtimeAsrConnecting = false;
  bool realtimeAsrActive = false;
  int realtimeAudioFrames = 0;
  int realtimeAudioBytes = 0;
  String realtimeStatus = '等待实时音频流';
  String realtimeTranscript = '';
  String realtimeMood = '';
  WeatherKind? realtimeWeather;
  bool syncingLatestMedia = false;
  bool mediaWindowAnalysisRunning = false;
  bool autoSyncEnabled = true;
  String syncStatus = '连接后自动同步最新视频';
  String? latestSyncedPath;
  bool aiTesting = false;
  String? aiTestMessage;
  String? _lastAutoAnalyzedPath;
  String? _lastDeviceName;

  /// The camera this project is developed against. Scans narrow to it by default
  /// so the many other Insta360 devices in range stay out of the way.
  static const preferredDeviceName = '5GQGMW';
  bool showPreferredOnly = true;

  /// Devices after applying the preferred-camera filter.
  List<DeviceRecord> get visibleScanDevices {
    if (!showPreferredOnly) return devices;
    final matches = devices
        .where((item) => item.name.contains(preferredDeviceName))
        .toList();
    return matches.isEmpty ? devices : matches;
  }

  void setShowPreferredOnly(bool value) {
    showPreferredOnly = value;
    notifyListeners();
  }

  String sourceName = '';
  String? sourcePath;
  int? sourceRecordedAtMs;
  MediaInfo? mediaInfo;
  AnalysisStage analysisStage = AnalysisStage.idle;
  double analysisProgress = 0;
  String analysisMessage = '等待从 GO Ultra 导入真实视频';
  String? lastError;
  int selectedNodeIndex = 0;
  String? syncMessage;
  String? lastWallpaperPath;
  List<WeatherNode> timeline = <WeatherNode>[];
  List<HighlightClip> highlights = <HighlightClip>[];
  List<VideoEvent> videoEvents = <VideoEvent>[];
  List<AnalysisHistory> analysisHistory = <AnalysisHistory>[];
  List<DeviceRecord> devices = <DeviceRecord>[];
  QwenRealtimeAsr? _realtimeAsr;
  Future<void> _realtimeMoodQueue = Future<void>.value();
  Future<void> _historyWriteQueue = Future<void>.value();
  String? _liveHistoryId;
  List<WeatherNode> _liveRealtimeNodes = <WeatherNode>[];
  List<VideoEvent> _liveRealtimeEvents = <VideoEvent>[];
  List<RealtimeTranscript> _realtimeWindowTranscripts = <RealtimeTranscript>[];
  List<VideoFrameSample> _realtimeWindowVideoFrames = <VideoFrameSample>[];
  int? _realtimeWindowStartCameraMs;
  int? _realtimeWindowStartAbsoluteMs;
  int? _lastRealtimeVideoSampleMs;
  int? _lastRealtimeIntensity;
  WeatherKind? _lastRealtimeWeather;
  String? _lastRealtimeMood;
  Future<void> _micProSyncQueue = Future<void>.value();

  void _queueAutomaticMicProSync(WeatherNode node) {
    _micProSyncQueue = _micProSyncQueue.then(
      (_) => syncToMicPro(node, automatic: true),
    );
  }

  WeatherNode? get selectedNode => timeline.isEmpty
      ? null
      : timeline[selectedNodeIndex.clamp(0, timeline.length - 1)];

  bool get isAnalyzing =>
      analysisStage == AnalysisStage.inspecting ||
      analysisStage == AnalysisStage.extracting ||
      analysisStage == AnalysisStage.transcribing ||
      analysisStage == AnalysisStage.understanding;

  DeviceRecord? get connectedDevice {
    for (final device in devices) {
      if (device.isConnected) return device;
    }
    return null;
  }

  bool get isConnected => connectedDevice != null;

  bool get connectionIsActive =>
      connectionStage == DeviceConnectionStage.connected ||
      connectionStage == DeviceConnectionStage.syncing ||
      connectedDevice != null;

  String text(String chinese, String english) =>
      language == AppLanguage.chinese ? chinese : english;

  Future<void> _loadPreferences() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      darkMode = preferences.getBool('darkMode') ?? false;
      language = preferences.getString('language') == 'en'
          ? AppLanguage.english
          : AppLanguage.chinese;
      _lastDeviceName = preferences.getString('lastDeviceName');
      final rawHistory = preferences.getString('analysisHistory');
      if (rawHistory != null && rawHistory.isNotEmpty) {
        final decoded = jsonDecode(rawHistory);
        if (decoded is List) {
          analysisHistory =
              decoded
                  .map(AnalysisHistory.fromJson)
                  .whereType<AnalysisHistory>()
                  .toList()
                ..sort((a, b) => b.analyzedAtMs.compareTo(a.analyzedAtMs));
        }
      }
      if (analysisHistory.isNotEmpty) {
        _restoreHistory(analysisHistory.first, notify: false);
      }
      notifyListeners();
    } on MissingPluginException {
      // Widget tests and non-mobile previews use the in-memory defaults.
    } on FormatException {
      // Ignore a partially written history payload and keep the live session usable.
    }
  }

  void _restoreHistory(AnalysisHistory entry, {bool notify = true}) {
    sourceName = entry.sourceName;
    sourcePath = entry.sourcePath;
    sourceRecordedAtMs = entry.timeline
        .map((node) => node.absoluteStartMs)
        .whereType<int>()
        .fold<int?>(
          null,
          (value, item) => value == null || item < value ? item : value,
        );
    timeline = List<WeatherNode>.from(entry.timeline);
    videoEvents = List<VideoEvent>.from(entry.videoEvents);
    highlights = _highlightsFromNodes(
      timeline,
      events: videoEvents,
      sourceDurationMs: entry.durationMs,
    );
    final restoredPath = sourcePath;
    if (restoredPath != null && highlights.isNotEmpty) {
      unawaited(_restoreExportedHighlights(restoredPath));
    }
    selectedNodeIndex = 0;
    analysisStage = timeline.isEmpty ? AnalysisStage.idle : AnalysisStage.ready;
    analysisProgress = timeline.isEmpty ? 0 : 1;
    analysisMessage = timeline.isEmpty
        ? text('暂无可恢复的真实分析结果', 'No recoverable real analysis')
        : text('已恢复历史真实分析结果', 'Restored the latest real analysis');
    if (notify) notifyListeners();
  }

  void restoreHistory(AnalysisHistory entry) {
    _restoreHistory(entry);
  }

  Future<void> _restoreExportedHighlights(String path) async {
    if (!File(path).existsSync()) return;
    final inspected = await native.inspectMedia(path);
    if (inspected != null) mediaInfo = inspected;
    await _exportHighlightClips(path);
  }

  Future<void> _persistHistory() {
    final payload = jsonEncode(
      analysisHistory.map((entry) => entry.toJson()).toList(),
    );
    _historyWriteQueue = _historyWriteQueue.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString('analysisHistory', payload);
      } on MissingPluginException {
        // Widget tests and non-mobile previews use the in-memory history.
      }
    });
    return _historyWriteQueue;
  }

  Future<void> _storeHistorySnapshot({
    required String id,
    required String sourceName,
    required String? sourcePath,
    required List<WeatherNode> nodes,
    required List<VideoEvent> events,
    int? durationMs,
  }) async {
    if (nodes.isEmpty && events.isEmpty) return;
    final entry = AnalysisHistory(
      id: id,
      sourceName: sourceName,
      sourcePath: sourcePath,
      analyzedAtMs: DateTime.now().millisecondsSinceEpoch,
      durationMs: durationMs,
      timeline: List<WeatherNode>.from(nodes),
      videoEvents: List<VideoEvent>.from(events),
    );
    final existingIndex = analysisHistory.indexWhere((item) => item.id == id);
    if (existingIndex >= 0) {
      analysisHistory = [
        for (var index = 0; index < analysisHistory.length; index++)
          if (index == existingIndex) entry else analysisHistory[index],
      ];
    } else {
      analysisHistory = [entry, ...analysisHistory].take(20).toList();
    }
    await _persistHistory();
    notifyListeners();
  }

  Future<void> setDarkMode(bool value) async {
    darkMode = value;
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('darkMode', value);
  }

  Future<void> setLanguage(AppLanguage value) async {
    language = value;
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'language',
      value == AppLanguage.english ? 'en' : 'zh',
    );
  }

  @override
  void dispose() {
    autoSyncTimer?.cancel();
    realtimeRetryTimer?.cancel();
    realtimeWindowTimer?.cancel();
    nativeEventSubscription?.cancel();
    realtimeAsrSubscription?.cancel();
    unawaited(_realtimeAsr?.stop());
    qwen.dispose();
    super.dispose();
  }

  void selectTab(int index) {
    settingsOpen = false;
    selectedTab = index;
    notifyListeners();
  }

  void setShowOnlyGo(bool value) {
    showOnlyGo = value;
    notifyListeners();
  }

  void openSettings() {
    settingsOpen = true;
    notifyListeners();
  }

  void closeSettings() {
    settingsOpen = false;
    notifyListeners();
  }

  /// Scans the common public folders for video files, so the app can offer a
  /// direct import path when the system picker is unavailable on the host device.
  Future<List<String>> discoverImportableVideos() async {
    final roots = <String>[
      '/sdcard/Movies',
      '/sdcard/DCIM',
      '/sdcard/Download',
      '/sdcard/Pictures',
    ];
    final found = <String>[];
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      try {
        for (final entity in dir.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final lower = entity.path.toLowerCase();
          if (lower.endsWith('.mp4') ||
              lower.endsWith('.mov') ||
              lower.endsWith('.mkv')) {
            found.add(entity.path);
          }
        }
      } catch (_) {
        // Skip folders the app cannot read and keep scanning the rest.
      }
    }
    found.sort();
    return found;
  }

  /// Imports a video by absolute path. Useful when the system picker is
  /// unavailable on the host device.
  Future<void> importVideoPath(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      _failAnalysis(text('文件不存在：$path', 'File not found: $path'));
      return;
    }
    sourcePath = path;
    sourceName = file.uri.pathSegments.last;
    sourceRecordedAtMs = null;
    latestSyncedPath = null;
    _lastAutoAnalyzedPath = null;
    _liveHistoryId = null;
    _liveRealtimeNodes = <WeatherNode>[];
    _liveRealtimeEvents = <VideoEvent>[];
    _resetRealtimeWindowState();
    mediaInfo = await native.inspectMedia(path);
    sourceRecordedAtMs = mediaInfo?.recordedAtMs;
    timeline = <WeatherNode>[];
    highlights = <HighlightClip>[];
    videoEvents = <VideoEvent>[];
    selectedNodeIndex = 0;
    analysisStage = AnalysisStage.idle;
    analysisProgress = 0;
    analysisMessage = mediaInfo == null
        ? text('无法读取视频轨道信息', 'Unable to inspect the video tracks')
        : text('素材已导入，点击开始分析', 'Media imported; start analysis');
    lastError = null;
    notifyListeners();
    await startAnalysis(path: path);
  }

  Future<void> pickVideo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
      withData: false,
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) return;
    sourcePath = path;
    sourceName = result!.files.single.name;
    sourceRecordedAtMs = null;
    latestSyncedPath = null;
    _lastAutoAnalyzedPath = null;
    _liveHistoryId = null;
    _liveRealtimeNodes = <WeatherNode>[];
    _liveRealtimeEvents = <VideoEvent>[];
    _resetRealtimeWindowState();
    mediaInfo = await native.inspectMedia(path);
    sourceRecordedAtMs = mediaInfo?.recordedAtMs;
    timeline = <WeatherNode>[];
    highlights = <HighlightClip>[];
    videoEvents = <VideoEvent>[];
    selectedNodeIndex = 0;
    analysisStage = AnalysisStage.idle;
    analysisProgress = 0;
    analysisMessage = mediaInfo == null
        ? text('无法读取视频轨道信息', 'Unable to inspect the video tracks')
        : text('真实素材已导入，点击开始分析', 'Real media imported; start analysis');
    lastError = null;
    notifyListeners();
  }

  /// Cuts each detected highlight into a standalone MP4 so playback and sharing
  /// use a real edited clip instead of a window into the full recording.
  Future<void> _exportHighlightClips(String sourcePath) async {
    if (highlights.isEmpty) return;
    final exported = <HighlightClip>[];
    for (final clip in highlights) {
      final sourceDuration = mediaInfo?.durationMs;
      final maxEnd = sourceDuration == null || sourceDuration <= 0
          ? clip.endMs
          : sourceDuration;
      final startMs = clip.startMs.clamp(0, maxEnd).toInt();
      final endMs = clip.endMs.clamp(startMs + 1000, maxEnd).toInt();
      if (endMs <= startMs) {
        exported.add(clip);
        continue;
      }
      final path = await native.exportVideoClip(
        path: sourcePath,
        startMs: startMs,
        endMs: endMs,
        fileName: 'highlight_${clip.kind.name}_${clip.startMs}',
      );
      exported.add(path == null ? clip : clip.copyWith(clipPath: path));
    }
    highlights = exported;
    notifyListeners();
  }

  Future<void> startAnalysis({String? path, String? name}) async {
    if (isAnalyzing) return;
    final targetPath = path ?? sourcePath;
    if (targetPath == null || targetPath.isEmpty) {
      _failAnalysis(
        text('请先从 GO Ultra 导入真实视频', 'Import a real GO Ultra video first'),
      );
      return;
    }
    sourcePath = targetPath;
    if (name != null && name.isNotEmpty) sourceName = name;
    lastError = null;
    analysisStage = AnalysisStage.inspecting;
    analysisProgress = 0.08;
    analysisMessage = text(
      '正在读取视频与音频轨道…',
      'Inspecting video and audio tracks…',
    );
    notifyListeners();

    if (!qwen.isConfigured) {
      _failAnalysis(
        text(
          '未配置百炼 API Key，无法进行真实分析',
          'Bailian API key is not configured; real analysis is unavailable',
        ),
      );
      return;
    }

    try {
      mediaInfo = await native.inspectMedia(targetPath);
      final info = mediaInfo;
      if (info == null) {
        throw StateError(text('视频轨道读取失败', 'Video track inspection failed'));
      }
      if (!info.hasVideo || !info.hasAudio) {
        throw StateError(
          text(
            '真实素材必须同时包含视频和音频轨道',
            'The real media must contain both video and audio tracks',
          ),
        );
      }
      sourceRecordedAtMs ??= info.recordedAtMs;
      analysisStage = AnalysisStage.extracting;
      analysisProgress = 0.2;
      analysisMessage = text(
        '正在按视频时间戳分离音频…',
        'Extracting audio with video timestamps…',
      );
      notifyListeners();

      final duration = info.durationMs.clamp(1000, 24 * 60 * 60 * 1000);
      // A 3-minute window keeps the summary at the level the product promises;
      // shorter windows produced one trivial event per camera nudge.
      const analysisWindowMs = 3 * 60 * 1000;
      final segmentCount = math.max(1, (duration / analysisWindowMs).ceil());
      final window = math.max(1000, (duration / segmentCount).ceil());
      final nodes = <WeatherNode>[];
      final analyzedVideoEvents = <VideoEvent>[];
      for (var index = 0; index < segmentCount; index++) {
        final start = (index * window).clamp(0, duration);
        final end = math.min(start + window, duration);
        final segmentProgress = (index + 1) / segmentCount;
        VideoAnalysisResult? videoAnalysis;
        analysisStage = AnalysisStage.understanding;
        analysisProgress = 0.2 + segmentProgress * 0.25;
        analysisMessage = text(
          '正在理解第 ${index + 1}/$segmentCount 段画面（${formatOffset(start)}—${formatOffset(end)}）…',
          'Understanding segment ${index + 1}/$segmentCount (${formatOffset(start)}—${formatOffset(end)})…',
        );
        notifyListeners();
        final frames = await native.extractVideoFrames(
          path: targetPath,
          startMs: start,
          endMs: end,
        );
        if (frames.isNotEmpty) {
          try {
            videoAnalysis = await qwen.understandVideoFrames(
              frames: frames,
              sourceStartMs: start,
              sourceEndMs: end,
            );
          } catch (error) {
            analysisMessage = text(
              '画面理解暂时超时，继续使用音频与情绪分析…',
              'Visual understanding timed out; continuing with audio and mood analysis…',
            );
            notifyListeners();
          }
          if (videoAnalysis != null && videoAnalysis.events.isNotEmpty) {
            analyzedVideoEvents.addAll(
              videoAnalysis.events.map(
                (event) => event.copyWith(
                  sourceRef: targetPath,
                  absoluteStartMs: sourceRecordedAtMs == null
                      ? null
                      : sourceRecordedAtMs! + event.startMs,
                  absoluteEndMs: sourceRecordedAtMs == null
                      ? null
                      : sourceRecordedAtMs! + event.endMs,
                ),
              ),
            );
          }
        }
        analysisStage = AnalysisStage.transcribing;
        analysisProgress = 0.45 + segmentProgress * 0.25;
        analysisMessage = text(
          '正在转写第 ${index + 1}/$segmentCount 段语音（${formatOffset(start)}—${formatOffset(end)}）…',
          'Transcribing segment ${index + 1}/$segmentCount (${formatOffset(start)}—${formatOffset(end)})…',
        );
        notifyListeners();
        final audioPath = await native.extractAudioChunk(
          path: targetPath,
          startMs: start,
          endMs: end,
        );
        final transcript = audioPath == null
            ? null
            : await qwen.transcribeAudio(
                audioFile: File(audioPath),
                sourceStartMs: start,
                sourceEndMs: end,
              );
        final textValue = transcript?.text.trim();
        if (textValue == null || textValue.isEmpty) continue;
        analysisStage = AnalysisStage.understanding;
        analysisProgress = 0.7 + segmentProgress * 0.25;
        analysisMessage = text(
          '正在理解这一段的影像氛围…',
          'Understanding the visual atmosphere…',
        );
        notifyListeners();
        final mood = await qwen.analyzeMood(
          transcript: textValue,
          localSignals: [
            '视频时间戳已保留',
            'GO Ultra 片段',
            '音频窗口',
            if (videoAnalysis != null) '视频理解：${videoAnalysis.summary}',
            if (videoAnalysis != null && videoAnalysis.events.isNotEmpty)
              '视频事件：${videoAnalysis.events.map((event) => event.title).join('、')}',
          ],
        );
        if (mood == null) continue;
        final node = WeatherNode(
          startMs: start,
          endMs: end,
          kind: mood.kind,
          mood: mood.mood,
          confidence: mood.confidence,
          evidence: mood.evidence,
          transcript: textValue,
          intensity: mood.intensity,
          sourceRef: targetPath,
          visualSummary: videoAnalysis?.summary,
          absoluteStartMs: sourceRecordedAtMs == null
              ? null
              : sourceRecordedAtMs! + start,
          absoluteEndMs: sourceRecordedAtMs == null
              ? null
              : sourceRecordedAtMs! + end,
        );
        nodes.add(node);
        _queueAutomaticMicProSync(node);
      }
      if (nodes.isEmpty) {
        throw StateError(
          text(
            '模型没有返回可用的真实转写或情绪结果',
            'The models returned no usable transcript or mood result',
          ),
        );
      }
      timeline = nodes;
      videoEvents = analyzedVideoEvents;
      highlights = _highlightsFromNodes(
        nodes,
        events: analyzedVideoEvents,
        sourceDurationMs: info.durationMs,
      );
      selectedNodeIndex = 0;
      final historyId =
          'analysis-${DateTime.now().millisecondsSinceEpoch}-${targetPath.hashCode}';
      _liveHistoryId = null;
      _liveRealtimeNodes = <WeatherNode>[];
      await _storeHistorySnapshot(
        id: historyId,
        sourceName: sourceName,
        sourcePath: targetPath,
        nodes: nodes,
        events: videoEvents,
        durationMs: info.durationMs,
      );
      analysisStage = AnalysisStage.ready;
      // Cut every highlight into a real standalone clip so playback and sharing use
      // an edited file rather than a pointer into the full recording.
      await _exportHighlightClips(targetPath);
      analysisProgress = 1;
      analysisMessage = text(
        '分析完成，已剪出 ${highlights.where((clip) => clip.clipPath != null).length} 段精彩瞬间',
        'Analysis complete; ${highlights.where((clip) => clip.clipPath != null).length} highlight clip(s) exported',
      );
    } catch (error) {
      _failAnalysis(
        text(
          '真实分析失败，未生成伪造结果',
          'Real analysis failed; no synthetic result was generated',
        ),
        error,
      );
    }
  }

  void _failAnalysis(String message, [Object? error]) {
    analysisStage = AnalysisStage.failed;
    analysisProgress = 0;
    analysisMessage = message;
    lastError = error?.toString();
    notifyListeners();
  }

  List<HighlightClip> _highlightsFromNodes(
    List<WeatherNode> nodes, {
    List<VideoEvent> events = const <VideoEvent>[],
    int? sourceDurationMs,
  }) {
    final candidates = <HighlightClip>[];
    final sortedEvents = [...events]
      ..sort((a, b) {
        final confidence = b.confidence.compareTo(a.confidence);
        if (confidence != 0) return confidence;
        return (b.endMs - b.startMs).compareTo(a.endMs - a.startMs);
      });

    for (final event in sortedEvents) {
      final node = nodes
          .where(
            (item) => item.startMs < event.endMs && item.endMs > event.startMs,
          )
          .fold<WeatherNode?>(
            null,
            (best, item) =>
                best == null || item.intensity > best.intensity ? item : best,
          );
      final range = _boundedHighlightRange(
        startMs: event.startMs,
        endMs: event.endMs,
        sourceDurationMs: sourceDurationMs,
        contextMs: 3000,
      );
      final reasonParts = <String>[
        event.description.trim(),
        if (node != null) ...node.evidence.take(1),
      ].where((item) => item.isNotEmpty).toList();
      final eventTitle = event.title.trim();
      final title = node == null || eventTitle.isEmpty
          ? (eventTitle.isEmpty ? '精彩瞬间' : eventTitle)
          : '${node.kind.chineseName} · $eventTitle';
      candidates.add(
        HighlightClip(
          id: 'event-${event.startMs}-${event.endMs}',
          startMs: range.$1,
          endMs: range.$2,
          kind: node?.kind ?? WeatherKind.cloudy,
          title: title,
          reason: reasonParts.isEmpty
              ? '视频模型识别到的画面事件'
              : reasonParts.join(' + '),
          score: math.max(event.confidence, node?.confidence ?? 0),
          transcript: node?.transcript ?? event.description,
          nodeStartMs: node?.startMs ?? event.startMs,
          sourcePath: event.sourceRef ?? node?.sourceRef ?? sourcePath,
          absoluteStartMs: _absoluteRangeStart(
            rangeStartMs: range.$1,
            signalStartMs: event.startMs,
            signalAbsoluteStartMs: event.absoluteStartMs,
            fallbackNode: node,
          ),
          absoluteEndMs: _absoluteRangeEnd(
            rangeEndMs: range.$2,
            signalEndMs: event.endMs,
            signalAbsoluteEndMs: event.absoluteEndMs,
            fallbackNode: node,
          ),
        ),
      );
    }

    final sortedNodes = [...nodes]
      ..sort((a, b) => b.intensity.compareTo(a.intensity));
    for (final node in sortedNodes) {
      if (candidates.length >= 3) break;
      final overlapsEvent = candidates.any(
        (clip) => clip.startMs < node.endMs && clip.endMs > node.startMs,
      );
      if (overlapsEvent) continue;
      final range = _boundedHighlightRange(
        startMs: node.startMs,
        endMs: node.endMs,
        sourceDurationMs: sourceDurationMs,
        contextMs: 3000,
      );
      candidates.add(
        HighlightClip(
          id: '${node.startMs}',
          startMs: range.$1,
          endMs: range.$2,
          kind: node.kind,
          title: '${node.kind.chineseName} · ${node.mood}',
          reason: node.evidence.take(2).join(' + '),
          score: node.confidence,
          transcript: node.transcript,
          nodeStartMs: node.startMs,
          sourcePath: node.sourceRef ?? sourcePath,
          absoluteStartMs: _absoluteRangeStart(
            rangeStartMs: range.$1,
            signalStartMs: node.startMs,
            signalAbsoluteStartMs: node.absoluteStartMs,
            fallbackNode: node,
          ),
          absoluteEndMs: _absoluteRangeEnd(
            rangeEndMs: range.$2,
            signalEndMs: node.endMs,
            signalAbsoluteEndMs: node.absoluteEndMs,
            fallbackNode: node,
          ),
        ),
      );
    }
    return candidates.take(3).toList();
  }

  /// Bounds a model signal to a standalone moment instead of copying a whole
  /// analysis window into the highlight list.
  (int, int) _boundedHighlightRange({
    required int startMs,
    required int endMs,
    required int? sourceDurationMs,
    required int contextMs,
  }) {
    final duration = sourceDurationMs != null && sourceDurationMs > 0
        ? sourceDurationMs
        : null;
    var start = math.max(0, startMs - contextMs);
    var end = math.max(start + 1000, endMs + contextMs);
    if (duration != null) {
      final latestValidStart = math.max(0, duration - 1000);
      start = start.clamp(0, latestValidStart).toInt();
      end = math.min(duration, math.max(start + 1000, end));
      final sourceLooksLikeWholeSignal =
          duration >= 8000 && end - start >= duration * 0.95;
      if (sourceLooksLikeWholeSignal) {
        final focusDuration = math.min(
          60 * 1000,
          math.max(8000, (duration * 0.75).round()),
        );
        if (focusDuration < duration) {
          final center = ((start + end) / 2).round();
          start = (center - focusDuration ~/ 2).clamp(
            0,
            duration - focusDuration,
          );
          end = start + focusDuration;
        }
      }
    }
    if (end - start > 60 * 1000) {
      final center = ((start + end) / 2).round();
      start = math.max(0, center - 30 * 1000);
      end = start + 60 * 1000;
      if (duration != null && end > duration) {
        end = duration;
        start = math.max(0, end - 60 * 1000);
      }
    }
    return (start, math.max(start + 1000, end));
  }

  int? _absoluteRangeStart({
    required int rangeStartMs,
    required int signalStartMs,
    required int? signalAbsoluteStartMs,
    required WeatherNode? fallbackNode,
  }) {
    final absoluteBase = signalAbsoluteStartMs == null
        ? (fallbackNode?.absoluteStartMs == null
              ? null
              : fallbackNode!.absoluteStartMs! - fallbackNode.startMs)
        : signalAbsoluteStartMs - signalStartMs;
    return absoluteBase == null ? null : absoluteBase + rangeStartMs;
  }

  int? _absoluteRangeEnd({
    required int rangeEndMs,
    required int signalEndMs,
    required int? signalAbsoluteEndMs,
    required WeatherNode? fallbackNode,
  }) {
    final absoluteBase = signalAbsoluteEndMs == null
        ? (fallbackNode?.absoluteStartMs == null
              ? null
              : fallbackNode!.absoluteStartMs! - fallbackNode.startMs)
        : signalAbsoluteEndMs - signalEndMs;
    return absoluteBase == null ? null : absoluteBase + rangeEndMs;
  }

  void selectNode(int index) {
    if (index < 0 || index >= timeline.length) return;
    selectedNodeIndex = index;
    notifyListeners();
  }

  Future<List<DeviceRecord>> scanDevices() async {
    scanning = true;
    connectionStage = DeviceConnectionStage.scanning;
    connectionStatus = text(
      '正在检查当前 Wi‑Fi 上的 GO Ultra…',
      'Checking for GO Ultra on the current Wi‑Fi…',
    );
    notifyListeners();
    try {
      await connectCurrentWifiCamera(allowWhileScanning: true);
      final discovered = List<DeviceRecord>.from(devices);
      analysisMessage = discovered.isNotEmpty
          ? text(
              '已在当前 Wi‑Fi 上发现 GO Ultra',
              'GO Ultra found on the current Wi‑Fi',
            )
          : text(
              '当前 Wi‑Fi 不是 GO Ultra 相机网络',
              'The current Wi‑Fi is not a GO Ultra camera network',
            );
      scanning = false;
      notifyListeners();
      return discovered;
    } catch (error) {
      scanning = false;
      connectionStage = DeviceConnectionStage.failed;
      connectionStatus = text('Wi‑Fi 检查失败', 'Wi‑Fi check failed');
      lastError = error.toString();
      notifyListeners();
      return <DeviceRecord>[];
    }
  }

  /// Connects through the Wi-Fi network already selected by Android.
  ///
  /// Camera discovery and connection never use Bluetooth. Bluetooth is reserved
  /// for the independent Mic Pro channel.
  Future<void> connectCurrentWifiCamera({bool allowWhileScanning = false}) async {
    if ((!allowWhileScanning && connectionStage.isBusy) ||
        connectedDevice != null) {
      return;
    }
    connectionStage = DeviceConnectionStage.connectingWifi;
    connectionStatus = text(
      '正在使用当前 Wi‑Fi 连接 GO Ultra…',
      'Connecting to GO Ultra over the current Wi‑Fi…',
    );
    lastError = null;
    previewReady = false;
    notifyListeners();
    try {
      final connected = await native.connectCurrentWifiCamera();
      final record =
          connected ??
          const DeviceRecord(
            id: 'go-ultra-wifi',
            name: 'GO Ultra Wi‑Fi',
            model: 'GO Ultra',
            connection: 'Wi‑Fi',
            isConnected: true,
          );
      _markDeviceConnected(record);
      connectionStage = DeviceConnectionStage.connected;
      connectionStatus = text(
        '已通过相机 Wi‑Fi 连接，正在启动实时视频流…',
        'Connected over camera Wi‑Fi; starting live video…',
      );
      _startAutoSync();
    } on PlatformException catch (error) {
      _markConnectionFailed(
        error.message ??
            'The current Wi‑Fi is not a reachable GO Ultra network',
      );
    } catch (error) {
      _markConnectionFailed(error.toString());
    } finally {
      notifyListeners();
    }
  }

  /// Connects through the camera Wi-Fi selected in Android system settings.
  ///
  /// GO Ultra is deliberately never connected through BLE. The system Wi-Fi
  /// hand-off keeps the camera transport separate from MicPro's BLE channel.
  Future<void> connectCameraAutomatically() async {
    await connectCurrentWifiCamera();
  }

  Future<void> toggleDevice(DeviceRecord device) async {
    if (device.isConnected) {
      _stopAutoSync();
      connectionStage = DeviceConnectionStage.idle;
      connectionStatus = text(
        '正在断开 ${device.name}',
        'Disconnecting ${device.name}',
      );
      previewReady = false;
      syncingLatestMedia = false;
      notifyListeners();
      await _stopRealtimeAnalysis();
      await native.disconnectCamera();
      devices = devices
          .map((item) => item.copyWith(isConnected: false))
          .toList();
      connectedDeviceName = null;
      connectionStatus = text('已断开设备', 'Device disconnected');
      notifyListeners();
      return;
    }
    if (connectionStage.isBusy) return;
    // A scanned BLE identity is only informational. The actual camera session
    // must always attach to the Wi-Fi network selected by Android.
    await connectCurrentWifiCamera();
  }

  /// True while the camera is recording (started in-app or from the shutter).
  bool recordingActive = false;
  int recordingElapsedMs = 0;
  String recordingStatus = '未开始录像';

  Future<void> toggleRecording() async {
    if (!connectionIsActive) {
      recordingStatus = text('请先连接 GO Ultra', 'Connect GO Ultra first');
      notifyListeners();
      return;
    }
    try {
      if (recordingActive) {
        recordingStatus = text('正在停止录像…', 'Stopping the recording…');
        notifyListeners();
        await native.stopRecording();
      } else {
        recordingStatus = text('正在开始录像…', 'Starting the recording…');
        notifyListeners();
        await native.startRecording();
      }
    } catch (error) {
      recordingStatus = text(
        '录像操作失败：$error',
        'Recording action failed: $error',
      );
      lastError = error.toString();
      notifyListeners();
    }
  }

  /// Camera videos available for manual selection.
  List<CameraVideo> cameraVideos = <CameraVideo>[];
  bool loadingCameraVideos = false;
  String? cameraVideoError;

  /// Loads the video list from the connected camera so the user can pick a clip
  /// instead of always analyzing the newest one.
  Future<void> loadCameraVideos() async {
    if (!connectionIsActive) {
      cameraVideoError = text('请先连接 GO Ultra', 'Connect GO Ultra first');
      notifyListeners();
      return;
    }
    loadingCameraVideos = true;
    cameraVideoError = null;
    notifyListeners();
    try {
      final videos = await native.listCameraVideos();
      cameraVideos = videos;
      if (videos.isEmpty) {
        cameraVideoError = text(
          '相机上没有可分析的视频',
          'No analyzable video on the camera',
        );
      }
    } catch (error) {
      cameraVideoError = error.toString();
    } finally {
      loadingCameraVideos = false;
      notifyListeners();
    }
  }

  /// Downloads the chosen camera clip and analyzes it immediately.
  Future<void> analyzeCameraVideo(CameraVideo video) async {
    if (isAnalyzing) return;
    analysisStage = AnalysisStage.inspecting;
    analysisProgress = 0.04;
    analysisMessage = text(
      '正在从 GO Ultra 同步 ${video.name}…',
      'Syncing ${video.name} from GO Ultra…',
    );
    lastError = null;
    notifyListeners();
    try {
      final synced = await native.syncCameraVideo(video.key);
      if (synced == null || synced.path.isEmpty) {
        throw StateError(
          text('未能下载所选视频', 'The selected video could not be downloaded'),
        );
      }
      latestSyncedPath = synced.path;
      sourcePath = synced.path;
      sourceName = synced.name;
      mediaInfo = await native.inspectMedia(synced.path);
      sourceRecordedAtMs = synced.creationTimeMs ?? mediaInfo?.recordedAtMs;
      if (mediaInfo != null &&
          sourceRecordedAtMs != null &&
          mediaInfo!.recordedAtMs != sourceRecordedAtMs) {
        mediaInfo = mediaInfo!.copyWith(recordedAtMs: sourceRecordedAtMs);
      }
      analysisStage = AnalysisStage.idle;
      analysisProgress = 0;
      syncStatus = text('已同步 ${synced.name}', 'Synced ${synced.name}');
      notifyListeners();
      await startAnalysis(path: synced.path, name: synced.name);
    } catch (error) {
      _failAnalysis(error.toString());
    }
  }

  Future<void> syncLatestMedia({bool automatic = false}) async {
    if (!connectionIsActive) {
      if (!automatic) {
        syncStatus = text('请先连接 GO Ultra', 'Connect GO Ultra before syncing');
        notifyListeners();
      }
      return;
    }
    if (syncingLatestMedia) return;
    syncingLatestMedia = true;
    connectionStage = DeviceConnectionStage.syncing;
    syncStatus = text(
      automatic ? '正在自动检查最新视频…' : '正在从 GO Ultra 同步最新视频…',
      automatic
          ? 'Checking for the latest video…'
          : 'Syncing the latest video from GO Ultra…',
    );
    notifyListeners();
    try {
      final synced = await native.syncLatestMedia();
      if (synced == null || synced.path.isEmpty) {
        throw StateError(
          text('GO Ultra 没有可同步的视频', 'GO Ultra has no video to sync'),
        );
      }
      final isNew = latestSyncedPath != synced.path;
      latestSyncedPath = synced.path;
      sourcePath = synced.path;
      sourceName = synced.name;
      mediaInfo = await native.inspectMedia(synced.path);
      sourceRecordedAtMs = synced.creationTimeMs ?? mediaInfo?.recordedAtMs;
      if (mediaInfo != null &&
          sourceRecordedAtMs != null &&
          mediaInfo!.recordedAtMs != sourceRecordedAtMs) {
        mediaInfo = mediaInfo!.copyWith(recordedAtMs: sourceRecordedAtMs);
      }
      syncStatus = isNew
          ? text('已同步 ${synced.name}', 'Synced ${synced.name}')
          : text('已是最新视频：${synced.name}', 'Already up to date: ${synced.name}');
      connectionStage = DeviceConnectionStage.connected;
      notifyListeners();
      final shouldAnalyzeSyncedVideo =
          !automatic || (!realtimeAsrActive && !realtimeAsrConnecting);
      final canUseRealtimeMediaWindows =
          automatic &&
          qwen.isConfigured &&
          realtimeAudioFrames == 0 &&
          !realtimeAsrActive &&
          !realtimeAsrConnecting &&
          !mediaWindowAnalysisRunning &&
          !isAnalyzing &&
          mediaInfo?.hasAudio == true &&
          mediaInfo?.hasVideo == true;
      if (isNew &&
          canUseRealtimeMediaWindows &&
          _lastAutoAnalyzedPath != synced.path) {
        _lastAutoAnalyzedPath = synced.path;
        unawaited(_runMediaWindowAnalysis());
      } else if (isNew &&
          !isAnalyzing &&
          !mediaWindowAnalysisRunning &&
          shouldAnalyzeSyncedVideo &&
          _lastAutoAnalyzedPath != synced.path) {
        _lastAutoAnalyzedPath = synced.path;
        await startAnalysis(path: synced.path, name: synced.name);
      }
    } catch (error) {
      syncStatus = text('同步失败，请点击重试', 'Sync failed; tap to retry');
      lastError = error.toString();
      connectionStage = DeviceConnectionStage.connected;
      if (!automatic) notifyListeners();
    } finally {
      syncingLatestMedia = false;
      if (connectionIsActive &&
          connectionStage == DeviceConnectionStage.syncing) {
        connectionStage = DeviceConnectionStage.connected;
      }
      notifyListeners();
    }
  }

  Future<void> testAiConnection() async {
    if (aiTesting) return;
    aiTesting = true;
    aiTestMessage = text('正在请求 Qwen…', 'Requesting Qwen…');
    notifyListeners();
    try {
      final reply = await qwen.testConnection();
      aiTestMessage = text(
        '连接成功：${reply.trim().isEmpty ? '已收到响应' : reply.trim()}',
        'Connected: ${reply.trim().isEmpty ? 'response received' : reply.trim()}',
      );
    } catch (error) {
      aiTestMessage = text('连接失败：$error', 'Connection failed: $error');
    } finally {
      aiTesting = false;
      notifyListeners();
    }
  }

  void _handleNativeEvent(Map<String, dynamic> event) {
    final stage = event['stage']?.toString();
    final deviceId = event['deviceId']?.toString();
    final deviceName = event['deviceName']?.toString();
    if (deviceName != null && deviceName.isNotEmpty) {
      connectedDeviceName = deviceName;
    }
    if (stage == 'audio_stream') {
      _handleRealtimeAudioEvent(event);
      if (realtimeAudioFrames % 10 != 0) return;
    }
    if (stage == 'video_stream_frame') {
      _handleRealtimeVideoFrame(event);
      return;
    }
    switch (stage) {
      case 'scan_started':
        scanning = true;
        connectionStage = DeviceConnectionStage.scanning;
        connectionStatus = text('正在扫描真实 GO 设备…', 'Scanning real GO devices…');
      case 'scan_finished':
        scanning = false;
        if (!connectionIsActive) {
          connectionStage = DeviceConnectionStage.idle;
          connectionStatus = text('等待连接 GO Ultra', 'Waiting for GO Ultra');
        }
      case 'scan_failed':
        scanning = false;
        connectionStage = DeviceConnectionStage.failed;
        connectionStatus = text('扫描失败', 'Scan failed');
      case 'connecting_ble':
        connectingDeviceId = deviceId ?? connectingDeviceId;
        connectionStage = DeviceConnectionStage.switchingWifi;
        connectionStatus = text('正在建立 BLE 连接…', 'Establishing BLE connection…');
      case 'ble_connected':
        connectionStage = DeviceConnectionStage.switchingWifi;
        connectionStatus = text(
          '正在获取相机 Wi‑Fi 参数…',
          'Reading the camera Wi‑Fi settings…',
        );
      case 'switching_ap':
        connectionStage = DeviceConnectionStage.switchingWifi;
        connectionStatus = text(
          '正在让 GO Ultra 进入 Wi‑Fi 模式…',
          'Switching GO Ultra to Wi‑Fi mode…',
        );
      case 'requesting_wifi':
        connectionStage = DeviceConnectionStage.requestingWifi;
        connectionStatus = text(
          '正在请求相机 Wi‑Fi 网络…',
          'Requesting the camera Wi‑Fi network…',
        );
      case 'wifi_available':
        connectionStage = DeviceConnectionStage.connectingWifi;
        connectionStatus = text(
          'Wi‑Fi 已就绪，正在连接 SDK…',
          'Wi‑Fi ready; connecting the SDK…',
        );
      case 'connecting_wifi':
        connectionStage = DeviceConnectionStage.connectingWifi;
        connectionStatus = text(
          '正在建立 SDK Wi‑Fi 连接…',
          'Establishing the SDK Wi‑Fi connection…',
        );
      case 'recording_starting':
        recordingStatus = text(
          '相机正在进入录像状态…',
          'Camera is entering record mode…',
        );
      case 'recording_started':
        recordingActive = true;
        recordingElapsedMs = 0;
        recordingStatus = text('录像进行中', 'Recording');
      case 'recording_tick':
        recordingElapsedMs = _number(event['elapsedMs']).round();
        recordingStatus = text(
          '录像进行中 · ${formatDuration(recordingElapsedMs)}',
          'Recording · ${formatDuration(recordingElapsedMs)}',
        );
      case 'recording_stopping':
        recordingStatus = text('正在停止录像…', 'Stopping the recording…');
      case 'recording_finished':
        recordingActive = false;
        recordingStatus = text(
          '录像已结束，可同步分析',
          'Recording finished; ready to analyze',
        );
        if (connectionIsActive) {
          unawaited(syncLatestMedia(automatic: true));
        }
      case 'recording_error':
        recordingActive = false;
        recordingStatus = text('录像失败', 'Recording failed');
        lastError = event['detail']?.toString();
      case 'authorization_requested':
        connectionStatus = text(
          '请在 GO Ultra 的 Action Pod 上确认授权…',
          'Confirm authorization on the GO Ultra Action Pod…',
        );
      case 'authorization_result':
        final outcome = event['detail']?.toString() ?? '';
        connectionStatus = outcome.contains('SUCCESS')
            ? text('授权成功', 'Authorization granted')
            : text('授权结果：$outcome', 'Authorization result: $outcome');
      case 'authorization_failed':
        connectionStatus = text('授权失败', 'Authorization failed');
        lastError = event['detail']?.toString();
      case 'micpro_authorization_requested':
        micProStatus = text(
          '请在 5 秒内按 Mic Pro 电源键授权',
          'Press the Mic Pro power button within 5 seconds',
        );
        syncMessage = micProStatus;
      case 'micpro_push_failed':
        micProStatus = text(
          'MicPro 推送失败：${event['detail'] ?? '未知错误'}',
          'MicPro push failed: ${event['detail'] ?? 'unknown error'}',
        );
        syncMessage = micProStatus;
      case 'micpro_pushed':
        micProStatus = text('MicPro 已更新情绪图标', 'MicPro mood icon updated');
      case 'camera_ready':
        _markDeviceConnectedByEvent(deviceId, deviceName);
        connectionStage = DeviceConnectionStage.connected;
        connectionStatus = text(
          '设备已连接，正在启动实时视频流…',
          'Device connected; starting live stream…',
        );
        _startAutoSync();
        unawaited(_startRealtimeAnalysis());
      case 'connected':
        _markDeviceConnectedByEvent(deviceId, deviceName);
        connectionStage = DeviceConnectionStage.connected;
        connectionStatus = text(
          '设备已连接，正在启动实时视频流…',
          'Device connected; starting live stream…',
        );
      case 'preview_starting':
        if (connectionIsActive) {
          connectionStatus = text(
            '已连接，实时视频流启动中…',
            'Connected; starting live video…',
          );
        }
      case 'preview_ready':
        previewReady = true;
        connectionStage = DeviceConnectionStage.connected;
        connectionStatus = text(
          '已连接 · 实时视频流已就绪',
          'Connected · live video ready',
        );
        unawaited(_startRealtimeAnalysis());
      case 'internet_ready':
        if (realtimeAsrActive) {
          realtimeStatus = text(
            '实时 ASR 已连接，等待语音…',
            'Realtime ASR connected; waiting for speech…',
          );
        }
      case 'preview_failed':
        previewReady = false;
        connectionStatus = text(
          '设备已连接，但实时预览启动失败',
          'Device connected, but live preview failed',
        );
        lastError = event['detail']?.toString();
      case 'connection_failed':
        unawaited(_stopRealtimeAnalysis());
        _markConnectionFailed(
          event['detail']?.toString() ?? 'Unknown connection error',
        );
      case 'disconnected':
        unawaited(_stopRealtimeAnalysis(flushWindow: true));
        _stopAutoSync();
        realtimeRetryTimer?.cancel();
        realtimeRetryTimer = null;
        devices = devices
            .map((item) => item.copyWith(isConnected: false))
            .toList();
        connectedDeviceName = null;
        previewReady = false;
        connectionStage = DeviceConnectionStage.idle;
        connectionStatus = text('设备已断开', 'Device disconnected');
      case 'sync_started':
        syncingLatestMedia = true;
        connectionStage = DeviceConnectionStage.syncing;
        syncStatus = text('正在同步最新视频…', 'Syncing the latest video…');
      case 'sync_progress':
        syncingLatestMedia = true;
        connectionStage = DeviceConnectionStage.syncing;
        final total = _number(event['total']);
        final progress = _number(event['progress']);
        syncStatus = total > 0
            ? text(
                '正在同步 ${(progress / total * 100).round()}%',
                'Syncing ${(progress / total * 100).round()}%',
              )
            : text('正在同步…', 'Syncing…');
      case 'sync_ready':
        syncStatus = text('最新视频已下载到手机', 'Latest video downloaded to the phone');
      case 'sync_failed':
        syncingLatestMedia = false;
        connectionStage = DeviceConnectionStage.connected;
        syncStatus = text(
          '自动同步失败，可点击立即同步重试',
          'Auto-sync failed; tap sync to retry',
        );
        lastError = event['detail']?.toString();
    }
    notifyListeners();
  }

  void _handleRealtimeAudioEvent(Map<String, dynamic> event) {
    final rawData = event['data'];
    final Uint8List? data = rawData is Uint8List
        ? rawData
        : rawData is List
        ? Uint8List.fromList(
            rawData.whereType<num>().map((value) => value.toInt()).toList(),
          )
        : null;
    if (data == null || data.isEmpty) return;
    realtimeAudioFrames += 1;
    realtimeAudioBytes += data.length;
    if (realtimeAudioFrames == 1 &&
        _realtimeAsr == null &&
        !realtimeAsrConnecting &&
        !mediaWindowAnalysisRunning) {
      unawaited(_startRealtimeAnalysis());
    }
    final timestamp = _number(
      event['timestampMs'] ?? event['timestamp'],
    ).round();
    _realtimeWindowStartCameraMs ??= timestamp;
    _realtimeWindowStartAbsoluteMs ??= DateTime.now().millisecondsSinceEpoch;
    _realtimeAsr?.addAudio(data, timestampMs: timestamp);
    if (realtimeAudioFrames == 1 || realtimeAudioFrames % 10 == 0) {
      realtimeStatus = realtimeAsrActive
          ? text(
              '实时音频已接入，等待 Qwen 转写…',
              'Live audio connected; waiting for Qwen transcription…',
            )
          : text(
              '已收到实时音频，正在连接 Qwen ASR…',
              'Live audio received; connecting Qwen ASR…',
            );
    }
  }

  void _handleRealtimeVideoFrame(Map<String, dynamic> event) {
    if (!realtimeAsrActive && !realtimeAsrConnecting) return;
    final rawData = event['data'];
    if (rawData is! Uint8List || rawData.isEmpty) return;
    final timestamp = _number(
      event['timestampMs'] ?? event['timestamp'],
    ).round();
    if (timestamp < 0) return;
    _realtimeWindowStartCameraMs ??= timestamp;
    _realtimeWindowStartAbsoluteMs ??= DateTime.now().millisecondsSinceEpoch;
    final lastSample = _lastRealtimeVideoSampleMs;
    if (lastSample != null &&
        timestamp >= lastSample &&
        timestamp - lastSample < realtimeVideoSampleIntervalMs) {
      return;
    }
    _lastRealtimeVideoSampleMs = timestamp;
    _realtimeWindowVideoFrames = [
      ..._realtimeWindowVideoFrames,
      VideoFrameSample(timestampMs: timestamp, data: rawData),
    ];
  }

  /// GO Ultra preview streams carry video only, so live audio never reaches the
  /// realtime ASR socket. This fallback analyzes the newest synced media file in
  /// 3-minute windows through the batch pipeline, producing real results from
  /// real audio and real frames instead of idling with zero audio frames.
  Future<void> _runMediaWindowAnalysis() async {
    if (mediaWindowAnalysisRunning) return;
    final path = sourcePath;
    if (path == null || path.isEmpty) return;
    final info = mediaInfo;
    if (info == null || !info.hasAudio || !info.hasVideo) return;
    mediaWindowAnalysisRunning = true;
    try {
      final duration = info.durationMs;
      final sourceStart = sourceRecordedAtMs;
      final windows = math.max(1, (duration / realtimeAnalysisWindowMs).ceil());
      for (var index = 0; index < windows; index++) {
        if (!connectionIsActive && !previewReady) break;
        final startMs = index * realtimeAnalysisWindowMs;
        final endMs = math.min(duration, startMs + realtimeAnalysisWindowMs);
        if (endMs <= startMs) break;
        final label = sourceStart == null
            ? '${formatOffset(startMs)}—${formatOffset(endMs)}'
            : '${formatTimestamp(sourceStart + startMs)}—${formatTimestamp(sourceStart + endMs)}';
        realtimeStatus = text(
          '正在分析素材窗口 $label（${index + 1}/$windows）…',
          'Analyzing media window $label (${index + 1}/$windows)…',
        );
        notifyListeners();
        try {
          final audioPath = await native.extractAudioChunk(
            path: path,
            startMs: startMs,
            endMs: endMs,
          );
          TranscriptSegment? segment;
          if (audioPath != null && audioPath.isNotEmpty) {
            segment = await qwen.transcribeAudio(
              audioFile: File(audioPath),
              sourceStartMs: startMs,
              sourceEndMs: endMs,
            );
          }
          final frames = await native.extractVideoFrames(
            path: path,
            startMs: startMs,
            endMs: endMs,
          );
          VideoAnalysisResult? videoAnalysis;
          if (frames.isNotEmpty) {
            try {
              videoAnalysis = await qwen.understandVideoFrames(
                frames: frames,
                sourceStartMs: startMs,
                sourceEndMs: endMs,
              );
            } catch (error) {
              realtimeStatus = text(
                '画面理解超时，继续使用音频分析 $label…',
                'Visual understanding timed out; continuing with audio for $label…',
              );
              notifyListeners();
            }
          }
          final transcript = segment?.text.trim() ?? '';
          MoodResult? mood;
          if (transcript.isNotEmpty) {
            mood = await qwen.analyzeMood(
              transcript: transcript,
              localSignals: [
                text('GO Ultra 已同步素材', 'Synced GO Ultra media'),
                text('音频与相机时间戳已对齐', 'Audio aligned to camera timestamps'),
                if (videoAnalysis != null) '视频理解：${videoAnalysis.summary}',
              ],
            );
          }
          final absoluteStart = sourceStart == null
              ? null
              : sourceStart + startMs;
          final absoluteEnd = sourceStart == null ? null : sourceStart + endMs;
          if (mood != null) {
            final node = WeatherNode(
              startMs: startMs,
              endMs: endMs,
              kind: mood.kind,
              mood: mood.mood,
              confidence: mood.confidence,
              evidence: mood.evidence,
              transcript: transcript,
              intensity: mood.intensity,
              sourceRef: path,
              visualSummary: videoAnalysis?.summary,
              absoluteStartMs: absoluteStart,
              absoluteEndMs: absoluteEnd,
            );
            timeline = [...timeline, node]
              ..sort((a, b) => a.startMs.compareTo(b.startMs));
            _liveRealtimeNodes = [..._liveRealtimeNodes, node];
            _queueAutomaticMicProSync(node);
            realtimeMood = mood.mood;
            realtimeWeather = mood.kind;
          }
          final events = videoAnalysis?.events ?? const <VideoEvent>[];
          if (events.isNotEmpty) {
            // Each event keeps its own offset inside the window so the timeline can
            // jump back to the exact moment rather than the whole window.
            final mapped = events
                .map(
                  (event) => event.copyWith(
                    sourceRef: path,
                    absoluteStartMs: absoluteStart == null
                        ? null
                        : absoluteStart + event.startMs - startMs,
                    absoluteEndMs: absoluteStart == null
                        ? null
                        : absoluteStart + event.endMs - startMs,
                  ),
                )
                .toList();
            videoEvents = [...videoEvents, ...mapped];
            _liveRealtimeEvents = [..._liveRealtimeEvents, ...mapped];
          }
          highlights = _highlightsFromNodes(
            timeline,
            events: videoEvents,
            sourceDurationMs: mediaInfo?.durationMs,
          );
          if (timeline.isNotEmpty) selectedNodeIndex = timeline.length - 1;
          notifyListeners();
        } catch (error) {
          realtimeStatus = text(
            '素材窗口分析失败：$error',
            'Media window analysis failed: $error',
          );
          lastError = error.toString();
          notifyListeners();
        }
      }
      await _storeHistorySnapshot(
        id: _liveHistoryId ?? 'live-${DateTime.now().millisecondsSinceEpoch}',
        sourceName: sourceName,
        sourcePath: sourcePath,
        nodes: _liveRealtimeNodes,
        events: _liveRealtimeEvents,
        durationMs: mediaInfo?.durationMs,
      );
      await _exportHighlightClips(path);
      realtimeStatus = text(
        '素材分析完成：已生成真实天气曲线',
        'Media analysis finished: real weather curve ready',
      );
    } finally {
      mediaWindowAnalysisRunning = false;
      notifyListeners();
    }
  }

  Future<void> _startRealtimeAnalysis() async {
    if ((!connectionIsActive && !previewReady) ||
        _realtimeAsr != null ||
        realtimeAsrConnecting) {
      return;
    }
    // The GO Ultra preview stream may be video-only. Use synced media on the tablet
    // until an audio frame arrives, then let the real-time ASR path take over.
    if (realtimeAudioFrames == 0) {
      if (sourcePath != null && mediaInfo != null) {
        unawaited(_runMediaWindowAnalysis());
      } else {
        realtimeStatus = text(
          '等待 GO Ultra 音频或最新同步素材…',
          'Waiting for GO Ultra audio or the latest synced media…',
        );
        notifyListeners();
      }
      return;
    }
    if (!qwen.isConfigured) {
      realtimeStatus = text(
        '未配置 Qwen，实时 ASR 未启动',
        'Qwen is not configured; realtime ASR is off',
      );
      notifyListeners();
      return;
    }
    realtimeAsrConnecting = true;
    realtimeMood = '';
    realtimeWeather = null;
    _liveRealtimeNodes = <WeatherNode>[];
    _liveRealtimeEvents = <VideoEvent>[];
    _liveHistoryId =
        'live-${DateTime.now().millisecondsSinceEpoch}-${connectedDeviceName ?? 'go-ultra'}';
    realtimeStatus = text(
      '正在连接 Qwen 实时 ASR，分析窗口为 3 分钟…',
      'Connecting to Qwen realtime ASR with 3-minute windows…',
    );
    notifyListeners();
    _resetRealtimeWindowState();
    final session = QwenRealtimeAsr(
      apiKey: QwenService.apiKey,
      workspaceId: QwenService.workspaceId,
    );
    _realtimeAsr = session;
    realtimeAsrSubscription = session.results.listen(
      _handleRealtimeTranscript,
      onError: (Object error, StackTrace stack) {
        realtimeAsrActive = false;
        realtimeStatus = text(
          '实时 ASR 失败：$error',
          'Realtime ASR failed: $error',
        );
        lastError = error.toString();
        notifyListeners();
        unawaited(
          _stopRealtimeAnalysis().then((_) => _scheduleRealtimeRetry()),
        );
      },
    );
    try {
      // The session routes its WebSocket through the platform AI transport, so the
      // process can stay bound to the camera Wi-Fi while ASR uses mobile data.
      await session.start();
      realtimeAsrActive = true;
      realtimeStatus = text(
        '实时 ASR 已连接，持续采集 3 分钟窗口…',
        'Realtime ASR connected; collecting 3-minute windows…',
      );
      realtimeWindowTimer?.cancel();
      realtimeWindowTimer = Timer.periodic(
        const Duration(milliseconds: realtimeAnalysisWindowMs),
        (_) => _queueRealtimeWindow(
          force:
              _realtimeWindowTranscripts.isEmpty &&
              _realtimeWindowVideoFrames.isEmpty,
        ),
      );
    } catch (error) {
      realtimeAsrActive = false;
      realtimeStatus = text(
        '实时 ASR 连接失败：$error',
        'Realtime ASR connection failed: $error',
      );
      lastError = error.toString();
      await _stopRealtimeAnalysis();
      _scheduleRealtimeRetry();
    } finally {
      realtimeAsrConnecting = false;
      notifyListeners();
    }
  }

  void _scheduleRealtimeRetry() {
    if (realtimeRetryTimer != null || !connectionIsActive) return;
    realtimeRetryTimer = Timer(const Duration(seconds: 5), () {
      realtimeRetryTimer = null;
      if (connectionIsActive) unawaited(_startRealtimeAnalysis());
    });
  }

  Future<void> _stopRealtimeAnalysis({bool flushWindow = false}) async {
    if (flushWindow &&
        _realtimeWindowStartCameraMs != null &&
        (_realtimeWindowTranscripts.isNotEmpty ||
            _realtimeWindowVideoFrames.isNotEmpty)) {
      _queueRealtimeWindow(force: true);
    }
    realtimeAsrConnecting = false;
    realtimeAsrActive = false;
    realtimeWindowTimer?.cancel();
    realtimeWindowTimer = null;
    final subscription = realtimeAsrSubscription;
    realtimeAsrSubscription = null;
    await subscription?.cancel();
    final session = _realtimeAsr;
    _realtimeAsr = null;
    await session?.stop();
    if (flushWindow) await _realtimeMoodQueue;
  }

  void _resetRealtimeWindowState() {
    _realtimeWindowTranscripts = <RealtimeTranscript>[];
    _realtimeWindowVideoFrames = <VideoFrameSample>[];
    _realtimeWindowStartCameraMs = null;
    _realtimeWindowStartAbsoluteMs = null;
    _lastRealtimeVideoSampleMs = null;
    _lastRealtimeIntensity = null;
    _lastRealtimeWeather = null;
    _lastRealtimeMood = null;
  }

  void _handleRealtimeTranscript(RealtimeTranscript result) {
    realtimeTranscript = result.text;
    if (result.isFinal && result.text.trim().isNotEmpty) {
      _realtimeWindowStartCameraMs ??= result.startMs;
      _realtimeWindowStartAbsoluteMs ??= result.absoluteStartMs;
      _realtimeWindowTranscripts.add(result);
      _queueRealtimeWindow();
      realtimeStatus = text(
        '已暂存 ${_realtimeWindowTranscripts.length} 句，满 3 分钟后联合分析…',
        '${_realtimeWindowTranscripts.length} sentence(s) buffered; joint analysis starts at 3 minutes…',
      );
    }
    notifyListeners();
  }

  void _queueRealtimeWindow({bool force = false}) {
    final windowStart = _realtimeWindowStartCameraMs;
    if (windowStart == null) return;
    final boundary = windowStart + realtimeAnalysisWindowMs;
    final buffered = List<RealtimeTranscript>.from(_realtimeWindowTranscripts);
    final bufferedVideo = List<VideoFrameSample>.from(
      _realtimeWindowVideoFrames,
    );
    if (buffered.isEmpty && bufferedVideo.isEmpty && !force) return;

    final latestTranscriptEnd = buffered.isEmpty
        ? windowStart
        : buffered
              .map((item) => item.endMs)
              .reduce((left, right) => math.max(left, right));
    final latestVideoTimestamp = bufferedVideo.isEmpty
        ? windowStart
        : bufferedVideo
              .map((item) => item.timestampMs)
              .reduce((left, right) => math.max(left, right));
    if (!force &&
        latestTranscriptEnd < boundary &&
        latestVideoTimestamp < boundary) {
      return;
    }

    final holdBoundary = boundary - realtimeBoundaryHoldMs;
    final splitIndex = force
        ? buffered.length - 1
        : buffered.lastIndexWhere((item) => item.endMs <= holdBoundary);
    final selected = buffered.isEmpty || splitIndex < 0
        ? const <RealtimeTranscript>[]
        : buffered.take(splitIndex + 1).toList();
    final carry = buffered.isEmpty || splitIndex < 0
        ? buffered
        : buffered.skip(splitIndex + 1).toList();
    final selectedVideo = force
        ? bufferedVideo
        : bufferedVideo
              .where((item) => item.timestampMs <= holdBoundary)
              .toList();
    final carryVideo = force
        ? const <VideoFrameSample>[]
        : bufferedVideo
              .where((item) => item.timestampMs > holdBoundary)
              .toList();

    final earliestBuffered = [
      ...buffered.map((item) => item.startMs),
      ...bufferedVideo.map((item) => item.timestampMs),
    ];
    final hasSelectedData = selected.isNotEmpty || selectedVideo.isNotEmpty;
    if (!force &&
        !hasSelectedData &&
        earliestBuffered.isNotEmpty &&
        earliestBuffered.reduce((left, right) => left < right ? left : right) <
            boundary) {
      // Keep a sentence/frame that overlaps the boundary for the next window.
      return;
    }
    _realtimeWindowTranscripts = carry;
    _realtimeWindowVideoFrames = carryVideo;
    final absoluteStart = _realtimeWindowStartAbsoluteMs;
    _realtimeWindowStartCameraMs = boundary;
    _realtimeWindowStartAbsoluteMs = absoluteStart == null
        ? null
        : absoluteStart + realtimeAnalysisWindowMs;
    _realtimeMoodQueue = _realtimeMoodQueue.then((_) async {
      await _analyzeRealtimeWindow(
        transcripts: selected,
        videoFrames: selectedVideo,
        startMs: windowStart,
        endMs: boundary,
        absoluteStartMs: absoluteStart,
      );
    });
  }

  Future<void> _analyzeRealtimeWindow({
    required List<RealtimeTranscript> transcripts,
    required List<VideoFrameSample> videoFrames,
    required int startMs,
    required int endMs,
    required int? absoluteStartMs,
  }) async {
    final windowLabel = absoluteStartMs == null
        ? '${formatOffset(startMs)}—${formatOffset(endMs)}'
        : '${formatTimestamp(absoluteStartMs)}—${formatTimestamp(absoluteStartMs + realtimeAnalysisWindowMs)}';
    realtimeStatus = text(
      '正在联合分析 3 分钟窗口 $windowLabel…',
      'Jointly analyzing the 3-minute window $windowLabel…',
    );
    notifyListeners();
    try {
      final transcript = transcripts
          .map((item) => item.text.trim())
          .where((item) => item.isNotEmpty)
          .join(' ');
      VideoAnalysisResult? videoAnalysis;
      final liveSourcePath = sourcePath;
      final sourceDuration = mediaInfo?.durationMs ?? 0;
      try {
        if (videoFrames.isNotEmpty) {
          videoAnalysis = await qwen.understandVideoFrames(
            frames: videoFrames,
            sourceStartMs: startMs,
            sourceEndMs: endMs,
          );
        } else if (liveSourcePath != null &&
            liveSourcePath.isNotEmpty &&
            startMs < sourceDuration) {
          final videoEnd = math.min(endMs, sourceDuration);
          final frames = await native.extractVideoFrames(
            path: liveSourcePath,
            startMs: startMs,
            endMs: videoEnd,
          );
          if (frames.isNotEmpty) {
            videoAnalysis = await qwen.understandVideoFrames(
              frames: frames,
              sourceStartMs: startMs,
              sourceEndMs: videoEnd,
            );
          }
        }
      } catch (error) {
        realtimeStatus = text(
          '画面理解超时，继续使用实时音频…',
          'Visual understanding timed out; continuing with realtime audio…',
        );
        notifyListeners();
      }
      MoodResult? mood;
      if (transcript.isNotEmpty) {
        mood = await qwen.analyzeMood(
          transcript: transcript,
          localSignals: [
            'GO Ultra 实时 3 分钟窗口',
            '音频与相机时间戳已对齐',
            if (videoAnalysis != null) '视频理解：${videoAnalysis.summary}',
            if (videoAnalysis != null && videoAnalysis.events.isNotEmpty)
              '视频事件：${videoAnalysis.events.map((event) => event.title).join('、')}',
          ],
        );
      }
      final visualEvents = videoAnalysis?.events ?? const <VideoEvent>[];
      final moodChanged =
          mood != null &&
          (_lastRealtimeMood == null ||
              mood.mood != _lastRealtimeMood ||
              mood.kind != _lastRealtimeWeather);
      final moodIsNotable =
          mood != null &&
          (moodChanged ||
              (_lastRealtimeIntensity == null
                  ? mood.intensity >= 65 ||
                        mood.kind == WeatherKind.storm ||
                        mood.kind == WeatherKind.rainbow
                  : (mood.intensity - _lastRealtimeIntensity!).abs() >= 25 ||
                        (mood.kind != _lastRealtimeWeather &&
                            mood.intensity >= 50)));
      final hasNotableResult = moodIsNotable || visualEvents.isNotEmpty;
      if (mood == null && visualEvents.isEmpty) {
        realtimeStatus = text(
          '本窗口没有可记录的语音或画面结果',
          'This window produced no recordable speech or visual result',
        );
        return;
      }
      if (mood != null) {
        _lastRealtimeIntensity = mood.intensity;
        _lastRealtimeWeather = mood.kind;
        _lastRealtimeMood = mood.mood;
      }
      if (!hasNotableResult) {
        realtimeStatus = text(
          '本窗口变化不明显，已跳过记录',
          'No significant change in this window; record skipped',
        );
        return;
      }
      final absoluteEndMs = absoluteStartMs == null
          ? null
          : absoluteStartMs + realtimeAnalysisWindowMs;
      if (mood != null && moodIsNotable) {
        final node = WeatherNode(
          startMs: startMs,
          endMs: endMs,
          kind: mood.kind,
          mood: mood.mood,
          confidence: mood.confidence,
          evidence: mood.evidence,
          transcript: transcript,
          intensity: mood.intensity,
          sourceRef: liveSourcePath ?? 'GO Ultra live stream',
          visualSummary: videoAnalysis?.summary,
          absoluteStartMs: absoluteStartMs,
          absoluteEndMs: absoluteEndMs,
        );
        timeline = [...timeline, node]
          ..sort((a, b) => a.startMs.compareTo(b.startMs));
        _liveRealtimeNodes = [..._liveRealtimeNodes, node];
        _queueAutomaticMicProSync(node);
      }
      final mappedEvents = visualEvents.map((event) {
        final relativeStart = (event.startMs - startMs).clamp(
          0,
          endMs - startMs,
        );
        final relativeEnd = (event.endMs - startMs).clamp(
          relativeStart,
          endMs - startMs,
        );
        return event.copyWith(
          sourceRef: liveSourcePath ?? 'GO Ultra live stream',
          absoluteStartMs: absoluteStartMs == null
              ? null
              : absoluteStartMs + relativeStart,
          absoluteEndMs: absoluteStartMs == null
              ? null
              : absoluteStartMs + relativeEnd,
        );
      }).toList();
      videoEvents = [...videoEvents, ...mappedEvents];
      _liveRealtimeEvents = [..._liveRealtimeEvents, ...mappedEvents];
      highlights = _highlightsFromNodes(
        timeline,
        events: videoEvents,
        sourceDurationMs: mediaInfo?.durationMs,
      );
      if (liveSourcePath != null &&
          liveSourcePath.isNotEmpty &&
          mediaInfo?.hasVideo == true &&
          highlights.isNotEmpty) {
        await _exportHighlightClips(liveSourcePath);
      }
      if (timeline.isNotEmpty) selectedNodeIndex = timeline.length - 1;
      await _storeHistorySnapshot(
        id: _liveHistoryId ?? 'live-${DateTime.now().millisecondsSinceEpoch}',
        sourceName:
            connectedDeviceName ?? text('GO Ultra 实时流', 'GO Ultra live stream'),
        sourcePath: liveSourcePath,
        nodes: _liveRealtimeNodes,
        events: _liveRealtimeEvents,
      );
      realtimeStatus = text(
        '已记录明显变化：${mood?.mood ?? ''}${mappedEvents.isEmpty ? '' : ' · ${mappedEvents.length} 个事件'}',
        'Significant change recorded: ${mood?.mood ?? ''}${mappedEvents.isEmpty ? '' : ' · ${mappedEvents.length} event(s)'}',
      );
      if (mood != null) {
        realtimeMood = mood.mood;
        realtimeWeather = mood.kind;
      }
    } catch (error) {
      realtimeStatus = text(
        '实时情绪分析失败：$error',
        'Realtime mood analysis failed: $error',
      );
      lastError = error.toString();
    }
    notifyListeners();
  }

  void _markDeviceConnected(DeviceRecord value) {
    devices = devices
        .map(
          (item) =>
              item.copyWith(isConnected: item.id == value.id ? true : false),
        )
        .toList();
    if (!devices.any((item) => item.id == value.id)) {
      devices = [...devices, value];
    }
    connectedDeviceName = value.name;
    _lastDeviceName = value.name;
    unawaited(_persistLastDevice());
  }

  /// Remembers which camera was used so the next scan can surface it first.
  Future<void> _persistLastDevice() async {
    final name = _lastDeviceName;
    if (name == null || name.isEmpty) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('lastDeviceName', name);
    } on MissingPluginException {
      // Widget tests keep the in-memory value only.
    }
  }

  /// Connects the remembered camera automatically once it appears in a scan.
  Future<void> connectRememberedDevice() async {
    final name = _lastDeviceName;
    if (name == null || name.isEmpty || connectionStage.isBusy) return;
    final matches = devices.where((item) => item.name == name).toList();
    if (matches.isEmpty) return;
    await toggleDevice(matches.first);
  }

  void _markDeviceConnectedByEvent(String? id, String? name) {
    if (id == null || id.isEmpty) return;
    devices = devices
        .map((item) => item.copyWith(isConnected: item.id == id))
        .toList();
    if (!devices.any((item) => item.id == id)) {
      devices = [
        ...devices,
        DeviceRecord(
          id: id,
          name: name ?? 'GO Ultra',
          model: 'GO Ultra',
          connection: 'Wi‑Fi',
          isConnected: true,
        ),
      ];
    }
    connectedDeviceName = name ?? connectedDeviceName;
  }

  void _markConnectionFailed(String detail) {
    unawaited(_stopRealtimeAnalysis());
    _stopAutoSync();
    devices = devices.map((item) => item.copyWith(isConnected: false)).toList();
    connectionStage = DeviceConnectionStage.failed;
    connectionStatus = text('连接失败，请重试', 'Connection failed; try again');
    final normalized = detail.toLowerCase();
    lastError =
        normalized.contains('wake up authorization') ||
            normalized.contains('authorization failed')
        ? text(
            '请在 GO Ultra 的 Action Pod 上点击确认或按快门完成授权，然后重试。',
            'Confirm on the GO Ultra Action Pod or press the shutter to authorize, then retry.',
          )
        : detail;
    previewReady = false;
    connectedDeviceName = null;
  }

  void _startAutoSync() {
    if (!autoSyncEnabled || autoSyncTimer != null) return;
    unawaited(syncLatestMedia(automatic: true));
    autoSyncTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      unawaited(syncLatestMedia(automatic: true));
    });
  }

  void _stopAutoSync() {
    autoSyncTimer?.cancel();
    autoSyncTimer = null;
  }

  static num _number(dynamic value) =>
      value is num ? value : num.tryParse('$value') ?? 0;

  void removeDevice(DeviceRecord device) {
    devices = devices.where((item) => item.id != device.id).toList();
    notifyListeners();
  }

  // region Mic Pro (independent e-ink channel)

  /// Discovered e-ink transmitters. This list is maintained separately from the
  /// camera list because the Mic Pro is an independent Bluetooth accessory, not a
  /// camera, and must be reachable even when no GO Ultra is around.
  List<Map<String, dynamic>> micProDevices = <Map<String, dynamic>>[];
  bool micProScanning = false;
  String micProStatus = '没找到墨水屏';
  String? micProConnectedAddress;

  /// Scans for the transmitter without touching the camera stack.
  Future<void> scanMicProDevices() async {
    micProScanning = true;
    micProStatus = text('正在扫描 Mic Pro…', 'Scanning for the Mic Pro…');
    notifyListeners();
    try {
      final devices = await native.scanMicPro();
      micProDevices = devices;
      micProStatus = devices.isEmpty
          ? text(
              '没找到 Mic Pro，请确认已开机',
              'No Mic Pro found; make sure it is powered on',
            )
          : text(
              '发现 ${devices.length} 台墨水屏设备',
              '${devices.length} e-ink device(s) found',
            );
    } catch (error) {
      micProStatus = text('扫描失败：$error', 'Scan failed: $error');
    } finally {
      micProScanning = false;
      notifyListeners();
    }
  }

  /// Connects to the transmitter and reports whether the e-ink service is present.
  Future<bool> connectMicProDevice(String address) async {
    micProStatus = text('正在连接墨水屏…', 'Connecting to the display…');
    notifyListeners();
    try {
      final info = await native.connectMicPro(address);
      final hasTrc = info?['hasTrcService'] == true;
      if (hasTrc) {
        micProConnectedAddress = address;
        micProDeviceAddress = address;
        micProStatus = text(
          '墨水屏已就绪，可随时换壁纸',
          'Display ready; ready to set a wallpaper',
        );
      } else {
        micProStatus = text(
          '已连接，但未找到墨水屏服务',
          'Connected, but the e-ink service was not found',
        );
      }
      notifyListeners();
      return hasTrc;
    } catch (error) {
      micProStatus = text('连接失败：$error', 'Connection failed: $error');
      notifyListeners();
      return false;
    }
  }

  /// Sweeps candidate protocol frames so the display's real replies can be read.
  Future<void> probeMicProProtocol() async {
    final address = micProConnectedAddress;
    if (address == null || address.isEmpty) {
      micProStatus = text(
        '请先扫描并连接 Mic Pro',
        'Scan and connect the Mic Pro first',
      );
      notifyListeners();
      return;
    }
    micProStatus = text('正在探测协议…', 'Probing the protocol…');
    notifyListeners();
    try {
      final report = await native.probeMicPro(address);
      final replies = report['replies'];
      final count = report['replyCount'] ?? 0;
      micProStatus = text(
        '探测完成：收到 $count 条响应',
        'Probe done: $count reply(ies)',
      );
      if (replies is List && replies.isNotEmpty) {
        lastMicProProbe = replies.take(6).map((e) => e.toString()).join(' | ');
      }
    } catch (error) {
      micProStatus = text('探测失败：$error', 'Probe failed: $error');
    }
    notifyListeners();
  }

  /// Raw hex of the most recent protocol replies, kept for on-screen inspection.
  String? lastMicProProbe;

  // endregion

  /// Sends the current mood to the Mic Pro.
  /// Automatic updates must stay silent and BLE-only; manual updates can still
  /// offer the official app import fallback when direct command ids are unknown.
  Future<void> syncToMicPro(WeatherNode node, {bool automatic = false}) async {
    syncMessage = text(
      '正在生成 240×208 状态卡…',
      'Generating a 240×208 status card…',
    );
    notifyListeners();
    try {
      final cardPath = await micPro.buildWallpaper(node: node, dark: darkMode);
      lastWallpaperPath = cardPath;
      if (automatic &&
          (micProConnectedAddress == null || micProConnectedAddress!.isEmpty)) {
        syncMessage = text(
          '情绪已记录；MicPro 当前未连接',
          'Mood recorded; MicPro is not connected',
        );
        notifyListeners();
        return;
      }
      if (automatic && micProCommandCodes.isEmpty) {
        syncMessage = text(
          '状态卡已生成；等待 MicPro 协议命令码',
          'Status card generated; MicPro command ids are not configured yet',
        );
        notifyListeners();
        return;
      }
      // Prepare the on-device payloads the transmitter expects.
      final payloads = await micPro.preparePayloads(
        cardPath: cardPath,
        cacheKey: '${node.kind.name}_${node.startMs}',
      );
      final bitmapPath = payloads['bitmapPath']?.toString();
      final metaPath = payloads['metaPath']?.toString();
      // Keep the address selected by the BLE connection as the single source of
      // truth. The old secondary field was never populated, so every direct push
      // was attempted without an address and immediately fell back to sharing.
      micProDeviceAddress ??= micProConnectedAddress;
      final pushed = await micPro.pushToDevice(
        bitmapPath: bitmapPath ?? '',
        metaPath: metaPath ?? '',
        codes: micProCommandCodes,
        address: micProConnectedAddress ?? micProDeviceAddress,
      );
      if (pushed) {
        syncMessage = text('已推送到 Mic Pro 墨水屏', 'Pushed to the Mic Pro display');
        notifyListeners();
        return;
      }
      if (automatic) {
        syncMessage = text(
          '状态卡已生成，但 MicPro 蓝牙推送失败',
          'Status card generated, but the MicPro BLE push failed',
        );
        notifyListeners();
        return;
      }
      await micPro.shareToOfficialPath(cardPath);
      syncMessage = text(
        '已生成 ${node.kind.chineseName} 状态卡，可在 Insta360 App 中确认导入',
        '${node.kind.englishName} card ready; confirm import in the Insta360 app',
      );
    } catch (error) {
      syncMessage = text(
        '状态卡生成失败：$error',
        'Wallpaper generation failed: $error',
      );
    }
    notifyListeners();
  }

  /// Numeric TRC command ids recovered from the accessory protocol trace.
  ///
  /// The frame uses 16-bit little-endian command ids. Keeping the names
  /// identical to the native sender makes a failed protocol step actionable.
  Map<String, int> micProCommandCodes = <String, int>{
    'TRC_APP_CMD_GET_AUTHORIZE': 3,
    'TRC_APP_CMD_NOTIFY_AUTHORIZE': 4,
    'TRC_APP_CMD_READY_WALLPAPER': 33,
    'TRC_APP_CMD_GET_WALLPAPER': 34,
    'APP_CMD_WRITE_FILE_BEGIN': 40,
    'APP_CMD_WRITE_FILE_DATA': 41,
    'APP_CMD_WRITE_FILE_END': 42,
    'APP_CMD_WRITE_FILE_CANCEL': 43,
  };

  /// Bluetooth address of the transmitter once discovered.
  String? micProDeviceAddress;

  Future<void> openDeveloper() async {
    final uri = Uri.parse('https://www.23j1633.xyz');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class RootShell extends StatelessWidget {
  const RootShell({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (controller.settingsOpen) return SettingsPage(controller: controller);
    final page = switch (controller.selectedTab) {
      0 => HomePage(controller: controller),
      1 => DevicesPage(controller: controller),
      _ => ProfilePage(controller: controller),
    };
    final tabs = <({IconData icon, IconData selectedIcon, String label})>[
      (
        icon: material.Icons.cloud_outlined,
        selectedIcon: material.Icons.cloud,
        label: controller.text('天气', 'Weather'),
      ),
      (
        icon: material.Icons.videocam_outlined,
        selectedIcon: material.Icons.videocam,
        label: controller.text('设备', 'Devices'),
      ),
      (
        icon: material.Icons.person_outline_rounded,
        selectedIcon: material.Icons.person_rounded,
        label: controller.text('我的', 'Profile'),
      ),
    ];
    return Scaffold(
      footers: [
        Container(
          decoration: BoxDecoration(
            color: colors.background,
            border: Border(
              top: BorderSide(color: colors.border.withValues(alpha: 0.6)),
            ),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 64,
              child: Row(
                children: [
                  for (var index = 0; index < tabs.length; index++)
                    Expanded(
                      child: _NavTab(
                        icon: tabs[index].icon,
                        selectedIcon: tabs[index].selectedIcon,
                        label: tabs[index].label,
                        selected: controller.selectedTab == index,
                        onTap: () => controller.selectTab(index),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
      child: SafeArea(child: page),
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final activeColor = brandBlue;
    final inactiveColor = colors.mutedForeground;
    return material.InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
              decoration: BoxDecoration(
                color: selected
                    ? activeColor.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                selected ? selectedIcon : icon,
                size: 21,
                color: selected ? activeColor : inactiveColor,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                height: 1.1,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? activeColor : inactiveColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
