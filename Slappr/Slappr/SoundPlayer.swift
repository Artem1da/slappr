import Foundation
import AppKit
import AVFoundation

/// Manages a collection of bundled sounds and plays a random one on demand.
final class SoundPlayer: ObservableObject {

    @Published var soundCount: Int = 0

    private var soundURLs: [URL] = []
    private var audioPlayer: AVAudioPlayer?

    private let supportedExtensions = ["mp3", "wav", "aiff", "m4a", "caf", "aac", "ogg"]

    init() {
        loadSounds()
    }

    /// Reload sounds from the app bundle's Sounds directory.
    func loadSounds() {
        soundURLs = []

        // Look for sounds in the bundle's Sounds directory
        guard let soundsDir = Bundle.main.resourceURL?.appendingPathComponent("Sounds") else {
            print("[Slappr] No Sounds directory found in bundle")
            soundCount = 0
            return
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: soundsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            soundURLs = files.filter { url in
                supportedExtensions.contains(url.pathExtension.lowercased())
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }

            soundCount = soundURLs.count
            print("[Slappr] Loaded \(soundCount) sounds from bundle")

        } catch {
            print("[Slappr] Error reading Sounds directory: \(error)")

            // Fallback: search the entire bundle for audio files
            for ext in supportedExtensions {
                if let urls = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) {
                    soundURLs.append(contentsOf: urls)
                }
            }
            soundCount = soundURLs.count
            print("[Slappr] Fallback: found \(soundCount) sounds in bundle root")
        }
    }

    /// Play a random sound from the collection.
    func playRandomSound() {
        guard !soundURLs.isEmpty else {
            print("[Slappr] No sounds available to play")
            playSystemBeep()
            return
        }

        let url = soundURLs.randomElement()!

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            print("[Slappr] Playing: \(url.lastPathComponent)")
        } catch {
            print("[Slappr] Error playing sound \(url.lastPathComponent): \(error)")
        }
    }

    /// Fallback: play system beep if no custom sounds available.
    private func playSystemBeep() {
        NSSound.beep()
    }
}
