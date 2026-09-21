package hk.pathguide.pathguide

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 刻意**不在这里缓存相机权限状态**：权限由 Dart 侧在启动后申请，
        // 插件必须每次动态检查，并在 Dart 授权后收到 startPreview 才启动相机。
        // 缓存一次会导致授权后仍无预览，且不报任何错。
        flutterEngine.plugins.add(VisionPlugin(context = this))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 屏幕常亮：演示途中息屏会让人以为程序崩了。
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
