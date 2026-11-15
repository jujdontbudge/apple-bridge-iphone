import Foundation

@MainActor
enum CaptureCapability {
    static let descriptor = Capability(id: "capture", title: "Camera and microphone", permission: "Face ID, camera and microphone", available: false)
}
