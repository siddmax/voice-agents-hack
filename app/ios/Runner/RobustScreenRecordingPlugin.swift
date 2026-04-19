import AVFoundation
import Flutter
import ReplayKit
import UIKit

final class RobustScreenRecordingPlugin: NSObject, FlutterPlugin {
  private let recorder = RPScreenRecorder.shared()
  private let writerQueue = DispatchQueue(label: "com.siddmax.syndai.screen-recording.writer")

  private var videoWriter: AVAssetWriter?
  private var videoWriterInput: AVAssetWriterInput?
  private var audioWriterInput: AVAssetWriterInput?
  private var videoOutputURL: URL?
  private var firstTimestamp: CMTime?
  private var isRecording = false
  private var isStopping = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "syndai_screen_recording",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(RobustScreenRecordingPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startRecordScreen":
      guard
        let args = call.arguments as? [String: Any],
        let name = args["name"] as? String
      else {
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing recording name", details: nil))
        return
      }
      let includeAudio = (args["audio"] as? Bool) ?? true
      startRecording(videoName: name, recordAudio: includeAudio, result: result)
    case "stopRecordScreen":
      stopRecording(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startRecording(
    videoName: String,
    recordAudio: Bool,
    result: @escaping FlutterResult
  ) {
    guard #available(iOS 11.0, *) else {
      result(FlutterError(code: "IOS_VERSION_ERROR", message: "Screen recording requires iOS 11 or later", details: nil))
      return
    }
    guard !isRecording && !isStopping else {
      result(FlutterError(code: "ALREADY_RECORDING", message: "Recording is already in progress", details: nil))
      return
    }

    do {
      try configureWriter(videoName: videoName, recordAudio: recordAudio)
    } catch {
      result(FlutterError(code: "FILE_ERROR", message: "Unable to create video file", details: error.localizedDescription))
      return
    }

    isRecording = true
    recorder.isMicrophoneEnabled = recordAudio
    recorder.startCapture(handler: { [weak self] sampleBuffer, sampleBufferType, error in
      guard let self = self, error == nil else { return }
      self.writerQueue.async {
        self.appendSampleBuffer(sampleBuffer, type: sampleBufferType, recordAudio: recordAudio)
      }
    }) { [weak self] error in
      guard let self = self else { return }
      if let error {
        self.writerQueue.async {
          self.videoWriter?.cancelWriting()
          DispatchQueue.main.async {
            self.resetRecordingState()
            result(FlutterError(code: "CAPTURE_ERROR", message: "Failed to start screen recording", details: error.localizedDescription))
          }
        }
      } else {
        result(true)
      }
    }
  }

  private func configureWriter(videoName: String, recordAudio: Bool) throws {
    let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    let outputURL = URL(fileURLWithPath: documentsPath).appendingPathComponent("\(videoName).mp4")
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let scale = UIScreen.main.scale
    let bounds = UIScreen.main.bounds
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(bounds.width * scale),
      AVVideoHeightKey: Int(bounds.height * scale)
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = true
    guard writer.canAdd(videoInput) else {
      throw NSError(domain: "RobustScreenRecordingPlugin", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Unable to add video writer input"
      ])
    }
    writer.add(videoInput)

    var audioInput: AVAssetWriterInput?
    if recordAudio {
      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128000
      ]
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      input.expectsMediaDataInRealTime = true
      if writer.canAdd(input) {
        writer.add(input)
        audioInput = input
      }
    }

    videoWriter = writer
    videoWriterInput = videoInput
    audioWriterInput = audioInput
    videoOutputURL = outputURL
    firstTimestamp = nil
  }

  private func appendSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    type: RPSampleBufferType,
    recordAudio: Bool
  ) {
    guard isRecording && !isStopping else { return }
    switch type {
    case .video:
      appendVideoBuffer(sampleBuffer)
    case .audioMic:
      if recordAudio {
        appendAudioBuffer(sampleBuffer)
      }
    default:
      break
    }
  }

  private func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard let writer = videoWriter, let input = videoWriterInput else { return }
    if writer.status == .unknown {
      let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      firstTimestamp = timestamp
      if writer.startWriting() {
        writer.startSession(atSourceTime: timestamp)
      }
    }
    if writer.status == .writing && input.isReadyForMoreMediaData {
      input.append(sampleBuffer)
    }
  }

  private func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard
      let writer = videoWriter,
      writer.status == .writing,
      let input = audioWriterInput,
      input.isReadyForMoreMediaData
    else {
      return
    }
    input.append(sampleBuffer)
  }

  private func stopRecording(result: @escaping FlutterResult) {
    guard #available(iOS 11.0, *) else {
      result(FlutterError(code: "IOS_VERSION_ERROR", message: "Screen recording requires iOS 11 or later", details: nil))
      return
    }
    guard isRecording || isStopping else {
      result("")
      return
    }
    guard !isStopping else {
      result(FlutterError(code: "STOPPING", message: "Recording is already stopping", details: nil))
      return
    }

    isStopping = true
    isRecording = false
    recorder.stopCapture { [weak self] stopError in
      guard let self = self else { return }
      self.writerQueue.async {
        self.finishWriting(stopError: stopError, result: result)
      }
    }
  }

  private func finishWriting(stopError: Error?, result: @escaping FlutterResult) {
    guard let writer = videoWriter else {
      completeStop(result: result, value: "", error: stopError)
      return
    }

    switch writer.status {
    case .unknown:
      writer.cancelWriting()
      completeStop(result: result, value: "", error: stopError)
    case .writing:
      videoWriterInput?.markAsFinished()
      audioWriterInput?.markAsFinished()
      writer.finishWriting { [weak self] in
        guard let self = self else { return }
        let writerError = writer.error ?? stopError
        let value = writer.status == .completed ? (self.videoOutputURL?.path ?? "") : ""
        self.completeStop(result: result, value: value, error: writerError)
      }
    case .completed:
      completeStop(result: result, value: videoOutputURL?.path ?? "", error: stopError)
    case .failed:
      completeStop(result: result, value: "", error: writer.error ?? stopError)
    case .cancelled:
      completeStop(result: result, value: "", error: stopError)
    @unknown default:
      writer.cancelWriting()
      completeStop(result: result, value: "", error: stopError)
    }
  }

  private func completeStop(result: @escaping FlutterResult, value: String, error: Error?) {
    DispatchQueue.main.async {
      self.resetRecordingState()
      if let error {
        result(FlutterError(code: "STOP_ERROR", message: "Failed to stop screen recording", details: error.localizedDescription))
      } else {
        result(value)
      }
    }
  }

  private func resetRecordingState() {
    videoWriter = nil
    videoWriterInput = nil
    audioWriterInput = nil
    videoOutputURL = nil
    firstTimestamp = nil
    isRecording = false
    isStopping = false
  }
}
