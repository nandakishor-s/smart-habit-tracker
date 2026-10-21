import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/streak_calculator.dart';
import '../../features/coach/coach_providers.dart';
import '../../features/coach/data/coach_model.dart';
import '../../features/coach/data/gemini_client.dart';
import '../../features/coach/data/groq_client.dart';
import '../../providers/habit_provider.dart';
import '../../providers/theme_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text('Settings', style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _Section(title: 'AI Coach', isDark: isDark, child: const _ApiKeySection()),
          _Section(title: 'Groq (fast backup)', isDark: isDark, child: const _GroqSection()),
          _Section(title: 'AI usage', isDark: isDark, child: _UsageSection(isDark: isDark)),
          _Section(title: 'Appearance', isDark: isDark, child: const _ThemeSection()),
          _Section(title: 'Streak freezes', isDark: isDark, child: _FreezeInfo(isDark: isDark)),
          _Section(title: 'Data', isDark: isDark, child: const _DataSection()),
          _Section(title: 'Privacy', isDark: isDark, child: _PrivacyNote(isDark: isDark)),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  final bool isDark;

  const _Section({required this.title, required this.child, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                  color: isDark ? AppColors.darkSurfaceBorder : AppColors.lightSurfaceBorder),
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

// --- API key & model ---

class _ApiKeySection extends ConsumerStatefulWidget {
  const _ApiKeySection();

  @override
  ConsumerState<_ApiKeySection> createState() => _ApiKeySectionState();
}

class _ApiKeySectionState extends ConsumerState<_ApiKeySection> {
  final _keyController = TextEditingController();
  bool _obscure = true;
  bool _testing = false;
  List<String>? _models;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  String _mask(String key) =>
      key.length <= 8 ? '••••' : '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) return;
    await ref.read(apiKeyProvider.notifier).save(key);
    _keyController.clear();
    FocusManager.instance.primaryFocus?.unfocus();
    await _test();
  }

  /// Checks the key by listing models (no generation quota used).
  Future<void> _test() async {
    final key = ref.read(apiKeyProvider).value;
    if (key == null) return;
    setState(() => _testing = true);
    final client = GeminiClient(apiKey: key, model: ref.read(geminiModelProvider));
    try {
      final models = await client.listModels();
      if (!mounted) return;
      setState(() => _models = models);
      _snack('Key works ✓ (${models.length} Gemini models available)');
    } on CoachModelException catch (e) {
      if (mounted) _snack(e.userMessage);
    } finally {
      client.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _remove() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove API key?'),
        content: const Text('The coach will stop working until you add a key again.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(apiKeyProvider.notifier).remove();
      setState(() => _models = null);
    }
  }

  Future<void> _pickModel() async {
    if (_models == null) await _test();
    if (!mounted) return;
    final current = ref.read(geminiModelProvider);
    final options = {GeminiClient.defaultModel, current, ...?_models}.toList();

    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Flash / Flash-Lite models use the least free quota. '
                '"${GeminiClient.defaultModel}" always points to the newest Flash.',
                style: GoogleFonts.inter(fontSize: 12),
              ),
            ),
            for (final m in options)
              ListTile(
                title: Text(m, style: GoogleFonts.inter(fontSize: 14)),
                trailing: m == current ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.of(ctx).pop(m),
              ),
          ],
        ),
      ),
    );
    if (picked != null) ref.read(geminiModelProvider.notifier).set(picked);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final apiKey = ref.watch(apiKeyProvider);
    final key = apiKey.value;
    final model = ref.watch(geminiModelProvider);
    final secondary = isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              key != null ? Icons.check_circle_rounded : Icons.key_off_rounded,
              color: key != null ? AppColors.success : secondary,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                key != null ? 'Gemini key saved: ${_mask(key)}' : 'No Gemini API key',
                style: GoogleFonts.inter(fontWeight: FontWeight.w600),
              ),
            ),
            if (key != null) ...[
              TextButton(
                onPressed: _testing ? null : _test,
                child: _testing
                    ? const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Test'),
              ),
              IconButton(
                onPressed: _remove,
                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.error),
                tooltip: 'Remove key',
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _keyController,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: GoogleFonts.inter(fontSize: 14),
          decoration: InputDecoration(
            labelText: key != null ? 'Replace key' : 'Paste API key',
            hintText: 'AIza…',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
            ),
          ),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(onPressed: _save, child: const Text('Save key')),
        ),
        const SizedBox(height: 4),
        Text(
          'Get a free key at aistudio.google.com/apikey. It is stored encrypted on this '
          'phone only and never leaves it except to call Gemini.',
          style: GoogleFonts.inter(fontSize: 12, color: secondary),
        ),
        const Divider(height: 28),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.memory_rounded),
          title: Text('Model', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
          subtitle: Text(model, style: GoogleFonts.inter(fontSize: 13)),
          trailing: const Icon(Icons.chevron_right_rounded),
          enabled: key != null,
          onTap: _pickModel,
        ),
      ],
    );
  }
}

// --- Groq key, model and provider order ---

class _GroqSection extends ConsumerStatefulWidget {
  const _GroqSection();

  @override
  ConsumerState<_GroqSection> createState() => _GroqSectionState();
}

class _GroqSectionState extends ConsumerState<_GroqSection> {
  final _keyController = TextEditingController();
  bool _testing = false;
  List<String>? _models;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) return;
    await ref.read(groqKeyProvider.notifier).save(key);
    _keyController.clear();
    FocusManager.instance.primaryFocus?.unfocus();
    await _test();
  }

  /// Checks the key by listing models, and moves off a model Groq retired.
  Future<void> _test() async {
    final key = ref.read(groqKeyProvider).value;
    if (key == null) return;
    setState(() => _testing = true);
    final client = GroqClient(apiKey: key, model: ref.read(groqModelProvider));
    try {
      final models = await client.listModels();
      if (!mounted) return;
      setState(() => _models = models);
      final current = ref.read(groqModelProvider);
      final best = GroqClient.pickModel(current, models);
      if (best != current) ref.read(groqModelProvider.notifier).set(best);
      _snack('Groq key works ✓ (${models.length} models available)');
    } on CoachModelException catch (e) {
      if (mounted) _snack(e.userMessage);
    } finally {
      client.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _pickModel() async {
    if (_models == null) await _test();
    if (!mounted) return;
    final current = ref.read(groqModelProvider);
    final options = {current, ...?_models}.toList();
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final m in options)
              ListTile(
                title: Text(m, style: GoogleFonts.inter(fontSize: 14)),
                trailing: m == current ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.of(ctx).pop(m),
              ),
          ],
        ),
      ),
    );
    if (picked != null) ref.read(groqModelProvider.notifier).set(picked);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final secondary = isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
    final key = ref.watch(groqKeyProvider).value;
    final hasGemini = ref.watch(apiKeyProvider).value?.isNotEmpty ?? false;
    final first = ref.watch(coachProviderProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              key != null ? Icons.check_circle_rounded : Icons.key_off_rounded,
              color: key != null ? AppColors.success : secondary,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                key != null ? 'Groq key saved' : 'No Groq key (optional)',
                style: GoogleFonts.inter(fontWeight: FontWeight.w600),
              ),
            ),
            if (key != null) ...[
              TextButton(
                onPressed: _testing ? null : _test,
                child: _testing
                    ? const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Test'),
              ),
              IconButton(
                onPressed: () => ref.read(groqKeyProvider.notifier).remove(),
                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.error),
                tooltip: 'Remove key',
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _keyController,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          style: GoogleFonts.inter(fontSize: 14),
          decoration: InputDecoration(
            labelText: key != null ? 'Replace Groq key' : 'Paste Groq key',
            hintText: 'gsk_…',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(onPressed: _save, child: const Text('Save key')),
        ),
        Text(
          'Free key at console.groq.com/keys. Very fast; used when Gemini is busy. '
          'Stored encrypted on this phone only.',
          style: GoogleFonts.inter(fontSize: 12, color: secondary),
        ),
        if (key != null) ...[
          const Divider(height: 28),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.memory_rounded),
            title: Text('Groq model', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
            subtitle: Text(ref.watch(groqModelProvider), style: GoogleFonts.inter(fontSize: 13)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _pickModel,
          ),
          if (hasGemini) ...[
            const SizedBox(height: 8),
            Text('Answer first with', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<CoachProvider>(
              segments: const [
                ButtonSegment(value: CoachProvider.gemini, label: Text('Gemini')),
                ButtonSegment(value: CoachProvider.groq, label: Text('Groq')),
              ],
              selected: {first},
              onSelectionChanged: (s) => ref.read(coachProviderProvider.notifier).set(s.first),
            ),
            const SizedBox(height: 6),
            Text(
              'The other one takes over automatically when the first is busy.',
              style: GoogleFonts.inter(fontSize: 12, color: secondary),
            ),
          ],
        ],
      ],
    );
  }
}

// --- Usage ---

class _UsageSection extends ConsumerWidget {
  final bool isDark;

  const _UsageSection({required this.isDark});

  String _compact(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(usageProvider);
    final today = usage.first;
    final secondary = isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
    final weekRequests = usage.fold<int>(0, (sum, u) => sum + u.requests);
    final weekTokens = usage.fold<int>(0, (sum, u) => sum + u.totalTokens);

    Widget stat(String value, String label) => Expanded(
          child: Column(
            children: [
              Text(value, style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w800)),
              Text(label, style: GoogleFonts.inter(fontSize: 11, color: secondary)),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            stat('${today.requests}', 'requests today'),
            stat(_compact(today.totalTokens), 'tokens today'),
            stat('${today.rateLimited}', 'rate-limited'),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Last 7 days: $weekRequests requests · ${_compact(weekTokens)} tokens',
          style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        for (final u in usage)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  child: Text(u.dateKey, style: GoogleFonts.inter(fontSize: 12, color: secondary)),
                ),
                Expanded(
                  child: Text(
                    '${u.requests} req · ${_compact(u.promptTokens)} in · '
                    '${_compact(u.outputTokens)} out'
                    '${u.errors + u.rateLimited > 0 ? ' · ${u.errors + u.rateLimited} failed' : ''}',
                    style: GoogleFonts.inter(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'Compare with your free-tier limits at aistudio.google.com (Usage / Rate limits). '
          'One coach message can use several requests when it reads data or proposes changes.',
          style: GoogleFonts.inter(fontSize: 12, color: secondary),
        ),
      ],
    );
  }
}

// --- Theme ---

class _ThemeSection extends ConsumerWidget {
  const _ThemeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<ThemeMode>(
        segments: const [
          ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.phone_android)),
          ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
          ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
        ],
        selected: {mode},
        onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).setThemeMode(s.first),
      ),
    );
  }
}

// --- Streak freeze info ---

class _FreezeInfo extends StatelessWidget {
  final bool isDark;

  const _FreezeInfo({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final style = GoogleFonts.inter(fontSize: 13, height: 1.5);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.ac_unit_rounded, color: AppColors.streakFreeze),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '• You start with ${StreakCalculator.initialFreezes} freeze.\n'
            '• Earn 1 for every ${StreakCalculator.freezeEarnInterval} days of streak '
            '(hold up to ${StreakCalculator.maxFreezes}).\n'
            '• If you miss a day, a freeze is used automatically and your streak survives '
            '(it just doesn\'t grow that day).\n'
            '• With no freezes left, a missed day resets the streak.',
            style: style,
          ),
        ),
      ],
    );
  }
}

// --- Data ---

class _DataSection extends ConsumerWidget {
  const _DataSection();

  Future<bool> _confirm(BuildContext context, String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
        content: Text(body, style: GoogleFonts.inter()),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.forum_outlined),
          title: const Text('Clear coach chat'),
          subtitle: const Text('Deletes the conversation and any unscheduled plan'),
          onTap: () async {
            if (await _confirm(context, 'Clear coach chat?',
                'Your habits are not affected.', 'Clear')) {
              ref.read(coachControllerProvider.notifier).newChat();
            }
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.restart_alt_rounded, color: AppColors.error),
          title: const Text('Start fresh today', style: TextStyle(color: AppColors.error)),
          subtitle: const Text('Deletes all habits and history, then adds the starter habits'),
          onTap: () async {
            if (await _confirm(context, 'Start fresh today?',
                'This deletes all habits and history. It cannot be undone.', 'Start fresh')) {
              ref.read(habitNotifierProvider.notifier).resetFreshStart();
            }
          },
        ),
      ],
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  final bool isDark;

  const _PrivacyNote({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Text(
      'Habits and history are stored only on this phone. When you chat with the coach, '
      'your message, recent chat and a summary of your habits and streaks are sent to '
      'Google Gemini (or Groq, if you added a Groq key). On the free tier, Google may use '
      'this data to improve its products, '
      'so avoid sharing anything sensitive.',
      style: GoogleFonts.inter(
        fontSize: 12,
        height: 1.5,
        color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
      ),
    );
  }
}
