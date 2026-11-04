//
//  TripActivityShared.swift
//  Compiled into both the app and the TripWidget extension.
//

import Foundation
import ActivityKit
import AppIntents

enum TripPhase: String, Codable, Hashable {
    case idle, driving, stopped, parked, inside, walking, drivethru, done

    var symbol: String {
        switch self {
        case .idle: return "location"
        case .driving: return "car.fill"
        case .stopped: return "octagon.fill"
        case .parked: return "parkingsign.circle.fill"
        case .inside: return "building.2.fill"
        case .walking: return "figure.walk"
        case .drivethru: return "takeoutbag.and.cup.and.straw.fill"
        case .done: return "checkmark.circle.fill"
        }
    }
}

struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: TripPhase
        var title: String
        var detail: String
        var speedKmh: Int
        var progress: Double
        var eta: Date?
        var leaveAt: Date?
    }

    var tripName: String
}

/// "Stop" button on the Live Activity. Runs in the app process.
struct EndTripIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Trip"
    static var description = IntentDescription("Stops the trip and restores your real location.")

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await TripRunner.shared.stopAndClear()
        #endif
        return .result()
    }
}
