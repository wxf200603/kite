import 'dart:async';
import 'dart:convert';

import 'package:Kelivo/core/database/business_preferences.dart';

/// Lightweight, optional workflow plugin.
///
/// Design constraints (per the Operit-integration spec):
///  * Do NOT copy Operit's full Flow-Runtime. Only its state machine, step
///    scheduling, and retry ideas are borrowed.
///  * Runs *on top of* Kelivo's existing MCP / built-in tool dispatch chain —
///    each step is just a tool call routed through the same handler the chat
///    uses. No parallel execution engine.
///  * Zero overhead when disabled: the [SettingsProvider.workflowPluginEnabled]
///    switch gates construction. Nothing initialises when off.
///  * No new database table. Workflow definitions are stored as a single JSON
///    string in [BusinessPreferences], alongside other settings.
///
/// This keeps Kelivo's architecture, database, MCP host, and chat logic
/// singular — the workflow plugin is purely an optional orchestration layer.
class WorkflowPlugin {
  WorkflowPlugin(this._prefs);

  static const String _workflowsKey = 'workflow_plugin_definitions_v1';

  final BusinessPreferences _prefs;
  List<Workflow> _workflows = const <Workflow>[];
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final raw = _prefs.getString(_workflowsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _workflows = list
            .map((e) => Workflow.fromJson(_stringKeyed(e as Map)))
            .toList(growable: false);
      } catch (_) {
        _workflows = const <Workflow>[];
      }
    }
    _loaded = true;
  }

  List<Workflow> get workflows => List.unmodifiable(_workflows);

  Workflow? byId(String id) {
    for (final w in _workflows) {
      if (w.id == id) return w;
    }
    return null;
  }

  Future<void> upsert(Workflow workflow) async {
    final list = _workflows.toList();
    final idx = list.indexWhere((w) => w.id == workflow.id);
    if (idx >= 0) {
      list[idx] = workflow;
    } else {
      list.add(workflow);
    }
    _workflows = List.unmodifiable(list);
    await _persist();
  }

  Future<void> delete(String id) async {
    _workflows = List.unmodifiable(
      _workflows.where((w) => w.id != id).toList(growable: false),
    );
    await _persist();
  }

  Future<void> _persist() async {
    final raw = jsonEncode(
      _workflows.map((w) => w.toJson()).toList(growable: false),
    );
    await _prefs.setString(_workflowsKey, raw);
  }

  Map<String, Object?> _stringKeyed(Map raw) => <String, Object?>{
    for (final entry in raw.entries) entry.key.toString(): entry.value,
  };
}

/// A sequence of tool calls executed in order. Each step's output is injected
/// into the next step's arguments as `previous_result`.
class Workflow {
  const Workflow({
    required this.id,
    required this.name,
    this.description = '',
    required this.steps,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String description;
  final List<WorkflowStep> steps;
  final bool enabled;

  factory Workflow.fromJson(Map<String, Object?> json) => Workflow(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    description: json['description']?.toString() ?? '',
    enabled: json['enabled'] == true,
    steps: (json['steps'] as List<dynamic>? ?? const <dynamic>[])
        .map((e) => WorkflowStep.fromJson(_sk(e as Map)))
        .toList(growable: false),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'description': description,
    'enabled': enabled,
    'steps': steps.map((s) => s.toJson()).toList(growable: false),
  };

  static Map<String, Object?> _sk(Map raw) => <String, Object?>{
    for (final e in raw.entries) e.key.toString(): e.value,
  };
}

enum StepFailurePolicy { stop, continueOn }

class WorkflowStep {
  const WorkflowStep({
    required this.id,
    required this.toolName,
    required this.args,
    this.maxRetries = 0,
    this.onFailure = StepFailurePolicy.stop,
  });

  final String id;
  final String toolName;
  final Map<String, dynamic> args;
  final int maxRetries;
  final StepFailurePolicy onFailure;

  factory WorkflowStep.fromJson(Map<String, Object?> json) => WorkflowStep(
    id: json['id']?.toString() ?? '',
    toolName: json['toolName']?.toString() ?? '',
    args: _stringKeyed(json['args'] as Map? ?? const {}),
    maxRetries: (json['maxRetries'] as num?)?.toInt() ?? 0,
    onFailure: (json['onFailure'] == 'continue' ||
            json['onFailure'] == 'continueOn')
        ? StepFailurePolicy.continueOn
        : StepFailurePolicy.stop,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'toolName': toolName,
    'args': args,
    'maxRetries': maxRetries,
    'onFailure': onFailure.name,
  };

  static Map<String, dynamic> _stringKeyed(Map raw) => <String, dynamic>{
    for (final e in raw.entries) e.key.toString(): e.value,
  };
}

/// Result of executing a single step.
class StepResult {
  const StepResult({
    required this.stepId,
    required this.status,
    this.output,
    this.error,
    this.attempts = 1,
  });

  final String stepId;
  final StepStatus status;
  final String? output;
  final String? error;
  final int attempts;
}

enum StepStatus { success, failed, skipped }

/// Executes a [Workflow] by driving each step through Kelivo's existing tool
/// dispatch handler. The handler is the same closure produced by
/// `ToolHandlerService.buildToolCallHandler`, so workflow steps are subject to
/// the same approval, gating, and routing as ordinary chat tool calls.
class WorkflowRunner {
  /// [toolCallHandler] has the same signature as the closure returned by
  /// `ToolHandlerService.buildToolCallHandler`: `(name, args, {toolCallId})`.
  WorkflowRunner({
    required Future<Object?> Function(
      String name,
      Map<String, dynamic> args, {
      String? toolCallId,
    }) toolCallHandler,
  }) : _handler = toolCallHandler;

  final Future<Object?> Function(
    String name,
    Map<String, dynamic> args, {
    String? toolCallId,
  }) _handler;

  Future<List<StepResult>> run(Workflow workflow) async {
    final results = <StepResult>[];
    String? previousOutput;
    for (final step in workflow.steps) {
      final args = Map<String, dynamic>.from(step.args);
      if (previousOutput != null) {
        args['previous_result'] = previousOutput;
      }
      final result = await _runStep(step, args);
      results.add(result);
      if (result.status == StepStatus.failed &&
          step.onFailure == StepFailurePolicy.stop) {
        // Mark remaining steps as skipped.
        final idx = workflow.steps.indexOf(step);
        for (var i = idx + 1; i < workflow.steps.length; i++) {
          results.add(
            StepResult(
              stepId: workflow.steps[i].id,
              status: StepStatus.skipped,
            ),
          );
        }
        break;
      }
      if (result.status == StepStatus.success) {
        previousOutput = result.output;
      }
    }
    return results;
  }

  Future<StepResult> _runStep(
    WorkflowStep step,
    Map<String, dynamic> args,
  ) async {
    var attempts = 0;
    while (attempts <= step.maxRetries) {
      attempts++;
      try {
        final out = await _handler(
          step.toolName,
          args,
          toolCallId: 'wf_${step.id}_$attempts',
        );
        return StepResult(
          stepId: step.id,
          status: StepStatus.success,
          output: out?.toString(),
          attempts: attempts,
        );
      } catch (e) {
        if (attempts > step.maxRetries) {
          return StepResult(
            stepId: step.id,
            status: StepStatus.failed,
            error: e.toString(),
            attempts: attempts,
          );
        }
        // Exponential-ish backoff between retries.
        await Future<void>.delayed(Duration(milliseconds: 200 * attempts));
      }
    }
    return StepResult(
      stepId: step.id,
      status: StepStatus.failed,
      error: 'max retries exceeded',
      attempts: attempts,
    );
  }
}
