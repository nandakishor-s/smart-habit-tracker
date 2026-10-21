import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'coach_model.dart';

/// Calls Groq's OpenAI-compatible chat API (free key from console.groq.com).
///
/// The coach speaks the Gemini `contents` shape, so requests and replies are
/// translated here. Tool call ids are kept on the `functionCall` parts.
class GroqClient implements CoachModel {
  static const String provider = 'Groq';
  static const String defaultModel = 'llama-3.3-70b-versatile';

  /// Tried in order when the saved model is no longer offered.
  static const List<String> preferredModels = [
    defaultModel,
    'openai/gpt-oss-120b',
    'openai/gpt-oss-20b',
    'llama-3.1-8b-instant',
  ];

  static const String _base = 'https://api.groq.com/openai/v1';
  static const Duration _timeout = Duration(seconds: 30);

  final String apiKey;
  final String model;
  final http.Client _http;

  GroqClient({required this.apiKey, required this.model, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      };

  void close() => _http.close();

  @override
  Future<ModelTurn> generate({
    required String systemInstruction,
    required List<Map<String, dynamic>> contents,
    List<Map<String, dynamic>> tools = const [],
  }) async {
    final body = {
      'model': model,
      'messages': toGroqMessages(systemInstruction, contents),
      if (tools.isNotEmpty) 'tools': tools.map(toGroqTool).toList(),
      'temperature': 0.7,
    };
    final json = await _send(() => _http.post(
          Uri.parse('$_base/chat/completions'),
          headers: _headers,
          body: jsonEncode(body),
        ));
    return parseGroqResponse(json);
  }

  /// Chat model ids for this key. Also a cheap way to check that a key works.
  Future<List<String>> listModels() async {
    final json = await _send(() => _http.get(Uri.parse('$_base/models'), headers: _headers));
    const notChat = ['whisper', 'guard', 'tts', 'playai', 'orpheus', 'distil'];
    return ((json['data'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .where((m) => m['active'] != false)
        .map((m) => m['id'] as String)
        .where((id) => !notChat.any(id.contains))
        .toList()
      ..sort();
  }

  /// The saved model if this key still offers it, else the best available one.
  static String pickModel(String saved, List<String> available) {
    if (available.isEmpty || available.contains(saved)) return saved;
    return preferredModels.firstWhere(available.contains, orElse: () => available.first);
  }

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() request) async {
    final http.Response res;
    final watch = Stopwatch()..start();
    try {
      res = await request().timeout(_timeout);
      debugPrint('Groq ${res.statusCode} in ${watch.elapsedMilliseconds} ms');
    } on SocketException catch (e) {
      throw CoachModelException(CoachErrorKind.network, e.message, provider: provider);
    } on TimeoutException {
      throw const CoachModelException(CoachErrorKind.network, 'Request timed out',
          provider: provider);
    } on http.ClientException catch (e) {
      throw CoachModelException(CoachErrorKind.network, e.message, provider: provider);
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
    final kind = switch (res.statusCode) {
      401 || 403 => CoachErrorKind.invalidKey,
      429 => CoachErrorKind.rateLimited,
      >= 500 => CoachErrorKind.server,
      _ => CoachErrorKind.unknown,
    };
    throw CoachModelException(kind, message, provider: provider);
  }
}

/// Gemini function declaration -> OpenAI tool. Public for testing.
Map<String, dynamic> toGroqTool(Map<String, dynamic> declaration) => {
      'type': 'function',
      'function': {
        'name': declaration['name'],
        if (declaration['description'] != null) 'description': declaration['description'],
        'parameters': declaration['parameters'] ?? {'type': 'object', 'properties': {}},
      },
    };

/// Gemini `contents` -> OpenAI `messages`. Function responses are matched to
/// the preceding calls in order. Public for testing.
List<Map<String, dynamic>> toGroqMessages(
    String systemInstruction, List<Map<String, dynamic>> contents) {
  final messages = <Map<String, dynamic>>[
    {'role': 'system', 'content': systemInstruction},
  ];
  final pendingIds = <String>[];
  var callCount = 0;

  for (final content in contents) {
    final parts = (content['parts'] as List? ?? []).cast<Map<String, dynamic>>();
    final text = parts
        .where((p) => p['text'] is String && p['thought'] != true)
        .map((p) => p['text'] as String)
        .join('\n');

    if (content['role'] == 'model') {
      final calls = [
        for (final p in parts)
          if (p['functionCall'] is Map) (p['functionCall'] as Map).cast<String, dynamic>(),
      ];
      final toolCalls = [
        for (final call in calls)
          {
            'id': call['id'] as String? ?? 'call_${callCount++}',
            'type': 'function',
            'function': {
              'name': call['name'],
              'arguments': jsonEncode(call['args'] ?? {}),
            },
          },
      ];
      pendingIds
        ..clear()
        ..addAll(toolCalls.map((c) => c['id'] as String));
      messages.add({
        'role': 'assistant',
        'content': text.isEmpty ? null : text,
        if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
      });
      continue;
    }

    for (final p in parts) {
      final response = p['functionResponse'] as Map?;
      if (response == null) continue;
      messages.add({
        'role': 'tool',
        'tool_call_id': pendingIds.isNotEmpty ? pendingIds.removeAt(0) : 'call_${callCount++}',
        'content': jsonEncode(response['response']),
      });
    }
    if (text.isNotEmpty) messages.add({'role': 'user', 'content': text});
  }
  return messages;
}

/// OpenAI chat completion -> [ModelTurn] in the Gemini shape. Public for testing.
ModelTurn parseGroqResponse(Map<String, dynamic> json) {
  final choices = (json['choices'] as List? ?? []).cast<Map<String, dynamic>>();
  if (choices.isEmpty) {
    throw const CoachModelException(CoachErrorKind.blocked, 'No response',
        provider: GroqClient.provider);
  }
  final message = (choices.first['message'] as Map).cast<String, dynamic>();
  final text = (message['content'] as String? ?? '').trim();

  final calls = <FunctionCall>[];
  final parts = <Map<String, dynamic>>[
    if (text.isNotEmpty) {'text': text},
  ];
  for (final raw in (message['tool_calls'] as List? ?? []).cast<Map<String, dynamic>>()) {
    final function = (raw['function'] as Map).cast<String, dynamic>();
    Map<String, dynamic> args;
    try {
      args = (jsonDecode(function['arguments'] as String? ?? '{}') as Map).cast<String, dynamic>();
    } catch (_) {
      args = {};
    }
    final name = function['name'] as String;
    calls.add(FunctionCall(name, args));
    parts.add({
      'functionCall': {'id': raw['id'], 'name': name, 'args': args},
    });
  }

  final usage = json['usage'] as Map<String, dynamic>? ?? {};
  return ModelTurn(
    // Marked so Gemini, if it takes over mid-reply, can tell these calls lack
    // its thought signatures (see foreignTurnsAsText).
    rawContent: {'role': 'model', 'producer': GroqClient.provider, 'parts': parts},
    text: text,
    functionCalls: calls,
    usage: TokenUsage(
      promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
    ),
  );
}
