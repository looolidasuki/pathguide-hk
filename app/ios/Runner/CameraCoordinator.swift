import Foundation

enum CameraOwner: String, CaseIterable {
  case vision, depth, menu, route
}

struct CameraRequestID: Hashable {
  let owner: CameraOwner
  fileprivate let coordinator: UUID
  fileprivate let nonce: UUID
}

struct CameraLeaseID: Hashable {
  let owner: CameraOwner
  fileprivate let coordinator: UUID
  fileprivate let nonce: UUID
}

enum CameraFailure: Equatable {
  case superseded, cancelled, timedOut, backgrounded, physicalStopFailed
}

enum CameraRequestOutcome: Equatable {
  case granted(CameraLeaseID)
  case failed(CameraFailure)
}

enum CameraOwnerStatus: Equatable {
  case idle
  case active(CameraLeaseID)
  case stopping(CameraLeaseID, waiting: CameraRequestID?)
  case blockedUnconfirmed(CameraLeaseID)
}

protocol CameraTimerToken: AnyObject {
  func cancel()
}

/// Schedule and cancel on the main thread. Cancellation must not invoke the callback.
protocol CameraTimeoutScheduler: AnyObject {
  func schedule(after seconds: TimeInterval, _ callback: @escaping () -> Void) -> CameraTimerToken
}

final class MainQueueCameraScheduler: CameraTimeoutScheduler {
  private final class Token: CameraTimerToken {
    let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
  }

  func schedule(after seconds: TimeInterval, _ callback: @escaping () -> Void) -> CameraTimerToken {
    let item = DispatchWorkItem(block: callback)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    return Token(item)
  }
}

/// All entry points and adapter callbacks execute on the main thread.
///
/// A lease authorizes queued permission/start work only while `isCurrent` is true.
/// The lease's stop adapter must synchronously invalidate its generation, then
/// acknowledge on the main thread only after all queued starts and physical stops
/// have drained. A logical cancellation or timeout never proves hardware stopped.
final class CameraCoordinator {
  typealias Stop = (@escaping (Bool) -> Void) -> Void
  static let shared = CameraCoordinator()

  private final class Request {
    let id: CameraRequestID
    let stop: Stop
    let onStopUnconfirmed: (CameraFailure) -> Void
    private var completion: ((CameraRequestOutcome) -> Void)?

    init(_ id: CameraRequestID, stop: @escaping Stop,
         onStopUnconfirmed: @escaping (CameraFailure) -> Void,
         completion: @escaping (CameraRequestOutcome) -> Void) {
      self.id = id
      self.stop = stop
      self.onStopUnconfirmed = onStopUnconfirmed
      self.completion = completion
    }

    func finish(_ outcome: CameraRequestOutcome) {
      let callback = completion
      completion = nil
      callback?(outcome)
    }
  }

  private struct Active {
    let request: Request
    let lease: CameraLeaseID
  }

  private final class Stopping {
    let id = UUID()
    let active: Active
    var timer: CameraTimerToken?
    var blocked = false
    init(_ active: Active) { self.active = active }
  }

  private let identity = UUID()
  private let scheduler: CameraTimeoutScheduler
  private let timeout: TimeInterval
  private var active: Active?
  private var stopping: Stopping?
  private var waiting: Request?
  private(set) var isBackgrounded = false

  init(scheduler: CameraTimeoutScheduler = MainQueueCameraScheduler(), timeout: TimeInterval = 3) {
    precondition(timeout.isFinite && timeout > 0)
    self.scheduler = scheduler
    self.timeout = timeout
  }

  var currentStatus: CameraOwnerStatus {
    requireMain()
    if let stop = stopping {
      return stop.blocked ? .blockedUnconfirmed(stop.active.lease)
        : .stopping(stop.active.lease, waiting: waiting?.id)
    }
    if let active { return .active(active.lease) }
    return .idle
  }

  func isCurrent(_ lease: CameraLeaseID) -> Bool {
    requireMain()
    return !isBackgrounded && lease.coordinator == identity && active?.lease == lease
  }

  /// Completion can synchronously reenter any coordinator method. State is
  /// committed before exposing a callback, and no replacement follows it.
  @discardableResult
  func request(owner: CameraOwner, stop: @escaping Stop,
               onStopUnconfirmed: @escaping (CameraFailure) -> Void = { _ in },
               completion: @escaping (CameraRequestOutcome) -> Void) -> CameraRequestID {
    requireMain()
    let id = CameraRequestID(owner: owner, coordinator: identity, nonce: UUID())
    let request = Request(id, stop: stop, onStopUnconfirmed: onStopUnconfirmed, completion: completion)
    if isBackgrounded {
      request.finish(.failed(.backgrounded))
    } else if let operation = stopping {
      if operation.blocked {
        request.finish(.failed(.physicalStopFailed))
      } else {
        let old = waiting
        waiting = request
        old?.finish(.failed(.superseded))
      }
    } else if let active {
      waiting = request
      beginStop(active)
    } else {
      grant(request)
    }
    return id
  }

  func cancel(_ request: CameraRequestID) {
    requireMain()
    guard request.coordinator == identity else { return }
    if waiting?.id == request {
      let old = waiting
      waiting = nil
      old?.finish(.failed(.cancelled))
    } else if let active, active.request.id == request {
      beginStop(active)
    }
  }

  func release(_ lease: CameraLeaseID) {
    requireMain()
    guard isCurrent(lease), let active else { return }
    beginStop(active)
  }

  func enterBackground() {
    requireMain()
    isBackgrounded = true
    let old = waiting
    waiting = nil
    if let active { beginStop(active) }
    old?.finish(.failed(.backgrounded))
  }

  /// Re-enables explicit requests; never restarts an old task.
  func enterForeground() {
    requireMain()
    isBackgrounded = false
  }

  private func grant(_ request: Request) {
    let lease = CameraLeaseID(owner: request.id.owner, coordinator: identity, nonce: UUID())
    active = Active(request: request, lease: lease)
    request.finish(.granted(lease))
  }

  private func beginStop(_ previous: Active) {
    active = nil
    let operation = Stopping(previous)
    let stopID = operation.id
    stopping = operation
    let timer = scheduler.schedule(after: timeout) { [weak self] in
      self?.failStop(stopID, reason: .timedOut)
    }
    if stopping === operation, !operation.blocked { operation.timer = timer }
    else { timer.cancel() }
    // The exact old owner's adapter is retained by its granted request.
    previous.request.stop { [weak self] confirmed in
      guard let self else { return }
      self.requireMain()
      if confirmed { self.acknowledgeStop(stopID) }
      else { self.failStop(stopID, reason: .physicalStopFailed) }
    }
  }

  private func acknowledgeStop(_ id: UUID) {
    requireMain()
    guard let operation = stopping, operation.id == id else { return }
    let next = waiting
    waiting = nil
    stopping = nil
    operation.timer?.cancel()
    operation.timer = nil
    // A timed-out request was already completed and removed. Only an explicitly
    // queued, still-live request can be granted; a background never starts one.
    if let next, !operation.blocked, !isBackgrounded { grant(next) }
  }

  private func failStop(_ id: UUID, reason: CameraFailure) {
    requireMain()
    guard let operation = stopping, operation.id == id, !operation.blocked else { return }
    operation.blocked = true
    let old = waiting
    waiting = nil
    operation.timer?.cancel()
    operation.timer = nil
    // Keep the physical gate until the matching late positive acknowledgment.
    old?.finish(.failed(reason))
    operation.active.request.onStopUnconfirmed(reason)
  }

  private func requireMain() { precondition(Thread.isMainThread, "CameraCoordinator requires main thread") }
}

/// One plugin acquisition, including delayed permission/start and stop callbacks.
/// Consumers keep one instance per attempt, so an old stop cannot invalidate a
/// newer attempt in the same plugin. Hardware callbacks must return on main.
final class CameraLeaseClient {
  private enum StopState { case idle, waiting, unconfirmed, finished }
  private let owner: CameraOwner
  private let coordinator: CameraCoordinator
  private let onInvalidated: () -> Void
  private var requestID: CameraRequestID?
  private var lease: CameraLeaseID?
  private var closed = false
  private var acquired = false
  private var ready: ((Bool) -> Void)?
  private var stopState = StopState.idle
  private var stopped: [(Bool) -> Void] = []
  // A broken adapter may drop its callback entirely. Keep waiters alive until
  // either its acknowledgment or the coordinator's bounded timeout fires.
  private var shutdownKeepAlive: CameraLeaseClient?

  init(owner: CameraOwner, coordinator: CameraCoordinator = .shared,
       onInvalidated: @escaping () -> Void = {}) {
    self.owner = owner
    self.coordinator = coordinator
    self.onInvalidated = onInvalidated
  }

  var isCurrent: Bool {
    precondition(Thread.isMainThread)
    return !closed && lease.map(coordinator.isCurrent) == true
  }

  func acquire(stop: @escaping CameraCoordinator.Stop, ready: @escaping (Bool) -> Void) {
    precondition(Thread.isMainThread && !acquired)
    acquired = true
    self.ready = ready
    guard !closed else { finishReady(false); return }
    let id = coordinator.request(owner: owner, stop: { [weak self] acknowledge in
      guard let self else { stop(acknowledge); return }
      self.stopState = .waiting
      self.shutdownKeepAlive = self
      self.invalidate()
      // The plugin may replace/nil its acquisition while shutdown is pending.
      // Keep its one-shot waiters alive through the physical acknowledgment.
      stop { [self] confirmed in
        precondition(Thread.isMainThread)
        if self.stopState == .finished { return }
        self.stopState = confirmed ? .finished : .unconfirmed
        acknowledge(confirmed)
        self.finishStopped(confirmed)
      }
    }, onStopUnconfirmed: { [weak self] _ in
      guard self?.stopState != .finished else { return }
      self?.stopState = .unconfirmed
      self?.finishStopped(false)
    }, completion: { [weak self] outcome in
      guard let self else { return }
      switch outcome {
      case .granted(let lease):
        self.lease = lease
        if self.closed { self.coordinator.release(lease) }
        else { self.finishReady(true) }
      case .failed:
        self.invalidate()
      }
    })
    requestID = id
    if closed { coordinator.cancel(id) }
  }

  /// Returns false on an unconfirmed physical stop, leaving the shared gate
  /// closed. A late hardware acknowledgment may release it, never auto-resume.
  func cancel(completion: @escaping (Bool) -> Void = { _ in }) {
    precondition(Thread.isMainThread)
    if stopState == .finished { completion(true); return }
    if stopState == .unconfirmed { completion(false); return }
    stopped.append(completion)
    invalidate()
    if let requestID { coordinator.cancel(requestID) }
    if let lease { coordinator.release(lease) }
    if stopState == .idle {
      stopState = .finished
      finishStopped(true)
    }
  }

  private func invalidate() {
    guard !closed else { return }
    closed = true
    finishReady(false)
    onInvalidated()
  }

  private func finishReady(_ granted: Bool) {
    let callback = ready
    ready = nil
    callback?(granted)
  }

  private func finishStopped(_ confirmed: Bool) {
    shutdownKeepAlive = nil
    let callbacks = stopped
    stopped = []
    callbacks.forEach { $0(confirmed) }
  }
}

/// Native channel callbacks can arrive through cancellation and permission
/// paths; consume a reply before exposing it to a reentrant Flutter caller.
final class CameraOnceReply<Value> {
  private var callback: ((Value) -> Void)?
  init(_ callback: @escaping (Value) -> Void) { self.callback = callback }
  func finish(_ value: Value) {
    precondition(Thread.isMainThread)
    let reply = callback
    callback = nil
    reply?(value)
  }
}
