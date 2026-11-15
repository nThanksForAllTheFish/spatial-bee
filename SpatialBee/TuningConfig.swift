import Foundation

/// Everything about the sound that is a number rather than code. Served as
/// `docs/config.json` from the GitHub Pages site so a change reaches the phone with a
/// push and a tap on Reload instead of a TestFlight cycle. Defaults here match the
/// shipped JSON so the app behaves sensibly offline.
struct TuningConfig: Codable, Equatable {
    struct Distance: Codable, Equatable {
        var referenceDistance: Double = 0.25
        var maximumDistance: Double = 6.0
        var rolloffFactor: Double = 1.2
    }
    struct Wobble: Codable, Equatable {
        var limitCm: Double = 8
        var stepCm: Double = 2
    }
    struct HighShelf: Codable, Equatable {
        var frequencyHz: Double = 5000
        var gainDb: Double = 0
    }
    struct Training: Codable, Equatable {
        /// Remote distance from the head, meters.
        var remoteRadius: Double = 1.0
        /// Angular speed of a dart, degrees per second.
        var remoteSpeedDegPerSec: Double = 150
        var hoverSecondsMin: Double = 0.8
        var hoverSecondsMax: Double = 2.5
        /// Warning time from the charge cue to the bolt.
        var chargeSeconds: Double = 0.9
        /// Half-angle of the block cone, degrees.
        var blockConeDeg: Double = 25
        var boltsPerRound: Int = 10
        var elevationMinDeg: Double = -25
        var elevationMaxDeg: Double = 60
        var resolveSeconds: Double = 0.8
        var remoteGain: Double = 0.25
        var remoteF0: Double = 520
        var remoteHarmonicCount: Int = 24
        var remoteHarmonicRolloff: Double = 0.9
        var remoteHissLevel: Double = 0.14
        var remoteHissLowHz: Double = 2500
        var remoteHissCutoffHz: Double = 11_000
        /// Hilt hum level.
        var saberHumGain: Double = 0.12
        /// Hilt sits this far from the head along the pointing direction.
        var saberRadius: Double = 0.35
        /// Blade length; the tip source sits at saberRadius + saberLength.
        var saberLength: Double = 1.1
        var saberTipGain: Double = 0.18
        var saberFizzLevel: Double = 0.5
        var saberSwingLevel: Double = 0.6
        /// Angular speed, degrees per second, that counts as a full swing.
        var saberSwingFullDegPerSec: Double = 300
    }

    struct Species: Codable, Equatable {
        var f0: Double
        var harmonicCount: Int
        var harmonicRolloff: Double
        var noiseLevel: Double
        var noiseCutoffHz: Double
        var pitchWander: Double
    }

    var version: Int = 1
    var renderer: String = "hrtfHQ"
    var gain: Double = 0.22
    var reverbBlend: Double = 0.12
    var reverbLevelDb: Double = -24
    var distance = Distance()
    var wobble = Wobble()
    var highShelf = HighShelf()
    var training = Training()
    var species: [String: Species] = [
        "bee": Species(f0: 230, harmonicCount: 40, harmonicRolloff: 0.8, noiseLevel: 0.18, noiseCutoffHz: 9000, pitchWander: 0.05),
        "mosquito": Species(f0: 620, harmonicCount: 16, harmonicRolloff: 1.0, noiseLevel: 0.06, noiseCutoffHz: 10000, pitchWander: 0.08),
    ]

    static let defaults = TuningConfig()

    func species(_ s: InsectSpecies) -> Species {
        species[s.rawValue] ?? TuningConfig.defaults.species[s.rawValue]!
    }

    // Unknown keys in the JSON (such as "note") are ignored by Codable. Missing keys
    // fall back to the defaults through this initializer.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TuningConfig.defaults
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        renderer = try c.decodeIfPresent(String.self, forKey: .renderer) ?? d.renderer
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? d.gain
        reverbBlend = try c.decodeIfPresent(Double.self, forKey: .reverbBlend) ?? d.reverbBlend
        reverbLevelDb = try c.decodeIfPresent(Double.self, forKey: .reverbLevelDb) ?? d.reverbLevelDb
        distance = try c.decodeIfPresent(Distance.self, forKey: .distance) ?? d.distance
        wobble = try c.decodeIfPresent(Wobble.self, forKey: .wobble) ?? d.wobble
        highShelf = try c.decodeIfPresent(HighShelf.self, forKey: .highShelf) ?? d.highShelf
        training = try c.decodeIfPresent(Training.self, forKey: .training) ?? d.training
        species = try c.decodeIfPresent([String: Species].self, forKey: .species) ?? d.species
    }
}

/// Fetches the config from the Pages site, cache-busted, with a short timeout.
enum TuningConfigLoader {
    static let url = URL(string: "https://nthanksforallthefish.github.io/spatial-bee/config.json")!

    static func fetch() async throws -> TuningConfig {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(TuningConfig.self, from: data)
    }
}
