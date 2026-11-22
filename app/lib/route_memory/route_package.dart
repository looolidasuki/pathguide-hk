import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

import 'cross_floor_contract.dart';
import 'route_media.dart';
import 'route_platform_profile.dart';
export 'route_media.dart';

enum RouteProblem {
  invalid,
  conflict,
  cancelled,
  deleted,
  notFound,
  corrupt,
  incompatible,
  keyUnavailable,
  busy,
  io,
  cleanupPending,
  capacity,
  outcomeUnknown,
}

class RouteStoreFailure implements Exception {
  const RouteStoreFailure(this.problem);
  final RouteProblem problem;
  @override
  String toString() => 'RouteStoreFailure(${problem.name})';
}

enum FloorEvidence { unknown, confirmed, inherited, segmentConfirmed }

@immutable
class RoutePoint {
  static const moreMarkTypes = {'escalator', 'ramp', 'reception', 'sign'};
  static const markTypes = {
    'landmark',
    'junction',
    'door',
    'stairs',
    'lift',
    'toilet',
    ...moreMarkTypes,
  };
  static const directions = {'left', 'right', 'straight'};
  static const maxTextNoteLength = 240;
  static const maxTextNoteBytes = 1024;
  static bool validMark(String? type, String? direction) =>
      (type == null || markTypes.contains(type)) &&
      (direction == null ||
          (type == 'junction' && directions.contains(direction)));
  static bool validTextNote(String text) =>
      text.isNotEmpty &&
      text == text.trim() &&
      text.length <= maxTextNoteBytes &&
      text.characters.length <= maxTextNoteLength &&
      utf8.encode(text).length <= maxTextNoteBytes;

  const RoutePoint(
    this.id,
    this.nameZh,
    this.nameEn, {
    this.floor,
    this.markType,
    this.direction,
    this.textNote,
    this.audioNote,
    FloorEvidence? floorEvidence,
    this.floorAnchorId,
    this.isFloorContextAnchor = false,
  }) : floorEvidence =
           floorEvidence ??
           (floor == null ? FloorEvidence.unknown : FloorEvidence.confirmed);
  final String id, nameZh, nameEn;
  final String? markType, direction, textNote;
  final RouteAudioNote? audioNote;
  final FloorRef? floor;
  final FloorEvidence floorEvidence;
  final String? floorAnchorId;
  final bool isFloorContextAnchor;
}

enum RouteMarkFailureReason { capture, capacity }

@immutable
class RouteMarkFailure {
  const RouteMarkFailure({
    required this.markType,
    this.direction,
    required this.attemptedAtUtc,
    required this.reason,
  });

  final String markType;
  final String? direction;
  final DateTime attemptedAtUtc;
  final RouteMarkFailureReason reason;

  Map<String, Object?> toMap() => {
    'markType': markType,
    if (direction != null) 'direction': direction,
    'attemptedAtUtc': attemptedAtUtc.toIso8601String(),
    'reason': reason.name,
  };

  factory RouteMarkFailure.fromMap(Map<String, dynamic> v) {
    final time = DateTime.tryParse(v['attemptedAtUtc'] as String);
    if (time == null || time.toIso8601String() != v['attemptedAtUtc']) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    return RouteMarkFailure(
      markType: v['markType'] as String,
      direction: v['direction'] as String?,
      attemptedAtUtc: time,
      reason: RouteMarkFailureReason.values.byName(v['reason'] as String),
    );
  }
}

@immutable
class RouteSegment {
  const RouteSegment(
    this.fromId,
    this.toId,
    this.mode, {
    this.connectorId,
    this.confirmed = false,
  });
  final String fromId, toId;
  final ConnectorMode mode;
  final String? connectorId;
  final bool confirmed;
}

enum RouteContentSource { synthetic, captured }

/// Schema 1 remains synthetic; schema 2 explicitly references captured media.
/// 'Complete' means structurally checked; never human/field approved.
class RouteDocument {
  RouteDocument({
    required this.id,
    required this.name,
    required this.buildingId,
    required List<RoutePoint> nodes,
    required List<RouteSegment> edges,
    this.source = RouteContentSource.synthetic,
    List<CapturedRouteView> views = const [],
    List<RouteMarkFailure> markFailures = const [],
    this.featureRevision = 'p0-synthetic-v1',
    this.preprocessRevision = 'none-synthetic',
  }) : views = List.unmodifiable(views),
       nodes = List.unmodifiable(nodes),
       edges = List.unmodifiable(edges),
       markFailures = List.unmodifiable(markFailures) {
    validate();
  }
  final String id, name, buildingId, featureRevision, preprocessRevision;
  final RouteContentSource source;
  final List<CapturedRouteView> views;
  final List<RoutePoint> nodes;
  final List<RouteSegment> edges;
  final List<RouteMarkFailure> markFailures;
  static const maxMarkFailures = 64;
  int get audioNoteBytes =>
      nodes.fold(0, (sum, n) => sum + (n.audioNote?.bytes.length ?? 0));
  int get encodedAudioNoteLength =>
      nodes.fold(0, (sum, n) => sum + (n.audioNote?.encoded.length ?? 0));
  static bool validId(String id) =>
      RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(id);
  bool get compatible =>
      compatibleRevisions(source, featureRevision, preprocessRevision);

  /// Captured routes replay only with this platform's landmark descriptor
  /// (iOS Vision feature print, Android MobileNetV3-small embedder); features
  /// from another profile are not comparable. See RouteFeatureProfile.
  static bool compatibleRevisions(
    RouteContentSource source,
    String featureRevision,
    String preprocessRevision,
  ) => source == RouteContentSource.synthetic
      ? featureRevision == 'p0-synthetic-v1' &&
            preprocessRevision == 'none-synthetic'
      : featureRevision == RoutePlatform.feature.featureRevision &&
            preprocessRevision == RoutePlatform.feature.preprocessRevision;

  void validate() {
    if ((source == RouteContentSource.synthetic &&
            (views.isNotEmpty || markFailures.isNotEmpty)) ||
        (source == RouteContentSource.captured &&
            (featureRevision == 'p0-synthetic-v1' ||
                preprocessRevision == 'none-synthetic')) ||
        views.length > RouteMediaBounds.viewsPerRoute ||
        markFailures.length > maxMarkFailures ||
        audioNoteBytes > RouteMediaBounds.audioBytesPerRoute ||
        markFailures.any(
          (f) =>
              !f.attemptedAtUtc.isUtc ||
              !RoutePoint.validMark(f.markType, f.direction),
        )) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    final identities = <String>{}, images = <String>{};
    final perNode = <String, int>{};
    for (final view in views) {
      view.validate(id);
      perNode[view.nodeId] = (perNode[view.nodeId] ?? 0) + 1;
      if (!nodes.any((n) => n.id == view.nodeId) ||
          !identities.add('${view.nodeId}/${view.viewId}') ||
          !images.add('${view.nodeId}/${view.imageSha}') ||
          perNode[view.nodeId]! > RouteMediaBounds.viewsPerNode) {
        throw const RouteStoreFailure(RouteProblem.invalid);
      }
    }
    if (!validId(id) ||
        !validId(buildingId) ||
        name.trim().isEmpty ||
        name.length > 120 ||
        nodes.length > 512 ||
        edges.length > 511 ||
        featureRevision.isEmpty ||
        featureRevision.length > 80 ||
        preprocessRevision.isEmpty ||
        preprocessRevision.length > 80 ||
        nodes.map((n) => n.id).toSet().length != nodes.length) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    for (final n in nodes) {
      if ((n.markType != null && source != RouteContentSource.captured) ||
          !RoutePoint.validMark(n.markType, n.direction) ||
          (n.textNote != null &&
              (n.markType == null || !RoutePoint.validTextNote(n.textNote!))) ||
          (n.audioNote != null && n.markType == null) ||
          !validId(n.id) ||
          n.nameZh.length > 120 ||
          n.nameEn.length > 120 ||
          (n.floor != null &&
              (n.floor!.buildingId != buildingId ||
                  !validId(n.floor!.id) ||
                  n.floor!.label.isEmpty ||
                  n.floor!.label.length > 40))) {
        throw const RouteStoreFailure(RouteProblem.invalid);
      }
    }
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final derived = [
        FloorEvidence.inherited,
        FloorEvidence.segmentConfirmed,
      ].contains(n.floorEvidence);
      if ((n.floor == null) != (n.floorEvidence == FloorEvidence.unknown) ||
          (derived != (n.floorAnchorId != null)) ||
          (source == RouteContentSource.synthetic &&
              (derived || n.isFloorContextAnchor)) ||
          (n.isFloorContextAnchor &&
              n.floorEvidence != FloorEvidence.confirmed)) {
        throw const RouteStoreFailure(RouteProblem.invalid);
      }
      if (derived) {
        final anchor = nodes.indexWhere((a) => a.id == n.floorAnchorId);
        if (anchor < 0 ||
            anchor >= i ||
            nodes[anchor].floorEvidence != FloorEvidence.confirmed ||
            !nodes[anchor].isFloorContextAnchor ||
            nodes[anchor].floor != n.floor ||
            nodes[anchor].floor!.label != n.floor!.label) {
          throw const RouteStoreFailure(RouteProblem.invalid);
        }
        for (var j = anchor + 1; j <= i; j++) {
          if (nodes[j].floor != n.floor ||
              nodes[j].floor!.label != n.floor!.label ||
              j - 1 >= edges.length ||
              edges[j - 1].mode != ConnectorMode.walk) {
            throw const RouteStoreFailure(RouteProblem.invalid);
          }
        }
      }
    }
    if (edges.length > (nodes.isEmpty ? 0 : nodes.length - 1)) {
      throw const RouteStoreFailure(RouteProblem.invalid);
    }
    for (var i = 0; i < edges.length; i++) {
      if (edges[i].fromId != nodes[i].id ||
          edges[i].toId != nodes[i + 1].id ||
          (edges[i].connectorId != null && !validId(edges[i].connectorId!))) {
        throw const RouteStoreFailure(RouteProblem.invalid);
      }
    }
  }

  bool get _hasProvenance =>
      source == RouteContentSource.captured &&
      nodes.any(
        (n) =>
            n.isFloorContextAnchor ||
            n.floorAnchorId != null ||
            n.floorEvidence == FloorEvidence.inherited ||
            n.floorEvidence == FloorEvidence.segmentConfirmed,
      );
  bool get _hasMarkMetadata =>
      markFailures.isNotEmpty || nodes.any((n) => n.markType != null);

  bool get complete {
    if (nodes.length < 2 ||
        edges.length != nodes.length - 1 ||
        nodes.any(
          (n) =>
              n.floor == null ||
              ![
                FloorEvidence.confirmed,
                FloorEvidence.segmentConfirmed,
              ].contains(n.floorEvidence),
        )) {
      return false;
    }
    if (source == RouteContentSource.captured &&
        nodes.any(
          (node) =>
              !views.any((v) => v.nodeId == node.id && v.featureSha != null),
        )) {
      return false;
    }
    for (var i = 0; i < edges.length; i++) {
      final e = edges[i];
      if (!e.confirmed ||
          (e.mode == ConnectorMode.walk &&
              nodes[i].floor != nodes[i + 1].floor) ||
          (e.mode != ConnectorMode.walk && e.connectorId == null)) {
        return false;
      }
    }
    return true;
  }

  Map<String, Object?> toMap() => {
    'schemaVersion': source == RouteContentSource.synthetic
        ? 1
        : nodes.any((n) => n.audioNote != null)
        ? 8
        : nodes.any((n) => n.textNote != null)
        ? 7
        : markFailures.isNotEmpty
        ? 6
        : nodes.any((n) => RoutePoint.moreMarkTypes.contains(n.markType))
        ? 5
        : _hasMarkMetadata
        ? 4
        : _hasProvenance
        ? 3
        : 2,
    'source': source.name,
    if (source == RouteContentSource.captured)
      'views': [for (final view in views) view.toMap()],
    if (markFailures.isNotEmpty)
      'markFailures': [for (final failure in markFailures) failure.toMap()],
    'direction': 'recorded',
    'id': id,
    'name': name,
    'buildingId': buildingId,
    'featureRevision': featureRevision,
    'preprocessRevision': preprocessRevision,
    'nodes': [
      for (final n in nodes)
        {
          'id': n.id,
          if (_hasMarkMetadata) 'markType': n.markType,
          if (_hasMarkMetadata) 'markDirection': n.direction,
          if (n.textNote != null) 'textNote': n.textNote,
          if (n.audioNote != null) 'audioNote': n.audioNote!.encoded,
          if (_hasProvenance || _hasMarkMetadata)
            'floorEvidence': n.floorEvidence.name,
          if (_hasProvenance || _hasMarkMetadata)
            'floorAnchor': n.floorAnchorId,
          if (_hasProvenance || _hasMarkMetadata)
            'floorContextAnchor': n.isFloorContextAnchor,
          'zh': n.nameZh,
          'en': n.nameEn,
          'floor': n.floor == null
              ? null
              : {
                  'building': n.floor!.buildingId,
                  'id': n.floor!.id,
                  'label': n.floor!.label,
                },
        },
    ],
    'edges': [
      for (final e in edges)
        {
          'from': e.fromId,
          'to': e.toId,
          'mode': e.mode.name,
          'connector': e.connectorId,
          'confirmed': e.confirmed,
        },
    ],
  };

  static FloorEvidence _decodeFloorEvidence(Object? raw) {
    for (final value in FloorEvidence.values) {
      if (value.name == raw) return value;
    }
    throw const RouteStoreFailure(RouteProblem.incompatible);
  }

  factory RouteDocument.fromMap(Map<String, dynamic> v) {
    final schema = v['schemaVersion'];
    final hasFloorEvidence = [3, 4, 5, 6, 7, 8].contains(schema);
    final hasMarks = [4, 5, 6, 7, 8].contains(schema);
    final synthetic =
        schema == 1 && v['source'] == 'synthetic' && !v.containsKey('views');
    final captured =
        [2, 3, 4, 5, 6, 7, 8].contains(schema) && v['source'] == 'captured';
    if ((!synthetic && !captured) || v['direction'] != 'recorded') {
      throw const RouteStoreFailure(RouteProblem.incompatible);
    }
    final rawFailures = v['markFailures'];
    final hasFailures = v.containsKey('markFailures');
    if ((schema == 6 && !hasFailures) ||
        (hasFailures &&
            ((schema != 6 && schema != 7 && schema != 8) ||
                rawFailures is! List ||
                rawFailures.isEmpty ||
                rawFailures.length > maxMarkFailures))) {
      throw const RouteStoreFailure(RouteProblem.incompatible);
    }
    final nodes = v['nodes'] as List;
    final noteNodes = nodes.where((n) => n is Map && n.containsKey('textNote'));
    final audioNodes = nodes.where(
      (n) => n is Map && n.containsKey('audioNote'),
    );
    if ((schema == 7 && noteNodes.isEmpty) ||
        (noteNodes.isNotEmpty &&
            ((schema != 7 && schema != 8) ||
                noteNodes.any((n) => n['textNote'] is! String))) ||
        (schema == 8
            ? audioNodes.isEmpty ||
                  audioNodes.any((n) => n['audioNote'] is! String)
            : audioNodes.isNotEmpty)) {
      throw const RouteStoreFailure(RouteProblem.incompatible);
    }
    if (!hasFloorEvidence &&
        nodes.any(
          (n) =>
              n is Map &&
              [
                'floorEvidence',
                'floorAnchor',
                'floorContextAnchor',
              ].any(n.containsKey),
        )) {
      throw const RouteStoreFailure(RouteProblem.incompatible);
    }
    if (nodes.any(
      (n) =>
          n is Map &&
          ((!hasMarks &&
                  (n.containsKey('markType') ||
                      n.containsKey('markDirection'))) ||
              (schema == 4 &&
                  RoutePoint.moreMarkTypes.contains(n['markType']))),
    )) {
      throw const RouteStoreFailure(RouteProblem.incompatible);
    }
    return RouteDocument(
      source: captured
          ? RouteContentSource.captured
          : RouteContentSource.synthetic,
      views: captured
          ? [
              for (final view in v['views'] as List)
                CapturedRouteView.fromMap(
                  Map<String, dynamic>.from(view as Map),
                ),
            ]
          : const [],
      markFailures: hasFailures
          ? [
              for (final failure in rawFailures as List)
                RouteMarkFailure.fromMap(
                  Map<String, dynamic>.from(failure as Map),
                ),
            ]
          : const [],
      id: v['id'] as String,
      name: v['name'] as String,
      buildingId: v['buildingId'] as String,
      featureRevision: v['featureRevision'] as String,
      preprocessRevision: v['preprocessRevision'] as String,
      nodes: [
        for (final n in nodes)
          RoutePoint(
            n['id'] as String,
            n['zh'] as String,
            n['en'] as String,
            markType: hasMarks ? n['markType'] as String? : null,
            direction: hasMarks ? n['markDirection'] as String? : null,
            textNote: n['textNote'] as String?,
            audioNote: n['audioNote'] == null
                ? null
                : RouteAudioNote.fromBase64(n['audioNote'] as String),
            floorEvidence: hasFloorEvidence
                ? _decodeFloorEvidence(n['floorEvidence'])
                : null,
            isFloorContextAnchor: hasFloorEvidence
                ? (n['floorContextAnchor'] as bool? ?? false)
                : false,
            floorAnchorId: hasFloorEvidence
                ? n['floorAnchor'] as String?
                : null,
            floor: n['floor'] == null
                ? null
                : FloorRef(
                    n['floor']['building'] as String,
                    n['floor']['id'] as String,
                    n['floor']['label'] as String,
                  ),
          ),
      ],
      edges: [
        for (final e in v['edges'] as List)
          RouteSegment(
            e['from'] as String,
            e['to'] as String,
            ConnectorMode.values.byName(e['mode'] as String),
            connectorId: e['connector'] as String?,
            confirmed: e['confirmed'] as bool,
          ),
      ],
    );
  }
}

@immutable
class RouteSnapshot {
  const RouteSnapshot(
    this.document,
    this.version,
    this.published,
    this.manifestSha,
  );
  final RouteDocument document;
  final int version;
  final bool published;
  final String manifestSha;
}

@immutable
class RouteLibraryEntry {
  RouteLibraryEntry({
    required this.id,
    required this.name,
    required this.revision,
    required List<int> versions,
    required List<int> rollbackVersions,
    this.activeVersion,
    this.draftVersion,
    this.problem,
  }) : versions = List.unmodifiable(versions),
       rollbackVersions = List.unmodifiable(rollbackVersions);
  final String id, name;
  final int revision;
  final int? activeVersion, draftVersion;
  final List<int> versions, rollbackVersions;
  final RouteProblem? problem;
}

@immutable
class RouteLibraryListing {
  RouteLibraryListing(List<RouteLibraryEntry> routes, this.pendingCleanup)
    : routes = List.unmodifiable(routes);
  final List<RouteLibraryEntry> routes;
  final int pendingCleanup;
}
