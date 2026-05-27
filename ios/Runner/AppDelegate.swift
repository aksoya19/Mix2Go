import Flutter
import UIKit
import AVFoundation
import ObjectiveC

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // ── iOS 26 beta VSync crash workaround ────────────────────────────────
    // FlutterViewController.createTouchRateCorrectionVSyncClientIfNeeded
    // null-dereferences at offset 420 (EXC_BAD_ACCESS) on every cold launch
    // on iOS 26 beta. Swizzle it to a no-op before Flutter initialises.
    AppDelegate.swizzleVSyncClientCreation()

    // ── Audio session ─────────────────────────────────────────────────────
    // Plain playback — raw audio path, no mic, no AEC, no DSP.
    // .allowBluetooth + .allowBluetoothA2DP enable Bluetooth output.
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback,
        mode: .default,
        options: [.allowBluetooth, .allowBluetoothA2DP]
      )
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("[AppDelegate] AVAudioSession setup failed: \(error)")
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: – iOS 26 VSync crash workaround

  private static var swizzled = false

  private static func swizzleVSyncClientCreation() {
    guard !swizzled else { return }
    swizzled = true

    guard let cls = NSClassFromString("FlutterViewController") else { return }
    let originalSel    = NSSelectorFromString("createTouchRateCorrectionVSyncClientIfNeeded")
    let replacementSel = #selector(AppDelegate.noopVSync)

    guard let original    = class_getInstanceMethod(cls, originalSel),
          let replacement = class_getInstanceMethod(AppDelegate.self, replacementSel)
    else { return }

    method_exchangeImplementations(original, replacement)
  }

  @objc private func noopVSync() {}
}
