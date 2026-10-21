# Habit Track

[![CI](https://github.com/nandakishor-s/smart-habit-tracker/actions/workflows/ci.yml/badge.svg)](https://github.com/nandakishor-s/smart-habit-tracker/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

A strict-streak habit tracker for Android, built with Flutter. A day only counts toward your streak when **every** scheduled habit is completed.

The next big step is an **AI Coach**: you chat with Gemini about your goals, agree on a plan, press **Schedule**, and the app creates, updates or removes habits for you. The end goal is to **publish on Google Play** and learn the full release pipeline.

---

## Current features

- Daily habit checklist with progress bar and a 7-day consistency strip
- Add / edit / delete habits (icon and accent color picker)
- Strict streak engine: current streak and best streak (`lib/core/utils/streak_calculator.dart`)
- **Streak freezes** (Duolingo-style):
  - start with 1, earn 1 every 7 streak days, hold up to 2
  - a missed day automatically uses a freeze and keeps the streak
  - frozen days show in ice blue
- "Perfect day" celebration dialog, which also tells you when you earned a freeze
- **AI Coach tab** (Gemini, using your own AI Studio key):
  - chat about your goals
  - the coach proposes changes; you review and **Schedule** them
- **Settings**:
  - Gemini and optional Groq keys (stored encrypted on the phone), model pickers, which provider answers first
  - AI usage stats (requests and tokens per day)
  - theme (saved between launches), data reset, privacy note
- Analytics screen: stat cards (including freezes) and a monthly calendar of perfect and frozen days
- Android home-screen widget showing the streak and today's progress
- Offline-first local storage with Hive
- Bottom navigation: Today · Coach · Analytics · Settings

## Tech stack

| Concern | Choice |
|---|---|
| Framework | Flutter 3.29 / Dart 3.7 |
| State | Riverpod 3 (`Notifier` / `Provider`) |
| Storage | Hive (`habits_box`, `habit_logs_box`, `settings_box`) |
| Home widget | `home_widget` + Kotlin `StreakWidgetProvider` |
| UI | Material 3, `google_fonts` (Inter), `flutter_animate`, `table_calendar` |

## Project structure

```
lib/
├── main.dart                     # Hive init + ProviderScope
├── app.dart                      # MaterialApp + theming
├── models/                       # Habit, HabitLog
├── core/
│   ├── services/                 # DatabaseService (Hive), HomeWidgetService
│   ├── utils/                    # StreakCalculator, AppDateUtils
│   └── theme/                    # AppTheme, AppColors
├── providers/                    # habit, streak, theme providers
├── features/coach/
│   ├── coach_providers.dart      # API key, model, usage, chat controller
│   ├── data/                     # CoachModel interface, GeminiClient (REST), UsageTracker
│   ├── domain/                   # CoachEngine (tool loop + prompt), CoachTools, PlanItem, PlanExecutor
│   └── presentation/             # CoachScreen, PlanReviewSheet
└── presentation/
    ├── screens/                  # HomeShell (tabs), Dashboard, Analytics, Settings
    └── widgets/                  # HabitTile, StreakBadge, WeeklyHeatmap, dialogs
android/app/src/main/kotlin/.../StreakWidgetProvider.kt   # native widget
```

## Getting started

**Requirements:** Flutter 3.29 (stable) and an Android device or emulator (Android 6.0+).

```bash
git clone https://github.com/nandakishor-s/smart-habit-tracker.git
cd smart-habit-tracker
flutter pub get
flutter run              # with an Android device connected
flutter test
```

### Using the AI Coach (free Gemini key)

The coach uses **your own** Gemini API key. No key ships with the app or lives in this repo.

1. Open [aistudio.google.com/apikey](https://aistudio.google.com/apikey) and sign in with a Google account (18+).
2. Click **Create API key** and copy it (it starts with `AIza`).
3. In the app go to **Settings → AI Coach**, paste the key and tap **Save key**. It is stored encrypted on the device (Android Keystore).
4. No billing account is needed. Without one you stay on the free tier and cannot be charged. When the free limit is reached, the coach pauses until it resets.

**Optional: Groq as a fast backup.** Create a free key at [console.groq.com/keys](https://console.groq.com/keys) (starts with `gsk_`) and save it under **Settings → Groq**. When Gemini is overloaded or out of quota, the coach switches to Groq automatically. You can also make Groq answer first. Groq runs open models such as Llama, so replies are very fast but can be a little less polished.

### Privacy

- Habits and history are stored **only on the device** (Hive).
- When you chat with the coach, your message, recent chat and a short summary of your habits and streaks are sent to **Google Gemini**, or to **Groq** if you added a Groq key. On the free tier, Google may use this to improve its products.
- No analytics, ads or tracking.

---

# Roadmap

## Development approach

Build and validate on my own phone first. Decide on public release and architecture later, based on real data.

1. **Personal build:** develop and run the app on my own device (CPH2249, Android 13) with my own AI Studio key in secure storage. No Firebase, no sign-in, no Play Store yet.
2. **Gather data while using it daily:**
   - Requests and tokens per coach conversation, and per day
   - How close I get to the free-tier rate limits
   - Response latency, and how often proposals need fixing or get rejected
   - Whether the Coach actually helps keep streaks (compare streaks before and after)
3. **Study existing apps:** look at how popular habit / AI-coach apps (e.g. Habitica, Fabulous, Finch, and AI-based trackers) handle:
   - AI features, free vs paid limits, and onboarding
   - Notifications, motivation and streak design
   - Privacy policies and Play Store listings
4. **Decide:** with that data, choose between zero-cost shared quota, bring-your-own-key, hybrid, or on-device, and whether to publish at all.

## Phase 0: Stabilise the base (before adding AI)

- [x] `git init` and push to GitHub, with CI (analyze, test, secret scan) and Dependabot
- [ ] Fix the release-build blocker: icons come from runtime `IconData(codePoint)`, which breaks icon tree-shaking in `flutter build --release`. Replace them with a fixed map of `Icons.*` constants keyed by a string id.
- [ ] Replace hard delete with **archive**. Deleting a habit currently removes it from past logs, which rewrites streak history. The `isArchived` field already exists.
- [x] Persist the theme mode in `settings_box`
- [ ] Recompute "today" when the app resumes, so it doesn't go stale after midnight
- [x] Clear the `flutter analyze` warnings (`withOpacity` → `withValues`, `BuildContext` used across `await`)
- [x] Add the `INTERNET` permission to the main manifest (release builds need it to call Gemini)
- [ ] Replace the empty widget test with a real smoke test
- [ ] Upgrade Flutter to the current stable release (needed later for Play's target-API requirement)

## Phase 1: Richer habit model (needed for "scheduling")

The AI can only *schedule* if a habit can say *when* it happens. Every habit is daily-only today.

New optional `Habit` fields (with defaults, so existing Hive data still loads):

| Field | Purpose |
|---|---|
| `frequency` | `daily` · `weekdays` (e.g. Mon/Wed/Fri) · `timesPerWeek` |
| `weekdays` | List of 1–7, used when `frequency = weekdays` |
| `reminderTime` | Optional `HH:mm` for a local notification |
| `goal` | Optional target, e.g. "30 days" or "read 20 books" |
| `startDate` / `endDate` | Lets a plan run for a fixed period |
| `source` | `manual` or `ai`, so you can see which habits the AI created |

Changes this requires:
- `StreakCalculator`: a day is perfect when every habit **scheduled for that day** is done (not every habit that exists)
- Dashboard: show only habits scheduled for the selected date
- Add/Edit dialog: frequency and reminder pickers
- Reminders through `flutter_local_notifications`
- Unit tests for the new streak rules

## Phase 2: AI Coach

> **Status: first version built** (development stage, own API key). It uses the current daily-only habit model. Weekdays and reminders arrive with Phase 1, when the tools gain those fields. Tool names in code: `propose_delete_habit` (hard delete, same as the manual UI) instead of archive, until archiving lands in Phase 0.

### User flow

1. A new **Coach** tab (bottom navigation: *Today · Coach · Analytics · Settings*).
2. You chat with the coach, e.g. *"I want to get fit and read more, but I only have evenings free."*
3. The coach asks follow-up questions, then proposes a **Plan**: a list of pending changes shown as cards:
   - ➕ Add "Evening walk, 30 min", Mon–Fri, reminder 19:00
   - ✏️ Change "Read 15 pages" to daily at 21:30
   - 🗑️ Archive "Morning meditation"
4. Each card has a checkbox, so you can untick anything you don't want.
5. **Schedule** applies the ticked changes in one go. Habits, reminders and the home widget update.
6. The coach can also answer questions about your progress (*"Why do I keep breaking my streak?"*) by reading your analytics.

### Key design rule: the AI proposes, you confirm

The model **never writes to the database directly**. It uses Gemini **function calling**:

| Tool | Type | What it does |
|---|---|---|
| `list_habits` | read | Current habits and their schedules |
| `get_analytics` | read | Streaks, completion rate per habit, weakest weekdays, last N days |
| `get_day_log` | read | What was completed on a given date |
| `propose_add_habit` | proposal | Adds an "add" item to the pending plan |
| `propose_update_habit` | proposal | Adds an "edit" item (title, schedule, reminder, goal) |
| `propose_archive_habit` | proposal | Adds an "archive/delete" item |
| `propose_log_change` | proposal | Mark or unmark a past day's completion |

- **Read** tools run straight away and return data to the model.
- **Proposal** tools only add items to a `PendingPlan`. Nothing changes until you press **Schedule**.
- `PlanExecutor` applies the ticked items through the existing `HabitNotifier` methods, so AI changes and manual changes share one code path.

### New code

```
lib/features/coach/
├── data/
│   ├── gemini_client.dart        # model, system prompt, tool declarations
│   ├── coach_tools.dart          # tool schemas + read-tool handlers
│   └── chat_repository.dart      # chat history in Hive (chat_box)
├── domain/
│   ├── plan_item.dart            # add / update / archive / logChange
│   └── plan_executor.dart        # applies selected items via HabitNotifier
└── presentation/
    ├── coach_screen.dart         # chat UI + streaming replies
    └── plan_review_sheet.dart    # proposal cards + Schedule button
```

The system prompt is rebuilt every session from a compact snapshot of current habits and the last 30 days of stats. This keeps the coach grounded without sending your whole history.

### API key: how Gemini is accessed

| Stage | Approach | Why |
|---|---|---|
| **Development** (own phone only) | Gemini API key from **Google AI Studio**, entered on a Settings screen and stored with `flutter_secure_storage`. **Never committed or hard-coded.** | Fastest way to build and test |
| **Play Store release** (if chosen) | **Firebase AI Logic** (`firebase_ai` package) using the *Gemini Developer API* backend, protected by **Firebase App Check** | A key shipped inside an APK can be extracted and abused. Firebase keeps the Gemini key on the server side, and it is the Google-recommended way to call Gemini from mobile apps. |

The client sits behind a small `CoachModel` interface, so moving from development to release only means swapping one implementation.

**How the quota works:** a key belongs to one Google project, and every user of the app shares that project's quota and billing. Google Sign-In only identifies the user. It does **not** give the app access to that user's own Gemini quota.

### Zero-cost architecture (candidate for public release)

Goal: run the app at **$0**. The only unavoidable cost is the one-time US$25 Google Play developer fee.

**The key rule: no billing account, no bill.** The Google Cloud / Firebase project has **no billing account attached**, so Google can't charge anything. When the free Gemini quota runs out, requests fail with a quota error (HTTP 429), and the app handles that politely.

```
App ──► Firebase App Check (Play Integrity) ──► Firebase AI Logic ──► Gemini Developer API (free tier)
 │
 ├─► Firebase Auth (Google Sign-In): who the user is
 ├─► Per-user daily message counter: protects the shared free quota
 └─► Optional "use my own key": heavy users spend their own free quota
```

| Piece | Free option |
|---|---|
| Gemini calls | Firebase AI Logic, *Gemini Developer API* backend, **Spark (free) plan**. Avoid the *Vertex AI* backend, which needs paid billing. |
| Abuse protection | Firebase App Check (Play Integrity), free within its quota |
| Login and per-user limits | Firebase Auth (Google Sign-In) and a daily counter per user |
| Heavy users | Bring-your-own-key setting (user's free AI Studio key, kept in secure storage) |
| Privacy policy page | GitHub Pages |
| CI/CD | GitHub Actions |
| Crash reports | Firebase Crashlytics |

**When the quota is used up:** only the Coach pauses, with a message like *"Coach is resting for today. Try again tomorrow, or add your own free Gemini key in Settings."* Habits, streaks and analytics keep working offline.

**Making the free quota last:**
- Use the smallest Flash / Flash-Lite model
- Send a short stats summary, never the full history
- Send only the last ~10 messages as chat context
- Cap each user at ~10–20 coach messages per day
- No background AI calls; generate motivation messages only when the app is opened

**Conditions to accept:**
- Free-tier prompts may be used by Google to improve its products. Disclose this in the privacy policy and the Play Data safety form, and never send sensitive data.
- Free limits are per project, so they run out quickly if the app grows. At that point, choose between paid usage and bring-your-own-key only.
- Free-tier limits and region rules change. Re-check the AI Studio rate-limit page and terms before launch.

**Alternatives considered (not the main path):**
- **On-device AI** (Gemini Nano via ML Kit, or Gemma via MediaPipe): free, private and offline. But Gemini Nano only runs on certain flagship phones, and Gemma is a ~0.5–1 GB download, slow on mid-range devices and weak at structured tool calls. A possible offline extra later.
- **Bring-your-own-key only:** costs $0 forever, but most users can't set up a key.

> **Status: not decided yet.** First build and use the Coach on my own phone with my own AI Studio key (Development stage above), then decide based on the data in *Development approach* below.

Other AI details:
- Model: the current **Gemini Flash** model, with the name kept in config rather than hard-coded throughout
- Rate limiting and clear error states (no network, quota exceeded, invalid key)
- Chat history stays on the device. Only the current conversation and the stats snapshot are sent to Gemini.

## Phase 3: Motivation features

- Daily motivational notification (the message is generated when the app is opened and scheduled locally)
- Streak-at-risk nudge in the evening if today isn't complete yet
- Weekly AI review: *"This week: 5/7 perfect days, Thursdays are your weak spot…"*
- Goal progress on the Analytics screen

## Phase 4: Publish on Google Play

### App identity (do this before the first upload: it can't be changed later)
- [x] Final `applicationId`: `com.nandakishor.smarthabittracker`
- [ ] App name and launcher icon (`flutter_launcher_icons`) and splash screen
- [ ] `version: x.y.z+build` bumped for every upload

### Build and signing
- [ ] Create an upload keystore. Keep it and its passwords **out of git** (`key.properties` is gitignored).
- [ ] Configure `signingConfigs` in `android/app/build.gradle.kts`
- [ ] Enable **Play App Signing**
- [ ] `flutter build appbundle --release` → upload the `.aab`
- [ ] Set `targetSdk` to the API level Play currently requires (check Play Console; it rises every August)
- [ ] Optional: R8 / obfuscation (`--obfuscate --split-debug-info`)

### Play Console
- [ ] Developer account (one-time US$25 fee, identity verification)
- [ ] **Privacy policy** URL. Required here because habit data and chat are sent to Google's Gemini API.
- [ ] **Data safety** form (data collected, shared with Google AI, retention)
- [ ] **Generative AI policy**: users must be able to **report / flag** offensive AI responses in the app
- [ ] Content rating questionnaire, store listing, screenshots, feature graphic
- [ ] **Closed testing**: new personal accounts need a closed test with at least 12 testers for 14 days before production access
- [ ] Production release with a staged rollout

### Ongoing (the "deployment-level system" part)
- [ ] CI with GitHub Actions: `flutter analyze` + `flutter test` on every push
- [ ] CD: build and upload to the internal testing track (e.g. Fastlane or `r0adkll/upload-google-play`)
- [ ] Crash reporting with Firebase Crashlytics
- [ ] Watch Play Console vitals (ANRs, crashes) and reviews

---

## Security rules for this repo

- Never commit API keys, keystores, `key.properties` or `google-services.json` secrets
- Store the development Gemini key only in secure storage on the device
- The AI never modifies data without explicit user confirmation
- Every push and pull request is scanned for leaked secrets (gitleaks in CI)

See [SECURITY.md](SECURITY.md) to report a vulnerability privately.

---

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

Copyright (C) 2026 Nanda Kishor S

This program is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3.0**, or (at your option) any later version. It comes with **no warranty**. See [LICENSE](LICENSE).

In short: you may use, study, change and share this app. If you distribute a modified version (for example on an app store), it must also be released under GPL-3.0 with its source code.

### Name and logo

The GPL covers the code, not the identity. The name **"Habit Track"**, the app icon and the store listing assets are not licensed for reuse. If you publish a fork, use a different name, icon and application ID so users can tell the apps apart.
