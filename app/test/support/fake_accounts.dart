import 'dart:async';

import 'package:pathguide/account/account_models.dart';
import 'package:pathguide/account/account_controller.dart';

const alice = AccountIdentity(
  uid: 'alice',
  name: '測試用戶',
  email: 'alice@example.test',
);
const bob = AccountIdentity(uid: 'bob', name: '另一用戶');
final sampleContact = EmergencyContact.validated('媽媽', '91234567', '家人');

class FakeAuth implements AccountAuth {
  final stream = StreamController<AccountIdentity?>.broadcast(sync: true);
  @override
  bool configured = true;
  @override
  String configurationMessage = '尚未配置 Google 登入';
  @override
  AccountIdentity? current;
  Object? failure;
  bool failReauth = false, failDeletion = false;
  int signIns = 0, deletions = 0;
  @override
  Stream<AccountIdentity?> get changes => stream.stream;
  void switchTo(AccountIdentity? user) {
    current = user;
    stream.add(user);
  }

  @override
  Future<AccountIdentity> signInGoogle() async {
    signIns++;
    if (failure != null) throw failure!;
    switchTo(alice);
    return alice;
  }

  @override
  Future<void> reauthenticateGoogle() async {
    if (failReauth) throw const AccountFailure('cancelled', '已取消驗證');
  }

  @override
  Future<void> signOut() async {
    switchTo(null);
  }

  @override
  Future<void> deleteUser() async {
    deletions++;
    if (failDeletion) {
      throw const AccountFailure('deletion-pending', '刪除未完成，請重試');
    }
    switchTo(null);
  }
}

class FakeRepository implements AccountRepository {
  final profiles = <String>{};
  final guards = <String>{};
  final contacts = <String, EmergencyContact>{};
  Object? ensureError, readError;
  Completer<void>? saveWait;
  Completer<void>? ensureWait;
  int creates = 0;
  @override
  Future<void> ensureAccount(String uid, {required bool acceptTerms}) async {
    await ensureWait?.future;
    if (guards.contains(uid)) {
      throw const AccountFailure('account-deleting', '帳號刪除待完成');
    }
    if (ensureError != null) throw ensureError!;
    if (!profiles.contains(uid)) {
      if (!acceptTerms) throw const AccountFailure('setup-required', '需要完成設定');
      profiles.add(uid);
      creates++;
    }
  }

  @override
  Future<EmergencyContact?> readContact(String uid) async {
    if (readError != null) throw readError!;
    return contacts[uid];
  }

  @override
  Future<void> saveContact(String uid, EmergencyContact contact) async {
    await saveWait?.future;
    contacts[uid] = contact;
  }

  @override
  Future<void> deleteContact(String uid) async {
    contacts.remove(uid);
  }

  @override
  Future<void> deletePhase3Data(String uid) async {
    guards.add(uid);
    contacts.remove(uid);
    profiles.remove(uid);
  }
}

class MemoryContactCache implements ContactCache {
  String? uid;
  EmergencyContact? contact;
  @override
  Future<EmergencyContact?> read(String uid) async =>
      this.uid == uid ? contact : null;
  @override
  Future<void> write(String uid, EmergencyContact contact) async {
    this.uid = uid;
    this.contact = contact;
  }

  @override
  Future<void> clear() async {
    uid = null;
    contact = null;
  }
}

class FakeDialer implements ContactDialer {
  bool available = true;
  final calls = <EmergencyContact>[];
  @override
  Future<bool> dial(EmergencyContact contact) async {
    calls.add(contact);
    return available;
  }
}

class AccountFixture {
  final auth = FakeAuth();
  final repository = FakeRepository();
  final cache = MemoryContactCache();
  final dialer = FakeDialer();
  late final controller = AccountController(
    auth: auth,
    repository: repository,
    cache: cache,
    dialer: dialer,
  );
}

Future<void> accountTick() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
