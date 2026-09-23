import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models.dart';
import 'native_bridge.dart';

class TranscriptSegment {
  const TranscriptSegment({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.emotion,
  });

  final int startMs;
  final int endMs;
  final String text;
  final String? emotion;
}

class MoodResult {
  const MoodResult({
    required this.kind,
    required this.mood,
    required this.confidence,
    required this.evidence,
    required this.intensity,
  });

  final WeatherKind kind;
  final String mood;
  final double confidence;
  final List<String> evidence;
  final int intensity;
}

class VideoAnalysisResult {
  const VideoAnalysisResult({required this.summary, required this.events});

  final String summary;
  final List<VideoEvent> events;
}

/// Routes Qwen HTTP calls through the Android side when the process is bound to
/// the camera Wi-Fi, so cloud analysis keeps using mobile data while media
/// transfer continues over the GO Ultra hotspot. Falls back to the package
/// client when the native bridge is unavailable (tests, desktop, web).
class AiHttpClient extends http.BaseClient {
  AiHttpClient({http.Client? fallback, NativeCameraBridge? bridge})
    : _fallback = fallback ?? http.Client(),
      _bridge = bridge;

  final http.Client _fallback;
  final NativeCameraBridge? _bridge;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bridge = _bridge;
    // Only plain requests are tunnelled; streaming bodies keep the default path
    // because finalizing them early would break the fallback call.
    if (bridge == null || request is! http.Request) {
      return _fallback.send(request);
    }
    final body = request.body;
    try {
      final payload = await bridge.aiHttpPost(
        url: request.url,
        headers: Map<String, String>.from(request.headers),
        body: body,
      );
      if (payload == null) return _fallback.send(request);
      final statusCode = _intValue(payload['statusCode']) ?? 500;
      final responseBody = payload['body']?.toString() ?? '';
      final bytes = utf8.encode(responseBody);
      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        statusCode,
        contentLength: bytes.length,
        request: request,
        headers: const {'content-type': 'application/json'},
      );
    } on PlatformException catch (error) {
      if (error.code == 'AI_NO_INTERNET') rethrow;
      return _fallback.send(request);
    } catch (_) {
      return _fallback.send(request);
    }
  }

  @override
  void close() {
    _fallback.close();
    super.close();
  }

  static int? _intValue(dynamic value) =>
      value is num ? value.round() : int.tryParse('$value');
}

class QwenService {
  /// Fragments shorter than this are camera handling noise, not real events.
  static const _minEventDurationMs = 10 * 1000;

  /// Upper bound on moments reported for a single 3-minute window.
  static const _maxEventsPerWindow = 2;

  QwenService({http.Client? client})
    : _client = client ?? AiHttpClient(bridge: NativeCameraBridge());

  static const workspaceConfigId = '7379080';
  // The workspace-scoped endpoint returns 403 for this key, so the verified
  // shared Beijing endpoints are used for every request, including realtime ASR.
  // The workspace header is still sent because the shared endpoint accepts it.
  static const workspaceId = 'ws-tjdprzo19lrbrhsy';
  static const apiHost = 'dashscope.aliyuncs.com';
  static const realtimeAsrEndpoint =
      'wss://dashscope.aliyuncs.com/api-ws/v1/inference';
  static const baseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
  static const dashScopeBaseUrl = 'https://dashscope.aliyuncs.com/api/v1';
  // The shared endpoint supports Base64 input for the synchronous ASR model.
  static const asrModel = 'qwen3-asr-flash';
  static const realtimeAsrModel = 'qwen-audio-3.0-asr-flash-streaming';
  static const moodModel = 'qwen3.8-max';
  static const videoModel = 'qwen3.8-omni-flash';

  // The key is intentionally injected at build time and never committed.
  static const apiKey = String.fromEnvironment('DASHSCOPE_API_KEY');

  final http.Client _client;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
  };

  Future<TranscriptSegment?> transcribeAudio({
    required File audioFile,
    required int sourceStartMs,
    required int sourceEndMs,
  }) async {
    if (!isConfigured || !await audioFile.exists()) return null;
    final bytes = await audioFile.readAsBytes();
    if (bytes.isEmpty) return null;

    final audioData = 'data:audio/mp4;base64,${base64Encode(bytes)}';
    final response = await _client
        .post(
          Uri.parse('$baseUrl/chat/completions'),
          headers: _headers,
          body: jsonEncode({
            'model': asrModel,
            'messages': [
              {
                'role': 'user',
                'content': [
                  {
                    'type': 'input_audio',
                    'input_audio': {'data': audioData},
                  },
                ],
              },
            ],
            'stream': false,
            'asr_options': {'enable_itn': false},
          }),
        )
        .timeout(const Duration(seconds: 90));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'ASR ${response.statusCode}: ${response.body}',
        uri: response.request?.url,
      );
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final output = _asMap(payload['output']);
    final nestedOutput = _asMap(output?['output']);
    final sentence =
        _asMap(output?['sentence']) ??
        _asMap(nestedOutput?['sentence']) ??
        _firstMap(output?['sentences']);
    final choices = (payload['choices'] ?? output?['choices']) as List?;
    final choice = choices != null && choices.isNotEmpty
        ? _asMap(choices.first)
        : null;
    final message = _asMap(choice?['message']);
    final outputText = output?['text']?.toString() ?? '';
    final sentenceText = sentence?['text']?.toString() ?? '';
    final content = outputText.trim().isNotEmpty
        ? outputText
        : sentenceText.trim().isNotEmpty
        ? sentenceText
        : _contentToText(message?['content']);
    if (content.isEmpty) return null;

    final annotationList = message?['annotations'] as List?;
    final annotation = annotationList != null && annotationList.isNotEmpty
        ? annotationList.first
        : null;
    final annotationMap = _asMap(annotation);
    final relativeStart = _intValue(
      sentence?['begin_time'] ?? annotationMap?['begin_time'],
    );
    final relativeEnd = _intValue(
      sentence?['end_time'] ?? annotationMap?['end_time'],
    );
    return TranscriptSegment(
      startMs: sourceStartMs + (relativeStart ?? 0),
      endMs: sourceStartMs + (relativeEnd ?? (sourceEndMs - sourceStartMs)),
      text: content.trim(),
      emotion:
          sentence?['emotion']?.toString() ??
          annotationMap?['emotion']?.toString(),
    );
  }

  Future<String> testConnection() async {
    if (!isConfigured) {
      throw StateError('DASHSCOPE_API_KEY is not configured');
    }
    final response = await _client
        .post(
          Uri.parse('$baseUrl/chat/completions'),
          headers: _headers,
          body: jsonEncode({
            'model': moodModel,
            'messages': [
              {'role': 'user', 'content': '只回复 OK'},
            ],
            'temperature': 0,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Qwen ${response.statusCode}: ${response.body}',
        uri: response.request?.url,
      );
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = payload['choices'] as List?;
    final choice = choices != null && choices.isNotEmpty
        ? _asMap(choices.first)
        : null;
    final message = _asMap(choice?['message']);
    final content = _contentToText(message?['content']).trim();
    if (content.isEmpty) throw StateError('Qwen returned an empty response');
    return content;
  }

  Future<MoodResult?> analyzeMood({
    required String transcript,
    required List<String> localSignals,
  }) async {
    if (!isConfigured || transcript.trim().isEmpty) return null;
    final prompt =
        '''
你是 dayweather 的影像氛围分析器。你只能判断当前影像片段的“氛围趋势”，不能做心理、医疗或人格诊断。
请基于下面的转写和音视频线索，严格返回 JSON，不要 Markdown：
{"weather":"sunny|cloudy|rain|storm|rainbow","mood":"一句不超过8字的氛围词","confidence":0.0,"intensity":0,"evidence":["最多3条可核验依据"]}
转写：$transcript
线索：${localSignals.join('、')}
''';
    final response = await _client
        .post(
          Uri.parse('$baseUrl/chat/completions'),
          headers: _headers,
          body: jsonEncode({
            'model': moodModel,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
            'temperature': 0.2,
          }),
        )
        .timeout(const Duration(seconds: 90));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Mood ${response.statusCode}: ${response.body}',
        uri: response.request?.url,
      );
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = payload['choices'] as List?;
    final message =
        (choices != null && choices.isNotEmpty ? choices.first : null)
            as Map<String, dynamic>?;
    final messageBody = message?['message'] as Map<String, dynamic>?;
    final content = _contentToText(messageBody?['content']);
    if (content.isEmpty) return null;
    final jsonText = _extractJson(content);
    if (jsonText == null) return null;
    final value = jsonDecode(jsonText) as Map<String, dynamic>;
    return MoodResult(
      kind: _weatherFrom(value['weather']?.toString()),
      mood: value['mood']?.toString() ?? '氛围变化',
      confidence: (_doubleValue(value['confidence']) ?? 0.6).clamp(0, 1),
      evidence: ((value['evidence'] as List?) ?? const [])
          .map((item) => item.toString())
          .take(3)
          .toList(),
      intensity: (_intValue(value['intensity']) ?? 50).clamp(0, 100),
    );
  }

  Future<String?> understandVideo(File videoFile) async {
    if (!isConfigured || !await videoFile.exists()) return null;
    final bytes = await videoFile.readAsBytes();
    if (bytes.isEmpty || bytes.length > 12 * 1024 * 1024) return null;
    final videoData = 'data:;base64,${base64Encode(bytes)}';
    final response = await _client
        .post(
          Uri.parse('$baseUrl/chat/completions'),
          headers: _headers,
          body: jsonEncode({
            'model': videoModel,
            'messages': [
              {
                'role': 'user',
                'content': [
                  {
                    'type': 'video_url',
                    'video_url': {'url': videoData},
                  },
                  {
                    'type': 'text',
                    'text': '请用不超过80字描述这段 GO Ultra 片段的场景、镜头变化和可核验的氛围线索。',
                  },
                ],
              },
            ],
            'modalities': ['text'],
          }),
        )
        .timeout(const Duration(seconds: 120));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Video ${response.statusCode}: ${response.body}',
        uri: response.request?.url,
      );
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = payload['choices'] as List?;
    final message =
        (choices != null && choices.isNotEmpty ? choices.first : null)
            as Map<String, dynamic>?;
    final messageBody = message?['message'] as Map<String, dynamic>?;
    return _contentToText(messageBody?['content']).trim().ifEmpty;
  }

  Future<VideoAnalysisResult?> understandVideoFrames({
    required List<VideoFrameSample> frames,
    required int sourceStartMs,
    required int sourceEndMs,
  }) async {
    if (!isConfigured || frames.isEmpty) return null;
    final content = <Map<String, dynamic>>[
      {
        'type': 'text',
        'text':
            '''
你是 dayweather 的影像日志整理器。下面是一段约 3 分钟真实影像按时间戳抽取的关键帧。
你的任务是提炼「这段影像里值得日后回看的时刻」，而不是逐帧描述画面。

判断标准（务必严格遵守）：
- 只记录有实质内容的时刻：一次完整活动、一段对话或发言、一个场景的切换、一次明显的氛围变化、值得回看的动作或成果。
- 忽略镜头微调、手持抖动、角度变化、对焦变化、同一画面的持续展示、屏幕文字轻微变化、人物走过等无实质意义的细节。
- 若整段影像只是持续拍同一个场景而没有发生实质事件，events 必须返回空数组 []，不要为凑数编造事件。
- 每个窗口最多 2 个事件；宁少勿多。事件至少持续 10 秒，不要输出只有几秒的碎片。
- 只描述画面中可核验的内容，不猜测人物身份、隐私或画外信息。

严格返回 JSON，不要 Markdown：
{"summary":"不超过60字，概括这3分钟整体在做什么、氛围如何","events":[{"start_ms":0,"end_ms":30000,"title":"不超过12字的事件标题","description":"不超过40字，说明发生了什么、为什么值得回看","confidence":0.0}]}
片段范围：${sourceStartMs}ms-${sourceEndMs}ms
关键帧相对时间：${frames.map((frame) => '${frame.timestampMs - sourceStartMs}ms').join('、')}
''',
      },
      for (final frame in frames.take(8))
        {
          'type': 'image_url',
          'image_url': {
            'url': 'data:image/jpeg;base64,${base64Encode(frame.data)}',
          },
        },
    ];
    final response = await _client
        .post(
          Uri.parse('$baseUrl/chat/completions'),
          headers: _headers,
          body: jsonEncode({
            'model': videoModel,
            'messages': [
              {'role': 'user', 'content': content},
            ],
            'modalities': ['text'],
            'temperature': 0.1,
          }),
        )
        .timeout(const Duration(seconds: 120));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Video ${response.statusCode}: ${response.body}',
        uri: response.request?.url,
      );
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = payload['choices'] as List?;
    final message =
        (choices != null && choices.isNotEmpty ? choices.first : null)
            as Map<String, dynamic>?;
    final messageBody = message?['message'] as Map<String, dynamic>?;
    final text = _contentToText(messageBody?['content']).trim();
    if (text.isEmpty) return null;
    final jsonText = _extractJson(text);
    if (jsonText == null) {
      return VideoAnalysisResult(summary: text, events: const []);
    }
    final value = jsonDecode(jsonText) as Map<String, dynamic>;
    final rawEvents = value['events'] as List? ?? const [];
    final events = <VideoEvent>[];
    for (final rawEvent in rawEvents) {
      final event = _asMap(rawEvent);
      if (event == null) continue;
      final relativeStart =
          _intValue(event['start_ms'] ?? event['startMs'] ?? event['start']) ??
          0;
      final relativeEnd =
          _intValue(event['end_ms'] ?? event['endMs'] ?? event['end']) ??
          relativeStart + 1000;
      final title = event['title']?.toString().trim() ?? '';
      final description = event['description']?.toString().trim() ?? '';
      if (title.isEmpty && description.isEmpty) continue;
      final startMs = (sourceStartMs + relativeStart).clamp(
        sourceStartMs,
        sourceEndMs,
      );
      final endMs =
          (sourceStartMs + math.max(relativeStart, relativeEnd).round()).clamp(
            sourceStartMs,
            sourceEndMs,
          );
      // Guard against camera nudges and other fragments: anything shorter than
      // the minimum duration is noise, not a moment worth revisiting.
      if (endMs - startMs < _minEventDurationMs) continue;
      events.add(
        VideoEvent(
          startMs: startMs,
          endMs: endMs,
          title: title.isEmpty ? '画面事件' : title,
          description: description,
          confidence: (_doubleValue(event['confidence']) ?? 0.6).clamp(0, 1),
        ),
      );
    }
    // Keep only the most substantial moments per window instead of dumping every
    // scene the model noticed.
    events.sort(
      (left, right) =>
          (right.endMs - right.startMs).compareTo(left.endMs - left.startMs),
    );
    final kept = events.take(_maxEventsPerWindow).toList()
      ..sort((left, right) => left.startMs.compareTo(right.startMs));
    return VideoAnalysisResult(
      summary: value['summary']?.toString().trim().ifEmpty ?? text,
      events: kept,
    );
  }

  void dispose() => _client.close();

  static String _contentToText(dynamic value) {
    if (value is String) return value;
    if (value is List) {
      return value.map((item) {
        if (item is String) return item;
        if (item is Map) return item['text']?.toString() ?? '';
        return '';
      }).join();
    }
    return '';
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static Map<String, dynamic>? _firstMap(dynamic value) {
    if (value is! List) return null;
    for (final item in value) {
      final map = _asMap(item);
      if (map != null) return map;
    }
    return null;
  }

  static String? _extractJson(String value) {
    final start = value.indexOf('{');
    final end = value.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    return value.substring(start, end + 1);
  }

  static int? _intValue(dynamic value) =>
      value is num ? value.round() : int.tryParse('$value');

  static double? _doubleValue(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('$value');

  static WeatherKind _weatherFrom(String? value) {
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
}

extension _NullableStringX on String {
  String? get ifEmpty => isEmpty ? null : this;
}

class RealtimeTranscript {
  const RealtimeTranscript({
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.isFinal,
    required this.sentenceId,
    this.absoluteStartMs,
    this.absoluteEndMs,
  });

  final int startMs;
  final int endMs;
  final String text;
  final bool isFinal;
  final int sentenceId;
  final int? absoluteStartMs;
  final int? absoluteEndMs;
}

class QwenRealtimeAsr {
  QwenRealtimeAsr({
    required this.apiKey,
    required this.workspaceId,
    this.model = QwenService.realtimeAsrModel,
    this.audioFormat = 'aac',
    // GO Ultra preview audio is 16 kHz AAC; declaring 48 kHz made the service
    // reject every window with 'DecodePost resample audio from 48000 to 16000'.
    this.sampleRate = 16000,
  });

  final String apiKey;
  final String workspaceId;
  final String model;
  final String audioFormat;
  final int sampleRate;
  final StreamController<RealtimeTranscript> _results =
      StreamController<RealtimeTranscript>.broadcast();
  final List<_PendingAudio> _pendingAudio = <_PendingAudio>[];

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  StreamSubscription<Map<String, dynamic>>? _aiEventSubscription;
  NativeCameraBridge? _bridge;
  bool _tunnelMode = false;
  String? _taskId;
  int? _baseCameraTimestampMs;
  int? _wallClockStartMs;
  bool _taskStarted = false;
  bool _finishSent = false;
  bool _closing = false;
  bool _reportedError = false;
  int _lastFinalSentenceId = 0;

  Stream<RealtimeTranscript> get results => _results.stream;

  Future<void> start() async {
    if (_socket != null) return;
    if (apiKey.trim().isEmpty) {
      throw StateError('DASHSCOPE_API_KEY is not configured');
    }
    final uri = Uri.parse(QwenService.realtimeAsrEndpoint);
    final taskId = _uuid();
    _taskId = taskId;
    final runTask = jsonEncode({
      'header': {
        'action': 'run-task',
        'task_id': taskId,
        'streaming': 'duplex',
      },
      'payload': {
        'task_group': 'audio',
        'task': 'asr',
        'function': 'recognition',
        'model': model,
        'parameters': {
          'format': audioFormat,
          'sample_rate': sampleRate,
          'language_hints': ['zh', 'en'],
          'semantic_punctuation_enabled': false,
          'max_sentence_silence': 1000,
          'heartbeat': true,
        },
        'input': <String, dynamic>{},
      },
    });

    // Prefer the Android tunnel so realtime ASR keeps running on mobile data
    // while the process stays bound to the camera Wi-Fi for media transfer.
    final bridge = _bridge ?? NativeCameraBridge();
    if (Platform.isAndroid) {
      try {
        final opened = Completer<void>();
        _aiEventSubscription = bridge.aiEvents.listen(
          (event) {
            switch (event['stage']) {
              case 'ai_ws_open':
                if (!opened.isCompleted) opened.complete();
              case 'ai_ws_message':
                final text = event['text'];
                if (text is String) _handleMessage(text);
              case 'ai_ws_failed':
                final detail = event['detail']?.toString();
                if (!opened.isCompleted) {
                  opened.completeError(
                    StateError(detail ?? 'AI WebSocket failed'),
                  );
                } else {
                  _reportError(StateError(detail ?? 'AI WebSocket failed'));
                }
              case 'ai_ws_closed':
                if (!_closing) _handleSocketDone();
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!opened.isCompleted) {
              opened.completeError(error);
            } else {
              _reportError(error, stack);
            }
          },
        );
        await bridge.aiWebSocketOpen(
          url: uri,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'X-DashScope-WorkSpace': workspaceId,
            'user-agent': 'dayweather/1.0',
          },
        );
        await opened.future.timeout(const Duration(seconds: 20));
        _bridge = bridge;
        _tunnelMode = true;
        await bridge.aiWebSocketSend(text: runTask);
        return;
      } catch (_) {
        // Fall back to a direct socket when the tunnel is unavailable.
        await _aiEventSubscription?.cancel();
        _aiEventSubscription = null;
        await bridge.aiWebSocketClose();
        _bridge = null;
      }
    }

    final socket = await WebSocket.connect(
      uri.toString(),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'X-DashScope-WorkSpace': workspaceId,
        'user-agent': 'dayweather/1.0',
      },
    ).timeout(const Duration(seconds: 20));
    _socket = socket;
    _socketSubscription = socket.listen(
      _handleMessage,
      onError: _handleSocketError,
      onDone: _handleSocketDone,
      cancelOnError: false,
    );
    socket.add(runTask);
  }

  void addAudio(Uint8List data, {required int timestampMs}) {
    if (data.isEmpty || _closing) return;
    _baseCameraTimestampMs ??= timestampMs;
    _wallClockStartMs ??= DateTime.now().millisecondsSinceEpoch;
    if (!_taskStarted) {
      if (_pendingAudio.length >= 64) _pendingAudio.removeAt(0);
      _pendingAudio.add(_PendingAudio(data, timestampMs));
      return;
    }
    _sendAudio(data);
  }

  Future<void> stop() async {
    if (_closing) return;
    _closing = true;
    final finishTask = jsonEncode({
      'header': {
        'action': 'finish-task',
        'task_id': _taskId,
        'streaming': 'duplex',
      },
      'payload': {'input': <String, dynamic>{}},
    });
    final socket = _socket;
    if (_tunnelMode) {
      final bridge = _bridge;
      if (bridge != null && _taskStarted && !_finishSent) {
        _finishSent = true;
        await bridge.aiWebSocketSend(text: finishTask);
      }
      await _aiEventSubscription?.cancel();
      _aiEventSubscription = null;
      await bridge?.aiWebSocketClose();
      _bridge = null;
      _tunnelMode = false;
    } else {
      if (socket != null && _taskStarted && !_finishSent) {
        _finishSent = true;
        socket.add(finishTask);
      }
      await _socketSubscription?.cancel();
      _socketSubscription = null;
      await socket?.close();
    }
    _socket = null;
    if (!_results.isClosed) await _results.close();
  }

  void _handleMessage(dynamic message) {
    if (message is! String) return;
    final decoded = jsonDecode(message);
    if (decoded is! Map) return;
    final header = _map(decoded['header']);
    final event = header?['event']?.toString();
    switch (event) {
      case 'task-started':
        _taskStarted = true;
        _flushPendingAudio();
      case 'result-generated':
        _handleResult(_map(decoded['payload']));
      case 'task-failed':
        final code = header?['error_code']?.toString() ?? 'UNKNOWN';
        final message =
            header?['error_message']?.toString() ?? 'ASR task failed';
        _reportError(StateError('Realtime ASR $code: $message'));
      case 'task-finished':
        _closing = true;
        if (!_tunnelMode) _socket?.close();
    }
  }

  void _handleResult(Map<String, dynamic>? payload) {
    final output = _map(payload?['output']);
    final sentence = _map(output?['sentence']);
    if (sentence == null || sentence['heartbeat'] == true) return;
    final text = sentence['text']?.toString().trim() ?? '';
    if (text.isEmpty) return;
    final sentenceId = _intValue(sentence['sentence_id']) ?? 0;
    final isFinal = sentence['sentence_end'] == true;
    if (isFinal && sentenceId > 0 && sentenceId <= _lastFinalSentenceId) return;
    if (isFinal && sentenceId > 0) _lastFinalSentenceId = sentenceId;
    final relativeStart = _intValue(sentence['begin_time']) ?? 0;
    final relativeEnd =
        _intValue(sentence['end_time']) ?? (relativeStart + 600);
    final base = _baseCameraTimestampMs ?? 0;
    final cameraStart = base + relativeStart;
    final cameraEnd = base + math.max(relativeStart, relativeEnd).round();
    final cameraTimestampIsAbsolute = cameraStart >= 946684800000;
    final wallClockBase = _wallClockStartMs;
    final absoluteStartMs = cameraTimestampIsAbsolute
        ? cameraStart
        : wallClockBase == null
        ? null
        : wallClockBase + relativeStart;
    final absoluteEndMs = cameraTimestampIsAbsolute
        ? cameraEnd
        : wallClockBase == null
        ? null
        : wallClockBase + math.max(relativeStart, relativeEnd).round();
    _results.add(
      RealtimeTranscript(
        startMs: cameraStart,
        endMs: cameraEnd,
        text: text,
        isFinal: isFinal,
        sentenceId: sentenceId,
        absoluteStartMs: absoluteStartMs,
        absoluteEndMs: absoluteEndMs,
      ),
    );
  }

  void _flushPendingAudio() {
    if (!_taskStarted) return;
    final queued = List<_PendingAudio>.from(_pendingAudio);
    _pendingAudio.clear();
    for (final item in queued) {
      _sendAudio(item.data);
    }
  }

  void _sendAudio(Uint8List data) {
    try {
      if (_tunnelMode) {
        final bridge = _bridge;
        if (bridge != null) unawaited(bridge.aiWebSocketSend(data: data));
      } else {
        _socket?.add(data);
      }
    } catch (error) {
      _reportError(error);
    }
  }

  void _handleSocketError(Object error, StackTrace stackTrace) {
    _reportError(error, stackTrace);
  }

  void _handleSocketDone() {
    if (!_closing) {
      _reportError(StateError('Realtime ASR WebSocket closed unexpectedly'));
    }
  }

  void _reportError(Object error, [StackTrace? stackTrace]) {
    if (_reportedError || _closing) return;
    _reportedError = true;
    _results.addError(error, stackTrace);
  }

  static Map<String, dynamic>? _map(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static int? _intValue(dynamic value) =>
      value is num ? value.round() : int.tryParse('$value');

  static String _uuid() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

class _PendingAudio {
  const _PendingAudio(this.data, this.timestampMs);

  final Uint8List data;
  final int timestampMs;
}
