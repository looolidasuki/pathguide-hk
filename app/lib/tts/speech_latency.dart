import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// 即時辨識「畫面 → 開始發聲」延遲的量度（App 語音路線）。
///
/// 一次播報分三段：原生處理（前處理＋推理，取自幀事件）、Dart 收到幀至提交播報、
/// 提交播報至 TTS 引擎回報開始。TTS 的開始回呼早於揚聲器實際出聲（尚欠裝置
/// 音訊緩衝），讀屏路線沒有開始回呼，兩者都不在此量度內；相機取像至原生分析
/// 開始的時間亦未計入。結果只作工程比較，不能當作人耳聽到的起音。
class SpeechLatencyProbe {
  SpeechLatencyProbe({DateTime Function()? clock, this.reportEvery = 10})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final int reportEvery;
  final List<double> _totals = [];
  ({DateTime received, DateTime submitted, double nativeMs})? _pending;

  /// 本次累計的樣本數（只計有開始回呼的播報）。
  int get count => _totals.length;

  /// 這一幀已提交播報；[receivedAt] 為 Dart 收到幀的時間。
  void submitted({required DateTime receivedAt, required double nativeMs}) {
    _pending = (received: receivedAt, submitted: _clock(), nativeMs: nativeMs);
  }

  /// 播報被取消或改由讀屏送出時作廢，避免與下一次開始回呼錯配。
  void cancel() => _pending = null;

  /// TTS 回報開始發聲；回傳本次總延遲（毫秒），無待配對的提交則回傳 null。
  double? started() {
    final p = _pending;
    _pending = null;
    if (p == null) return null;
    final now = _clock();
    final total =
        p.nativeMs +
        p.submitted.difference(p.received).inMicroseconds / 1000 +
        now.difference(p.submitted).inMicroseconds / 1000;
    _totals.add(total);
    if (reportEvery > 0 && _totals.length % reportEvery == 0) {
      debugPrint('播報延遲 $summary');
    }
    return total;
  }

  /// 例：`n=20 p50=612ms p95=880ms`。
  String get summary {
    if (_totals.isEmpty) return 'n=0';
    return 'n=${_totals.length} p50=${percentile(0.5).round()}ms '
        'p95=${percentile(0.95).round()}ms';
  }

  /// 最近似排名法的百分位數（樣本少時偏保守）。
  double percentile(double q) {
    final sorted = [..._totals]..sort();
    final rank = math.max(1, (q * sorted.length).ceil());
    return sorted[rank - 1];
  }
}
