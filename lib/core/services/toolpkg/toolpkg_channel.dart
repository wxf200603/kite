import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Client for the ToolPkg loader running on the transplanted QuickJS sandbox.
///
/// Two execution paths are exposed:
///  * [invoke] runs a function from an installed ToolPkg zip.
///  * [evalJs] runs ad-hoc JS (used by the `mcp_native_js` built-in tool).
///
/// Both honour the `allowFile` / `allowNetwork` permission flags.
class ToolPkgChannel {
  ToolPkgChannel({MethodChannel? methodChannel})
      : _methods = methodChannel ??
            const MethodChannel('app.toolpkg', StandardMethodCodec()) {
    _ensureConsoleLogHandler();
  }

  final MethodChannel _methods;

  static bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  // ---- Console log bridge ----
  static final StreamController<ToolPkgConsoleEntry> _consoleLogController =
      StreamController<ToolPkgConsoleEntry>.broadcast();
  static bool _consoleHandlerRegistered = false;

  /// Stream of console.* output captured from QuickJS sandboxes.
  Stream<ToolPkgConsoleEntry> get consoleLogStream =>
      _consoleLogController.stream;

  void _ensureConsoleLogHandler() {
    if (_consoleHandlerRegistered) return;
    _consoleHandlerRegistered = true;
    _methods.setMethodCallHandler((call) async {
      if (call.method == 'onConsoleLog') {
        final map = call.arguments as Map<dynamic, dynamic>?;
        if (map != null) {
          _consoleLogController.add(
            ToolPkgConsoleEntry.fromMap(
              map.map((k, v) => MapEntry(k.toString(), v)),
            ),
          );
        }
        return null;
      }
      if (call.method == 'httpGet') {
        // Bridged HTTP request from the Kotlin PermissionGate. The actual
        // HTTP client lives in Dart so we can reuse proxies, timeouts, and
        // avoid granting the QuickJS sandbox direct socket access.
        final args = call.arguments as Map<dynamic, dynamic>?;
        final url = args?['url']?.toString() ?? '';
        if (url.isEmpty) {
          throw PlatformException(code: 'invalid_url', message: 'url is required');
        }
        try {
          final uri = Uri.parse(url);
          final response = await http.get(uri).timeout(
            const Duration(seconds: 25),
          );
          if (response.statusCode >= 400) {
            throw PlatformException(
              code: 'http_${response.statusCode}',
              message: 'HTTP ${response.statusCode}',
            );
          }
          return response.body;
        } on PlatformException {
          rethrow;
        } catch (e) {
          throw PlatformException(code: 'http_error', message: e.toString());
        }
      }
      return null;
    });
  }

  Future<List<ToolPkgConsoleEntry>> getConsoleLogs() async {
    if (!isSupportedPlatform) return const <ToolPkgConsoleEntry>[];
    final raw = await _invoke<List<dynamic>>('getConsoleLogs');
    return raw
        .map((e) => ToolPkgConsoleEntry.fromMap(
              (e as Map).map((k, v) => MapEntry(k.toString(), v)),
            ))
        .toList(growable: false);
  }

  Future<void> clearConsoleLogs() async {
    if (!isSupportedPlatform) return;
    await _invoke<bool>('clearConsoleLogs');
  }

  /// Sets the host backend used for ToolPkg exec/readFile/writeFile.
  ///
  /// [backend] must be one of `normal`, `root`, `proot`.
  Future<void> setHostBackend(String backend) async {
    if (!isSupportedPlatform) return;
    await _invoke<bool>('setHostBackend', <String, Object?>{'backend': backend});
  }

  /// Sets the rootfs directory used by the `proot` backend.
  Future<void> setRootfsDir(String? rootfsDir) async {
    if (!isSupportedPlatform) return;
    await _invoke<bool>(
      'setRootfsDir',
      <String, Object?>{'rootfsDir': rootfsDir},
    );
  }

  /// Pushes the ToolPkg network master switch and domain whitelist down to
  /// the native plugin. Even when a package declares the "network" capability
  /// and the user grants it, [enabled] must be true for any HTTP request to
  /// leave the sandbox. [whitelist] is a comma-separated list of domain
  /// patterns (supports `*`); empty means allow all domains.
  Future<void> setNetworkConfig({
    required bool enabled,
    required String whitelist,
  }) async {
    if (!isSupportedPlatform) return;
    await _invoke<bool>(
      'setNetworkConfig',
      <String, Object?>{'enabled': enabled, 'whitelist': whitelist},
    );
  }

  Future<ToolPkgInfo> install(String zipPath) async {
    _requireSupported();
    final raw = await _invoke<Map>('install', <String, Object?>{
      'zipPath': zipPath,
    });
    return ToolPkgInfo.fromMap(_stringKeyed(raw));
  }

  Future<List<ToolPkgInfo>> list() async {
    if (!isSupportedPlatform) return const <ToolPkgInfo>[];
    final raw = await _invoke<String>('list');
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => ToolPkgInfo.fromMap(_stringKeyed(e as Map)))
        .toList(growable: false);
  }

  Future<String> invoke({
    required String packageId,
    required String function,
    Map<String, dynamic> args = const <String, dynamic>{},
    bool allowFile = false,
    bool allowNetwork = false,
  }) async {
    _requireSupported();
    return await _invoke<String>('invoke', <String, Object?>{
      'packageId': packageId,
      'function': function,
      'args': jsonEncode(args),
      'allowFile': allowFile,
      'allowNetwork': allowNetwork,
    });
  }

  Future<String> evalJs({
    required String code,
    Map<String, dynamic> args = const <String, dynamic>{},
    bool allowFile = false,
    bool allowNetwork = false,
  }) async {
    _requireSupported();
    return await _invoke<String>('evalJs', <String, Object?>{
      'code': code,
      'args': jsonEncode(args),
      'allowFile': allowFile,
      'allowNetwork': allowNetwork,
    });
  }

  Future<bool> uninstall(String packageId) async {
    if (!isSupportedPlatform) return false;
    return await _invoke<bool>(
      'uninstall',
      <String, Object?>{'packageId': packageId},
    );
  }

  void _requireSupported() {
    if (!isSupportedPlatform) {
      throw const ToolPkgUnsupportedException();
    }
  }

  Future<T> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      final result = await _methods.invokeMethod<Object?>(method, args);
      return result as T;
    } on MissingPluginException catch (e) {
      throw ToolPkgException('plugin_missing', e.message);
    } on PlatformException catch (e) {
      throw ToolPkgException(e.code, e.message);
    }
  }

  Map<String, Object?> _stringKeyed(Map raw) => <String, Object?>{
    for (final entry in raw.entries) entry.key.toString(): entry.value,
  };
}

class ToolPkgInfo {
  const ToolPkgInfo({
    required this.id,
    required this.displayName,
    required this.description,
    required this.version,
    this.capabilities = const <String>[],
  });

  final String id;
  final String displayName;
  final String description;
  final String version;
  final List<String> capabilities;

  factory ToolPkgInfo.fromMap(Map<String, Object?> map) => ToolPkgInfo(
    id: map['id']?.toString() ?? '',
    displayName: map['displayName']?.toString() ?? '',
    description: map['description']?.toString() ?? '',
    version: map['version']?.toString() ?? '',
    capabilities: (map['capabilities'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList(growable: false) ??
        const <String>[],
  );
}

class ToolPkgException implements Exception {
  const ToolPkgException(this.code, [this.message]);
  final String code;
  final String? message;
  @override
  String toString() => 'ToolPkgException($code, $message)';
}

class ToolPkgUnsupportedException extends ToolPkgException {
  const ToolPkgUnsupportedException()
      : super('unsupported', 'ToolPkg is only available on Android.');
}

/// A single console.* entry captured from a QuickJS sandbox.
class ToolPkgConsoleEntry {
  const ToolPkgConsoleEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  final int timestamp;
  final String level;
  final String message;

  factory ToolPkgConsoleEntry.fromMap(Map<String, Object?> map) =>
      ToolPkgConsoleEntry(
        timestamp: (map['ts'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
        level: map['level']?.toString() ?? 'log',
        message: map['message']?.toString() ?? '',
      );

  String get formattedTime {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }
}
