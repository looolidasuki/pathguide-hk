package hk.pathguide.pathguide

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 刻意**不在这里缓存相机权限状态**：权限由 Dart 侧在启动后申请，
        // 插件必须每次动态检查，并在 Dart 授权后收到 startPreview 才启动相机。
        // 缓存一次会导致授权后仍无预览，且不报任何错。
        flutterEngine.plugins.add(VisionPlugin(context = this))
        flutterEngine.plugins.add(NavigationPlugin())
        flutterEngine.plugins.add(SpeechInputPlugin())
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 屏幕常亮：演示途中息屏会让人以为程序崩了。
        // Individual foreground tasks now own the wake flag.
    }
    override fun onStop() {
        TaskWakeLock.clear(window)
        super.onStop()
    }
}
