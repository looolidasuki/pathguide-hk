import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/navigation/navigation_models.dart';
import 'package:pathguide/navigation/navigation_services.dart';
import 'package:pathguide/navigation/navigation_controller.dart';
import 'package:pathguide/navigation/route_progress.dart';
import 'package:pathguide/navigation/navigation_page.dart';
import 'package:pathguide/navigation/platform_navigation.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/menu/menu_reader.dart';

// Synthetic metre-scale fixtures: no stored provider route content or real tracks.
Coordinate point(double east, [double north = 0]) =>
    Coordinate(22.3 + north / 111195, 114.2 + east / 102870);
Place place([MapProvider provider = MapProvider.apple]) => Place(
  provider: provider,
  id: 'destination',
  name: '測試目的地',
  address: '香港測試地址',
  coordinate: point(200),
);
WalkingRoute route([MapProvider provider = MapProvider.apple]) => WalkingRoute(
  provider: provider,
  id: 'test',
  polyline: [point(0), point(100), point(200)],
  steps: [
    RouteStep(instructions: '沿測試街前進', polyline: [point(0), point(100)]),
    RouteStep(instructions: '左轉進入測試路', polyline: [point(100), point(200)]),
  ],
  distance: 200,
  duration: 180,
);
LocationFix fix(
  double east, {
  double north = 0,
  int seconds = 0,
  double accuracy = 5,
  double age = 0,
}) => LocationFix(
  coordinate: point(east, north),
  accuracy: accuracy,
  receivedAt: Duration(seconds: seconds),
  ageSeconds: age,
);

class MemoryStore implements DestinationStore {
  List<SavedDestination> favorites = [], recent = [];
  bool broken = false;
  @override
  Future<({List<SavedDestination> favorites, List<SavedDestination> recent})>
  load() async {
    if (broken) throw const NavigationFailure('storage', '未能讀取收藏。');
    return (favorites: favorites, recent: recent);
  }

  @override
  Future<void> save(List<SavedDestination> a, List<SavedDestination> b) async {
    favorites = List.from(a);
    recent = List.from(b);
  }
}

class Services
    implements PlaceSearchService, WalkingRouteService, LocationService {
  @override
  MapProvider get provider => MapProvider.apple;
  final stream = StreamController<LocationFix>.broadcast(sync: true);
  int starts = 0, stops = 0, calculations = 0;
  bool awake = false;
  Duration now = Duration.zero;
  Completer<List<Place>>? searchPending;
  Completer<WalkingRoute>? routePending;
  Completer<LocationFix>? fixPending;
  Completer<void>? wakePending;
  Object? routeFailure;
  LocationFix? nextFix;
  @override
  Future<List<Place>> search(String text) =>
      searchPending?.future ?? Future.value([place()]);
  @override
  Future<Place> resolve(SavedDestination p) async => place();
  @override
  Future<void> cancelSearch() async {}
  @override
  Future<WalkingRoute> calculate(Coordinate origin, Place destination) async {
    calculations++;
    if (routeFailure != null) throw routeFailure!;
    return routePending?.future ?? route(destination.provider);
  }

  @override
  Future<void> cancelRoute() async {}
  @override
  Future<LocationFix> current() =>
      fixPending?.future ??
      Future.value(nextFix ?? fix(0, seconds: now.inSeconds));
  @override
  Stream<LocationFix> get updates => stream.stream;
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> keepAwake(bool value) async {
    if (value && wakePending != null) await wakePending!.future;
    awake = value;
  }

  @override
  Future<String?> address(Coordinate c) async => null;
  void emit(double east, {double north = 0, double accuracy = 5}) => stream.add(
    fix(east, north: north, accuracy: accuracy, seconds: now.inSeconds),
  );
}

class SilentSpeech implements SpeechInputService {
  @override
  Future<MenuSpeechResult> listen({
    required bool allowNetwork,
    required void Function(String) onPartial,
    required void Function(MenuSpeechPhase) onPhase,
  }) async =>
      const MenuSpeechResult(MenuSpeechOutcome.finalText, text: '我想去測試目的地');
  @override
  Future<void> cancel() async {}
  @override
  void dispose() {}
}

class RecordingNavigationSpeaker extends NullSpeaker {
  final words = <String>[];
  @override
  Future<void> speak(String text) async {
    words.add(text);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('provider-independent geometry and navigation rules', () {
    test('Apple and Google normalized routes have the same progress', () {
      final a = RouteProgress(
        WalkingRoute.fromMap(route().toMap()),
        point(200),
      );
      final g = RouteProgress(
        WalkingRoute.fromMap(route(MapProvider.google).toMap()),
        point(200),
      );
      for (var s = 0; s <= 60; s += 10) {
        a.update(fix(s.toDouble(), seconds: s), Duration(seconds: s));
        g.update(fix(s.toDouble(), seconds: s), Duration(seconds: s));
      }
      expect(a.along, closeTo(60, 1));
      expect(g.along, closeTo(a.along, .01));
      expect(a.nextDistance, closeTo(40, 1));
    });
    test('single GPS jump does not advance a step', () {
      final p = RouteProgress(route(), point(200));
      expect(
        p.update(fix(110, seconds: 1), const Duration(seconds: 1)).uncertain,
        true,
      );
      expect(p.stepIndex, 0);
      expect(p.along, 0);
    });
    test('advance and near prompts are each spoken once; progression needs two fixes', () {
      final p = RouteProgress(route(), point(200));
      final messages = <String>[];
      var s = 0;
      for (final east in [0, 20, 40, 55, 60, 80, 87, 90, 92, 106, 108]) {
        s += 10;
        final u = p.update(
          fix(east.toDouble(), seconds: s),
          Duration(seconds: s),
        );
        if (u.message != null) messages.add(u.message!);
      }
      expect(messages.where((text) => text.startsWith('約 ')), hasLength(2));
      expect(messages.last, '左轉進入測試路');
      expect(p.stepIndex, 1);
    });
    test(
      'deviation needs three points lasting ten seconds and no stale evidence',
      () {
        final p = RouteProgress(route(), point(200));
        expect(p.update(fix(0, north: 80), Duration.zero).deviated, false);
        expect(
          p
              .update(fix(0, north: 80, seconds: 5), const Duration(seconds: 5))
              .deviated,
          false,
        );
        expect(
          p
              .update(
                fix(0, north: 80, seconds: 10),
                const Duration(seconds: 10),
              )
              .deviated,
          true,
        );
        p.update(
          fix(0, seconds: 11, accuracy: 100),
          const Duration(seconds: 11),
        );
        expect(
          p
              .update(
                fix(0, north: 80, seconds: 12),
                const Duration(seconds: 12),
              )
              .deviated,
          false,
        );
      },
    );
    test(
      'parallel legs and crossings are uncertain rather than silently snapping',
      () {
        final r = WalkingRoute(
          provider: MapProvider.apple,
          id: 'parallel',
          polyline: [point(0), point(150), point(150, 8), point(0, 8)],
          steps: [
            RouteStep(instructions: '前進', polyline: [point(0), point(150)]),
            RouteStep(
              instructions: '折返',
              polyline: [point(150, 8), point(0, 8)],
            ),
          ],
          distance: 308,
          duration: 300,
        );
        final p = RouteProgress(r, point(0, 8));
        expect(p.update(fix(0, north: 4), Duration.zero).uncertain, true);
        expect(p.stepIndex, 0);
      },
    );
    test('final proximity is not an automatic completed session', () {
      final p = RouteProgress(route(), point(200));
      var nearby = false;
      var seconds = 0;
      for (var east = 0; east <= 190; east += 10) {
        seconds += 10;
        nearby = p
            .update(
              fix(east.toDouble(), seconds: seconds),
              Duration(seconds: seconds),
            )
            .nearby;
      }
      expect(nearby, true);
    });
    test('age, imprecise location and invalid coordinate are rejected', () {
      expect(
        fix(0, age: 11).usable(Duration.zero, const NavigationRules()),
        false,
      );
      expect(
        fix(0, accuracy: 26).usable(Duration.zero, const NavigationRules()),
        false,
      );
      expect(
        fix(0).usable(const Duration(seconds: 11), const NavigationRules()),
        false,
      );
      expect(
        () => Coordinate.fromMap({'latitude': double.nan, 'longitude': 114}),
        throwsA(isA<NavigationFailure>()),
      );
      expect(
        () => WalkingRoute.fromMap({...route().toMap(), 'steps': []}),
        throwsA(isA<NavigationFailure>()),
      );
    });
    test(
      'Google favorites contain no provider address, coordinate or route',
      () {
        final saved = SavedDestination.fromPlace(
          place(MapProvider.google),
          '我的學校',
        );
        final text = jsonEncode(saved.toMap());
        expect(text, contains('我的學校'));
        expect(text, contains('destination'));
        expect(text, isNot(contains('coordinate')));
        expect(text, isNot(contains('香港測試地址')));
        expect(
          SavedDestination.fromMap(jsonDecode(text) as Map).applePlace,
          isNull,
        );
      },
    );
    test(
      'destination speech prefixes are independent of menu normalization',
      () {
        expect(destinationQuery('我想去調景嶺站'), '調景嶺站');
        expect(destinationQuery('唔該，帶我去 HKDI'), 'HKDI');
        expect(destinationQuery('去水街'), '去水街');
      },
    );
  });
  test('cached locations cannot accumulate deviation evidence', () {
    final p = RouteProgress(route(), point(200));
    final cached = fix(0, north: 80);
    p.update(cached, Duration.zero);
    expect(p.update(cached, const Duration(seconds: 5)).deviated, false);
    expect(p.update(cached, const Duration(seconds: 10)).deviated, false);
  });
  test('step notices survive normalization and enter replay text', () {
    final r = WalkingRoute(
      provider: MapProvider.apple,
      id: 'notices',
      polyline: [point(0), point(100)],
      steps: [
        RouteStep(
          instructions: '前進',
          notice: '留意路口',
          polyline: [point(0), point(100)],
        ),
      ],
      distance: 100,
      duration: 90,
    );
    expect(
      RouteProgress(WalkingRoute.fromMap(r.toMap()), point(100)).instruction,
      contains('留意路口'),
    );
  });
  test('blank short step does not invent a maneuver', () {
    final r = WalkingRoute(
      provider: MapProvider.google,
      id: 'short',
      polyline: [point(0), point(20)],
      steps: [
        RouteStep(instructions: ' \n ', polyline: [point(0), point(20)]),
      ],
      distance: 20,
      duration: 20,
    );
    final p = RouteProgress(r, point(20));
    expect(p.instruction, '沿目前路線前進。');
    expect(p.route.steps.first.maneuver, 'unknown');
  });
  test('empty departure marker does not hide the first real instruction', () {
    final original = route();
    final p = RouteProgress(
      WalkingRoute(
        provider: MapProvider.apple,
        id: 'departure',
        polyline: original.polyline,
        steps: [
          RouteStep(instructions: '', polyline: [point(0)]),
          ...original.steps,
        ],
        distance: original.distance,
        duration: original.duration,
      ),
      point(200),
    );
    expect(p.instruction, '沿測試街前進');
  });
  test(
    'a single point beyond a turn cannot be confirmed by a point before it',
    () {
      final p = RouteProgress(route(), point(200));
      var seconds = 0;
      for (final east in [0, 20, 40, 60, 80, 95, 107, 96]) {
        seconds += 10;
        p.update(
          fix(east.toDouble(), seconds: seconds),
          Duration(seconds: seconds),
        );
      }
      expect(p.stepIndex, 0);
      p.update(fix(108, seconds: 90), const Duration(seconds: 90));
      final confirmed = p.update(
        fix(110, seconds: 100),
        const Duration(seconds: 100),
      );
      expect(p.stepIndex, 1);
      expect(confirmed.message, '左轉進入測試路');
    },
  );
  test('a short leg omits the fifty metre advance notice', () {
    final p = RouteProgress(
      WalkingRoute(
        provider: MapProvider.apple,
        id: 'short-leg',
        polyline: [point(0), point(30), point(100)],
        steps: [
          RouteStep(instructions: '前進', polyline: [point(0), point(30)]),
          RouteStep(instructions: '右轉', polyline: [point(30), point(100)]),
        ],
        distance: 100,
        duration: 100,
      ),
      point(100),
    );
    expect(p.update(fix(0), Duration.zero).message, isNull);
    p.update(fix(18, seconds: 10), const Duration(seconds: 10));
    expect(
      p.update(fix(20, seconds: 20), const Duration(seconds: 20)).message,
      contains('右轉'),
    );
  });
  group('navigation session lifecycle', () {
    late Services services;
    late NavigationController nav;
    late MemoryStore store;
    setUp(() {
      services = Services();
      store = MemoryStore();
      nav = NavigationController(
        searchService: services,
        routeService: services,
        location: services,
        store: store,
        clock: () => services.now,
      );
    });
    tearDown(() async {
      nav.dispose();
      await services.stream.close();
    });
    test('superseded search cannot replace a newer result', () async {
      final old = Completer<List<Place>>();
      services.searchPending = old;
      final task = nav.search('舊地點');
      await Future<void>.delayed(Duration.zero);
      services.searchPending = null;
      await nav.search('新地點');
      old.complete([]);
      await task;
      expect(nav.results.single.id, place().id);
    });
    test('late wake acquisition after pause is released', () async {
      await nav.select(place());
      services.wakePending = Completer<void>();
      final task = nav.start();
      await Future<void>.delayed(Duration.zero);
      await nav.pause();
      services.wakePending!.complete();
      await task;
      expect(nav.state, NavigationState.paused);
      expect(services.awake, false);
    });
    test('old completion cannot unlock an in-flight new calculation', () async {
      final old = Completer<WalkingRoute>();
      services.routePending = old;
      final selection = nav.select(place());
      await Future<void>.delayed(Duration.zero);
      await nav.pause();
      final newer = Completer<WalkingRoute>();
      services.routePending = newer;
      final restarted = nav.start();
      await Future<void>.delayed(Duration.zero);
      old.complete(route());
      await selection;
      await nav.start();
      expect(services.calculations, 2);
      expect(nav.busy, true);
      newer.complete(route());
      await restarted;
      expect(nav.state, NavigationState.navigating);
    });
    test(
      'moving origin while route is calculating cannot start an outdated route',
      () async {
        await nav.select(place());
        services.routePending = Completer<WalkingRoute>();
        final task = nav.start();
        await Future<void>.delayed(Duration.zero);
        services.nextFix = fix(80);
        services.routePending!.complete(route());
        await task;
        expect(nav.state, NavigationState.failed);
        expect(nav.message, contains('起點已改變'));
        expect(services.starts, 0);
      },
    );
    test('stationary noisy fix is not enough to reroute', () async {
      await nav.select(place());
      await nav.start();
      final count = services.calculations;
      services.now = const Duration(seconds: 1);
      services.emit(0, north: 60);
      services.now = const Duration(seconds: 2);
      services.emit(0);
      services.now = const Duration(seconds: 3);
      services.emit(0, north: 60);
      await Future<void>.delayed(Duration.zero);
      expect(services.calculations, count);
    });
    test(
      'usable location resumes guidance once after poor positioning',
      () async {
        await nav.select(place());
        await nav.start();
        services.now = const Duration(seconds: 1);
        services.emit(0, accuracy: 80);
        expect(nav.state, NavigationState.locationPoor);
        services.now = const Duration(seconds: 2);
        services.emit(0);
        expect(nav.state, NavigationState.navigating);
        expect(nav.announcement, contains('已恢復路線指示'));
        final spoken = nav.announcementId;
        services.now = const Duration(seconds: 3);
        services.emit(1);
        expect(nav.announcementId, spoken);
      },
    );
    test(
      'nearby requires explicit End; address failure preserves useful position',
      () async {
        await nav.select(place());
        await nav.start();
        for (var east = 0; east <= 190; east += 10) {
          services.now += const Duration(seconds: 10);
          services.emit(east.toDouble());
        }
        expect(nav.state, NavigationState.nearby);
        expect(nav.session, isNotNull);
        expect(await nav.currentPosition(), contains('定位誤差'));
        await nav.end();
        expect(nav.session, isNull);
        expect(services.awake, false);
      },
    );
    test('preview cannot start GPS tracking; Start refreshes route and takes wake flag', () async {
      await nav.select(place());
      expect(nav.state, NavigationState.preview);
      expect(services.starts, 0);
      expect(services.awake, false);
      await nav.start();
      expect(services.calculations, 2);
      expect(nav.state, NavigationState.navigating);
      expect(services.awake, true);
      await nav.pause();
      expect(nav.state, NavigationState.paused);
      expect(services.awake, false);
      expect(nav.nextInstruction(), contains('沒有有效'));
    });
    test('old search result is discarded after background pause', () async {
      services.searchPending = Completer();
      final task = nav.search('舊地點');
      await Future<void>.delayed(Duration.zero);
      await nav.pause(background: true);
      services.searchPending!.complete([place()]);
      await task;
      expect(nav.results, isEmpty);
      expect(nav.state, NavigationState.idle);
    });
    test(
      'old route response cannot restart background or ended navigation',
      () async {
        services.routePending = Completer();
        final task = nav.select(place());
        await Future<void>.delayed(Duration.zero);
        await nav.end();
        services.routePending!.complete(route());
        await task;
        expect(nav.route, isNull);
        expect(nav.session, isNull);
        expect(services.starts, 0);
      },
    );
    test('poor location prevents preview and start', () async {
      services.nextFix = fix(0, accuracy: 60);
      await nav.select(place());
      expect(nav.state, NavigationState.failed);
      expect(services.calculations, 0);
      expect(nav.session, isNull);
    });
    test(
      'off-route uncertainty keeps evidence and makes one recalculation',
      () async {
        await nav.select(place());
        await nav.start();
        final count = services.calculations;
        for (final second in [1, 6, 11]) {
          services.now = Duration(seconds: second);
          services.emit(0, north: 80);
        }
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(services.calculations, count + 1);
        for (final second in [12, 17, 22]) {
          services.now = Duration(seconds: second);
          services.emit(0, north: 80);
        }
        await Future<void>.delayed(Duration.zero);
        expect(services.calculations, count + 1);
      },
    );
    test('reroute failure stops old instructions and offers retry', () async {
      await nav.select(place());
      await nav.start();
      services.routeFailure = const NavigationFailure('offline', '未能重新計算路線。');
      for (final second in [1, 6, 11]) {
        services.now = Duration(seconds: second);
        services.emit(0, north: 80);
      }
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(nav.state, NavigationState.failed);
      expect(nav.nextInstruction(), contains('沒有有效'));
      expect(services.awake, false);
    });
    test(
      'favorites rename, delete and recent survive a new controller',
      () async {
        await nav.select(place());
        await nav.favorite('學校');
        await nav.renameFavorite(nav.favorites.single, '新名稱');
        await nav.start();
        await Future<void>.delayed(Duration.zero);
        final restored = NavigationController(
          searchService: services,
          routeService: services,
          location: services,
          store: store,
          clock: () => services.now,
        );
        await restored.initialize();
        expect(restored.favorites.single.label, '新名稱');
        expect(restored.recent.length, 1);
        await restored.removeFavorite(restored.favorites.single);
        expect(restored.favorites, isEmpty);
        restored.dispose();
      },
    );
    test(
      'broken storage permits recovery without blocking navigation',
      () async {
        store.broken = true;
        await nav.initialize();
        expect(nav.message, contains('收藏'));
        await nav.clearSaved();
        await nav.select(place());
        expect(nav.state, NavigationState.preview);
      },
    );
    test(
      'stale timer stops exact instructions without needing another GPS event',
      () async {
        await nav.select(place());
        await nav.start();
        services.now = const Duration(seconds: 11);
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(nav.state, NavigationState.locationPoor);
        expect(nav.nextInstruction(), contains('沒有有效'));
        await nav.pause();
      },
    );
    testWidgets(
      'accessible flow searches, previews and pauses on actual background',
      (tester) async {
        nav.dispose();
        await tester.runAsync(() => services.stream.close());
        services = Services();
        store = MemoryStore();
        nav = NavigationController(
          searchService: services,
          routeService: services,
          location: services,
          store: store,
          clock: () => services.now,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NavigationPage(
                settings: AppSettings.memory(),
                controller: nav,
                speech: SilentSpeech(),
                speaker: NullSpeaker(),
                mapBuilder: (_, _) => const Text('測試地圖'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '測試目的地');
        await tester.tap(find.widgetWithText(FilledButton, '搜尋'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, '測試目的地'));
        await tester.pumpAndSettle();
        expect(find.text('香港測試地址'), findsOneWidget);
        expect(services.starts, 0);
        await tester.ensureVisible(find.text('開始導航'));
        await tester.tap(find.text('開始導航'));
        await tester.pump();
        await tester.pump();
        expect(nav.state, NavigationState.navigating);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        await tester.pump();
        expect(nav.state, NavigationState.paused);
        expect(services.awake, false);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(nav.state, NavigationState.paused);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        // Page owns its controller; avoid disposing it twice in group teardown.
        nav = NavigationController(
          searchService: services,
          routeService: services,
          location: services,
          store: store,
          clock: () => services.now,
        );
      },
    );
  });
  test(
    'native location monotonic age contract and cancellation channels',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('hk.pathguide/navigation');
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'currentLocation') {
          return {
            'coordinate': point(0).toMap(),
            'accuracy': 4.0,
            'ageSeconds': 12.0,
          };
        }
        return null;
      });
      final native = NativeNavigationServices(MapProvider.apple);
      final value = await native.current();
      expect(value.usable(navigationNow(), const NavigationRules()), false);
      await native.cancelSearch();
      await native.cancelRoute();
      expect(calls, ['currentLocation', 'cancelSearch', 'cancelRoute']);
      messenger.setMockMethodCallHandler(channel, null);
    },
  );
  testWidgets('five voice searches each automatically announce exactly once', (
    tester,
  ) async {
    final services = Services();
    final store = MemoryStore();
    final nav = NavigationController(
      searchService: services,
      routeService: services,
      location: services,
      store: store,
      clock: () => services.now,
    );
    final speaker = RecordingNavigationSpeaker();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NavigationPage(
            settings: AppSettings.memory(),
            controller: nav,
            speech: SilentSpeech(),
            speaker: speaker,
            mapBuilder: (_, _) => const Text('地圖'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('講出目的地'));
      await tester.pumpAndSettle();
    }
    expect(speaker.words.where((t) => t.startsWith('找到')).length, 5);
    expect(find.widgetWithText(ListTile, '測試目的地'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await services.stream.close();
  });
  testWidgets(
    'reader output excludes simultaneous TTS and map provider mismatch is visible',
    (tester) async {
      final services = Services();
      final nav = NavigationController(
        searchService: services,
        routeService: services,
        location: services,
        store: MemoryStore(),
        clock: () => services.now,
      );
      final speaker = RecordingNavigationSpeaker();
      final announcements = <Object?>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockDecodedMessageHandler<dynamic>(
        SystemChannels.accessibility,
        (value) async {
          announcements.add(value);
          return null;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(accessibleNavigation: true),
              child: NavigationPage(
                settings: AppSettings.memory(),
                controller: nav,
                speech: SilentSpeech(),
                speaker: speaker,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('講出目的地'));
      await tester.pumpAndSettle();
      expect(speaker.words, isEmpty);
      expect(
        announcements.where((x) => x.toString().contains('找到')),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await services.stream.close();
      messenger.setMockDecodedMessageHandler<dynamic>(
        SystemChannels.accessibility,
        null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NavigationMap(
            provider: MapProvider.apple,
            route: route(MapProvider.google),
          ),
        ),
      );
      expect(find.text('地圖與路線來源不符。'), findsOneWidget);
    },
  );
}
