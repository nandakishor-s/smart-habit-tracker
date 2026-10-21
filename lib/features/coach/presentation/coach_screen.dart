import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/theme/app_colors.dart';
import '../../../presentation/screens/home_shell.dart';
import '../coach_providers.dart';
import '../domain/chat_message.dart';
import 'plan_review_sheet.dart';

class CoachScreen extends ConsumerStatefulWidget {
  const CoachScreen({super.key});

  @override
  ConsumerState<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends ConsumerState<CoachScreen> {
  final _input = TextEditingController();

  static const _starters = [
    'Help me build a simple morning routine',
    'Review my last 30 days',
    'Why do I keep missing days?',
    'My habits feel too hard. Make them easier',
  ];

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _send([String? text]) {
    final message = text ?? _input.text;
    if (message.trim().isEmpty) return;
    _input.clear();
    ref.read(coachControllerProvider.notifier).send(message);
  }

  Future<void> _confirmNewChat() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('New chat', style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
        content: Text('Clear this conversation and any unscheduled plan?',
            style: GoogleFonts.inter()),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Clear')),
        ],
      ),
    );
    if (confirm == true) ref.read(coachControllerProvider.notifier).newChat();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final coach = ref.watch(coachControllerProvider);
    final keyState = ref.watch(hasCoachKeyProvider);
    final hasKey = keyState.value ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.auto_awesome, color: AppColors.primary),
            const SizedBox(width: 10),
            Text('AI Coach', style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w800)),
          ],
        ),
        actions: [
          if (coach.messages.isNotEmpty)
            IconButton(
              onPressed: coach.isSending ? null : _confirmNewChat,
              icon: const Icon(Icons.add_comment_outlined),
              tooltip: 'New chat',
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: keyState.isLoading
          ? const Center(child: CircularProgressIndicator())
          : !hasKey
              ? _NoKeyView(isDark: isDark)
              : Column(
                  children: [
                    Expanded(
                      child: coach.messages.isEmpty
                          ? _StarterView(starters: _starters, onTap: _send, isDark: isDark)
                          : _MessageList(
                              messages: coach.messages,
                              isSending: coach.isSending,
                              isDark: isDark,
                            ),
                    ),
                    if (coach.error != null)
                      _ErrorBanner(
                        message: coach.error!,
                        onRetry: () => ref.read(coachControllerProvider.notifier).retry(),
                      ),
                    if (coach.plan.isNotEmpty)
                      _PlanBar(
                        count: coach.plan.length,
                        onTap: () => PlanReviewSheet.show(context),
                      ),
                    _InputBar(
                      controller: _input,
                      enabled: !coach.isSending,
                      onSend: _send,
                      onStop: () => ref.read(coachControllerProvider.notifier).cancel(),
                      isDark: isDark,
                    ),
                  ],
                ),
    );
  }
}

/// Gemini sometimes adds markdown despite instructions; show it as plain text.
String _plain(String text) => text
    .replaceAll('**', '')
    .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
    .replaceAll(RegExp(r'^\s*[*-]\s+', multiLine: true), '• ');

class _MessageList extends StatelessWidget {
  final List<ChatMessage> messages;
  final bool isSending;
  final bool isDark;

  const _MessageList({required this.messages, required this.isSending, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final items = messages.reversed.toList();
    return ListView.builder(
      reverse: true, // newest at the bottom, auto-scrolls on new messages
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: items.length + (isSending ? 1 : 0),
      itemBuilder: (context, index) {
        if (isSending && index == 0) return _TypingBubble(isDark: isDark);
        final m = items[isSending ? index - 1 : index];
        switch (m.role) {
          case ChatRole.event:
            return _EventChip(text: m.text, isDark: isDark);
          case ChatRole.user:
          case ChatRole.coach:
            return _Bubble(message: m, isDark: isDark);
        }
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final bool isDark;

  const _Bubble({required this.message, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final text = isUser ? message.text : _plain(message.text);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Copied')));
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
          decoration: BoxDecoration(
            color: isUser
                ? AppColors.primary
                : (isDark ? AppColors.darkSurface : AppColors.lightSurface),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isUser ? 18 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 18),
            ),
            border: isUser
                ? null
                : Border.all(
                    color: isDark ? AppColors.darkSurfaceBorder : AppColors.lightSurfaceBorder),
          ),
          child: Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 14,
              height: 1.4,
              color: isUser
                  ? Colors.white
                  : (isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary),
            ),
          ),
        ),
      ),
    ).animate().fade(duration: 200.ms).slideY(begin: 0.1, duration: 200.ms);
  }
}

class _EventChip extends StatelessWidget {
  final String text;
  final bool isDark;

  const _EventChip({required this.text, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.success.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.event_available_rounded, size: 16, color: AppColors.success),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.success),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  final bool isDark;

  const _TypingBubble({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 7,
              height: 7,
              decoration: const BoxDecoration(color: AppColors.pending, shape: BoxShape.circle),
            )
                .animate(onPlay: (c) => c.repeat())
                .fade(begin: 0.3, end: 1, delay: (i * 150).ms, duration: 450.ms)
                .then()
                .fade(begin: 1, end: 0.3, duration: 450.ms);
          }),
        ),
      ),
    );
  }
}

class _StarterView extends StatelessWidget {
  final List<String> starters;
  final ValueChanged<String> onTap;
  final bool isDark;

  const _StarterView({required this.starters, required this.onTap, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final secondary = isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 24),
        const Icon(Icons.auto_awesome, size: 48, color: AppColors.primary),
        const SizedBox(height: 16),
        Text(
          'Plan habits with your coach',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Talk about your goals. The coach proposes changes, and nothing happens '
          'until you review them and press Schedule.',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(fontSize: 13, color: secondary, height: 1.4),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (final s in starters)
              ActionChip(
                label: Text(s, style: GoogleFonts.inter(fontSize: 13)),
                onPressed: () => onTap(s),
              ),
          ],
        ),
      ],
    );
  }
}

class _NoKeyView extends ConsumerWidget {
  final bool isDark;

  const _NoKeyView({required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.key_rounded, size: 48, color: AppColors.primary),
            const SizedBox(height: 16),
            Text('Add an AI key',
                style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'Get a free Gemini key at aistudio.google.com/apikey or a Groq key at '
              'console.groq.com/keys, then save it in Settings. '
              'It is stored encrypted on this phone only.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => ref.read(homeTabProvider.notifier).select(HomeTab.settings),
              icon: const Icon(Icons.settings_rounded),
              label: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: GoogleFonts.inter(fontSize: 12, color: AppColors.error)),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _PlanBar extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _PlanBar({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: AppColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.checklist_rounded, color: AppColors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$count proposed change${count == 1 ? '' : 's'}',
                    style: GoogleFonts.inter(
                        fontWeight: FontWeight.w600, color: AppColors.primary),
                  ),
                ),
                Text('Review & Schedule',
                    style: GoogleFonts.inter(
                        fontWeight: FontWeight.bold, color: AppColors.primary, fontSize: 13)),
                const Icon(Icons.chevron_right_rounded, color: AppColors.primary),
              ],
            ),
          ),
        ),
      ),
    ).animate().fade().slideY(begin: 0.3);
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String?> onSend;
  final VoidCallback onStop;
  final bool isDark;

  const _InputBar({
    required this.controller,
    required this.enabled,
    required this.onSend,
    required this.onStop,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                style: GoogleFonts.inter(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Message your coach…',
                  filled: true,
                  fillColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                        color: isDark ? AppColors.darkSurfaceBorder : AppColors.lightSurfaceBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                        color: isDark ? AppColors.darkSurfaceBorder : AppColors.lightSurfaceBorder),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            enabled
                ? IconButton.filled(
                    onPressed: () => onSend(null),
                    icon: const Icon(Icons.send_rounded),
                    tooltip: 'Send',
                  )
                : IconButton.filledTonal(
                    onPressed: onStop,
                    icon: const Icon(Icons.stop_rounded),
                    tooltip: 'Stop',
                  ),
          ],
        ),
      ),
    );
  }
}
