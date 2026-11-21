import 'dart:async';

import 'package:data_usage_tracker/main.dart';
import 'package:data_usage_tracker/test_ads.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, Key, Locale, SizedBox, Text, Widget;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';

class FakeAds implements TrackerAds {
  final result = Completer<LaunchAd?>();
  int loads = 0;

  @override
  Future<LaunchAd?> loadLaunchAd() {
    loads++;
    return result.future;
  }

  @override
  Widget banner() => const Text('Fake top banner');
}

class FakeLaunchAd implements LaunchAd {
  final dismissed = Completer<void>();
  bool shown = false;
  bool disposed = false;

  @override
  Future<void> show() {
    shown = true;
    return dismissed.future;
  }

  @override
  void dispose() => disposed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('data_usage_tracker/usage');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final loading = find.byKey(const Key('launch-loading'));

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  void mockStartup({
    required bool returning,
    required Future<bool> hasAccess,
    bool seen = true,
  }) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'privacySeen':
          return seen;
        case 'markPrivacySeen':
          seen = true;
          return true;
        case 'returningLaunch':
          return returning;
        case 'hasAccess':
          return hasAccess;
        case 'daily':
          return {
            'mobile': null,
            'wifi': {'total': 0, 'apps': []},
          };
        default:
          return null;
      }
    });
  }

  testWidgets('first launch skips app-open ads and places the banner above usage', (tester) async {
    final ads = FakeAds();
    final access = Completer<bool>();
    mockStartup(returning: true, hasAccess: access.future, seen: false);

    await tester.pumpWidget(TrackerApp(ads: ads));
    await tester.pump();
    expect(loading, findsNothing);
    expect(ads.loads, 0);
    expect(find.text('Privacy & Data'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(ads.loads, 0);
    access.complete(true);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Fake top banner')).dy,
      lessThan(tester.getTopLeft(find.text('Today’s usage')).dy));
  });

  testWidgets('Arabic onboarding persists across cold launches', (tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('ar');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    final firstAds = FakeAds();
    mockStartup(returning: true, hasAccess: Future.value(false), seen: false);

    await tester.pumpWidget(TrackerApp(ads: firstAds));
    await tester.pumpAndSettle();
    expect(find.text('الخصوصية والبيانات'), findsOneWidget);
    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();
    expect(firstAds.loads, 0);
    await tester.pumpWidget(const SizedBox.shrink());

    final nextAds = FakeAds()..result.complete(null);
    await tester.pumpWidget(TrackerApp(ads: nextAds));
    await tester.pumpAndSettle();
    expect(find.text('متابعة'), findsNothing);
  });

  testWidgets('an immediately available ad is shown before usage is ready', (tester) async {
    final access = Completer<bool>();
    final ad = FakeLaunchAd();
    final ads = FakeAds()..result.complete(ad);
    mockStartup(returning: true, hasAccess: access.future);

    await tester.pumpWidget(TrackerApp(ads: ads));
    await tester.pump();
    expect(ad.shown, isTrue);
    ad.dismissed.complete();
    access.complete(false);
    await tester.pumpAndSettle();
    expect(ad.disposed, isTrue);
  });

  testWidgets('load failure releases startup before the deadline', (tester) async {
    final access = Completer<bool>();
    final ads = FakeAds();
    mockStartup(returning: true, hasAccess: access.future);

    await tester.pumpWidget(TrackerApp(ads: ads));
    await tester.pump();
    ads.result.complete(null);
    await tester.pump();
    expect(loading, findsNothing);
    access.complete(false);
    await tester.pumpAndSettle();
  });

  testWidgets('backgrounding cancels the startup ad and resuming does not retry', (tester) async {
    final access = Completer<bool>();
    final ads = FakeAds();
    mockStartup(returning: true, hasAccess: access.future);

    await tester.pumpWidget(TrackerApp(ads: ads));
    await tester.pump();
    expect(ads.loads, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(loading, findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final ad = FakeLaunchAd();
    ads.result.complete(ad);
    access.complete(false);
    await tester.pumpAndSettle();
    expect(ads.loads, 1);
    expect(ad.shown, isFalse);
    expect(ad.disposed, isTrue);
  });

  testWidgets('discards an ad that arrives after the dashboard is ready', (tester) async {
    final ads = FakeAds();
    final access = Completer<bool>();
    mockStartup(returning: true, hasAccess: access.future);

    await tester.pumpWidget(TrackerApp(ads: ads));
    await tester.pump();
    expect(loading, findsOneWidget);
    expect(ads.loads, 1);
    access.complete(true);
    await tester.pumpAndSettle();
    expect(loading, findsNothing);

    final ad = FakeLaunchAd();
    ads.result.complete(ad);
    await tester.pumpAndSettle();
    expect(ad.shown, isFalse);
    expect(ad.disposed, isTrue);
  });

  testWidgets('ends the ad window at three seconds and skips late ads', (tester) async {
    final ads = FakeAds();
    final access = Completer<bool>();
    mockStartup(returning: true, hasAccess: access.future);

    await tester.pumpWidget(TrackerApp(ads: ads));
    await tester.pump();
    expect(loading, findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(loading, findsNothing);

    final ad = FakeLaunchAd();
    ads.result.complete(ad);
    access.complete(true);
    await tester.pumpAndSettle();
    expect(ad.shown, isFalse);
    expect(ad.disposed, isTrue);
  });

  testWidgets('shows an early ad over loading and clears it after dismissal', (tester) async {
    final ads = FakeAds();
    final access = Completer<bool>();
    mockStartup(returning: true, hasAccess: access.future);

    await tester.pumpWidget(TrackerApp(ads: ads));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    final ad = FakeLaunchAd();
    ads.result.complete(ad);
    await tester.pump();
    expect(ad.shown, isTrue);

    access.complete(true);
    await tester.pump(const Duration(seconds: 3));
    expect(loading, findsOneWidget);
    expect(find.text('Fake top banner'), findsNothing);
    ad.dismissed.complete();
    await tester.pumpAndSettle();
    expect(ad.disposed, isTrue);
    expect(loading, findsNothing);
    expect(find.text('Fake top banner'), findsOneWidget);
  });
}
