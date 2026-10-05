import 'dart:async';
import 'dart:convert';

import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/services/local_llm/local_llm_channel.dart';
import 'package:Kelivo/core/services/mcp_call_stats_service.dart';
import 'package:Kelivo/core/services/toolpkg/toolpkg_channel.dart';
import 'package:Kelivo/core/services/toolpkg/toolpkg_permission_service.dart';

/// Native agent capabilities exposed to the model as built-in MCP-style tools.
///
/// These are *extensions* of Kelivo's existing tool pipeline, not a parallel
/// MCP host. They reuse the same assistant tool switches (`localToolIds`),
/// the same tool catalog, and the same dispatch chain in
/// `ToolHandlerService`.
///
///  - `mcp_native_llama`: runs inference through the transplanted llama.cpp
///    JNI binding. The model path comes from Kelivo's own model selection; no
///    Operit download/management UI is imported.
///  - `mcp_native_js`: runs ad-hoc JS inside the transplanted QuickJS sandbox.
///    File / network access is gated by per-call permission flags.
abstract final class NativeAgentToolsService {
  NativeAgentToolsService._();

  static const String nativeLlama = 'mcp_native_llama';
  static const String nativeJs = 'mcp_native_js';

  static const List<String> all = <String>[nativeLlama, nativeJs];

  /// Global feature gates. Updated by the settings provider when the user
  /// toggles the corresponding switches. When false, the tool is treated as
  /// unavailable on every platform: it is not advertised to the model and
  /// any call returns null without touching the native layer.
  static bool localLlmEnabled = false;
  static bool quickJsSandboxEnabled = false;

  /// Local-only call timing statistics. Set by [SettingsProvider] during
  /// load so [tryHandleToolCall] can record durations without holding a
  /// reference to the widget tree.
  static McpCallStatsService? statsService;

  static bool isAvailableOnThisPlatform(String name) {
    switch (name) {
      case nativeLlama:
        return localLlmEnabled && LocalLlmChannel.isSupportedPlatform;
      case nativeJs:
        return quickJsSandboxEnabled && LocalLlmChannel.isSupportedPlatform;
      default:
        return false;
    }
  }

  static Map<String, dynamic> definitionFor(String name) {
    switch (name) {
      case nativeLlama:
        return _nativeLlamaDefinition;
      case nativeJs:
        return _nativeJsDefinition;
      default:
        throw ArgumentError.value(name, 'name', 'Unknown native agent tool');
    }
  }

  static Future<String?> tryHandleToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant? assistant, {
    LocalLlmChannel? llmChannel,
    ToolPkgChannel? toolPkgChannel,
    ToolPkgPermissionService? permissionService,
    void Function(String token)? onToken,
    bool tokenStreamSmoothing = false,
  }) async {
    if (assistant == null || !assistant.localToolIds.contains(name)) {
      return null;
    }
    // Honor the global feature gates. When disabled, return null so the
    // dispatch chain falls through (zero native work, no memory footprint).
    if (!isAvailableOnThisPlatform(name)) {
      return null;
    }
    switch (name) {
      case nativeLlama:
        return _timedCall(
          toolType: nativeLlama,
          action: () => _handleNativeLlama(
            args,
            llmChannel ?? LocalLlmChannel(),
            onToken: onToken,
            tokenStreamSmoothing: tokenStreamSmoothing,
          ),
        );
      case nativeJs:
        // Distinguish ad-hoc JS from ToolPkg package invocations for stats.
        final isToolPkg = (args['package_id']?.toString() ?? '').isNotEmpty;
        return _timedCall(
          toolType: isToolPkg ? 'toolpkg' : nativeJs,
          action: () => _handleNativeJs(
            args,
            toolPkgChannel ?? ToolPkgChannel(),
            permissionService,
          ),
        );
      default:
        return null;
    }
  }

  /// Runs [action], measures its wall-clock duration, and records a stat
  /// entry. The result of [action] is returned unchanged. Success is derived
  /// from the JSON `ok` field when the result looks like our envelope;
  /// otherwise a non-null result counts as success.
  static Future<String> _timedCall({
    required String toolType,
    required Future<String> Function() action,
  }) async {
    final sw = Stopwatch()..start();
    String result;
    var success = false;
    try {
      result = await action();
      success = _resultOk(result);
    } catch (_) {
      sw.stop();
      statsService?.record(
        toolType: toolType,
        durationMs: sw.elapsedMilliseconds,
        success: false,
      );
      rethrow;
    }
    sw.stop();
    statsService?.record(
      toolType: toolType,
      durationMs: sw.elapsedMilliseconds,
      success: success,
    );
    return result;
  }

  static bool _resultOk(String result) {
    if (result.isEmpty) return false;
    try {
      final decoded = jsonDecode(result);
      if (decoded is Map) {
        final ok = decoded['ok'];
        if (ok is bool) return ok;
      }
    } catch (_) {
      // Not JSON; treat as success (the handler returned something).
    }
    return true;
  }

  static Future<String> _handleNativeLlama(
    Map<String, dynamic> args,
    LocalLlmChannel channel, {
    void Function(String token)? onToken,
    bool tokenStreamSmoothing = false,
  }) async {
    final modelPath = (args['model_path'] ?? '').toString();
    final prompt = (args['prompt'] ?? '').toString();
    if (modelPath.isEmpty) {
      return _error('model_path is required');
    }
    if (prompt.isEmpty) {
      return _error('prompt is required');
    }
    final maxTokens = (args['max_tokens'] as num?)?.toInt() ?? 1024;
    final systemPrompt = args['system_prompt']?.toString();
    final fullPrompt = systemPrompt == null || systemPrompt.isEmpty
        ? prompt
        : '$systemPrompt\n\n$prompt';
    String? sessionId;
    try {
      final available = await channel.isAvailable();
      if (!available) {
        final reason = await channel.getUnavailableReason();
        return _error('local llama unavailable: $reason');
      }
      sessionId = await channel.createSession(pathModel: modelPath);
      final output = await _generateWithSmoothing(
        channel: channel,
        sessionId: sessionId,
        prompt: fullPrompt,
        maxTokens: maxTokens,
        onToken: onToken,
        smoothing: tokenStreamSmoothing,
      );
      return jsonEncode(<String, dynamic>{'ok': true, 'text': output});
    } catch (e) {
      return _error(e.toString());
    } finally {
      if (sessionId != null) {
        unawaited(channel.release(sessionId));
      }
    }
  }

  /// Generates text, optionally streaming (smoothed) tokens to [onToken].
  ///
  /// When [smoothing] is false and no [onToken] callback is provided, this is
  /// a thin wrapper over the non-streaming [LocalLlmChannel.generate] with
  /// zero extra overhead. Otherwise it uses [LocalLlmChannel.generateStream]
  /// and pipes tokens through a [TokenSmoother].
  static Future<String> _generateWithSmoothing({
    required LocalLlmChannel channel,
    required String sessionId,
    required String prompt,
    required int maxTokens,
    void Function(String token)? onToken,
    required bool smoothing,
  }) async {
    final useStream = smoothing || onToken != null;
    if (!useStream) {
      return await channel.generate(
        sessionId: sessionId,
        prompt: prompt,
        maxTokens: maxTokens,
      );
    }
    final smoother = TokenSmoother(enabled: smoothing);
    final raw = channel.generateStream(
      sessionId: sessionId,
      prompt: prompt,
      maxTokens: maxTokens,
    );
    final sb = StringBuffer();
    await for (final chunk in smoother.smooth(raw)) {
      sb.write(chunk);
      onToken?.call(chunk);
    }
    smoother.dispose();
    return sb.toString();
  }

  static Future<String> _handleNativeJs(
    Map<String, dynamic> args,
    ToolPkgChannel channel,
    ToolPkgPermissionService? permissionService,
  ) async {
    final packageId = args['package_id']?.toString();
    final function = args['function']?.toString() ?? 'main';
    final code = (args['code'] ?? '').toString();

    // Package invocation path: respects manifest capabilities.
    if (packageId != null && packageId.isNotEmpty) {
      if (permissionService == null) {
        return _error('permission service unavailable for package invocation');
      }
      // Resolve the package metadata to read its declared capabilities.
      final packages = await channel.list();
      final pkg = packages.where((p) => p.id == packageId).cast<ToolPkgInfo?>().firstWhere(
            (p) => p != null,
            orElse: () => null,
          );
      if (pkg == null) {
        return _error('package not installed: $packageId');
      }
      final resolved = await permissionService.ensureCapabilities(
        packageId: packageId,
        packageDisplayName: pkg.displayName,
        capabilities: pkg.capabilities,
      );
      if (resolved == null) {
        return _error('permission denied for package: $packageId');
      }
      final innerArgs = args['args'] is Map
          ? args['args'] as Map<String, dynamic>
          : <String, dynamic>{};
      try {
        final output = await channel.invoke(
          packageId: packageId,
          function: function,
          args: innerArgs,
          allowFile: resolved['file'] == true,
          allowNetwork: resolved['network'] == true,
        );
        return jsonEncode(<String, dynamic>{
          'ok': true,
          'result': output,
          'packageId': packageId,
          'function': function,
          'permissions': resolved,
        });
      } catch (e) {
        return _error(e.toString());
      }
    }

    // Ad-hoc eval path: per-call allow flags, no manifest.
    if (code.isEmpty) {
      return _error('code or package_id is required');
    }
    final innerArgs = args['args'] is Map
        ? args['args'] as Map<String, dynamic>
        : <String, dynamic>{};
    final allowFile = args['allow_file'] == true;
    final allowNetwork = args['allow_network'] == true;
    try {
      final output = await channel.evalJs(
        code: code,
        args: innerArgs,
        allowFile: allowFile,
        allowNetwork: allowNetwork,
      );
      return jsonEncode(<String, dynamic>{
        'ok': true,
        'result': output,
        'permissions': <String, bool>{
          'file': allowFile,
          'network': allowNetwork,
        },
      });
    } catch (e) {
      return _error(e.toString());
    }
  }

  static String _error(String message) =>
      jsonEncode(<String, dynamic>{'ok': false, 'error': message});

  static final Map<String, dynamic> _nativeLlamaDefinition =
      <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': nativeLlama,
      'description': 'Run inference locally on-device using a llama.cpp model. '
          'Provide the absolute path to a GGUF model file selected through '
          "Kelivo's model picker. Returns the generated text.",
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'model_path': <String, dynamic>{
            'type': 'string',
            'description': 'Absolute path to the GGUF model file.',
          },
          'prompt': <String, dynamic>{
            'type': 'string',
            'description': 'The prompt to generate from.',
          },
          'system_prompt': <String, dynamic>{
            'type': 'string',
            'description': 'Optional system prompt prepended to the prompt.',
          },
          'max_tokens': <String, dynamic>{
            'type': 'integer',
            'description': 'Maximum number of tokens to generate.',
            'default': 1024,
          },
        },
        'required': <String>['model_path', 'prompt'],
      },
    },
  };

  static final Map<String, dynamic> _nativeJsDefinition = <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': nativeJs,
      'description': 'Execute JavaScript inside a QuickJS sandbox on the '
          'device. Two modes: (1) provide `code` for ad-hoc eval with '
          'allow_file / allow_network flags; (2) provide `package_id` to '
          'invoke a function from an installed ToolPkg, whose manifest '
          'capabilities are authorised by the user on first use.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'code': <String, dynamic>{
            'type': 'string',
            'description': 'JavaScript source to execute (ad-hoc mode).',
          },
          'package_id': <String, dynamic>{
            'type': 'string',
            'description': 'ID of an installed ToolPkg to invoke '
                '(package mode). When set, `code` is ignored.',
          },
          'function': <String, dynamic>{
            'type': 'string',
            'description': 'Exported function name to call inside the '
                'package (package mode). Defaults to "main".',
            'default': 'main',
          },
          'args': <String, dynamic>{
            'type': 'object',
            'description': 'Optional arguments exposed to the script as '
                'global `__args`.',
          },
          'allow_file': <String, dynamic>{
            'type': 'boolean',
            'description': 'Allow the script to read/write files '
                '(ad-hoc mode only).',
            'default': false,
          },
          'allow_network': <String, dynamic>{
            'type': 'boolean',
            'description': 'Allow the script to make HTTP requests '
                '(ad-hoc mode only).',
            'default': false,
          },
        },
      },
    },
  };
}
