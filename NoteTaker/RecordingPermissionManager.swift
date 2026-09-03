import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation

@MainActor
final class RecordingPermissionManager: ObservableObject {
    @Published private(set) var microphoneGranted = false
    @Published private(set) var systemAudioGranted = false
    @Published private(set) var isRequesting = false
    @Published private(set) var status = "Allow access before your first recording"

    var allAccessGranted: Bool {
        microphoneGranted && systemAudioGranted
    }

    init() {
        refresh()
    }

    func refresh() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        systemAudioGranted = CGPreflightScreenCaptureAccess()

        if allAccessGranted {
            status = "Microphone and system audio are ready"
        }
    }

    func requestAccess() async {
        guard !isRequesting else { return }
        isRequesting = true
        status = "Requesting recording access..."
        defer { isRequesting = false }

        microphoneGranted = await requestMicrophoneAccess()

        if CGPreflightScreenCaptureAccess() {
            systemAudioGranted = true
        } else {
            systemAudioGranted = CGRequestScreenCaptureAccess()
        }

        refresh()
        status = allAccessGranted
            ? "Microphone and system audio are ready"
            : "Finish approval in Privacy & Security, then return to NoteTaker"
    }

    func openPrivacySettings() {
        let pane = microphoneGranted ? "Privacy_ScreenCapture" : "Privacy_Microphone"
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
