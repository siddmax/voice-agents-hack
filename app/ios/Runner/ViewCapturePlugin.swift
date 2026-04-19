import AVFoundation
import Flutter
import UIKit

final class ViewCapturePlugin: NSObject, FlutterPlugin {
  private let writerQueue = DispatchQueue(label: "com.siddmax.syndai.view-capture.writer")
  private var captureTimer: DispatchSourceTimer?
  private var ringBuffer: [(timestamp: CFTimeInterval, jpeg: Data)] = []
  private let maxBufferSeconds: Double = 60
  private let captureInterval: Double = 1.0 / 3.0
  private var isWarmed = false
  private var frameCount = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "syndai_view_capture",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(ViewCapturePlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "warmUp":
      warmUp(result: result)
    case "flush":
      flush(result: result)
    case "coolDown":
      coolDown(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func warmUp(result: @escaping FlutterResult) {
    guard !isWarmed else {
      result(true)
      return
    }

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: captureInterval)
    timer.setEventHandler { [weak self] in
      self?.captureFrame()
    }
    timer.resume()
    captureTimer = timer
    isWarmed = true
    result(true)
  }

  private func captureFrame() {
    guard isWarmed else { return }
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow })
    else { return }

    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
    let image = renderer.image { ctx in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
    }

    guard let jpeg = image.jpegData(compressionQuality: 0.5) else { return }

    let now = CACurrentMediaTime()
    writerQueue.async { [weak self] in
      guard let self = self else { return }
      self.ringBuffer.append((timestamp: now, jpeg: jpeg))
      self.frameCount += 1
      let cutoff = now - self.maxBufferSeconds
      self.ringBuffer.removeAll { $0.timestamp < cutoff }
    }
  }

  private func flush(result: @escaping FlutterResult) {
    writerQueue.async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async { result("") }
        return
      }
      let frames = self.ringBuffer
      guard !frames.isEmpty else {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "NO_FRAMES",
            message: "Ring buffer is empty. No frames were captured.",
            details: nil
          ))
        }
        return
      }
      self.encodeToMP4(frames: frames) { path in
        DispatchQueue.main.async { result(path) }
      }
    }
  }

  private func encodeToMP4(
    frames: [(timestamp: CFTimeInterval, jpeg: Data)],
    completion: @escaping (String) -> Void
  ) {
    let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    let fileName = "voicebug_repro_\(Int(Date().timeIntervalSince1970 * 1000)).mp4"
    let outputURL = URL(fileURLWithPath: documentsPath).appendingPathComponent(fileName)

    if FileManager.default.fileExists(atPath: outputURL.path) {
      try? FileManager.default.removeItem(at: outputURL)
    }

    guard let firstImage = UIImage(data: frames[0].jpeg) else {
      completion("")
      return
    }

    let width = Int(firstImage.size.width * firstImage.scale)
    let height = Int(firstImage.size.height * firstImage.scale)

    guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
      completion("")
      return
    }

    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
    ]
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    writerInput.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: writerInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ]
    )

    guard writer.canAdd(writerInput) else {
      completion("")
      return
    }
    writer.add(writerInput)

    guard writer.startWriting() else {
      completion("")
      return
    }
    writer.startSession(atSourceTime: .zero)

    let baseTimestamp = frames[0].timestamp
    let fps = 3.0

    for frame in frames {
      autoreleasepool {
        guard let image = UIImage(data: frame.jpeg),
              let cgImage = image.cgImage
        else { return }

        let elapsed = frame.timestamp - baseTimestamp
        let presentationTime = CMTime(seconds: elapsed, preferredTimescale: CMTimeScale(fps * 600))

        while !writerInput.isReadyForMoreMediaData {
          Thread.sleep(forTimeInterval: 0.01)
        }

        guard let pool = adaptor.pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
          data: CVPixelBufferGetBaseAddress(buffer),
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        adaptor.append(buffer, withPresentationTime: presentationTime)
      }
    }

    writerInput.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()

    if writer.status == .completed {
      completion(outputURL.path)
    } else {
      completion("")
    }
  }

  private func coolDown(result: @escaping FlutterResult) {
    captureTimer?.cancel()
    captureTimer = nil
    isWarmed = false
    writerQueue.async { [weak self] in
      self?.ringBuffer.removeAll()
      self?.frameCount = 0
      DispatchQueue.main.async { result(nil) }
    }
  }
}
