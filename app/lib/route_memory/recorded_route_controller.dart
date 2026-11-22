import 'dart:async';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'cross_floor_contract.dart';
import 'encrypted_route_store.dart';
import 'route_package.dart';
import 'route_observation_source.dart';
import 'route_landmark_client.dart';
import 'route_localizer.dart';
import 'route_frame_quality.dart';
import 'route_learning_store.dart';

enum RecordedRouteMode { library, record, replay }

/// One screen owns camera, analysis jobs and store writes. Every asynchronous
/// operation is fenced. Replay writes only to the optional learning store.
class RecordedRouteController extends ChangeNotifier {
  RecordedRouteController({
    required this.store,
    RouteObservationSource? source,
    RouteLandmarkClient? analyzer,
    this.openLearningStore,
  }) : source = source ?? RouteObservationSource(),
       analyzer = analyzer ?? RouteLandmarkClient() {
    _events = this.source.events.listen(
      (status) {
        if (!_stopping &&
            _running &&
            [
              RouteCaptureStatus.paused,
              RouteCaptureStatus.stopped,
              RouteCaptureStatus.unsupported,
              RouteCaptureStatus.permission,
              RouteCaptureStatus.unavailable,
              RouteCaptureStatus.failed,
              RouteCaptureStatus.stopUnconfirmed,
            ].contains(status)) {
          unawaited(pause());
        }
      },
      onError: (Object _) {
        unawaited(pause());
      },
    );
  }
  final EncryptedRouteStore store;
  final RouteObservationSource source;
  final RouteLandmarkClient analyzer;
  final Future<RouteLearningStore> Function()? openLearningStore;
  RouteLearningStore? _learningStore;
  String? _learningTrip;
  bool _savingLearningFrame = false;
  bool _withdrawingLearning = false;
  bool get learningEnabled =>
      _learningTrip != null &&
      !_withdrawingLearning &&
      !learningWithdrawalFailed;
  bool get learningBusy => _withdrawingLearning;
  bool learningWithdrawalFailed = false;
  bool learningSaveFailed = false;

  Future<RouteLearningStore> learningStore() async =>
      _learningStore ??= await openLearningStore!();

  void enableLearning() {
    if (openLearningStore == null ||
        !replayAvailable ||
        finished ||
        !_foreground ||
        _disposed ||
        _withdrawingLearning ||
        _learningTrip != null) {
      return;
    }
    learningSaveFailed = false;
    _learningTrip = _newId();
    _changed();
  }

  Future<void> withdrawLearning() async {
    final trip = _learningTrip;
    if (trip == null || _withdrawingLearning) return;
    _withdrawingLearning = true;
    learningWithdrawalFailed = false;
    _changed();
    try {
      // No store is opened by opt-in alone.
      await _learningStore?.deleteTrip(trip);
      _learningTrip = null;
      learningSaveFailed = false;
    } catch (_) {
      learningWithdrawalFailed = true;
    } finally {
      _withdrawingLearning = false;
      _changed();
    }
  }

  Future<void> _keepLearningFrame(
    String trip,
    int op,
    RouteKeyframe frame,
    LandmarkAnalysis analysis,
    String nodeId,
    RouteMatchState prediction,
    String? predictedNode,
  ) async {
    if (_savingLearningFrame) return;
    final route = _id!, version = _captureVersion;
    bool isCurrent() =>
        _current(op) && _running && learningEnabled && _learningTrip == trip;
    _savingLearningFrame = true;
    try {
      if (!await RouteFrameQuality.usable(frame) || !isCurrent()) return;
      final session = frame.observation['session'];
      final sequence = frame.observation['sequence'];
      if (session is! String || sequence is! int) return;
      final storage = await learningStore();
      if (!isCurrent()) return;
      await storage.add(
        routeId: route,
        routeVersion: version,
        tripId: trip,
        session: session,
        sequence: sequence,
        requestedNode: nodeId,
        result: prediction.name,
        predictedNode: predictedNode,
        jpeg: frame.bytes,
        feature: analysis.feature,
        featureProfile: RouteLocalizer.featureRevision,
        preprocessProfile: RouteLocalizer.preprocessRevision,
        isCurrent: isCurrent,
      );
    } on LearningStoreFailure catch (error) {
      if (isCurrent() && !['cancelled', 'duplicate'].contains(error.code)) {
        learningSaveFailed = true;
        _changed();
      }
    } catch (_) {
      if (isCurrent()) {
        learningSaveFailed = true;
        _changed();
      }
    } finally {
      _savingLearningFrame = false;
    }
  }

  StreamSubscription<RouteCaptureStatus>? _events;
  RecordedRouteMode mode = RecordedRouteMode.library;
  List<RouteLibraryEntry> entries = const [];
  List<RoutePoint> _nodes = [];
  List<RouteSegment> _edges = [];
  List<CapturedRouteView> _views = [];
  List<RouteMarkFailure> _markFailures = [];
  Map<String, Uint8List> _media = {};
  String? _id;
  String _name = '', _building = '';
  int _captureVersion = 1, _revision = 0, _epoch = 0;
  bool _busy = false,
      _running = false,
      _foreground = true,
      _disposed = false,
      _stopping = false,
      _dirty = false,
      _reloadRequired = false;
  FloorRef? _recordingFloor;
  String? _recordingAnchor;
  ConnectorMode? _recordingConnector;
  List<String> _floorCandidates = const [];
  final _floorClock = Stopwatch()..start();
  Duration? _floorCandidatesAt;
  FloorRef? get recordingFloor => _recordingFloor;
  List<String> get floorCandidates =>
      _floorCandidatesAt != null &&
          _floorClock.elapsed - _floorCandidatesAt! <=
              const Duration(seconds: 10)
      ? _floorCandidates
      : const [];
  ConnectorMode? get recordingConnector => _recordingConnector;
  List<RoutePoint> get floorAnchors =>
      List.unmodifiable(_nodes.where((n) => n.isFloorContextAnchor));

  void _withdrawFloorContext() {
    _recordingFloor = null;
    _recordingAnchor = null;
  }

  void markFloorUnknown() {
    if (!canEdit) return;
    _withdrawFloorContext();
    notice = 'floorUnknown';
    _changed();
  }

  Future<bool> confirmCurrentFloor(String label) async {
    if (!canCapture || label.trim().isEmpty || label.trim().length > 40) {
      return false;
    }
    final op = _epoch;
    final added = await recordLandmark(
      '路標 ${_nodes.length + 1}',
      label,
      confirmed: true,
      connectionConfirmed: false,
      mode: _recordingConnector ?? ConnectorMode.walk,
    );
    if (!added || !_current(op) || !_running) return false;
    final point = _nodes.last;
    _nodes[_nodes.length - 1] = RoutePoint(
      point.id,
      point.nameZh,
      'Landmark ${_nodes.length}',
      floor: point.floor,
      isFloorContextAnchor: true,
    );
    _recordingFloor = _nodes.last.floor;
    _recordingAnchor = _nodes.last.id;
    _recordingConnector = null;
    notice = 'floorConfirmed';
    _changed();
    return true;
  }

  Future<bool> beginFloorChange(ConnectorMode connector) async {
    if (!canCapture || connector == ConnectorMode.walk) return false;
    final op = _epoch;
    final added = await recordLandmark(
      '轉層入口 ${_nodes.length + 1}',
      '',
      inheritContext: true,
    );
    if (!_current(op)) return false;
    _withdrawFloorContext();
    _floorCandidates = const [];
    _recordingConnector = connector;
    notice = added ? 'floorChanging' : 'floorChangingNoPhoto';
    _changed();
    return added;
  }

  void confirmFloorSegment(String anchorId) {
    if (!canEdit || _running) return;
    final start = _nodes.indexWhere(
      (n) => n.id == anchorId && n.isFloorContextAnchor,
    );
    if (start < 0) return;
    final floor = _nodes[start].floor;
    for (var i = start + 1; i < _nodes.length; i++) {
      final n = _nodes[i];
      if (n.isFloorContextAnchor ||
          n.floor != floor ||
          _edges[i - 1].mode != ConnectorMode.walk) {
        break;
      }
      if (n.floorEvidence == FloorEvidence.confirmed) {
        _edges[i - 1] = _edge(i, ConnectorMode.walk, true);
        continue;
      }
      if (n.floorAnchorId != anchorId) break;
      _nodes[i] = RoutePoint(
        n.id,
        n.nameZh,
        n.nameEn,
        markType: n.markType,
        direction: n.direction,
        textNote: n.textNote,
        audioNote: n.audioNote,
        floor: floor,
        floorEvidence: FloorEvidence.segmentConfirmed,
        floorAnchorId: anchorId,
      );
      _edges[i - 1] = _edge(i, ConnectorMode.walk, true);
    }
    _dirty = true;
    notice = 'segmentReviewed';
    _changed();
  }

  bool finished = false;
  bool automaticRecording = false;
  Timer? _automaticTimer;
  bool _automaticWorking = false;
  bool _manualEntryPending = false;
  void setManualEntryPending(bool pending) {
    if (_disposed) return;
    _manualEntryPending = pending;
    if (pending) {
      _automaticTimer?.cancel();
    } else {
      _armAutomatic();
    }
  }

  int automaticCandidates = 0;
  static const automaticInterval = Duration(seconds: 5);

  void _armAutomatic() {
    _automaticTimer?.cancel();
    if (_disposed ||
        !_foreground ||
        _manualEntryPending ||
        !automaticRecording ||
        !_running ||
        mode != RecordedRouteMode.record) {
      return;
    }
    _automaticTimer = Timer.periodic(automaticInterval, (_) {
      unawaited(sampleAutomatically());
    });
  }

  Future<void> sampleAutomatically() async {
    if (!automaticRecording ||
        !canCapture ||
        _automaticWorking ||
        _manualEntryPending) {
      return;
    }
    if (_views.length >= 48) {
      _automaticTimer?.cancel();
      notice = 'automaticCapacity';
      _changed();
      return;
    }
    _automaticWorking = true;
    try {
      await recordLandmark('路標 ${_nodes.length + 1}', '', automatic: true);
    } finally {
      _automaticWorking = false;
    }
  }

  int? _index, _transition;
  String notice = 'ready';
  String? problem;
  RouteLibraryEntry? selected;
  RouteLocalizer? _localizer;
  bool get busy => _busy || _stopping;
  bool get running => _running;
  bool get dirty => _dirty;
  bool get canEdit =>
      !_disposed &&
      _foreground &&
      !_busy &&
      !_stopping &&
      !_reloadRequired &&
      mode == RecordedRouteMode.record;
  bool get canCapture => canEdit && _running;
  bool get canSaveDraft =>
      canEdit && (_nodes.isNotEmpty || _markFailures.isNotEmpty);
  bool get canCheck =>
      !_disposed &&
      _foreground &&
      !_busy &&
      _running &&
      mode == RecordedRouteMode.replay &&
      !finished;
  String get name => _name;
  List<RoutePoint> get nodes => List.unmodifiable(_nodes);
  List<RouteMarkFailure> get markFailures => List.unmodifiable(_markFailures);
  String? get actualNodeId => _localizer?.actualNodeId;
  FloorRef? get actualFloor => _localizer?.actualFloor;
  FloorRef? get expectedFloor => _localizer?.expectedFloor;
  RoutePoint? get confirmedReplayMark {
    final index = _index;
    if (!canCheck || index == null) return null;
    final point = _nodes[index];
    return point.id == actualNodeId && point.markType != null ? point : null;
  }

  String? get replayDirection {
    final point = confirmedReplayMark;
    if (point == null || _index! >= _edges.length) return null;
    final edge = _edges[_index!];
    return edge.confirmed && edge.mode == ConnectorMode.walk
        ? point.direction
        : null;
  }

  RoutePoint? get nextPoint => _index != null && _index! + 1 < _nodes.length
      ? _nodes[_index! + 1]
      : null;
  bool get atArrival =>
      actualNodeId != null && actualNodeId == _nodes.lastOrNull?.id;
  RouteDocument? get document => _id == null
      ? null
      : RouteDocument(
          id: _id!,
          name: _name,
          buildingId: _building,
          nodes: _nodes,
          edges: _edges,
          source: RouteContentSource.captured,
          views: _views,
          markFailures: _markFailures,
          featureRevision: RouteLocalizer.featureRevision,
          preprocessRevision: RouteLocalizer.preprocessRevision,
        );
  bool _current(int op) => !_disposed && _foreground && op == _epoch;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  String _newId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  void _error(Object error) {
    problem = error is RouteStoreFailure
        ? error.problem.name
        : error is LandmarkFailure
        ? error.code
        : 'failed';
    notice = error is LandmarkFailure ? 'captureFailed' : 'error';
  }

  Future<void> refresh() async {
    if (_disposed || !_foreground || _busy) return;
    final op = ++_epoch;
    _busy = true;
    _changed();
    try {
      final all = await store.list();
      final captured = <RouteLibraryEntry>[];
      for (final entry in all.routes) {
        try {
          if ((await store.read(entry.id)).document.source ==
              RouteContentSource.captured) {
            captured.add(entry);
          }
        } on RouteStoreFailure catch (error) {
          captured.add(
            RouteLibraryEntry(
              id: entry.id,
              name: entry.name,
              revision: entry.revision,
              versions: entry.versions,
              rollbackVersions: entry.rollbackVersions,
              activeVersion: entry.activeVersion,
              draftVersion: entry.draftVersion,
              problem: error.problem,
            ),
          );
        }
      }
      if (!_current(op)) return;
      entries = List.unmodifiable(captured);
      problem = null;
    } catch (e) {
      if (_current(op)) _error(e);
    } finally {
      if (_current(op)) {
        _busy = false;
        _changed();
      }
    }
  }

  Future<void> startRecording(String name, {bool automatic = false}) async {
    if (_disposed ||
        !_foreground ||
        _busy ||
        name.trim().isEmpty ||
        name.length > 120) {
      return;
    }
    await pause();
    if (_disposed || !_foreground || notice == 'stopUnconfirmed') return;
    _localizer?.dispose();
    _localizer = null;
    _withdrawFloorContext();
    _recordingConnector = null;
    _floorCandidates = const [];
    _manualEntryPending = false;
    automaticRecording = automatic;
    automaticCandidates = 0;
    _id = _newId();
    _building = 'b-$_id';
    _name = name.trim();
    _revision = 0;
    _captureVersion = 1;
    _nodes = [];
    _edges = [];
    _views = [];
    _markFailures = [];
    _media = {};
    selected = null;
    _dirty = false;
    _reloadRequired = false;
    finished = false;
    _index = _transition = null;
    mode = RecordedRouteMode.record;
    await resume();
  }

  Future<void> resume() async {
    if (_disposed ||
        !_foreground ||
        _busy ||
        _stopping ||
        _id == null ||
        _reloadRequired ||
        finished ||
        mode == RecordedRouteMode.library) {
      return;
    }
    if (mode == RecordedRouteMode.replay && _localizer == null) {
      notice = 'draft';
      _changed();
      return;
    }
    final op = ++_epoch;
    _busy = true;
    problem = null;
    notice = 'starting';
    _changed();
    try {
      final status = await source.start(
        routeId: _id!,
        routeVersion: _captureVersion,
      );
      if (!_current(op)) return;
      _running = status == RouteCaptureStatus.running;
      notice = _running ? 'ready' : status.name;
      if (_running) _armAutomatic();
    } catch (e) {
      if (_current(op)) _error(e);
    } finally {
      if (_current(op)) {
        _busy = false;
        _changed();
      }
    }
  }

  String _normalizedFloor(String value) =>
      value.trim().toUpperCase().replaceAll(RegExp(r'[\s/]'), '');

  FloorRef? _floor(String label, bool confirmed) {
    if (!confirmed || label.trim().isEmpty) return null;
    if (label.trim().length > 40) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    for (final n in _nodes) {
      if (n.floor != null &&
          _normalizedFloor(n.floor!.label) == _normalizedFloor(label)) {
        return n.floor;
      }
    }
    return FloorRef(_building, 'f-${_newId()}', label.trim());
  }

  RouteSegment _edge(int index, ConnectorMode mode, bool confirmed) {
    final a = _nodes[index - 1], b = _nodes[index];
    return RouteSegment(
      a.id,
      b.id,
      mode,
      connectorId: mode == ConnectorMode.walk ? null : 'connector-$index',
      confirmed:
          confirmed &&
          a.floor != null &&
          b.floor != null &&
          (mode != ConnectorMode.walk || a.floor == b.floor),
    );
  }

  Future<(RouteKeyframe, LandmarkAnalysis)> _capture(int op) async {
    final captured = await source.capture();
    if (!_current(op) || !_running) throw const LandmarkFailure('cancelled');
    final frame = captured.keyframe;
    if (frame == null) throw LandmarkFailure(captured.status.name);
    final value = await analyzer.analyze(frame);
    if (!_current(op) || !_running) throw const LandmarkFailure('cancelled');
    return (frame, value);
  }

  void _recordMarkFailure(
    String type,
    String? direction,
    DateTime attemptedAtUtc,
    RouteMarkFailureReason reason,
  ) {
    if (_markFailures.length == RouteDocument.maxMarkFailures) {
      _markFailures.removeAt(0);
    }
    _markFailures.add(
      RouteMarkFailure(
        markType: type,
        direction: direction,
        attemptedAtUtc: attemptedAtUtc,
        reason: reason,
      ),
    );
    _dirty = true;
    notice = reason == RouteMarkFailureReason.capacity
        ? 'markCapacity'
        : 'markFailed';
  }

  Future<bool> recordLandmark(
    String name,
    String floor, {
    ConnectorMode mode = ConnectorMode.walk,
    bool confirmed = false,
    String? nodeId,
    bool automatic = false,
    bool inheritContext = false,
    bool connectionConfirmed = true,
    String? markType,
    String? direction,
  }) async {
    if (!RoutePoint.validMark(markType, direction)) return false;
    if (!canCapture || name.trim().isEmpty || name.length > 120) return false;
    final existing = nodeId == null
        ? null
        : _nodes.indexWhere((n) => n.id == nodeId);
    if (existing != null && existing < 0) return false;
    final attemptedAtUtc = markType != null && nodeId == null && !automatic
        ? DateTime.now().toUtc()
        : null;
    if (_views.length >= (automatic ? 48 : 64) ||
        (nodeId != null &&
            _views.where((v) => v.nodeId == nodeId).length >= 4)) {
      problem = 'capacity';
      notice = 'error';
      if (attemptedAtUtc != null) {
        _recordMarkFailure(
          markType!,
          direction,
          attemptedAtUtc,
          RouteMarkFailureReason.capacity,
        );
      }
      _changed();
      return false;
    }
    if ((_recordingConnector ?? mode) != ConnectorMode.walk) {
      _withdrawFloorContext();
    }
    final op = _epoch;
    _busy = true;
    problem = null;
    if (!automatic) notice = 'capturing';
    _changed();
    try {
      final (frame, value) = await _capture(op);
      final floorToken = RegExp(
        r'^(?:[BL]?\d{1,2}F|G|GF|UG|LG|M|[0-9一二三四五六七八九十百零]{1,5}樓)$',
      );
      _floorCandidatesAt = _floorClock.elapsed;
      _floorCandidates = List.unmodifiable(
        value.text
            .map(_normalizedFloor)
            .where((v) => floorToken.hasMatch(v))
            .toSet()
            .take(5),
      );
      final conflicting =
          _recordingFloor != null &&
          _floorCandidates.any(
            (v) => v != _normalizedFloor(_recordingFloor!.label),
          );
      if (conflicting) _withdrawFloorContext();
      if (automatic) {
        automaticCandidates++;
        if (!await RouteFrameQuality.usable(frame)) {
          if (_current(op)) {
            notice = conflicting ? 'floorConflict' : 'automaticLowDetail';
          }
          return false;
        }
        if (!_current(op) || !_running) return false;
        if (_views.any((v) => v.imageSha == value.imageSha)) {
          notice = conflicting ? 'floorConflict' : 'automaticDuplicate';
          return false;
        }
        if (_views.isNotEmpty) {
          final last = _media[_views.last.featureSha];
          if (last == null) throw const LandmarkFailure('invalid');
          final distances = await analyzer.compare(value.feature, [last]);
          if (!_current(op) || !_running) return false;
          if (distances.single < 2) {
            notice = conflicting ? 'floorConflict' : 'automaticDuplicate';
            return false;
          }
        }
      }
      var serial = 1;
      while (_nodes.any((n) => n.id == 'n-$serial')) {
        serial++;
      }
      final id = nodeId ?? 'n-$serial';
      if (_views.any((v) => v.nodeId == id && v.imageSha == value.imageSha)) {
        notice = 'duplicate';
        return false;
      }
      final featureSha = sha256.convert(value.feature).toString();
      final view = CapturedRouteView(
        nodeId: id,
        viewId: 'v-${_views.where((v) => v.nodeId == id).length + 1}',
        imageSha: value.imageSha,
        imageBytes: frame.bytes.length,
        width: frame.width,
        height: frame.height,
        featureSha: featureSha,
        featureBytes: value.feature.length,
        savedAtUtc: DateTime.now().toUtc().toIso8601String(),
        observation: frame.observation,
      );
      view.validate(_id!);
      if (nodeId == null) {
        final inherited =
            (automatic ||
                inheritContext ||
                (!confirmed && floor.trim().isEmpty)) &&
            _recordingFloor != null;
        final f = inherited ? _recordingFloor : _floor(floor, confirmed);
        if (!inherited && _recordingFloor != null && f != _recordingFloor) {
          _withdrawFloorContext();
        }
        _nodes.add(
          RoutePoint(
            id,
            name.trim(),
            automatic ? 'Landmark ${_nodes.length + 1}' : name.trim(),
            markType: markType,
            direction: direction,
            floor: f,
            floorEvidence: inherited ? FloorEvidence.inherited : null,
            floorAnchorId: inherited ? _recordingAnchor : null,
          ),
        );
        if (_nodes.length > 1) {
          _edges.add(
            _edge(
              _nodes.length - 1,
              _recordingConnector ?? mode,
              confirmed && connectionConfirmed,
            ),
          );
        }
      }
      _views.add(view);
      _media[value.imageSha] = Uint8List.fromList(frame.bytes)
          .asUnmodifiableView();
      _media[featureSha] = value.feature;
      _dirty = true;
      notice = conflicting ? 'floorConflict' : 'captured';
      return true;
    } catch (e) {
      if (_current(op)) {
        if (automatic) {
          _error(e);
          final pauseEpoch = _epoch + 1;
          await pause();
          if (!_disposed &&
              _foreground &&
              _epoch == pauseEpoch &&
              notice != 'stopUnconfirmed') {
            notice = 'automaticFailed';
            _changed();
          }
        } else {
          _error(e);
          if (attemptedAtUtc != null) {
            _recordMarkFailure(
              markType!,
              direction,
              attemptedAtUtc,
              RouteMarkFailureReason.capture,
            );
          }
        }
      }
    } finally {
      if (_current(op)) {
        _busy = false;
        _changed();
      }
    }
    return false;
  }

  Future<bool> mark(String type, String label, {String? direction}) async {
    if (!canCapture || mode != RecordedRouteMode.record) return false;
    final count = _nodes.where((n) => n.markType == type).length + 1;
    return recordLandmark(
      '$label $count',
      '',
      inheritContext: true,
      markType: type,
      direction: direction,
    );
  }

  bool get canUndoMark =>
      canEdit &&
      mode == RecordedRouteMode.record &&
      _nodes.any((n) => n.markType != null);
  bool undoLastMark() {
    if (!canUndoMark) return false;
    final index = _nodes.lastIndexWhere((n) => n.markType != null);
    final removed = _nodes.removeAt(index);
    final oldEdges = List<RouteSegment>.of(_edges);
    _edges.clear();
    for (var i = 1; i < _nodes.length; i++) {
      final matching = oldEdges.where(
        (e) => e.fromId == _nodes[i - 1].id && e.toId == _nodes[i].id,
      );
      _edges.add(
        matching.isNotEmpty
            ? matching.first
            : RouteSegment(_nodes[i - 1].id, _nodes[i].id, ConnectorMode.walk),
      );
    }
    _views.removeWhere((v) => v.nodeId == removed.id);
    final used = _views.expand((v) => [v.imageSha, v.featureSha]).toSet();
    _media.removeWhere((key, _) => !used.contains(key));
    _dirty = true;
    notice = 'markUndone';
    _changed();
    return true;
  }

  bool updateMarkNote(RoutePoint mark, String input) {
    final text = input.trim();
    final note = text.isEmpty ? null : text;
    if (note != null && !RoutePoint.validTextNote(note)) return false;
    return _updateMarkNotes(mark, textNote: note, audioNote: mark.audioNote);
  }

  bool updateMarkAudioNote(RoutePoint mark, RouteAudioNote? note) {
    final otherBytes = _nodes.fold<int>(
      0,
      (sum, point) =>
          sum +
          (identical(point, mark) ? 0 : point.audioNote?.bytes.length ?? 0),
    );
    if (otherBytes + (note?.bytes.length ?? 0) >
        RouteMediaBounds.audioBytesPerRoute) {
      return false;
    }
    return _updateMarkNotes(mark, textNote: mark.textNote, audioNote: note);
  }

  bool _updateMarkNotes(
    RoutePoint mark, {
    required String? textNote,
    required RouteAudioNote? audioNote,
  }) {
    if (!canEdit || mark.markType == null) return false;
    final index = _nodes.indexOf(mark);
    if (index < 0) return false;
    if (mark.textNote == textNote && identical(mark.audioNote, audioNote)) {
      return true;
    }
    _nodes[index] = RoutePoint(
      mark.id,
      mark.nameZh,
      mark.nameEn,
      floor: mark.floor,
      markType: mark.markType,
      direction: mark.direction,
      textNote: textNote,
      audioNote: audioNote,
      floorEvidence: mark.floorEvidence,
      floorAnchorId: mark.floorAnchorId,
      isFloorContextAnchor: mark.isFloorContextAnchor,
    );
    _dirty = true;
    notice = 'noteEdited';
    _changed();
    return true;
  }

  void updateNode(
    int index,
    String name,
    String floor,
    ConnectorMode mode,
    bool confirmed,
  ) {
    if (!canEdit ||
        index < 0 ||
        index >= _nodes.length ||
        name.trim().isEmpty ||
        name.length > 120) {
      return;
    }
    try {
      final previous = _nodes[index];
      final previousMode = index > 0
          ? _edges[index - 1].mode
          : ConnectorMode.walk;
      final preserve =
          previous.floor != null &&
          _normalizedFloor(previous.floor!.label) == _normalizedFloor(floor) &&
          previousMode == mode &&
          confirmed == incomingConfirmed(index);
      final f = preserve ? previous.floor : _floor(floor, confirmed);
      _nodes[index] = RoutePoint(
        previous.id,
        name.trim(),
        name.trim(),
        markType: previous.markType,
        direction: previous.direction,
        textNote: previous.textNote,
        audioNote: previous.audioNote,
        floor: f,
        floorEvidence: preserve ? previous.floorEvidence : null,
        floorAnchorId: preserve ? previous.floorAnchorId : null,
        isFloorContextAnchor: previous.isFloorContextAnchor && f != null,
      );
      if (index > 0) {
        _edges[index - 1] = _edge(
          index,
          mode,
          confirmed && (previous.floor == null || previous.floor == f),
        );
      }
      if (previous.floor != f || previousMode != mode) {
        _withdrawFloorContext();
        for (var j = index + 1; j < _nodes.length; j++) {
          final n = _nodes[j];
          if (n.floorAnchorId == null) continue;
          final anchor = _nodes.indexWhere((p) => p.id == n.floorAnchorId);
          if (anchor > index) continue;
          _nodes[j] = RoutePoint(
            n.id,
            n.nameZh,
            n.nameEn,
            markType: n.markType,
            direction: n.direction,
            textNote: n.textNote,
            audioNote: n.audioNote,
          );
          final e = _edges[j - 1];
          _edges[j - 1] = RouteSegment(
            e.fromId,
            e.toId,
            e.mode,
            connectorId: e.connectorId,
            confirmed: false,
          );
          if (j < _edges.length) {
            final next = _edges[j];
            _edges[j] = RouteSegment(
              next.fromId,
              next.toId,
              next.mode,
              connectorId: next.connectorId,
              confirmed: false,
            );
          }
        }
      }
      if (previous.floor != f && index < _edges.length) {
        final old = _edges[index];
        _edges[index] = RouteSegment(
          old.fromId,
          old.toId,
          old.mode,
          connectorId: old.connectorId,
          confirmed: false,
        );
      }
      _dirty = true;
      notice = 'edited';
      problem = null;
    } catch (e) {
      _error(e);
    }
    _changed();
  }

  Future<void> save({required bool activate, String? name}) async {
    if (!canSaveDraft) return;
    if (name != null) {
      if (name.trim().isEmpty || name.length > 120) return;
      _name = name.trim();
    }
    _withdrawFloorContext();
    _recordingConnector = null;
    _floorCandidates = const [];
    _automaticTimer?.cancel();
    final op = ++_epoch;
    _busy = true;
    _running = false;
    _stopping = true;
    problem = null;
    _changed();
    try {
      final stopped = await source.stop();
      await analyzer.cancel();
      if (!_current(op)) return;
      if (stopped == RouteCaptureStatus.stopUnconfirmed) {
        notice = 'stopUnconfirmed';
        return;
      }
      final doc = document!;
      final saved = await store.save(
        doc,
        token: store.capture(doc.id),
        expectedRevision: _revision,
        activate: activate,
        media: _media,
      );
      if (!_current(op)) return;
      _captureVersion = saved.version;
      _revision++;
      _dirty = false;
      notice = 'saved';
    } catch (e) {
      if (_current(op)) {
        _error(e);
        notice = 'saveFailed';
        if (e is RouteStoreFailure &&
            [
              RouteProblem.outcomeUnknown,
              RouteProblem.conflict,
            ].contains(e.problem)) {
          _reloadRequired = true;
        }
      }
    } finally {
      _stopping = false;
      if (_current(op)) {
        _busy = false;
        _changed();
      }
    }
  }

  Future<void> open(RouteLibraryEntry entry, {bool recording = false}) async {
    await pause();
    if (_disposed || !_foreground || notice == 'stopUnconfirmed') return;
    _clearSelection();
    final op = ++_epoch;
    _busy = true;
    problem = null;
    _changed();
    try {
      final version = recording
          ? (entry.draftVersion ?? entry.activeVersion)
          : (entry.activeVersion ?? entry.draftVersion);
      final snapshot = await store.read(entry.id, version: version);
      final doc = snapshot.document;
      if (doc.source != RouteContentSource.captured) {
        throw const RouteStoreFailure(RouteProblem.incompatible);
      }
      final hashes = recording
          ? null
          : {
              for (final v in doc.views)
                if (v.featureSha != null) v.featureSha!,
            };
      final media = await store.readMediaBatch(
        entry.id,
        snapshot.version,
        hashes: hashes,
      );
      if (!_current(op)) return;
      _id = doc.id;
      _building = doc.buildingId;
      _name = doc.name;
      _nodes = List.of(doc.nodes);
      _edges = List.of(doc.edges);
      _views = List.of(doc.views);
      _markFailures = List.of(doc.markFailures);
      _media = Map.of(media);
      selected = entry;
      _revision = entry.revision;
      _captureVersion = snapshot.version;
      _dirty = false;
      _reloadRequired = false;
      finished = false;
      _index = _transition = null;
      mode = recording ? RecordedRouteMode.record : RecordedRouteMode.replay;
      _localizer?.dispose();
      _localizer = null;
      if (!recording && snapshot.published && doc.complete && doc.compatible) {
        _localizer = RouteLocalizer(
          routeId: doc.id,
          routeVersion: snapshot.version,
          landmarks: [
            for (final n in doc.nodes)
              RouteLandmarkIdentity(
                n.id,
                n.floor!,
                [
                  for (final v in doc.views.where(
                    (v) => v.nodeId == n.id && v.featureSha != null,
                  ))
                    v.viewId,
                ],
                exitForConnectors: [
                  for (final e in doc.edges.where(
                    (e) =>
                        e.toId == n.id &&
                        e.mode != ConnectorMode.walk &&
                        e.confirmed,
                  ))
                    e.connectorId!,
                ],
              ),
          ],
        );
        notice = 'replayReady';
      } else {
        notice = recording
            ? 'paused'
            : !doc.compatible
            ? 'incompatible'
            : 'draft';
      }
    } catch (e) {
      if (_current(op)) _error(e);
    } finally {
      if (_current(op)) {
        _busy = false;
        _changed();
      }
    }
  }

  Future<bool> checkPosition(
    String nodeId,
    String floor, {
    required bool directionConfirmed,
  }) async {
    if (!canCheck || _localizer == null) return false;
    final candidates = _nodes.where((n) => n.id == nodeId).toList();
    if (candidates.length != 1) return false;
    final node = candidates.single;
    _localizer!.pause();
    if (_transition != null) {
      final edge = _edges[_transition!];
      if (edge.toId != nodeId) {
        notice = 'wrongNode';
        _changed();
        return false;
      }
      _localizer!.expectFloor(
        node.floor,
        exitNodeId: node.id,
        connectorId: edge.connectorId,
      );
    } else {
      _localizer!.expectFloor(null);
    }
    if (node.floor == null ||
        _normalizedFloor(floor) != _normalizedFloor(node.floor!.label) ||
        !directionConfirmed) {
      notice = !directionConfirmed ? 'wrongDirection' : 'wrongFloor';
      _changed();
      return false;
    }
    final op = _epoch, watch = Stopwatch()..start();
    final trip = learningEnabled ? _learningTrip : null;
    _busy = true;
    problem = null;
    notice = 'checking';
    _changed();
    try {
      final (frame, value) = await _capture(op);
      final featureViews = _views.where((v) => v.featureSha != null).toList();
      final distances = await analyzer.compare(value.feature, [
        for (final v in featureViews)
          _media[v.featureSha] ??
              (throw const RouteStoreFailure(RouteProblem.corrupt)),
      ]);
      if (!_current(op) || !_running) return false;
      final ticket = _localizer!.beginObservation(
        frameAge:
            Duration(milliseconds: (frame.observation['ageMs'] as num).ceil()) +
            watch.elapsed,
      );
      _localizer!.accept(
        ticket,
        [
          for (var i = 0; i < featureViews.length; i++)
            RouteViewDistance(
              featureViews[i].nodeId,
              featureViews[i].viewId,
              distances[i],
            ),
        ],
        feature: RouteLocalizer.featureRevision,
        preprocess: RouteLocalizer.preprocessRevision,
        ocr: value.text,
      );
      final prediction = _localizer!.result;
      if (trip != null &&
          ['candidate', 'unknown', 'ambiguous'].contains(prediction.name)) {
        unawaited(
          _keepLearningFrame(
            trip,
            op,
            frame,
            value,
            nodeId,
            prediction,
            _localizer!.candidateNodeId,
          ),
        );
      }
      if (prediction != RouteMatchState.candidate) {
        notice = prediction.name;
        return false;
      }
      _localizer!.confirmFloor(node.floor!);
      _localizer!.confirmExit(directionConfirmed: true);
      if (_localizer!.actualNodeId != nodeId) {
        _localizer!.pause();
        notice = 'wrongNode';
        return false;
      }
      _index = _nodes.indexOf(node);
      _transition = null;
      notice = atArrival ? 'arrival' : 'confirmed';
      return true;
    } catch (e) {
      if (_current(op)) {
        _localizer?.pause();
        _error(e);
      }
    } finally {
      if (_current(op)) {
        _busy = false;
        _changed();
      }
    }
    return false;
  }

  bool enterConnector() {
    if (_disposed ||
        !_foreground ||
        _busy ||
        actualNodeId == null ||
        _index == null ||
        _index! >= _edges.length) {
      return false;
    }
    final edge = _edges[_index!];
    if (edge.mode == ConnectorMode.walk || !edge.confirmed) return false;
    _transition = _index;
    _localizer!.expectFloor(
      _nodes[_index! + 1].floor,
      exitNodeId: edge.toId,
      connectorId: edge.connectorId,
    );
    notice = 'transitioning';
    _changed();
    return true;
  }

  void clearReplayPosition() {
    if (!canCheck || actualNodeId == null) return;
    _localizer!.pause();
    notice = 'ready';
    _changed();
  }

  Future<void> confirmArrival() async {
    if (!atArrival || _busy) return;
    await pause();
    if (notice != 'stopUnconfirmed') {
      finished = true;
      notice = 'finished';
      _changed();
    }
  }

  Future<void> pause() async {
    _withdrawFloorContext();
    _recordingConnector = null;
    _floorCandidates = const [];
    _automaticTimer?.cancel();
    if (_disposed) return;
    final op = ++_epoch;
    _busy = false;
    _running = false;
    _stopping = true;
    _localizer?.pause();
    store.cancelPending();
    notice = 'stopping';
    _changed();
    final stopping = source.stop();
    await analyzer.cancel();
    final status = await stopping;
    _stopping = false;
    if (_disposed || op != _epoch) return;
    notice = status == RouteCaptureStatus.stopUnconfirmed
        ? 'stopUnconfirmed'
        : 'paused';
    _changed();
  }

  void setForeground(bool foreground) {
    if (_disposed) return;
    _foreground = foreground;
    if (!foreground) {
      unawaited(pause());
    } else {
      _changed();
    }
  }

  Future<void> delete(RouteLibraryEntry entry) async {
    await pause();
    if (_disposed || !_foreground || notice == 'stopUnconfirmed') return;
    final op = ++_epoch;
    _busy = true;
    _changed();
    try {
      await store.delete(
        entry.id,
        expectedRevision: entry.revision,
        beforeDelete: openLearningStore == null
            ? null
            : () async => (await learningStore()).deleteRoute(entry.id),
      );
      if (!_current(op)) return;
      _clearSelection();
      notice = 'deleted';
    } catch (e) {
      if (_current(op)) _error(e);
    } finally {
      if (_current(op)) {
        _busy = false;
        _changed();
      }
    }
    await refresh();
  }

  Future<void> rollback(RouteLibraryEntry entry, int version) async {
    if (_busy || _disposed || !_foreground) return;
    await pause();
    if (notice == 'stopUnconfirmed') return;
    final op = ++_epoch;
    _busy = true;
    _changed();
    try {
      await store.rollback(entry.id, version, expectedRevision: entry.revision);
      if (_current(op)) {
        _clearSelection();
        notice = 'rolledBack';
      }
    } catch (e) {
      if (_current(op)) _error(e);
    } finally {
      if (_current(op)) {
        _busy = false;
        _changed();
      }
    }
    await refresh();
  }

  void _clearSelection() {
    _learningTrip = null;
    learningWithdrawalFailed = false;
    learningSaveFailed = false;
    _automaticTimer?.cancel();
    automaticRecording = false;
    _localizer?.dispose();
    _localizer = null;
    _id = null;
    _nodes = [];
    _edges = [];
    _views = [];
    _markFailures = [];
    _media.clear();
    selected = null;
    _dirty = false;
    _reloadRequired = false;
    finished = false;
    _index = _transition = null;
    mode = RecordedRouteMode.library;
  }

  bool get replayAvailable => _localizer != null;
  RoutePoint? get transitionExit =>
      _transition == null ? null : _nodes[_transition! + 1];
  ConnectorMode? get nextConnector =>
      _index == null || _index! >= _edges.length ? null : _edges[_index!].mode;
  int viewsFor(String id) => _views.where((v) => v.nodeId == id).length;
  ConnectorMode incomingMode(int index) =>
      index > 0 ? _edges[index - 1].mode : ConnectorMode.walk;
  bool incomingConfirmed(int index) =>
      _nodes[index].floor != null &&
      (index == 0 || _edges[index - 1].confirmed);

  Future<void> showLibrary() async {
    await pause();
    if (_disposed || !_foreground || notice == 'stopUnconfirmed') return;
    _clearSelection();
    await refresh();
  }

  Future<void> cleanup() async {
    if (_busy || _disposed || !_foreground) return;
    final op = ++_epoch;
    _busy = true;
    _changed();
    try {
      await store.pruneHistory();
      if (!_current(op)) return;
      await store.cleanupUnreferenced();
      if (_current(op)) notice = 'cleaned';
    } catch (e) {
      if (_current(op)) _error(e);
    } finally {
      if (_current(op)) {
        _busy = false;
        _changed();
      }
    }
    if (_current(op)) await refresh();
  }

  @override
  void dispose() {
    _automaticTimer?.cancel();
    _disposed = true;
    _epoch++;
    store.cancelPending();
    _localizer?.dispose();
    analyzer.dispose();
    unawaited(source.stop());
    unawaited(_events?.cancel());
    _media.clear();
    super.dispose();
  }
}
