import SwiftUI

struct ContentView: View {
    @StateObject private var controller = BeeController()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(action: toggle) {
                        Text(controller.isRunning ? "Stop" : "Start")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.isRunning ? .red : .accentColor)

                    Button("Re-center forward") {
                        controller.recenter()
                    }
                    .disabled(!controller.isRunning || controller.autoOrbit)
                } footer: {
                    Text("Hold the phone pointing straight ahead of you and tap Re-center. The insect then goes wherever you point.")
                }

                Section("Insect") {
                    Picker("Species", selection: $controller.species) {
                        ForEach(InsectSpecies.allCases) { species in
                            Text(species.label).tag(species)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading) {
                        Text("Distance \(controller.radius, specifier: "%.2f") m")
                        Slider(value: $controller.radius, in: 0.15...3.0)
                    }

                    VStack(alignment: .leading) {
                        Text("Bandwidth \(controller.bandwidthHz / 1000, specifier: "%.1f") kHz")
                        Slider(value: $controller.bandwidthHz, in: 1_000...16_000, step: 100)
                        Text("Up-down cues live above about 5 kHz. Lower this and elevation should collapse to left-right.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Control") {
                    Picker("Pointing axis", selection: $controller.pointingAxis) {
                        ForEach(PointingAxis.allCases) { axis in
                            Text(axis.label).tag(axis)
                        }
                    }

                    Toggle("Auto-orbit", isOn: $controller.autoOrbit)

                    if controller.autoOrbit {
                        VStack(alignment: .leading) {
                            Text("Orbit rate \(controller.orbitRate, specifier: "%.2f") rev/s")
                            Slider(value: $controller.orbitRate, in: -0.5...0.5)
                        }
                    }
                }

                Section("Position") {
                    LabeledContent("Azimuth", value: String(format: "%+.0f°", controller.azimuthDegrees))
                    LabeledContent("Elevation", value: String(format: "%+.0f°", controller.elevationDegrees))
                    LabeledContent("Distance", value: String(format: "%.2f m", controller.distanceMeters))
                    CompassView(azimuthDegrees: controller.azimuthDegrees,
                                elevationDegrees: controller.elevationDegrees)
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                }

                Section("Status") {
                    LabeledContent("Audio", value: controller.audio.statusText)
                    LabeledContent("Output", value: controller.audio.outputRouteText)
                    if controller.audio.isRunning && !controller.audio.outputIsHeadphones {
                        Label("Headphones needed for 3D rendering", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("Motion", value: controller.motion.isAvailable ? "Available" : "Not available (orbit only)")
                }
            }
            .navigationTitle("Spatial Bee")
        }
    }

    private func toggle() {
        if controller.isRunning {
            controller.stop()
        } else {
            controller.start()
        }
    }
}

/// Top-down view of the head with a dot where the insect is. Dot size grows with elevation.
struct CompassView: View {
    let azimuthDegrees: Double
    let elevationDegrees: Double

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let ring = size * 0.42
            let theta = azimuthDegrees * .pi / 180
            let dot = CGPoint(x: center.x + ring * sin(theta), y: center.y - ring * cos(theta))
            let dotSize = 10 + 8 * max(0, elevationDegrees / 90)

            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.4), lineWidth: 1)
                    .frame(width: ring * 2, height: ring * 2)
                    .position(center)
                // Nose marker: straight ahead is up.
                Path { p in
                    p.move(to: CGPoint(x: center.x, y: center.y - ring))
                    p.addLine(to: CGPoint(x: center.x, y: center.y - ring - 8))
                }
                .stroke(.secondary, lineWidth: 2)
                Circle()
                    .fill(.secondary.opacity(0.25))
                    .frame(width: size * 0.22, height: size * 0.22)
                    .position(center)
                Text("You")
                    .font(.caption2)
                    .position(center)
                Circle()
                    .fill(elevationDegrees >= 0 ? Color.accentColor : Color.gray)
                    .frame(width: dotSize, height: dotSize)
                    .position(dot)
            }
        }
    }
}

#Preview {
    ContentView()
}
