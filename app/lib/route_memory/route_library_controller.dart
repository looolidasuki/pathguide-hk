import 'dart:math';

import 'package:flutter/foundation.dart';

import 'route_package.dart';

/// Narrow UI boundary. Native storage/crypto and fixture construction stay Sol-owned.
abstract interface class RouteLibraryBackend {
  Future<RouteLibraryListing> list();
  Future<void> saveSample(
    String id,
    String name,
    bool draft,
    int expectedRevision,
  );
  Future<void> rollback(String id, int version, int expectedRevision);
  Future<void> delete(String id, int expectedRevision);
  Future<void> cleanup();
  void cancelPending();
}

enum LibraryNotice { ready, saved, rolledBack, deleted, cleaned, paused }

class RouteLibraryController extends ChangeNotifier {
  RouteLibraryController(this._backend);
  final RouteLibraryBackend _backend;
  List<RouteLibraryEntry> _entries = const [];
  int _pendingCleanup = 0, _generation = 0;
  bool _busy = false, _foreground = true, _paused = false, _disposed = false;
  RouteProblem? _error;
  LibraryNotice _notice = LibraryNotice.ready;
  List<RouteLibraryEntry> get entries => _entries;
  int get pendingCleanup => _pendingCleanup;
  int get generation => _generation;
  bool get busy => _busy;
  bool get foreground => _foreground;
  bool get paused => _paused;
  RouteProblem? get error => _error;
  LibraryNotice get notice => _notice;
  bool get canAct => !_disposed && !_busy && _foreground && !_paused;

  Future<void> refresh() {
    if (_disposed || !_foreground || _busy) return Future.value();
    _paused = false;
    return _run(null, LibraryNotice.ready);
  }

  Future<void> addSample(String name, {required bool draft}) {
    if (name.trim().isEmpty || name.length > 120) {
      if (canAct) {
        _error = RouteProblem.invalid;
        notifyListeners();
      }
      return Future.value();
    }
    final rng = Random.secure();
    final id = List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return _run(
      () => _backend.saveSample(id, name.trim(), draft, 0),
      LibraryNotice.saved,
    );
  }

  Future<void> saveRevision(RouteLibraryEntry entry, {required bool draft}) =>
      _run(
        () => _backend.saveSample(entry.id, entry.name, draft, entry.revision),
        LibraryNotice.saved,
      );
  Future<void> rollback(RouteLibraryEntry entry, int version) => _run(
    () => _backend.rollback(entry.id, version, entry.revision),
    LibraryNotice.rolledBack,
  );
  Future<void> delete(RouteLibraryEntry entry) => _run(
    () => _backend.delete(entry.id, entry.revision),
    LibraryNotice.deleted,
  );
  Future<void> cleanup() => _run(_backend.cleanup, LibraryNotice.cleaned);

  Future<void> _run(
    Future<void> Function()? action,
    LibraryNotice notice,
  ) async {
    if (!canAct) return;
    final gen = _generation;
    _busy = true;
    _error = null;
    notifyListeners();
    RouteProblem? failure;
    RouteLibraryListing? listing;
    try {
      if (action != null) await action();
      if (_disposed || gen != _generation || !_foreground) return;
      listing = await _backend.list();
    } on RouteStoreFailure catch (e) {
      failure = e.problem;
    } catch (_) {
      failure = RouteProblem.io;
    }
    // This is a read reconciliation, never a retry of an uncertain write.
    if (failure != null && !_disposed && gen == _generation && _foreground) {
      try {
        listing = await _backend.list();
      } catch (_) {
        /* Keep original failure. */
      }
    }
    if (_disposed || gen != _generation || !_foreground) return;
    _entries = listing?.routes ?? const [];
    _pendingCleanup = listing?.pendingCleanup ?? 0;
    _error = failure;
    _busy = false;
    if (failure == null) _notice = notice;
    notifyListeners();
  }

  void pause() {
    if (_disposed) return;
    _generation++;
    _backend.cancelPending();
    _paused = true;
    _busy = false;
    _notice = LibraryNotice.paused;
    notifyListeners();
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      pause();
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _generation++;
    _backend.cancelPending();
    _disposed = true;
    super.dispose();
  }
}
