import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../database/business_preferences.dart';
import '../../../shared/widgets/snackbar.dart';

/// Decision the user made for a ToolPkg capability request.
enum ToolPkgPermDecision {
  /// Grant forever (remember).
  granted,
  /// Grant for this invocation only.
  temporary,
  /// Deny (remember).
  denied,
}

/// Simple permission model for ToolPkg manifest capabilities.
///
/// Capabilities are declared in each package's `manifest.json`, e.g.
/// `["file", "network"]`. Before an installed package is invoked, the caller
/// asks this service to ensure every declared capability is allowed.
///
/// Storage (no new DB tables):
///  * Per-package/per-capability grants live in [BusinessPreferences] as
///    `toolpkg_perm_grant_<pkgId>_<cap>` → `"granted"` / `"denied"`.
///  * A rolling audit log lives at `toolpkg_perm_audit_log` as a JSON array
///    (capped to 200 most-recent entries).
///
/// Gated by the `quickJsSandboxEnabled` setting: when the sandbox is off the
/// native tool is already hidden by [NativeAgentToolsService], so this service
/// is never reached.
class ToolPkgPermissionService {
  ToolPkgPermissionService(this._prefs);

  final BusinessPreferences _prefs;

  static const String _grantPrefix = 'toolpkg_perm_grant_';
  static const String _auditLogKey = 'toolpkg_perm_audit_log';
  static const int _maxAuditEntries = 200;

  /// In-memory "temporary" grants, valid until the process dies.
  final Map<String, Set<String>> _temporaryGrants = <String, Set<String>>{};

  /// Returns the persisted grant for (packageId, capability), or null when the
  /// user has not decided yet.
  String? _persistedGrant(String packageId, String capability) {
    return _prefs.getString('$_grantPrefix${packageId}_$capability');
  }

  Future<void> _persistGrant(
    String packageId,
    String capability,
    String value,
  ) {
    return _prefs.setString(
      '$_grantPrefix${packageId}_$capability',
      value,
    );
  }

  /// Ensures every capability in [capabilities] is allowed for [packageId].
  ///
  /// Returns the resolved allow-flags map keyed by capability. If the user
  /// denies any required capability, returns null so the caller can abort.
  Future<Map<String, bool>?> ensureCapabilities({
    required String packageId,
    required String packageDisplayName,
    required List<String> capabilities,
  }) async {
    if (capabilities.isEmpty) {
      return const <String, bool>{};
    }

    final resolved = <String, bool>{};
    for (final cap in capabilities) {
      final decision = await _resolveCapability(
        packageId: packageId,
        packageDisplayName: packageDisplayName,
        capability: cap,
      );
      if (decision == ToolPkgPermDecision.denied) {
        await _appendAudit(
          packageId: packageId,
          capability: cap,
          decision: 'denied',
        );
        return null;
      }
      resolved[cap] = true;
    }
    return resolved;
  }

  Future<ToolPkgPermDecision> _resolveCapability({
    required String packageId,
    required String packageDisplayName,
    required String capability,
  }) async {
    // 1. Persisted grant (remembered).
    final persisted = _persistedGrant(packageId, capability);
    if (persisted == 'granted') return ToolPkgPermDecision.granted;
    if (persisted == 'denied') return ToolPkgPermDecision.denied;

    // 2. In-memory temporary grant (this session only).
    if (_temporaryGrants[packageId]?.contains(capability) == true) {
      return ToolPkgPermDecision.temporary;
    }

    // 3. Ask the user.
    final decision = await _showPermissionDialog(
      packageId: packageId,
      packageDisplayName: packageDisplayName,
      capability: capability,
    );

    switch (decision) {
      case ToolPkgPermDecision.granted:
        await _persistGrant(packageId, capability, 'granted');
        await _appendAudit(
          packageId: packageId,
          capability: capability,
          decision: 'granted',
        );
        break;
      case ToolPkgPermDecision.temporary:
        _temporaryGrants.putIfAbsent(packageId, () => <String>{}).add(capability);
        await _appendAudit(
          packageId: packageId,
          capability: capability,
          decision: 'temporary',
        );
        break;
      case ToolPkgPermDecision.denied:
        await _persistGrant(packageId, capability, 'denied');
        break;
    }
    return decision;
  }

  Future<ToolPkgPermDecision> _showPermissionDialog({
    required String packageId,
    required String packageDisplayName,
    required String capability,
  }) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null) {
      // No UI available: deny by default (safe choice).
      return ToolPkgPermDecision.denied;
    }

    final capLabel = _capabilityLabel(capability);
    final result = await showDialog<ToolPkgPermDecision>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text('$packageDisplayName 请求权限'),
        content: Text(
          '工具包「$packageDisplayName」请求使用「$capLabel」权限。'
          '\n\n允许后该包可在沙箱内调用对应能力。',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(ToolPkgPermDecision.denied),
            child: const Text('拒绝'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(ToolPkgPermDecision.temporary),
            child: const Text('仅本次允许'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(ToolPkgPermDecision.granted),
            child: const Text('允许并记住'),
          ),
        ],
      ),
    );
    return result ?? ToolPkgPermDecision.denied;
  }

  String _capabilityLabel(String capability) {
    switch (capability) {
      case 'file':
        return '文件读写';
      case 'network':
        return '网络访问';
      default:
        return capability;
    }
  }

  // ── Audit log ────────────────────────────────────────────────────────────

  Future<void> _appendAudit({
    required String packageId,
    required String capability,
    required String decision,
  }) async {
    final raw = _prefs.getString(_auditLogKey);
    final List<dynamic> list =
        raw == null ? <dynamic>[] : (jsonDecode(raw) as List<dynamic>);
    list.insert(0, <String, Object?>{
      'ts': DateTime.now().toIso8601String(),
      'packageId': packageId,
      'capability': capability,
      'decision': decision,
    });
    if (list.length > _maxAuditEntries) {
      list.removeRange(_maxAuditEntries, list.length);
    }
    await _prefs.setString(_auditLogKey, jsonEncode(list));
  }

  /// Returns the audit log (most recent first).
  List<Map<String, dynamic>> getAuditLog() {
    final raw = _prefs.getString(_auditLogKey);
    if (raw == null) return const <Map<String, dynamic>>[];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
  }

  Future<void> clearAuditLog() => _prefs.setString(_auditLogKey, '[]');

  /// Clears all remembered grants for [packageId] (temporary + persisted).
  Future<void> resetGrants(String packageId) async {
    _temporaryGrants.remove(packageId);
    final keys = _prefs.getKeys().where(
          (k) => k.startsWith('$_grantPrefix${packageId}_'),
        );
    for (final k in keys) {
      await _prefs.setString(k, '');
    }
  }
}
