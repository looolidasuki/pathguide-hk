import Flutter
import UIKit
import MapKit
import CoreLocation

final class NavigationPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, CLLocationManagerDelegate {
  private let channel: FlutterMethodChannel
  private let events: FlutterEventChannel
  private let manager: CLLocationManager
  private let locationServicesEnabled: () -> Bool
  private let geocoder = CLGeocoder()
  private var sink: FlutterEventSink?
  private var search: MKLocalSearch?
  private var searchReply: FlutterResult?
  private var directions: MKDirections?
  private var routeReply: FlutterResult?
  private var fixReply: FlutterResult?
  private var fixTimeout: DispatchWorkItem?
  private var tracking = false
  private var idleBefore: Bool?
  private weak var map: MKMapView? { didSet { positionPin = nil; if let lastLocation { updateMap(lastLocation) } } }
  private var positionPin: MKPointAnnotation?
  private var lastLocation: CLLocation?

  init(messenger: FlutterBinaryMessenger,
       locationManager: CLLocationManager = CLLocationManager(),
       locationServicesEnabled: @escaping () -> Bool = { CLLocationManager.locationServicesEnabled() }) {
    manager = locationManager
    self.locationServicesEnabled = locationServicesEnabled
    channel = FlutterMethodChannel(name: "hk.pathguide/navigation", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "hk.pathguide/navigation/location", binaryMessenger: messenger)
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.distanceFilter = 2
    manager.activityType = .fitness
    events.setStreamHandler(self)
    NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
  }
  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = NavigationPlugin(messenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: plugin.channel)
    registrar.register(NavigationMapFactory { [weak plugin] map in plugin?.map = map }, withId: "hk.pathguide/navigation/map")
  }
  deinit { NotificationCenter.default.removeObserver(self) }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; stop(); return nil }
  private func error(_ code: String, _ text: String) -> FlutterError { FlutterError(code: code, message: text, details: nil) }
  private func coordinate(_ value: Any?) -> CLLocationCoordinate2D? {
    guard let m = value as? [String: Any], let lat = m["latitude"] as? Double, let lng = m["longitude"] as? Double else { return nil }
    let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
    return CLLocationCoordinate2DIsValid(c) ? c : nil
  }
  private func point(_ c: CLLocationCoordinate2D) -> [String: Double] { ["latitude": c.latitude, "longitude": c.longitude] }
  private func points(_ line: MKPolyline) -> [[String: Double]] { (0..<line.pointCount).map { point(line.points()[$0].coordinate) } }
  private func cancelSearch() { search?.cancel(); search = nil; let reply = searchReply; searchReply = nil; reply?(error("cancelled", "已取消搜尋。")) }
  private func cancelRoute() { directions?.cancel(); directions = nil; let reply = routeReply; routeReply = nil; reply?(error("cancelled", "已取消路線查詢。")) }
  private func awake(_ enabled: Bool) {
    if enabled { if idleBefore == nil { idleBefore = UIApplication.shared.isIdleTimerDisabled }; UIApplication.shared.isIdleTimerDisabled = true }
    else if let old = idleBefore { UIApplication.shared.isIdleTimerDisabled = old; idleBefore = nil }
  }
  private func stop() {
    tracking = false; manager.stopUpdatingLocation(); fixTimeout?.cancel(); fixTimeout = nil
    let reply = fixReply; fixReply = nil; reply?(error("cancelled", "已停止定位。")); awake(false)
  }
  @objc private func background() { stop(); cancelSearch(); cancelRoute(); geocoder.cancelGeocode() }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "searchPlaces":
      guard let query = args["query"] as? String, !query.isEmpty, query.count <= 200 else { result(error("invalid_argument", "請輸入目的地名稱。")); return }
      cancelSearch()
      let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
      request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 22.32, longitude: 114.17), span: MKCoordinateSpan(latitudeDelta: 0.65, longitudeDelta: 0.9))
      let operation = MKLocalSearch(request: request); search = operation; searchReply = result
      operation.start { [weak self, weak operation] response, failure in
        guard let self, let operation, self.search === operation else { return }
        self.search = nil; let reply = self.searchReply; self.searchReply = nil
        reply?(Self.placesResult(response?.mapItems, failure: failure))
      }
    case "cancelSearch": cancelSearch(); result(nil)
    case "calculateRoute":
      guard let origin = coordinate(args["origin"]), let destination = args["destination"] as? [String: Any], let end = coordinate(destination["coordinate"]), destination["provider"] as? String == "apple" else { result(error("invalid_argument", "路線資料無效。")); return }
      cancelRoute()
      let request = MKDirections.Request()
      request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin)); request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
      request.transportType = .walking; request.requestsAlternateRoutes = false
      let operation = MKDirections(request: request); directions = operation; routeReply = result
      operation.calculate { [weak self, weak operation] response, failure in
        guard let self, let operation, self.directions === operation else { return }
        self.directions = nil; let reply = self.routeReply; self.routeReply = nil
        guard let route = response?.routes.first, failure == nil else { reply?(self.error("no_route", "未能取得步行路線，請檢查網絡或修改目的地。")); return }
        reply?(["provider": "apple", "id": UUID().uuidString, "polyline": self.points(route.polyline), "distance": route.distance, "duration": route.expectedTravelTime, "notices": route.advisoryNotices, "steps": route.steps.map { step -> [String: Any] in
          ["instructions": step.instructions, "notice": step.notice ?? "", "polyline": self.points(step.polyline), "maneuver": "unknown"]
        }])
      }
    case "cancelRoute": cancelRoute(); result(nil)
    case "currentLocation":
      guard fixReply == nil else { result(error("busy", "正在定位，請稍候。")); return }
      guard locationServicesEnabled() else { result(error("location_disabled", "請先在系統設定開啟定位服務。")); return }
      fixReply = result
      let timeout = DispatchWorkItem { [weak self] in self?.finishFix(nil, failure: self?.error("location_poor", "未能取得精確位置，請到開揚位置重試。")) }
      fixTimeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
      if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() } else { requestFix() }
    case "startLocation":
      guard authorized && manager.accuracyAuthorization == .fullAccuracy else { result(error("location_denied", "請開啟使用 App 期間的精確定位。")); return }
      tracking = true; manager.startUpdatingLocation(); result(nil)
    case "stopLocation": stop(); result(nil)
    case "keepAwake": awake(args["enabled"] as? Bool == true); result(nil)
    case "address":
      guard let c = coordinate(args["coordinate"]) else { result(nil); return }
      geocoder.cancelGeocode()
      geocoder.reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude), preferredLocale: Locale(identifier: "zh_Hant_HK")) { places, _ in result(places?.first.map { [$0.name, $0.locality].compactMap { $0 }.joined(separator: "，") }) }
    default: result(FlutterMethodNotImplemented)
    }
  }
  static func placesResult(_ items: [MKMapItem]?, failure: Error?) -> Any {
    if let failure {
      let code = (failure as? MKError)?.code
      if code == .placemarkNotFound { return [[String: Any]]() }
      if code == .loadingThrottled {
        return FlutterError(code: "quota", message: "搜尋次數暫時過多，請稍後重試。", details: nil)
      }
      return FlutterError(code: "unavailable", message: "搜尋服務暫時不可用，請檢查網絡後重試。", details: nil)
    }
    guard let items else {
      return FlutterError(code: "unavailable", message: "搜尋服務暫時不可用，請稍後重試。", details: nil)
    }
    return items.filter { $0.placemark.isoCountryCode == "HK" }.prefix(10).map { item -> [String: Any] in
      let c = item.placemark.coordinate
      return ["provider": "apple", "id": "\(c.latitude),\(c.longitude):\(item.name ?? "")",
              "name": item.name ?? "目的地", "address": item.placemark.title ?? "",
              "coordinate": ["latitude": c.latitude, "longitude": c.longitude]]
    }
  }
  private var authorized: Bool { manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways }
  private func requestFix() {
    guard fixReply != nil else { return }
    guard authorized else { finishFix(nil, failure: error("location_denied", "未獲定位權限，可在設定開啟使用 App 期間的定位。")); return }
    guard manager.accuracyAuthorization == .fullAccuracy else { finishFix(nil, failure: error("location_poor", "請在系統設定為領路通開啟精確定位。")); return }
    manager.startUpdatingLocation()
  }
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if fixReply != nil && manager.authorizationStatus != .notDetermined { requestFix() }
    if tracking && (!authorized || manager.accuracyAuthorization != .fullAccuracy) {
      sink?(error(authorized ? "location_poor" : "location_denied", "定位權限已變更，請重新開啟精確定位後繼續。"))
      stop()
    }
  }
  private func data(_ location: CLLocation) -> [String: Any] {
    var value: [String: Any] = ["coordinate": point(location.coordinate), "accuracy": location.horizontalAccuracy, "ageSeconds": max(0, -location.timestamp.timeIntervalSinceNow)]
    if location.course >= 0 && location.speed > 0.8 { value["course"] = location.course }
    return value
  }
  private func updateMap(_ location: CLLocation) {
    guard let map else { return }
    if positionPin == nil { let pin = MKPointAnnotation(); pin.title = "目前位置"; map.addAnnotation(pin); positionPin = pin }
    positionPin?.coordinate = location.coordinate
  }
  private func finishFix(_ location: CLLocation?, failure: FlutterError? = nil) {
    fixTimeout?.cancel(); fixTimeout = nil; let reply = fixReply; fixReply = nil
    if !tracking { manager.stopUpdatingLocation() }
    if let location { reply?(data(location)) }
    else { reply?(failure ?? error("location_poor", "定位暫時不足。")) }
  }
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let latest = locations.last else { return }
    lastLocation = latest; updateMap(latest)
    if fixReply != nil && latest.horizontalAccuracy >= 0 && latest.horizontalAccuracy <= 25 && abs(latest.timestamp.timeIntervalSinceNow) <= 10 { finishFix(latest) }
    if tracking { sink?(data(latest)) }
  }
  func locationManager(_ manager: CLLocationManager, didFailWithError failure: Error) {
    if (failure as? CLError)?.code == .locationUnknown { return }
    finishFix(nil, failure: error("location_poor", "定位暫時不可用，請檢查權限或重試。"))
    if tracking { sink?(error("location_poor", "定位暫時不可用。")) }
  }
}

private final class NavigationMapFactory: NSObject, FlutterPlatformViewFactory {
  let created: (MKMapView) -> Void
  init(_ created: @escaping (MKMapView) -> Void) { self.created = created }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView { NavigationMapView(frame, args as? [String: Any] ?? [:], created) }
}
private final class NavigationMapView: NSObject, FlutterPlatformView, MKMapViewDelegate {
  private let map: MKMapView
  init(_ frame: CGRect, _ args: [String: Any], _ created: (MKMapView) -> Void) {
    map = MKMapView(frame: frame); super.init(); map.delegate = self
    // No implicit location subscription: the navigation task owns location lifetime.
    map.showsUserLocation = false
    if let route = args["route"] as? [String: Any], route["provider"] as? String == "apple", let points = route["polyline"] as? [[String: Double]], !points.isEmpty {
      var coords = points.compactMap { p -> CLLocationCoordinate2D? in guard let lat = p["latitude"], let lng = p["longitude"] else { return nil }; return CLLocationCoordinate2D(latitude: lat, longitude: lng) }
      let line = MKPolyline(coordinates: &coords, count: coords.count); map.addOverlay(line)
      map.setVisibleMapRect(line.boundingMapRect, edgePadding: UIEdgeInsets(top: 25, left: 25, bottom: 25, right: 25), animated: false)
    }
    if let place = args["destination"] as? [String: Any], let c = place["coordinate"] as? [String: Double], let lat = c["latitude"], let lng = c["longitude"] {
      let pin = MKPointAnnotation(); pin.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng); pin.title = place["name"] as? String; map.addAnnotation(pin)
    }
    created(map)
  }
  func view() -> UIView { map }
  func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer { let renderer = MKPolylineRenderer(overlay: overlay); renderer.strokeColor = .systemBlue; renderer.lineWidth = 5; return renderer }
}
