import Foundation

/// Cold-open admission only; an established session keeps its existing reconnect behavior.
struct ReceiverStartupGate {
  private(set) var listeningArmed = false
  private(set) var deadline: TimeInterval?

  mutating func configure(automatically: Bool, delaySeconds: Int, now: TimeInterval) {
    guard !listeningArmed else { return }
    deadline = automatically ? now + Double(min(max(delaySeconds, 0), 5)) : nil
  }

  @discardableResult
  mutating func connect() -> Bool {
    guard !listeningArmed else { return false }
    listeningArmed = true
    deadline = nil
    return true
  }

  mutating func advance(now: TimeInterval) -> Bool {
    guard let deadline, now >= deadline else { return false }
    return connect()
  }
}
