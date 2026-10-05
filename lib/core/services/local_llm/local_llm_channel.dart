import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Client for the transplanted llama.cpp JNI binding, exposed to Dart over the
/// `app.llm` MethodChannel. Only Android is supported; other platforms throw
/// [LocalLlmUnsupportedException] so the caller can degrade gracefully.
class LocalLlmChannel {
  LocalLlmChannel({MethodChannel? methodChannel})
      : _methods = methodChannel ??
            const MethodChannel('app.llm', StandardMethodCodec());

  final MethodChannel _methods;

  static bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<bool> isAvailable() async {
    if (!isSupportedPlatform) return false;
    try {
      return await _methods.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<String> getUnavailableReason() async {
    if (!isSupportedPlatform) return 'platform_unsupported';
    try {
      return await _methods.invokeMethod<String>('getUnavailableReason') ??
          'unknown';
    } on MissingPluginException {
      return 'plugin_missing';
    }
  }

  Future<String> createSession({
    required String pathModel,
    LlamaConfig config = const LlamaConfig(),
  }) async {
    _requireSupported();
    final raw = await _invoke<Map>(
      'createSession',
      <String, Object?>{
        'pathModel': pathModel,
        ...config.toMap(),
      },
    );
    final id = raw['sessionId']?.toString();
    if (id == null || id.isEmpty) {
      throw const LocalLlmException('no_session', 'createSession returned no id');
    }
    return id;
  }

  Future<String> generate({
    required String sessionId,
    required String prompt,
    int maxTokens = 1024,
  }) async {
    _requireSupported();
    return await _invoke<String>(
      'generate',
      <String, Object?>{
        'sessionId': sessionId,
        'prompt': prompt,
        'maxTokens': maxTokens,
      },
    );
  }

  Future<int> countTokens({
    required String sessionId,
    required String text,
  }) async {
    _requireSupported();
    return await _invoke<int>(
      'countTokens',
      <String, Object?>{'sessionId': sessionId, 'text': text},
    );
  }

  Future<String?> applyChatTemplate({
    required String sessionId,
    required List<String> roles,
    required List<String> contents,
    bool enableThinking = false,
    bool addAssistant = true,
  }) async {
    _requireSupported();
    return await _invoke<String?>(
      'applyChatTemplate',
      <String, Object?>{
        'sessionId': sessionId,
        'roles': roles,
        'contents': contents,
        'enableThinking': enableThinking,
        'addAssistant': addAssistant,
      },
    );
  }

  Future<void> cancel(String sessionId) async {
    if (!isSupportedPlatform) return;
    await _invoke<bool>('cancel', <String, Object?>{'sessionId': sessionId});
  }

  /// Streams tokens from a llama.cpp session.
  ///
  /// Returns a broadcast stream that emits each decoded token. The stream
  /// completes when generation finishes or errors. The native side pushes
  /// tokens via `onToken` / `onStreamDone` / `onStreamError` callbacks on
  /// the same MethodChannel.
  Stream<String> generateStream({
    required String sessionId,
    required String prompt,
    int maxTokens = 1024,
  }) {
    _requireSupported();
    final controller = StreamController<String>();
    final key = _StreamKey(sessionId, identityHashCode(controller));

    void handler(MethodCall call) {
      if (call.method == 'onToken') {
        final map = call.arguments as Map<dynamic, dynamic>?;
        if (map?['sessionId'] == sessionId) {
          controller.add(map?['token']?.toString() ?? '');
        }
      } else if (call.method == 'onStreamDone') {
        final map = call.arguments as Map<dynamic, dynamic>?;
        if (map?['sessionId'] == sessionId) {
          _removeStreamHandler(key);
          controller.close();
        }
      } else if (call.method == 'onStreamError') {
        final map = call.arguments as Map<dynamic, dynamic>?;
        if (map?['sessionId'] == sessionId) {
          _removeStreamHandler(key);
          controller.addError(map?['error']?.toString() ?? 'stream_error');
          controller.close();
        }
      }
    }

    _streamHandlers[key] = handler;
    _methods.setMethodCallHandler(_dispatchStreamCalls);

    controller.onCancel = () {
      _removeStreamHandler(key);
    };

    // Kick off generation on the native side.
    _invoke<bool>(
      'generateStream',
      <String, Object?>{
        'sessionId': sessionId,
        'prompt': prompt,
        'maxTokens': maxTokens,
      },
    ).catchError((Object e) {
      if (!controller.isClosed) {
        controller.addError(e);
        controller.close();
      }
      _removeStreamHandler(key);
    });

    return controller.stream;
  }

  static final Map<_StreamKey, void Function(MethodCall)> _streamHandlers =
      <_StreamKey, void Function(MethodCall)>{};

  static Future<dynamic> _dispatchStreamCalls(MethodCall call) async {
    final snapshot = List<_StreamKey>.from(_streamHandlers.keys);
    for (final key in snapshot) {
      final handler = _streamHandlers[key];
      if (handler != null) {
        runCatching(() => handler(call));
      }
    }
  }

  void _removeStreamHandler(_StreamKey key) {
    _streamHandlers.remove(key);
    if (_streamHandlers.isEmpty) {
      _methods.setMethodCallHandler(null);
    }
  }

  Future<void> release(String sessionId) async {
    if (!isSupportedPlatform) return;
    await _invoke<bool>('release', <String, Object?>{'sessionId': sessionId});
  }

  /// Pushes the prewarm configuration to the native [LlamaPreWarmManager].
  ///
  /// When [enabled] is false the manager is inert (no callbacks registered,
  /// no sessions tracked). [bgReleaseModel] controls whether active sessions
  /// are released when the app is backgrounded; [warmupOnCharge] controls
  /// whether the last-used model is mmap-preloaded while charging.
  Future<void> applyPrewarmConfig({
    required bool enabled,
    required bool bgReleaseModel,
    required bool warmupOnCharge,
  }) async {
    if (!isSupportedPlatform) return;
    await _invoke<bool>(
      'applyPrewarmConfig',
      <String, Object?>{
        'enabled': enabled,
        'bgReleaseModel': bgReleaseModel,
        'warmupOnCharge': warmupOnCharge,
      },
    );
  }

  /// Notifies the native manager that the app moved to the background.
  Future<void> onAppBackground() async {
    if (!isSupportedPlatform) return;
    try {
      await _invoke<bool>('onAppBackground');
    } catch (_) {
      // Native side may not be ready; ignore.
    }
  }

  /// Notifies the native manager that the app moved to the foreground.
  Future<void> onAppForeground() async {
    if (!isSupportedPlatform) return;
    try {
      await _invoke<bool>('onAppForeground');
    } catch (_) {
      // Native side may not be ready; ignore.
    }
  }

  /// Reads lightweight metadata from a GGUF file header (name, architecture,
  /// parameter label, quantization type, default context length).
  ///
  /// Returns null if the file is not a valid GGUF file or the platform does
  /// not support the operation. Never throws — failures degrade to null.
  Future<GgufMetadata?> readGgufMetadata(String path) async {
    if (!isSupportedPlatform) return null;
    if (path.isEmpty) return null;
    try {
      final map = await _methods.invokeMethod<Map<dynamic, dynamic>?>(
        'readGgufMetadata',
        <String, Object?>{'path': path},
      );
      if (map == null) return null;
      return GgufMetadata.fromMap(map.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  void _requireSupported() {
    if (!isSupportedPlatform) {
      throw const LocalLlmUnsupportedException();
    }
  }

  Future<T> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      final result = await _methods.invokeMethod<Object?>(method, args);
      return result as T;
    } on MissingPluginException catch (e) {
      throw LocalLlmException('plugin_missing', e.message);
    } on PlatformException catch (e) {
      throw LocalLlmException(e.code, e.message);
    }
  }
}

class LlamaConfig {
  const LlamaConfig({
    this.nThreads = 4,
    this.nCtx = 2048,
    this.nBatch = 512,
    this.nUBatch = 512,
    this.nGpuLayers = 0,
    this.useMmap = false,
    this.flashAttention = false,
    this.kvUnified = true,
    this.offloadKqv = false,
  });

  final int nThreads;
  final int nCtx;
  final int nBatch;
  final int nUBatch;
  final int nGpuLayers;
  final bool useMmap;
  final bool flashAttention;
  final bool kvUnified;
  final bool offloadKqv;

  Map<String, Object?> toMap() => <String, Object?>{
    'nThreads': nThreads,
    'nCtx': nCtx,
    'nBatch': nBatch,
    'nUBatch': nUBatch,
    'nGpuLayers': nGpuLayers,
    'useMmap': useMmap,
    'flashAttention': flashAttention,
    'kvUnified': kvUnified,
    'offloadKqv': offloadKqv,
  };
}

class LocalLlmException implements Exception {
  const LocalLlmException(this.code, [this.message]);
  final String code;
  final String? message;
  @override
  String toString() => 'LocalLlmException($code, $message)';
}

class LocalLlmUnsupportedException extends LocalLlmException {
  const LocalLlmUnsupportedException()
      : super('unsupported', 'Local LLM is only available on Android.');
}

/// Lightweight metadata parsed from a GGUF file header by [ModelInfoReader].
class GgufMetadata {
  const GgufMetadata({
    this.name,
    this.architecture,
    this.parameterLabel,
    this.quantization,
    this.contextLength,
    this.fileSizeBytes,
    this.integrityWarning,
  });

  final String? name;
  final String? architecture;
  final String? parameterLabel;
  final String? quantization;
  final int? contextLength;
  final int? fileSizeBytes;
  final String? integrityWarning;

  factory GgufMetadata.fromMap(Map<String, Object?> map) {
    return GgufMetadata(
      name: map['name'] as String?,
      architecture: map['architecture'] as String?,
      parameterLabel: map['parameterLabel'] as String?,
      quantization: map['quantization'] as String?,
      contextLength: (map['contextLength'] as num?)?.toInt(),
      fileSizeBytes: (map['fileSizeBytes'] as num?)?.toInt(),
      integrityWarning: map['integrityWarning'] as String?,
    );
  }

  String get displaySummary {
    final parts = <String>[];
    if (parameterLabel != null) parts.add(parameterLabel!);
    if (quantization != null) parts.add(quantization!);
    if (contextLength != null) parts.add('ctx: ${_formatCtx(contextLength!)}');
    return parts.join(' · ');
  }

  static String _formatCtx(int n) {
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}k';
    return '$n';
  }
}

/// Internal key for routing streamed tokens to the correct controller.
class _StreamKey {
  const _StreamKey(this.sessionId, this.controllerId);
  final String sessionId;
  final int controllerId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _StreamKey &&
          runtimeType == other.runtimeType &&
          sessionId == other.sessionId &&
          controllerId == other.controllerId;

  @override
  int get hashCode => Object.hash(sessionId, controllerId);
}

/// Lightweight time-buffer smoother for streamed LLM tokens.
///
/// Tokens arrive one at a time from llama.cpp; rendering each immediately
/// causes a jittery, flickery experience on slow models. [TokenSmoother]
/// accumulates tokens into a short buffer and flushes them at a fixed cadence,
/// producing a steady stream of chunks for the UI.
///
/// When [enabled] is false the smoother is a pass-through with zero overhead.
class TokenSmoother {
  TokenSmoother({
    this.enabled = false,
    this.flushIntervalMs = 50,
    this.maxBatchSize = 12,
  });

  /// Master toggle; when false [smooth] is an identity transform.
  bool enabled;

  /// How often the buffer is flushed, in milliseconds.
  final int flushIntervalMs;

  /// Maximum tokens held before an immediate flush (prevents runaway lag).
  final int maxBatchSize;

  final StringBuffer _buffer = StringBuffer();
  Timer? _timer;
  bool _sourceDone = false;

  /// Transforms a raw token stream into a smoothed chunk stream.
  Stream<String> smooth(Stream<String> source) {
    if (!enabled) return source;
    final controller = StreamController<String>();
    _sourceDone = false;

    void flush() {
      if (_buffer.isEmpty) return;
      final chunk = _buffer.toString();
      _buffer.clear();
      if (!controller.isClosed) controller.add(chunk);
    }

    void scheduleFlush() {
      _timer?.cancel();
      _timer = Timer(Duration(milliseconds: flushIntervalMs), () {
        flush();
        if (_sourceDone && !controller.isClosed) {
          controller.close();
        }
      });
    }

    source.listen(
      (token) {
        _buffer.write(token);
        if (_buffer.length >= maxBatchSize) {
          _timer?.cancel();
          flush();
        } else {
          scheduleFlush();
        }
      },
      onError: (Object e) {
        _timer?.cancel();
        flush();
        if (!controller.isClosed) {
          controller.addError(e);
          controller.close();
        }
      },
      onDone: () {
        _sourceDone = true;
        if (_buffer.isEmpty) {
          _timer?.cancel();
          if (!controller.isClosed) controller.close();
        } else {
          scheduleFlush();
        }
      },
    );

    controller.onCancel = () {
      _timer?.cancel();
      _buffer.clear();
      _sourceDone = false;
    };

    return controller.stream;
  }

  void dispose() {
    _timer?.cancel();
    _buffer.clear();
    _sourceDone = false;
  }
}
