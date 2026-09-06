//
//  AppModel.swift
//  Prospector
//

import SwiftUI
import simd

/// State shared between the control window and the immersive space.
///
/// The two scenes can't share `@State`, so anything either needs to show or
/// change (load progress, the chosen model, passthrough, alignment) lives
/// here. Navigation state also lives here so that alignment survives exiting
/// and re-entering the immersive space.
@Observable
@MainActor
final class AppModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case failed(String)
    }

    /// A one-shot action requested by the panel. The immersive view consumes
    /// it on its next frame, because the actions need the loaded entity or
    /// the current head position.
    enum Request {
        case resetHeight
        case resetPosition
        case alignToRoom
    }

    /// How much of the real room shows through the model. Ordered from least
    /// to most passthrough so levels can be compared.
    enum Passthrough: Int, CaseIterable, Identifiable, Comparable {
        case none, partial, full

        var id: Self { self }

        var title: String {
            switch self {
            case .none: "None"
            case .partial: "Partial"
            case .full: "Full"
            }
        }

        /// Model opacity for this level. `full` hides the model outright, so its
        /// value is never applied.
        var modelOpacity: Float {
            switch self {
            case .none: 1
            case .partial: 0.8
            case .full: 0
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var loadState: LoadState = .idle
    var isImmersiveSpaceOpen = false
    var passthrough: Passthrough = .none
    /// The HDRI horizon behind the model. Off by default because with passthrough
    /// it hides the real room; useful for outdoor models.
    var showSkybox = false
    /// Whether the in-space control panel drifts along to stay in front of you.
    var panelFollowsUser = true
    var pendingRequest: Request?
    var alignmentMessage: String?

    private var passthroughBeforeFull: Passthrough = .none

    /// Flips between full passthrough and whatever was set before it.
    func toggleFullPassthrough() {
        if passthrough == .full {
            passthrough = passthroughBeforeFull
        } else {
            passthroughBeforeFull = passthrough
            passthrough = .full
        }
    }

    // MARK: - Model file

    private static let modelBookmarkKey = "modelBookmark"

    /// The USDZ the user picked. The file stays where it is; a security-scoped
    /// bookmark is kept so it doesn't have to be picked again next launch.
    private(set) var modelURL: URL?

    var modelName: String? {
        modelURL?.deletingPathExtension().lastPathComponent
    }

    init() {
        modelURL = Self.resolveStoredModelURL()
    }

    /// Makes a file from the picker the current model and remembers it.
    func selectModel(_ url: URL) async {
        do {
            let bookmark = try await url.withSecurityScopedAccess { try url.bookmarkData() }
            UserDefaults.standard.set(bookmark, forKey: Self.modelBookmarkKey)
            modelURL = url
            loadState = .idle
            resetNavigation()
        } catch {
            loadState = .failed("Couldn't remember \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func resolveStoredModelURL() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: modelBookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale, let refreshed = try? url.bookmarkData() {
            UserDefaults.standard.set(refreshed, forKey: modelBookmarkKey)
        }
        return url
    }

    // MARK: - Navigation

    // Written every frame by the immersive view and read by nothing in a view
    // body, so they are kept out of observation.

    /// Where the viewer is standing, in the model's (unrotated) coordinate space.
    @ObservationIgnored var playerPosition = SIMD3<Float>(0, 0, 0)
    /// Extra rotation applied to the model around the vertical axis.
    @ObservationIgnored var worldYaw: Float = 0

    /// The rotation the model root gets for the current yaw.
    static func worldRotation(yaw: Float) -> simd_quatf {
        simd_quatf(angle: -yaw, axis: SIMD3<Float>(0, 1, 0))
    }

    /// The translation the model root gets for the current position and yaw.
    /// Setting it moves the viewer to match.
    var worldTranslation: SIMD3<Float> {
        get { -simd_act(Self.worldRotation(yaw: worldYaw), playerPosition) }
        set { playerPosition = -simd_act(Self.worldRotation(yaw: worldYaw).inverse, newValue) }
    }

    func resetNavigation() {
        playerPosition = .zero
        worldYaw = 0
        alignmentMessage = nil
    }

    /// Shifts the model by `delta`, given in the immersive space's coordinates.
    func moveWorld(by delta: SIMD3<Float>) {
        worldTranslation += delta
    }

    /// Spins the model around a vertical axis through `pivot` (in the immersive
    /// space's coordinates), so the viewer stays put while the world turns.
    func rotateWorld(byYaw yawDelta: Float, around pivot: SIMD3<Float>) {
        let spin = Self.worldRotation(yaw: yawDelta)
        let translation = worldTranslation
        worldYaw = Self.wrapAngle(worldYaw + yawDelta)
        worldTranslation = simd_act(spin, translation - pivot) + pivot
    }

    static let quarterTurn: Float = .pi / 2

    /// Wraps an angle to (-period/2, period/2]. The default period gives (-π, π];
    /// pass `quarterTurn` for things that repeat every 90°, like walls.
    static func wrapAngle(_ angle: Float, period: Float = 2 * .pi) -> Float {
        let half = period / 2
        var result = angle.truncatingRemainder(dividingBy: period)
        if result > half { result -= period }
        if result <= -half { result += period }
        return result
    }
}

extension URL {
    /// Runs `body` with access to a file outside the app's sandbox, such as one
    /// from the file picker or a resolved bookmark.
    func withSecurityScopedAccess<T>(_ body: () async throws -> T) async rethrows -> T {
        let isAccessing = startAccessingSecurityScopedResource()
        defer {
            if isAccessing { stopAccessingSecurityScopedResource() }
        }
        return try await body()
    }
}

extension simd_float4x4 {
    /// A column as a 3-vector (its position for column 3, an axis otherwise).
    func column3(_ index: Int) -> SIMD3<Float> {
        let column = self[index]
        return SIMD3<Float>(column.x, column.y, column.z)
    }

    var translation: SIMD3<Float> { column3(3) }
}
