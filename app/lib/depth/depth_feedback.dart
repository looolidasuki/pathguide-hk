/// Product guidance, kept separate from sensor diagnostics and point counts.
String depthStatusText(String status, {required bool english}) {
  String t(String zh, String en) => english ? en : zh;
  return switch (status) {
    'idle' => t(
      '未開始測距。請站定、對準，再按開始。',
      'Measurement not started. Stand still, aim, then press Start.',
    ),
    'starting' || 'waiting' => t(
      '正在準備測距。可暫停或返回。',
      'Preparing measurement. You can pause or go back.',
    ),
    'ready' => t(
      '已取得中央表面估算距離。可重讀、暫停或返回。',
      'Estimated centre surface range available. You can read, pause or go back.',
    ),
    'objectsReady' => t(
      '已辨識到物件。距離未能確認時會保留未知，可重讀、暫停或返回。',
      'Objects recognized. Unconfirmed ranges remain unknown. You can read, pause or go back.',
    ),
    'noObjects' => t(
      '暫未辨識到支援的物件。可繼續觀察、重讀狀態或停止；不代表前方暢通。',
      'No supported objects recognized yet. Keep observing, read the status or stop; this does not establish clear space.',
    ),
    'model' => t(
      '目前無法載入辨識模型。可關閉物件模式再試準星測距，或返回。',
      'The recognition model is unavailable. Turn off object mode to try crosshair range, or go back.',
    ),
    'stabilizing' || 'moving' => t(
      '正在確認，請站定並保持對準。也可暫停或返回。',
      'Confirming the measurement. Stand still and keep aiming. You can also pause or go back.',
    ),
    'tracking' => t(
      '目前無法確認距離。可暫停後重新開始，或返回。',
      'Range cannot be confirmed. Pause and start again, or go back.',
    ),
    'permission' => t(
      '未有相機權限。可開啟系統設定允許相機，或返回。',
      'Camera permission is unavailable. Allow camera access in system settings, or go back.',
    ),
    'unsupported' => t(
      '此裝置不支援測距。請返回使用其他功能。',
      'This device does not support range measurement. Go back to use other features.',
    ),
    'paused' => t(
      '已暫停。可按開始重新量度，或返回。',
      'Paused. Press Start to measure again, or go back.',
    ),
    'interrupted' => t(
      '相機已中斷，舊結果已清除。可重新開始，或返回。',
      'Camera interrupted; previous results cleared. Start again, or go back.',
    ),
    'stale' => t(
      '結果已過期，正在重新取得。可暫停後重新開始，或返回。',
      'Results expired. Getting new observations. Pause and start again, or go back.',
    ),
    'failed' => t(
      '目前無法測距。可重新開始，或返回。',
      'Measurement is unavailable. Start again, or go back.',
    ),
    _ => t(
      '目前無法取得可靠距離。可暫停後重新開始，或返回。',
      'Reliable range is unavailable. Pause and start again, or go back.',
    ),
  };
}

String depthObjectGuidance(
  String reason, {
  required bool english,
}) => switch (reason) {
  'stabilizing' || 'sampling_changed' =>
    english
        ? 'Confirming the measurement. Stand still and keep aiming, or pause.'
        : '正在確認，請站定並保持對準，也可暫停。',
  'overlap' =>
    english
        ? 'Objects overlap in the image. Stand still and re-aim, or pause.'
        : '畫面中的物件重疊。可站定並重新對準，或暫停。',
  'small' =>
    english
        ? 'The object is too small in the image to measure. You can re-aim or pause.'
        : '物件在畫面中太小，暫時量不到。可重新對準或暫停。',
  'depth_missing' || 'depth_format' =>
    english
        ? 'Reliable range is unavailable. Pause and start again, or go back.'
        : '目前無法取得可靠距離。可暫停後重新開始，或返回。',
  _ =>
    english
        ? 'Range cannot be confirmed. Stand still and re-aim, or pause.'
        : '暫時量不到距離。可站定並重新對準，或暫停。',
};
