import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pathguide/account/account_models.dart';
import 'package:pathguide/account/firebase_accounts.dart';

import 'support/fake_accounts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AccountFixture f;
  setUp(() {
    f = AccountFixture();
    f.controller;
  });
  tearDown(() {
    f.controller.dispose();
  });
  Future<void> login() async {
    await accountTick();
    await f.controller.signIn(acceptTerms: true);
  }

  test('phone normalization preserves E164 and rejects dial URI injection', () {
    expect(
      EmergencyContact.validated('媽媽', '9123-4567', '').phone,
      '+85291234567',
    );
    expect(
      EmergencyContact.validated('家人', '+44 7700 900123', '').phone,
      '+447700900123',
    );
    for (final phone in ['tel:123', '91234567;123', '+852123', '+0012345678']) {
      expect(
        () => EmergencyContact.validated('家人', phone, ''),
        throwsA(isA<AccountFailure>()),
      );
    }
    expect(
      () => EmergencyContact.validated('', '91234567', ''),
      throwsA(isA<AccountFailure>()),
    );
  });
  test('guest stays signed out and sign-in requires agreement', () async {
    await accountTick();
    await f.controller.signIn(acceptTerms: false);
    expect(f.auth.signIns, 0);
    expect(f.controller.identity, isNull);
    expect(f.repository.profiles, isEmpty);
  });
  test('cancelled Google sign-in creates no profile', () async {
    f.auth.failure = const AccountFailure('cancelled', '已取消登入');
    await login();
    expect(f.controller.identity, isNull);
    expect(f.repository.profiles, isEmpty);
    expect(f.controller.busy, isFalse);
  });
  test('account initialization retries with the same UID', () async {
    f.repository.ensureError = StateError('network');
    await login();
    expect(f.controller.identity?.uid, 'alice');
    expect(f.controller.profileReady, isFalse);
    f.repository.ensureError = null;
    await f.controller.retryProfile(acceptTerms: true);
    await f.controller.retryProfile(acceptTerms: false);
    expect(f.controller.profileReady, isTrue);
    expect(f.repository.creates, 1);
    expect(f.controller.offerContactSetup, isFalse);
  });
  test('contact can be skipped, saved, changed and removed', () async {
    await login();
    expect(f.controller.offerContactSetup, isTrue);
    f.controller.skipContactSetup();
    expect(f.controller.offerContactSetup, isFalse);
    expect(await f.controller.saveContact(sampleContact), isTrue);
    expect(f.cache.uid, 'alice');
    expect(f.repository.contacts['alice']?.phone, '+85291234567');
    await f.controller.saveContact(
      EmergencyContact.validated('爸爸', '92345678', ''),
    );
    expect(f.controller.contact?.name, '爸爸');
    await f.controller.removeContact();
    expect(f.cache.contact, isNull);
    expect(f.repository.contacts, isEmpty);
  });
  test('sign-out clears contact and account information', () async {
    await login();
    await f.controller.saveContact(sampleContact);
    await f.controller.signOut();
    expect(f.controller.identity, isNull);
    expect(f.controller.contact, isNull);
    expect(f.cache.contact, isNull);
  });
  test(
    'old account delayed save cannot populate new account or cache',
    () async {
      await login();
      f.repository.profiles.add('bob');
      f.repository.saveWait = Completer<void>();
      final pending = f.controller.saveContact(sampleContact);
      f.auth.switchTo(bob);
      await accountTick();
      f.repository.saveWait!.complete();
      await pending;
      await accountTick();
      expect(f.controller.identity?.uid, 'bob');
      expect(f.controller.contact, isNull);
      expect(f.cache.contact, isNull);
      expect(f.repository.contacts['bob'], isNull);
    },
  );
  test(
    'restored same account can call secure cached contact when offline',
    () async {
      await accountTick();
      f.repository.profiles.add('alice');
      f.repository.readError = StateError('offline');
      await f.cache.write('alice', sampleContact);
      f.auth.switchTo(alice);
      await accountTick();
      await f.controller.callContact();
      expect(f.dialer.calls.single.phone, '+85291234567');
      expect(f.controller.message, contains('交由系統'));
      expect(f.controller.message, isNot(contains('成功求助')));
    },
  );
  test(
    'offline contact stays callable while profile refresh is pending',
    () async {
      await accountTick();
      await f.cache.write('alice', sampleContact);
      f.repository.ensureWait = Completer<void>();
      f.auth.switchTo(alice);
      await accountTick();
      expect(f.controller.busy, isTrue);
      expect(f.controller.canCallContact, isTrue);
      await f.controller.callContact();
      expect(f.dialer.calls.single.phone, '+85291234567');
      f.repository.ensureWait!.completeError(StateError('offline'));
      await accountTick();
      expect(f.controller.busy, isFalse);
    },
  );

  test('dialer failure is explicit', () async {
    await login();
    await f.controller.saveContact(sampleContact);
    f.dialer.available = false;
    await f.controller.callContact();
    expect(f.controller.message, contains('未能開啟撥號'));
  });
  test('cancelled reauthentication does not delete contact', () async {
    await login();
    await f.controller.saveContact(sampleContact);
    f.auth.failReauth = true;
    await f.controller.deleteAccount();
    expect(f.repository.guards, isEmpty);
    expect(f.controller.contact, isNotNull);
  });
  test('interrupted identity deletion leaves guard and is retryable', () async {
    await login();
    await f.controller.saveContact(sampleContact);
    f.auth.failDeletion = true;
    await f.controller.deleteAccount();
    expect(f.controller.deletionPending, isTrue);
    expect(f.controller.contact, isNull);
    expect(f.cache.contact, isNull);
    expect(f.repository.guards, contains('alice'));
    expect(f.repository.profiles, isEmpty);
    f.auth.failDeletion = false;
    await f.controller.deleteAccount();
    expect(f.controller.identity, isNull);
    expect(f.controller.deletionPending, isFalse);
  });
  test(
    'secure cache is owner scoped, validates data, and clears on logout',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final cache = SecureContactCache();
      await cache.write('alice', sampleContact);
      expect((await cache.read('alice'))?.name, '媽媽');
      expect(await cache.read('bob'), isNull);
      expect(await cache.read('alice'), isNull);
      await cache.write('alice', sampleContact);
      await cache.clear();
      expect(await cache.read('alice'), isNull);
    },
  );
}
