import 'dart:async';

import 'package:flutter/foundation.dart';

import 'account_models.dart';

class AccountController extends ChangeNotifier {
  AccountController({
    required this.auth,
    required this.repository,
    required this.cache,
    required this.dialer,
  }) {
    _subscription = auth.changes.listen(
      (user) {
        if (!_authAction) unawaited(_restore(user));
      },
      onError: (Object _) {
        if (!_disposed) {
          message = '未能同步登入狀態，基本辨識仍可使用。';
          notifyListeners();
        }
      },
    );
    unawaited(_restore(auth.current));
  }
  final AccountAuth auth;
  final AccountRepository repository;
  final ContactCache cache;
  final ContactDialer dialer;
  late final StreamSubscription<AccountIdentity?> _subscription;
  AccountIdentity? identity;
  EmergencyContact? contact;
  bool busy = false;
  bool profileReady = false;
  bool deletionPending = false;
  bool offerContactSetup = false;
  bool _initialized = false;
  bool _authAction = false;
  bool _dialing = false;
  bool _disposed = false;
  int _generation = 0;
  String? message;
  bool get configured => auth.configured;
  bool get canCallContact =>
      contact != null &&
      identity != null &&
      auth.current?.uid == identity?.uid &&
      !deletionPending &&
      !_authAction &&
      !_dialing;
  bool _valid(int generation, [String? uid]) =>
      !_disposed &&
      generation == _generation &&
      (uid == null || (identity?.uid == uid && auth.current?.uid == uid));
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _error(Object error) {
    if (error is AccountFailure) {
      message = error.message;
      if (error.code == 'account-deleting') deletionPending = true;
    } else {
      message = '暫時未能完成，請檢查網絡後重試；基本辨識仍可使用。';
    }
  }

  Future<void> _restore(AccountIdentity? user) async {
    if (_initialized && identity?.uid == user?.uid) return;
    _initialized = true;
    final generation = ++_generation;
    identity = user;
    contact = null;
    profileReady = false;
    deletionPending = false;
    offerContactSetup = false;
    busy = user != null;
    message = null;
    _notify();
    try {
      if (user == null) {
        await cache.clear();
        return;
      }
      final local = await cache.read(user.uid);
      if (!_valid(generation, user.uid)) return;
      contact = local;
      _notify();
      await _loadProfile(generation, user.uid, acceptTerms: false);
    } catch (error) {
      if (_valid(generation)) _error(error);
    } finally {
      if (_valid(generation)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> _loadProfile(
    int generation,
    String uid, {
    required bool acceptTerms,
  }) async {
    try {
      await repository
          .ensureAccount(uid, acceptTerms: acceptTerms)
          .timeout(const Duration(seconds: 12));
      if (!_valid(generation, uid)) return;
      profileReady = true;
      final remote = await repository
          .readContact(uid)
          .timeout(const Duration(seconds: 8));
      if (!_valid(generation, uid)) return;
      contact = remote;
      if (remote == null) {
        await cache.clear();
      } else {
        await cache.write(uid, remote);
      }
      if (_valid(generation, uid)) {
        offerContactSetup = acceptTerms && remote == null;
        message = '帳號已就緒；照片收集須另外配置及同意。';
      }
    } on AccountFailure catch (error) {
      if (error.code == 'account-deleting' && _valid(generation, uid)) {
        deletionPending = true;
        profileReady = false;
        contact = null;
        await cache.clear();
      }
      rethrow;
    }
  }

  Future<void> signIn({required bool acceptTerms}) async {
    if (busy) return;
    if (!configured) {
      message = auth.configurationMessage;
      _notify();
      return;
    }
    if (!acceptTerms) {
      message = '請先閱讀並同意帳號用途說明。';
      _notify();
      return;
    }
    final generation = ++_generation;
    busy = true;
    message = null;
    _authAction = true;
    _notify();
    try {
      final user = await auth.signInGoogle();
      if (!_valid(generation)) return;
      identity = user;
      contact = null;
      deletionPending = false;
      profileReady = false;
      await cache.clear();
      if (_valid(generation, user.uid)) {
        await _loadProfile(generation, user.uid, acceptTerms: true);
      }
    } catch (error) {
      if (_valid(generation)) _error(error);
    } finally {
      _authAction = false;
      if (_valid(generation)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> retryProfile({required bool acceptTerms}) async {
    final uid = identity?.uid;
    if (busy || uid == null) return;
    final generation = ++_generation;
    busy = true;
    message = null;
    _notify();
    try {
      await _loadProfile(generation, uid, acceptTerms: acceptTerms);
    } catch (error) {
      if (_valid(generation)) _error(error);
    } finally {
      if (_valid(generation)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<bool> saveContact(EmergencyContact next) async {
    final uid = identity?.uid;
    if (busy || uid == null || !profileReady || deletionPending) return false;
    final generation = ++_generation;
    busy = true;
    message = null;
    _notify();
    try {
      await repository.saveContact(uid, next);
      if (!_valid(generation, uid)) return false;
      await cache.write(uid, next);
      if (!_valid(generation, uid)) return false;
      contact = next;
      offerContactSetup = false;
      message = '緊急聯絡人已儲存。';
      return true;
    } catch (error) {
      if (_valid(generation)) _error(error);
      return false;
    } finally {
      if (_valid(generation)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> removeContact() async {
    final uid = identity?.uid;
    if (busy || uid == null || !profileReady || deletionPending) return;
    final generation = ++_generation;
    busy = true;
    _notify();
    try {
      await repository.deleteContact(uid);
      if (!_valid(generation, uid)) return;
      await cache.clear();
      if (_valid(generation, uid)) {
        contact = null;
        message = '緊急聯絡人已刪除。';
      }
    } catch (error) {
      if (_valid(generation)) _error(error);
    } finally {
      if (_valid(generation)) {
        busy = false;
        _notify();
      }
    }
  }

  void skipContactSetup() {
    offerContactSetup = false;
    _notify();
  }

  Future<void> callContact() async {
    final target = contact;
    final uid = identity?.uid;
    if (!canCallContact ||
        target == null ||
        uid == null ||
        deletionPending ||
        auth.current?.uid != uid) {
      return;
    }
    final generation = _generation;
    _dialing = true;
    _notify();
    try {
      final launched = await dialer.dial(target);
      if (_valid(generation, uid)) {
        message = launched ? '已交由系統處理撥號，請按系統提示操作。' : '未能開啟撥號，請使用電話 App 聯絡。';
        _notify();
      }
    } catch (_) {
      if (_valid(generation, uid)) {
        message = '未能開啟系統撥號。';
        _notify();
      }
    } finally {
      _dialing = false;
      _notify();
    }
  }

  Future<void> signOut() async {
    if (busy) return;
    final generation = ++_generation;
    busy = true;
    _authAction = true;
    contact = null;
    profileReady = false;
    offerContactSetup = false;
    _notify();
    try {
      var cacheCleared = true;
      try {
        await cache.clear();
      } catch (_) {
        cacheCleared = false;
      }
      await auth.signOut();
      if (_valid(generation)) {
        identity = null;
        deletionPending = false;
        message = cacheCleared
            ? '已登出，可繼續使用基本辨識。'
            : '已登出；本機安全資料清理未完成，請解鎖手機後重新開啟 App。';
      }
    } catch (error) {
      if (_valid(generation)) _error(error);
    } finally {
      _authAction = false;
      if (_valid(generation)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> deleteAccount() async {
    final uid = identity?.uid;
    if (busy || uid == null) return;
    final generation = ++_generation;
    busy = true;
    _authAction = true;
    message = null;
    _notify();
    try {
      await auth.reauthenticateGoogle();
      if (!_valid(generation, uid)) return;
      await repository.deletePhase3Data(uid);
      if (!_valid(generation, uid)) return;
      deletionPending = true;
      contact = null;
      profileReady = false;
      await cache.clear();
      await auth.deleteUser();
      if (_valid(generation)) {
        identity = null;
        deletionPending = false;
        message = '帳號及本階段的聯絡資料已刪除。';
      }
    } catch (error) {
      if (_valid(generation)) _error(error);
    } finally {
      _authAction = false;
      if (_valid(generation)) {
        busy = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
