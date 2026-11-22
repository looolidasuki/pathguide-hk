import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/navigation/navigation_hub_page.dart';
import 'package:pathguide/route_memory/encrypted_route_store.dart';
import 'package:pathguide/route_memory/recorded_route_controller.dart';
import 'package:pathguide/route_memory/route_audio_note_dialog.dart';
import 'package:pathguide/route_memory/route_journey_page.dart';
import 'package:pathguide/route_memory/route_localizer.dart';
import 'package:pathguide/route_memory/route_observation_source.dart';
import 'package:pathguide/route_memory/route_package.dart';
import 'package:pathguide/route_memory/cross_floor_contract.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/ui/app_theme.dart';

import 'route_record_replay_test.dart' show Vault;
import 'captured_route_store_test.dart' show capturedDocument, capturedMedia;
import 'route_camera_fixture.dart';
import 'support/route_audio_fixture.dart';

void main() {
  for (final language in AppLanguage.values) {
    testWidgets(
      '${language.name}: floor and lift choices are accessible at double text size',
      (t) async {
        final root = (await t.runAsync(
          () => Directory.systemTemp.createTemp('floor-choice-ui-'),
        ))!;
        final store = (await t.runAsync(
          () => EncryptedRouteStore.open(root: root, vault: Vault()),
        ))!;
        final native = RouteNativeFixture()..attach();
        const channel = MethodChannel('hk.pathguide/route_landmark');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'cancel') return null;
          final f = Uint8List.fromList([1]);
          return {
            ...Map<String, Object?>.from(call.arguments as Map),
            'status': 'ok',
            'feature': f,
            'featureSha': sha256.convert(f).toString(),
            'text': <String>[],
            'ocrRevision': 3,
            'manualFloorConfirmationRequired': true,
          };
        });
        final c = RecordedRouteController(
          store: store,
          source: RouteObservationSource(supported: true),
        );
        await c.startRecording('Floor test');
        t.view.physicalSize = const Size(320, 568);
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        String label(String zh, String en) =>
            language == AppLanguage.chinese ? zh : en;
        Future<void> progress(bool Function() done) async {
          for (var i = 0; i < 200 && !done(); i++) {
            await t.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            });
            await t.pump();
          }
          await t.pumpAndSettle();
          expect(done(), isTrue);
        }

        Future<void> tap(String value, {bool dialog = false}) async {
          final f = find.text(value);
          if (!dialog) {
            await t.drag(find.byType(Scrollable).first, const Offset(0, 3000));
            await t.pumpAndSettle();
            await t.scrollUntilVisible(
              f,
              100,
              scrollable: find.byType(Scrollable).first,
            );
          }
          await t.ensureVisible(f);
          await t.pumpAndSettle();
          await t.tap(f);
          await t.pumpAndSettle();
        }

        await t.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: RouteJourneyPage(
              settings: AppSettings.memory(language: language),
              createController: () async => c,
              previewBuilder: (_) => const SizedBox(),
            ),
          ),
        );
        await progress(
          () => find.byType(Scrollable).evaluate().isNotEmpty && !c.busy,
        );
        await tap(label('確認／更新目前樓層', 'Confirm or update current floor'));
        await tap(label('確認目前係 G', 'Confirm current floor G'), dialog: true);
        await progress(() => c.recordingFloor != null);
        expect(c.recordingFloor!.label, 'G');
        expect(c.nodes.last.floorEvidence, FloorEvidence.confirmed);
        await tap(label('記錄下一個路標', 'Record next landmark'));
        await t.enterText(find.byType(TextField).at(0), 'Corner');
        await tap(label('拍攝並加入', 'Capture and add'), dialog: true);
        await progress(() => c.nodes.length == 2 && !c.busy);
        expect(c.nodes.last.floorEvidence, FloorEvidence.inherited);
        expect(c.nodes.last.floor!.label, 'G');
        await tap(label('記錄轉層入口', 'Mark floor-change entrance'));
        await tap(label('升降機', 'Lift'), dialog: true);
        await progress(() => c.recordingConnector == ConnectorMode.elevator);
        expect(c.recordingFloor, isNull);
        await tap(label('確認出口樓層', 'Confirm exit floor'));
        await tap(label('確認目前係 3F', 'Confirm current floor 3F'), dialog: true);
        await progress(() => c.recordingFloor?.label == '3F');
        expect(c.document!.complete, isFalse);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() async {
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        });
        native.detach();
        messenger.setMockMethodCallHandler(channel, null);
      },
    );
  }
  testWidgets(
    'automatic recording saves and reopens text and audio on the chosen mark',
    (t) async {
      t.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(
            accessibleNavigation: true,
            supportsAnnounce: true,
          );
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final spoken = <String>[];
      final accessMessenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      accessMessenger.setMockDecodedMessageHandler(
        SystemChannels.accessibility,
        (message) async {
          if (message is Map && message['type'] == 'announce') {
            spoken.add((message['data'] as Map)['message'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => accessMessenger.setMockDecodedMessageHandler(
          SystemChannels.accessibility,
          null,
        ),
      );
      final root = (await t.runAsync(
        () => Directory.systemTemp.createTemp('automatic-ui-'),
      ))!;
      final store = (await t.runAsync(
        () => EncryptedRouteStore.open(root: root, vault: Vault()),
      ))!;
      final native = RouteNativeFixture()..attach();
      final image = File('test/fixtures/route_camera/synthetic-detail-grid.jpg')
          .readAsBytesSync();
      native.changeCapture = (v) {
        v.addAll({
          'jpeg': image,
          'sha256': sha256.convert(image).toString(),
          'byteCount': image.length,
          'width': 64,
          'height': 64,
        });
        (v['header'] as Map<String, Object?>).addAll({
          'rawWidth': 64,
          'rawHeight': 64,
          'uprightWidth': 64,
          'uprightHeight': 64,
        });
        return v;
      };
      const channel = MethodChannel('hk.pathguide/route_landmark');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cancel') return null;
        final f = Uint8List.fromList([1]);
        return {
          ...Map<String, Object?>.from(call.arguments as Map),
          'status': 'ok',
          'feature': f,
          'featureSha': sha256.convert(f).toString(),
          'text': <String>[],
          'ocrRevision': 3,
          'manualFloorConfirmationRequired': true,
        };
      });
      final c = RecordedRouteController(
        store: store,
        source: RouteObservationSource(supported: true),
      );
      Future<void> progress([bool Function()? done]) async {
        for (var i = 0; i < 200; i++) {
          await t.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          });
          await t.pump();
          if (done?.call() == true) break;
        }
      }

      await t.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: RouteJourneyPage(
            settings: AppSettings.memory(),
            initialRecording: true,
            createController: () async => c,
            previewBuilder: (_) => const SizedBox(),
          ),
        ),
      );
      await progress(() => find.text('開始錄路').evaluate().isNotEmpty);
      await t.scrollUntilVisible(
        find.text('開始錄路'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await t.ensureVisible(find.text('開始錄路'));
      await t.tap(find.text('開始錄路'));
      await progress(() => c.running);
      expect(c.automaticRecording, isTrue);
      await t.pump(const Duration(seconds: 5));
      await progress(() => c.nodes.isNotEmpty);
      expect(c.nodes.length, 1);
      expect(c.nodes.first.floor, isNull);
      expect(find.text('記錄路標'), findsNothing);
      final mark = find.byKey(const ValueKey('mark-stairs'));
      await t.ensureVisible(mark);
      await t.tap(mark);
      await progress(() => !c.busy && c.nodes.length == 2);
      expect(c.nodes.last.markType, 'stairs');
      await t.pump();
      expect(spoken.where((v) => v == '樓梯'), hasLength(1));
      expect(spoken.where((v) => v == '樓梯，已記錄'), hasLength(1));
      final undo = find.byKey(const ValueKey('undo-mark'));
      await t.ensureVisible(undo);
      await t.tap(undo);
      await t.pump();
      expect(c.nodes.length, 1);

      t.view.physicalSize = const Size(320, 568);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await t.pump();
      final more = find.byKey(const ValueKey('more-marks'));
      final capturesBeforeMenu = native.capturedResponse;
      Future<void> openMarks() async {
        await t.ensureVisible(more);
        await t.pumpAndSettle();
        await t.tap(more);
        await t.pumpAndSettle();
      }

      await openMarks();
      expect(find.byType(AlertDialog), findsOneWidget);
      await t.pump(const Duration(seconds: 6));
      expect(native.capturedResponse, same(capturesBeforeMenu));
      expect(c.nodes.length, 1);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(native.capturedResponse, same(capturesBeforeMenu));
      expect(t.widget<OutlinedButton>(more).focusNode!.hasPrimaryFocus, isTrue);

      final ramp = find.text('斜道');
      final rampButton = find.widgetWithText(OutlinedButton, '斜道');
      await openMarks();
      c.setForeground(false);
      await t.pumpAndSettle();
      expect(t.widget<OutlinedButton>(rampButton).onPressed, isNull);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(native.capturedResponse, same(capturesBeforeMenu));
      c.setForeground(true);
      await t.pumpAndSettle();
      await t.tap(find.text('繼續錄路'));
      await progress(() => c.running);

      await openMarks();
      await t.ensureVisible(ramp);
      await t.pumpAndSettle();
      final selectRamp = t.widget<OutlinedButton>(rampButton).onPressed!;
      await t.tap(ramp);
      selectRamp();
      await progress(() => !c.busy && c.nodes.length == 2);
      await t.pumpAndSettle();
      expect(c.nodes.last.markType, 'ramp');
      expect(c.nodes.last.floor, isNull);
      expect(spoken.where((v) => v == '斜道'), hasLength(1));
      expect(spoken.where((v) => v == '斜道，已記錄'), hasLength(1));
      expect(t.widget<OutlinedButton>(more).focusNode!.hasPrimaryFocus, isTrue);

      final door = find.byKey(const ValueKey('mark-door'));
      await t.ensureVisible(door);
      await t.pumpAndSettle();
      await t.tap(door);
      await progress(() => !c.busy && c.nodes.length == 3);
      final lastFrame = native.capturedResponse;
      await openMarks();
      final textNote = find.text('文字備註');
      await t.ensureVisible(textNote);
      await t.pumpAndSettle();
      await t.tap(textNote);
      await t.pumpAndSettle();
      final selected = find.text('1. 斜道 1');
      await t.ensureVisible(selected);
      await t.pumpAndSettle();
      await t.tap(selected);
      await t.pumpAndSettle();
      const note = '斜道旁有扶手。';
      await t.enterText(find.byType(TextFormField), note);
      await t.pump(const Duration(seconds: 6));
      final apply = find.text('套用備註');
      await t.ensureVisible(apply);
      await t.pumpAndSettle();
      await t.tap(apply);
      await t.pumpAndSettle();
      expect(native.capturedResponse, same(lastFrame));
      expect(c.nodes[1].textNote, note);
      expect(c.nodes.last.textNote, isNull);
      expect(t.widget<OutlinedButton>(more).focusNode!.hasPrimaryFocus, isTrue);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final wave = syntheticNoteWav();
      final audioCalls = <String>[];
      var denyMicrophone = true;
      messenger.setMockMethodCallHandler(RouteNoteAudio.channel, (call) async {
        audioCalls.add(call.method);
        if (call.method == 'start') {
          if (denyMicrophone) throw PlatformException(code: 'permission');
          return 10000;
        }
        if (call.method == 'finish') return wave;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(RouteNoteAudio.channel, null),
      );

      Future<void> openAudioEditor() async {
        await openMarks();
        final audio = find.text('錄音備註');
        await t.ensureVisible(audio);
        await t.pumpAndSettle();
        await t.tap(audio);
        await t.pumpAndSettle();
        await t.ensureVisible(selected);
        await t.pumpAndSettle();
        await t.tap(selected);
        await t.pumpAndSettle();
      }

      await openAudioEditor();
      expect(audioCalls, isEmpty);
      await t.tap(find.text('開始錄音'));
      await t.pumpAndSettle();
      expect(find.text('請在系統設定允許咪高峰。'), findsOneWidget);
      denyMicrophone = false;
      await t.tap(find.text('開始錄音'));
      await t.pumpAndSettle();
      expect(find.text('停止錄音'), findsOneWidget);
      await t.pump(const Duration(seconds: 10));
      await t.pumpAndSettle();
      expect(audioCalls.where((method) => method == 'finish'), hasLength(1));
      expect(c.nodes[1].audioNote, isNull);
      final preview = find.text('試聽錄音');
      await t.ensureVisible(preview);
      await t.pumpAndSettle();
      await t.tap(preview);
      await t.pumpAndSettle();
      expect(audioCalls.where((method) => method == 'play'), hasLength(1));
      await t.tap(find.text('套用錄音'));
      await t.pumpAndSettle();
      expect(c.nodes[1].audioNote?.bytes, orderedEquals(wave));
      expect(c.nodes[1].textNote, note);
      expect(native.capturedResponse, same(lastFrame));

      await openAudioEditor();
      final replace = find.text('重新錄音');
      await t.ensureVisible(replace);
      await t.pumpAndSettle();
      await t.tap(replace);
      await t.pumpAndSettle();
      final callsBeforeCancel = audioCalls.length;
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(audioCalls.skip(callsBeforeCancel), contains('cancel'));
      expect(audioCalls.where((method) => method == 'finish'), hasLength(1));
      expect(c.nodes[1].audioNote?.bytes, orderedEquals(wave));
      debugDefaultTargetPlatformOverride = null;
      expect(t.takeException(), isNull);
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
      t.platformDispatcher.clearTextScaleFactorTestValue();
      await t.pump();

      final finish = find.text('結束並保存');
      await t.scrollUntilVisible(
        finish,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await t.ensureVisible(finish);
      await t.tap(finish);
      await progress(() => c.notice == 'saved');
      expect(c.notice, 'saved');
      var reopened = false;
      c
          .showLibrary()
          .then((_) => c.open(c.entries.single, recording: true))
          .then((_) => reopened = true);
      await progress(() => reopened);
      expect(reopened, isTrue);
      expect(c.name, '路線 1');
      expect(c.nodes.length, 3);
      expect(c.nodes[1].markType, 'ramp');
      expect(c.nodes[1].textNote, note);
      expect(c.nodes[1].audioNote?.bytes, orderedEquals(wave));
      expect(c.document!.complete, isFalse);
      final edit = find.text('編輯文字備註');
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        edit.hitTestable(),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await t.ensureVisible(edit);
      await t.pumpAndSettle();
      await t.tap(edit);
      await t.pumpAndSettle();
      expect(find.text(note), findsOneWidget);
      await t.enterText(find.byType(TextFormField), '取消改動');
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(c.nodes[1].textNote, note);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
        await root.delete(recursive: true);
      });
      native.detach();
      messenger.setMockMethodCallHandler(channel, null);
    },
  );
  testWidgets('a failed first mark can be saved and viewed from the library', (
    t,
  ) async {
    final root = (await t.runAsync(
      () => Directory.systemTemp.createTemp('failed-mark-ui-'),
    ))!;
    addTearDown(() => root.delete(recursive: true));
    final store = (await t.runAsync(
      () => EncryptedRouteStore.open(root: root, vault: Vault()),
    ))!;
    final native = RouteNativeFixture()..attach();
    native.changeCapture = (reply) => {...reply, 'status': 'no_frame'};
    addTearDown(native.detach);
    t.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          accessibleNavigation: true,
          supportsAnnounce: true,
        );
    addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final announced = <String>[];
    messenger.setMockDecodedMessageHandler(SystemChannels.accessibility, (
      message,
    ) async {
      if (message is Map && message['type'] == 'announce') {
        announced.add((message['data'] as Map)['message'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockDecodedMessageHandler(
        SystemChannels.accessibility,
        null,
      ),
    );
    final c = RecordedRouteController(
      store: store,
      source: RouteObservationSource(supported: true),
    );

    Future<void> progress(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump();
      }
      await t.pumpAndSettle();
      expect(done(), isTrue);
    }

    await t.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: RouteJourneyPage(
          settings: AppSettings.memory(),
          initialRecording: true,
          createController: () async => c,
          previewBuilder: (_) => const SizedBox(),
        ),
      ),
    );
    final start = find.text('開始錄路');
    await progress(() => start.evaluate().isNotEmpty);
    await t.ensureVisible(start);
    await t.tap(start);
    await progress(() => c.running);
    final mark = find.byKey(const ValueKey('mark-left'));
    await t.ensureVisible(mark);
    await t.tap(mark);
    await progress(() => c.notice == 'markFailed');
    expect(
      announced.where((message) => message == '未能記錄，可在原處再試'),
      hasLength(1),
    );
    expect(announced, isNot(contains('左轉，已記錄')));
    expect(c.nodes, isEmpty);
    final finish = find.text('結束並保存');
    await t.tap(finish);
    await progress(() => c.notice == 'saved');

    await t.tap(find.byTooltip('返回'));
    final open = find.text('開啟路線');
    await progress(() => open.evaluate().isNotEmpty);
    await t.ensureVisible(open);
    await t.tap(open);
    await progress(() => c.mode == RecordedRouteMode.replay && !c.busy);
    expect(find.text('開始重行'), findsNothing);
    final history = find.text('標記失敗紀錄（1）');
    await t.ensureVisible(history);
    await t.tap(history);
    await t.pumpAndSettle();
    expect(find.text('左轉'), findsOneWidget);
    expect(find.textContaining('取相或分析未完成'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'landmark dialog submits typed floor and closes safely while capture is pending',
    (t) async {
      final root = (await t.runAsync(
        () => Directory.systemTemp.createTemp('route-dialog-'),
      ))!;
      final store = (await t.runAsync(
        () => EncryptedRouteStore.open(root: root, vault: Vault()),
      ))!;
      final native = RouteNativeFixture()..delayCapture = true;
      native.attach();
      const channel = MethodChannel('hk.pathguide/route_landmark');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cancel') return null;
        final feature = Uint8List.fromList([1]);
        return {
          ...Map<String, Object?>.from(call.arguments as Map),
          'status': 'ok',
          'feature': feature,
          'featureSha': sha256.convert(feature).toString(),
          'text': <String>[],
          'ocrRevision': 3,
          'manualFloorConfirmationRequired': true,
        };
      });
      final c = RecordedRouteController(
        store: store,
        source: RouteObservationSource(supported: true),
      );
      var previewMounts = 0;
      await c.startRecording('test route');
      await t.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: RouteJourneyPage(
            settings: AppSettings.memory(),
            createController: () async => c,
            previewBuilder: (_) =>
                PreviewLifetime(onMount: () => previewMounts++),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await t.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await t.pump();
      }
      await t.scrollUntilVisible(
        find.text('記錄下一個路標'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.text('記錄下一個路標'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(0), '門口');
      await t.enterText(find.byType(TextField).at(1), '1');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await t.pump();
      expect(
        c.running,
        isTrue,
        reason: 'System input inactivity is not app background',
      );
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      native.sendEvent('paused');
      await t.pumpAndSettle();
      expect(c.running, isFalse);
      expect(find.text('門口'), findsOneWidget);
      await t.tap(find.text('拍攝並加入'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 250));
      expect(t.takeException(), isNull);
      expect(
        previewMounts,
        1,
        reason: 'Busy indicator must not replace the native camera preview',
      );
      native.sendEvent('paused');
      await t.pumpAndSettle();
      expect(c.nodes, isEmpty);
      expect(find.text('相片尚未加入，已保留輸入：門口'), findsOneWidget);
      native.captureReply!.complete(native.capturedResponse);
      native.delayCapture = false;
      await t.scrollUntilVisible(
        find.text('重試剛才路標'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await t.ensureVisible(find.text('重試剛才路標'));
      await t.tap(find.text('重試剛才路標'));
      for (var i = 0; i < 10; i++) {
        await t.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await t.pump();
      }
      expect(c.nodes.length, 1);
      expect(c.busy, isFalse);
      Future<void> complete(Future<void> task) async {
        var done = false;
        task.whenComplete(() => done = true);
        for (var i = 0; i < 300 && !done; i++) {
          await t.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          });
          await t.pump();
        }
        expect(done, isTrue);
      }

      await complete(c.pause());
      await t.pump();
      await complete(c.resume());
      await t.pump();
      expect(
        previewMounts,
        1,
        reason: 'Pause/resume must reuse the same native preview',
      );
      native.delayCapture = false;
      await complete(c.recordLandmark('下一點', '1', confirmed: true));
      expect(c.nodes.length, 2);
      await complete(c.save(activate: false));
      expect(c.notice, 'saved');
      expect(c.dirty, isFalse);
      await complete(c.showLibrary());
      final saved = c.entries.single;
      await complete(c.open(saved, recording: true));
      expect(c.nodes.length, 2);
      expect(c.running, isFalse);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
        await root.delete(recursive: true);
      });
      native.detach();
      messenger.setMockMethodCallHandler(channel, null);
    },
  );
  for (final useReader in [true, false]) {
    testWidgets(
      'replay confirms a junction and reads its note only on request (reader: $useReader)',
      (t) async {
        final language = useReader ? AppLanguage.chinese : AppLanguage.english;
        String label(String zh, String en) => useReader ? zh : en;
        final note = label('轉角有接待處。', 'Reception is by the corner.');
        final wave = RouteAudioNote.fromBytes(syntheticNoteWav());
        if (useReader) {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
        }
        t.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(
              accessibleNavigation: useReader,
              supportsAnnounce: useReader,
            );
        addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
        t.view.physicalSize = const Size(320, 568);
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final native = RouteNativeFixture()..attach();
        const landmark = MethodChannel('hk.pathguide/route_landmark');
        const speech = MethodChannel('flutter_tts');
        final announced = <String>[], spoken = <String>[];
        final audioCalls = <String>[];
        Completer<void>? playback;
        messenger.setMockMethodCallHandler(RouteNoteAudio.channel, (
          call,
        ) async {
          audioCalls.add(call.method);
          if (call.method == 'play') {
            expect((call.arguments as Map)['bytes'], orderedEquals(wave.bytes));
            playback = Completer<void>();
            await playback!.future;
          }
          if (call.method == 'cancel') playback?.complete();
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(RouteNoteAudio.channel, null),
        );
        var speechStops = 0;
        messenger.setMockDecodedMessageHandler(SystemChannels.accessibility, (
          message,
        ) async {
          if (message is Map && message['type'] == 'announce') {
            announced.add((message['data'] as Map)['message'] as String);
          }
          return null;
        });
        messenger.setMockMethodCallHandler(speech, (call) async {
          if (call.method == 'getLanguages') return ['en-HK'];
          if (call.method == 'speak') spoken.add(call.arguments as String);
          if (call.method == 'stop') speechStops++;
          return 1;
        });
        messenger.setMockMethodCallHandler(landmark, (call) async {
          if (call.method == 'cancel') return null;
          final args = Map<String, Object?>.from(call.arguments as Map);
          final feature = Uint8List.fromList([1]);
          return {
            ...args,
            'status': 'ok',
            if (call.method == 'compare')
              'distances': [0.0, 20.0]
            else ...{
              'feature': feature,
              'featureSha': sha256.convert(feature).toString(),
              'text': <String>[],
              'ocrRevision': 3,
              'manualFloorConfirmationRequired': true,
            },
          };
        });
        addTearDown(() {
          native.detach();
          messenger.setMockMethodCallHandler(landmark, null);
          messenger.setMockMethodCallHandler(speech, null);
          messenger.setMockDecodedMessageHandler(
            SystemChannels.accessibility,
            null,
          );
        });
        late RecordedRouteController c;
        await t.runAsync(() async {
          final root = await Directory.systemTemp.createTemp(
            'direction-replay-ui-',
          );
          addTearDown(() => root.delete(recursive: true));
          final store = await EncryptedRouteStore.open(
            root: root,
            vault: Vault(),
          );
          final map = capturedDocument().toMap();
          final points = map['nodes'] as List<Map<String, Object?>>;
          map['schemaVersion'] = useReader ? 8 : 7;
          for (final point in points) {
            point['floorEvidence'] = 'confirmed';
          }
          points.first.addAll({
            'zh': '左轉 1',
            'en': 'Turn left 1',
            'markType': 'junction',
            'markDirection': 'left',
            'textNote': note,
            if (useReader) 'audioNote': wave.encoded,
          });
          points.last.addAll({
            'zh': '東面路口',
            'en': 'East junction',
            'markType': 'junction',
            'markDirection': 'right',
          });
          final doc = RouteDocument.fromMap(map);
          await store.save(
            doc,
            token: store.capture(doc.id),
            expectedRevision: 0,
            activate: true,
            media: capturedMedia(),
          );
          c = RecordedRouteController(
            store: store,
            source: RouteObservationSource(supported: true),
          );
          await c.open((await store.list()).routes.single);
        });

        Future<void> reveal(Finder finder, {double delta = 100}) async {
          await t.scrollUntilVisible(
            finder,
            delta,
            scrollable: find.byType(Scrollable).first,
          );
          await t.ensureVisible(finder);
          await t.pumpAndSettle();
        }

        await t.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: RouteJourneyPage(
              settings: AppSettings.memory(language: language),
              createController: () async => c,
              previewBuilder: (_) => const SizedBox(),
            ),
          ),
        );
        for (
          var i = 0;
          i < 200 && find.byType(Scrollable).evaluate().isEmpty;
          i++
        ) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump();
        }
        await t.tap(find.text(label('開始重行', 'Start replay')));
        await t.pumpAndSettle();
        final message = label(
          '已確認路口。錄製路線在這裡左轉。',
          'Junction confirmed. The recorded route turns left here.',
        );
        final floor = find.byType(TextField);
        final confirm = find.text(
          label('拍攝並確認此路標', 'Capture and confirm landmark'),
        );
        final readNote = find.text(label('讀出文字備註', 'Read text note'));
        final playNote = find.text('播放錄音備註');
        expect(readNote, findsNothing);
        expect(playNote, findsNothing);
        expect(find.text(note), findsNothing);
        await reveal(find.byType(DropdownButtonFormField<String>));
        expect(find.text(label('路口 1', 'Junction 1')), findsOneWidget);
        expect(find.text(label('左轉 1', 'Turn left 1')), findsNothing);
        final selector = t.widget<DropdownButton<String>>(
          find.byType(DropdownButton<String>),
        );
        expect(
          (selector.items!.last.child as Text).data,
          label('東面路口', 'East junction'),
        );

        await reveal(floor);
        await t.enterText(floor, 'G');
        await reveal(confirm);
        await t.tap(confirm);
        await t.pumpAndSettle();
        expect(c.notice, 'wrongDirection');
        expect(readNote, findsNothing);
        expect(announced, isEmpty);
        expect(spoken, isEmpty);

        await reveal(floor, delta: -100);
        await t.enterText(floor, 'G');
        final attestation = find.byType(CheckboxListTile);
        await reveal(attestation);
        await t.tap(attestation);
        await reveal(confirm);
        await t.tap(confirm);
        await t.pumpAndSettle();
        expect(c.replayDirection, 'left');
        await reveal(find.text(message), delta: -100);
        expect(find.text(message), findsOneWidget);
        expect(announced, useReader ? [message] : isEmpty);
        expect(spoken, useReader ? isEmpty : [message]);
        expect(find.text(note), findsNothing);
        await reveal(readNote);
        await t.tap(readNote);
        await t.pumpAndSettle();
        expect(find.text(note), findsOneWidget);
        expect(announced, useReader ? [message, note] : isEmpty);
        expect(spoken, useReader ? isEmpty : [message, note]);
        expect(audioCalls, isEmpty);
        if (useReader) {
          await reveal(playNote);
          await t.tap(playNote);
          await t.pumpAndSettle();
          expect(audioCalls, ['play']);
          expect(find.text('停止播放備註'), findsOneWidget);
          expect(find.text(note), findsNothing);
        }
        if (!useReader) {
          await t.runAsync(() => Future<void>.delayed(RouteLocalizer.validity));
          await t.pump(const Duration(seconds: 1));
          expect(c.confirmedReplayMark, isNull);
          expect(find.text(note), findsOneWidget);
          final repeat = find.text('Read note again');
          await reveal(repeat);
          await t.tap(repeat);
          await t.pumpAndSettle();
          expect(spoken, [message, note, note]);
          final close = find.text('Close note');
          await reveal(close);
          await t.tap(close);
          await t.pumpAndSettle();
          expect(find.text(note), findsNothing);
          expect(readNote, findsNothing);
        }
        final stopsBeforePause = speechStops;
        await t.tap(find.text(label('暫停', 'Pause')));
        await t.pumpAndSettle();
        expect(find.text(message), findsNothing);
        expect(find.text(note), findsNothing);
        expect(speechStops, stopsBeforePause);
        expect(audioCalls, useReader ? ['play', 'cancel'] : isEmpty);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        if (useReader) debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('corrupt captured route never advertises replay availability', (
    t,
  ) async {
    late Directory root;
    late EncryptedRouteStore store;
    await t.runAsync(() async {
      root = await Directory.systemTemp.createTemp('corrupt-route-ui-');
      store = await EncryptedRouteStore.open(root: root, vault: Vault());
      final doc = capturedDocument();
      await store.save(
        doc,
        token: store.capture(doc.id),
        expectedRevision: 0,
        activate: true,
        media: capturedMedia(),
      );
      final files = await root
          .list(recursive: true)
          .where(
            (f) =>
                f is File &&
                f.path.endsWith('.enc') &&
                !f.path.endsWith('/catalog.enc'),
          )
          .toList();
      await File(files.first.path).writeAsBytes([1]);
    });
    final native = RouteNativeFixture()..attach();
    final c = RecordedRouteController(
      store: store,
      source: RouteObservationSource(supported: true),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: RouteJourneyPage(
          settings: AppSettings.memory(language: AppLanguage.english),
          createController: () async => c,
        ),
      ),
    );
    for (var i = 0; i < 100; i++) {
      await t.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await t.pump();
    }
    await t.pumpAndSettle();
    expect(
      find.byType(Scrollable),
      findsWidgets,
      reason:
          'controller busy=${c.busy} notice=${c.notice} entries=${c.entries.length}',
    );
    await t.scrollUntilVisible(
      find.text('Data unverified; replay unavailable'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Replay version available'), findsNothing);
    expect(find.text('Unverified data'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      await root.delete(recursive: true);
    });
    native.detach();
  });
  for (final language in AppLanguage.values) {
    testWidgets(
      '${language.name} hub has three clear actions at double text size',
      (t) async {
        t.view.physicalSize = const Size(320, 568);
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        var search = 0, library = 0, record = 0;
        await t.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: NavigationHubPage(
                settings: AppSettings.memory(language: language),
                onSearch: () => search++,
                onLibrary: () => library++,
                onRecord: () => record++,
                onBack: () {},
              ),
            ),
          ),
        );
        for (final label
            in language == AppLanguage.chinese
                ? ['搜尋目的地', '我的路線', '錄製新路線']
                : ['Search destination', 'My routes', 'Record new route']) {
          await t.scrollUntilVisible(
            find.text(label),
            150,
            scrollable: find.byType(Scrollable).first,
          );
          await t.ensureVisible(find.text(label));
          await t.pumpAndSettle();
          await t.tap(find.text(label));
        }
        expect([search, library, record], [1, 1, 1]);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
    testWidgets(
      '${language.name} empty library and record form never auto-start camera',
      (t) async {
        final root = (await t.runAsync(
          () => Directory.systemTemp.createTemp('journey-ui-'),
        ))!;
        final native = RouteNativeFixture()..attach();
        final store = (await t.runAsync(
          () => EncryptedRouteStore.open(root: root, vault: Vault()),
        ))!;
        final c = RecordedRouteController(
          store: store,
          source: RouteObservationSource(supported: true),
        );
        t.view.physicalSize = const Size(320, 568);
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        await t.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: RouteJourneyPage(
              settings: AppSettings.memory(language: language),
              createController: () async => c,
            ),
          ),
        );
        // Real encrypted file IO is outside the widget fake clock.
        for (var i = 0; i < 15; i++) {
          await t.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          });
          await t.pump();
        }
        await t.pumpAndSettle();
        expect(c.running, isFalse);
        final label = language == AppLanguage.chinese
            ? '錄製新路線'
            : 'Record new route';
        await t.scrollUntilVisible(
          find.text(label),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await t.ensureVisible(find.text(label));
        await t.tap(find.text(label));
        await t.pumpAndSettle();
        final start = language == AppLanguage.chinese
            ? '開始錄路'
            : 'Start recording';
        await t.scrollUntilVisible(
          find.text(start),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await t.ensureVisible(find.text(start));
        expect(c.running, isFalse);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() async {
          await Future<void>.delayed(Duration.zero);
        });
        native.detach();
        await t.runAsync(() => root.delete(recursive: true));
      },
    );
  }
}

class PreviewLifetime extends StatefulWidget {
  const PreviewLifetime({super.key, required this.onMount});
  final VoidCallback onMount;
  @override
  State<PreviewLifetime> createState() => _PreviewLifetimeState();
}

class _PreviewLifetimeState extends State<PreviewLifetime> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
