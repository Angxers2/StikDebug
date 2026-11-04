//
//  TripPlannerView.swift
//  StikDebug
//
//  Map-first trip planner: 3D follow camera, live traffic, route + live position,
//  tap-to-pin, freehand walking paths, and a draggable control sheet.
//

import SwiftUI
import MapKit

struct TripPlannerView: View {
    @ObservedObject private var runner = TripRunner.shared
    @State private var plan = TripPlan.load()

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var cameraHeading: Double = 0
    @State private var follow = true
    @State private var show3D = true
    @State private var showTraffic = true
    @State private var showSheet = false
    @State private var detent: PresentationDetent = .medium
    @State private var mode: Mode = .drive
    @State private var drawing = false
    @State private var droppedPin: TripPlace?
    @State private var message: String?

    enum Mode: String, CaseIterable, Identifiable {
        case drive = "Drive", walk = "Walk", presets = "Presets"
        var id: String { rawValue }
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if !runner.routeLine.isEmpty {
                    MapPolyline(coordinates: runner.routeLine)
                        .stroke(.blue.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                }
                if mode == .walk, plan.walkPath.count > 1, !runner.isRunning {
                    MapPolyline(coordinates: plan.walkPath.map(\.coordinate))
                        .stroke(.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: [8, 6]))
                }
                if let home = plan.home {
                    Marker("Home", systemImage: "house.fill", coordinate: home.coordinate).tint(.green)
                }
                ForEach(Array(plan.stops.enumerated()), id: \.element.id) { index, stop in
                    Marker("\(index + 1). \(stop.name)", systemImage: stop.kind.symbol, coordinate: stop.coordinate).tint(.orange)
                }
                if let dest = plan.dest {
                    Marker(dest.name, systemImage: "flag.checkered", coordinate: dest.coordinate).tint(.red)
                }
                if plan.realWithin > 0, let center = plan.handoverAtStart ? plan.home?.coordinate : plan.handover?.coordinate {
                    MapCircle(center: center, radius: plan.realWithin)
                        .foregroundStyle(.green.opacity(0.12))
                        .stroke(.green.opacity(0.6), lineWidth: 2)
                }
                if let pin = droppedPin {
                    Marker("Dropped pin", systemImage: "mappin", coordinate: pin.coordinate).tint(.purple)
                }
                if let position = runner.position {
                    Annotation("", coordinate: position, anchor: .center) {
                        PositionPuck(phase: runner.phase, rotation: runner.heading - cameraHeading)
                    }
                }
            }
            .mapStyle(.standard(elevation: show3D ? .realistic : .flat, pointsOfInterest: .all, showsTraffic: showTraffic))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .continuous) { context in
                cameraHeading = context.camera.heading
            }
            .onTapGesture { point in
                guard !drawing, !runner.isRunning, let coordinate = proxy.convert(point, from: .local) else { return }
                dropPin(at: coordinate)
            }
            .overlay {
                if drawing {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard let c = proxy.convert(value.location, from: .local) else { return }
                                    if let last = plan.walkPath.last,
                                       CLLocation(latitude: last.lat, longitude: last.lon)
                                        .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) < 3 { return }
                                    plan.walkPath.append(WalkPoint(lat: c.latitude, lon: c.longitude))
                                }
                        )
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) { topBar }
        .navigationTitle("Trip Planner")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onReceive(runner.$position) { position in
            guard follow, let position else { return }
            withAnimation(.linear(duration: 1)) {
                camera = .camera(MapCamera(centerCoordinate: position,
                                           distance: runner.phase == .driving || runner.phase == .stopped ? 650 : 250,
                                           heading: runner.heading, pitch: show3D ? 60 : 0))
            }
        }
        .onChange(of: drawing) { _, isDrawing in
            if isDrawing { detent = .height(150) }
        }
        .onChange(of: plan.home) { _, _ in plan.save() }
        .onAppear { showSheet = true }
        .onDisappear { showSheet = false; plan.save() }
        .sheet(isPresented: $showSheet) {
            TripSheet(plan: $plan, mode: $mode, drawing: $drawing, droppedPin: $droppedPin,
                      message: $message, detent: $detent, onFocus: focus)
                .presentationDetents([.height(150), .medium, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(24)
                .interactiveDismissDisabled()
        }
    }

    // MARK: - Top bar (live status + map toggles)

    private var topBar: some View {
        VStack(spacing: 8) {
            if runner.isRunning || runner.phase == .done {
                LiveCard(runner: runner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack {
                Spacer()
                VStack(spacing: 0) {
                    MapToggle(symbol: follow ? "location.fill" : "location", isOn: $follow)
                    Divider().frame(width: 32)
                    MapToggle(symbol: show3D ? "view.3d" : "view.2d", isOn: $show3D)
                    Divider().frame(width: 32)
                    MapToggle(symbol: "car.rear.road.lane", isOn: $showTraffic)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .animation(.spring(duration: 0.35), value: runner.isRunning)
    }

    private func dropPin(at coordinate: CLLocationCoordinate2D) {
        var pin = TripPlace(name: "Dropped pin", coordinate: coordinate)
        droppedPin = pin
        detent = .medium
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) { marks, _ in
            if let mark = marks?.first {
                pin.name = mark.name ?? mark.thoroughfare ?? "Dropped pin"
                if droppedPin?.id == pin.id { droppedPin = pin }
            }
        }
    }

    private func focus(_ coordinate: CLLocationCoordinate2D) {
        follow = false
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .camera(MapCamera(centerCoordinate: coordinate, distance: 900, heading: 0, pitch: show3D ? 45 : 0))
        }
    }
}

// MARK: - Live status card

private struct LiveCard: View {
    @ObservedObject var runner: TripRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: runner.phase.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(phaseColor.gradient, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(runner.title).font(.headline).lineLimit(1)
                    if !runner.detail.isEmpty {
                        Text(runner.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if runner.phase == .driving || runner.phase == .stopped || runner.phase == .walking {
                    VStack(spacing: 0) {
                        Text("\(runner.speedKmh)")
                            .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                        Text("km/h").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .animation(.snappy, value: runner.speedKmh)
                }
            }
            if runner.phase == .driving || runner.phase == .stopped {
                ProgressView(value: runner.progress).tint(phaseColor)
                if let eta = runner.eta {
                    HStack {
                        Label("Arrive \(eta.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                        Spacer()
                        Text(eta, style: .relative)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            } else if let leaveAt = runner.leaveAt, leaveAt > Date() {
                HStack {
                    Label("Leaving at \(leaveAt.formatted(date: .omitted, time: .shortened))", systemImage: "hourglass")
                    Spacer()
                    Text(timerInterval: Date()...leaveAt, countsDown: true)
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private var phaseColor: Color {
        switch runner.phase {
        case .driving: return .blue
        case .stopped: return .red
        case .walking: return .orange
        case .inside, .parked: return .purple
        case .drivethru: return .pink
        case .done, .idle: return .green
        }
    }
}

private struct PositionPuck: View {
    let phase: TripPhase
    let rotation: Double

    var body: some View {
        ZStack {
            Circle().fill(.blue.opacity(0.18)).frame(width: 54, height: 54)
            Circle().fill(.white).frame(width: 30, height: 30).shadow(radius: 3)
            Image(systemName: phase == .driving || phase == .stopped ? "location.north.fill" : phase.symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.blue)
                .rotationEffect(.degrees(phase == .driving || phase == .stopped ? rotation : 0))
        }
        .animation(.linear(duration: 1), value: rotation)
    }
}

private struct MapToggle: View {
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .frame(width: 44, height: 44)
        }
    }
}

// MARK: - Control sheet

private struct TripSheet: View {
    @ObservedObject private var runner = TripRunner.shared
    @Binding var plan: TripPlan
    @Binding var mode: TripPlannerView.Mode
    @Binding var drawing: Bool
    @Binding var droppedPin: TripPlace?
    @Binding var message: String?
    @Binding var detent: PresentationDetent
    let onFocus: (CLLocationCoordinate2D) -> Void

    @AppStorage(TripRunner.baseURLKey) private var baseURL = ""
    @State private var presets: [TripPreset] = []
    @State private var searchTarget: SearchTarget?
    @State private var showLog = false

    enum SearchTarget: String, Identifiable {
        case home, stop, dest, handover
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: return "Set Home"
            case .stop: return "Add Stop"
            case .dest: return "Set Destination"
            case .handover: return "Handover Place"
            }
        }
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if runner.isRunning {
                        Button(role: .destructive) {
                            Task { await runner.stopAndClear() }
                        } label: {
                            Label("Stop & Use Real Location", systemImage: "location.slash.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                    }
                    if !pairingExists {
                        Banner(text: "Import a pairing file in Settings first.", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    if let message {
                        Banner(text: message, symbol: "info.circle.fill", tint: .blue)
                            .onTapGesture { self.message = nil }
                    }
                    if let pin = droppedPin {
                        droppedPinCard(pin)
                    }

                    Picker("Mode", selection: $mode) {
                        ForEach(TripPlannerView.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .drive: driveTab
                    case .walk: walkTab
                    case .presets: presetsTab
                    }

                    logSection
                }
                .padding(16)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $searchTarget) { target in
                PlaceSearchSheet(title: target.title) { place in
                    assign(place, to: target)
                    onFocus(place.coordinate)
                }
                .presentationDetents([.large])
            }
        }
        .task { presets = await TripRunner.fetchPresets() }
        .onChange(of: plan.stops) { _, _ in plan.save() }
        .onChange(of: plan.dest) { _, _ in plan.save() }
    }

    // MARK: Drive

    private var driveTab: some View {
        VStack(spacing: 16) {
            Card {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        RouteDot(symbol: "house.fill", tint: .green)
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("Start", selection: $plan.startMode) {
                                ForEach(StartMode.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            Button {
                                searchTarget = .home
                            } label: {
                                Text(plan.home?.name ?? "Set Home address")
                                    .font(.subheadline)
                                    .foregroundStyle(plan.home == nil ? .red : .secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 10)

                    ForEach($plan.stops) { $stop in
                        Divider().padding(.leading, 44)
                        StopRow(stop: $stop) {
                            plan.stops.removeAll { $0.id == stop.id }
                        } onFocus: { onFocus(stop.coordinate) }
                    }

                    Divider().padding(.leading, 44)
                    Button {
                        searchTarget = .stop
                    } label: {
                        HStack(spacing: 12) {
                            RouteDot(symbol: "plus", tint: .gray)
                            Text("Add stop (drive-thru, gas, store…)").font(.subheadline)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }

                    Divider().padding(.leading, 44)
                    Button {
                        searchTarget = .dest
                    } label: {
                        HStack(spacing: 12) {
                            RouteDot(symbol: "flag.checkered", tint: .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.dest?.name ?? "Choose destination")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(plan.dest == nil ? .secondary : .primary)
                                Text("Tap the map or search").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                    }
                }
            }

            Card {
                VStack(spacing: 14) {
                    HStack {
                        Label("Stay", systemImage: "hourglass")
                        Spacer()
                        Text(TripRunner.duration(plan.stayMinutes * 60)).monospacedDigit().foregroundStyle(.secondary)
                        Stepper("", value: $plan.stayMinutes, in: 0...720, step: 15).labelsHidden()
                    }
                    Toggle(isOn: $plan.enterBuilding) {
                        Label("Go inside & move around", systemImage: "building.2")
                    }
                    Toggle(isOn: $plan.startInside) {
                        Label("Start inside, walk out to car", systemImage: "figure.walk.departure")
                    }
                    Toggle(isOn: $plan.driveBack) {
                        Label("Drive back", systemImage: "arrow.uturn.backward")
                    }
                    Toggle(isOn: $plan.clearAtEnd) {
                        Label("Real location when done", systemImage: "checkmark.circle")
                    }
                }
                .font(.subheadline)
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Hand over to real location", systemImage: "location.circle")
                        Spacer()
                        Text(plan.realWithin == 0 ? "Off" : "within \(Int(plan.realWithin)) m")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $plan.realWithin, in: 0...1500, step: 50)
                    if plan.realWithin > 0 {
                        Picker("Near", selection: $plan.handoverAtStart) {
                            Text("Near start").tag(true)
                            Text("Near a place").tag(false)
                        }
                        .pickerStyle(.segmented)
                        if !plan.handoverAtStart {
                            Button {
                                searchTarget = .handover
                            } label: {
                                Label(plan.handover?.name ?? "Choose handover place", systemImage: "mappin.and.ellipse")
                                    .foregroundStyle(plan.handover == nil ? Color.red : Color.accentColor)
                            }
                        }
                        Text("When the fake location comes back within this distance (driving, walking or parked), it switches to your real GPS.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }

            Card {
                VStack(spacing: 14) {
                    Toggle(isOn: $plan.realSignals) {
                        Label("Real traffic lights & stop signs", systemImage: "light.beacon.max")
                    }
                    Toggle(isOn: $plan.traffic) {
                        Label("Traffic slowdowns", systemImage: "car.2")
                    }
                }
                .font(.subheadline)
            }

            PrimaryButton(title: "Start Trip", symbol: "car.fill",
                          disabled: runner.isRunning || !pairingExists || plan.dest == nil ||
                          (plan.startMode == .home && plan.home == nil)) {
                start(file: "default.js", name: plan.dest?.name ?? "Trip")
            }
        }
        .onChange(of: plan.startInside) { _, _ in plan.save() }
    }

    // MARK: Walk

    private var walkTab: some View {
        VStack(spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button {
                            drawing.toggle()
                            if drawing { plan.walkPath = [] }
                        } label: {
                            Label(drawing ? "Done Drawing" : "Draw Path", systemImage: drawing ? "checkmark" : "pencil.tip")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(drawing ? .green : .orange)
                        Spacer()
                        Button("Clear", role: .destructive) { plan.walkPath = [] }
                            .disabled(plan.walkPath.isEmpty)
                    }
                    Text(drawing ? "Drag your finger on the map to draw the route." :
                            plan.walkPath.count > 1 ? String(format: "%.0f m path, %d points", walkLength, plan.walkPath.count) :
                            "Draw a path on the map to walk it, e.g. around a park or inside a mall.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Card {
                VStack(spacing: 14) {
                    Picker("Speed", selection: $plan.walkSpeed) {
                        Text("Stroll").tag(0.9)
                        Text("Walk").tag(1.4)
                        Text("Jog").tag(2.8)
                        Text("Bike").tag(5.5)
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: $plan.walkLoop) {
                        Label("Loop until stopped", systemImage: "repeat")
                    }
                    .font(.subheadline)
                }
            }
            PrimaryButton(title: "Start Walk", symbol: "figure.walk",
                          disabled: runner.isRunning || !pairingExists || plan.walkPath.count < 2) {
                drawing = false
                plan.save()
                runner.runRemote(file: "walk.js", name: "Walk",
                                 args: plan.args(start: TripPlace(name: "Path start", coordinate: plan.walkPath[0].coordinate)))
            }
        }
    }

    private var walkLength: Double {
        zip(plan.walkPath, plan.walkPath.dropFirst()).reduce(0) {
            $0 + CLLocation(latitude: $1.0.lat, longitude: $1.0.lon).distance(from: CLLocation(latitude: $1.1.lat, longitude: $1.1.lon))
        }
    }

    // MARK: Presets

    private var presetsTab: some View {
        VStack(spacing: 12) {
            if presets.isEmpty {
                ProgressView().padding()
            }
            ForEach(presets) { preset in
                Button {
                    start(file: preset.file, name: preset.name)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: preset.icon ?? "map.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            if let detail = preset.description {
                                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                        }
                        Spacer()
                        Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                    }
                    .padding(12)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(runner.isRunning || !pairingExists || (preset.needsDestination == true && plan.dest == nil))
            }
            DisclosureGroup("Script source") {
                TextField(TripRunner.defaultBaseURL, text: $baseURL)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { presets = await TripRunner.fetchPresets() } }
                Text("Presets and trip behaviour load from this folder every run, so they update without reinstalling.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.top, 8)
        }
    }

    // MARK: Pieces

    private func droppedPinCard(_ pin: TripPlace) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(pin.name, systemImage: "mappin.circle.fill").font(.headline).lineLimit(1)
                    Spacer()
                    Button { droppedPin = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
                HStack(spacing: 8) {
                    pinButton("Home", "house.fill") { plan.home = pin }
                    pinButton("Stop", "plus") { plan.stops.append(pin) }
                    pinButton("Destination", "flag.checkered") { plan.dest = pin }
                }
                pinButton("Hand over to real location here", "location.circle") {
                    plan.handover = pin
                    plan.handoverAtStart = false
                    if plan.realWithin == 0 { plan.realWithin = 300 }
                }
            }
        }
    }

    private func pinButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            droppedPin = nil
            plan.save()
        } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var logSection: some View {
        DisclosureGroup(isExpanded: $showLog) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(runner.log.reversed().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Log", systemImage: "text.alignleft").font(.subheadline)
        }
        .opacity(runner.log.isEmpty ? 0 : 1)
    }

    private func assign(_ place: TripPlace, to target: SearchTarget) {
        switch target {
        case .home: plan.home = place
        case .stop: plan.stops.append(place)
        case .dest: plan.dest = place
        case .handover:
            plan.handover = place
            plan.handoverAtStart = false
        }
        plan.save()
    }

    private func start(file: String, name: String) {
        plan.save()
        detent = .height(150)
        Task {
            if let problem = await runner.start(plan: plan, file: file, name: name) {
                message = problem
                detent = .medium
            }
        }
    }
}

private struct StopRow: View {
    @Binding var stop: TripPlace
    let onDelete: () -> Void
    let onFocus: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(StopKind.allCases) { kind in
                    Button {
                        stop.kind = kind
                        stop.minutes = kind.defaultMinutes
                    } label: { Label(kind.title, systemImage: kind.symbol) }
                }
            } label: {
                RouteDot(symbol: stop.kind.symbol, tint: .orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .onTapGesture(perform: onFocus)
                Text("\(stop.kind.title) · \(Int(stop.minutes)) min").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Stepper("", value: $stop.minutes, in: 1...240, step: stop.minutes < 10 ? 1 : 5).labelsHidden()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
    }
}

private struct RouteDot: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint.gradient, in: Circle())
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(tint)
    }
}

private struct PrimaryButton: View {
    let title: String
    let symbol: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(disabled)
        .sensoryFeedback(.impact, trigger: disabled)
    }
}

/// Apple Maps search with autocomplete.
private struct PlaceSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onPick: (TripPlace) -> Void

    @StateObject private var completer = SearchCompleter()
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List(completer.results, id: \.self) { result in
                Button {
                    resolve(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).foregroundStyle(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search places or addresses")
            .onChange(of: query) { _, newValue in completer.update(newValue) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            onPick(TripPlace(name: item.name ?? completion.title, coordinate: item.placemark.coordinate))
            dismiss()
        }
    }
}

private final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(_ query: String) {
        if query.isEmpty { results = [] } else { completer.queryFragment = query }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }
}
