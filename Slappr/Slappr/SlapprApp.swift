import SwiftUI

/// Shared app state that wires accelerometer to sound player.
final class AppState: ObservableObject {

    let accelerometer = AccelerometerManager()
    let soundPlayer = SoundPlayer()

    init() {
        accelerometer.onSlapDetected = { [weak self] in
            self?.soundPlayer.playRandomSound()
        }
        // Defer IOKit initialization until after the app's run loop is fully set up
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.accelerometer.startMonitoring()
        }
    }
}

@main
struct SlapprApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(accelerometer: appState.accelerometer, soundPlayer: appState.soundPlayer)
        } label: {
            Image(systemName: appState.accelerometer.isMonitoring ? "hand.raised.fill" : "hand.raised.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
