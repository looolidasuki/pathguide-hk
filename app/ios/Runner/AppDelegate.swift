import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var cameraLifecycle: CameraApplicationLifecycle?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    RouteLandmarkProbe.runIfRequested()
    cameraLifecycle = CameraApplicationLifecycle(
      initiallyActive: application.applicationState == .active)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PathGuideNavigationPlugin") {
      NavigationPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PathGuideMenuPlugin") {
      MenuPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PathGuideVisionPlugin") {
      VisionPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PathGuideDepthPlugin") {
      DepthPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PathGuideRouteLandmarkPlugin") {
      RouteLandmarkPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PathGuideRouteStoragePlugin") {
      RouteStoragePlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PathGuideRouteCameraPlugin") {
      RouteCameraPlugin.register(with: registrar)
    }
  }
}

/// Bind the shared hardware gate once, before registering any camera plugin.
/// Foreground only permits an explicit new request; it never restarts an owner.
final class CameraApplicationLifecycle {
  private let center: NotificationCenter
  private var observers: [NSObjectProtocol] = []

  init(coordinator: CameraCoordinator = .shared,
       center: NotificationCenter = .default, initiallyActive: Bool) {
    precondition(Thread.isMainThread)
    self.center = center
    if initiallyActive { coordinator.enterForeground() }
    else { coordinator.enterBackground() }
    observers = [
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
        object: nil, queue: .main) { _ in coordinator.enterBackground() },
      center.addObserver(forName: UIApplication.didBecomeActiveNotification,
        object: nil, queue: .main) { _ in coordinator.enterForeground() },
    ]
  }

  deinit { observers.forEach(center.removeObserver) }
}
