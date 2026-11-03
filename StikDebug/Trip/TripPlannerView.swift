//
//  TripPlannerView.swift
//  StikDebug
//

import SwiftUI
import MapKit

struct TripPlannerView: View {
    @ObservedObject private var runner = TripRunner.shared

    @AppStorage("trip.home.name") private var homeName = ""
    @AppStorage("trip.home.lat") private var homeLat = 0.0
    @AppStorage("trip.home.lon") private var homeLon = 0.0
    @AppStorage("trip.dest.name") private var destName = ""
    @AppStorage("trip.dest.lat") private var destLat = 0.0
    @AppStorage("trip.dest.lon") private var destLon = 0.0
    @AppStorage("trip.stayMinutes") private var stayMinutes = 120.0
    @AppStorage("trip.driveBack") private var driveBack = true
    @AppStorage("trip.clearAtEnd") private var clearAtEnd = true
    @AppStorage(TripRunner.baseURLKey) private var baseURL = ""

    @State private var presets: [TripPreset] = []
    @State private var loadingPresets = false

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)
    }
    private var hasHome: Bool { !homeName.isEmpty }
    private var hasDest: Bool { !destName.isEmpty }

    var body: some View {
        Form {
            if !pairingExists {
                Text("Import a pairing file first (Settings).").foregroundStyle(.red)
            }

            if runner.isRunning || !runner.log.isEmpty {
                Section("Now") {
                    Text(runner.status).font(.headline)
                    if runner.isRunning {
                        Button("Stop & Use Real Location", role: .destructive) {
                            Task { await runner.stopAndClear() }
                        }
                    }
                }
            }

            Section("Places") {
                PlaceSearchRow(title: "Home", name: homeName) { name, c in
                    homeName = name; homeLat = c.latitude; homeLon = c.longitude
                }
                PlaceSearchRow(title: "Destination", name: destName) { name, c in
                    destName = name; destLat = c.latitude; destLon = c.longitude
                }
            }

            Section {
                Stepper("Stay \(TripRunner.duration(stayMinutes * 60))", value: $stayMinutes, in: 0...720, step: 15)
                Toggle("Drive back home", isOn: $driveBack)
                Toggle("Then use real location", isOn: $clearAtEnd)
                Button("Start Trip") { runner.runRemote(args: args) }
                    .disabled(runner.isRunning || !pairingExists || !hasHome || !hasDest)
            } header: {
                Text("Quick Trip")
            } footer: {
                Text("Starts at Home, drives to the destination with traffic and stops at lights, stays, then drives back.")
            }

            Section {
                if loadingPresets && presets.isEmpty {
                    ProgressView()
                } else if presets.isEmpty {
                    Text("No presets found").foregroundStyle(.secondary)
                }
                ForEach(presets) { preset in
                    Button {
                        runner.runRemote(file: preset.file, args: args)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            if let detail = preset.description {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(runner.isRunning || !pairingExists || !hasHome || (preset.needsDestination == true && !hasDest))
                }
            } header: {
                HStack {
                    Text("Presets")
                    Spacer()
                    Button("Refresh") { Task { await loadPresets() } }.font(.caption)
                }
            } footer: {
                Text("Presets are scripts in your GitHub trips folder. Edit or add them there; no reinstall needed.")
            }

            if !runner.log.isEmpty {
                Section("Log") {
                    ForEach(Array(runner.log.reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }

            Section("Advanced") {
                TextField(TripRunner.defaultBaseURL, text: $baseURL)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await loadPresets() } }
            }
        }
        .navigationTitle("Trip Planner")
        .task { await loadPresets() }
        .refreshable { await loadPresets() }
    }

    private var args: [String: Any] {
        [
            "home": ["lat": homeLat, "lon": homeLon, "name": homeName],
            "dest": ["lat": destLat, "lon": destLon, "name": destName],
            "stayMinutes": stayMinutes,
            "driveBack": driveBack,
            "clearAtEnd": clearAtEnd,
        ]
    }

    private func loadPresets() async {
        loadingPresets = true
        presets = await TripRunner.fetchPresets()
        loadingPresets = false
    }
}

/// Text field that searches Apple Maps and lets you pick a result.
private struct PlaceSearchRow: View {
    let title: String
    let name: String
    let onPick: (String, CLLocationCoordinate2D) -> Void

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(name.isEmpty ? "Not set" : name)
                    .font(.caption)
                    .foregroundStyle(name.isEmpty ? .red : .secondary)
                    .lineLimit(1)
            }
            TextField("Search \(title.lowercased())…", text: $query)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit(search)
            if searching { ProgressView() }
            ForEach(results, id: \.self) { item in
                Button {
                    onPick(item.name ?? query, item.placemark.coordinate)
                    results = []
                    query = ""
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.name ?? "Unknown")
                        Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func search() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        searching = true
        MKLocalSearch(request: request).start { response, _ in
            searching = false
            results = Array((response?.mapItems ?? []).prefix(5))
        }
    }
}
