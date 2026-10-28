import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account_controller.dart';
import 'account_models.dart';

class DisabledAccountAuth implements AccountAuth {
  const DisabledAccountAuth([
    this.configurationMessage =
        'Google 登入尚未配置。請由組員提供 Firebase 手機端設定；基本辨識仍可直接使用。',
  ]);
  @override
  final String configurationMessage;
  @override
  bool get configured => false;
  @override
  AccountIdentity? get current => null;
  @override
  Stream<AccountIdentity?> get changes => const Stream.empty();
  Never _unavailable() =>
      throw AccountFailure('not-configured', configurationMessage);
  @override
  Future<AccountIdentity> signInGoogle() async => _unavailable();
  @override
  Future<void> reauthenticateGoogle() async => _unavailable();
  @override
  Future<void> signOut() async {}
  @override
  Future<void> deleteUser() async => _unavailable();
}

class DisabledAccountRepository implements AccountRepository {
  Never _unavailable() =>
      throw const AccountFailure('not-configured', 'Firebase 尚未配置。');
  @override
  Future<void> ensureAccount(String uid, {required bool acceptTerms}) async =>
      _unavailable();
  @override
  Future<EmergencyContact?> readContact(String uid) async => _unavailable();
  @override
  Future<void> saveContact(String uid, EmergencyContact contact) async =>
      _unavailable();
  @override
  Future<void> deleteContact(String uid) async => _unavailable();
  @override
  Future<void> deletePhase3Data(String uid) async => _unavailable();
}

class EmptyContactCache implements ContactCache {
  @override
  Future<EmergencyContact?> read(String uid) async => null;
  @override
  Future<void> write(String uid, EmergencyContact contact) async {}
  @override
  Future<void> clear() async {}
}

class SystemContactDialer implements ContactDialer {
  @override
  Future<bool> dial(EmergencyContact contact) => launchUrl(
    Uri(
      scheme: 'tel',
      path: EmergencyContact.validated(
        contact.name,
        contact.phone,
        contact.relationship,
      ).phone,
    ),
    mode: LaunchMode.externalApplication,
  );
}

AccountController unconfiguredAccounts([String? message]) => AccountController(
  auth: message == null
      ? const DisabledAccountAuth()
      : DisabledAccountAuth(message),
  repository: DisabledAccountRepository(),
  cache: EmptyContactCache(),
  dialer: SystemContactDialer(),
);

/// Serialize secure-storage operations so Logout clears any earlier in-flight write.
class SecureContactCache implements ContactCache {
  SecureContactCache({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
              synchronizable: false,
            ),
          );
  static const key = 'pathguide.emergency_contact.v1';
  final FlutterSecureStorage _storage;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  Future<EmergencyContact?> read(String uid) => _serial(() async {
    final raw = await _storage.read(key: key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['ownerUid'] != uid || json['schemaVersion'] != 1) {
        await _storage.delete(key: key);
        return null;
      }
      return EmergencyContact.fromJson(json['contact'] as Map<String, dynamic>);
    } catch (_) {
      await _storage.delete(key: key);
      return null;
    }
  });
  @override
  Future<void> write(String uid, EmergencyContact contact) => _serial(
    () => _storage.write(
      key: key,
      value: jsonEncode({
        'schemaVersion': 1,
        'ownerUid': uid,
        'contact': contact.toJson(),
      }),
    ),
  );
  @override
  Future<void> clear() => _serial(() => _storage.delete(key: key));
}

class FirebaseGoogleAuth implements AccountAuth {
  FirebaseGoogleAuth(this.firebase, this.google);
  final FirebaseAuth firebase;
  final GoogleSignIn google;
  @override
  bool get configured => true;
  @override
  String get configurationMessage => '';
  AccountIdentity? _identity(User? user) => user == null
      ? null
      : AccountIdentity(
          uid: user.uid,
          name: user.displayName,
          email: user.email,
        );
  @override
  AccountIdentity? get current => _identity(firebase.currentUser);
  @override
  Stream<AccountIdentity?> get changes =>
      firebase.authStateChanges().map(_identity);
  Future<OAuthCredential> _credential() async {
    try {
      final account = await google.authenticate();
      final token = account.authentication.idToken;
      if (token == null) {
        throw const AccountFailure('missing-token', 'Google 未提供登入憑證，請重新嘗試。');
      }
      return GoogleAuthProvider.credential(idToken: token);
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const AccountFailure('cancelled', '已取消 Google 登入，可繼續使用基本辨識。');
      }
      throw const AccountFailure(
        'google-unavailable',
        '未能開啟 Google 登入，請檢查網絡及專案設定。',
      );
    }
  }

  @override
  Future<AccountIdentity> signInGoogle() async {
    try {
      final credential = await _credential();
      final result = await firebase.signInWithCredential(credential);
      final user = _identity(result.user);
      if (user == null) {
        throw const AccountFailure('missing-user', '未能取得帳號，請重試。');
      }
      return user;
    } on FirebaseAuthException {
      throw const AccountFailure('auth-failed', 'Google 驗證未完成，請檢查網絡及登入設定後重試。');
    }
  }

  @override
  Future<void> reauthenticateGoogle() async {
    final user = firebase.currentUser;
    if (user == null) throw const AccountFailure('signed-out', '請先登入。');
    try {
      await user.reauthenticateWithCredential(await _credential());
      await user.getIdToken(true);
    } on FirebaseAuthException {
      throw const AccountFailure(
        'reauthentication-failed',
        '請選擇目前同一個 Google 帳號完成重新驗證。',
      );
    }
  }

  @override
  Future<void> signOut() async {
    await firebase.signOut();
    // A Google SDK sign-out failure must not keep the Firebase session alive.
    try {
      await google.signOut();
    } catch (_) {}
  }

  @override
  Future<void> deleteUser() async {
    final user = firebase.currentUser;
    if (user == null) throw const AccountFailure('signed-out', '請先登入。');
    try {
      await user.delete();
    } on FirebaseAuthException {
      throw const AccountFailure(
        'deletion-pending',
        '聯絡資料已移除，帳號刪除未完成。請重新驗證後重試刪除。',
      );
    }
    try {
      await google.signOut();
    } catch (_) {}
  }
}

class FirestoreAccountRepository implements AccountRepository {
  FirestoreAccountRepository(this.db);
  final FirebaseFirestore db;
  DocumentReference<Map<String, dynamic>> _user(String uid) =>
      db.collection('users').doc(uid);
  DocumentReference<Map<String, dynamic>> _contact(String uid) =>
      _user(uid).collection('private').doc('emergencyContact');
  DocumentReference<Map<String, dynamic>> _guard(String uid) =>
      db.collection('account_deletions').doc(uid);

  @override
  Future<void> ensureAccount(
    String uid, {
    required bool acceptTerms,
  }) => db.runTransaction((tx) async {
    final guard = await tx.get(_guard(uid));
    final user = await tx.get(_user(uid));
    if (guard.exists || user.data()?['status'] == 'deleting') {
      throw const AccountFailure('account-deleting', '帳號刪除待完成，請重試刪除或登出。');
    }
    if (!user.exists) {
      if (!acceptTerms) {
        throw const AccountFailure('setup-required', '帳號已驗證，請同意用途說明後完成帳號設定。');
      }
      tx.set(_user(uid), {
        'schemaVersion': 1,
        'status': 'active',
        'termsVersion': accountTermsVersion,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } else if (user.data()?['schemaVersion'] != 1 ||
        user.data()?['status'] != 'active') {
      throw const AccountFailure('unsupported-profile', '帳號資料暫時不相容，請聯絡組員核對。');
    }
  });
  @override
  Future<EmergencyContact?> readContact(String uid) async {
    final result = await _contact(uid)
        .get(const GetOptions(source: Source.server));
    return result.exists ? EmergencyContact.fromJson(result.data()!) : null;
  }

  Future<void> _changeContact(String uid, EmergencyContact? contact) =>
      db.runTransaction((tx) async {
        final user = await tx.get(_user(uid));
        final guard = await tx.get(_guard(uid));
        if (user.data()?['status'] != 'active' || guard.exists) {
          throw const AccountFailure('account-deleting', '帳號目前不可更改聯絡資料。');
        }
        if (contact == null) {
          tx.delete(_contact(uid));
        } else {
          tx.set(_contact(uid), {
            'schemaVersion': 1,
            'ownerUid': uid,
            ...contact.toJson(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
  @override
  Future<void> saveContact(String uid, EmergencyContact contact) =>
      _changeContact(uid, contact);
  @override
  Future<void> deleteContact(String uid) => _changeContact(uid, null);
  @override
  Future<void> deletePhase3Data(String uid) async {
    var hasPhotoConsent = false;
    try {
      hasPhotoConsent =
          (await _user(uid)
                  .collection('private')
                  .doc('photoConsent')
                  .get(const GetOptions(source: Source.server)))
              .exists;
    } on FirebaseException catch (e) {
      // Phase-3 rules deny this new path; do not break existing account deletion.
      if (e.code != 'permission-denied') rethrow;
    }
    if (const bool.fromEnvironment('PHOTO_UPLOAD_ENABLED') || hasPhotoConsent) {
      await FirebaseFunctions.instanceFor(region: 'asia-east2')
          .httpsCallable(
            'deletePhotoAccountData',
            options: HttpsCallableOptions(timeout: const Duration(minutes: 5)),
          )
          .call<void>({'expectedUid': uid});
      return;
    }
    await db.runTransaction((tx) async {
      final guard = await tx.get(_guard(uid));
      if (!guard.exists) {
        tx.set(_guard(uid), {
          'schemaVersion': 1,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
      tx.delete(_contact(uid));
      tx.delete(_user(uid));
    });
  }
}

/// Only public client settings are accepted. No Admin/service-account key belongs here.
Future<AccountController> configuredAccounts() async {
  const enabled = bool.fromEnvironment('FIREBASE_ENABLED');
  if (!enabled) return unconfiguredAccounts();
  if (kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.iOS &&
          defaultTargetPlatform != TargetPlatform.android)) {
    return unconfiguredAccounts('Google 登入本輪只配置 iPhone／Android；基本辨識仍可使用。');
  }
  const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  const appId = String.fromEnvironment('FIREBASE_APP_ID');
  const sender = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  const iosClient = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
  const webClient = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
  if ([apiKey, projectId, appId, sender].any((s) => s.isEmpty) ||
      (defaultTargetPlatform == TargetPlatform.iOS && iosClient.isEmpty) ||
      (defaultTargetPlatform == TargetPlatform.android && webClient.isEmpty)) {
    return unconfiguredAccounts('Firebase 手機端設定未完整；請核對設定檔，基本辨識仍可使用。');
  }
  try {
    final app = await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: apiKey,
        projectId: projectId,
        appId: appId,
        messagingSenderId: sender,
        iosClientId: iosClient,
        iosBundleId: String.fromEnvironment(
          'FIREBASE_IOS_BUNDLE_ID',
          defaultValue: 'hk.pathguide.pathguide',
        ),
      ),
    );
    await GoogleSignIn.instance.initialize(
      clientId: defaultTargetPlatform == TargetPlatform.iOS ? iosClient : null,
      serverClientId: webClient.isEmpty ? null : webClient,
    );
    final db = FirebaseFirestore.instanceFor(app: app);
    // Do not leave contact information in a shared Firestore disk cache.
    db.settings = const Settings(persistenceEnabled: false);
    return AccountController(
      auth: FirebaseGoogleAuth(
        FirebaseAuth.instanceFor(app: app),
        GoogleSignIn.instance,
      ),
      repository: FirestoreAccountRepository(db),
      cache: SecureContactCache(),
      dialer: SystemContactDialer(),
    );
  } catch (_) {
    return unconfiguredAccounts('Google 登入初始化失敗，請核對 Firebase 設定；基本辨識仍可使用。');
  }
}
