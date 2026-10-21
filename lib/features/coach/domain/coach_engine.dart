import 'dart:convert';

import '../../../core/utils/date_utils.dart';
import '../data/coach_model.dart';
import 'chat_message.dart';
import 'coach_tools.dart';
import 'plan_item.dart';

class EngineReply {
  final String text;
  final List<PlanItem> newPlanItems;

  const EngineReply(this.text, this.newPlanItems);
}

/// Runs one coach turn: sends the chat to the model, executes tool calls in a
/// loop, and collects proposed plan items. Pure Dart, so it is unit-testable
/// with a fake [CoachModel].
class CoachEngine {
  /// Chat messages sent as context (keeps requests small on the free tier).
  static const int historyWindow = 8;

  /// Older coach replies are cut to this many characters; the latest one is
  /// kept whole. Long replies were the biggest part of every request.
  static const int oldReplyChars = 280;

  /// Max model requests per user message (each tool round is one request).
  static const int maxRounds = 5;

  final CoachModel model;

  /// Called after every successful request, e.g. for usage tracking.
  final void Function(TokenUsage usage)? onUsage;

  CoachEngine(this.model, {this.onUsage});

  Future<EngineReply> reply({
    required List<ChatMessage> history,
    required String userText,
    required CoachTools tools,
    required String systemInstruction,
  }) async {
    final contents = buildContents([
      ...history,
      ChatMessage(role: ChatRole.user, text: userText, time: DateTime.now()),
    ]);
    final proposed = <PlanItem>[];
    final textParts = <String>[];

    for (var round = 0; round < maxRounds; round++) {
      final turn = await model.generate(
        systemInstruction: systemInstruction,
        contents: contents,
        tools: CoachTools.declarations,
      );
      onUsage?.call(turn.usage);
      if (turn.text.isNotEmpty) textParts.add(turn.text);
      if (turn.functionCalls.isEmpty) break;

      // Only proposals plus a message for the user: the reply is complete, so
      // skip the extra request that would just acknowledge the tool results.
      final onlyProposals = turn.functionCalls.every((c) => c.name.startsWith('propose_'));
      if (onlyProposals && turn.text.isNotEmpty) {
        for (final call in turn.functionCalls) {
          _runTool(tools, call, proposed);
        }
        break;
      }

      contents.add(turn.rawContent);
      contents.add({
        'role': 'user',
        'parts': [
          for (final call in turn.functionCalls)
            {
              'functionResponse': {
                'name': call.name,
                'response': _runTool(tools, call, proposed),
              }
            }
        ],
      });
    }

    var text = textParts.join('\n\n').trim();
    if (text.isEmpty) {
      text = proposed.isEmpty
          ? "Sorry, I couldn't finish that. Could you try asking again?"
          : "I've added ${proposed.length} change${proposed.length == 1 ? '' : 's'} "
              'to your plan. Review them and press Schedule when you are happy.';
    }
    return EngineReply(text, proposed);
  }

  Map<String, dynamic> _runTool(
      CoachTools tools, FunctionCall call, List<PlanItem> proposed) {
    // Count proposals from this turn too, so the plan size limit holds.
    final result = CoachTools(
      habits: tools.habits,
      logs: tools.logs,
      today: tools.today,
      pendingCount: tools.pendingCount + proposed.length,
    ).handle(call.name, call.args);
    if (result.planItem != null) proposed.add(result.planItem!);
    return result.response;
  }

  /// Converts the last [historyWindow] chat messages to Gemini `contents`.
  /// Merges consecutive same-role messages and makes sure the first turn is
  /// from the user, as the API expects.
  static List<Map<String, dynamic>> buildContents(List<ChatMessage> messages) {
    final window = messages.length > historyWindow
        ? messages.sublist(messages.length - historyWindow)
        : messages;

    final contents = <Map<String, dynamic>>[];
    final lastCoach = window.lastIndexWhere((m) => m.role == ChatRole.coach);
    for (final (i, m) in window.indexed) {
      final role = m.role == ChatRole.coach ? 'model' : 'user';
      var text = m.role == ChatRole.event ? '[App note] ${m.text}' : m.text;
      if (m.role == ChatRole.coach && i != lastCoach && text.length > oldReplyChars) {
        text = '${text.substring(0, oldReplyChars)}…';
      }
      if (contents.isEmpty && role == 'model') continue;
      if (contents.isNotEmpty && contents.last['role'] == role) {
        (contents.last['parts'] as List).add({'text': text});
      } else {
        contents.add({
          'role': role,
          'parts': [
            {'text': text}
          ],
        });
      }
    }
    return contents;
  }
}

/// The coach's instructions plus a compact snapshot of the user's data, so
/// simple questions need no extra tool round trips.
String buildSystemInstruction({
  required DateTime now,
  required Map<String, dynamic> analyticsSnapshot,
  required List<Map<String, dynamic>> habitsSnapshot,
}) {
  return '''
You are "Coach", a warm, practical habit coach inside the Habit Track app.
Today is ${AppDateUtils.formatHeaderDate(now)} (${AppDateUtils.toDateKey(now)}).

HOW THE APP WORKS
- Every habit is daily. A day is "perfect" only when ALL habits are done.
- The streak counts consecutive perfect days. Today never breaks the streak while in progress.
- Streak freezes: the user starts with 1, earns 1 for every 7 streak days, holds at most 2. A missed past day automatically uses a freeze and keeps the streak (without adding to it).
- Habits do not have specific weekdays or reminder times yet. If the user wants those, say they are coming soon and suggest a daily version that fits.

YOUR JOB
- Help the user build realistic routines, stay motivated, and understand their progress.
- Ask 1-2 short clarifying questions before proposing a plan, unless the request is already clear.
- Prefer few, small, specific habits. Too many daily habits makes perfect days hard, so warn when the list is getting long.
- CURRENT HABITS and PROGRESS below are complete and up to date. Answer from them directly. Call get_analytics only for more than 14 days, and get_day_log only for one specific date.

CHANGING DATA
- You can NOT change anything directly. Use the propose_* tools to queue changes. The user reviews them and presses "Schedule" to apply.
- Never say a change is done. Say it is in the plan, waiting for them to Schedule.
- Use exact habit ids from the data. Propose a delete only when the user clearly wants a habit gone.
- When proposing several changes, call all the propose_* tools together in one turn, not one per turn, and write your message to the user in that same turn.

STYLE
- Plain text only, no markdown symbols like ** or #. Short paragraphs; use "- " for lists.
- Keep replies under about 120 words unless the user asks for detail.
- Be encouraging but honest. Celebrate streaks and freezes earned.

CURRENT HABITS
${jsonEncode(habitsSnapshot)}

PROGRESS (last 14 days)
${jsonEncode(analyticsSnapshot)}
''';
}
