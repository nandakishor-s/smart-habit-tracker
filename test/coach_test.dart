import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_track/core/constants/habit_styles.dart';
import 'package:habit_track/core/utils/date_utils.dart';
import 'package:habit_track/features/coach/data/coach_model.dart';
import 'package:habit_track/features/coach/data/gemini_client.dart';
import 'package:habit_track/features/coach/domain/chat_message.dart';
import 'package:habit_track/features/coach/domain/coach_engine.dart';
import 'package:habit_track/features/coach/domain/coach_tools.dart';
import 'package:habit_track/features/coach/domain/plan_executor.dart';
import 'package:habit_track/features/coach/domain/plan_item.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:habit_track/models/habit.dart';
import 'package:habit_track/models/habit_log.dart';
import 'package:habit_track/providers/habit_provider.dart';

final today = DateTime(2026, 3, 31, 10);
DateTime daysAgo(int n) => DateTime(today.year, today.month, today.day - n);

final workout = Habit(id: 'h1', title: 'Workout', createdAt: daysAgo(10));
final reading = Habit(id: 'h2', title: 'Read', createdAt: daysAgo(3));

CoachTools toolsWith({int pending = 0, Map<String, HabitLog> logs = const {}}) =>
    CoachTools(habits: [workout, reading], logs: logs, today: today, pendingCount: pending);

/// In-memory [HabitActions] for executor tests.
class FakeHabitActions implements HabitActions {
  final List<Habit> habits;
  final Map<String, Set<String>> completions = {};

  FakeHabitActions(List<Habit> initial) : habits = [...initial];

  @override
  List<Habit> get currentHabits => habits;

  @override
  Future<void> addHabit(Habit habit) async => habits.add(habit);

  @override
  Future<void> updateHabit(Habit habit) async {
    habits[habits.indexWhere((h) => h.id == habit.id)] = habit;
  }

  @override
  Future<void> deleteHabit(String habitId) async => habits.removeWhere((h) => h.id == habitId);

  @override
  Future<void> setHabitCompletion(DateTime date, String habitId, bool completed) async {
    final set = completions.putIfAbsent(AppDateUtils.toDateKey(date), () => {});
    completed ? set.add(habitId) : set.remove(habitId);
  }
}

/// Returns scripted turns in order and records what it was sent.
class FakeModel implements CoachModel {
  final List<ModelTurn> turns;
  final List<List<Map<String, dynamic>>> requests = [];

  FakeModel(this.turns);

  @override
  Future<ModelTurn> generate({
    required String systemInstruction,
    required List<Map<String, dynamic>> contents,
    List<Map<String, dynamic>> tools = const [],
  }) async {
    requests.add(List.of(contents));
    return turns[requests.length - 1];
  }
}

ModelTurn textTurn(String text) => ModelTurn(
      rawContent: {'role': 'model', 'parts': [{'text': text}]},
      text: text,
      functionCalls: const [],
    );

ModelTurn callTurn(String name, Map<String, dynamic> args) => ModelTurn(
      rawContent: {
        'role': 'model',
        'parts': [
          {'functionCall': {'name': name, 'args': args}, 'thoughtSignature': 'sig'}
        ]
      },
      text: '',
      functionCalls: [FunctionCall(name, args)],
    );

void main() {
  group('CoachTools proposals', () {
    test('Add habit queues a plan item with named icon and color', () {
      final r = toolsWith().handle('propose_add_habit',
          {'title': 'Evening walk', 'icon': 'run', 'color': 'teal', 'reason': 'Gentle cardio'});

      expect(r.planItem?.type, PlanItemType.addHabit);
      expect(r.planItem?.iconCodePoint, habitIconOptions['run']);
      expect(r.planItem?.colorValue, habitColorOptions['teal']);
      expect(r.response['status'], 'queued_for_user_approval');
    });

    test('Rejects a duplicate habit title', () {
      final r = toolsWith().handle('propose_add_habit', {'title': 'workout', 'reason': ''});
      expect(r.planItem, isNull);
      expect(r.response['error'], contains('already exists'));
    });

    test('Rejects unknown habit ids', () {
      final r = toolsWith().handle('propose_delete_habit', {'habit_id': 'nope', 'reason': ''});
      expect(r.planItem, isNull);
      expect(r.response['error'], contains('CURRENT HABITS'));
    });

    test('Log change rejects future dates and dates before the habit existed', () {
      final tools = toolsWith();
      final future = tools.handle('propose_log_change', {
        'habit_id': 'h1',
        'date': AppDateUtils.toDateKey(daysAgo(-1)),
        'completed': true,
        'reason': '',
      });
      final tooEarly = tools.handle('propose_log_change', {
        'habit_id': 'h2',
        'date': AppDateUtils.toDateKey(daysAgo(5)),
        'completed': true,
        'reason': '',
      });
      final ok = tools.handle('propose_log_change', {
        'habit_id': 'h1',
        'date': AppDateUtils.toDateKey(daysAgo(1)),
        'completed': true,
        'reason': 'Forgot to tick',
      });

      expect(future.response['error'], contains('future'));
      expect(tooEarly.response['error'], contains('did not exist'));
      expect(ok.planItem?.dateKey, AppDateUtils.toDateKey(daysAgo(1)));
    });

    test('Update with nothing to change is rejected', () {
      final r = toolsWith().handle('propose_update_habit', {'habit_id': 'h1', 'reason': ''});
      expect(r.response['error'], 'Nothing to change');
    });

    test('Refuses new proposals once the plan is full', () {
      final r = toolsWith(pending: CoachTools.maxPendingItems)
          .handle('propose_add_habit', {'title': 'X', 'reason': ''});
      expect(r.planItem, isNull);
    });
  });

  group('Short habit ids', () {
    test('The model sees h1, h2 and proposals map them back to real ids', () {
      final a = Habit(id: '2f1c9d1e-aaaa-bbbb-cccc-000000000001', title: 'A', createdAt: daysAgo(5));
      final b = Habit(id: '2f1c9d1e-aaaa-bbbb-cccc-000000000002', title: 'B', createdAt: daysAgo(5));
      expect(CoachTools.snapshot([a, b]).map((h) => h['id']), ['h1', 'h2']);

      final tools = CoachTools(habits: [a, b], logs: const {}, today: today);
      final r = tools.handle('propose_delete_habit', {'habit_id': 'h2', 'reason': ''});
      expect(r.planItem!.habitId, b.id);
      // Real ids still work.
      expect(tools.handle('propose_delete_habit', {'habit_id': a.id, 'reason': ''}).planItem!.habitId, a.id);
      expect(tools.handle('propose_delete_habit', {'habit_id': 'h9', 'reason': ''}).planItem, isNull);
    });
  });

  group('Analytics', () {
    test('History string marks perfect, missed and today', () {
      final key = AppDateUtils.toDateKey(daysAgo(1));
      final logs = {key: HabitLog(dateKey: key, completedHabitIds: {'h1', 'h2'})};
      final a = buildAnalytics(habits: [workout, reading], logs: logs, today: today, days: 3);

      // 3 days ago: missed (both habits exist), 2 ago: missed, 1 ago: perfect, today.
      // First miss is saved by the starting freeze only if a streak was running (it wasn't).
      expect(a['history_oldest_to_today'], 'MMPT');
      expect(a['current_streak'], 1);
    });
  });

  group('PlanExecutor', () {
    test('Applies only selected items', () async {
      final actions = FakeHabitActions([workout, reading]);
      final items = [
        const PlanItem(id: 'a', type: PlanItemType.addHabit, title: 'Walk'),
        const PlanItem(id: 'b', type: PlanItemType.deleteHabit, habitId: 'h2', selected: false),
        const PlanItem(id: 'c', type: PlanItemType.updateHabit, habitId: 'h1', title: 'Gym'),
      ];

      final result = await PlanExecutor(actions, now: () => today).apply(items);

      expect(result.applied.map((i) => i.id), containsAll(['a', 'c']));
      expect(actions.habits.map((h) => h.title), ['Gym', 'Read', 'Walk']);
    });

    test('Skips items whose habit was removed earlier in the plan', () async {
      final actions = FakeHabitActions([workout]);
      final items = [
        const PlanItem(id: 'del', type: PlanItemType.deleteHabit, habitId: 'h1'),
        const PlanItem(
            id: 'log', type: PlanItemType.logChange, habitId: 'h1', dateKey: '2026-03-30', completed: true),
      ];
      // Log changes run before deletes, so both succeed.
      final result = await PlanExecutor(actions).apply(items);

      expect(result.skipped, isEmpty);
      expect(actions.completions['2026-03-30'], {'h1'});
      expect(actions.habits, isEmpty);

      final again = await PlanExecutor(actions).apply([items.first]);
      expect(again.skipped.values.single, 'Habit no longer exists');
    });
  });

  group('CoachEngine', () {
    test('Runs tool calls, collects proposals and returns the final text', () async {
      final model = FakeModel([
        callTurn('list_habits', {}),
        callTurn('propose_add_habit', {'title': 'Stretch', 'reason': 'Recovery'}),
        textTurn('Added a stretch habit to your plan.'),
      ]);

      final reply = await CoachEngine(model).reply(
        history: const [],
        userText: 'Add stretching',
        tools: toolsWith(),
        systemInstruction: 'test',
      );

      expect(reply.text, 'Added a stretch habit to your plan.');
      expect(reply.newPlanItems.single.title, 'Stretch');
      expect(model.requests.length, 3);
      // The model's raw content (with its thought signature) is sent back as-is,
      // followed by the function response.
      final last = model.requests.last;
      expect(last[last.length - 2]['parts'][0]['thoughtSignature'], 'sig');
      expect(last.last['parts'][0]['functionResponse']['name'], 'propose_add_habit');
    });

    test('Falls back to a helpful message when the model returns no text', () async {
      final model = FakeModel([
        callTurn('propose_add_habit', {'title': 'Stretch', 'reason': ''}),
        textTurn(''),
      ]);
      final reply = await CoachEngine(model).reply(
        history: const [],
        userText: 'hi',
        tools: toolsWith(),
        systemInstruction: 'test',
      );
      expect(reply.text, contains('press Schedule'));
    });

    test('Stops after proposals that come with a message, saving a request', () async {
      final turn = ModelTurn(
        rawContent: const {'role': 'model', 'parts': []},
        text: 'Here is your morning plan.',
        functionCalls: const [
          FunctionCall('propose_add_habit', {'title': 'Wake at 4:30', 'reason': ''}),
          FunctionCall('propose_add_habit', {'title': 'Drink water', 'reason': ''}),
        ],
      );
      final model = FakeModel([turn]);
      final reply = await CoachEngine(model).reply(
        history: const [],
        userText: 'Morning routine',
        tools: toolsWith(),
        systemInstruction: 'test',
      );
      expect(model.requests.length, 1);
      expect(reply.text, 'Here is your morning plan.');
      expect(reply.newPlanItems.map((i) => i.title), ['Wake at 4:30', 'Drink water']);
    });

    test('Shortens older coach replies but keeps the latest one whole', () {
      ChatMessage m(ChatRole r, String t) => ChatMessage(role: r, text: t, time: today);
      final long = 'x' * 1000;
      final contents = CoachEngine.buildContents([
        m(ChatRole.user, 'a'),
        m(ChatRole.coach, long),
        m(ChatRole.user, 'b'),
        m(ChatRole.coach, long),
      ]);
      expect((contents[1]['parts'][0]['text'] as String).length, CoachEngine.oldReplyChars + 1);
      expect(contents[3]['parts'][0]['text'], long);
    });

    test('Builds contents: merges same-role turns, drops leading model turns, windows history', () {
      ChatMessage m(ChatRole r, String t) => ChatMessage(role: r, text: t, time: today);
      final contents = CoachEngine.buildContents([
        m(ChatRole.coach, 'welcome'),
        m(ChatRole.user, 'a'),
        m(ChatRole.event, 'plan applied'),
        m(ChatRole.coach, 'b'),
      ]);

      expect(contents.length, 2);
      expect(contents.first['role'], 'user');
      expect((contents.first['parts'] as List).length, 2);
      expect(contents.first['parts'][1]['text'], '[App note] plan applied');

      final many = [for (var i = 0; i < 30; i++) m(i.isEven ? ChatRole.user : ChatRole.coach, '$i')];
      final windowed = CoachEngine.buildContents(many);
      expect(windowed.length, CoachEngine.historyWindow);
    });
  });

  group('Gemini response parsing', () {
    test('Extracts text, function calls and usage, skipping thoughts', () {
      final turn = parseGenerateResponse({
        'candidates': [
          {
            'content': {
              'role': 'model',
              'parts': [
                {'text': 'thinking...', 'thought': true},
                {'text': 'Sure!'},
                {
                  'functionCall': {'name': 'get_analytics', 'args': {'days': 7}},
                  'thoughtSignature': 'abc'
                },
              ]
            },
            'finishReason': 'STOP'
          }
        ],
        'usageMetadata': {'promptTokenCount': 100, 'candidatesTokenCount': 20, 'thoughtsTokenCount': 5},
      });

      expect(turn.text, 'Sure!');
      expect(turn.functionCalls.single.name, 'get_analytics');
      expect(turn.functionCalls.single.args['days'], 7);
      expect(turn.usage.promptTokens, 100);
      expect(turn.usage.outputTokens, 25);
      expect((turn.rawContent['parts'] as List)[2]['thoughtSignature'], 'abc');
    });

    test('Blocked prompt throws a blocked error', () {
      expect(
        () => parseGenerateResponse({'promptFeedback': {'blockReason': 'SAFETY'}}),
        throwsA(isA<CoachModelException>().having((e) => e.kind, 'kind', CoachErrorKind.blocked)),
      );
    });
  });

  group('GeminiClient overload handling', () {
    final ok = jsonEncode({
      'candidates': [
        {
          'content': {
            'role': 'model',
            'parts': [
              {'text': 'Hi!'}
            ]
          }
        }
      ]
    });
    final busy = jsonEncode({
      'error': {'code': 503, 'message': 'high demand', 'status': 'UNAVAILABLE'}
    });

    GeminiClient clientWith(http.Response Function(String model) respond, List<String> calls) =>
        GeminiClient(
          apiKey: 'test',
          model: GeminiClient.defaultModel,
          retryDelay: Duration.zero,
          httpClient: MockClient((req) async {
            final model = req.url.pathSegments.last.split(':').first;
            calls.add(model);
            return respond(model);
          }),
        );

    Future<ModelTurn> hi(GeminiClient c) => c.generate(systemInstruction: 's', contents: [
          {
            'role': 'user',
            'parts': [
              {'text': 'hi'}
            ]
          }
        ]);

    test('Falls back to the lighter model when the default stays overloaded', () async {
      final calls = <String>[];
      final client = clientWith(
          (m) => m == GeminiClient.fallbackModel ? http.Response(ok, 200) : http.Response(busy, 503),
          calls);
      final turn = await hi(client);
      expect(turn.text, 'Hi!');
      expect(calls, [GeminiClient.defaultModel, GeminiClient.defaultModel, GeminiClient.fallbackModel]);
      expect(client.activeModel, GeminiClient.fallbackModel);

      // The rest of the reply sticks to the model that answered.
      await hi(client);
      expect(calls.last, GeminiClient.fallbackModel);
    });

    test('Recovers on a quick retry without switching model', () async {
      final calls = <String>[];
      var first = true;
      final client = clientWith((m) {
        if (first) {
          first = false;
          return http.Response(busy, 503);
        }
        return http.Response(ok, 200);
      }, calls);
      expect((await hi(client)).text, 'Hi!');
      expect(calls, [GeminiClient.defaultModel, GeminiClient.defaultModel]);
    });

    test('Reports a server error when both models are overloaded', () async {
      final client = clientWith((_) => http.Response(busy, 503), []);
      expect(
        () => hi(client),
        throwsA(isA<CoachModelException>().having((e) => e.kind, 'kind', CoachErrorKind.server)),
      );
    });

    test('Does not retry a rejected key', () async {
      final calls = <String>[];
      final client = clientWith(
          (_) => http.Response(jsonEncode({'error': {'message': 'API key not valid', 'status': 'INVALID_ARGUMENT'}}), 400),
          calls);
      await expectLater(hi(client), throwsA(isA<CoachModelException>()));
      expect(calls.length, 1);
    });
  });

  test('Habits are in the prompt, so list_habits is not offered as a tool', () {
    final names = CoachTools.declarations.map((d) => d['name']).toList();
    expect(names, isNot(contains('list_habits')));
    expect(names, containsAll(['get_analytics', 'get_day_log', 'propose_add_habit']));
  });
}
