import 'package:uuid/uuid.dart';

import '../../../core/constants/habit_styles.dart';
import '../../../core/utils/date_utils.dart';
import '../../../core/utils/streak_calculator.dart';
import '../../../models/habit.dart';
import '../../../models/habit_log.dart';
import 'plan_item.dart';

/// Result of running one tool call.
class ToolResult {
  /// JSON sent back to the model as the function response.
  final Map<String, dynamic> response;

  /// Set when a proposal tool queued a change.
  final PlanItem? planItem;

  const ToolResult(this.response, [this.planItem]);

  factory ToolResult.error(String message) => ToolResult({'error': message});
}

/// Gemini function declarations and handlers for the coach.
///
/// Read tools (`get_analytics`, `get_day_log`; `list_habits` is still handled
/// but not offered) answer right away.
/// Proposal tools (`propose_*`) never change data: they only return a
/// [PlanItem] for the user to review and schedule.
class CoachTools {
  static const int maxPendingItems = 20;

  final List<Habit> habits;
  final Map<String, HabitLog> logs;
  final DateTime today;
  final int pendingCount;
  final Uuid _uuid;

  CoachTools({
    required this.habits,
    required this.logs,
    required this.today,
    this.pendingCount = 0,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  static final List<Map<String, dynamic>> declarations = [
    // No list_habits here: the system instruction already holds every habit,
    // and offering the tool made the model spend a round trip re-reading it.
    {
      'name': 'get_analytics',
      'description': 'Only for periods longer than the 14 days already provided: '
          'streaks, freezes, per-habit completion rates, weekday performance and '
          'a day-by-day history for the last N days.',
      'parameters': {
        'type': 'object',
        'properties': {
          'days': {
            'type': 'integer',
            'description': 'How many past days to analyse (7-90). Default 30.',
          },
        },
      },
    },
    {
      'name': 'get_day_log',
      'description': 'Which habits were completed on one date.',
      'parameters': {
        'type': 'object',
        'properties': {
          'date': {'type': 'string', 'description': 'Date as YYYY-MM-DD.'},
        },
        'required': ['date'],
      },
    },
    {
      'name': 'propose_add_habit',
      'description': 'Propose a new daily habit. Queued for the user to approve; '
          'nothing changes until they press Schedule.',
      'parameters': {
        'type': 'object',
        'properties': {
          'title': {'type': 'string', 'description': 'Short, specific (max 60 chars).'},
          'description': {'type': 'string', 'description': 'Optional detail, e.g. when or how much.'},
          'icon': {'type': 'string', 'enum': habitIconOptions.keys.toList()},
          'color': {'type': 'string', 'enum': habitColorOptions.keys.toList()},
          'reason': {'type': 'string', 'description': 'One sentence on why this helps.'},
        },
        'required': ['title', 'reason'],
      },
    },
    {
      'name': 'propose_update_habit',
      'description': 'Propose editing an existing habit. Only include fields that change.',
      'parameters': {
        'type': 'object',
        'properties': {
          'habit_id': {'type': 'string'},
          'title': {'type': 'string'},
          'description': {'type': 'string'},
          'icon': {'type': 'string', 'enum': habitIconOptions.keys.toList()},
          'color': {'type': 'string', 'enum': habitColorOptions.keys.toList()},
          'reason': {'type': 'string'},
        },
        'required': ['habit_id', 'reason'],
      },
    },
    {
      'name': 'propose_delete_habit',
      'description': 'Propose deleting a habit. Its completion history is removed too, '
          'which can change past perfect days, so use only when the user wants it gone.',
      'parameters': {
        'type': 'object',
        'properties': {
          'habit_id': {'type': 'string'},
          'reason': {'type': 'string'},
        },
        'required': ['habit_id', 'reason'],
      },
    },
    {
      'name': 'propose_log_change',
      'description': 'Propose marking a habit done or not done on a past date or today '
          '(e.g. the user forgot to tick it).',
      'parameters': {
        'type': 'object',
        'properties': {
          'habit_id': {'type': 'string'},
          'date': {'type': 'string', 'description': 'YYYY-MM-DD, not in the future.'},
          'completed': {'type': 'boolean'},
          'reason': {'type': 'string'},
        },
        'required': ['habit_id', 'date', 'completed', 'reason'],
      },
    },
  ];

  DateTime get _todayNorm => AppDateUtils.normalize(today);

  ToolResult handle(String name, Map<String, dynamic> args) {
    try {
      switch (name) {
        case 'list_habits':
          return ToolResult({'habits': snapshot(habits)});
        case 'get_analytics':
          final days = ((args['days'] as num?)?.toInt() ?? 30).clamp(7, 90);
          return ToolResult(buildAnalytics(habits: habits, logs: logs, today: today, days: days));
        case 'get_day_log':
          return _dayLog(args);
        case 'propose_add_habit':
        case 'propose_update_habit':
        case 'propose_delete_habit':
        case 'propose_log_change':
          if (pendingCount >= maxPendingItems) {
            return ToolResult.error('The plan already has $maxPendingItems changes. '
                'Ask the user to review and schedule it first.');
          }
          return _propose(name, args);
        default:
          return ToolResult.error('Unknown tool "$name"');
      }
    } catch (e) {
      return ToolResult.error('Invalid arguments: $e');
    }
  }

  ToolResult _propose(String name, Map<String, dynamic> args) {
    final reason = (args['reason'] as String?)?.trim() ?? '';
    switch (name) {
      case 'propose_add_habit':
        final title = (args['title'] as String?)?.trim() ?? '';
        if (title.isEmpty) return ToolResult.error('title is required');
        if (title.length > 60) return ToolResult.error('title must be at most 60 characters');
        if (habits.any((h) => h.title.toLowerCase() == title.toLowerCase())) {
          return ToolResult.error('A habit named "$title" already exists');
        }
        return _queued(PlanItem(
          id: _uuid.v4(),
          type: PlanItemType.addHabit,
          title: title,
          description: (args['description'] as String?)?.trim() ?? '',
          iconCodePoint: habitIconOptions[args['icon']] ?? habitIconOptions['check'],
          colorValue: habitColorOptions[args['color']] ?? habitColorOptions['indigo'],
          reason: reason,
        ));

      case 'propose_update_habit':
        final habit = _findHabit(args['habit_id']);
        if (habit == null) return _unknownHabit(args['habit_id']);
        final title = (args['title'] as String?)?.trim();
        final description = (args['description'] as String?)?.trim();
        final icon = habitIconOptions[args['icon']];
        final color = habitColorOptions[args['color']];
        if (title != null && (title.isEmpty || title.length > 60)) {
          return ToolResult.error('title must be 1-60 characters');
        }
        if (title == null && description == null && icon == null && color == null) {
          return ToolResult.error('Nothing to change');
        }
        return _queued(PlanItem(
          id: _uuid.v4(),
          type: PlanItemType.updateHabit,
          habitId: habit.id,
          habitTitle: habit.title,
          title: title,
          description: description,
          iconCodePoint: icon,
          colorValue: color,
          reason: reason,
        ));

      case 'propose_delete_habit':
        final habit = _findHabit(args['habit_id']);
        if (habit == null) return _unknownHabit(args['habit_id']);
        return _queued(PlanItem(
          id: _uuid.v4(),
          type: PlanItemType.deleteHabit,
          habitId: habit.id,
          habitTitle: habit.title,
          reason: reason,
        ));

      default: // propose_log_change
        final habit = _findHabit(args['habit_id']);
        if (habit == null) return _unknownHabit(args['habit_id']);
        final date = _parseDate(args['date']);
        if (date == null) return ToolResult.error('date must be YYYY-MM-DD');
        if (date.isAfter(_todayNorm)) return ToolResult.error('date is in the future');
        if (date.isBefore(AppDateUtils.normalize(habit.createdAt))) {
          return ToolResult.error('"${habit.title}" did not exist on that date');
        }
        final completed = args['completed'];
        if (completed is! bool) return ToolResult.error('completed must be true or false');
        return _queued(PlanItem(
          id: _uuid.v4(),
          type: PlanItemType.logChange,
          habitId: habit.id,
          habitTitle: habit.title,
          dateKey: AppDateUtils.toDateKey(date),
          completed: completed,
          reason: reason,
        ));
    }
  }

  ToolResult _queued(PlanItem item) => ToolResult({
        'status': 'queued_for_user_approval',
        'summary': item.summary,
        'note': 'Not applied yet. The user must press Schedule.',
      }, item);

  ToolResult _unknownHabit(Object? id) =>
      ToolResult.error('No habit with id "$id". Use an id from CURRENT HABITS.');

  ToolResult _dayLog(Map<String, dynamic> args) {
    final date = _parseDate(args['date']);
    if (date == null) return ToolResult.error('date must be YYYY-MM-DD');
    final key = AppDateUtils.toDateKey(date);
    final log = logs[key];
    final active = habits.where((h) => !AppDateUtils.normalize(h.createdAt).isAfter(date));
    return ToolResult({
      'date': key,
      'habits': [
        for (final h in active)
          {'id': aliasOf(habits, h), 'completed': log?.isHabitCompleted(h.id) ?? false},
      ],
      'perfect': StreakCalculator.isDayPerfect(date, habits, logs),
    });
  }

  /// Accepts a short alias ("h2") or a real habit id.
  Habit? _findHabit(Object? id) {
    final match = RegExp(r'^h(\d+)$').firstMatch('$id');
    if (match != null) {
      final i = int.parse(match.group(1)!) - 1;
      if (i >= 0 && i < habits.length) return habits[i];
    }
    for (final h in habits) {
      if (h.id == id) return h;
    }
    return null;
  }

  static DateTime? _parseDate(Object? value) {
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
    final parsed = DateTime.tryParse(value);
    return parsed == null ? null : AppDateUtils.normalize(parsed);
  }

  /// Short id shown to the model instead of the 36-character UUID, which
  /// costs many tokens on every request. [_findHabit] maps it back.
  static String aliasOf(List<Habit> habits, Habit h) => 'h${habits.indexOf(h) + 1}';

  /// All habits as the model sees them, with short ids.
  static List<Map<String, dynamic>> snapshot(List<Habit> habits) =>
      [for (final h in habits) habitJson(h, aliasOf(habits, h))];

  static Map<String, dynamic> habitJson(Habit h, String id) => {
        'id': id,
        'title': h.title,
        if (h.description.isNotEmpty) 'description': h.description,
        'icon': iconNameFor(h.iconCodePoint) ?? 'check',
        'color': colorNameFor(h.colorValue) ?? 'custom',
        'created': AppDateUtils.toDateKey(h.createdAt),
      };
}

/// Compact analytics used by `get_analytics` and the system prompt.
Map<String, dynamic> buildAnalytics({
  required List<Habit> habits,
  required Map<String, HabitLog> logs,
  required DateTime today,
  int days = 30,
}) {
  final todayNorm = AppDateUtils.normalize(today);
  final streak = StreakCalculator.calculateStreak(today: today, habits: habits, logs: logs);
  const weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  final perHabit = <Map<String, dynamic>>[];
  for (final h in habits) {
    final created = AppDateUtils.normalize(h.createdAt);
    var scheduled = 0, done = 0;
    for (var i = 1; i <= days; i++) {
      final d = DateTime(todayNorm.year, todayNorm.month, todayNorm.day - i);
      if (d.isBefore(created)) break;
      scheduled++;
      if (logs[AppDateUtils.toDateKey(d)]?.isHabitCompleted(h.id) ?? false) done++;
    }
    perHabit.add({
      'id': CoachTools.aliasOf(habits, h),
      'done_days': done,
      'tracked_days': scheduled,
      if (scheduled > 0) 'completion_pct': (done * 100 / scheduled).round(),
      'done_today': logs[AppDateUtils.toDateKey(todayNorm)]?.isHabitCompleted(h.id) ?? false,
    });
  }

  // Oldest -> newest. P perfect, F frozen, M missed, - no habits, T today.
  final history = StringBuffer();
  final weekdayTotals = List.filled(7, 0), weekdayPerfect = List.filled(7, 0);
  for (var i = days; i >= 0; i--) {
    final d = DateTime(todayNorm.year, todayNorm.month, todayNorm.day - i);
    final key = AppDateUtils.toDateKey(d);
    final hasHabits = habits.any((h) => !AppDateUtils.normalize(h.createdAt).isAfter(d));
    final perfect = StreakCalculator.isDayPerfect(d, habits, logs);
    if (i == 0) {
      history.write(perfect ? 'P' : 'T');
    } else if (!hasHabits) {
      history.write('-');
    } else {
      history.write(perfect ? 'P' : (streak.frozenDateKeys.contains(key) ? 'F' : 'M'));
      weekdayTotals[d.weekday - 1]++;
      if (perfect) weekdayPerfect[d.weekday - 1]++;
    }
  }

  return {
    'today': AppDateUtils.toDateKey(todayNorm),
    'current_streak': streak.currentStreak,
    'best_streak': streak.bestStreak,
    'freezes_held': streak.freezesAvailable,
    'freezes_max': StreakCalculator.maxFreezes,
    'perfect_days_until_next_freeze': streak.daysUntilNextFreeze,
    'today_done': '${streak.todayCompletedCount}/${streak.todayTotalCount}',
    'habits': perHabit,
    'weekday_perfect_pct': {
      for (var w = 0; w < 7; w++)
        if (weekdayTotals[w] > 0)
          weekdayNames[w]: (weekdayPerfect[w] * 100 / weekdayTotals[w]).round(),
    },
    'history_oldest_to_today': history.toString(),
    'history_legend': 'P=perfect, F=missed but saved by a freeze, M=missed, '
        '-=no habits yet, T=today in progress',
  };
}
