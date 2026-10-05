import 'dart:async';
import 'dart:math';

import '../../database/chat_database_repository.dart';
import '../../models/chat_message.dart';

/// Lightweight enhancement layer that reuses Kelivo's existing conversation
/// storage (the `summary` field + `extras` blob) to add two Operit-inspired
/// memory capabilities — WITHOUT introducing a parallel memory subsystem or
/// any new database table.
///
///  1. Auto-summary: when a conversation grows past a threshold, ask the model
///     for a concise running summary and persist it in the conversation extras.
///  2. Simple vector recall: build in-process TF-IDF vectors over the
///     conversation's messages and retrieve the top-K most relevant messages
///     for the current query.
///
/// Both features are opt-in helpers; the core chat pipeline is not modified.
class ConversationMemoryEnhancer {
  ConversationMemoryEnhancer(this._db);

  final ChatDatabaseRepository _db;

  /// Global gate. When false, [autoSummarize] and [recall] become no-ops so the
  /// feature has zero runtime cost. Toggled by SettingsProvider.
  static bool enabled = false;

  static const String _summaryKey = 'auto_summary';
  static const int summaryMessageThreshold = 40;
  static const int recallTopK = 6;

  /// Generates (or refreshes) a running summary for [conversationId] using the
  /// supplied summarisation function. The summary is stored in the
  /// conversation's extras blob, never in a separate table.
  Future<void> autoSummarize({
    required String conversationId,
    required int messageCount,
    required Future<String> Function(List<ChatMessage> messages) summarizer,
  }) async {
    if (!enabled) return;
    if (messageCount < summaryMessageThreshold) return;
    final messages = await _db.getMessagesRange(
      conversationId,
      start: 0,
      limit: 60,
    );
    if (messages.length < summaryMessageThreshold) return;
    final summary = await summarizer(messages);
    await _db.updateConversationExtras(conversationId, (extras) {
      extras[_summaryKey] = summary;
      extras['auto_summary_updated_at'] =
          DateTime.now().millisecondsSinceEpoch;
      return extras;
    });
  }

  /// Returns the stored auto-summary for [conversationId], or null.
  Future<String?> getSummary(String conversationId) async {
    final conversation = await _db.getConversation(conversationId);
    final extras = conversation?.extras;
    if (extras == null) return null;
    final v = extras[_summaryKey];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// Simple vector recall over the conversation's messages using TF-IDF +
  /// cosine similarity. Returns the top-K messages most relevant to [query].
  Future<List<ChatMessage>> recall({
    required String conversationId,
    required String query,
    int limit = recallTopK,
  }) async {
    if (!enabled) return const <ChatMessage>[];
    if (query.trim().isEmpty) return const <ChatMessage>[];
    final messages = await _db.getMessagesRange(
      conversationId,
      start: 0,
      limit: 200,
    );
    if (messages.isEmpty) return const <ChatMessage>[];

    final docs = messages
        .map((m) => m.content.trim())
        .where((c) => c.isNotEmpty)
        .toList(growable: false);
    if (docs.isEmpty) return const <ChatMessage>[];

    final tfidf = _TfIdfIndex.build(docs);
    final queryVec = tfidf.vectorFor(query);
    final scored = <_ScoredMessage>[];
    for (var i = 0; i < docs.length; i++) {
      final sim = _cosine(tfidf.vectorAt(i), queryVec);
      if (sim > 0) scored.add(_ScoredMessage(messages[i], sim));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).map((s) => s.message).toList(growable: false);
  }

  static double _cosine(List<double> a, List<double> b) {
    if (a.length != b.length) return 0;
    var dot = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (sqrt(na) * sqrt(nb));
  }
}

class _ScoredMessage {
  const _ScoredMessage(this.message, this.score);
  final ChatMessage message;
  final double score;
}

/// Minimal in-process TF-IDF index. No native deps, no external model.
class _TfIdfIndex {
  _TfIdfIndex._(this._vocab, this._idf, this._docVectors);

  final Map<String, int> _vocab;
  final List<double> _idf;
  final List<List<double>> _docVectors;

  static _TfIdfIndex build(List<String> docs) {
    final vocab = <String, int>{};
    final tokenized = <List<String>>[];
    for (final doc in docs) {
      final tokens = _tokenize(doc);
      tokenized.add(tokens);
      for (final t in tokens) {
        vocab.putIfAbsent(t, () => vocab.length);
      }
    }
    final vocabSize = vocab.length;
    final df = List<int>.filled(vocabSize, 0);
    for (final tokens in tokenized) {
      final seen = <String>{};
      for (final t in tokens) {
        if (seen.add(t)) df[vocab[t]!]++;
      }
    }
    final n = docs.length;
    final idf = List<double>.generate(
      vocabSize,
      (i) => log((n + 1) / (df[i] + 1)) + 1,
    );
    final vectors = <List<double>>[];
    for (final tokens in tokenized) {
      final tf = List<double>.filled(vocabSize, 0);
      for (final t in tokens) {
        tf[vocab[t]!]++;
      }
      final len = tokens.length;
      if (len > 0) {
        for (var i = 0; i < vocabSize; i++) {
          tf[i] = (tf[i] / len) * idf[i];
        }
      }
      vectors.add(tf);
    }
    return _TfIdfIndex._(vocab, idf, vectors);
  }

  List<double> vectorAt(int i) => _docVectors[i];

  List<double> vectorFor(String text) {
    final tokens = _tokenize(text);
    final vec = List<double>.filled(_vocab.length, 0);
    if (tokens.isEmpty) return vec;
    final tf = <String, int>{};
    for (final t in tokens) {
      tf[t] = (tf[t] ?? 0) + 1;
    }
    final len = tokens.length;
    tf.forEach((t, count) {
      final idx = _vocab[t];
      if (idx != null) {
        vec[idx] = (count / len) * _idf[idx];
      }
    });
    return vec;
  }

  static List<String> _tokenize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty && t.length > 1)
      .toList(growable: false);
}
