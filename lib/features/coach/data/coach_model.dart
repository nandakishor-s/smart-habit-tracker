/// Provider-agnostic interface for the coach's language model.
///
/// Implemented by [GeminiClient] and [GroqClient]; [FallbackCoachModel] chains
/// two of them. Moving to Firebase AI Logic for a Play Store release only
/// needs a new implementation.
abstract class CoachModel {
  /// Sends one request. [contents] uses the Gemini `contents` JSON shape
  /// (`{role, parts: [...]}`); [tools] are Gemini function declarations.
  Future<ModelTurn> generate({
    required String systemInstruction,
    required List<Map<String, dynamic>> contents,
    List<Map<String, dynamic>> tools = const [],
  });
}

class FunctionCall {
  final String name;
  final Map<String, dynamic> args;

  const FunctionCall(this.name, this.args);
}

class TokenUsage {
  final int promptTokens;
  final int outputTokens;

  const TokenUsage({this.promptTokens = 0, this.outputTokens = 0});
}

class ModelTurn {
  /// The model's raw `content` object. It must be sent back unchanged in the
  /// next request, because it can carry thought signatures that Gemini
  /// requires for function calling.
  final Map<String, dynamic> rawContent;
  final String text;
  final List<FunctionCall> functionCalls;
  final TokenUsage usage;

  const ModelTurn({
    required this.rawContent,
    required this.text,
    required this.functionCalls,
    this.usage = const TokenUsage(),
  });
}

enum CoachErrorKind { invalidKey, rateLimited, network, blocked, server, unknown }

class CoachModelException implements Exception {
  final CoachErrorKind kind;
  final String message;

  /// Shown in [userMessage], e.g. "Gemini" or "Groq".
  final String provider;

  const CoachModelException(this.kind, this.message, {this.provider = 'Gemini'});

  /// Worth trying another model or provider: overloaded, slow or out of quota.
  bool get isBusy =>
      kind == CoachErrorKind.server ||
      kind == CoachErrorKind.rateLimited ||
      (kind == CoachErrorKind.network && message == 'Request timed out');

  /// Short, friendly text for the chat UI.
  String get userMessage {
    switch (kind) {
      case CoachErrorKind.invalidKey:
        return 'Your $provider API key was rejected. Check it in Settings.';
      case CoachErrorKind.rateLimited:
        return '$provider free-tier limit reached for now. Wait a minute and try again.';
      case CoachErrorKind.network:
        return message == 'Request timed out'
            ? '$provider took too long to answer. Try again.'
            : 'No connection to $provider. Check your internet and try again.';
      case CoachErrorKind.blocked:
        return '$provider declined to answer that. Try rephrasing.';
      case CoachErrorKind.server:
        return '$provider is overloaded right now. Try again in a minute.';
      case CoachErrorKind.unknown:
        return '$provider: $message';
    }
  }

  @override
  String toString() => 'CoachModelException($kind): $message';
}

/// Uses [primary], and switches to [backup] for the rest of the reply when
/// [primary] is busy. Errors other than "busy" are reported as they are.
class FallbackCoachModel implements CoachModel {
  final CoachModel primary;
  final CoachModel backup;
  bool _onBackup = false;

  FallbackCoachModel(this.primary, this.backup);

  @override
  Future<ModelTurn> generate({
    required String systemInstruction,
    required List<Map<String, dynamic>> contents,
    List<Map<String, dynamic>> tools = const [],
  }) async {
    if (!_onBackup) {
      try {
        return await primary.generate(
            systemInstruction: systemInstruction, contents: contents, tools: tools);
      } on CoachModelException catch (e) {
        if (!e.isBusy) rethrow;
        _onBackup = true;
      }
    }
    return backup.generate(systemInstruction: systemInstruction, contents: contents, tools: tools);
  }
}
