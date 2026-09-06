//
//  ImmersiveView.swift
//  Prospector
//
//  Created by Christian Selig on 2025-08-20.
//

import SwiftUI
import RealityKit
import ARKit

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    @StateObject private var controllerManager = GameControllerManager()
    /// An empty root that navigation moves and rotates; the loaded model is its child.
    @State private var worldRoot: Entity?
    /// Holds the HDRI sphere once it's been loaded. Stays put while the model moves.
    @State private var skyboxHolder: Entity?
    @State private var panelEntity: Entity?
    @State private var isPanelCatchingUp = false
    @State private var updateSubscription: EventSubscription?
    @State private var worldTracking: WorldTrackingProvider?
    @State private var handTrackingTask: Task<Void, Never>?
    @State private var planeDetectionTask: Task<Void, Never>?
    @State private var planeAnchors: [UUID: PlaneAnchor] = [:]
    @State private var arkitSession = ARKitSession()
    @State private var leftPinchActive: Bool = false
    @State private var rightPinchActive: Bool = false
    @State private var leftPinchStartTime: TimeInterval?
    @State private var rightPinchStartTime: TimeInterval?
    @State private var activePinch: ActivePinch?
    @State private var isDragTranslucent = false
    @State private var opacityRestoreTask: Task<Void, Never>?
    @State private var modeCueText: String?
    @State private var modeCueTask: Task<Void, Never>?

    let movementSpeed: Float = 2.0
    let speedModeMultiplier: Float = 6.0
    let heightSpeed: Float = 1.5
    let lookRotationSpeed: Float = 2.25
    let terrainProbeHeight: Float = 1.5
    let pinchOnDistance: Float = 0.02
    let pinchOffDistance: Float = 0.03
    let pinchHoldDuration: TimeInterval = 0.5
    /// Right-hand sweeps closer to your head than this are ignored: the angle is too twitchy.
    let minimumRotationRadius: Float = 0.3
    /// How long the model stays translucent after a pinch ends.
    let dragOpacityLinger: Duration = .milliseconds(750)
    /// Where the floating control panel sits relative to your head, in metres.
    /// The drop puts it below your eyeline so you glance down for it.
    let panelDistance: Float = 0.7
    let panelDrop: Float = 0.6
    /// The panel starts drifting back in front of you once it's this far off-centre...
    let panelFollowAngle: Float = 30 * .pi / 180
    /// ...or this far from where it should be.
    let panelFollowDistance: Float = 0.6
    let panelFollowSpeed: Float = 4
    /// Detected planes smaller than this (in square metres) are ignored when aligning.
    let minimumPlaneArea: Float = 1.0
    let wallRaycastLength: Float = 50

    /// Where the head is assumed to be until world tracking reports it: at the
    /// space's origin, at eye height, facing -Z.
    static let defaultHeadPose: simd_float4x4 = {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4<Float>(0, 1.4, 0, 1)
        return pose
    }()

    var body: some View {
        RealityView { content, attachments in
            await loadScene(into: content, attachments: attachments)
        } attachments: {
            Attachment(id: "controls") {
                ControlPanelView()
                    .environment(appModel)
            }
        }
        .gesture(worldPinchGesture)
        .overlay(alignment: .top) {
            if let modeCueText {
                Text(modeCueText)
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 40)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .onChange(of: appModel.passthrough) {
            applyPassthrough()
        }
        .onChange(of: appModel.showSkybox) {
            Task { await updateSkybox() }
        }
        .onChange(of: controllerManager.terrainFollowEnabled) { _, isEnabled in
            showModeCue(isEnabled ? "Terrain Follow On" : "Terrain Follow Off")
        }
        .onChange(of: controllerManager.speedModeEnabled) { _, isEnabled in
            showModeCue(isEnabled ? "Speed Mode On" : "Speed Mode Off")
        }
        .onAppear {
            appModel.isImmersiveSpaceOpen = true
            appModel.loadState = .loading
        }
        .onDisappear {
            updateSubscription?.cancel()
            handTrackingTask?.cancel()
            planeDetectionTask?.cancel()
            modeCueTask?.cancel()
            opacityRestoreTask?.cancel()
            appModel.isImmersiveSpaceOpen = false
            appModel.loadState = .idle
        }
    }

    // MARK: - Scene setup

    private func loadScene(into content: RealityViewContent, attachments: RealityViewAttachments) async {
        // ARKit warms up (and plane detection starts gathering walls) while the model loads.
        startTracking()

        if let panel = attachments.entity(for: "controls") {
            content.add(panel)
            panelEntity = panel
            placePanel(immediately: true, device: deviceTransform())
        }

        guard let modelURL = appModel.modelURL else {
            appModel.loadState = .failed("No model selected.")
            return
        }

        let model: Entity
        do {
            // The file lives outside the sandbox, so access has to be opened around the load.
            model = try await modelURL.withSecurityScopedAccess { try await Entity(contentsOf: modelURL) }
        } catch {
            appModel.loadState = .failed("Couldn't load \(modelURL.lastPathComponent): \(error.localizedDescription)")
            return
        }

        await prepareForInteraction(model)

        let root = Entity()
        root.addChild(model)
        content.add(root)
        worldRoot = root
        applyNavigationTransform(to: root)

        let holder = Entity()
        content.add(holder)
        skyboxHolder = holder
        await updateSkybox()
        applyPassthrough()

        updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
            updateFrame(deltaTime: Float(event.deltaTime))
        }

        appModel.loadState = .idle
    }

    /// Shows or hides the skybox, loading the 4K texture the first time it's wanted.
    private func updateSkybox() async {
        guard let holder = skyboxHolder else { return }
        if appModel.showSkybox, holder.children.isEmpty,
           let exrURL = Bundle.main.url(forResource: "meadow_2_4k", withExtension: "exr") {
            do {
                let texture = try await TextureResource(contentsOf: exrURL)
                var material = UnlitMaterial()
                material.color = .init(texture: .init(texture))
                let sphere = ModelEntity(mesh: .generateSphere(radius: 1000), materials: [material])
                // Scale negatively on one axis to flip the normals so the texture shows on the inside.
                sphere.scale = SIMD3<Float>(-1, 1, 1)
                holder.addChild(sphere)
            } catch {
                print("Failed to load environment texture: \(error)")
            }
        }
        holder.isEnabled = appModel.showSkybox
    }

    private func startTracking() {
        Task { @MainActor in
            let worldProvider = WorldTrackingProvider()
            worldTracking = worldProvider

            var providers: [any DataProvider] = [worldProvider]
            var authorizations: [ARKitSession.AuthorizationType] = []

            let handTracking = HandTrackingProvider.isSupported ? HandTrackingProvider() : nil
            if let handTracking {
                providers.append(handTracking)
                authorizations += HandTrackingProvider.requiredAuthorizations
            }

            let planeDetection = PlaneDetectionProvider.isSupported
                ? PlaneDetectionProvider(alignments: [.horizontal, .vertical]) : nil
            if let planeDetection {
                providers.append(planeDetection)
                authorizations += PlaneDetectionProvider.requiredAuthorizations
            }

            if !authorizations.isEmpty {
                _ = await arkitSession.requestAuthorization(for: authorizations)
            }

            do {
                try await arkitSession.run(providers)
            } catch {
                print("Failed to start ARKit session: \(error)")
            }

            if let handTracking {
                startHandTrackingUpdates(with: handTracking)
            }
            if let planeDetection {
                startPlaneDetectionUpdates(with: planeDetection)
            }
        }
    }

    // MARK: - Per-frame update

    private func updateFrame(deltaTime: Float) {
        guard let root = worldRoot else { return }

        handlePendingRequest(for: root)

        let movement = controllerManager.movementVector
        let lookInput = controllerManager.lookVector
        let heightAdjust = controllerManager.heightAdjustment
        let speedMultiplier = controllerManager.speedModeEnabled ? speedModeMultiplier : 1

        if controllerManager.shouldResetHeight {
            resetHeight(for: root)
        }

        if heightAdjust != 0 {
            appModel.playerPosition.y += heightAdjust * heightSpeed * speedMultiplier * deltaTime
        }

        let device = deviceTransform()
        if appModel.panelFollowsUser {
            placePanel(immediately: false, device: device, deltaTime: deltaTime)
        }

        // Right thumbstick turns the world around the viewer.
        if lookInput.x != 0 {
            let yawDelta = -lookInput.x * lookRotationSpeed * deltaTime
            appModel.rotateWorld(byYaw: yawDelta, around: device.translation)
        }

        // Left thumbstick moves relative to the direction you're looking.
        if movement != .zero {
            let moveDistance = movementSpeed * speedMultiplier * deltaTime
            let combinedYaw = directionYaw(device.column3(2)) + appModel.worldYaw
            let cosYaw = cos(combinedYaw)
            let sinYaw = sin(combinedYaw)

            let rotatedX = movement.x * cosYaw - movement.y * sinYaw
            let rotatedZ = movement.x * sinYaw + movement.y * cosYaw

            appModel.playerPosition.x += rotatedX * moveDistance
            appModel.playerPosition.z -= rotatedZ * moveDistance
            followTerrainIfEnabled(in: root)
        }

        applyNavigationTransform(to: root)
    }

    private func handlePendingRequest(for root: Entity) {
        guard let request = appModel.pendingRequest else { return }
        appModel.pendingRequest = nil

        switch request {
        case .resetHeight:
            resetHeight(for: root)
            showModeCue("Snapped to floor")
        case .resetPosition:
            appModel.resetNavigation()
            showModeCue("Position reset")
        case .alignToRoom:
            alignToRoom(root)
        }
    }

    private func applyNavigationTransform(to root: Entity) {
        root.transform = Transform(rotation: AppModel.worldRotation(yaw: appModel.worldYaw),
                                   translation: appModel.worldTranslation)
    }

    private func resetHeight(for root: Entity) {
        appModel.playerPosition.y = terrainSurfaceHeight(below: appModel.playerPosition, in: root) ?? 0
    }

    private func followTerrainIfEnabled(in root: Entity) {
        guard controllerManager.terrainFollowEnabled,
              let terrainHeight = terrainSurfaceHeight(below: appModel.playerPosition, in: root) else { return }
        appModel.playerPosition.y = terrainHeight
    }

    // MARK: - Floating control panel

    /// Keeps the panel in front of you. Unless placing it immediately, it only
    /// drifts once you've turned or moved well away from it, so it doesn't feel
    /// glued to your face.
    private func placePanel(immediately: Bool, device: simd_float4x4, deltaTime: Float = 0) {
        guard let panel = panelEntity else { return }
        let head = device.translation
        let back = device.column3(2)
        var forward = SIMD3<Float>(-back.x, 0, -back.z)
        guard simd_length(forward) > 0.01 else { return }
        forward = simd_normalize(forward)

        let target = head + forward * panelDistance + SIMD3<Float>(0, -panelDrop, 0)

        if immediately {
            panel.position = target
        } else {
            let offset = target - panel.position
            let toPanel = panel.position - head
            let angle = acos(max(-1, min(1, simd_dot(forward, simd_normalize(SIMD3<Float>(toPanel.x, 0, toPanel.z))))))
            if !isPanelCatchingUp, angle > panelFollowAngle || simd_length(offset) > panelFollowDistance {
                isPanelCatchingUp = true
            }
            guard isPanelCatchingUp else { return }
            panel.position += offset * (1 - exp(-panelFollowSpeed * deltaTime))
            if simd_length(offset) < 0.02 {
                isPanelCatchingUp = false
            }
        }

        // Face the viewer: yaw so the panel's +Z (its front) points at the head,
        // then tilt it up since it sits below the eyeline.
        let toHead = simd_normalize(head - panel.position)
        let yaw = simd_quatf(angle: directionYaw(toHead), axis: SIMD3<Float>(0, 1, 0))
        let tilt = simd_quatf(angle: -asin(toHead.y), axis: SIMD3<Float>(1, 0, 0))
        panel.orientation = yaw * tilt
    }

    /// True if the entity is the model or one of its parts (as opposed to the panel).
    private func isPartOfModel(_ entity: Entity) -> Bool {
        sequence(first: entity, next: { $0.parent }).contains { $0 === worldRoot }
    }

    // MARK: - Head pose

    /// The head's transform in the immersive space, or a default pose until tracking is up.
    private func deviceTransform() -> simd_float4x4 {
        worldTracking?.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.originFromAnchorTransform
            ?? Self.defaultHeadPose
    }

    private func headPosition() -> SIMD3<Float> {
        deviceTransform().translation
    }

    /// The yaw of a direction, as an angle about +Y that turns +Z onto it.
    private func directionYaw(_ direction: SIMD3<Float>) -> Float {
        atan2(direction.x, direction.z)
    }

    // MARK: - Grab-the-world pinch

    /// The pinch currently driving navigation. A second pinch while one is
    /// active is ignored.
    private struct ActivePinch {
        let id: SpatialEventCollection.Event.ID
        let isRightHand: Bool
        var lastLocation: SIMD3<Float>
    }

    /// Pinch on the model and drag. Left hand pulls the world past you (vertical
    /// movement is ignored so walls stay on the floor). Right hand swings the
    /// world around you: the room turns by the angle your hand sweeps. The model
    /// goes translucent while pinching.
    private var worldPinchGesture: some Gesture {
        SpatialEventGesture()
            .targetedToAnyEntity()
            .onChanged(handlePinchEvents)
            .onEnded(handlePinchEvents)
    }

    private func handlePinchEvents(_ value: EntityTargetValue<SpatialEventCollection>) {
        for event in value.gestureValue {
            handlePinchEvent(event, in: value)
        }
    }

    private func handlePinchEvent(_ event: SpatialEventCollection.Event, in value: EntityTargetValue<SpatialEventCollection>) {
        guard event.phase == .active else {
            if activePinch?.id == event.id {
                activePinch = nil
                opacityRestoreTask = delayed(dragOpacityLinger) { setModelTranslucent(false) }
            }
            return
        }

        guard var pinch = activePinch else {
            // Pinches on the control panel (or anything else that isn't the model) are not navigation.
            guard isPartOfModel(value.entity) else { return }
            let location = value.convert(event.location3D, from: .local, to: .scene)
            activePinch = ActivePinch(id: event.id, isRightHand: event.chirality == .right, lastLocation: location)
            setModelTranslucent(true)
            return
        }
        guard pinch.id == event.id, let root = worldRoot else { return }

        let location = value.convert(event.location3D, from: .local, to: .scene)
        let previous = pinch.lastLocation
        pinch.lastLocation = location
        activePinch = pinch

        if pinch.isRightHand {
            let head = headPosition()
            let before = SIMD2(previous.x - head.x, previous.z - head.z)
            let after = SIMD2(location.x - head.x, location.z - head.z)
            guard simd_length(before) > minimumRotationRadius, simd_length(after) > minimumRotationRadius else { return }
            let sweep = AppModel.wrapAngle(atan2(after.y, after.x) - atan2(before.y, before.x))
            appModel.rotateWorld(byYaw: sweep, around: head)
        } else {
            var delta = location - previous
            delta.y = 0
            guard delta != .zero else { return }
            appModel.moveWorld(by: delta)
            followTerrainIfEnabled(in: root)
        }
    }

    private func setModelTranslucent(_ isTranslucent: Bool) {
        opacityRestoreTask?.cancel()
        opacityRestoreTask = nil
        isDragTranslucent = isTranslucent
        applyPassthrough()
    }

    /// Applies the chosen passthrough level to the model and skybox, or at least
    /// partial passthrough while pinching. Full passthrough hides them outright.
    private func applyPassthrough() {
        let level = isDragTranslucent ? max(appModel.passthrough, .partial) : appModel.passthrough
        for entity in [worldRoot, skyboxHolder].compactMap({ $0 }) {
            entity.isEnabled = level != .full && (entity !== skyboxHolder || appModel.showSkybox)
            if level.modelOpacity < 1 {
                entity.components.set(OpacityComponent(opacity: level.modelOpacity))
            } else {
                entity.components.remove(OpacityComponent.self)
            }
        }
    }

    // MARK: - Aligning the model with the real room

    /// Uses ARKit's detected walls and floor to line the model up with the room:
    /// 1. Rotate so the model's walls run parallel to the largest real wall.
    /// 2. Put the model's floor on the real floor.
    /// 3. Slide the model so the wall in front of you is as far away as the real wall
    ///    (and likewise for a second wall at right angles, which pins the other axis).
    ///
    /// Stand roughly where you'd be in the model before pressing the button. Walls
    /// come in 90° multiples, so a wrong facing is one right-hand quarter sweep away.
    private func alignToRoom(_ root: Entity) {
        let head = headPosition()
        let anchors = Array(planeAnchors.values).filter { planeArea($0) >= minimumPlaneArea }
        let walls = anchors
            .filter { $0.alignment == .vertical }
            .sorted { planeArea($0) > planeArea($1) }
        let floor = anchors
            .filter { $0.alignment == .horizontal && planePosition($0).y < head.y - 0.5 }
            .min { planePosition($0).y < planePosition($1).y }

        guard let mainWall = walls.first else {
            appModel.alignmentMessage = "No walls detected yet. Look around the room and try again."
            return
        }

        // 1. Yaw: match the model's wall direction to the real wall direction, modulo 90°.
        let wallYaw = horizontalYaw(of: planeNormal(mainWall))
        let modelYaw = horizontalYaw(of: modelWallAxis(of: root))
        appModel.rotateWorld(byYaw: AppModel.wrapAngle(wallYaw - modelYaw, period: AppModel.quarterTurn), around: head)
        applyNavigationTransform(to: root)

        // 2. Floor: model floor under the viewer onto the real floor.
        resetHeight(for: root)
        if let floor {
            appModel.moveWorld(by: SIMD3<Float>(0, planePosition(floor).y, 0))
        }
        applyNavigationTransform(to: root)

        // 3. Position: for up to two perpendicular walls, make the nearest model
        // surface in that direction sit exactly where the real wall is.
        var usedNormals: [SIMD3<Float>] = []
        for wall in walls where usedNormals.count < 2 {
            var normal = planeNormal(wall)
            guard usedNormals.allSatisfy({ abs(simd_dot($0, normal)) < 0.7 }) else { continue }

            var realDistance = simd_dot(planePosition(wall) - head, normal)
            if realDistance < 0 {
                normal = -normal
                realDistance = -realDistance
            }

            guard let modelDistance = modelSurfaceDistance(from: head, along: normal, in: root) else { continue }
            appModel.moveWorld(by: normal * (realDistance - modelDistance))
            applyNavigationTransform(to: root)
            usedNormals.append(normal)
        }

        let floorText = floor == nil ? "" : " and the floor"
        appModel.alignmentMessage = "Aligned to \(usedNormals.count) wall\(usedNormals.count == 1 ? "" : "s")\(floorText). Fine-tune by pinching and dragging if needed."
    }

    private func planePosition(_ anchor: PlaneAnchor) -> SIMD3<Float> {
        anchor.originFromAnchorTransform.translation
    }

    /// Plane geometry lies in the anchor's XZ plane, so the anchor's Y axis is the normal.
    /// Flattened to horizontal because we only care about yaw.
    private func planeNormal(_ anchor: PlaneAnchor) -> SIMD3<Float> {
        let axis = anchor.originFromAnchorTransform.column3(1)
        return simd_normalize(SIMD3<Float>(axis.x, 0, axis.z))
    }

    private func planeArea(_ anchor: PlaneAnchor) -> Float {
        let extent = anchor.geometry.extent
        return extent.width * extent.height
    }

    /// Whichever of the model root's axes is most horizontal in the immersive space.
    /// Assumes the model's walls run along its own axes, which is true for almost every
    /// room design export.
    private func modelWallAxis(of root: Entity) -> SIMD3<Float> {
        let orientation = root.orientation(relativeTo: nil)
        let axes = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
        let worldAxes = axes.map { simd_act(orientation, $0) }
        let flattest = worldAxes.min { abs($0.y) < abs($1.y) }!
        return simd_normalize(SIMD3<Float>(flattest.x, 0, flattest.z))
    }

    /// Distance from `origin` to the nearest model surface in `direction`, measured
    /// in the immersive space's coordinates.
    private func modelSurfaceDistance(from origin: SIMD3<Float>, along direction: SIMD3<Float>, in root: Entity) -> Float? {
        guard let scene = root.scene else { return nil }
        let localOrigin = root.convert(position: origin, from: nil)
        let localDirection = simd_normalize(root.convert(direction: direction, from: nil))

        guard let hit = scene.raycast(origin: localOrigin,
                                      direction: localDirection,
                                      length: wallRaycastLength,
                                      query: .nearest,
                                      relativeTo: root).first else { return nil }

        let hitPosition = root.convert(position: hit.position, to: nil)
        return simd_length(hitPosition - origin)
    }

    /// The yaw of a horizontal vector measured from +X towards +Z. Only differences
    /// of these are used (wall vs model), so it deliberately differs from `directionYaw`.
    private func horizontalYaw(of vector: SIMD3<Float>) -> Float {
        atan2(vector.z, vector.x)
    }

    // MARK: - Plane detection

    private func startPlaneDetectionUpdates(with provider: PlaneDetectionProvider) {
        planeDetectionTask?.cancel()
        planeDetectionTask = Task {
            for await update in provider.anchorUpdates {
                if update.event == .removed {
                    planeAnchors.removeValue(forKey: update.anchor.id)
                } else {
                    planeAnchors[update.anchor.id] = update.anchor
                }
            }
        }
    }

    // MARK: - Hand tracking (hold a thumb + middle finger pinch to toggle full passthrough)

    private func startHandTrackingUpdates(with provider: HandTrackingProvider) {
        handTrackingTask?.cancel()
        handTrackingTask = Task {
            for await update in provider.anchorUpdates {
                handleHandAnchorUpdate(update)
            }
        }
    }

    private func handleHandAnchorUpdate(_ update: AnchorUpdate<HandAnchor>) {
        let anchor = update.anchor
        let chirality = anchor.chirality

        if update.event == .removed || !anchor.isTracked {
            setPinchStartTime(nil, for: chirality)
            setPinchActive(false, for: chirality)
            return
        }

        guard let handSkeleton = anchor.handSkeleton else {
            setPinchStartTime(nil, for: chirality)
            setPinchActive(false, for: chirality)
            return
        }

        let thumb = handSkeleton.joint(.thumbTip)
        let middle = handSkeleton.joint(.middleFingerTip)

        guard thumb.isTracked, middle.isTracked else {
            setPinchStartTime(nil, for: chirality)
            setPinchActive(false, for: chirality)
            return
        }

        let originFromAnchor = anchor.originFromAnchorTransform
        let thumbWorld = simd_mul(originFromAnchor, thumb.anchorFromJointTransform)
        let middleWorld = simd_mul(originFromAnchor, middle.anchorFromJointTransform)

        let distance = simd_distance(thumbWorld.translation, middleWorld.translation)

        let isPinching = isPinchActive(for: chirality)

        if !isPinching && distance <= pinchOnDistance {
            let now = CACurrentMediaTime()
            let startTime = pinchStartTime(for: chirality) ?? now
            setPinchStartTime(startTime, for: chirality)
            if now - startTime >= pinchHoldDuration {
                setPinchActive(true, for: chirality)
                setPinchStartTime(nil, for: chirality)
                appModel.toggleFullPassthrough()
            }
        } else if !isPinching && distance > pinchOnDistance {
            setPinchStartTime(nil, for: chirality)
        } else if isPinching && distance >= pinchOffDistance {
            setPinchActive(false, for: chirality)
            setPinchStartTime(nil, for: chirality)
        }
    }

    // MARK: - Helpers

    /// Runs `action` after `delay` unless the returned task is cancelled first.
    private func delayed(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func showModeCue(_ text: String) {
        modeCueTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            modeCueText = text
        }
        modeCueTask = delayed(.seconds(1.2)) {
            withAnimation(.easeIn(duration: 0.2)) {
                modeCueText = nil
            }
        }
    }

    /// Gives every mesh a collision shape (for terrain following and wall alignment
    /// raycasts) and makes it a gesture target (for grab-the-world pinching).
    private func prepareForInteraction(_ entity: Entity) async {
        if let modelEntity = entity as? ModelEntity,
           let mesh = modelEntity.model?.mesh {
            if let shape = try? await ShapeResource.generateStaticMesh(from: mesh) {
                modelEntity.collision = CollisionComponent(shapes: [shape], isStatic: true)
            } else {
                modelEntity.generateCollisionShapes(recursive: false, static: true)
            }
            modelEntity.components.set(InputTargetComponent())
        }

        for child in entity.children {
            await prepareForInteraction(child)
        }
    }

    private func terrainSurfaceHeight(below position: SIMD3<Float>, in root: Entity) -> Float? {
        guard let scene = root.scene else { return nil }

        let bounds = root.visualBounds(relativeTo: root)
        let verticalExtent = max(bounds.extents.y, 1)
        let origin = SIMD3<Float>(position.x, position.y + terrainProbeHeight, position.z)
        let rayLength = verticalExtent + abs(origin.y - bounds.center.y) + terrainProbeHeight

        return scene.raycast(
            origin: origin,
            direction: SIMD3<Float>(0, -1, 0),
            length: rayLength,
            query: .nearest,
            relativeTo: root
        ).first?.position.y
    }

    private func isPinchActive(for chirality: HandAnchor.Chirality) -> Bool {
        switch chirality {
        case .left:
            return leftPinchActive
        case .right:
            return rightPinchActive
        @unknown default:
            return false
        }
    }

    private func setPinchActive(_ isActive: Bool, for chirality: HandAnchor.Chirality) {
        switch chirality {
        case .left:
            leftPinchActive = isActive
        case .right:
            rightPinchActive = isActive
        @unknown default:
            break
        }
    }

    private func pinchStartTime(for chirality: HandAnchor.Chirality) -> TimeInterval? {
        switch chirality {
        case .left:
            return leftPinchStartTime
        case .right:
            return rightPinchStartTime
        @unknown default:
            return nil
        }
    }

    private func setPinchStartTime(_ time: TimeInterval?, for chirality: HandAnchor.Chirality) {
        switch chirality {
        case .left:
            leftPinchStartTime = time
        case .right:
            rightPinchStartTime = time
        @unknown default:
            break
        }
    }
}

#Preview {
    ImmersiveView()
        .environment(AppModel())
}
