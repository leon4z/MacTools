# LinearMouse source attribution

Source: https://github.com/linearmouse/linearmouse/tree/v0.11.4

Pinned commit: `df23b547ea0821c729eae1e6055bf3a018ab6b4f`. MIT license, copyright (c) 2021–2026 LinearMouse; full text in `LICENSE`, also included in the installed app resources. SHA-256 comparison with downloaded upstream files is in `PROVENANCE.json`.

- `SmoothedScrollingEngine.swift`, `Smoothed.swift`, `Bidirectional.swift`: unchanged upstream source.
- `EventThread.swift`: upstream event run loop and timer; bundle identifier has a CLI-safe fallback; thread name changed for MacTools.
- `ScrollWheelEventView.swift`: upstream delta and IOHID transformations; removed dependency on MouseEventView by owning the CGEvent directly, removed hot-path logging, added bundle identifier fallback.
- `SmoothedScrollEventDelivery.swift`: extracted delivery class and point accumulator from upstream `LinearMouse/EventTransformer/SmoothedScrollingTransformer.swift`; widened class visibility, same algorithm.
- `Compatibility.swift`: MacTools scaffolding for upstream configuration namespaces, protocol, clamping and Decimal conversion.
- `Sources/App/HIDBridge.h`: scroll IOHID declarations adapted from upstream bridging header. `HIDSettingsLease` uses the full HID client used by PointerKit. Pointer updates retain MacTools' compare-and-swap recovery journal.
- `Tests/Upstream/SmoothedScrollingEngineTests.swift`: upstream 19 engine cases; XCTest imports replaced by minimal assertion wrappers and a CLI runner because this machine has Command Line Tools without XCTest. Test bodies remain upstream.

MacTools owns `MouseScrollProcessor` and `MouseScrollRuntime`: wheel-only integration, explicit pause, failure passthrough, pending-input recovery and lifecycle. It uses upstream easeInOut parameters with bouncing disabled. No GestureKit, device normalization, trackpad handling or LinearMouse GUI is imported. Continuous/high-precision inputs pass through unchanged. The speed knob is passed to upstream speed; response/inertia adapt to MacTools' existing smoothing duration.

The IOHID bridge uses private macOS interfaces, as does upstream; system upgrades need regression testing. This reuse does not mean the full upstream application or its device-specific behavior has been ported.
