import 'dart:io';

import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/navigation/navigation_hub_page.dart';
import 'package:pathguide/route_memory/encrypted_route_store.dart';
import 'package:pathguide/route_memory/recorded_route_controller.dart';
import 'package:pathguide/route_memory/route_journey_page.dart';
import 'package:pathguide/route_memory/route_observation_source.dart';
import 'package:pathguide/route_memory/route_package.dart';
import 'package:pathguide/route_memory/cross_floor_contract.dart';
import 'package:pathguide/settings/app_settings.dart';
import 'package:pathguide/ui/app_theme.dart';

import 'route_record_replay_test.dart' show Vault;
import 'captured_route_store_test.dart' show capturedDocument, capturedMedia;
import 'route_camera_fixture.dart';

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
    'automatic entry needs no point form, finish names and reopens a real draft',
    (t) async {
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
      final finish = find.text('結束錄路並命名保存');
      await t.scrollUntilVisible(
        finish,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await t.ensureVisible(finish);
      await t.tap(finish);
      await progress(() => find.text('結束並保存草稿').evaluate().isNotEmpty);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '屋企到大堂');
      final save = find.widgetWithText(FilledButton, '保存草稿');
      await t.ensureVisible(save);
      await t.tap(save);
      await progress(() => c.notice == 'saved');
      expect(c.notice, 'saved');
      var reopened = false;
      c
          .showLibrary()
          .then((_) => c.open(c.entries.single, recording: true))
          .then((_) => reopened = true);
      await progress(() => reopened);
      expect(reopened, isTrue);
      expect(c.name, '屋企到大堂');
      expect(c.nodes.length, 1);
      expect(c.document!.complete, isFalse);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
        await root.delete(recursive: true);
      });
      native.detach();
      messenger.setMockMethodCallHandler(channel, null);
    },
  );
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
