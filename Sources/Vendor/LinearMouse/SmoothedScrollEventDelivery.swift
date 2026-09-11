// MIT License
// Copyright (c) 2021-2026 LinearMouse
// Extracted unchanged from SmoothedScrollingTransformer.swift at v0.11.4; visibility widened.
import CoreGraphics
import Foundation
final class SmoothedScrollEventDelivery {
    static let inputLineStepInPoints = 36.0
    private static let outputLineStepInPoints = 12.0
    private var pointDeltaAccumulator = SmoothedScrollPointDeltaAccumulator()

    func resetPointDeltaRemainders() {
        pointDeltaAccumulator.reset()
    }

    func apply(
        phases: (scrollPhase: CGScrollPhase?, momentumPhase: CGMomentumScrollPhase),
        to view: ScrollWheelEventView
    ) {
        view.scrollPhase = phases.scrollPhase
        view.momentumPhase = phases.momentumPhase
    }

    func phasesFor(
        _ phase: SmoothedScrollingEngine.Phase,
        appliesPhases: Bool = true
    ) -> (scrollPhase: CGScrollPhase?, momentumPhase: CGMomentumScrollPhase) {
        guard appliesPhases else {
            return (nil, .none)
        }

        switch phase {
        case .touchBegan:
            return (.began, .none)
        case .touchChanged:
            return (.changed, .none)
        case .touchEnded:
            return (.ended, .none)
        case .momentumBegan:
            return (nil, .begin)
        case .momentumChanged:
            return (nil, .continuous)
        case .momentumEnded:
            return (nil, .end)
        }
    }

    func deltaXInPixels(from view: ScrollWheelEventView) -> Double {
        if !view.continuous {
            if view.deltaX != 0 {
                return Double(view.deltaX) * Self.inputLineStepInPoints
            }
            if view.deltaXPt != 0 {
                return view.deltaXPt * Self.inputLineStepInPoints
            }
            if view.deltaXFixedPt != 0 {
                return view.deltaXFixedPt * Self.inputLineStepInPoints * 10
            }
        }
        if view.deltaXFixedPt != 0 {
            return view.deltaXFixedPt
        }
        if view.deltaXPt != 0 {
            return view.deltaXPt
        }
        return Double(view.deltaX) * Self.inputLineStepInPoints
    }

    func deltaYInPixels(from view: ScrollWheelEventView) -> Double {
        if !view.continuous {
            if view.deltaY != 0 {
                return Double(view.deltaY) * Self.inputLineStepInPoints
            }
            if view.deltaYPt != 0 {
                return view.deltaYPt * Self.inputLineStepInPoints
            }
            if view.deltaYFixedPt != 0 {
                return view.deltaYFixedPt * Self.inputLineStepInPoints * 10
            }
        }
        if view.deltaYFixedPt != 0 {
            return view.deltaYFixedPt
        }
        if view.deltaYPt != 0 {
            return view.deltaYPt
        }
        return Double(view.deltaY) * Self.inputLineStepInPoints
    }

    func setHorizontal(_ value: Double, on view: ScrollWheelEventView) {
        view.deltaX = integerDelta(for: value)
        view.deltaXPt = pointDeltaAccumulator.horizontalPointDelta(for: value)
        view.deltaXFixedPt = value
        view.ioHidScrollX = value
    }

    func setVertical(_ value: Double, on view: ScrollWheelEventView) {
        view.deltaY = integerDelta(for: value)
        view.deltaYPt = pointDeltaAccumulator.verticalPointDelta(for: value)
        view.deltaYFixedPt = value
        view.ioHidScrollY = value
    }

    func setSyntheticHorizontal(
        _ value: Double,
        on view: ScrollWheelEventView,
        accumulatesSubpixelDelta: Bool
    ) {
        setSyntheticHorizontalOutput(
            pointDeltaAccumulator.horizontalPointDelta(
                for: value,
                accumulates: accumulatesSubpixelDelta
            ),
            on: view
        )
    }

    func setSyntheticVertical(
        _ value: Double,
        on view: ScrollWheelEventView,
        accumulatesSubpixelDelta: Bool
    ) {
        setSyntheticVerticalOutput(
            pointDeltaAccumulator.verticalPointDelta(
                for: value,
                accumulates: accumulatesSubpixelDelta
            ),
            on: view
        )
    }

    func zeroHorizontal(on view: ScrollWheelEventView) {
        view.deltaX = 0
        view.deltaXPt = 0
        view.deltaXFixedPt = 0
        view.ioHidScrollX = 0
    }

    func zeroVertical(on view: ScrollWheelEventView) {
        view.deltaY = 0
        view.deltaYPt = 0
        view.deltaYFixedPt = 0
        view.ioHidScrollY = 0
    }

    func hasDelta(on view: ScrollWheelEventView) -> Bool {
        view.deltaX != 0 || view.deltaY != 0 ||
            view.deltaXPt != 0 || view.deltaYPt != 0 ||
            view.deltaXFixedPt != 0 || view.deltaYFixedPt != 0 ||
            view.ioHidScrollX != 0 || view.ioHidScrollY != 0
    }

    private func setSyntheticHorizontalOutput(_ value: Double, on view: ScrollWheelEventView) {
        view.deltaX = integerDelta(for: value)
        view.deltaXPt = value
        view.deltaXFixedPt = value
        view.ioHidScrollX = value
    }

    private func setSyntheticVerticalOutput(_ value: Double, on view: ScrollWheelEventView) {
        view.deltaY = integerDelta(for: value)
        view.deltaYPt = value
        view.deltaYFixedPt = value
        view.ioHidScrollY = value
    }

    private func integerDelta(for value: Double) -> Int64 {
        Int64((value / Self.outputLineStepInPoints).rounded(.towardZero))
    }
}

struct SmoothedScrollPointDeltaAccumulator {
    private var horizontalRemainder = 0.0
    private var verticalRemainder = 0.0

    mutating func reset() {
        horizontalRemainder = 0
        verticalRemainder = 0
    }

    mutating func horizontalPointDelta(for value: Double, accumulates: Bool = true) -> Double {
        pointDelta(for: value, remainder: &horizontalRemainder, accumulates: accumulates)
    }

    mutating func verticalPointDelta(for value: Double, accumulates: Bool = true) -> Double {
        pointDelta(for: value, remainder: &verticalRemainder, accumulates: accumulates)
    }

    private func pointDelta(for value: Double, remainder: inout Double, accumulates: Bool) -> Double {
        guard accumulates else {
            remainder = 0
            return truncatedPointDelta(for: value)
        }

        let combinedValue = value + remainder
        let pointDelta = truncatedPointDelta(for: combinedValue)
        remainder = combinedValue - pointDelta

        return pointDelta
    }

    private func truncatedPointDelta(for value: Double) -> Double {
        Double(Int64(value.rounded(.towardZero)))
    }
}
