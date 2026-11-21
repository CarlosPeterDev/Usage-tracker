import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException, SystemUiOverlayStyle;

import 'feature_language.dart';
import 'reports.dart';
import 'privacy_policy_page.dart';
import 'test_ads.dart';
import 'tracker_ui.dart';
import 'usage.dart';

void main() => runApp(TrackerApp(ads: AdMobTestAds()));

extension AppearanceLabel on ThemeMode {
  String displayLabel(BuildContext context) => switch (this) {
    ThemeMode.system => tr(context, 'Automatic', 'تلقائي'),
    ThemeMode.light => tr(context, 'Light', 'فاتح'),
    ThemeMode.dark => tr(context, 'Dark', 'داكن'),
  };
}

ThemeData trackerTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF007F77),
    brightness: brightness,
    surface: dark ? const Color(0xFF172424) : Colors.white,
    onSurface: dark ? const Color(0xFFE2F3EE) : const Color(0xFF152D2B),
    primary: dark ? const Color(0xFF74DFC8) : const Color(0xFF006C62),
    secondary: dark ? const Color(0xFFFFCD87) : const Color(0xFF8A500D),
  );
  final background = dark ? const Color(0xFF101919) : const Color(0xFFF1F7F5);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: scheme.onSurface,
      scrolledUnderElevation: 0,
      systemOverlayStyle: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    useMaterial3: true,
  );
}

class TrackerApp extends StatefulWidget {
  const TrackerApp({super.key, this.ads});

  final TrackerAds? ads;

  @override
  State<TrackerApp> createState() => _TrackerAppState();
}

class _TrackerAppState extends State<TrackerApp> with WidgetsBindingObserver {
  final usage = UsageService();
  ThemeMode mode = ThemeMode.system;
  String language = WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'ar' ? 'ar' : 'en';
  int appearanceRevision = 0;
  Timer? startupDeadline;
  bool loadingScreen = false;
  bool dashboardReady = false;
  bool showingAd = false;
  bool privacyChecked = false;
  bool privacyPending = false;
  bool startupInterrupted = false;
  bool savingPrivacy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    restoreAppearance();
    checkFirstLaunch();
  }

  @override
  void dispose() {
    startupDeadline?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      startupInterrupted = true;
      if (!showingAd) closeLoadingScreen();
    }
  }

  void closeLoadingScreen() {
    startupDeadline?.cancel();
    if (mounted && loadingScreen) setState(() => loadingScreen = false);
  }

  void finishDashboardStartup() {
    dashboardReady = true;
    if (!showingAd) closeLoadingScreen();
  }

  static const privacyChannel = MethodChannel('data_usage_tracker/usage');

  Future<void> checkFirstLaunch() async {
    var seen = false;
    var returning = false;
    try {
      seen = await privacyChannel.invokeMethod<bool>('privacySeen') ?? false;
      if (seen && widget.ads != null) {
        returning =
            await privacyChannel.invokeMethod<bool>('returningLaunch') ?? false;
      }
    } on PlatformException {
      // Keep startup available when the platform cannot read preferences.
    } on MissingPluginException {
      // Keep startup available on unsupported platforms.
    }
    if (!mounted) return;
    setState(() {
      privacyChecked = true;
      privacyPending = !seen;
    });
    if (seen) unawaited(restoreLanguage());
    if (returning && !startupInterrupted) {
      unawaited(prepareLaunchAd(widget.ads!));
    }
  }

  Future<void> completePrivacy() async {
    if (savingPrivacy) return;
    setState(() => savingPrivacy = true);
    try {
      final saved = await privacyChannel.invokeMethod<bool>('markPrivacySeen');
      if (saved == true && mounted) {
        setState(() => privacyPending = false);
        unawaited(restoreLanguage());
      }
    } on PlatformException {
      // Keep the notice visible so acknowledgement can be retried.
    } on MissingPluginException {
      // Keep the notice visible so acknowledgement can be retried.
    } finally {
      if (mounted) setState(() => savingPrivacy = false);
    }
  }

  Future<void> prepareLaunchAd(TrackerAds ads) async {
    LaunchAd? ad;
    try {
      if (!mounted || dashboardReady || privacyPending) return;
      setState(() => loadingScreen = true);
      startupDeadline = Timer(const Duration(seconds: 3), closeLoadingScreen);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !loadingScreen) return;
      ad = await ads.loadLaunchAd();
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (ad == null || !mounted || !loadingScreen || dashboardReady ||
          (lifecycle != null && lifecycle != AppLifecycleState.resumed)) return;
      startupDeadline?.cancel();
      showingAd = true;
      await ad.show();
    } catch (_) {
      // Ad failures should leave app startup available.
    } finally {
      ad?.dispose();
      showingAd = false;
      closeLoadingScreen();
    }
  }

  Future<void> restoreAppearance() async {
    final revision = appearanceRevision;
    try {
      final stored = await usage.appearance();
      if (!mounted || revision != appearanceRevision) return;
      setState(() => mode = switch (stored) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      });
    } on PlatformException {
      // The system theme remains the default if settings cannot be read.
    } on MissingPluginException {
      // The dashboard reports unsupported platforms separately.
    }
  }

  Future<void> changeAppearance(ThemeMode next) async {
    final revision = ++appearanceRevision;
    await usage.saveAppearance(next.name);
    if (mounted && revision == appearanceRevision) setState(() => mode = next);
  }

  Future<void> restoreLanguage() async {
    try {
      final saved = await usage.language();
      if (mounted && (saved == 'ar' || saved == 'en')) {
        setState(() => language = saved!);
      }
    } on PlatformException {
      // English is the default if preferences are unavailable.
    } on MissingPluginException {
      // The dashboard reports unsupported platforms separately.
    }
  }

  Future<void> changeLanguage(String next) async {
    await usage.saveLanguage(next);
    if (mounted) setState(() => language = next);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Data Usage Tracker',
    theme: trackerTheme(Brightness.light),
    darkTheme: trackerTheme(Brightness.dark),
    themeMode: mode,
    locale: Locale(language),
    supportedLocales: const [Locale('en'), Locale('ar')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: !privacyChecked
      ? const Scaffold(body: Center(child: CircularProgressIndicator()))
      : privacyPending
      ? PrivacyPolicyPage(firstLaunch: true, onContinue: savingPrivacy ? null : completePrivacy)
      : Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          excluding: loadingScreen,
          child: Dashboard(
            mode: mode,
            onAppearanceChanged: changeAppearance,
            onLanguageChanged: changeLanguage,
            onInitialLoadFinished: finishDashboardStartup,
            ads: loadingScreen ? null : widget.ads,
          ),
        ),
        if (loadingScreen)
          Scaffold(
            key: const ValueKey('launch-loading'),
            body: SafeArea(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const TrackerLogo(size: 56),
                    const SizedBox(height: 12),
                    Text(language == 'ar' ? 'بنحمّل الاستهلاك' : 'Loading usage'),
                    const SizedBox(height: 18),
                    const CircularProgressIndicator(),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class Dashboard extends StatefulWidget {
  const Dashboard({
    super.key,
    required this.mode,
    required this.onAppearanceChanged,
    required this.onLanguageChanged,
    required this.onInitialLoadFinished,
    this.ads,
  });

  final ThemeMode mode;
  final Future<void> Function(ThemeMode) onAppearanceChanged;
  final Future<void> Function(String) onLanguageChanged;
  final VoidCallback onInitialLoadFinished;
  final TrackerAds? ads;

  @override
  State<Dashboard> createState() => _DashboardState();
}

typedef _DailyUsage = Map<Network, NetworkUsage?>;

class _DashboardState extends State<Dashboard> with WidgetsBindingObserver {
  final usage = UsageService();
  DateTime today = calendarDay(DateTime.now());
  late DateTime day = today;
  Network network = Network.wifi;
  bool details = false;
  bool monthly = false;
  bool hasAccess = false;
  bool busy = true;
  bool initialLoadFinished = false;
  bool needsPhonePermission = false;
  String? error;
  int request = 0;
  final dailyCache = <DateTime, _DailyUsage>{};
  final periodCache = <(DateTime, bool), UsagePeriod>{};
  int cacheRevision = 0;
  bool foreground = true;
  Timer? prefetchTimer;
  (DateTime, int, Future<_DailyUsage>)? prefetchRead;
  Timer? selectionDebounce;
  int? queuedSelection;
  bool loadingSelection = false;
  String? selectionError;

  MonitorSettings monitor = const MonitorSettings();
  String filter = 'all';
  String query = '';
  String sort = 'usage';

  bool get mobile => network == Network.mobile;
  String get networkName => network.label(context);
  _DailyUsage? get dailyData => dailyCache[details ? day : today];
  (DateTime, bool) get selectedPeriod => (periodStart, monthly);
  UsagePeriod? get currentPeriod => periodCache[selectedPeriod];
  DateTime get earliest => calendarDay(mondayOf(today), -364);
  DateTime get periodStart {
    final selected = details ? day : today;
    return details && monthly
        ? DateTime(selected.year, selected.month)
        : mondayOf(selected);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    usage.onWidgetNavigation(load);
    load();
  }

  @override
  void dispose() {
    selectionDebounce?.cancel();
    prefetchTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    usage.onWidgetNavigation(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      unawaited(load());
    } else {
      prefetchTimer?.cancel();
    }
  }

  void clearUsageCache() {
    cacheRevision++;
    dailyCache.clear();
    periodCache.clear();
  }

  void rememberDay(DateTime date, _DailyUsage data) {
    dailyCache.remove(date);
    dailyCache[date] = data;
    if (dailyCache.length > 48) {
      dailyCache.remove(dailyCache.keys.firstWhere((key) => key != today && key != day));
    }
  }

  void rememberPeriod((DateTime, bool) key, UsagePeriod period) {
    periodCache[key] = period;
    if (periodCache.length > 6) periodCache.remove(periodCache.keys.first);
  }

  Iterable<DateTime> prefetchDates() sync* {
    final anchor = details ? day : today;
    final start = details ? calendarDay(periodStart, -1) : calendarDay(today, -6);
    final end = !details ? today : monthly
        ? DateTime(day.year, day.month + 1)
        : calendarDay(periodStart, 7);
    for (var offset = 1; offset <= 32; offset++) {
      final previous = calendarDay(anchor, -offset);
      final next = calendarDay(anchor, offset);
      if (previous.isBefore(start) && next.isAfter(end)) break;
      if (!previous.isBefore(start) && !previous.isBefore(earliest)) yield previous;
      if (!next.isAfter(end) && !next.isAfter(today)) yield next;
    }
  }

  void schedulePrefetch() {
    prefetchTimer?.cancel();
    if (!mounted || !foreground || !hasAccess || busy || error != null ||
        selectionError != null || prefetchRead != null || loadingSelection ||
        queuedSelection != null || selectionDebounce?.isActive == true) return;
    final target = prefetchDates().where((date) => !dailyCache.containsKey(date)).firstOrNull;
    if (target != null) {
      prefetchTimer = Timer(const Duration(milliseconds: 650), () {
        unawaited(prefetchDay(target));
      });
    }
  }

  Future<void> prefetchDay(DateTime target) async {
    final revision = cacheRevision;
    final read = usage.daily(target);
    prefetchRead = (target, revision, read);
    var completed = false;
    try {
      final data = await read;
      if (mounted && revision == cacheRevision) rememberDay(target, data);
      completed = true;
    } on PlatformException {
      // Background failures do not replace the visible selection.
    } on MissingPluginException {
      // Usage queries are only supported on Android.
    } finally {
      prefetchRead = null;
      if (completed || revision != cacheRevision) schedulePrefetch();
    }
  }

  Future<_DailyUsage> readSelectedDay(DateTime selected) {
    final pending = prefetchRead;
    if (pending != null && pending.$1 == selected && pending.$2 == cacheRevision) {
      return pending.$3;
    }
    return usage.daily(selected);
  }

  Future<void> load() async {
    if (!mounted) return;
    selectionDebounce?.cancel();
    prefetchTimer?.cancel();
    queuedSelection = null;
    final ticket = ++request;
    setState(() {
      final now = calendarDay(DateTime.now());
      if (day == today || day.isAfter(now)) day = now;
      today = now;
      if (day.isBefore(earliest)) day = earliest;
      busy = true;
      error = null;
      selectionError = null;
      clearUsageCache();
    });
    try {
      final openedNetwork = await usage.widgetNetwork();
      if (!mounted) return;
      if (openedNetwork != null) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        setState(() {
          details = openedNetwork != Network.both;
          network = details ? openedNetwork : Network.wifi;
          day = today;
          monthly = false;
          query = '';
          filter = 'all';
          sort = 'usage';
        });
        if (ticket != request) {
          await load();
          return;
        }
      }
      if (ticket != request) return;
      final allowed = await usage.hasAccess();
      if (!mounted || ticket != request) return;
      if (!allowed) {
        setState(() {
          hasAccess = false;
          busy = false;
        });
        return;
      }
      final selected = details ? day : today;
      final start = periodStart;
      final month = details && monthly;
      final phonePermission = await usage.needsPhonePermission();
      if (!mounted || ticket != request) return;
      final data = await usage.daily(selected);
      if (!mounted || ticket != request) return;
      final period = details ?
          (month ? await usage.monthly(start) : await usage.weekly(start)) : null;
      if (!mounted || ticket != request) return;
      final savedMonitor = await usage.settings();
      if (!mounted || ticket != request) return;
      setState(() {
        hasAccess = true;
        needsPhonePermission = phonePermission;
        busy = false;
        rememberDay(selected, data);
        if (period != null) rememberPeriod((start, month), period);
        monitor = savedMonitor;
      });
      schedulePrefetch();
    } on PlatformException catch (exception) {
      if (!mounted || ticket != request) return;
      setState(() {
        busy = false;
        if (exception.code == 'permission') {
          hasAccess = false;
        } else {
          error = exception.message ?? 'Could not read usage. Try again.';
        }
      });
    } on MissingPluginException {
      if (!mounted || ticket != request) return;
      setState(() {
        busy = false;
        error = 'Usage tracking is available on Android.';
      });
    } finally {
      if (mounted && ticket == request && !initialLoadFinished) {
        initialLoadFinished = true;
        widget.onInitialLoadFinished();
      }
    }
  }

  void openDetails(Network selected) {
    setState(() {
      network = selected;
      day = today;
      details = true;
      monthly = false;
      query = '';
      filter = 'all';
      sort = 'usage';
    });
    scheduleSelection();
  }

  void closeDetails() {
    setState(() => details = false);
    if (!busy && hasAccess && error == null && dailyData != null) {
      request++;
      selectionDebounce?.cancel();
      queuedSelection = null;
      selectionError = null;
      schedulePrefetch();
    } else {
      unawaited(load());
    }
  }

  void selectDay(DateTime value) {
    if (!details || value == day || value.isBefore(earliest) || value.isAfter(today)) return;
    setState(() => day = value);
    if (busy) {
      unawaited(load());
    } else {
      scheduleSelection();
    }
  }

  void scheduleSelection() {
    final ticket = ++request;
    selectionDebounce?.cancel();
    prefetchTimer?.cancel();
    queuedSelection = null;
    setState(() => selectionError = null);
    if (dailyData != null && currentPeriod != null) {
      schedulePrefetch();
      return;
    }
    selectionDebounce = Timer(const Duration(milliseconds: 120), () {
      queuedSelection = ticket;
      unawaited(loadSelection());
    });
  }

  Future<void> loadSelection() async {
    final ticket = queuedSelection;
    if (loadingSelection || ticket == null || ticket != request || !mounted) return;
    // Android serializes usage queries. Keep only the newest selection waiting.
    queuedSelection = null;
    loadingSelection = true;
    final selected = day;
    final (start, month) = selectedPeriod;
    try {
      if (dailyData == null) {
        final data = await readSelectedDay(selected);
        if (!mounted || ticket != request) return;
        setState(() => rememberDay(selected, data));
      }
      if (currentPeriod == null) {
        final period = month ? await usage.monthly(start) : await usage.weekly(start);
        if (!mounted || ticket != request) return;
        setState(() => rememberPeriod((start, month), period));
      }
    } on PlatformException catch (exception) {
      if (!mounted || ticket != request) return;
      setState(() {
        if (exception.code == 'permission') {
          hasAccess = false;
          clearUsageCache();
        } else {
          selectionError = exception.message ??
              tr(context, 'Could not read usage.', 'مقدرناش نحمّل الاستهلاك.');
        }
      });
    } on MissingPluginException {
      if (!mounted || ticket != request) return;
      setState(() => selectionError =
          tr(context, 'Usage tracking is available on Android.', 'متابعة الاستهلاك متاحة على أندرويد.'));
    } finally {
      loadingSelection = false;
      if (queuedSelection != null) {
        unawaited(loadSelection());
      } else {
        schedulePrefetch();
      }
    }
  }

  void movePeriod(int direction) {
    final target = monthly
        ? DateTime(day.year, day.month + direction)
        : calendarDay(day, direction * 7);
    selectDay(target.isAfter(today) ? today : (target.isBefore(earliest) ? earliest : target));
  }

  Future<void> chooseDate() async {
    final selected = await showDatePicker(
      context: context, initialDate: day, firstDate: earliest, lastDate: today,
    );
    if (selected != null && mounted) selectDay(selected);
  }

  Future<void> platformAction(Future<void> Function() action, {bool reload = false}) async {
    try {
      await action();
      if (reload && mounted) load();
    } on PlatformException catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(exception.message ?? 'Could not complete this action.')),
      );
    }
  }

  void requestPhonePermission() => platformAction(usage.requestPhonePermission, reload: true);

  Future<void> chooseAppearance() async {
    final next = await showDialog<ThemeMode>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(tr(context, 'Appearance', 'المظهر')),
        children: [
          for (final mode in ThemeMode.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, mode),
              child: Row(
                children: [
                  Icon(switch (mode) {
                    ThemeMode.system => Icons.brightness_auto_outlined,
                    ThemeMode.light => Icons.light_mode_outlined,
                    ThemeMode.dark => Icons.dark_mode_outlined,
                  }),
                  const SizedBox(width: 14),
                  Expanded(child: Text(mode.displayLabel(context))),
                  if (widget.mode == mode) const Icon(Icons.check, semanticLabel: 'Selected'),
                ],
              ),
            ),
        ],
      ),
    );
    if (next != null && next != widget.mode && mounted) {
      await platformAction(() => widget.onAppearanceChanged(next));
    }
  }

  Future<void> chooseLanguage() async {
    final next = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr(context, 'Language', 'اللغة')),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 'en'), child: const Text('English')),
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 'ar'), child: const Text('العربية')),
        ],
      ),
    );
    if (next != null && mounted) await platformAction(() => widget.onLanguageChanged(next));
  }

  Future<void> editPlan() async {
    final next = await showDialog<MonitorSettings>(
      context: context, builder: (_) => PlanEditor(settings: monitor),
    );
    if (next == null || !mounted) return;
    if ((next.thresholds || next.spikes || next.customThresholds.isNotEmpty) && !await usage.notificationPermission()) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(context, 'Notification permission is off.', 'إذن الإشعارات مقفول.')),
      ));
    }
    if (!mounted) return;
    await platformAction(() => saveMonitor(next));
  }

  Future<void> saveMonitor(MonitorSettings settings) async {
    await usage.saveSettings(settings);
    if (mounted) setState(() => monitor = settings);
  }

  Future<void> addWidget() async {
    final selected = await showModalBottomSheet<Network>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Text(tr(context, 'Choose a home screen widget', 'اختار ويدجت للشاشة الرئيسية'),
                  style: Theme.of(context).textTheme.titleLarge),
              ),
              for (final network in [Network.wifi, Network.mobile, Network.both])
                ListTile(
                  leading: Icon(network.icon),
                  title: Text(network == Network.both
                    ? tr(context, 'Wi-Fi + mobile data', 'الواي فاي + داتا الموبايل')
                    : network.label(context)),
                  subtitle: Text(network == Network.both ? "3 × 1" : "2 × 1"),
                  trailing: const Icon(Icons.add_to_home_screen),
                  onTap: () => Navigator.pop(sheetContext, network),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    var requested = false;
    try {
      requested = await usage.pinWidget(selected);
    } on PlatformException {
      // Some launchers only support adding widgets through their picker.
    }
    if (requested || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'Add the home screen widget', 'ضيف الويدجت للشاشة الرئيسية')),
        content: Text(tr(context,
          'Touch and hold an empty spot on your home screen, choose Widgets, then drag Data Usage Tracker onto the screen.',
          'اضغط مطوّل على مكان فاضي في الشاشة الرئيسية، اختار الأدوات (Widgets)، واسحب Data Usage Tracker للشاشة.')),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, 'Done', 'تمام')))],
      ),
    );
  }

  void openReports() => Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => RangeReportPage(service: usage, network: Network.wifi, today: today),
  ));

  void openApp(AppUsage app, DateTime date) => Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppHistoryPage(
      app: app, day: date, service: usage, pinned: monitor.pinned.contains(app.identity),
      onPin: () {
        final pins = {...monitor.pinned};
        if (!pins.remove(app.identity)) pins.add(app.identity);
        return saveMonitor(monitor.withPins(pins));
      },
    ),
  ));

  void showSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: Text(tr(context, 'Appearance', 'المظهر')),
              subtitle: Text(widget.mode.displayLabel(context)),
              onTap: () {
                Navigator.pop(sheetContext);
                chooseAppearance();
              },
            ),
            ListTile(
              leading: const Icon(Icons.translate),
              title: Text(tr(context, 'Language', 'اللغة')),
              onTap: () {
                Navigator.pop(sheetContext);
                chooseLanguage();
              },
            ),
            ListTile(
              leading: const Icon(Icons.data_usage),
              title: Text(tr(context, 'Mobile data plan', 'باقة الموبايل')),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(editPlan());
              },
            ),
            ListTile(
              leading: const Icon(Icons.widgets_outlined),
              title: Text(tr(context, 'Home screen widget', 'ويدجت الشاشة الرئيسية')),
              onTap: () {
                Navigator.pop(sheetContext);
                addWidget();
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(tr(context, 'Refresh usage', 'حدّث الاستهلاك')),
              onTap: () {
                Navigator.pop(sheetContext);
                load();
              },
            ),
            ListTile(
              leading: const Icon(Icons.shield_outlined),
              title: Text(tr(context, 'Privacy & Data', 'الخصوصية والبيانات')),
              subtitle: Text(tr(context, 'Permissions, local data and advertising', 'الأذونات والبيانات المحلية والإعلانات')),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const PrivacyPolicyPage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: Text(tr(context, 'Usage access settings', 'إعدادات إذن الاستخدام')),
              onTap: () {
                Navigator.pop(sheetContext);
                platformAction(usage.openSettings);
              },
            ),
          ],
        )),
      ),
    );
  }

  void openPlan() => Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => StatefulBuilder(builder: (context, update) => Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Mobile data plan', 'باقة الموبايل'))),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PlanSummary(settings: monitor, service: usage, today: today, revision: request,
            onEdit: () async {
              await editPlan();
              if (context.mounted) update(() {});
            }),

        ],
      )),
    )),
  ));

  void openAppHighlights() {
    final daily = dailyData;
    if (daily == null) return;
    final data = daily[network];
    final selected = day;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr(context, 'Top apps', 'أعلى التطبيقات استهلاكًا'),
              style: Theme.of(context).textTheme.titleMedium),
            if (data == null || data.apps.isEmpty)
              Text(tr(context, 'No app activity for this day.', 'مفيش استهلاك للتطبيقات في اليوم ده.')),
            for (final app in data?.apps.take(3) ?? <AppUsage>[])
              ListTile(
                title: Text(displayAppName(context, app.name)),
                trailing: Text('${formatBytes(app.bytes)} · ${data!.appTotal <= 0 ? '—' :
                    '${(app.bytes * 100 / data.appTotal).toStringAsFixed(1)}%'}'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  openApp(app, selected);
                },
              ),
            const SizedBox(height: 12),
            Text(tr(context, 'Pinned apps', 'التطبيقات المثبّتة'),
              style: Theme.of(context).textTheme.titleMedium),
            if (monitor.pinned.isEmpty)
              Text(tr(context, 'Pin an app from its usage history.', 'ثبّت أي تطبيق من صفحة سجل استهلاكه.')),
            for (final pin in monitor.pinned)
              pinnedTile(sheetContext, pin, data, daily, selected),
          ],
        ),
      )),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !details,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && details) closeDetails();
    },
    child: Scaffold(
      appBar: AppBar(
        toolbarHeight: details ? 56 : 72,
        centerTitle: details,
        leading: details
            ? IconButton(tooltip: tr(context, 'Back to overview', 'ارجع للملخص'), onPressed: closeDetails,
                icon: const Icon(Icons.arrow_back))
            : null,
        title: details
            ? Text(networkName, style: const TextStyle(fontWeight: FontWeight.w800))
            : Row(children: [
                const TrackerLogo(),
                const SizedBox(width: 12),
                Flexible(child: Text('Data Usage Tracker', maxLines: 2,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
              ]),
        actions: [
          if (!details || (hasAccess && !busy && error == null))
            IconButton(
              tooltip: details ? tr(context, 'App highlights', 'أهم التطبيقات') : tr(context, 'Settings', 'الإعدادات'),
              onPressed: !details ? showSettings : dailyData == null ? null : openAppHighlights,
              icon: Icon(details ? Icons.star_outline : Icons.settings),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (hasAccess && widget.ads != null)
              LayoutBuilder(builder: (context, constraints) =>
                constraints.maxWidth >= 320
                    ? widget.ads!.banner()
                    : const SizedBox.shrink(),
              ),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 940),
                  child: error != null
                      ? notice(Icons.error_outline, error!, tr(context, 'Retry', 'جرّب تاني'), load)
                      : !hasAccess && !busy
                      ? notice(
                          Icons.lock_outline,
                          tr(context, 'Enable Usage access for Data Usage Tracker to see network usage.', 'فعّل إذن الوصول للاستخدام لتطبيق Data Usage Tracker عشان تشوف استهلاك الشبكة.'),
                          tr(context, 'Open Usage access settings', 'افتح إعدادات إذن الاستخدام'),
                          () => platformAction(usage.openSettings),
                        )
                      : busy
                      ? const Center(child: CircularProgressIndicator())
                      : details ? detailsView(context) : overview(context),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget notice(IconData icon, String text, String label, VoidCallback action) =>
      Center(child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary, size: 42),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton(onPressed: action, child: Text(label)),
          ],
        ),
      ));

  Widget mobileAccessNotice() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      children: [
        Text(
          needsPhonePermission
              ? tr(context, 'Android 7–9 needs Phone permission to read mobile data usage.',
                  'أندرويد ٧–٩ محتاج إذن الهاتف لقراءة استهلاك الداتا.')
              : tr(context, 'Android could not read mobile data for an active SIM.',
                  'أندرويد مقدرش يقرأ استهلاك الداتا لشريحة مفعّلة.'),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        if (needsPhonePermission)
          TextButton(onPressed: requestPhonePermission, child: Text(tr(context, 'Allow mobile data access', 'اسمح بقراءة استهلاك الداتا'))),
      ],
    ),
  );

  Widget overview(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      key: const PageStorageKey('usage-home'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text(tr(context, 'Today’s usage', 'استهلاك النهارده'),
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, constraints) {
          final tiles = [
            analysisTile(Network.wifi, scheme.primary),
            analysisTile(Network.mobile, scheme.secondary),
          ];
          if (constraints.maxWidth < 350 || MediaQuery.textScalerOf(context).scale(16) > 21) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              tiles.first, const SizedBox(height: 10), tiles.last,
            ]);
          }
          return Row(children: [
            Expanded(child: tiles.first),
            const SizedBox(width: 12),
            Expanded(child: tiles.last),
          ]);
        }),
        const SizedBox(height: 20),
        surface(context, child: ListTile(
          leading: Icon(Icons.add_to_home_screen, color: scheme.primary),
          title: Text(tr(context, 'Add widget', 'ضيف ويدجت')),
          subtitle: Text(tr(context, 'Choose a widget for your Android home screen',
            'اختار ويدجت لشاشة الموبايل الرئيسية')),
          trailing: const Icon(Icons.chevron_right),
          onTap: addWidget,
        )),
        const SizedBox(height: 10),
        surface(context, child: ListTile(
          leading: const Icon(Icons.analytics_outlined),
          title: Text(tr(context, 'Usage reports', 'تقارير الاستهلاك')),
          subtitle: Text(tr(context, 'Compare weeks, pick dates, or export CSV', 'قارن الأسابيع أو اختار تواريخ أو صدّر CSV')),
          trailing: const Icon(Icons.chevron_right),
          onTap: openReports,
        )),
        const SizedBox(height: 10),
        surface(context, child: ListTile(
          leading: const Icon(Icons.donut_large_outlined),
          title: Text(tr(context, 'Mobile data plan', 'باقة الموبايل')),
          subtitle: Text(tr(context, 'Balance, renewal, and alerts', 'المتبقي والتجديد والتنبيهات')),
          trailing: const Icon(Icons.chevron_right),
          onTap: openPlan,
        )),
      ],
    );
  }

  Widget analysisTile(Network selected, Color accent) {
    final theme = Theme.of(context);
    final bytes = dailyData?[selected]?.total;
    final label = selected == Network.wifi
        ? tr(context, 'Analyze Wi-Fi', 'حلّل الواي فاي')
        : tr(context, 'Analyze mobile data', 'حلّل داتا الموبايل');
    return surface(context, child: InkWell(
      onTap: () => openDetails(selected),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(selected.icon, color: accent),
            const SizedBox(height: 10),
            Text(selected.label(context), style: theme.textTheme.titleSmall),
            Text(usageLabel(bytes),
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Text(label, style: TextStyle(color: accent, fontWeight: FontWeight.w700))),
              Icon(Icons.chevron_right, color: accent, size: 18),
            ]),
          ],
        ),
      ),
    ));
  }

  Widget pinnedTile(BuildContext context, String pin, NetworkUsage? data,
      Map<Network, NetworkUsage?> daily, DateTime selected) {
    final selectedApp = data?.apps.where((app) => app.identity == pin).firstOrNull;
    final recentApp = selectedApp ?? daily.values
        .expand((value) => value?.apps ?? <AppUsage>[])
        .where((app) => app.identity == pin).firstOrNull;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.push_pin_outlined),
      title: Text(recentApp?.name ?? pin),
      subtitle: recentApp?.package == null ? null : Text(recentApp!.package!),
      trailing: Text(data == null ? '—' : formatBytes(selectedApp?.bytes ?? 0)),
      onTap: recentApp == null ? null : () {
        Navigator.pop(context);
        openApp(recentApp, selected);
      },
      onLongPress: () {
        Navigator.pop(context);
        platformAction(() => saveMonitor(monitor.withPins({...monitor.pinned}..remove(pin))));
      },
    );
  }

  Widget detailsView(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = mobile ? scheme.secondary : scheme.primary;
    final daily = dailyData;
    final data = daily?[network];
    final period = currentPeriod;
    final total = period?.total.forNetwork(network);
    final cutoff = monthly ? DateTime(day.year, day.month + 1) : calendarDay(periodStart, 7);
    final lastDay = calendarDay(cutoff, -1);
    final amounts = period?.days.map((day) => day?.forNetwork(network)).toList() ??
        List<int?>.filled(monthly ? lastDay.day : 7, null);
    final displayedEnd = lastDay.isAfter(today) ? today : lastDay;
    final updating = selectionError == null && (daily == null || period == null);
    final needle = query.trim().toLowerCase();
    final apps = (data?.apps ?? <AppUsage>[]).where((app) =>
        (filter == 'all' || (filter == 'system' && app.system == true) ||
          (filter == 'user' && app.system == false)) &&
        (app.name.toLowerCase().contains(needle) ||
          (app.package?.toLowerCase().contains(needle) ?? false))).toList();
    if (sort == 'name') apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (sort == 'low') apps.sort((a, b) => a.bytes.compareTo(b.bytes));
    return ListView.builder(
      key: ValueKey(network),
      padding: const EdgeInsets.fromLTRB(16, 5, 16, 24),
      itemCount: apps.length + 1,
      itemBuilder: (context, index) {
        if (index > 0) {
          final app = apps[index - 1];
          return InkWell(
            onTap: () => openApp(app, day),
            child: AppRow(
            key: ValueKey('${network.name}:${app.package}:${app.name}:$index'),
            app: app, color: accent,
            total: data!.appTotal,
            service: usage,
          ));
        }
        final dates = MaterialLocalizations.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            surface(context, child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(children: [
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${period == null ? '—' : usageLabel(total)} · ${monthly ? tr(context, 'Monthly total', 'إجمالي الشهر') : tr(context, 'Weekly total', 'إجمالي الأسبوع')}',
                            style: TextStyle(fontWeight: FontWeight.w700, color: accent)),
                          Text('${dates.formatShortDate(periodStart)} – ${dates.formatShortDate(displayedEnd)}',
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                        ],
                      )),
                      IconButton(
                        tooltip: tr(context, 'About usage totals', 'عن أرقام الاستهلاك'),
                        onPressed: () => showUsageExplanation(context),
                        icon: const Icon(Icons.info_outline, size: 19),
                      ),
                    ]),
                  ),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      periodButton(tr(context, 'Weekly', 'أسبوعي'), !monthly),
                      periodButton(tr(context, 'Monthly', 'شهري'), monthly),
                      IconButton(tooltip: tr(context, 'Pick date', 'اختار تاريخ'), onPressed: chooseDate,
                        icon: const Icon(Icons.calendar_month_outlined)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      IconButton(
                        tooltip: monthly ? tr(context, 'Previous month', 'الشهر السابق') : tr(context, 'Previous week', 'الأسبوع السابق'),
                        icon: const Icon(Icons.chevron_left),
                        onPressed: periodStart.isAfter(monthly
                            ? DateTime(earliest.year, earliest.month) : earliest)
                            ? () => movePeriod(-1) : null,
                      ),
                      Expanded(child: Column(
                        children: [
                          Text(dates.formatMediumDate(day), textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.w800)),
                          Text(daily == null ? '—' : usageLabel(data?.total),
                            style: TextStyle(color: scheme.onSurfaceVariant),
                            semanticsLabel: daily == null ? null : tr(context, 'Device total: ${usageLabel(data?.total)}',
                              'إجمالي الجهاز: ${usageLabel(data?.total)}')),
                        ],
                      )),
                      IconButton(
                        tooltip: monthly ? tr(context, 'Next month', 'الشهر التالي') : tr(context, 'Next week', 'الأسبوع التالي'),
                        icon: const Icon(Icons.chevron_right),
                        onPressed: periodStart.isBefore(monthly
                            ? DateTime(today.year, today.month) : mondayOf(today))
                            ? () => movePeriod(1) : null,
                      ),
                    ],
                  ),
                  SizedBox(
                    height: 2,
                    child: updating ? LinearProgressIndicator(
                      minHeight: 2,
                      semanticsLabel: tr(context, 'Updating usage', 'بنحدّث الاستهلاك'),
                    ) : null,
                  ),
                  PeriodChart(
                    start: periodStart, day: day, amounts: amounts,
                    monthly: monthly, earliest: earliest, today: today, onDay: selectDay, accent: accent,
                  ),
                ],
              ),
            )),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                ActionChip(label: Text(tr(context, 'Today', 'النهارده')), onPressed: () => selectDay(today)),
                ActionChip(label: Text(tr(context, 'Yesterday', 'امبارح')),
                  onPressed: () => selectDay(calendarDay(today, -1))),
              ],
            ),
            const SizedBox(height: 10),
            Text(tr(context, '$networkName usage by app', 'استهلاك التطبيقات · $networkName'),
              style: Theme.of(context).textTheme.titleMedium),
            if (selectionError case final String message)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(message),
                trailing: TextButton(
                  onPressed: scheduleSelection,
                  child: Text(tr(context, 'Retry', 'جرّب تاني')),
                ),
              ),
            if (data != null && data.apps.isNotEmpty) ...[
              Text(tr(context, 'All recorded apps: ${formatBytes(data.appTotal)}',
                'إجمالي التطبيقات المسجّلة: ${formatBytes(data.appTotal)}'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              TextFormField(
                initialValue: query,
                onChanged: (value) => setState(() => query = value),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: tr(context, 'Search apps or packages', 'ابحث عن اسم تطبيق أو حزمة'),
                ),
              ),
              Wrap(spacing: 8, children: [
                DropdownButton<String>(
                  value: filter, onChanged: (value) => setState(() => filter = value ?? 'all'),
                  items: [
                    DropdownMenuItem(value: 'all', child: Text(tr(context, 'All apps', 'كل التطبيقات'))),
                    DropdownMenuItem(value: 'user', child: Text(tr(context, 'Installed apps', 'تطبيقات المستخدم'))),
                    DropdownMenuItem(value: 'system', child: Text(tr(context, 'System apps', 'تطبيقات النظام'))),
                  ],
                ),
                DropdownButton<String>(
                  value: sort, onChanged: (value) => setState(() => sort = value ?? 'usage'),
                  items: [
                    DropdownMenuItem(value: 'usage', child: Text(tr(context, 'Most used', 'الأعلى استهلاكًا'))),
                    DropdownMenuItem(value: 'low', child: Text(tr(context, 'Least used', 'الأقل استهلاكًا'))),
                    DropdownMenuItem(value: 'name', child: Text(tr(context, 'Name', 'الاسم'))),
                  ],
                ),
              ]),
              if (apps.isEmpty) Text(tr(context, 'No matching apps', 'مفيش تطبيقات مطابقة')),
            ],
            if (daily != null && data == null)
              mobileAccessNotice()
            else if (data != null && data.apps.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(tr(context, 'Android has no per-app records for this date and network.', 'أندرويد معندوش سجلات للتطبيقات على الشبكة دي في التاريخ ده.'),
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
          ],
        );
      },
    );
  }

  Widget periodButton(String label, bool selected) => ChoiceChip(
    label: Text(label),
    selected: selected,
    onSelected: (_) {
      if (selected) return;
      setState(() => monthly = !monthly);
      scheduleSelection();
    },
  );
}

String usageLabel(int? bytes) => bytes == null ? 'Unavailable' : formatBytes(bytes);

Widget surface(BuildContext context, {required Widget child}) {
  final scheme = Theme.of(context).colorScheme;
  return Card(
    margin: EdgeInsets.zero,
    color: scheme.surface,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: scheme.outlineVariant),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class PeriodChart extends StatefulWidget {
  const PeriodChart({
    super.key, required this.start, required this.day, required this.amounts,
    required this.monthly, required this.earliest, required this.today, required this.onDay,
    required this.accent,
  });

  final DateTime start;
  final DateTime day;
  final List<int?> amounts;
  final bool monthly;
  final DateTime earliest;
  final DateTime today;
  final ValueChanged<DateTime> onDay;
  final Color accent;

  @override
  State<PeriodChart> createState() => _PeriodChartState();
}

class _PeriodChartState extends State<PeriodChart> {
  final controller = ScrollController();
  static const dayWidth = 42.0;

  @override
  void initState() {
    super.initState();
    if (widget.monthly) WidgetsBinding.instance.addPostFrameCallback((_) => centerDay());
  }

  @override
  void didUpdateWidget(PeriodChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.monthly && (widget.day != oldWidget.day || !oldWidget.monthly)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => centerDay());
    }
  }

  void centerDay() {
    if (!mounted || !controller.hasClients) return;
    final position = controller.position;
    final offset = dayWidth * (widget.day.day - .5) - position.viewportDimension / 2;
    controller.jumpTo(offset.clamp(0.0, position.maxScrollExtent).toDouble());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peak = widget.amounts.whereType<int>().fold<int>(1, math.max);
    final dates = MaterialLocalizations.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final height = constraints.maxWidth >= 560 ? 158.0 : 117.0;
      final columns = List.generate(widget.amounts.length, (index) {
        final date = calendarDay(widget.start, index);
        final bytes = widget.amounts[index];
        final selected = date == widget.day;
        final enabled = !date.isAfter(widget.today) && !date.isBefore(widget.earliest);
        final barHeight = bytes == null || bytes == 0 ? 3.0 : math.max(4.0, (height - 22) * bytes / peak);
        final label = widget.monthly
            ? '${date.day}'
            : dates.narrowWeekdays[date.weekday % 7];
        final bar = Semantics(
          button: true, selected: selected, enabled: enabled,
          label: '${dates.formatFullDate(date)}, ${usageLabel(bytes)}',
          child: InkWell(
            key: ValueKey('chart-day-${date.toIso8601String()}'),
            onTap: enabled ? () => widget.onDay(date) : null,
            borderRadius: BorderRadius.circular(8),
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: height,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        width: widget.monthly ? 17 : 30,
                        height: barHeight,
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
                          color: bytes == null || bytes == 0
                              ? scheme.surfaceContainerHighest
                              : selected ? widget.accent : widget.accent.withValues(alpha: .42),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(label, style: TextStyle(
                    fontSize: 12, color: selected ? widget.accent : scheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w400,
                  )),
                ],
              ),
            ),
          ),
        );
        return widget.monthly ? SizedBox(width: dayWidth, child: bar) : Expanded(child: bar);
      });
      return widget.monthly
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal, controller: controller,
              child: Row(children: columns))
          : Row(children: columns);
    });
  }
}
