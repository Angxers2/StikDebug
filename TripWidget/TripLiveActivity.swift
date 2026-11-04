//
//  TripLiveActivity.swift
//  TripWidget
//
//  Lock Screen + Dynamic Island for a running trip: live km/h, progress and ETA while
//  driving; a countdown to leaving while parked or inside; a Stop button.
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct TripWidgetBundle: WidgetBundle {
    var body: some Widget {
        TripLiveActivity()
    }
}

struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: state.phase, size: 40)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingValue(state: state).font(.title2.weight(.bold))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.headline).lineLimit(1)
                        if !state.detail.isEmpty {
                            Text(state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        BottomInfo(state: state)
                        Button(intent: EndTripIntent()) {
                            Label("Stop & use real location", systemImage: "location.slash.fill")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: state.phase.symbol).foregroundStyle(phaseTint(state.phase))
            } compactTrailing: {
                TrailingValue(state: state).font(.caption.weight(.semibold)).frame(maxWidth: 56)
            } minimal: {
                Image(systemName: state.phase.symbol).foregroundStyle(phaseTint(state.phase))
            }
        }
    }
}

private struct LockScreenView: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PhaseIcon(phase: state.phase, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.headline).lineLimit(1)
                    if !state.detail.isEmpty {
                        Text(state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                TrailingValue(state: state).font(.title.weight(.bold))
            }
            BottomInfo(state: state)
            Button(intent: EndTripIntent()) {
                Label("Stop", systemImage: "location.slash.fill").font(.caption.weight(.semibold))
            }
            .tint(.red)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

/// km/h while moving, countdown while staying.
private struct TrailingValue: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        if isMoving(state.phase) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(state.speedKmh)").monospacedDigit()
                Text("km/h").font(.caption2).foregroundStyle(.secondary)
            }
        } else if let leaveAt = state.leaveAt, leaveAt > Date() {
            Text(timerInterval: Date()...leaveAt, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            Image(systemName: state.phase.symbol)
        }
    }
}

private struct BottomInfo: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        if isMoving(state.phase) {
            VStack(spacing: 4) {
                ProgressView(value: min(1, max(0, state.progress))).tint(phaseTint(state.phase))
                if let eta = state.eta {
                    HStack {
                        Text("Arrive \(eta.formatted(date: .omitted, time: .shortened))")
                        Spacer()
                        Text(timerInterval: Date()...max(Date(), eta), countsDown: true).monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } else if let leaveAt = state.leaveAt, leaveAt > Date() {
            HStack {
                Image(systemName: "hourglass")
                Text("Leaving at \(leaveAt.formatted(date: .omitted, time: .shortened))")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct PhaseIcon: View {
    let phase: TripPhase
    let size: CGFloat

    var body: some View {
        Image(systemName: phase.symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(phaseTint(phase).gradient, in: RoundedRectangle(cornerRadius: size * 0.28))
    }
}

private func isMoving(_ phase: TripPhase) -> Bool {
    phase == .driving || phase == .stopped || phase == .walking || phase == .drivethru
}

private func phaseTint(_ phase: TripPhase) -> Color {
    switch phase {
    case .driving: return .blue
    case .stopped: return .red
    case .walking: return .orange
    case .inside, .parked: return .purple
    case .drivethru: return .pink
    case .done, .idle: return .green
    }
}
