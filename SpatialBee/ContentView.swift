import SwiftUI

struct ContentView: View {
    @StateObject private var controller = BeeController()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $controller.mode) {
                        ForEach(AppMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

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
                    .disabled(!controller.isRunning || (controller.mode == .explore && controller.autoOrbit))
                } footer: {
                    Text(controller.headTracking
                         ? "Look straight ahead with the phone pointing the same way, then tap Re-center. Re-center again if it drifts."
                         : "Hold the phone pointing straight ahead of you and tap Re-center.")
                }

                if controller.mode == .training {
                    trainingSection
                } else {
                    insectSection
                }

                Section("Control") {
                    Picker("Renderer", selection: $controller.renderer) {
                        ForEach(SpatialRenderer.allCases) { renderer in
                            Text(renderer.label).tag(renderer)
                        }
                    }

                    Picker("Pointing axis", selection: $controller.pointingAxis) {
                        ForEach(PointingAxis.allCases) { axis in
                            Text(axis.label).tag(axis)
                        }
                    }

                    Toggle("Head tracking (AirPods)", isOn: $controller.headTracking)
                        .disabled(!controller.head.isAvailable)

                    if controller.mode == .explore {
                        Toggle("Auto-orbit", isOn: $controller.autoOrbit)
                        if controller.autoOrbit {
                            VStack(alignment: .leading) {
                                Text("Orbit rate \(controller.orbitRate, specifier: "%.2f") rev/s")
                                Slider(value: $controller.orbitRate, in: -0.5...0.5)
                            }
                        }
                    }
                }

                tuningSection

                Section("Position") {
                    LabeledContent(controller.mode == .training ? "Remote azimuth" : "Azimuth",
                                   value: String(format: "%+.0f°", controller.azimuthDegrees))
                    LabeledContent(controller.mode == .training ? "Remote elevation" : "Elevation",
                                   value: String(format: "%+.0f°", controller.elevationDegrees))
                    if controller.mode == .training {
                        LabeledContent("Saber azimuth", value: String(format: "%+.0f°", controller.saberAzimuthDegrees))
                        LabeledContent("Saber elevation", value: String(format: "%+.0f°", controller.saberElevationDegrees))
                        LabeledContent("Saber error", value: String(format: "%.0f°", controller.game.saberErrorDeg))
                    } else {
                        LabeledContent("Distance", value: String(format: "%.2f m", controller.distanceMeters))
                    }
                    if controller.headTracking {
                        LabeledContent("Head yaw", value: String(format: "%+.0f°", controller.headYawDegrees))
                        LabeledContent("Head pitch", value: String(format: "%+.0f°", controller.headPitchDegrees))
                    }
                    CompassView(azimuthDegrees: controller.azimuthDegrees,
                                elevationDegrees: controller.elevationDegrees,
                                headYawDegrees: controller.headTracking ? controller.headYawDegrees : 0,
                                saberAzimuthDegrees: controller.mode == .training ? controller.saberAzimuthDegrees : nil,
                                charging: controller.game.phase == .charging)
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
                    LabeledContent("Head", value: controller.head.sampleRateHz > 0
                                   ? String(format: "%@ · %.0f Hz", controller.head.status, controller.head.sampleRateHz)
                                   : controller.head.status)
                }
            }
            .navigationTitle(controller.mode == .training ? "Jedi Training" : "Spatial Bee")
        }
        .overlay { blastShieldOverlay }
    }

    // MARK: Sections

    private var insectSection: some View {
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
    }

    private var trainingSection: some View {
        Section {
            let game = controller.game
            let active = game.phase != .idle && game.phase != .roundOver
            Button(action: { active ? controller.abortRound() : controller.startRound() }) {
                Text(active ? "Abort round" : "Start round")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!controller.isRunning)

            LabeledContent("Remote", value: game.statusText)
            LabeledContent("Bolts", value: "\(game.boltsFired) / \(controller.config.training.boltsPerRound)")
            LabeledContent("Blocked", value: "\(game.score)")
            LabeledContent("Streak", value: "\(game.streak) (best \(game.bestStreak))")

            Toggle("Saber hum", isOn: $controller.saberHum)
            Toggle("Blast shield", isOn: $controller.blastShield)

            if game.phase == .roundOver, !game.shots.isEmpty {
                DisclosureGroup("Results") {
                    ForEach(game.shots) { shot in
                        HStack {
                            Text("Bolt \(shot.index)")
                            Spacer()
                            Text(shot.blocked ? "Blocked" : "Hit")
                                .foregroundStyle(shot.blocked ? .green : .red)
                            Text(shot.reactionMs.map { "\($0) ms" } ?? String(format: "%.0f° off", shot.errorDeg))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.footnote)
                    }
                    let times = game.shots.compactMap { $0.reactionMs }
                    if !times.isEmpty {
                        LabeledContent("Mean reaction", value: "\(times.reduce(0, +) / times.count) ms")
                            .font(.footnote)
                    }
                }
            }
        } header: {
            Text("Training")
        } footer: {
            Text("The remote darts around you and hovers. When you hear it charge, point the phone at it before it fires. Blast shield blanks the screen; double-tap to lift it.")
        }
    }

    private var tuningSection: some View {
        Section {
            HStack {
                Button(controller.configLoading ? "Loading…" : "Reload config") {
                    Task { await controller.reloadConfig() }
                }
                .disabled(controller.configLoading)
                Spacer()
                Button("Reset") { controller.resetToLoadedConfig() }
            }
            Text(controller.configStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if controller.mode == .training {
                tuningSlider("Charge warning", value: $controller.chargeSeconds, range: 0.3...2.5, format: "%.2f s", step: 0.05)
                tuningSlider("Block cone", value: $controller.blockConeDeg, range: 5...60, format: "%.0f°", step: 1)
                tuningSlider("Remote speed", value: $controller.remoteSpeed, range: 30...400, format: "%.0f °/s", step: 10)
                tuningSlider("Remote gain", value: $controller.remoteGain, range: 0.05...0.6, format: "%.2f")
                tuningSlider("Remote hiss", value: $controller.remoteHiss, range: 0...0.5, format: "%.2f")
                tuningSlider("Remote rolloff", value: $controller.remoteRolloff, range: 0.3...2.0, format: "%.2f")
                tuningSlider("Saber hilt hum", value: $controller.saberHumGain, range: 0...0.4, format: "%.2f")
                tuningSlider("Saber tip", value: $controller.saberTipGain, range: 0...0.5, format: "%.2f")
                tuningSlider("Saber fizz", value: $controller.saberFizz, range: 0...1.0, format: "%.2f")
            } else {
                tuningSlider("Gain", value: $controller.gain, range: 0.05...0.6, format: "%.2f")
                tuningSlider("High-shelf gain", value: $controller.shelfGainDb, range: -12...12, format: "%+.0f dB", step: 1)
                tuningSlider("High-shelf from", value: $controller.shelfFrequencyHz, range: 2000...10000, format: "%.0f Hz", step: 250)
                tuningSlider("Harmonic rolloff", value: $controller.harmonicRolloff, range: 0.3...2.0, format: "%.2f")
                tuningSlider("Noise level", value: $controller.noiseLevel, range: 0...0.5, format: "%.2f")
                tuningSlider("Wobble", value: $controller.wobbleLimitCm, range: 0...20, format: "%.0f cm", step: 1)
            }
            tuningSlider("Reverb blend", value: $controller.reverbBlend, range: 0...0.5, format: "%.2f")
        } header: {
            Text("Tuning")
        } footer: {
            Text("Values come from config.json on the Pages site. Sliders edit them live; Reload fetches the published file again.")
        }
    }

    @ViewBuilder
    private var blastShieldOverlay: some View {
        if controller.blastShield {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 12) {
                    Text("Blast shield down")
                        .font(.headline)
                        .foregroundStyle(.gray)
                    Text(controller.game.statusText)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    Text("Blocked \(controller.game.score) of \(controller.game.boltsFired)")
                        .foregroundStyle(.gray)
                        .monospacedDigit()
                    Text("Double-tap to lift")
                        .font(.footnote)
                        .foregroundStyle(.gray)
                        .padding(.top, 24)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { controller.blastShield = false }
        }
    }

    private func toggle() {
        if controller.isRunning {
            controller.stop()
        } else {
            controller.start()
        }
    }

    @ViewBuilder
    private func tuningSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                              format: String, step: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
    }
}

/// Top-down view of the head. Dot: the insect or the remote, size growing with
/// elevation, red while the remote charges. Blue nose: where the head faces. Thin line:
/// where the saber points.
struct CompassView: View {
    let azimuthDegrees: Double
    let elevationDegrees: Double
    var headYawDegrees: Double = 0
    var saberAzimuthDegrees: Double? = nil
    var charging = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let ring = size * 0.42
            let theta = azimuthDegrees * .pi / 180
            let dot = CGPoint(x: center.x + ring * sin(theta), y: center.y - ring * cos(theta))
            let dotSize = 10 + 8 * max(0, elevationDegrees / 90)
            let nose = headYawDegrees * .pi / 180
            let noseInner = CGPoint(x: center.x + (size * 0.11) * sin(nose), y: center.y - (size * 0.11) * cos(nose))
            let noseOuter = CGPoint(x: center.x + (size * 0.11 + 10) * sin(nose), y: center.y - (size * 0.11 + 10) * cos(nose))

            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.4), lineWidth: 1)
                    .frame(width: ring * 2, height: ring * 2)
                    .position(center)
                Path { p in
                    p.move(to: CGPoint(x: center.x, y: center.y - ring))
                    p.addLine(to: CGPoint(x: center.x, y: center.y - ring - 8))
                }
                .stroke(.secondary, lineWidth: 2)
                if let saber = saberAzimuthDegrees {
                    let phi = saber * .pi / 180
                    Path { p in
                        p.move(to: center)
                        p.addLine(to: CGPoint(x: center.x + ring * sin(phi), y: center.y - ring * cos(phi)))
                    }
                    .stroke(.orange.opacity(0.8), lineWidth: 2)
                }
                Path { p in
                    p.move(to: noseInner)
                    p.addLine(to: noseOuter)
                }
                .stroke(Color.accentColor, lineWidth: 3)
                Circle()
                    .fill(.secondary.opacity(0.25))
                    .frame(width: size * 0.22, height: size * 0.22)
                    .position(center)
                Text("You")
                    .font(.caption2)
                    .position(center)
                Circle()
                    .fill(charging ? Color.red : (elevationDegrees >= 0 ? Color.accentColor : Color.gray))
                    .frame(width: dotSize, height: dotSize)
                    .position(dot)
            }
        }
    }
}

#Preview {
    ContentView()
}
