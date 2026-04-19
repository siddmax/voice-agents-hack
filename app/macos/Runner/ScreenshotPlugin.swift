import Cocoa
import FlutterMacOS
import CoreGraphics

class ScreenshotPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.voicebug/screenshot",
            binaryMessenger: registrar.messenger
        )
        let instance = ScreenshotPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "capture":
            captureScreen(result: result)
        case "checkPermission":
            if #available(macOS 10.15, *) {
                result(CGPreflightScreenCaptureAccess())
            } else {
                result(true)
            }
        case "requestPermission":
            if #available(macOS 10.15, *) {
                let granted = CGRequestScreenCaptureAccess()
                result(granted)
            } else {
                result(true)
            }
        case "openSettings":
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func captureScreen(result: @escaping FlutterResult) {
        guard let cgImage = CGWindowListCreateImage(
            CGRect.null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.boundsIgnoreFraming]
        ) else {
            result(FlutterError(code: "CAPTURE_FAILED", message: "CGWindowListCreateImage returned nil", details: nil))
            return
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            result(FlutterError(code: "ENCODE_FAILED", message: "PNG encoding failed", details: nil))
            return
        }

        result(FlutterStandardTypedData(bytes: pngData))
    }
}
