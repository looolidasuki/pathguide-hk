import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'route_media.dart';
import 'route_platform_profile.dart';

class RouteNoteAudio {
  static const channel = MethodChannel('hk.pathguide/route_note_audio');
  static int _nextOwner = 0;

  /// iOS: RouteNoteAudioPlugin.swift; Android: RouteNoteAudioPlugin.kt.
  /// Android uses the real host OS (not defaultTargetPlatform, which is
  /// android in host tests) so widget tests keep their iOS expectations.
  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS || RoutePlatform.isAndroid);

  final _owner = 'route-note-${++_nextOwner}';
  Map<String, Object> get _args => {'owner': _owner};

  Future<int> start() async {
    final limit = await channel.invokeMethod<int>('start', _args);
    if (limit == null ||
        limit <= 0 ||
        limit > RouteMediaBounds.audioNoteSeconds * 1000) {
      throw StateError('Invalid recording limit');
    }
    return limit;
  }

  Future<RouteAudioNote> finish() async {
    final data = await channel
        .invokeMethod<Uint8List>('finish', _args)
        .timeout(const Duration(seconds: 3));
    if (data == null) throw StateError('Missing recording');
    return RouteAudioNote.fromBytes(data);
  }

  Future<void> play(RouteAudioNote note) => channel
      .invokeMethod<void>('play', {..._args, 'bytes': note.bytes})
      .timeout(const Duration(seconds: RouteMediaBounds.audioNoteSeconds + 3));

  Future<void> cancel() async {
    try {
      await channel
          .invokeMethod<void>('cancel', _args)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // App lifecycle and interruption handling also stop the native owner.
    }
  }
}

enum _AudioPhase { idle, preparing, recording, finishing, playing }

class RouteAudioNoteDialog extends StatefulWidget {
  const RouteAudioNoteDialog({
    super.key,
    required this.markName,
    required this.initial,
    required this.translate,
    required this.apply,
  });

  final String markName;
  final RouteAudioNote? initial;
  final String Function(String, String) translate;
  final bool Function(RouteAudioNote?) apply;

  @override
  State<RouteAudioNoteDialog> createState() => _RouteAudioNoteDialogState();
}

class _RouteAudioNoteDialogState extends State<RouteAudioNoteDialog>
    with WidgetsBindingObserver {
  final _audio = RouteNoteAudio();
  late RouteAudioNote? _clip = widget.initial;
  _AudioPhase _phase = _AudioPhase.idle;
  Timer? _limit;
  String? _message;
  int _epoch = 0;
  String t(String zh, String en) => widget.translate(zh, en);
  bool _current(int ticket) => mounted && ticket == _epoch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _halt() {
    _epoch++;
    _limit?.cancel();
    unawaited(_audio.cancel());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        _phase != _AudioPhase.idle) {
      _halt();
      setState(() {
        _phase = _AudioPhase.idle;
        _message = t('錄音或播放已中斷。', 'Recording or playback was interrupted.');
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _halt();
    super.dispose();
  }

  Future<void> _start() async {
    if (_phase != _AudioPhase.idle) return;
    final ticket = ++_epoch;
    setState(() {
      _message = null;
      _phase = _AudioPhase.preparing;
    });
    try {
      final limitMs = await _audio.start();
      if (!_current(ticket)) return;
      setState(() => _phase = _AudioPhase.recording);
      _limit = Timer(Duration(milliseconds: limitMs), _finish);
    } catch (error) {
      if (!_current(ticket)) return;
      _halt();
      setState(() {
        _phase = _AudioPhase.idle;
        _message = error is PlatformException && error.code == 'permission'
            ? t('請在系統設定允許咪高峰。', 'Allow microphone access in Settings.')
            : t('未能開始錄音，請再試。', 'Could not start recording. Try again.');
      });
    }
  }

  Future<void> _finish() async {
    if (_phase != _AudioPhase.recording) return;
    _limit?.cancel();
    final ticket = ++_epoch;
    setState(() => _phase = _AudioPhase.finishing);
    try {
      final clip = await _audio.finish();
      if (!_current(ticket)) return;
      setState(() {
        _clip = clip;
        _phase = _AudioPhase.idle;
        _message = t('錄音已準備，可以試聽或套用。', 'Recording ready to preview or apply.');
      });
    } catch (error) {
      if (!_current(ticket)) return;
      _halt();
      setState(() {
        _phase = _AudioPhase.idle;
        _message = error is PlatformException && error.code == 'too_short'
            ? t('錄音太短，請重錄。', 'Recording was too short. Try again.')
            : t('未能完成錄音，請重試。', 'Could not finish recording. Try again.');
      });
    }
  }

  Future<void> _preview() async {
    final clip = _clip;
    if (_phase != _AudioPhase.idle || clip == null) return;
    final ticket = ++_epoch;
    setState(() {
      _message = null;
      _phase = _AudioPhase.playing;
    });
    try {
      await _audio.play(clip);
    } catch (_) {
      if (!_current(ticket)) return;
      setState(() => _message = t('未能播放錄音。', 'Could not play recording.'));
      await _audio.cancel();
    } finally {
      if (_current(ticket)) setState(() => _phase = _AudioPhase.idle);
    }
  }

  void _apply() {
    if (_phase != _AudioPhase.idle || ModalRoute.isCurrentOf(context) != true) {
      return;
    }
    if (widget.apply(_clip)) {
      Navigator.pop(context);
    } else {
      setState(
        () => _message = t(
          '未能套用錄音，請檢查路線容量或重開標記。',
          'Could not apply recording. Check route capacity or reopen the mark.',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final idle = _phase == _AudioPhase.idle;
    final status =
        _message ??
        switch (_phase) {
          _AudioPhase.idle => t(
            '每段最長 10 秒。',
            'Up to 10 seconds per recording.',
          ),
          _AudioPhase.preparing => t('正在準備咪高峰。', 'Preparing the microphone.'),
          _AudioPhase.recording => t('錄音中。', 'Recording.'),
          _AudioPhase.finishing => t('正在結束錄音。', 'Finishing the recording.'),
          _AudioPhase.playing => t('正在播放錄音。', 'Playing recording.'),
        };
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _halt();
      },
      child: AlertDialog(
        scrollable: true,
        title: Text(t('錄音備註', 'Audio note')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.markName),
            Semantics(liveRegion: true, child: Text(status)),
            const SizedBox(height: 12),
            if (idle)
              FilledButton(
                onPressed: _start,
                child: Text(
                  _clip == null
                      ? t('開始錄音', 'Start recording')
                      : t('重新錄音', 'Record again'),
                ),
              ),
            if (_phase == _AudioPhase.recording)
              FilledButton(
                onPressed: _finish,
                child: Text(t('停止錄音', 'Stop recording')),
              ),
            if (_phase == _AudioPhase.playing)
              OutlinedButton(
                onPressed: () {
                  _halt();
                  setState(() => _phase = _AudioPhase.idle);
                },
                child: Text(t('停止播放', 'Stop playback')),
              ),
            if (idle && _clip != null) ...[
              OutlinedButton(
                onPressed: _preview,
                child: Text(t('試聽錄音', 'Preview recording')),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _clip = null;
                  _message = t(
                    '套用後會移除這段錄音。',
                    'Apply to remove this recording.',
                  );
                }),
                child: Text(t('移除錄音', 'Remove recording')),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (ModalRoute.isCurrentOf(context) == true) {
                Navigator.pop(context);
              }
            },
            child: Text(t('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: idle && (_clip != null || widget.initial != null)
                ? _apply
                : null,
            child: Text(t('套用錄音', 'Apply recording')),
          ),
        ],
      ),
    );
  }
}
