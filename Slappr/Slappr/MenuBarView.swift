import SwiftUI

struct MenuBarView: View {

    @ObservedObject var accelerometer: AccelerometerManager
    @ObservedObject var soundPlayer: SoundPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Header
            HStack {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                Text("Slappr")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
            }

            Divider()

            // Status
            HStack {
                Circle()
                    .fill(accelerometer.isMonitoring ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(accelerometer.isMonitoring ? "Мониторинг активен" : "Мониторинг выключен")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Toggle
            Toggle(isOn: Binding(
                get: { accelerometer.isMonitoring },
                set: { _ in accelerometer.toggleMonitoring() }
            )) {
                Text("Включить детекцию")
            }
            .toggleStyle(.switch)

            Divider()

            // Sensitivity slider
            VStack(alignment: .leading, spacing: 4) {
                Text("Чувствительность")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Высокая")
                        .font(.caption2)
                    Slider(
                        value: $accelerometer.sensitivity,
                        in: 0.5...4.0,
                        step: 0.1
                    )
                    Text("Низкая")
                        .font(.caption2)
                }

                Text("Порог: \(String(format: "%.1f", accelerometer.sensitivity))g")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Current acceleration
            if accelerometer.isMonitoring {
                HStack {
                    Text("Ускорение:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(String(format: "%.2f", accelerometer.lastMagnitude))g")
                        .font(.caption)
                        .monospacedDigit()
                }
            }

            Divider()

            // Sound info
            HStack {
                Image(systemName: "speaker.wave.2")
                    .foregroundColor(.secondary)
                Text("\(soundPlayer.soundCount) звуков загружено")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Test button
            Button {
                soundPlayer.playRandomSound()
            } label: {
                HStack {
                    Image(systemName: "play.circle")
                    Text("Тест звука")
                }
            }

            Divider()

            // Quit
            Button {
                accelerometer.stopMonitoring()
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Выход")
                }
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 260)
    }
}
