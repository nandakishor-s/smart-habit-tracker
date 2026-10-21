import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'coach_model.dart';

/// Calls the Gemini Developer API (Google AI Studio key) over REST.
///
/// Development-stage only: the key is the user's own, read from secure storage.
class GeminiClient implements CoachModel {
  static const String defaultModel = 'gemini-flash-latest';

  /// Lighter model tried when the chosen one is overloaded (503) or slow.
  static const String fallbackModel = 'gemini-flash-lite-latest';
  static const Duration _retryDelay = Duration(milliseconds: 1500);
  static const String _base = 'https://generativelanguage.googleapis.com/v1beta';
  static const Duration _timeout = Duration(seconds: 30);

  final String apiKey;
  final String model;
  final http.Client _http;

  /// Set once the fallback answered, so the rest of this reply (tool rounds)
  /// stays on one model.
  String? _activeModel;
  final Duration _delay;

  GeminiClient({
    required this.apiKey,
    required this.model,
    http.Client? httpClient,
    Duration retryDelay = _retryDelay,
  })  : _http = httpClient ?? http.Client(),
        _delay = retryDelay;

  /// The model that answered last (differs from [model] after a fallback).
  String get activeModel => _activeModel ?? model;

  /// Releases the HTTP connections. Call once the client is no longer needed.
  void close() => _http.close();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      };

  @override
  Future<ModelTurn> generate({
    required String systemInstruction,
    required List<Map<String, dynamic>> contents,
    List<Map<String, dynamic>> tools = const [],
  }) async {
    final body = {
      'systemInstruction': {
        'parts': [
          {'text': systemInstruction}
        ]
      },
      'contents': contents,
      if (tools.isNotEmpty)
        'tools': [
          {'functionDeclarations': tools}
        ],
      'generationConfig': {'temperature': 0.7},
    };

    final encoded = jsonEncode(body);
    Future<Map<String, dynamic>> call(String m) => _send(() => _http.post(
          Uri.parse('$_base/models/$m:generateContent'),
          headers: _headers,
          body: encoded,
        ));

    final current = activeModel;
    try {
      return parseGenerateResponse(await call(current));
    } on CoachModelException catch (e) {
      if (!_isBusy(e)) rethrow;
      // Overloaded: one quick retry on 503, then the lighter model.
      if (e.kind == CoachErrorKind.server) {
        await Future<void>.delayed(_delay);
        try {
          return parseGenerateResponse(await call(current));
        } on CoachModelException catch (e2) {
          if (!_isBusy(e2)) rethrow;
        }
      }
      if (current == fallbackModel) rethrow;
      debugPrint('Gemini $current busy, falling back to $fallbackModel');
      try {
        final json = await call(fallbackModel);
        _activeModel = fallbackModel;
        return parseGenerateResponse(json);
      } on CoachModelException {
        throw e; // Report the original problem, not the fallback's.
      }
    }
  }

  static bool _isBusy(CoachModelException e) =>
      e.kind == CoachErrorKind.server ||
      (e.kind == CoachErrorKind.network && e.message == 'Request timed out');

  /// Lists model ids that support `generateContent`. Also a cheap way to
  /// check that a key works.
  Future<List<String>> listModels() async {
    final json = await _send(() => _http.get(
          Uri.parse('$_base/models?pageSize=200'),
          headers: _headers,
        ));
    final models = (json['models'] as List? ?? []).cast<Map<String, dynamic>>();
    return models
        .where((m) => (m['supportedGenerationMethods'] as List? ?? [])
            .contains('generateContent'))
        .map((m) => (m['name'] as String).replaceFirst('models/', ''))
        .where((name) => name.contains('gemini'))
        .toList()
      ..sort();
  }

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() request) async {
    final http.Response res;
    final watch = Stopwatch()..start();
    try {
      res = await request().timeout(_timeout);
      debugPrint('Gemini ${res.statusCode} in ${watch.elapsedMilliseconds} ms '
          '(${res.bodyBytes.length} bytes)');
    } on SocketException catch (e) {
      throw CoachModelException(CoachErrorKind.network, e.message);
    } on TimeoutException {
      debugPrint('Gemini timed out after ${watch.elapsedMilliseconds} ms');
      throw const CoachModelException(CoachErrorKind.network, 'Request timed out');
    } on http.ClientException catch (e) {
      throw CoachModelException(CoachErrorKind.network, e.message);
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      json = {};
    }

    if (res.statusCode == 200) return json;

    final error = json['error'] as Map<String, dynamic>? ?? {};
    final message = (error['message'] as String?) ?? 'HTTP ${res.statusCode}';
    final status = error['status'] as String? ?? '';
    if (res.statusCode == 429 || status == 'RESOURCE_EXHAUSTED') {
      throw CoachModelException(CoachErrorKind.rateLimited, message);
    }
    if (res.statusCode == 401 ||
        res.statusCode == 403 ||
        message.contains('API key') ||
        status == 'PERMISSION_DENIED') {
      throw CoachModelException(CoachErrorKind.invalidKey, message);
    }
    if (res.statusCode >= 500) {
      throw CoachModelException(CoachErrorKind.server, message);
    }
    throw CoachModelException(CoachErrorKind.unknown, message);
  }
}

/// Parses a `generateContent` response body. Public for testing.
ModelTurn parseGenerateResponse(Map<String, dynamic> json) {
  final candidates = (json['candidates'] as List? ?? []).cast<Map<String, dynamic>>();
  if (candidates.isEmpty) {
    final reason = (json['promptFeedback'] as Map?)?['blockReason'];
    throw CoachModelException(
        CoachErrorKind.blocked, 'No response${reason != null ? ' ($reason)' : ''}');
  }

  final candidate = candidates.first;
  final content = (candidate['content'] as Map?)?.cast<String, dynamic>() ??
      <String, dynamic>{'role': 'model', 'parts': <dynamic>[]};
  final parts = (content['parts'] as List? ?? []).cast<Map<String, dynamic>>();

  final textBuffer = StringBuffer();
  final calls = <FunctionCall>[];
  for (final part in parts) {
    // Skip internal reasoning parts; only show the answer.
    if (part['thought'] == true) continue;
    if (part['text'] is String) textBuffer.write(part['text']);
    final call = part['functionCall'] as Map<String, dynamic>?;
    if (call != null) {
      calls.add(FunctionCall(
        call['name'] as String,
        (call['args'] as Map?)?.cast<String, dynamic>() ?? {},
      ));
    }
  }

  if (calls.isEmpty && textBuffer.isEmpty) {
    final finish = candidate['finishReason'];
    if (finish == 'SAFETY' || finish == 'PROHIBITED_CONTENT' || finish == 'BLOCKLIST') {
      throw CoachModelException(CoachErrorKind.blocked, 'Blocked ($finish)');
    }
  }

  final usage = json['usageMetadata'] as Map<String, dynamic>? ?? {};
  return ModelTurn(
    rawContent: {'role': 'model', ...content, 'parts': parts},
    text: textBuffer.toString().trim(),
    functionCalls: calls,
    usage: TokenUsage(
      promptTokens: (usage['promptTokenCount'] as num?)?.toInt() ?? 0,
      outputTokens: ((usage['candidatesTokenCount'] as num?)?.toInt() ?? 0) +
          ((usage['thoughtsTokenCount'] as num?)?.toInt() ?? 0),
    ),
  );
}
