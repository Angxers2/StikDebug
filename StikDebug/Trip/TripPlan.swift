//
//  TripPlan.swift
//  StikDebug
//
//  The saved trip setup (places, stops, toggles) shared by the Trip Planner and Shortcuts.
//

import Foundation
import CoreLocation

struct TripPlace: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double
    var kind: StopKind = .quick
    var minutes: Double = 5

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    init(name: String, coordinate: CLLocationCoordinate2D, kind: StopKind = .quick) {
        self.name = name
        lat = coordinate.latitude
        lon = coordinate.longitude
        self.kind = kind
        minutes = kind.defaultMinutes
    }

    var jsValue: [String: Any] {
        ["lat": lat, "lon": lon, "name": name, "kind": kind.rawValue, "minutes": minutes]
    }
}

enum StopKind: String, Codable, CaseIterable, Identifiable {
    case driveThru, quick, inside, gas
    var id: String { rawValue }

    var title: String {
        switch self {
        case .driveThru: return "Drive-thru"
        case .quick: return "Wait in car"
        case .inside: return "Go inside"
        case .gas: return "Gas"
        }
    }

    var symbol: String {
        switch self {
        case .driveThru: return "takeoutbag.and.cup.and.straw.fill"
        case .quick: return "car.fill"
        case .inside: return "building.2.fill"
        case .gas: return "fuelpump.fill"
        }
    }

    var defaultMinutes: Double {
        switch self {
        case .driveThru: return 8
        case .quick: return 5
        case .inside: return 20
        case .gas: return 7
        }
    }
}

enum StartMode: String, Codable, CaseIterable, Identifiable {
    case home, current
    var id: String { rawValue }
    var title: String { self == .home ? "Home" : "Current location" }
}

struct WalkPoint: Codable, Hashable {
    var lat: Double
    var lon: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

struct TripPlan: Codable {
    var home: TripPlace?
    var startMode: StartMode = .home
    var stops: [TripPlace] = []
    var dest: TripPlace?
    var stayMinutes: Double = 120
    var startInside = true          // walk out of the building to the car first
    var enterBuilding = true        // go inside at the destination (vs. wait in the car)
    var driveBack = true
    var clearAtEnd = true
    var realWithin: Double = 300    // switch to real location when coming within this of the handover point (0 = off)
    var handoverAtStart = true      // handover point: the trip's start, or `handover`
    var handover: TripPlace?
    var realSignals = true
    var traffic = true
    var walkPath: [WalkPoint] = []
    var walkSpeed: Double = 1.4
    var walkLoop = false

    private static let key = "trip.plan.v2"

    static func load() -> TripPlan {
        guard let data = UserDefaults.standard.data(forKey: key),
              let plan = try? JSONDecoder().decode(TripPlan.self, from: data) else { return TripPlan() }
        return plan
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// `trip.args` for the scripts. `start` is Home or the real current location.
    func args(start: TripPlace) -> [String: Any] {
        [
            "start": start.jsValue,
            "home": (home ?? start).jsValue,
            "stops": stops.map(\.jsValue),
            "dest": dest?.jsValue ?? start.jsValue,
            "stayMinutes": stayMinutes,
            "startInside": startInside,
            "enterBuilding": enterBuilding,
            "driveBack": driveBack,
            "clearAtEnd": clearAtEnd,
            "realWithin": realWithin,
            "handover": (handoverAtStart ? start : (handover ?? start)).jsValue,
            "realSignals": realSignals,
            "traffic": traffic,
            "path": walkPath.map { ["lat": $0.lat, "lon": $0.lon] },
            "walkSpeed": walkSpeed,
            "walkLoop": walkLoop,
        ]
    }
}

/// One-shot read of the device's real location (only real while no simulation is active).
final class RealLocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    func fetch() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBest
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { self.finish(nil) }
        }
    }

    private func finish(_ coordinate: CLLocationCoordinate2D?) {
        continuation?.resume(returning: coordinate)
        continuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: finish(nil)
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}

extension TripRunner {
    /// Resolves the start (Home or real current location) and runs `file` with the saved plan.
    @MainActor
    func start(plan: TripPlan, file: String, name: String) async -> String? {
        var start = plan.home
        if plan.startMode == .current {
            if LocationSimulationSession.shared.isActive {
                return "Stop the current simulation first so your real location can be read."
            }
            guard let here = await RealLocationFetcher().fetch() else {
                return "Couldn't get your current location."
            }
            start = TripPlace(name: "Current location", coordinate: here)
        }
        guard let start else { return "Set Home first." }
        runRemote(file: file, name: name, args: plan.args(start: start))
        return nil
    }
}
