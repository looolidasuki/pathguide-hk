package hk.pathguide.pathguide

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    /**
     * 菜單插件需要 Activity 才能開系統相機／相簿，並接收回來的結果，
     * 所以在這裡持有實例，由 [onActivityResult] 轉發。
     */
    private val menuPlugin by lazy { MenuPlugin(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 刻意**不在这里缓存相机权限状态**：权限由 Dart 侧在启动后申请，
        // 插件必须每次动态检查，并在 Dart 授权后收到 startPreview 才启动相机。
        // 缓存一次会导致授权后仍无预览，且不报任何错。
        flutterEngine.plugins.add(VisionPlugin(context = this))
        flutterEngine.plugins.add(NavigationPlugin())
        flutterEngine.plugins.add(SpeechInputPlugin())
        flutterEngine.plugins.add(menuPlugin)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // 先問菜單插件（它只認自己的 requestCode），其餘照舊交回 Flutter。
        if (!menuPlugin.onActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
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
