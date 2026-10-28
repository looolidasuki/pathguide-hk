import 'dart:async';

import 'package:flutter/foundation.dart';

import 'navigation_models.dart';
import 'navigation_services.dart';
import 'route_progress.dart';

class NavigationController extends ChangeNotifier {
  NavigationController({
    required this.searchService,
    required this.routeService,
    required this.location,
    required this.store,
    required this.clock,
    this.rules = const NavigationRules(),
  });
  final PlaceSearchService searchService;
  final WalkingRouteService routeService;
  final LocationService location;
  final DestinationStore store;
  final Duration Function() clock;
  final NavigationRules rules;
  NavigationState state = NavigationState.idle;
  String message = '搜尋香港目的地，或選取此手機收藏。';
  String _lastQuery = '';
  List<Place> results = [];
  List<SavedDestination> favorites = [], recent = [];
  Place? destination;
  WalkingRoute? route;
  NavigationSession? session;
  RouteProgress? progress;
  LocationFix? fix;
  String? announcement;
  int announcementId = 0, _generation = 0;
  bool _disposed = false, _background = false, _started = false;
  int? _calculationGeneration;
  bool get _calculating => _calculationGeneration != null;
  Future<void>? _shutdown;
  Duration? _lastRecalculation;
  StreamSubscription<LocationFix>? _subscription;
  Timer? _staleTimer;
  bool get hasTask =>
      destination != null && (_started || state == NavigationState.paused);
  bool get active =>
      session != null &&
      state != NavigationState.paused &&
      state != NavigationState.failed;
  bool get busy => [
    NavigationState.searching,
    NavigationState.locating,
    NavigationState.calculating,
    NavigationState.rerouting,
  ].contains(state);
  String get locationStatus {
    if (state == NavigationState.paused || state == NavigationState.failed) {
      return '定位已停止。';
    }
    if (state == NavigationState.locating) return '正在取得精確定位。';
    final current = fix;
    if (current == null || !current.usable(clock(), rules)) {
      return '定位暫時不足，請到較開揚位置。';
    }
    return '定位誤差約 ${current.accuracy.round()} 米。';
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _say(String text) {
    announcement = text;
    announcementId++;
  }

  void _error(Object e) {
    message = e is NavigationFailure ? e.message : '未能完成導航操作，請重試。';
    _say(message);
  }

  bool _valid(int generation) =>
      !_disposed && !_background && generation == _generation;
  Future<void> initialize() async {
    try {
      final data = await store.load();
      if (_disposed) return;
      favorites = data.favorites;
      recent = data.recent;
    } catch (e) {
      if (!_disposed) _error(e);
    }
    _changed();
  }

  Future<void> search(String text) async {
    final query = text.trim();
    if (query.isEmpty || hasTask) return;
    _lastQuery = query;
    final generation = ++_generation;
    _calculationGeneration = null;
    destination = null;
    route = null;
    progress = null;
    session = null;
    state = NavigationState.searching;
    results = [];
    message = '正在搜尋目的地。';
    _changed();
    try {
      await routeService.cancelRoute();
      await searchService.cancelSearch();
      if (!_valid(generation)) return;
      final found = await searchService.search(query);
      if (!_valid(generation)) return;
      results = found;
      state = NavigationState.idle;
      message = found.isEmpty
          ? '找不到目的地，請修改名稱或地址。'
          : '找到 ${found.length} 個地點，請核對名稱及地址。';
      _say(message);
    } catch (e) {
      if (_valid(generation)) {
        state = NavigationState.failed;
        _error(e);
      }
    }
    _changed();
  }

  Future<void> selectSaved(SavedDestination saved) async {
    if (busy || active) return;
    _lastQuery = saved.label;
    final generation = ++_generation;
    state = NavigationState.locating;
    _changed();
    try {
      final place = await searchService.resolve(saved);
      if (_valid(generation)) await select(place);
    } catch (e) {
      if (_valid(generation)) {
        state = NavigationState.failed;
        _error(e);
        _changed();
      }
    }
  }

  Future<void> select(Place place) async {
    if (active) return;
    _lastRecalculation = null;
    _started = false;
    destination = place;
    results = [];
    route = null;
    progress = null;
    session = null;
    await _calculate(false);
  }

  Future<void> retryPreview() async {
    if (hasTask || busy) return;
    route = null;
    progress = null;
    await _calculate(false);
  }

  Future<void> _calculate(bool begin) async {
    final place = destination;
    if (place == null || _calculating || _disposed || _background) return;
    final generation = ++_generation;
    _calculationGeneration = generation;
    state = NavigationState.locating;
    message = '正在取得目前位置。';
    _changed();
    try {
      await _shutdown;
      if (!_valid(generation)) return;
      final current = await location.current();
      if (!_valid(generation)) return;
      if (!current.usable(clock(), rules)) {
        throw const NavigationFailure(
          'location_poor',
          '定位暫時不足，請到較開揚位置重試，並開啟精確定位。',
        );
      }
      fix = current;
      state = NavigationState.calculating;
      message = '正在計算步行路線。';
      _changed();
      final found = await routeService.calculate(current.coordinate, place);
      if (!_valid(generation)) return;
      if (found.provider != place.provider) {
        throw const NavigationFailure('invalid_data', '路線來源不符，請重新搜尋。');
      }
      route = found;
      progress = RouteProgress(found, place.coordinate, rules: rules);
      if (begin) {
        final latest = await location.current();
        if (!_valid(generation)) return;
        if (!latest.usable(clock(), rules)) {
          throw const NavigationFailure('location_poor', '定位暫時不足，請重新定位後開始。');
        }
        if (latest.coordinate.distanceTo(current.coordinate) > 30) {
          throw const NavigationFailure('origin_changed', '計算期間起點已改變，請重新取得路線。');
        }
        fix = latest;
        session = NavigationSession(
          id: generation,
          destination: place,
          route: found,
        );
        state = NavigationState.navigating;
        message = '導航中。';
        _say(progress!.instruction);
        await _listen(generation);
        if (!_valid(generation)) return;
        recent.removeWhere(
          (p) => p.provider == place.provider && p.id == place.id,
        );
        recent.insert(
          0,
          SavedDestination.fromPlace(
            place,
            place.provider == MapProvider.google
                ? (_lastQuery.isEmpty ? '最近目的地' : _lastQuery)
                : place.name,
          ),
        );
        recent = recent.take(10).toList();
        unawaited(_persist());
      } else {
        state = NavigationState.preview;
        message = '請核對目的地、地址及路線，再開始導航。';
        _say(message);
      }
    } catch (e) {
      if (_valid(generation)) {
        session = null;
        state = NavigationState.failed;
        _error(e);
        await _stopLocation();
      }
    } finally {
      if (_calculationGeneration == generation) _calculationGeneration = null;
      _changed();
    }
  }

  // Always recalculate from a new fix: preview origins and paused sessions can move.
  Future<void> start() {
    if (destination == null) return Future<void>.value();
    _started = true;
    return _calculate(true);
  }

  Future<void> _listen(int generation) async {
    await _subscription?.cancel();
    _subscription = location.updates.listen(
      (value) {
        if (!_valid(generation) || session?.id != generation) {
          return;
        }
        fix = value;
        if (state == NavigationState.nearby) {
          _changed();
        } else {
          _update(value);
        }
      },
      onError: (Object e) {
        if (_valid(generation)) {
          state = NavigationState.locationPoor;
          _error(e);
          progress?.resetEvidence();
          _changed();
        }
      },
    );
    await location.start();
    if (!_valid(generation)) {
      await _stopLocation();
      return;
    }
    await location.keepAwake(true);
    if (!_valid(generation)) {
      await location.keepAwake(false);
      return;
    }
    _staleTimer?.cancel();
    _staleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_valid(generation) && fix != null && !fix!.usable(clock(), rules)) {
        if (state == NavigationState.nearby) {
          _changed();
        } else {
          _poor();
        }
      }
    });
  }

  void _poor({bool resetEvidence = true}) {
    if (resetEvidence) progress?.resetEvidence();
    if (state != NavigationState.locationPoor) {
      state = NavigationState.locationPoor;
      message = '定位暫時不足，無法提供下一步。';
      _say(message);
      _changed();
    }
  }

  void _update(LocationFix value) {
    if (_calculating ||
        state == NavigationState.rerouting ||
        state == NavigationState.failed) {
      return;
    }
    if (!value.usable(clock(), rules)) {
      _poor();
      return;
    }
    final update = progress!.update(value, clock());
    if (update.deviated) {
      unawaited(_reroute());
      return;
    }
    if (update.uncertain) {
      _poor(resetEvidence: false);
      return;
    }
    final recovering = state == NavigationState.locationPoor;
    state = update.nearby ? NavigationState.nearby : NavigationState.navigating;
    message = update.nearby ? '已接近目的地，請確認入口。' : '導航中。';
    if (update.message != null) {
      _say(update.message!);
    } else if (recovering) {
      _say('已恢復路線指示。${nextInstruction()}');
    }
    _changed();
  }

  Future<void> _reroute() async {
    if (_lastRecalculation != null &&
        clock() - _lastRecalculation! < rules.recalculateCooldown) {
      return;
    }
    _lastRecalculation = clock();
    final generation = ++_generation;
    state = NavigationState.rerouting;
    _say('可能已偏離路線，正在重新計算。');
    _changed();
    session = null;
    _shutdown = _stopLocation();
    await _shutdown;
    if (!_valid(generation)) return;
    await _calculate(true);
  }

  String nextInstruction() {
    if (state == NavigationState.nearby) return '已接近目的地，請確認入口。確認入口後可結束導航。';
    if (state != NavigationState.navigating ||
        fix == null ||
        !fix!.usable(clock(), rules)) {
      return '暫時沒有有效的下一步指示，請繼續定位或重試。';
    }
    final p = progress!;
    return '${p.instruction} 距離下一步約 ${p.nextDistance.round()} 米，路線剩餘約 ${p.remaining.round()} 米。';
  }

  Future<String> currentPosition() async {
    final generation = _generation;
    final current = fix;
    if (current == null || !current.usable(clock(), rules)) {
      return '定位暫時不足，無法確認目前位置。';
    }
    String? address;
    try {
      address = await location
          .address(current.coordinate)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
    } catch (_) {
      /* Position remains useful without geocoding. */
    }
    if (!_valid(generation) ||
        state == NavigationState.paused ||
        state == NavigationState.failed ||
        !current.usable(clock(), rules)) {
      return '定位已變更或導航已暫停，請重新查詢目前位置。';
    }
    return '${address == null || address.trim().isEmpty ? '已取得目前位置' : address}。定位誤差約 ${current.accuracy.round()} 米。${progress == null ? '' : '路線剩餘約 ${progress!.remaining.round()} 米。'}';
  }

  Future<void> pause({bool background = false}) async {
    ++_generation;
    _background = background;
    _calculationGeneration = null;
    final hadTask = destination != null;
    if (hadTask) {
      state = NavigationState.paused;
      message = background ? '已切到背景，導航已暫停。返回後請按繼續導航。' : '導航已暫停。';
    } else {
      state = NavigationState.idle;
      message = '搜尋已取消，可重新輸入目的地。';
    }
    announcement = null;
    announcementId++;
    _shutdown = Future.wait([
      _stopLocation(),
      routeService.cancelRoute(),
      searchService.cancelSearch(),
    ]).then((_) {});
    _changed();
    await _shutdown;
    _changed();
  }

  void foreground() {
    _background = false;
  }

  Future<void> end() async {
    await pause();
    destination = null;
    route = null;
    progress = null;
    session = null;
    fix = null;
    _started = false;
    state = NavigationState.idle;
    message = '導航已結束。';
    _changed();
  }

  Future<void> _stopLocation() async {
    _staleTimer?.cancel();
    _staleTimer = null;
    final subscription = _subscription;
    _subscription = null;
    // Releasing hardware must not wait for an EventChannel cancellation ack.
    await Future.wait([
      if (subscription != null) subscription.cancel(),
      location.stop(),
      location.keepAwake(false),
    ]);
  }

  Future<void> favorite(String label) async {
    final place = destination;
    if (place == null || label.trim().isEmpty) return;
    favorites.removeWhere(
      (p) => p.provider == place.provider && p.id == place.id,
    );
    favorites.add(SavedDestination.fromPlace(place, label.trim()));
    await _persist();
    _changed();
  }

  Future<void> removeFavorite(SavedDestination p) async {
    favorites.remove(p);
    await _persist();
    _changed();
  }

  Future<void> renameFavorite(SavedDestination p, String label) async {
    if (label.trim().isEmpty) return;
    final i = favorites.indexOf(p);
    if (i < 0) return;
    favorites[i] = SavedDestination(
      provider: p.provider,
      id: p.id,
      label: label.trim(),
      savedAt: p.savedAt,
      applePlace: p.applePlace,
    );
    await _persist();
    _changed();
  }

  Future<void> clearSaved() async {
    favorites = [];
    recent = [];
    await _persist();
    _changed();
  }

  Future<void> _persist() async {
    try {
      await store.save(favorites, recent);
    } catch (_) {
      if (!_disposed) {
        message = '地點未能儲存，請重試。';
        _changed();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    unawaited(_stopLocation());
    unawaited(routeService.cancelRoute());
    unawaited(searchService.cancelSearch());
    super.dispose();
  }
}

String destinationQuery(String transcript) => transcript
    .trim()
    .replaceFirst(RegExp(r'^(?:唔該[，,\s]*)?(?:我想去|帶我去|我要去)[，,\s]*'), '')
    .trim();
