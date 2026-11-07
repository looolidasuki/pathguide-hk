import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import 'encrypted_route_store.dart';
import 'device_route_library.dart';
import 'route_library_controller.dart';
import 'route_library_page.dart';

/// The sole native store owner for this screen; opening is lazy and explicit.
class RouteLibraryScreen extends StatefulWidget {
  const RouteLibraryScreen({
    super.key,
    required this.settings,
    this.createController,
  });
  final AppSettings settings;
  final Future<RouteLibraryController> Function()? createController;
  @override
  State<RouteLibraryScreen> createState() => _RouteLibraryScreenState();
}

class _RouteLibraryScreenState extends State<RouteLibraryScreen>
    with WidgetsBindingObserver {
  RouteLibraryController? _controller;
  bool _failed = false, _foreground = true;
  int _generation = 0;
  bool get _en => widget.settings.language == AppLanguage.english;
  String _t(String zh, String en) => _en ? en : zh;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _open();
  }

  Future<void> _open() async {
    final gen = ++_generation;
    try {
      final c = await (widget.createController?.call() ?? _deviceController());
      if (!mounted || gen != _generation) {
        c.dispose();
        return;
      }
      c.setForeground(_foreground);
      setState(() {
        _controller = c;
        _failed = false;
      });
    } catch (_) {
      if (mounted && gen == _generation) setState(() => _failed = true);
    }
  }

  Future<RouteLibraryController> _deviceController() async =>
      RouteLibraryController(
        DeviceRouteLibrary(await EncryptedRouteStore.open()),
      );
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _controller?.setForeground(_foreground);
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: _controller != null
        ? RouteLibraryPage(
            controller: _controller!,
            settings: widget.settings,
            onBack: () => Navigator.of(context).pop(),
          )
        : SafeArea(
            child: AnimatedBuilder(
              animation: widget.settings,
              builder: (context, _) => Column(
                children: [
                  Expanded(
                    child: Center(
                      child: Text(
                        _failed
                            ? _t(
                                '暫時無法開啟本機路線庫，資料未被清除。',
                                'Cannot open local routes. Existing data has been retained.',
                              )
                            : _t('正在開啟本機路線庫…', 'Opening local routes…'),
                      ),
                    ),
                  ),
                  if (_failed)
                    OutlinedButton(
                      onPressed: () {
                        setState(() => _failed = false);
                        _open();
                      },
                      child: Text(_t('重新嘗試', 'Retry')),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(_t('返回', 'Back')),
                    ),
                  ),
                ],
              ),
            ),
          ),
  );
}
