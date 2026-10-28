package hk.pathguide.pathguide

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * 快速設定磁貼：讓領路通能從**通知欄**啟動，不必回到主頁。
 *
 * ## 為什麼要做這個（無障礙理由）
 *
 * 全盲使用者要從主頁開 App，只能一頁一頁滑、一個一個聽圖示名稱，是線性搜尋，很慢。
 * 而磁貼是**雙指下拉通知欄**就能碰到、在任何 App 裡都能用，是目前唯一
 * 「不需要回主頁、兩秒內可達」的路徑。
 *
 * ## 為什麼不能用 `startActivity` 直接開 MainActivity
 *
 * 1. `TileService` 不是前景元件，從它啟動 Activity 必須走
 *    `startActivityAndCollapse`，否則會被系統當成背景啟動而擋掉。
 * 2. **API 34 起 `startActivityAndCollapse(Intent)` 已棄用**，改用接受
 *    `PendingIntent` 的多載版本。本專案的 targetSdk 是 36，
 *    所以兩條分支都要寫，否則在 Android 14+ 上磁貼會沒反應。
 *
 * ## 這裡刻意不做的事
 *
 * 不在 `onClick` 裡自己判斷「App 是否已在執行」。啟動邏輯交給系統處理
 * （`ACTION_MAIN` + `CATEGORY_LAUNCHER`，與桌面圖示完全相同的意圖），
 * 加上 manifest 裡的 `launchMode="singleTop"`，就算 App 已經開著也只會被帶到前景，
 * 不會開出第二個實例。自己寫一套判斷只會多一份會過期的假設。
 */
class PathGuideTileService : TileService() {

    /**
     * 磁貼出現在通知欄時，把標籤與圖示同步一次。
     *
     * 標籤走資源（`@string/tile_label`）而不是寫死，理由與桌面圖示的
     * `@string/app_name` 相同：**這是全盲使用者唯一會聽到的字**，
     * 必須跟著系統語言走。英文系統聽到「Start guidance」、
     * 香港中文系統聽到「開始引導」。
     */
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        tile.state = Tile.STATE_INACTIVE
        tile.icon = Icon.createWithResource(this, R.drawable.ic_qs_tile)
        tile.label = getString(R.string.tile_label)
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()

        // 用意圖完全比照桌面圖示：這樣「從磁貼開」與「從桌面開」走的是同一條路，
        // 行為不會分岔。加了 NEW_TASK 是因為我們不在 Activity 的任務裡。
        val launch = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // API 34+：必須用 PendingIntent 版本。
            // FLAG_IMMUTABLE 是 API 31+ 的強制要求，缺了會直接丟例外。
            val pending = PendingIntent.getActivity(
                this,
                0,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(launch)
        }
    }
}
