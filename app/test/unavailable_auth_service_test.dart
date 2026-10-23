import 'package:flutter_test/flutter_test.dart';

import 'package:pathguide/auth/auth_service.dart';
import 'package:pathguide/auth/unavailable_auth_service.dart';

/// 沒有後端時的登入服務（`UnavailableAuthService`）。
///
/// ## 這個檔案在釘什麼
///
/// **正式 App 不可以偽造一次登入。**
///
/// 這聽起來像廢話，但這正是它修掉的缺陷：正式入口以前接的是
/// `MockAuthService`，而它的預設結果是 `SignedIn` 帶一個假帳號
/// （`mock.user@pathguide.test`／`Mock User`）。於是使用者按一下「用 Google
/// 帳號登入」，App 就播報「登入成功」並返回，設定頁顯示「已登入」——
/// 而云端能力一個都不存在。
///
/// 對全盲使用者，那句話就是他對「我的資料有沒有送出」的唯一依據。
/// 所以這裡的每一條斷言都只問一件事：**它有沒有宣稱成功。**
void main() {
  group('UnavailableAuthService（沒有後端時唯一的誠實答案）', () {
    const svc = UnavailableAuthService();

    test('restore() 回 null：起點是訪客，不是已登入', () async {
      // 非 null 的話設定頁的帳號列就會寫「已登入」——一個純粹的謊言。
      expect(await svc.restore(), isNull);
    });

    test('availableProviders() 是空的：不畫按了也不會成功的登入方式', () async {
      // 帳號頁只畫 `availableProviders()` 裡有的方式，所以空集合等於
      // 「畫面上不會出現一顆按下去只會失敗的按鈕」。
      expect(await svc.availableProviders(), isEmpty);
    });

    test('★ signIn 對每一種方式都回 AuthFailed，絕不是 SignedIn', () async {
      for (final provider in AuthProvider.values) {
        final result = await svc.signIn(provider);
        expect(
          result,
          isA<AuthFailed>(),
          reason: '${provider.name}：沒有後端時不可以回報任何成功',
        );
        expect(
          result,
          isNot(isA<SignedIn>()),
          reason: '${provider.name}：SignedIn 會讓帳號頁播報「登入成功」',
        );
      }
    });

    test('★ 其他會產生登入狀態的方法也都不可能成功', () async {
      final results = <String, AuthResult>{
        'requestEmailCode': await svc.requestEmailCode('blind@pathguide.test'),
        'verifyEmailCode':
            await svc.verifyEmailCode('blind@pathguide.test', '123456'),
        'linkProvider': await svc.linkProvider(AuthProvider.google),
        'unlinkProvider': await svc.unlinkProvider(AuthProvider.google),
      };

      results.forEach((name, result) {
        expect(result, isA<AuthFailed>(), reason: '$name 必須是失敗');
        expect(result, isNot(isA<SignedIn>()), reason: '$name 不可以成功');
        // 也不可以說「這個信箱已經有帳號，要連結嗎」——那條路會把人繞回
        // `linkProvider`，最後還是只能失敗，卻先讓使用者以為有進展。
        expect(result, isNot(isA<NeedsLinking>()), reason: '$name 不可以誤導');
      });
    });

    test('signOut() 與 deleteAccount() 不拋例外（本來就沒有東西可做）', () async {
      // 帳號頁的「登出」是**按得到**的。這裡拋出去的話，使用者按下按鈕後
      // 一個聲音都沒有——那正是這一整條工作線在修的那類缺陷。
      await expectLater(svc.signOut(), completes);
      await expectLater(svc.deleteAccount(), completes);

      // 而且做完之後仍然是訪客：這兩個方法沒有任何副作用。
      expect(await svc.restore(), isNull);
      expect(await svc.availableProviders(), isEmpty);
    });
  });
}
