import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:habit_track/core/theme/app_colors.dart';
import 'package:habit_track/presentation/widgets/streak_badge.dart';

Future<void> pumpBadge(WidgetTester tester, StreakBadge badge) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.light(),
      home: Scaffold(body: Center(child: badge)),
    ),
  );
  // StreakBadge starts a zero-delay animation. Flush it so the test
  // does not end with a pending timer.
  await tester.pump();
}

Future<void> unmountBadge(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpWidget(const SizedBox());
}

List<Icon> snowflakes(WidgetTester tester) {
  return tester.widgetList<Icon>(find.byIcon(Icons.ac_unit_rounded)).toList();
}

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('Shows 0/2 and two dimmed snowflakes when no freezes are held', (tester) async {
    await pumpBadge(
      tester,
      const StreakBadge(streakCount: 4, freezesAvailable: 0, maxFreezes: 2),
    );

    expect(find.text('0/2'), findsOneWidget);
    expect(find.textContaining('Next freeze in 7 perfect days'), findsOneWidget);

    final icons = snowflakes(tester);
    expect(icons, hasLength(2));
    for (final icon in icons) {
      expect(icon.color, Colors.black26);
    }

    await unmountBadge(tester);
  });

  testWidgets('Shows 2/2 and Freezes full when the maximum is held', (tester) async {
    await pumpBadge(
      tester,
      const StreakBadge(streakCount: 4, freezesAvailable: 2, maxFreezes: 2),
    );

    expect(find.text('2/2'), findsOneWidget);
    expect(find.textContaining('Freezes full'), findsOneWidget);
    expect(find.textContaining('Next freeze in'), findsNothing);

    final icons = snowflakes(tester);
    expect(icons, hasLength(2));
    for (final icon in icons) {
      expect(icon.color, AppColors.streakFreeze);
    }

    await unmountBadge(tester);
  });

  testWidgets('Says 1 perfect day when daysUntilNextFreeze is 1', (tester) async {
    await pumpBadge(
      tester,
      const StreakBadge(
        streakCount: 4,
        freezesAvailable: 1,
        maxFreezes: 2,
        daysUntilNextFreeze: 1,
      ),
    );

    expect(find.textContaining('Next freeze in 1 perfect day'), findsOneWidget);
    expect(find.textContaining('perfect days'), findsNothing);
    expect(find.text('1/2'), findsOneWidget);

    final icons = snowflakes(tester);
    expect(icons, hasLength(2));
    expect(icons[0].color, AppColors.streakFreeze);
    expect(icons[1].color, Colors.black26);

    await unmountBadge(tester);
  });

  testWidgets('Says DAY STREAK for 1 and DAYS STREAK otherwise', (tester) async {
    await pumpBadge(tester, const StreakBadge(streakCount: 1));
    expect(find.text('DAY STREAK'), findsOneWidget);
    expect(find.text('DAYS STREAK'), findsNothing);
    expect(find.text('1'), findsOneWidget);

    await pumpBadge(tester, const StreakBadge(streakCount: 0));
    expect(find.text('DAYS STREAK'), findsOneWidget);
    expect(find.text('DAY STREAK'), findsNothing);

    await pumpBadge(tester, const StreakBadge(streakCount: 12));
    expect(find.text('DAYS STREAK'), findsOneWidget);
    expect(find.text('DAY STREAK'), findsNothing);
    expect(find.text('12'), findsOneWidget);

    await unmountBadge(tester);
  });
}
