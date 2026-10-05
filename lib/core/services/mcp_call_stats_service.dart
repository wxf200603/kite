import 'dart:async';
import 'dart:convert';

import '../database/business_preferences.dart';

/// A single recorded MCP / native tool call.
class McpCallStat {
  const McpCallStat({
    required this.toolType,
    required this.timestamp,
    required this.durationMs,
    required this.success,
  });

  /// One of `mcp_native_llama`, `mcp_native_js`, `toolpkg`.
  final String toolType;

  /// Milliseconds since epoch.
  final int timestamp;

  /// Wall-clock duration of the call in milliseconds.
  final int durationMs;

  /// Whether the call returned a successful result.
  final bool success;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'toolType': toolType,
        'timestamp': timestamp,
        'durationMs': durationMs,
        'success': success,
      };

  factory McpCallStat.fromJson(Map<String, dynamic> json) => McpCallStat(
        toolType: json['toolType']?.toString() ?? 'unknown',
        timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        success: json['success'] == true,
      );
}

/// Aggregated statistics for a single tool type.
class McpCallStatAggregate {
  const McpCallStatAggregate({
    required this.toolType,
    required this.count,
    required this.failureCount,
    required this.avgDurationMs,
    required this.totalDurationMs,
  });

  final String toolType;
  final int count;
  final int failureCount;
  final int avgDurationMs;
  final int totalDurationMs;

  double get successRate =>
      count == 0 ? 0 : (count - failureCount) / count;
}

/// Local-only ring buffer of MCP / native tool call timings.
///
/// Data is persisted as a JSON array under a single [BusinessPreferences] key
/// (`mcp_call_stats_v1`) and capped at [_maxEntries] most-recent entries.
/// Nothing is uploaded anywhere — this is strictly on-device telemetry.
class McpCallStatsService {
  McpCallStatsService(this._prefs);

  static const String _statsKey = 'mcp_call_stats_v1';
  static const int _maxEntries = 1000;

  final BusinessPreferences _prefs;

  /// Records a call. The write is serialized by [BusinessPreferences] and is
  /// fire-and-forget from the caller's perspective so it never blocks the
  /// tool dispatch path.
  void record({
    required String toolType,
    required int durationMs,
    required bool success,
  }) {
    unawaited(_append(McpCallStat(
      toolType: toolType,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      durationMs: durationMs,
      success: success,
    )));
  }

  Future<void> _append(McpCallStat entry) async {
    await _prefs.load();
    final raw = _prefs.getString(_statsKey);
    final List<dynamic> list =
        raw == null ? <dynamic>[] : (jsonDecode(raw) as List<dynamic>);
    list.insert(0, entry.toJson());
    if (list.length > _maxEntries) {
      list.removeRange(_maxEntries, list.length);
    }
    await _prefs.setString(_statsKey, jsonEncode(list));
  }

  /// Returns all recorded entries, most recent first.
  List<McpCallStat> getEntries() {
    final raw = _prefs.getString(_statsKey);
    if (raw == null || raw.isEmpty) return const <McpCallStat>[];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => McpCallStat.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(growable: false);
  }

  /// Aggregates entries by tool type.
  List<McpCallStatAggregate> getAggregated() {
    final entries = getEntries();
    final buckets = <String, List<McpCallStat>>{};
    for (final e in entries) {
      buckets.putIfAbsent(e.toolType, () => <McpCallStat>[]).add(e);
    }
    return buckets.entries
        .map((kv) {
          final items = kv.value;
          var total = 0;
          var failures = 0;
          for (final e in items) {
            total += e.durationMs;
            if (!e.success) failures++;
          }
          return McpCallStatAggregate(
            toolType: kv.key,
            count: items.length,
            failureCount: failures,
            avgDurationMs: items.isEmpty ? 0 : total ~/ items.length,
            totalDurationMs: total,
          );
        })
        .toList()
      ..sort((a, b) => b.count.compareTo(a.count));
  }

  Future<void> clear() async {
    await _prefs.setString(_statsKey, '[]');
  }
}
