import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:pathguide/route_memory/encrypted_route_store.dart';
import 'package:pathguide/route_memory/recorded_route_controller.dart';
import 'package:pathguide/route_memory/cross_floor_contract.dart';
import 'package:pathguide/route_memory/route_localizer.dart';
import 'package:pathguide/route_memory/route_learning_store.dart';
import 'package:pathguide/route_memory/route_package.dart';
import 'package:pathguide/route_memory/route_observation_source.dart';

import 'route_camera_fixture.dart';
import 'support/route_audio_fixture.dart';

class Vault implements RouteKeyVault {
  List<int>? bytes;
  @override
  Future<List<int>?> read() async => bytes;
  @override
  Future<void> write(List<int> b) async {
    bytes = List.of(b);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late RecordedRouteController c;
  late EncryptedRouteStore store;
  late RouteNativeFixture native;
  late Vault learningVault;
  Future<void> Function()? learningCheckpoint;
  var learningOpens = 0;
  var ordinal = 0, match = 0;
  var ambiguous = false;
  List<String> observedText = [];
  Completer<void>? analysisGate;
  const channel = MethodChannel('hk.pathguide/route_landmark');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  test('typed marks survive encrypted save/reopen and old-schema downgrade rejects', () async {
    await c.startRecording('Marks');
    expect(await c.mark('stairs', '樓梯'), isTrue);
    expect(await c.mark('junction', '左轉', direction: 'left'), isTrue);
    final doc = c.document!;
    expect(doc.toMap()['schemaVersion'], 4);
    expect(RouteDocument.fromMap(doc.toMap()).nodes.last.direction, 'left');
    expect(
      () => RouteDocument.fromMap({...doc.toMap(), 'schemaVersion': 2}),
      throwsA(isA<RouteStoreFailure>()),
    );
    await c.save(activate: false);
    await c.showLibrary();
    await c.open(c.entries.single, recording: true);
    expect(c.nodes.last.markType, 'junction');
    expect(c.nodes.last.direction, 'left');
  });
  test(
    'extra facility types survive encrypted replay and retain floor evidence',
    () async {
      await c.startRecording('Facilities');
      expect(await c.confirmCurrentFloor('G'), isTrue);
      final anchor = c.floorAnchors.single;
      for (final type in RoutePoint.moreMarkTypes) {
        expect(await c.mark(type, type), isTrue);
        expect(c.nodes.last.floorEvidence, FloorEvidence.inherited);
        expect(c.nodes.last.floorAnchorId, anchor.id);
        expect(c.nodes.last.direction, isNull);
      }
      expect(c.document!.complete, isFalse);
      expect(
        c.document!.edges.map((edge) => edge.mode),
        everyElement(ConnectorMode.walk),
      );
      final map = c.document!.toMap();
      expect(map['schemaVersion'], 5);
      expect(
        () => RouteDocument.fromMap({...map, 'schemaVersion': 4}),
        throwsA(
          isA<RouteStoreFailure>().having(
            (e) => e.problem,
            'problem',
            RouteProblem.incompatible,
          ),
        ),
      );
      await c.pause();
      c.confirmFloorSegment(anchor.id);
      await c.save(activate: true);
      final entry = (await store.list()).routes.single;
      await c.open(entry);
      expect(
        c.nodes.skip(1).map((n) => n.markType),
        RoutePoint.moreMarkTypes.toList(),
      );
      await c.resume();
      match = 2;
      expect(
        await c.checkPosition('n-3', 'G', directionConfirmed: true),
        isTrue,
      );
      expect(c.confirmedReplayMark?.markType, 'ramp');
      expect(c.replayDirection, isNull);
      await c.open(entry, recording: true);
      expect(c.undoLastMark(), isTrue);
      expect(c.nodes.last.markType, 'reception');
    },
  );
  test('undo manual mark preserves later unmarked frames and invalidates joined connection', () async {
    await c.startRecording('Undo');
    await c.recordLandmark('auto before', '');
    await c.mark('door', '門口');
    await c.recordLandmark('auto after', '');
    expect(c.undoLastMark(), isTrue);
    expect(c.nodes.map((n) => n.nameZh), ['auto before', 'auto after']);
    expect(c.document!.edges.single.confirmed, isFalse);
    expect(c.document!.views.length, 2);
    await c.mark('stairs', '樓梯');
    expect(c.nodes.map((n) => n.id).toSet().length, 3);
  });
  test('busy mark never queues a second capture', () async {
    await c.startRecording('Busy');
    analysisGate = Completer<void>();
    final first = c.mark('stairs', '樓梯');
    expect(await c.mark('door', '門口'), isFalse);
    analysisGate!.complete();
    expect(await first, isTrue);
    expect(c.nodes.length, 1);
    expect(c.nodes.single.markType, 'stairs');
    expect(c.markFailures, isEmpty);
  });

  test(
    'audio notes are bounded and encrypted without changing the media catalog',
    () async {
      final wave = syntheticNoteWav(rate: 48000, seconds: 10);
      expect(
        () => RouteAudioNote.fromBytes(Uint8List.fromList(wave)..[0] = 0),
        throwsA(isA<RouteStoreFailure>()),
      );
      final note = RouteAudioNote.fromBytes(wave);
      await c.startRecording('Audio notes');
      for (var i = 0; i < 5; i++) {
        expect(
          await c.recordLandmark(
            'Door ${i + 1}',
            'G',
            confirmed: true,
            markType: 'door',
          ),
          isTrue,
        );
      }
      for (var i = 0; i < 4; i++) {
        expect(c.updateMarkAudioNote(c.nodes[i], note), isTrue);
      }
      expect(c.updateMarkAudioNote(c.nodes.last, note), isFalse);
      expect(c.updateMarkNote(c.nodes.first, 'Reception'), isTrue);
      c.updateNode(0, 'Door by reception', 'G', ConnectorMode.walk, true);
      expect(c.nodes.first.audioNote, same(note));
      final map = c.document!.toMap();
      expect(map['schemaVersion'], 8);
      expect(
        () => RouteDocument.fromMap({...map, 'schemaVersion': 7}),
        throwsA(isA<RouteStoreFailure>()),
      );
      await c.save(activate: true);
      expect(c.notice, 'saved');
      final files = await root
          .list(recursive: true)
          .where((f) => f is File && f.path.endsWith('.enc'))
          .cast<File>()
          .toList();
      for (final file in files) {
        expect(await file.readAsString(), isNot(contains(note.encoded)));
      }
      final entry = (await store.list()).routes.single;
      await c.open(entry);
      expect(c.confirmedReplayMark, isNull);
      await c.resume();
      expect(
        await c.checkPosition('n-1', 'G', directionConfirmed: true),
        isTrue,
      );
      expect(c.confirmedReplayMark?.audioNote?.encoded, note.encoded);
      expect(c.confirmedReplayMark?.textNote, 'Reception');
      await c.open(entry, recording: true);
      for (var i = 0; i < 4; i++) {
        expect(c.updateMarkAudioNote(c.nodes[i], null), isTrue);
      }
      expect(c.document!.toMap()['schemaVersion'], 7);
      await c.delete(entry);
      expect((await store.list()).routes, isEmpty);
    },
  );

  test(
    'text notes stay on the selected mark through review and encrypted replay',
    () async {
      await c.startRecording('Notes');
      expect(await c.confirmCurrentFloor('G'), isTrue);
      final anchor = c.floorAnchors.single;
      expect(c.updateMarkNote(anchor, 'Unmarked point'), isFalse);
      expect(await c.mark('junction', '左轉', direction: 'left'), isTrue);
      expect(await c.mark('ramp', '斜道'), isTrue);
      final mark = c.nodes[1];
      final lastFrame = native.capturedResponse;
      expect(
        c.updateMarkNote(mark, 'x' * (RoutePoint.maxTextNoteLength + 1)),
        isFalse,
      );
      expect(c.updateMarkNote(mark, '👩‍👩‍👦‍👦' * 100), isFalse);
      const note = '右邊有接待處。';
      expect(c.updateMarkNote(mark, '  $note\n'), isTrue);
      expect(c.nodes[1].textNote, note);
      expect(c.nodes[2].textNote, isNull);
      expect(native.capturedResponse, same(lastFrame));
      expect(c.updateMarkNote(mark, 'Stale edit'), isFalse);
      c.updateNode(1, '轉角', 'G', ConnectorMode.walk, false);
      expect(c.nodes[1].id, mark.id);
      expect(c.nodes[1].direction, 'left');
      expect(c.nodes[1].textNote, note);
      native.changeCapture = (reply) => {...reply, 'status': 'no_frame'};
      expect(await c.mark('door', '門口'), isFalse);
      native.changeCapture = null;
      await c.pause();
      c.confirmFloorSegment(anchor.id);
      expect(c.nodes[1].floorEvidence, FloorEvidence.segmentConfirmed);
      expect(c.nodes[1].textNote, note);

      final manifest = c.document!.toMap();
      expect(manifest['schemaVersion'], 7);
      expect(
        () => RouteDocument.fromMap({...manifest, 'schemaVersion': 6}),
        throwsA(isA<RouteStoreFailure>()),
      );
      await c.save(activate: true);
      final entry = (await store.list()).routes.single;
      await c.open(entry);
      expect(c.markFailures.single.markType, 'door');
      expect(c.confirmedReplayMark, isNull);
      await c.resume();
      match = 1;
      expect(
        await c.checkPosition(mark.id, 'G', directionConfirmed: true),
        isTrue,
      );
      expect(c.confirmedReplayMark?.textNote, note);
      expect(c.replayDirection, 'left');

      await c.open(entry, recording: true);
      final reopened = c.nodes[1];
      expect(reopened.textNote, note);
      expect(c.updateMarkNote(reopened, '   '), isTrue);
      expect(c.nodes[1].textNote, isNull);
      expect(c.document!.toMap()['schemaVersion'], 6);
      expect(c.updateMarkNote(c.nodes.last, 'Another note'), isTrue);
      expect(c.undoLastMark(), isTrue);
      expect(c.document!.nodes.every((n) => n.textNote == null), isTrue);
    },
  );
  test(
    'failed manual marks stay in an encrypted draft through retry and undo',
    () async {
      await c.startRecording('Failed turn');
      native.changeCapture = (reply) => {...reply, 'status': 'no_frame'};
      expect(await c.mark('junction', '左轉', direction: 'left'), isFalse);
      expect(c.running, isTrue);
      expect(c.notice, 'markFailed');
      expect(c.dirty, isTrue);
      expect(c.document!.nodes, isEmpty);
      expect(c.document!.views, isEmpty);
      final failure = c.markFailures.single;
      expect(failure.direction, 'left');
      expect(failure.reason, RouteMarkFailureReason.capture);
      expect(failure.attemptedAtUtc.isUtc, isTrue);
      final failureMap = c.document!.toMap();
      expect(failureMap['schemaVersion'], 6);
      expect(
        () => RouteDocument.fromMap({...failureMap, 'schemaVersion': 5}),
        throwsA(isA<RouteStoreFailure>()),
      );

      native.changeCapture = null;
      observedText = ['A' * 121];
      expect(await c.mark('door', '門口'), isFalse);
      expect(c.markFailures.last.markType, 'door');
      expect(c.document!.views, isEmpty);
      observedText = [];
      expect(await c.mark('junction', '左轉', direction: 'left'), isTrue);
      expect(c.nodes.single.nameZh, '左轉 1');
      expect(c.markFailures, hasLength(2));
      expect(c.undoLastMark(), isTrue);
      expect(c.document!.views, isEmpty);
      expect(c.canSaveDraft, isTrue);
      await c.save(activate: false);
      final entry = (await store.list()).routes.single;
      expect(entry.activeVersion, isNull);
      await c.open(entry);
      expect(c.nodes, isEmpty);
      expect(c.replayAvailable, isFalse);
      expect(c.markFailures.first.toMap(), failure.toMap());
      expect(c.markFailures.last.markType, 'door');

      await c.open(entry, recording: true);
      await c.resume();
      native.delayCapture = true;
      final pending = c.mark('stairs', '樓梯');
      await Future<void>.delayed(Duration.zero);
      await c.pause();
      native.captureReply!.complete(native.capturedResponse);
      expect(await pending, isFalse);
      expect(c.markFailures, hasLength(2));
      expect(c.dirty, isFalse);
      await c.delete(entry);
      expect(c.markFailures, isEmpty);
      expect((await store.list()).routes, isEmpty);
    },
  );

  test(
    'capacity failures retain only the latest attempts without taking photos',
    () async {
      await c.startRecording('Photo limit');
      for (var i = 0; i < RouteMediaBounds.viewsPerRoute; i++) {
        expect(
          await c.recordLandmark('Point ${i + 1}', 'G', confirmed: true),
          isTrue,
        );
      }
      final lastCapture = native.capturedResponse;
      expect(await c.mark('stairs', 'Stairs'), isFalse);
      expect(c.markFailures.single.reason, RouteMarkFailureReason.capacity);
      for (var i = 0; i < RouteDocument.maxMarkFailures; i++) {
        expect(await c.mark('ramp', 'Ramp'), isFalse);
      }
      expect(c.notice, 'markCapacity');
      expect(c.markFailures, hasLength(RouteDocument.maxMarkFailures));
      expect(c.markFailures.map((f) => f.markType), everyElement('ramp'));
      expect(native.capturedResponse, same(lastCapture));
      expect(c.document!.complete, isTrue);
      await c.save(activate: true);
      await c.open((await store.list()).routes.single);
      expect(c.replayAvailable, isTrue);
      expect(c.markFailures, hasLength(RouteDocument.maxMarkFailures));
      expect(c.nodes, hasLength(RouteMediaBounds.viewsPerRoute));
      expect(c.nodes.every((point) => point.markType == null), isTrue);
    },
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('record-route-');
    native = RouteNativeFixture()..attach();
    ordinal = 0;
    match = 0;
    ambiguous = false;
    observedText = [];
    analysisGate = null;
    learningCheckpoint = null;
    learningVault = Vault();
    learningOpens = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final a = Map<String, Object?>.from(call.arguments as Map);
      if (call.method == 'cancel') return null;
      if (call.method == 'compare') {
        return {
          ...a,
          'status': 'ok',
          'distances': [
            for (var i = 0; i < (a['references'] as List).length; i++)
              ambiguous || i == match ? 0.0 : 20.0,
          ],
        };
      }
      await analysisGate?.future;
      final f = Uint8List.fromList([++ordinal]);
      return {
        ...a,
        'status': 'ok',
        'feature': f,
        'featureSha': sha256.convert(f).toString(),
        'text': observedText,
        'ocrRevision': 3,
        'manualFloorConfirmationRequired': true,
      };
    });
    store = await EncryptedRouteStore.open(root: root, vault: Vault());
    c = RecordedRouteController(
      store: store,
      source: RouteObservationSource(supported: true),
      openLearningStore: () {
        learningOpens++;
        return RouteLearningStore.open(
          root: root,
          vault: learningVault,
          checkpoint: () async => learningCheckpoint?.call(),
        );
      },
    );
  });
  tearDown(() async {
    await c.pause();
    c.dispose();
    await Future<void>.delayed(Duration.zero);
    native.detach();
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });
  Future<void> record() async {
    await c.startRecording('G to classroom');
    await c.recordLandmark('Entrance', 'G', confirmed: true);
    await c.recordLandmark('Lift', 'G', confirmed: true);
    await c.recordLandmark(
      'Lift exit',
      '3F',
      mode: ConnectorMode.elevator,
      confirmed: true,
    );
    await c.recordLandmark('Room', '3F', confirmed: true);
    await c.save(activate: true);
  }

  Future<void> replay() async {
    await record();
    await c.open((await store.list()).routes.single);
    await c.resume();
  }

  void useDetailedFrame([String file = 'synthetic-detail-grid.jpg']) {
    final jpeg = File('test/fixtures/route_camera/$file').readAsBytesSync();
    native.changeCapture = (v) {
      v['jpeg'] = jpeg;
      v['sha256'] = sha256.convert(jpeg).toString();
      v['byteCount'] = jpeg.length;
      v['width'] = 64;
      v['height'] = 64;
      (v['header'] as Map<String, Object?>).addAll({
        'rawWidth': 64,
        'rawHeight': 64,
        'uprightWidth': 64,
        'uprightHeight': 64,
      });
      return v;
    };
  }

  Future<void> waitForCandidate(RouteLearningStore learning) async {
    for (var i = 0; i < 200; i++) {
      if ((await learning.list()).isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Candidate was not stored');
  }

  test(
    'learning is opt-in and separately stores prediction and requested node',
    () async {
      await replay();
      useDetailedFrame();
      expect(
        await c.checkPosition('n-1', 'G', directionConfirmed: true),
        isTrue,
      );
      expect(learningOpens, 0);
      c.enableLearning();
      match = 1;
      expect(
        await c.checkPosition('n-1', 'G', directionConfirmed: true),
        isFalse,
      );
      expect(c.notice, 'wrongNode');
      final learning = await c.learningStore();
      await waitForCandidate(learning);
      final record = await learning.read((await learning.list()).single);
      expect(record['prediction'], 'candidate');
      expect(record['predictedNode'], 'n-2');
      expect(record['requestedNode'], 'n-1');
      expect(record['routeVersion'], c.selected!.activeVersion);
      expect(record['state'], 'pending');
      expect(record['reviews'], isEmpty);
      final entry = c.selected!;
      await c.open(entry);
      expect(c.learningEnabled, isFalse);
      expect(await learning.list(routeId: entry.id), hasLength(1));
      await c.delete(entry);
      expect(await learning.list(), isEmpty);
      expect((await store.list()).routes, isEmpty);
    },
  );

  for (final withdraw in [true, false]) {
    test(
      'learning write is fenced by ${withdraw ? 'withdrawal' : 'background'}',
      () async {
        await replay();
        useDetailedFrame();
        c.enableLearning();
        final learning = await c.learningStore();
        final atCommit = Completer<void>(), releaseCommit = Completer<void>();
        learningCheckpoint = () async {
          if (!atCommit.isCompleted) atCommit.complete();
          await releaseCommit.future;
        };
        expect(
          await c.checkPosition('n-1', 'G', directionConfirmed: true),
          isTrue,
        );
        await atCommit.future.timeout(const Duration(seconds: 3));
        Future<void>? withdrawal;
        if (withdraw) {
          withdrawal = c.withdrawLearning();
          expect(c.actualNodeId, 'n-1');
          expect(c.learningEnabled, isFalse);
        } else {
          c.setForeground(false);
        }
        releaseCommit.complete();
        await withdrawal;
        expect(await learning.list(), isEmpty);
      },
    );
  }

  test(
    'withdrawing candidates leaves the recorded route and position intact',
    () async {
      await replay();
      useDetailedFrame();
      c.enableLearning();
      expect(
        await c.checkPosition('n-1', 'G', directionConfirmed: true),
        isTrue,
      );
      final learning = await c.learningStore();
      await waitForCandidate(learning);
      await c.withdrawLearning();
      expect(await learning.list(), isEmpty);
      expect(c.actualNodeId, 'n-1');
      expect(c.learningEnabled, isFalse);
      expect(
        (await store.list()).routes.single.activeVersion,
        c.selected!.activeVersion,
      );
    },
  );

  test(
    'candidate storage failure leaves a successful landmark check intact',
    () async {
      await replay();
      useDetailedFrame();
      learningCheckpoint = () async => throw const FileSystemException('test');
      c.enableLearning();
      expect(
        await c.checkPosition('n-1', 'G', directionConfirmed: true),
        isTrue,
      );
      for (var i = 0; i < 200 && !c.learningSaveFailed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(c.learningSaveFailed, isTrue);
      expect(c.actualNodeId, 'n-1');
      expect(await (await c.learningStore()).list(), isEmpty);
    },
  );

  test(
    'feature similarity rejects different JPEGs of a similar candidate',
    () async {
      useDetailedFrame();
      await c.startRecording('automatic', automatic: true);
      await c.sampleAutomatically();
      expect(c.nodes.length, 1);
      useDetailedFrame('synthetic-detail-grid-alt.jpg');
      match = 0;
      await c.sampleAutomatically();
      expect(c.nodes.length, 1);
      expect(c.notice, 'automaticDuplicate');
      match = 1;
      await c.sampleAutomatically();
      expect(c.nodes.length, 2);
      expect(c.document!.complete, isFalse);
      await c.pause();
    },
  );
  test(
    'confirmed anchor is inherited, reviewed once and preserved as schema3',
    () async {
      useDetailedFrame();
      await c.startRecording('context', automatic: true);
      expect(await c.confirmCurrentFloor('G'), isTrue);
      final anchor = c.nodes.first.id;
      useDetailedFrame('synthetic-detail-grid-alt.jpg');
      match = 1;
      await c.sampleAutomatically();
      expect(c.nodes.length, 2);
      expect(c.nodes.last.floor!.label, 'G');
      expect(c.nodes.last.floorEvidence, FloorEvidence.inherited);
      expect(c.nodes.last.floorAnchorId, anchor);
      expect(c.document!.complete, isFalse);
      await c.pause();
      expect(c.recordingFloor, isNull);
      c.confirmFloorSegment(anchor);
      expect(c.nodes.last.floorEvidence, FloorEvidence.segmentConfirmed);
      expect(c.document!.complete, isTrue);
      await c.save(activate: true);
      await c.open((await store.list()).routes.single, recording: true);
      expect(c.document!.toMap()['schemaVersion'], 3);
      expect(c.nodes.last.floorEvidence, FloorEvidence.segmentConfirmed);
      expect(c.recordingFloor, isNull);
      c.updateNode(0, 'anchor', '1F', ConnectorMode.walk, true);
      expect(c.nodes.last.floor, isNull);
      expect(c.document!.complete, isFalse);
    },
  );
  test('floor-change entry withdraws inherited context until a new explicit exit anchor', () async {
    useDetailedFrame();
    await c.startRecording('lift', automatic: true);
    await c.confirmCurrentFloor('G');
    expect(await c.beginFloorChange(ConnectorMode.elevator), isTrue);
    expect(c.recordingFloor, isNull);
    expect(await c.confirmCurrentFloor('3F'), isTrue);
    expect(c.recordingFloor!.label, '3F');
    expect(c.incomingMode(c.nodes.length - 1), ConnectorMode.elevator);
    expect(c.document!.complete, isFalse);
    await c.pause();
    expect(c.recordingFloor, isNull);
  });
  test(
    'conflicting OCR withdraws context even when candidate image is duplicate',
    () async {
      useDetailedFrame();
      await c.startRecording('context', automatic: true);
      await c.confirmCurrentFloor('G');
      observedText = ['3F'];
      await c.sampleAutomatically();
      expect(c.recordingFloor, isNull);
      expect(c.notice, 'floorConflict');
      expect(c.floorCandidates, ['3F']);
      expect(
        c.nodes.length,
        1,
      ); // OCR is not an automatically confirmed anchor.
      await c.pause();
    },
  );
  test(
    'new anchor after unknown does not approve the unknown connection',
    () async {
      useDetailedFrame();
      await c.startRecording('context', automatic: true);
      await c.confirmCurrentFloor('G');
      c.markFloorUnknown();
      expect(c.recordingFloor, isNull);
      await c.confirmCurrentFloor('G');
      await c.pause();
      c.confirmFloorSegment(c.nodes.first.id);
      expect(c.incomingConfirmed(1), isFalse);
      expect(c.document!.complete, isFalse);
    },
  );
  test('renaming inherited point retains its source and ancestor edit invalidates later inheritance', () async {
    useDetailedFrame();
    await c.startRecording('context', automatic: true);
    await c.confirmCurrentFloor('G');
    useDetailedFrame('synthetic-detail-grid-alt.jpg');
    match = 1;
    await c.sampleAutomatically();
    c.updateNode(1, '已補名稱', 'G', ConnectorMode.walk, false);
    expect(c.nodes[1].floorEvidence, FloorEvidence.inherited);
    expect(c.nodes[1].floor!.label, 'G');
    // A manual important checkpoint may inherit without becoming confirmed.
    await c.recordLandmark('角位', '', inheritContext: true);
    expect(c.nodes.last.floorEvidence, FloorEvidence.inherited);
    c.updateNode(1, '新樓層', '1F', ConnectorMode.walk, true);
    expect(c.nodes.last.floor, isNull);
    expect(c.recordingFloor, isNull);
    expect(c.document!.complete, isFalse);
    await c.pause();
  });
  test('manual blank floor inherits valid context and later automatic draft remains saveable', () async {
    useDetailedFrame();
    await c.startRecording('manual context', automatic: true);
    await c.confirmCurrentFloor('G');
    await c.recordLandmark('手動角位', '');
    expect(c.nodes.last.floorEvidence, FloorEvidence.inherited);
    useDetailedFrame('synthetic-detail-grid-alt.jpg');
    match = 1;
    await c.sampleAutomatically();
    expect(c.nodes.length, 3);
    expect(c.document!.complete, isFalse);
    await c.save(activate: false);
    expect(c.notice, 'saved');
    await c.open((await store.list()).routes.single, recording: true);
    expect(c.nodes.length, 3);
  });
  test(
    'changing confirmed exit floor withdraws incoming connector confirmation',
    () async {
      useDetailedFrame();
      await c.startRecording('lift', automatic: true);
      await c.confirmCurrentFloor('G');
      await c.beginFloorChange(ConnectorMode.elevator);
      await c.confirmCurrentFloor('3F');
      c.updateNode(2, '出口', '3F', ConnectorMode.elevator, true);
      expect(c.incomingConfirmed(2), isTrue);
      c.updateNode(2, '出口', '4F', ConnectorMode.elevator, true);
      expect(c.incomingConfirmed(2), isFalse);
      expect(c.recordingFloor, isNull);
      await c.pause();
    },
  );
  test('manual non-walk checkpoint breaks context and following draft remains valid', () async {
    useDetailedFrame();
    await c.startRecording('manual device', automatic: true);
    await c.confirmCurrentFloor('G');
    await c.recordLandmark('設備', '', mode: ConnectorMode.elevator);
    expect(c.recordingFloor, isNull);
    expect(c.nodes.last.floor, isNull);
    useDetailedFrame('synthetic-detail-grid-alt.jpg');
    match = 1;
    await c.sampleAutomatically();
    expect(c.nodes.last.floor, isNull);
    expect(c.document!.complete, isFalse);
    await c.save(activate: false);
    expect(c.notice, 'saved');
  });
  testWidgets(
    'start once creates an automatic draft and pause prevents later additions',
    (t) async {
      useDetailedFrame();
      await c.startRecording('automatic', automatic: true);
      await t.pump(const Duration(seconds: 5));
      for (var i = 0; i < 30; i++) {
        await t.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await t.pump();
      }
      expect(c.nodes.length, 1);
      expect(c.nodes.first.floor, isNull);
      await c.pause();
      await t.pump(const Duration(seconds: 15));
      expect(c.nodes.length, 1);
      expect(c.running, isFalse);
    },
  );
  test('low detail candidate is not added and manual pending input suspends sampling', () async {
    await c.startRecording('automatic', automatic: true);
    c.setManualEntryPending(true);
    await c.sampleAutomatically();
    expect(c.nodes, isEmpty);
    c.setManualEntryPending(false);
    await c.sampleAutomatically();
    // Existing tiny camera fixture has insufficient detail at the engineering screen.
    expect(c.nodes, isEmpty);
    expect(c.notice, 'automaticLowDetail');
    await c.pause();
  });
  test(
    'automatic recording adds numbered unknown drafts without a landmark form',
    () async {
      useDetailedFrame();
      await c.startRecording('automatic', automatic: true);
      await c.sampleAutomatically();
      expect(
        c.nodes.length,
        1,
        reason: '${c.notice}/${c.problem} candidates=${c.automaticCandidates}',
      );
      expect(c.nodes.first.nameZh, '路標 1');
      expect(c.nodes.first.floor, isNull);
      await c.sampleAutomatically();
      expect(c.nodes.length, 1); // repeated photo is not a new landmark.
      await c.save(activate: false);
      final entry = (await store.list()).routes.single;
      expect(entry.activeVersion, isNull);
      await c.open(entry, recording: true);
      expect(c.nodes.length, 1);
      expect(c.document!.complete, isFalse);
    },
  );
  test('empty library records G lift 3F room, saves and reopens for confirmed replay', () async {
    await replay();
    expect(c.document!.complete, isTrue);
    match = 1;
    await c.checkPosition('n-2', 'G', directionConfirmed: true);
    expect(c.actualNodeId, 'n-2');
    expect(c.enterConnector(), isTrue);
    expect(c.actualFloor, isNull);
    match = 2;
    await c.checkPosition('n-3', '3F', directionConfirmed: true);
    expect(c.actualFloor!.label, '3F');
    match = 3;
    await c.checkPosition('n-4', '3F', directionConfirmed: true);
    expect(c.finished, isFalse);
    await c.confirmArrival();
    expect(c.finished, isTrue);
  });
  test(
    'unknown floor or unconfirmed segment stays draft and cannot start replay',
    () async {
      await c.startRecording('draft');
      await c.recordLandmark('G', 'G', confirmed: true);
      await c.recordLandmark('unknown', '3F');
      expect(c.document!.complete, isFalse);
      await c.save(activate: false);
      final entry = (await store.list()).routes.single;
      expect(entry.activeVersion, isNull);
      await c.open(entry);
      await c.resume();
      expect(c.running, isFalse);
      expect(c.replayAvailable, isFalse);
      await c.open(entry, recording: true);
      c.updateNode(1, 'Exit', '3F', ConnectorMode.elevator, true);
      expect(c.document!.complete, isTrue);
      await c.save(activate: true);
      expect(c.notice, 'saved');
    },
  );
  test('wrong floor, wrong direction, ambiguous match and wrong requested node hold position', () async {
    await replay();
    await c.checkPosition('n-1', '3F', directionConfirmed: true);
    expect(c.actualFloor, isNull);
    await c.checkPosition('n-1', 'G', directionConfirmed: false);
    expect(c.actualFloor, isNull);
    ambiguous = true;
    await c.checkPosition('n-1', 'G', directionConfirmed: true);
    expect(c.actualNodeId, isNull);
    ambiguous = false;
    match = 1;
    await c.checkPosition('n-1', 'G', directionConfirmed: true);
    expect(c.actualNodeId, isNull);
    match = 2;
    await c.checkPosition('n-3', '3F', directionConfirmed: true);
    expect(c.actualNodeId, 'n-3'); // Explicit mid-route recovery.
    await c.pause();
    expect(c.actualFloor, isNull);
    await c.resume();
    expect(c.actualFloor, isNull);
  });
  test('floor transition is bound to recorded exit and cannot certify another node', () async {
    await replay();
    match = 1;
    await c.checkPosition('n-2', 'G', directionConfirmed: true);
    expect(c.enterConnector(), isTrue);
    match = 3;
    await c.checkPosition('n-4', '3F', directionConfirmed: true);
    expect(c.notice, 'wrongNode');
    expect(c.actualFloor, isNull);
  });
  test(
    'replay uses fresh manual directions only for confirmed walk segments',
    () async {
      await c.startRecording('Directions');
      for (final direction in ['left', 'right', 'straight', 'left']) {
        expect(
          await c.recordLandmark(
            direction,
            'G',
            confirmed: true,
            markType: 'junction',
            direction: direction,
          ),
          isTrue,
        );
      }
      expect(
        await c.recordLandmark(
          'Exit',
          '3F',
          confirmed: true,
          mode: ConnectorMode.elevator,
        ),
        isTrue,
      );
      expect(
        await c.recordLandmark('Door', '3F', confirmed: true, markType: 'door'),
        isTrue,
      );
      expect(
        await c.recordLandmark(
          'End',
          '3F',
          confirmed: true,
          markType: 'junction',
          direction: 'right',
        ),
        isTrue,
      );
      await c.save(activate: true);
      await c.open((await store.list()).routes.single);
      await c.resume();
      expect(c.replayDirection, isNull);

      for (final (index, direction) in ['left', 'right', 'straight'].indexed) {
        match = index;
        expect(
          await c.checkPosition(
            'n-${index + 1}',
            'G',
            directionConfirmed: true,
          ),
          isTrue,
        );
        expect(c.confirmedReplayMark?.id, 'n-${index + 1}');
        expect(c.replayDirection, direction);
      }
      expect(
        await c.checkPosition('n-3', '3F', directionConfirmed: true),
        isFalse,
      );
      expect(c.replayDirection, isNull);
      expect(
        await c.checkPosition('n-3', 'G', directionConfirmed: false),
        isFalse,
      );
      expect(c.replayDirection, isNull);
      ambiguous = true;
      expect(
        await c.checkPosition('n-3', 'G', directionConfirmed: true),
        isFalse,
      );
      expect(c.replayDirection, isNull);
      ambiguous = false;
      expect(
        await c.checkPosition('n-2', 'G', directionConfirmed: true),
        isFalse,
      );
      expect(c.replayDirection, isNull);
      await c.checkPosition('n-3', 'G', directionConfirmed: true);
      expect(c.replayDirection, 'straight');
      await Future<void>.delayed(RouteLocalizer.validity);
      expect(c.replayDirection, isNull);
      expect(c.actualNodeId, isNull);
      await c.checkPosition('n-3', 'G', directionConfirmed: true);
      c.clearReplayPosition();
      expect(c.replayDirection, isNull);
      expect(c.actualNodeId, isNull);
      await c.checkPosition('n-3', 'G', directionConfirmed: true);
      await c.pause();
      expect(c.replayDirection, isNull);
      await c.resume();
      expect(c.replayDirection, isNull);

      match = 3;
      await c.checkPosition('n-4', 'G', directionConfirmed: true);
      expect(c.confirmedReplayMark?.markType, 'junction');
      expect(c.replayDirection, isNull);
      expect(c.enterConnector(), isTrue);
      expect(c.confirmedReplayMark, isNull);
      match = 4;
      await c.checkPosition('n-5', '3F', directionConfirmed: true);
      expect(c.actualNodeId, 'n-5');
      expect(c.confirmedReplayMark, isNull);
      match = 5;
      await c.checkPosition('n-6', '3F', directionConfirmed: true);
      expect(c.confirmedReplayMark?.markType, 'door');
      expect(c.replayDirection, isNull);
      match = 6;
      await c.checkPosition('n-7', '3F', directionConfirmed: true);
      expect(c.atArrival, isTrue);
      expect(c.replayDirection, isNull);
    },
  );
  test(
    'background during analysis rejects late capture and does not restart',
    () async {
      await c.startRecording('late');
      analysisGate = Completer<void>();
      final pending = c.recordLandmark('Entrance', 'G', confirmed: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      c.setForeground(false);
      analysisGate!.complete();
      await pending;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.nodes, isEmpty);
      expect(c.running, isFalse);
      c.setForeground(true);
      expect(c.running, isFalse);
    },
  );
  test('editing a floor withdraws outgoing connection and never reuses floor identity', () async {
    await record();
    final old = c.nodes[2].floor;
    c.updateNode(2, 'Exit', '4F', ConnectorMode.elevator, true);
    expect(c.nodes[2].floor, isNot(old));
    expect(c.incomingConfirmed(3), isFalse);
    expect(c.document!.complete, isFalse);
  });
  test(
    'replay writes no photos or versions, delete removes all route media',
    () async {
      await replay();
      final before = await root
          .list(recursive: true)
          .where((f) => f is File)
          .map((f) => f.path)
          .toList();
      match = 0;
      await c.checkPosition('n-1', 'G', directionConfirmed: true);
      final after = await root
          .list(recursive: true)
          .where((f) => f is File)
          .map((f) => f.path)
          .toList();
      expect(after.toSet(), before.toSet());
      final entry = (await store.list()).routes.single;
      await c.delete(entry);
      expect((await store.list()).routes, isEmpty);
      expect(c.document, isNull);
    },
  );
  test(
    'failed open clears prior route so it cannot replay the wrong selection',
    () async {
      await replay();
      final stale = (await store.list()).routes.single;
      await store.delete(stale.id, expectedRevision: stale.revision);
      await c.open(stale);
      expect(c.document, isNull);
      expect(c.replayAvailable, isFalse);
      await c.resume();
      expect(c.running, isFalse);
    },
  );
}
