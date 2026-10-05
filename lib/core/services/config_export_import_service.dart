import 'dart:convert';

import '../../database/business_preferences.dart';

/// Exports and imports a curated subset of Kelivo-Operit configuration as JSON.
///
/// Included scopes (no new DB tables; everything lives in the existing
/// [BusinessPreferences] key-value store):
///  * Global feature switches (the boolean/string toggles exposed in Settings).
///  * Per-assistant local-tool selection (`localToolIds`).
///  * ToolPkg capability authorization records
///    (`toolpkg_perm_grant_<pkg>_<cap>`).
///
/// Import does **not** overwrite unrelated settings. Only the keys listed in
/// [_globalSwitchKeys], the assistant tool-selection field, and the ToolPkg
/// grant keys are touched.
class ConfigExportImportService {
  ConfigExportImportService(this._prefs);

  final BusinessPreferences _prefs;

  static const String _assistantsKey = 'assistants_v1';
  static const String _toolpkgGrantPrefix = 'toolpkg_perm_grant_';

  /// Curated list of global switch keys to export/import.
  ///
  /// These are the feature toggles a user typically wants to carry between
  /// devices. Sensitive per-provider credentials and UI preferences are
  /// intentionally excluded.
  static const List<String> _globalSwitchKeys = <String>[
    'local_llm_enabled_v1',
    'quickjs_sandbox_enabled_v1',
    'toolpkg_host_backend_v1',
    'workflow_plugin_enabled_v1',
    'memory_enhancement_enabled_v1',
    'llm_bg_release_model_v1',
    'llm_warmup_on_charge_v1',
    'token_stream_smoothing_v1',
    'search_enabled_v1',
  ];

  /// Builds the export payload as a JSON-encoded string.
  Future<String> exportJson() async {
    await _prefs.load();
    final globalSwitches = <String, Object?>{};
    for (final key in _globalSwitchKeys) {
      if (_prefs.containsKey(key)) {
        globalSwitches[key] = _prefs.get(key);
      }
    }

    final assistants = <Map<String, Object?>>[];
    final raw = _prefs.getString(_assistantsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final item in list) {
          final map = item as Map<String, dynamic>;
          assistants.add(<String, Object?>{
            'id': map['id'],
            'name': map['name'],
            'localToolIds': map['localToolIds'] ?? const <String>[],
          });
        }
      } catch (_) {
        // Ignore malformed assistant data; export what we can.
      }
    }

    final toolpkgGrants = <String, String>{};
    for (final key in _prefs.getKeys()) {
      if (key.startsWith(_toolpkgGrantPrefix)) {
        final value = _prefs.getString(key);
        if (value != null) toolpkgGrants[key] = value;
      }
    }

    return jsonEncode(<String, Object?>{
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'globalSwitches': globalSwitches,
      'assistants': assistants,
      'toolpkgGrants': toolpkgGrants,
    });
  }

  /// Parses and returns a summary of what an import would change, without
  /// applying anything. Used to populate the confirmation dialog.
  ImportPreview previewImport(String json) {
    final data = _parsePayload(json);
    if (data == null) {
      return const ImportPreview(valid: false, reason: 'JSON 格式无效或版本不兼容');
    }
    return ImportPreview(
      valid: true,
      globalSwitchCount: (data['globalSwitches'] as Map?)?.length ?? 0,
      assistantCount: (data['assistants'] as List?)?.length ?? 0,
      toolpkgGrantCount: (data['toolpkgGrants'] as Map?)?.length ?? 0,
    );
  }

  /// Applies the import. Caller must show a confirmation dialog first.
  ///
  /// Only the scoped keys are written; unrelated preferences are left
  /// untouched. Returns the number of keys actually changed.
  Future<int> applyImport(String json) async {
    final data = _parsePayload(json);
    if (data == null) return 0;
    await _prefs.load();

    var changed = 0;

    final globalSwitches = data['globalSwitches'] as Map?;
    if (globalSwitches != null) {
      for (final entry in globalSwitches.entries) {
        final key = entry.key.toString();
        if (!_globalSwitchKeys.contains(key)) continue;
        final value = entry.value;
        await _writeValue(key, value);
        changed++;
      }
    }

    final assistants = data['assistants'] as List?;
    if (assistants != null && assistants.isNotEmpty) {
      changed += await _mergeAssistantToolIds(assistants);
    }

    final grants = data['toolpkgGrants'] as Map?;
    if (grants != null) {
      for (final entry in grants.entries) {
        final key = entry.key.toString();
        if (!key.startsWith(_toolpkgGrantPrefix)) continue;
        await _prefs.setString(key, entry.value.toString());
        changed++;
      }
    }

    return changed;
  }

  Future<int> _mergeAssistantToolIds(List<dynamic> incoming) async {
    final raw = _prefs.getString(_assistantsKey);
    if (raw == null || raw.isEmpty) return 0;
    List<dynamic> current;
    try {
      current = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      return 0;
    }
    final byId = <String, Map<String, dynamic>>{};
    for (final item in current) {
      final map = item as Map<String, dynamic>;
      final id = map['id']?.toString();
      if (id != null) byId[id] = map;
    }
    var changed = 0;
    for (final item in incoming) {
      final map = item as Map;
      final id = map['id']?.toString();
      if (id == null) continue;
      final existing = byId[id];
      if (existing == null) continue; // only update existing assistants
      final newToolIds = (map['localToolIds'] as List?)?.cast<String>() ?? const <String>[];
      final oldToolIds = (existing['localToolIds'] as List?)?.cast<String>() ?? const <String>[];
      if (_listEquals(oldToolIds, newToolIds)) continue;
      existing['localToolIds'] = newToolIds;
      changed++;
    }
    if (changed > 0) {
      await _prefs.setString(_assistantsKey, jsonEncode(current));
    }
    return changed;
  }

  Future<void> _writeValue(String key, Object? value) async {
    if (value is bool) {
      await _prefs.setBool(key, value);
    } else if (value is int) {
      await _prefs.setInt(key, value);
    } else if (value is double) {
      await _prefs.setDouble(key, value);
    } else if (value is String) {
      await _prefs.setString(key, value);
    } else if (value is List) {
      await _prefs.setStringList(key, value.cast<String>());
    }
  }

  Map<String, Object?>? _parsePayload(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      if (map['version'] != 1) return null;
      return map;
    } catch (_) {
      return null;
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Summary of an import payload, used to render the confirmation dialog.
class ImportPreview {
  const ImportPreview({
    required this.valid,
    this.reason,
    this.globalSwitchCount = 0,
    this.assistantCount = 0,
    this.toolpkgGrantCount = 0,
  });

  final bool valid;
  final String? reason;
  final int globalSwitchCount;
  final int assistantCount;
  final int toolpkgGrantCount;
}
