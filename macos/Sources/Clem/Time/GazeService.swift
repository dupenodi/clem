import AVFoundation
import Foundation
import Vision

/// Eyes-on-screen (opt-in): when the user goes input-idle (reading, watching),
/// grab a ~2s webcam burst and use on-device Vision face detection + head
/// pose to decide whether they're still looking at the screen. Frames are
/// analysed in memory and never stored or transmitted. The camera indicator
/// blinks briefly during a check; checks are throttled and only happen while
/// idle — never during normal typing/clicking.
@MainActor
final class GazeService {
    static let shared = GazeService()

    /// The synthetic activity label for "present but looking elsewhere" —
    /// always treated as a distraction by FocusService.
    nonisolated static let offScreenLabel = "Off-screen"

    enum Attention {
        case screen       // face found, head pointed at the display
        case away         // face found, head turned elsewhere (phone, TV, person)
        case absent       // nobody in front of the camera
        case unavailable  // no permission / no camera / check failed
    }

    private var lastResult: Attention = .unavailable
    private var lastCheckAt: Date?
    private var inFlight: Task<Attention, Never>?
    private let cacheTTL: TimeInterval = 45

    /// Current attention verdict, at most one camera burst per `cacheTTL`.
    func attention() async -> Attention {
        if let t = lastCheckAt, Date().timeIntervalSince(t) < cacheTTL { return lastResult }
        if let running = inFlight { return await running.value }
        let task = Task<Attention, Never> {
            let granted = await Self.ensureAccess()
            let result = granted ? await Self.sampleBurst() : .unavailable
            return result
        }
        inFlight = task
        let result = await task.value
        lastResult = result
        lastCheckAt = Date()
        inFlight = nil
        return result
    }

    private static func ensureAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private static func sampleBurst() async -> Attention {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let grabber = GazeFrameGrabber()
                let verdicts = grabber.capture(frames: 4, timeout: 2.5)
                cont.resume(returning: vote(verdicts))
            }
        }
    }

    /// Majority vote across the burst — bias toward "screen" so a single
    /// blurry frame can't turn a watcher into a wanderer.
    nonisolated private static func vote(_ verdicts: [Attention]) -> Attention {
        guard !verdicts.isEmpty else { return .unavailable }
        let screen = verdicts.filter { $0 == .screen }.count
        let away = verdicts.filter { $0 == .away }.count
        if screen >= max(1, verdicts.count / 2) { return .screen }
        if away >= max(1, verdicts.count / 2) { return .away }
        return .absent
    }
}

/// Opens the default camera at low resolution, classifies a handful of
/// frames, and shuts the session down immediately.
private final class GazeFrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var verdicts: [GazeService.Attention] = []
    private var frameCount = 0
    private var wanted = 0

    func capture(frames: Int, timeout: TimeInterval) -> [GazeService.Attention] {
        wanted = frames
        session.sessionPreset = .vga640x480
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return [] }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "clem.gaze.frames"))
        guard session.canAddOutput(output) else { return [] }
        session.addOutput(output)

        session.startRunning()
        _ = done.wait(timeout: .now() + timeout)
        session.stopRunning()

        lock.lock(); defer { lock.unlock() }
        return verdicts
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        // Skip the first frames (auto-exposure warm-up), then take every 3rd.
        guard frameCount > 6, frameCount % 3 == 0,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])

        let verdict: GazeService.Attention
        if let face = (request.results ?? []).max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) {
            let yaw = abs(face.yaw?.doubleValue ?? 0)
            let pitch = abs(face.pitch?.doubleValue ?? 0)
            // Head roughly toward the display → still watching/reading.
            verdict = (yaw <= 0.38 && pitch <= 0.32) ? .screen : .away
        } else {
            verdict = .absent
        }

        lock.lock()
        verdicts.append(verdict)
        let enough = verdicts.count >= wanted
        lock.unlock()
        if enough { done.signal() }
    }
}
