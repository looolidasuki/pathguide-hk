package hk.pathguide.pathguide

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 相机是运行时权限。这里只在**已经授予**时启动预览；未授予时先不启动，
        // 由 Dart 侧请求权限，授予后重建平台视图（见 VisionPreview 的 key）。
        // 这样避免在 Kotlin 里再做一套权限请求逻辑。
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        flutterEngine.plugins.add(VisionPlugin(context = this, cameraGranted = granted))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 屏幕常亮：演示途中息屏会让人以为程序崩了。
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
