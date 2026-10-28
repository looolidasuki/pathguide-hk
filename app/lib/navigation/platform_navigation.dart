import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../menu/menu_reader.dart';
import '../platform/app_attestation.dart';
import 'navigation_models.dart';
import 'navigation_services.dart';

final _elapsed = Stopwatch()..start();
Duration navigationNow() => _elapsed.elapsed;

Future<bool> _configureNavigationFirebase() async {
  if (Firebase.apps.isNotEmpty) return true;
  const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  const appId = String.fromEnvironment('FIREBASE_APP_ID');
  const sender = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  if ([apiKey, projectId, appId, sender].any((s) => s.isEmpty)) return false;
  try {
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: apiKey,
        projectId: projectId,
        appId: appId,
        messagingSenderId: sender,
      ),
    );
    return true;
  } catch (_) {
    return false;
  }
}

class NativeNavigationServices
    implements PlaceSearchService, WalkingRouteService, LocationService {
  NativeNavigationServices(this.provider, {MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('hk.pathguide/navigation');
  @override
  final MapProvider provider;
  final MethodChannel _channel;
  int _request = 0;
  Future<T?> _invoke<T>(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      return await _channel.invokeMethod<T>(name, {
        'requestId': '${++_request}',
        ...args,
      });
    } on PlatformException catch (e) {
      throw NavigationFailure(e.code, e.message ?? '導航服務暫時不可用，請重試。');
    } on MissingPluginException {
      throw const NavigationFailure('unsupported', '此裝置未提供導航服務，請安裝最新手機版本。');
    }
  }

  @override
  Future<List<Place>> search(String text) async =>
      (await _invoke<List>('searchPlaces', {'query': text}) ?? [])
          .map((p) => Place.fromMap(p as Map))
          .toList();
  @override
  Future<Place> resolve(SavedDestination destination) async {
    if (destination.provider != provider) {
      throw const NavigationFailure('unsupported', '請在此平台重新搜尋目的地。');
    }
    if (provider == MapProvider.apple && destination.applePlace != null) {
      return destination.applePlace!;
    }
    return Place.fromMap(
      (await _invoke<Map>('resolvePlace', {'id': destination.id}))!,
    );
  }

  @override
  Future<void> cancelSearch() async {
    try {
      await _invoke<void>('cancelSearch');
    } on NavigationFailure {
      /* Cancellation is safe even before native registration. */
    }
  }

  @override
  Future<WalkingRoute> calculate(Coordinate origin, Place destination) async {
    if (provider == MapProvider.apple) {
      return WalkingRoute.fromMap(
        (await _invoke<Map>('calculateRoute', {
          'origin': origin.toMap(),
          'destination': destination.toMap(),
        }))!,
      );
    }
    if (!const bool.fromEnvironment('NAVIGATION_GOOGLE_ENABLED') ||
        !await _configureNavigationFirebase() ||
        !await activateAppAttestation()) {
      throw const NavigationFailure(
        'not_configured',
        'Android 路線服務尚未啟用，請完成 Google 及後端配置。',
      );
    }
    try {
      final response = await FirebaseFunctions.instanceFor(region: 'asia-east2')
          .httpsCallable(
            'computeWalkingRoute',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 20)),
          )
          .call<dynamic>({
            'schemaVersion': 1,
            'requestId': '${++_request}',
            'origin': origin.toMap(),
            'destinationPlaceId': destination.id,
          });
      return WalkingRoute.fromMap(response.data as Map);
    } on FirebaseFunctionsException catch (e) {
      throw NavigationFailure(e.code, switch (e.code) {
        'resource-exhausted' => '路線查詢配額暫時用盡，請稍後重試。',
        'not-found' => '未找到可用的步行路線。',
        'failed-precondition' => 'Android 路線服務尚未配置。',
        _ => '未能取得路線，請檢查網絡或稍後重試。',
      });
    }
  }

  @override
  Future<void> cancelRoute() async {
    try {
      await _invoke<void>('cancelRoute');
    } on NavigationFailure {
      /* No active route request on unsupported devices. */
    }
  }

  LocationFix _fix(Map m) => LocationFix(
    coordinate: Coordinate.fromMap(m['coordinate'] as Map),
    accuracy: (m['accuracy'] as num).toDouble(),
    receivedAt: navigationNow(),
    ageSeconds: (m['ageSeconds'] as num).toDouble(),
    course: (m['course'] as num?)?.toDouble(),
  );
  @override
  Future<LocationFix> current() async =>
      _fix((await _invoke<Map>('currentLocation'))!);
  @override
  Stream<LocationFix> get updates =>
      const EventChannel('hk.pathguide/navigation/location')
          .receiveBroadcastStream()
          .map((event) => _fix(event as Map));
  @override
  Future<void> start() async {
    await _invoke<void>('startLocation');
  }

  @override
  Future<void> stop() async {
    try {
      await _invoke<void>('stopLocation');
    } on NavigationFailure {
      /* Safe on unsupported platforms and disposal. */
    }
  }

  @override
  Future<String?> address(Coordinate coordinate) =>
      _invoke<String>('address', {'coordinate': coordinate.toMap()});
  @override
  Future<void> keepAwake(bool enabled) async {
    try {
      await _invoke<void>('keepAwake', {'enabled': enabled});
    } on NavigationFailure {
      /* No wake lock was acquired. */
    }
  }
}

class AndroidSpeechInput implements SpeechInputService {
  AndroidSpeechInput() {
    _channel.setMethodCallHandler((call) async {
      final m = call.arguments as Map?;
      if (m?['requestId'] != _id) return;
      if (call.method == 'speechPartial') {
        _partial?.call(m?['text'] as String? ?? '');
      }
      if (call.method == 'speechPhase') {
        _phase?.call(MenuSpeechPhase.values.byName(m?['phase'] as String));
      }
    });
  }
  final _channel = const MethodChannel('hk.pathguide/speech');
  int _id = 0;
  static int _sequence = 0;
  void Function(String)? _partial;
  void Function(MenuSpeechPhase)? _phase;
  @override
  Future<MenuSpeechResult> listen({
    required bool allowNetwork,
    required void Function(String) onPartial,
    required void Function(MenuSpeechPhase) onPhase,
  }) async {
    _partial = onPartial;
    _phase = onPhase;
    onPhase(MenuSpeechPhase.preparing);
    try {
      return MenuSpeechResult.fromMap(
        await _channel.invokeMapMethod('listen', {
          'requestId': _id = ++_sequence,
          'allowNetwork': allowNetwork,
        }),
      );
    } on PlatformException catch (e) {
      throw MenuFailure(e.message ?? '未能收音，請用文字搜尋。', code: e.code);
    } on MissingPluginException {
      throw const MenuFailure('此裝置未提供語音輸入，請用文字搜尋。');
    }
  }

  @override
  Future<void> cancel() async {
    _id = ++_sequence;
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (_) {}
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}

class NavigationPlatform {
  NavigationPlatform({
    required this.services,
    required this.speech,
    required this.map,
  });
  final NativeNavigationServices services;
  final SpeechInputService speech;
  final Widget Function(WalkingRoute?, Place?) map;
  factory NavigationPlatform.create() {
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final provider = android ? MapProvider.google : MapProvider.apple;
    return NavigationPlatform(
      services: NativeNavigationServices(provider),
      speech: android
          ? AndroidSpeechInput()
          : MenuSpeechInput(NativeMenuReader()),
      map: (route, place) =>
          NavigationMap(provider: provider, route: route, destination: place),
    );
  }
}

class NavigationMap extends StatelessWidget {
  const NavigationMap({
    super.key,
    required this.provider,
    this.route,
    this.destination,
  });
  final MapProvider provider;
  final WalkingRoute? route;
  final Place? destination;
  @override
  Widget build(BuildContext context) {
    if (route != null && route!.provider != provider) {
      return const Text('地圖與路線來源不符。');
    }
    final params = <String, Object?>{
      'route': route?.toMap(),
      'destination': destination?.toMap(),
    };
    final map = kIsWeb
        ? const Text('請使用手機版本查看地圖。')
        : switch (defaultTargetPlatform) {
            TargetPlatform.iOS => UiKitView(
              viewType: 'hk.pathguide/navigation/map',
              creationParams: params,
              creationParamsCodec: const StandardMessageCodec(),
            ),
            TargetPlatform.android => AndroidView(
              viewType: 'hk.pathguide/navigation/map',
              creationParams: params,
              creationParamsCodec: const StandardMessageCodec(),
            ),
            _ => const Text('請使用手機版本查看地圖。'),
          };
    // Route changes recreate the view with a fresh overlay. Map gestures are optional.
    return SizedBox(
      height: 220,
      child: KeyedSubtree(
        key: ValueKey(route?.id ?? destination?.id),
        child: Semantics(
          label:
              '${provider == MapProvider.google ? 'Google Maps' : 'Apple 地圖'} 路線地圖；文字指示及操作在地圖下方。',
          child: ExcludeSemantics(child: map),
        ),
      ),
    );
  }
}
