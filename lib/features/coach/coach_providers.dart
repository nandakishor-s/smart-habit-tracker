import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/secure_key_store.dart';
import '../../providers/habit_provider.dart';
import 'data/coach_model.dart';
import 'data/gemini_client.dart';
import 'data/groq_client.dart';
import 'data/usage_tracker.dart';
import 'domain/chat_message.dart';
import 'domain/coach_engine.dart';
import 'domain/coach_tools.dart';
import 'domain/plan_executor.dart';
import 'domain/plan_item.dart';

// --- Settings: API key, model, usage ---

final secureKeyStoreProvider = Provider<SecureKeyStore>((ref) => SecureKeyStore());

/// The user's Gemini API key from secure storage (null when not set).
class ApiKeyNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() => ref.read(secureKeyStoreProvider).readGeminiKey();

  Future<void> save(String key) async {
    await ref.read(secureKeyStoreProvider).saveGeminiKey(key);
    state = AsyncData(key.trim());
  }

  Future<void> remove() async {
    await ref.read(secureKeyStoreProvider).deleteGeminiKey();
    state = const AsyncData(null);
  }
}

final apiKeyProvider = AsyncNotifierProvider<ApiKeyNotifier, String?>(ApiKeyNotifier.new);

class GeminiModelNotifier extends Notifier<String> {
  static const _key = 'gemini_model';

  @override
  String build() =>
      (ref.watch(databaseServiceProvider).getSetting(_key) as String?) ??
      GeminiClient.defaultModel;

  void set(String model) {
    state = model;
    ref.read(databaseServiceProvider).putSetting(_key, model);
  }
}

final geminiModelProvider =
    NotifierProvider<GeminiModelNotifier, String>(GeminiModelNotifier.new);

/// The user's Groq API key from secure storage (null when not set).
class GroqKeyNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() => ref.read(secureKeyStoreProvider).readGroqKey();

  Future<void> save(String key) async {
    await ref.read(secureKeyStoreProvider).saveGroqKey(key);
    state = AsyncData(key.trim());
  }

  Future<void> remove() async {
    await ref.read(secureKeyStoreProvider).deleteGroqKey();
    state = const AsyncData(null);
  }
}

final groqKeyProvider = AsyncNotifierProvider<GroqKeyNotifier, String?>(GroqKeyNotifier.new);

class GroqModelNotifier extends Notifier<String> {
  static const _key = 'groq_model';

  @override
  String build() =>
      (ref.watch(databaseServiceProvider).getSetting(_key) as String?) ?? GroqClient.defaultModel;

  void set(String model) {
    state = model;
    ref.read(databaseServiceProvider).putSetting(_key, model);
  }
}

final groqModelProvider = NotifierProvider<GroqModelNotifier, String>(GroqModelNotifier.new);

enum CoachProvider { gemini, groq }

/// Which provider answers first. The other one, if it has a key, is the backup.
class CoachProviderNotifier extends Notifier<CoachProvider> {
  static const _key = 'coach_provider';

  @override
  CoachProvider build() =>
      (ref.watch(databaseServiceProvider).getSetting(_key) as String?) == 'groq'
          ? CoachProvider.groq
          : CoachProvider.gemini;

  void set(CoachProvider provider) {
    state = provider;
    ref.read(databaseServiceProvider).putSetting(_key, provider.name);
  }
}

final coachProviderProvider =
    NotifierProvider<CoachProviderNotifier, CoachProvider>(CoachProviderNotifier.new);

/// True when at least one AI key is saved, so the coach can run.
final hasCoachKeyProvider = Provider<AsyncValue<bool>>((ref) {
  final gemini = ref.watch(apiKeyProvider);
  final groq = ref.watch(groqKeyProvider);
  if (gemini.isLoading || groq.isLoading) return const AsyncLoading();
  return AsyncData((gemini.value?.isNotEmpty ?? false) || (groq.value?.isNotEmpty ?? false));
});

final usageTrackerProvider =
    Provider<UsageTracker>((ref) => UsageTracker(ref.watch(databaseServiceProvider)));

/// Last 7 days of AI usage, newest first. Refreshed after each request.
class UsageNotifier extends Notifier<List<DailyUsage>> {
  @override
  List<DailyUsage> build() => ref.watch(usageTrackerProvider).recent(7);

  void refresh() => state = ref.read(usageTrackerProvider).recent(7);
}

final usageProvider = NotifierProvider<UsageNotifier, List<DailyUsage>>(UsageNotifier.new);

// --- Chat ---

class CoachState {
  final List<ChatMessage> messages;
  final List<PlanItem> plan;
  final bool isSending;
  final String? error;

  const CoachState({
    this.messages = const [],
    this.plan = const [],
    this.isSending = false,
    this.error,
  });

  int get selectedCount => plan.where((p) => p.selected).length;

  CoachState copyWith({
    List<ChatMessage>? messages,
    List<PlanItem>? plan,
    bool? isSending,
    String? error,
    bool clearError = false,
  }) =>
      CoachState(
        messages: messages ?? this.messages,
        plan: plan ?? this.plan,
        isSending: isSending ?? this.isSending,
        error: clearError ? null : (error ?? this.error),
      );
}

class CoachController extends Notifier<CoachState> {
  static const _messagesKey = 'messages';
  static const _planKey = 'plan';

  /// Upper bound for one whole reply, including tool rounds, so the chat
  /// can never stay stuck on the typing indicator.
  static const replyTimeout = Duration(seconds: 90);

  /// Bumped by [cancel]; a reply from an older run is dropped.
  int _runId = 0;

  @override
  CoachState build() {
    final db = ref.watch(databaseServiceProvider);
    final rawMessages = (db.getCoachData(_messagesKey) as List?) ?? [];
    final rawPlan = (db.getCoachData(_planKey) as List?) ?? [];
    return CoachState(
      messages: rawMessages.map((m) => ChatMessage.fromMap(m as Map)).toList(),
      plan: rawPlan.map((p) => PlanItem.fromMap(p as Map)).toList(),
    );
  }

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.isSending) return;
    final history = state.messages;
    final userMessage = ChatMessage(role: ChatRole.user, text: trimmed, time: DateTime.now());
    state = state.copyWith(messages: [...history, userMessage], clearError: true);
    await _persist();
    await _run(history, trimmed);
  }

  /// Re-sends the last user message after an error.
  Future<void> retry() async {
    final messages = state.messages;
    if (state.isSending || messages.isEmpty || messages.last.role != ChatRole.user) return;
    state = state.copyWith(clearError: true);
    await _run(messages.sublist(0, messages.length - 1), messages.last.text);
  }

  /// Stops waiting for the current reply. The user's message stays so they
  /// can retry.
  void cancel() {
    if (!state.isSending) return;
    _runId++;
    state = state.copyWith(isSending: false, error: 'Stopped. Tap Retry to ask again.');
  }

  Future<void> _run(List<ChatMessage> history, String userText) async {
    final runId = ++_runId;
    state = state.copyWith(isSending: true);
    final usage = ref.read(usageTrackerProvider);
    final clients = <void Function()>[];

    try {
      final model = await _buildModel(clients);
      if (model == null) {
        state = state.copyWith(isSending: false, error: 'Add a Gemini or Groq API key in Settings first.');
        return;
      }

      final habitState = ref.read(habitNotifierProvider);
      final now = DateTime.now();
      final engine = CoachEngine(
        model,
        onUsage: (u) {
          usage.recordRequest(promptTokens: u.promptTokens, outputTokens: u.outputTokens);
        },
      );

      final reply = await engine
          .reply(
            history: history,
            userText: userText,
            tools: CoachTools(
              habits: habitState.habits,
              logs: habitState.logs,
              today: now,
              pendingCount: state.plan.length,
            ),
            systemInstruction: buildSystemInstruction(
              now: now,
              habitsSnapshot: CoachTools.snapshot(habitState.habits),
              analyticsSnapshot: buildAnalytics(
                habits: habitState.habits,
                logs: habitState.logs,
                today: now,
                days: 14,
              ),
            ),
          )
          .timeout(replyTimeout);
      if (runId != _runId) return;
      state = state.copyWith(
        isSending: false,
        messages: [
          ...state.messages,
          ChatMessage(role: ChatRole.coach, text: reply.text, time: DateTime.now()),
        ],
        plan: [...state.plan, ...reply.newPlanItems],
      );
      await _persist();
    } on TimeoutException {
      debugPrint('Coach reply timed out after $replyTimeout');
      if (runId != _runId) return;
      await usage.recordError(rateLimited: false);
      state = state.copyWith(
          isSending: false,
          error: 'Gemini took too long to answer. Tap Retry, or pick a faster model in Settings.');
    } on CoachModelException catch (e) {
      debugPrint('Coach error: $e');
      if (runId != _runId) return;
      await usage.recordError(rateLimited: e.kind == CoachErrorKind.rateLimited);
      state = state.copyWith(isSending: false, error: e.userMessage);
    } catch (e, st) {
      debugPrint('Coach error: $e\n$st');
      if (runId != _runId) return;
      await usage.recordError(rateLimited: false);
      state = state.copyWith(isSending: false, error: 'Something went wrong: $e');
    } finally {
      for (final close in clients) {
        close();
      }
      ref.read(usageProvider.notifier).refresh();
    }
  }

  /// The chosen provider first, the other one as backup when it has a key.
  /// Adds each client's close function to [clients].
  Future<CoachModel?> _buildModel(List<void Function()> clients) async {
    final geminiKey = await ref.read(apiKeyProvider.future);
    final groqKey = await ref.read(groqKeyProvider.future);
    final hasGemini = geminiKey != null && geminiKey.isNotEmpty;
    final hasGroq = groqKey != null && groqKey.isNotEmpty;
    if (!hasGemini && !hasGroq) return null;

    GeminiClient gemini() {
      final c = GeminiClient(
        apiKey: geminiKey!,
        model: ref.read(geminiModelProvider),
        // With Groq as backup, hand over at once instead of trying Flash-Lite.
        useFallbackModel: !hasGroq,
      );
      clients.add(c.close);
      return c;
    }

    GroqClient groq() {
      final c = GroqClient(apiKey: groqKey!, model: ref.read(groqModelProvider));
      clients.add(c.close);
      return c;
    }

    final groqFirst = ref.read(coachProviderProvider) == CoachProvider.groq;
    if (hasGemini && hasGroq) {
      return groqFirst ? FallbackCoachModel(groq(), gemini()) : FallbackCoachModel(gemini(), groq());
    }
    return hasGroq ? groq() : gemini();
  }

  void toggleItem(String id) {
    state = state.copyWith(plan: [
      for (final p in state.plan) p.id == id ? p.copyWith(selected: !p.selected) : p,
    ]);
    _persist();
  }

  Future<void> discardPlan() async {
    state = state.copyWith(plan: []);
    await _persist();
  }

  /// Applies the ticked plan items, clears the plan and notes the result in
  /// the chat so the coach knows what happened.
  Future<PlanResult> applyPlan() async {
    final result =
        await PlanExecutor(ref.read(habitNotifierProvider.notifier)).apply(state.plan);

    final lines = [
      if (result.applied.isNotEmpty)
        'User scheduled: ${result.applied.map((i) => i.summary).join('; ')}.',
      if (result.skipped.isNotEmpty)
        'Could not apply: ${result.skipped.entries.map((e) => '${e.key.summary} (${e.value})').join('; ')}.',
      if (state.plan.any((p) => !p.selected)) 'User declined the other proposals.',
    ];
    state = state.copyWith(
      plan: [],
      messages: [
        ...state.messages,
        if (lines.isNotEmpty)
          ChatMessage(role: ChatRole.event, text: lines.join(' '), time: DateTime.now()),
      ],
    );
    await _persist();
    return result;
  }

  Future<void> newChat() async {
    await ref.read(databaseServiceProvider).clearCoachData();
    state = const CoachState();
  }

  Future<void> _persist() async {
    final db = ref.read(databaseServiceProvider);
    await db.putCoachData(_messagesKey, state.messages.map((m) => m.toMap()).toList());
    await db.putCoachData(_planKey, state.plan.map((p) => p.toMap()).toList());
  }
}

final coachControllerProvider =
    NotifierProvider<CoachController, CoachState>(CoachController.new);
