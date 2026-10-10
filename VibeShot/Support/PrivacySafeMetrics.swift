import CoreGraphics
import Foundation
import os

/// The small, fixed vocabulary used by local diagnostics. Values are deliberately numeric-only
/// so a metric cannot accidentally carry screenshot pixels, annotation text, names, paths, or
/// error descriptions.
enum PrivacySafeMetricStage: String, Sendable {
    case permission
    case snapshot
    case overlay
    case export
    case teardown
}

struct PrivacySafeMetric: Equatable, Sendable {
    let stage: PrivacySafeMetricStage
    let durationNanoseconds: UInt64
    let count: Int
    let estimatedBytes: Int
    let residentBytes: Int

    init(
        stage: PrivacySafeMetricStage,
        durationNanoseconds: UInt64 = 0,
        count: Int = 0,
        estimatedBytes: Int = 0,
        residentBytes: Int = 0
    ) {
        self.stage = stage
        self.durationNanoseconds = durationNanoseconds
        self.count = max(0, count)
        self.estimatedBytes = max(0, estimatedBytes)
        self.residentBytes = max(0, residentBytes)
    }
}

@MainActor
protocol PrivacySafeMetricsSink: AnyObject {
    func record(_ metric: PrivacySafeMetric)
}

/// Used by tests and embedders that do not want diagnostics. It intentionally has no state and no
/// logging side effects.
@MainActor
final class NoopPrivacySafeMetricsSink: PrivacySafeMetricsSink {
    func record(_ metric: PrivacySafeMetric) {}
}

/// A test-visible sink that stores only the numeric metric envelope. It is useful for verifying
/// instrumentation without ever retaining a source image or user content.
@MainActor
final class RecordingPrivacySafeMetricsSink: PrivacySafeMetricsSink {
    private(set) var metrics: [PrivacySafeMetric] = []

    func record(_ metric: PrivacySafeMetric) {
        metrics.append(metric)
    }
}

/// The production sink emits fixed-stage signposts through os_log. No caller-supplied strings are
/// accepted, and all payload fields are numeric. External telemetry is intentionally absent.
@MainActor
final class OSLogPrivacySafeMetricsSink: PrivacySafeMetricsSink {
    private let log = OSLog(subsystem: "com.vibeshot.VibeShot", category: "metrics")

    func record(_ metric: PrivacySafeMetric) {
        os_log(
            "stage=%{public}s duration_ns=%{public}llu count=%{public}lld estimated_bytes=%{public}lld resident_bytes=%{public}lld",
            log: log,
            type: .info,
            metric.stage.rawValue,
            metric.durationNanoseconds,
            metric.count,
            metric.estimatedBytes,
            metric.residentBytes
        )
        os_signpost(
            .event,
            log: log,
            name: "privacy_safe_metric",
            "%{public}s %{public}llu %{public}lld %{public}lld %{public}lld",
            metric.stage.rawValue,
            metric.durationNanoseconds,
            Int64(metric.count),
            Int64(metric.estimatedBytes),
            Int64(metric.residentBytes)
        )
    }
}

@MainActor
final class PrivacySafeMetrics {
    let sink: any PrivacySafeMetricsSink

    init(sink: any PrivacySafeMetricsSink = OSLogPrivacySafeMetricsSink()) {
        self.sink = sink
    }

    static var noop: PrivacySafeMetrics {
        PrivacySafeMetrics(sink: NoopPrivacySafeMetricsSink())
    }

    func record(
        _ stage: PrivacySafeMetricStage,
        durationNanoseconds: UInt64 = 0,
        count: Int = 0,
        estimatedBytes: Int = 0,
        residentBytes: Int = 0
    ) {
        sink.record(PrivacySafeMetric(
            stage: stage,
            durationNanoseconds: durationNanoseconds,
            count: count,
            estimatedBytes: estimatedBytes,
            residentBytes: residentBytes
        ))
    }

    func measure<T>(
        _ stage: PrivacySafeMetricStage,
        count: Int = 0,
        estimatedBytes: Int = 0,
        residentBytes: Int = 0,
        _ operation: () throws -> T
    ) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            record(
                stage,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- start,
                count: count,
                estimatedBytes: estimatedBytes,
                residentBytes: residentBytes
            )
        }
        return try operation()
    }
}

private func privacySafeEstimatedBytes(width: Int, height: Int) -> Int {
    let width = max(0, width)
    let height = max(0, height)
    let area = width.multipliedReportingOverflow(by: height)
    let bytes = area.partialValue.multipliedReportingOverflow(by: 4)
    return (area.overflow || bytes.overflow) ? Int.max : bytes.partialValue
}

func privacySafeEstimatedBytes(for snapshots: [DisplaySnapshot]) -> Int {
    snapshots.reduce(into: 0) { total, snapshot in
        let bytes = privacySafeEstimatedBytes(width: snapshot.image.width, height: snapshot.image.height)
        let sum = total.addingReportingOverflow(bytes)
        total = sum.overflow ? Int.max : sum.partialValue
    }
}

func privacySafeEstimatedBytes(for image: CGImage) -> Int {
    privacySafeEstimatedBytes(width: image.width, height: image.height)
}
