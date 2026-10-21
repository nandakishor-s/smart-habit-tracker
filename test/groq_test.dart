import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_track/features/coach/data/coach_model.dart';
import 'package:habit_track/features/coach/data/groq_client.dart';
import 'package:habit_track/features/coach/domain/coach_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('Groq translation', () {
    test('Tool round trip keeps call ids and order', () {
      final turn = parseGroqResponse({
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'id': 'call_a',
                  'type': 'function',
                  'function': {'name': 'get_day_log', 'arguments': '{"date":"2026-10-20"}'},
                },
              ],
            },
          },
        ],
        'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
      });
      expect(turn.functionCalls.single.name, 'get_day_log');
      expect(turn.functionCalls.single.args, {'date': '2026-10-20'});
      expect(turn.usage.outputTokens, 5);

      final messages = toGroqMessages('sys', [
        {
          'role': 'user',
          'parts': [
            {'text': 'What did I do yesterday?'}
          ],
        },
        turn.rawContent,
        {
          'role': 'user',
          'parts': [
            {
              'functionResponse': {
                'name': 'get_day_log',
                'response': {'done': []},
              }
            }
          ],
        },
      ]);
      expect(messages.map((m) => m['role']), ['system', 'user', 'assistant', 'tool']);
      expect((messages[2]['tool_calls'] as List).single['id'], 'call_a');
      expect(messages[3]['tool_call_id'], 'call_a');
      expect(jsonDecode(messages[3]['content'] as String), {'done': []});
    });

    test('Coach tool declarations convert to OpenAI tools', () {
      final tools = CoachTools.declarations.map(toGroqTool).toList();
      for (final t in tools) {
        expect(t['type'], 'function');
        expect((t['function'] as Map)['parameters'], isA<Map>());
      }
    });

    test('Picks a supported model when the saved one is retired', () {
      expect(GroqClient.pickModel('old-model', ['llama-3.1-8b-instant', 'openai/gpt-oss-120b']),
          'openai/gpt-oss-120b');
      expect(GroqClient.pickModel(GroqClient.defaultModel, [GroqClient.defaultModel]),
          GroqClient.defaultModel);
    });

    test('Rejected key is reported as a Groq error', () async {
      final client = GroqClient(
        apiKey: 'bad',
        model: GroqClient.defaultModel,
        httpClient: MockClient((_) async => http.Response(
            jsonEncode({'error': {'message': 'Invalid API Key'}}), 401)),
      );
      await expectLater(
        client.generate(systemInstruction: 's', contents: []),
        throwsA(isA<CoachModelException>()
            .having((e) => e.kind, 'kind', CoachErrorKind.invalidKey)
            .having((e) => e.userMessage, 'userMessage', contains('Groq'))),
      );
    });
  });

  group('FallbackCoachModel', () {
    test('Switches to the backup when the primary is busy, and stays there', () async {
      final primary = _FakeModel(fail: CoachErrorKind.server);
      final backup = _FakeModel();
      final model = FallbackCoachModel(primary, backup);

      expect((await _ask(model)).text, 'ok');
      expect((await _ask(model)).text, 'ok');
      expect(primary.calls, 1);
      expect(backup.calls, 2);
    });

    test('Does not hide a rejected key behind the backup', () async {
      final model = FallbackCoachModel(_FakeModel(fail: CoachErrorKind.invalidKey), _FakeModel());
      await expectLater(_ask(model), throwsA(isA<CoachModelException>()));
    });
  });
}

Future<ModelTurn> _ask(CoachModel m) => m.generate(systemInstruction: 's', contents: []);

class _FakeModel implements CoachModel {
  final CoachErrorKind? fail;
  int calls = 0;

  _FakeModel({this.fail});

  @override
  Future<ModelTurn> generate({
    required String systemInstruction,
    required List<Map<String, dynamic>> contents,
    List<Map<String, dynamic>> tools = const [],
  }) async {
    calls++;
    if (fail != null) throw CoachModelException(fail!, 'x');
    return const ModelTurn(rawContent: {}, text: 'ok', functionCalls: []);
  }
}
