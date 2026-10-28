package hk.pathguide.pathguide

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.Geocoder
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.widget.TextView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.location.*
import com.google.android.gms.maps.*
import com.google.android.gms.maps.model.*
import com.google.android.libraries.places.api.Places
import com.google.android.libraries.places.api.model.Place
import com.google.android.libraries.places.api.model.RectangularBounds
import com.google.android.libraries.places.api.net.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.Locale

class NavigationPlugin : FlutterPlugin, ActivityAware, PluginRegistry.RequestPermissionsResultListener, EventChannel.StreamHandler, DefaultLifecycleObserver {
  private lateinit var context: Context
  private lateinit var channel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private var activity: Activity? = null
  private var activityBinding: ActivityPluginBinding? = null
  private var sink: EventChannel.EventSink? = null
  private var fixReply: MethodChannel.Result? = null
  private var client: FusedLocationProviderClient? = null
  private var places: PlacesClient? = null
  private var searching: MethodChannel.Result? = null
  private var searchGeneration = 0
  private var tracking = false
  private val handler = Handler(Looper.getMainLooper())
  private val maps = mutableSetOf<NavigationMapView>()
  private var lastPosition: LatLng? = null
  private val timeout = Runnable { finishFix(null, "定位逾時，請到開揚位置重試。") }
  private val callback = object : LocationCallback() {
    override fun onLocationResult(result: LocationResult) {
      val fix = result.lastLocation ?: return
      val age = (SystemClock.elapsedRealtimeNanos() - fix.elapsedRealtimeNanos).coerceAtLeast(0) / 1e9
      val value = mutableMapOf<String, Any>("coordinate" to mapOf("latitude" to fix.latitude, "longitude" to fix.longitude), "accuracy" to fix.accuracy.toDouble(), "ageSeconds" to age)
      if (fix.hasBearing() && fix.hasSpeed() && fix.speed > 0.8) value["course"] = fix.bearing.toDouble()
      if (fixReply != null && age <= 10 && fix.accuracy <= 25 && fine()) finishFix(value)
      if (tracking) sink?.success(value)
      lastPosition = LatLng(fix.latitude, fix.longitude)
      maps.forEach { it.position(lastPosition!!) }
    }
    override fun onLocationAvailability(value: LocationAvailability) { if (!value.isLocationAvailable && tracking) sink?.error("location_poor", "定位暫時不足。", null) }
  }
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "hk.pathguide/navigation"); channel.setMethodCallHandler(::handle)
    eventChannel = EventChannel(binding.binaryMessenger, "hk.pathguide/navigation/location"); eventChannel.setStreamHandler(this)
    binding.platformViewRegistry.registerViewFactory("hk.pathguide/navigation/map", object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
      override fun create(context: Context, id: Int, args: Any?): PlatformView {
        val a = activity
        val view = NavigationMapView(a ?: context, args as? Map<*, *> ?: emptyMap<Any, Any>(), configured(), a as? LifecycleOwner) { maps.remove(it) }
        maps.add(view); lastPosition?.let { view.position(it) }; return view
      }
    })
  }
  private fun configured(): Boolean = key().isNotBlank() && GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS
  private fun key(): String = context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA).metaData?.getString("com.google.android.geo.API_KEY") ?: ""
  private fun ready(result: MethodChannel.Result): Boolean {
    if (GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) != ConnectionResult.SUCCESS) { result.error("unsupported", "此手機沒有可用的 Google Play 服務，導航暫不可用。", null); return false }
    if (key().isBlank()) { result.error("not_configured", "Google 地圖及搜尋尚未設定。", null); return false }
    if (client == null) client = LocationServices.getFusedLocationProviderClient(context)
    if (places == null) { if (!Places.isInitialized()) Places.initializeWithNewPlacesApiEnabled(context, key(), Locale.TRADITIONAL_CHINESE); places = Places.createClient(context) }
    return true
  }
  private fun fine() = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
  private fun handle(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "cancelSearch" -> { cancelSearch(); result.success(null) }
      "cancelRoute" -> result.success(null) // Flutter generations discard an already sent callable response.
      "stopLocation" -> { stop(); result.success(null) }
      "keepAwake" -> { awake(call.argument<Boolean>("enabled") == true); result.success(null) }
      "searchPlaces" -> {
        if (!ready(result)) return
        val query = call.argument<String>("query")?.trim() ?: ""
        if (query.isBlank() || query.length > 200) { result.error("invalid_argument", "請輸入目的地名稱。", null); return }
        cancelSearch(); searching = result; val generation = searchGeneration
        val request = SearchByTextRequest.builder(query, listOf(Place.Field.ID, Place.Field.DISPLAY_NAME, Place.Field.FORMATTED_ADDRESS, Place.Field.LOCATION))
          .setMaxResultCount(10).setRegionCode("HK").setLocationRestriction(RectangularBounds.newInstance(LatLng(22.15,113.80), LatLng(22.58,114.45))).build()
        places!!.searchByText(request).addOnSuccessListener { response -> if (generation == searchGeneration) { searching = null; result.success(response.places.mapNotNull(::placeData)) } }
          .addOnFailureListener { if (generation == searchGeneration) { searching = null; result.error("unavailable", "未能搜尋，請檢查網絡及 Google 設定。", null) } }
      }
      "resolvePlace" -> {
        if (!ready(result)) return
        val id = call.argument<String>("id") ?: ""
        val request = FetchPlaceRequest.newInstance(id, listOf(Place.Field.ID, Place.Field.DISPLAY_NAME, Place.Field.FORMATTED_ADDRESS, Place.Field.LOCATION))
        places!!.fetchPlace(request).addOnSuccessListener { response -> val place = placeData(response.place); if (place == null) result.error("not_found", "此地點已失效，請重新搜尋。", null) else result.success(place) }
          .addOnFailureListener { result.error("not_found", "未能讀取收藏地點，請連線或重新搜尋。", null) }
      }
      "currentLocation" -> {
        if (!ready(result)) return
        if (fixReply != null) { result.error("busy", "正在取得位置。", null); return }
        fixReply = result; handler.postDelayed(timeout, 15000)
        if (fine()) requestFix() else {
          val a = activity
          if (a == null) finishFix(null, "請返回 App 後重試。") else ActivityCompat.requestPermissions(a, arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION), 871)
        }
      }
      "startLocation" -> {
        if (!ready(result)) return
        if (!fine()) { result.error("location_denied", "請為領路通開啟精確定位。", null); return }
        tracking = true; requestFix(); result.success(null)
      }
      "address" -> {
        val c = call.argument<Map<String, Number>>("coordinate")
        if (c == null || !Geocoder.isPresent()) { result.success(null); return }
        // Legacy Geocoder is blocking; keep it off the platform thread.
        Thread {
          val address = try { @Suppress("DEPRECATION")
            Geocoder(context, Locale.TRADITIONAL_CHINESE).getFromLocation(c["latitude"]!!.toDouble(), c["longitude"]!!.toDouble(), 1)?.firstOrNull()?.getAddressLine(0)
          } catch (_: Exception) { null }
          handler.post { result.success(address) }
        }.start()
      }
      else -> result.notImplemented()
    }
  }
  private fun placeData(place: Place): Map<String, Any>? {
    val c = place.location ?: return null
    return mapOf("provider" to "google", "id" to (place.id ?: return null), "name" to (place.displayName ?: "目的地"), "address" to (place.formattedAddress ?: ""), "coordinate" to mapOf("latitude" to c.latitude, "longitude" to c.longitude))
  }
  @Suppress("MissingPermission")
  private fun requestFix() {
    if (!fine()) { finishFix(null, "請開啟精確定位。"); return }
    val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 2000).setMinUpdateIntervalMillis(1000).setMinUpdateDistanceMeters(2f).build()
    client?.requestLocationUpdates(request, callback, Looper.getMainLooper())?.addOnFailureListener { finishFix(null, "未能定位，請檢查系統定位設定。"); if (tracking) sink?.error("location_poor", "定位暫時不可用。", null) }
  }
  private fun finishFix(value: Map<String, Any>?, failure: String? = null) {
    handler.removeCallbacks(timeout); val result = fixReply; fixReply = null
    if (!tracking) client?.removeLocationUpdates(callback)
    if (value != null) result?.success(value) else result?.error("location_poor", failure ?: "定位暫時不足。", null)
  }
  private fun awake(enabled: Boolean) { TaskWakeLock.set(activity?.window, "navigation", enabled) }
  private fun stop() { tracking = false; finishFix(null, "定位已停止。"); awake(false) }
  private fun cancelSearch() { searchGeneration++; val old = searching; searching = null; old?.error("cancelled", "搜尋已取消。", null) }
  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
    if (requestCode != 871) return false
    if (fixReply != null) { if (fine()) requestFix() else finishFix(null, "請在設定開啟使用期間的精確定位。") }; return true
  }
  override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
  override fun onCancel(arguments: Any?) { sink = null; stop() }
  override fun onStop(owner: LifecycleOwner) { stop(); cancelSearch() }
  override fun onAttachedToActivity(binding: ActivityPluginBinding) { activityBinding = binding; activity = binding.activity; binding.addRequestPermissionsResultListener(this); (activity as? LifecycleOwner)?.lifecycle?.addObserver(this) }
  override fun onDetachedFromActivity() { activityBinding?.removeRequestPermissionsResultListener(this); activityBinding = null; stop(); cancelSearch(); (activity as? LifecycleOwner)?.lifecycle?.removeObserver(this); activity = null }
  override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) { stop(); cancelSearch(); channel.setMethodCallHandler(null); eventChannel.setStreamHandler(null) }
}

private class NavigationMapView(context: Context, args: Map<*, *>, configured: Boolean, private val owner: LifecycleOwner?, private val disposed: (NavigationMapView) -> Unit) : PlatformView, DefaultLifecycleObserver {
  private val mapView = if (configured) MapView(context) else null
  private val fallback = TextView(context).apply { text = "Google 地圖尚未配置或此裝置不支援。" }
  private var googleMap: GoogleMap? = null
  private var marker: Marker? = null
  private var destroyed = false
  private var latestPosition: LatLng? = null
  init {
    mapView?.onCreate(null)
    mapView?.getMapAsync { map ->
      googleMap = map
      latestPosition?.let { position(it) }
      val route = args["route"] as? Map<*, *>
      if (route?.get("provider") == "google") {
        val points = (route["polyline"] as? List<*>)?.mapNotNull { coordinate(it) } ?: emptyList()
        if (points.size >= 2) { map.addPolyline(PolylineOptions().addAll(points).color(0xff1565c0.toInt()).width(10f)); val bounds = LatLngBounds.builder(); points.forEach { bounds.include(it) }; mapView?.post { try { map.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds.build(), 40)) } catch (_: Exception) {} } }
      }
      val place = args["destination"] as? Map<*, *>
      coordinate(place?.get("coordinate"))?.let { map.addMarker(MarkerOptions().position(it).title(place?.get("name") as? String)) }
    }
    owner?.lifecycle?.addObserver(this)
    if (owner == null) { mapView?.onStart(); mapView?.onResume() }
  }
  private fun coordinate(raw: Any?): LatLng? { val m = raw as? Map<*, *> ?: return null; return LatLng((m["latitude"] as? Number)?.toDouble() ?: return null, (m["longitude"] as? Number)?.toDouble() ?: return null) }
  fun position(point: LatLng) { latestPosition = point; val map = googleMap ?: return; if (marker == null) marker = map.addMarker(MarkerOptions().position(point).title("目前位置").icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_AZURE))) else marker?.position = point }
  override fun getView(): View = mapView ?: fallback
  override fun onStart(owner: LifecycleOwner) { mapView?.onStart() }
  override fun onResume(owner: LifecycleOwner) { mapView?.onResume() }
  override fun onPause(owner: LifecycleOwner) { mapView?.onPause() }
  override fun onStop(owner: LifecycleOwner) { mapView?.onStop() }
  override fun onDestroy(owner: LifecycleOwner) { dispose() }
  override fun dispose() { if (destroyed) return; destroyed = true; owner?.lifecycle?.removeObserver(this); mapView?.onPause(); mapView?.onStop(); mapView?.onDestroy(); disposed(this) }
}
