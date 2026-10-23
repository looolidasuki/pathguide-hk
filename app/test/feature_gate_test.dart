// `FeatureGate` 的門禁測試：**放行條件只有一個**（登入 ＋ 有網）。
//
// 斷言三件事：
// 1. 訪客一律不能用雲能力，而且提示必須說出「怎麼解鎖」（含「登入」）；
// 2. 已登入但離線也不能用，而且提示必須說出缺的是什麼（含「網絡」）；
// 3. 兩者都成立時四項雲能力全開 —— 否則門禁就變成「永遠關著」。
//
// 第 1、2 點不只斷言 `isFalse`：只斷言「不能用」的話，把提示寫成「無權限」
// 也會綠，但使用者聽到「無權限」不知道下一步要做什麼。

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/api/feature_gate.dart';
import 'package:pathguide/l10n/app_locale.dart';
import 'package:pathguide/l10n/app_strings.dart';

void main() {
  setUp(() => AppLocale.current = AppLanguage.zh);

  test('★ 訪客一律不允許雲能力，且提示要說出「怎麼解鎖」', () {
    const gate = FeatureGate(state: SessionState.guest, isOnline: true);
    for (final c in CloudCapability.values) {
      expect(gate.allows(c), isFalse, reason: '$c 不該對訪客開放');
      final msg = gate.denialMessage(c);
      expect(msg, isNotEmpty);
      expect(msg, contains('登入'), reason: '提示必須告訴使用者怎麼解鎖');
    }
  });

  test('★ 已登入但離線：仍不允許（雲能力本來就需要網）', () {
    const gate = FeatureGate(state: SessionState.authenticated, isOnline: false);
    expect(gate.allows(CloudCapability.uploadFrames), isFalse);
    expect(
      gate.denialMessage(CloudCapability.uploadFrames),
      contains('網絡'),
    );
  });

  test('已登入且有網：全部允許', () {
    const gate = FeatureGate(state: SessionState.authenticated, isOnline: true);
    for (final c in CloudCapability.values) {
      expect(gate.allows(c), isTrue, reason: '$c 對已登入且有網的使用者應開放');
    }
  });

  test('英文包的提示同樣說出解鎖方式（Sign in）與缺網絡（network）', () {
    AppLocale.current = AppLanguage.en;
    addTearDown(() => AppLocale.current = AppLanguage.zh);

    const guestGate = FeatureGate(state: SessionState.guest, isOnline: true);
    final guestMsg = guestGate.denialMessage(CloudCapability.visionQuery);
    expect(guestMsg.toLowerCase(), contains('sign in'));

    const offlineGate =
        FeatureGate(state: SessionState.authenticated, isOnline: false);
    final offlineMsg = offlineGate.denialMessage(CloudCapability.visionQuery);
    expect(offlineMsg.toLowerCase(), contains('network'));
  });

  test('提示與文案來自同一份 AppStrings，不是硬寫在門禁裡', () {
    const gate = FeatureGate(state: SessionState.guest, isOnline: false);
    expect(
      gate.denialMessage(CloudCapability.planRoute),
      AppStrings.of(AppLanguage.zh).deniedNeedsLogin,
    );
  });
}
