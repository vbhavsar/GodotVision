/**
 
Mirror Node3Ds from Godot to RealityKit.
 
 */

//  Created by Kevin Watters on 1/3/24.

let HANDLE_RUNLOOP_MANUALLY = true
let DO_EXTRA_DEBUGGING = false

import Foundation
import SwiftUI
import RealityKit
import SwiftGodot
import SwiftGodotKit

private let whiteNonMetallic = SimpleMaterial(color: .white, isMetallic: false)

let VISION_VOLUME_CAMERA_GODOT_NODE_NAME = "VisionVolumeCamera"
let SHOW_CORNERS = false

struct NodeData {
    enum Flags: UInt32 {
        case VISIBLE = 1
    }
    
    var objectID: Int64
    var parentID: Int64
    var pos: simd_float4
    var rot: simd_quatf
    var scl: simd_float4
    
    var nativeHandle: UnsafeRawPointer
    var flags: UInt32
    var pad0: Float
}

enum ShapeSubType {
    case None
    case Box(size: simd_float3)
    case Sphere(radius: Float)
    case Capsule(height: Float, radius: Float)
    case Mesh(SwiftGodot.Mesh, Skeleton3D?)
}

// TODO: Maybe remove this struct entirely? we used to run Godot on a background thread, and used this to communicate all the "rendering" data back to the main thread. but now that the two loops are intertwined it may not be necessary.
struct DrawEntry {
    var name: String? = nil
    var instanceId: Int64 = 0
    var parentId: Int64 = 0
    var inputRayPickable: ShapeSubType? = nil
    var hoverEffect: Bool = false
    // properties to split off into an "instantiation packet"
    var shape: ShapeSubType = .None
    var materials: [MaterialEntry] = []
    var node: SwiftGodot.Node3D
}

struct AudioStreamPlay {
    var godotInstanceID: Int64 = 0
    var resourcePath: String
    var volumeDb: Double = 0
    var prepareOnly: Bool = false
    var retryCount = 0
}

public class GodotVisionCoordinator: NSObject, ObservableObject {
    struct InitOptions {
        var godotProjectFileUrl: URL? = nil /// Where to find the Godot project files. Defaults to `Godot_Project` in the main application bundle.
    }
    
    private var godotInstanceIDToEntity: [Int64: Entity] = [:]
    
    private var godotEntitiesParent = Entity() /// The tree of RealityKit Entities mirroring Godot Node3Ds gets parented here.
    private var eventSubscription: EventSubscription? = nil
    private var nodeTransformsChangedToken: SwiftGodot.Object? = nil
    private var nodeAddedToken: SwiftGodot.Object? = nil
    private var nodeRemovedToken: SwiftGodot.Object? = nil
    private var processFrameToken: SwiftGodot.Object? = nil
    private var receivedRootNode = false
    private var resourceCache: ResourceCache = .init()
    private var sceneTree: SceneTree? = nil
    private var volumeCamera: SwiftGodot.Node3D? = nil
    private var audioStreamPlays: [AudioStreamPlay] = []
    private var _audioResources: [String: AudioFileResource] = [:]
    
    private var godotInstanceIDsRemovedFromTree: Set<UInt> = .init()
    private var volumeCameraPosition: simd_float3 = .zero
    private var volumeCameraBoxSize: simd_float3 = .one
    private var realityKitVolumeSize: simd_double3 = .one /// The size we think the RealitKit volume is, in meters, as an application in the user's AR space.
    private var godotToRealityKitRatio: Float = 0.05 // default ratio - this is adjusted when realityKitVolumeSize size changes
    
    public func changeScaleIfVolumeSizeChanged(_ volumeSize: simd_double3) {
        if volumeSize != realityKitVolumeSize {
            realityKitVolumeSize = volumeSize
            let ratio  = simd_float3(realityKitVolumeSize) / volumeCameraBoxSize
            godotToRealityKitRatio = max(max(ratio.x, ratio.y), ratio.z)
            self.godotEntitiesParent.scale = .one * godotToRealityKitRatio
        }
    }
    
    public func reloadScene() {
        print("reloadScene currently doesn't work for loading a new version of the scene saved from the editor, since Xcode copies the Godot_Project into the application's bundle only once at build time.")
        resetRealityKit()
        if let sceneFilePath = self.sceneTree?.currentScene?.sceneFilePath {
            self.changeSceneToFile(atResourcePath: sceneFilePath)
        } else {
            logError("cannot reload, no .sceneFilePath")
        }
    }

    public func changeSceneToFile(atResourcePath sceneResourcePath: String) {
        guard let sceneTree else { return }
        print("CHANGING SCENE TO", sceneResourcePath)
        
        self.receivedRootNode = false // we will "regrab" the root node and do init stuff with it again.
        
        let callbackRunner = GodotSwiftBridge.instance
        if let parent = callbackRunner.getParent() {
            parent.removeChild(node: callbackRunner)
        }
        
        let result = sceneTree.changeSceneToFile(path: sceneResourcePath)
        if SwiftGodot.GodotError.ok != result {
            logError("changeSceneToFile result was not ok: \(result)")
        }
    }
    
    public func initGodot() {
        var args = [
            ".",  // TODO: not sure about this, I think it's the "project directory" -- ios build command line eats the first argument.
            
            // We want Godot to run in headless mode, meaning: don't open windows, don't render anything, don't play sounds.
            "--headless",
            
            // The GodotVision Godot fork sees this argument and assumes that we will tick the main loop manually.
            "--runLoopHandledByHost"
        ]
        
        // Here we tell Godot where to find our Godot project.
        
        // args.append(contentsOf: ["--main-pack", getPackFileURLString()])
        args.append(contentsOf: ["--path", getProjectDir()])
        
        // This is the SwiftGodotKit "entry" point
        runGodot(args: args,
                 initHook: initHook,
                 loadScene: self.receivedSceneTree,
                 loadProjectSettings: { _ in },
                 verbose: true)
    }
    
    private func receivedSceneTree(sceneTree: SwiftGodot.SceneTree) {
        print("loadSceneCallback", sceneTree.getInstanceId(), sceneTree)
        
        // the packfile load happens after this callback. so as a hack we use nodeAdded for now to notice a specially named root node coming into being.
        
        nodeTransformsChangedToken = sceneTree.nodeTransformsChanged.connect(onNodeTransformsChanged)
        nodeAddedToken             = sceneTree.nodeAdded.connect(onNodeAdded)
        nodeRemovedToken           = sceneTree.nodeRemoved.connect(onNodeRemoved)
        processFrameToken          = sceneTree.processFrame.connect(onGodotFrame)
        
        self.sceneTree = sceneTree
        
        #if false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            print("RK HIEARCHY-------")
            printEntityTree(self.godotEntitiesParent)
        }
        #endif
    }
    
    private func onNodeRemoved(_ node: SwiftGodot.Node) {
        let _ = godotInstanceIDsRemovedFromTree.insert(node.getInstanceId())
    }
    
    private func onNodeTransformsChanged(_ packedByteArray: PackedByteArray) {
        guard let data = packedByteArray.asDataNoCopy() else {
            return
        }
        
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            ptr.withMemoryRebound(to: NodeData.self) { nodeDatas in
                _receivedNodeDatas(nodeDatas)
            }
        }
    }
    
    private var nodeIdsForNewlyEnteredNodes: [(Int64, Bool)] = []
    
    private func onNodeAdded(_ node: SwiftGodot.Node) {
        let isRoot = node.getParent() == node.getTree()?.root
        
        // TODO: Hack to get around the fact that the nodes coming in don't cast properly as their subclass yet. outside of this signal handler they do, so we store the id for later.
        nodeIdsForNewlyEnteredNodes.append((Int64(node.getInstanceId()), isRoot))
        
        if isRoot && !receivedRootNode {
            receivedRootNode = true
            
            resetRealityKit()
            
            //print("GOT ROOT NODE, attaching callback runner", node)
            node.addChild(node: GodotSwiftBridge.instance)
            GodotSwiftBridge.instance.onAudioStreamPlayed = { [weak self] (playInfo: AudioStreamPlay) -> Void in
                guard let self else { return }
                audioStreamPlays.append(playInfo)
            }
        }
    }
    
    private func didReceiveGodotVolumeCamera(_ node: Node3D) {
        volumeCamera = node
        
        guard let area3D = volumeCamera as? Area3D else {
            logError("expected node '\(VISION_VOLUME_CAMERA_GODOT_NODE_NAME)' to be an Area3D, but it was a \(node.godotClassName)")
            return
        }
        
        let collisionShape3Ds = area3D.findChildren(pattern: "*", type: "CollisionShape3D")
        if collisionShape3Ds.count != 1 {
            logError("expected \(VISION_VOLUME_CAMERA_GODOT_NODE_NAME) to have exactly one child with CollisionShape3D, but got \(collisionShape3Ds.count)")
            return
        }
        
        guard let collisionShape3D = collisionShape3Ds[0] as? CollisionShape3D else {
            logError("Could not cast child as CollisionShape3D")
            return
        }
        
        guard let boxShape3D = collisionShape3D.shape as? BoxShape3D else {
            logError("Could not cast shape as BoxShape3D in CollisionShape3D child of \(VISION_VOLUME_CAMERA_GODOT_NODE_NAME)")
            return
        }
        
        let godotVolumeBoxSize = simd_float3(boxShape3D.size)
        volumeCameraBoxSize = godotVolumeBoxSize
        
        let ratio = simd_float3(realityKitVolumeSize) / godotVolumeBoxSize
        
        // Check that the boxes (realtikit and godot) have the same "shape"
        if !(ratio.x.isApproximatelyEqualTo(ratio.y) && ratio.y.isApproximatelyEqualTo(ratio.z)) {
            logError("expected the proportions of the RealityKit volume to match the godot volume! the camera volume may be off.")
        }
        godotToRealityKitRatio = max(max(ratio.x, ratio.y), ratio.z)
        self.godotEntitiesParent.scale = .one * godotToRealityKitRatio
    }
    
    func resetRealityKit() {
        assert(Thread.current.isMainThread)
        audioStreamPlays.removeAll()
        resourceCache.reset()
        skeletonEntities.removeAll()
        for child in godotEntitiesParent.children.map({ $0 }) {
            child.removeFromParent()
        }
    }
    
    private func onGodotFrame() {
        if let volumeCamera {
            // should do rotation too, but idk how to go from godot rotation to RK 'orientation'
            // ie: physicsEntitiesParent.orientation = some_function(volumeCamera.rotation)
            // use scale here too
            volumeCameraPosition = simd_float3(volumeCamera.globalPosition) * -1 * godotToRealityKitRatio
        }
    }
    
    public func setupRealityKitScene(_ content: RealityViewContent, volumeSize: simd_double3) -> Entity {
        assert(Thread.current.isMainThread)
        
        realityKitVolumeSize = volumeSize
        
        if SHOW_CORNERS {
            // Place some cubes to show the edges of the realitykit volume.
            let volumeDebugParent = Entity()
            volumeDebugParent.name = "volumeDebugParent"
            
            let debugCube = MeshResource.generateBox(size: 0.1)
            func addAtPoint(_ p: simd_float3) {
                let e = ModelEntity(mesh: debugCube, materials: [whiteNonMetallic])
                e.position = p
                content.add(e)
            }
            
            let half = simd_float3(volumeSize * 0.5)
            addAtPoint(.init(half.x, half.y, -half.z))
            addAtPoint(.init(half.x, -half.y, -half.z))
            addAtPoint(.init(-half.x, -half.y, -half.z))
            addAtPoint(.init(-half.x, -half.y, -half.z))
            
            addAtPoint(.init(half.x, half.y, half.z))
            addAtPoint(.init(half.x, -half.y, half.z))
            addAtPoint(.init(-half.x, -half.y, half.z))
            addAtPoint(.init(-half.x, -half.y, half.z))
        }
        
        // Register a per-frame RealityKit update function.
        eventSubscription = content.subscribe(to: SceneEvents.Update.self, realityKitPerFrameTick)
        
        // Create a root Entity to store all our mirrored Godot nodes-turned-RealityKit entities.
        godotEntitiesParent.name = "GODOTRK_ROOT"
        
        content.add(godotEntitiesParent)
        
        return godotEntitiesParent
    }

    public func viewDidDisappear() {
        if let eventSubscription {
            eventSubscription.cancel()
            self.eventSubscription = nil
        }
        
        // Disconnect SceneTree signals
        if let sceneTree {
            if let nodeTransformsChangedToken {
                sceneTree.nodeTransformsChanged.disconnect(nodeTransformsChangedToken)
                self.nodeTransformsChangedToken = nil
            }
            if let nodeAddedToken {
                sceneTree.nodeAdded.disconnect(nodeAddedToken)
                self.nodeAddedToken = nil
            }
            if let nodeRemovedToken {
                sceneTree.nodeRemoved.disconnect(nodeRemovedToken)
                self.nodeRemovedToken = nil
            }
            if let processFrameToken {
                sceneTree.processFrame.disconnect(processFrameToken)
                self.processFrameToken = nil
            }
            self.sceneTree = nil
        }
    }
    
    private func cacheAudioResource(resourcePath: String) -> AudioFileResource? {
        var audioResource: AudioFileResource? = _audioResources[resourcePath]
        if audioResource == nil {
            do {
                audioResource = try AudioFileResource.load(contentsOf: fileUrl(forGodotResourcePath: resourcePath))
            } catch {
                logError(error)
                return nil
            }
            
            _audioResources[resourcePath] = audioResource
        }
        return audioResource
    }
    
    private func _createRealityKitEntityForNewNode(_ node: SwiftGodot.Node) -> Entity {
        var materials: [RealityKit.Material]? = nil
        var skeleton3D: SwiftGodot.Skeleton3D? = nil
        var mesh: SwiftGodot.Mesh? = nil

        if let meshInstance3D = node as? MeshInstance3D {
            skeleton3D = meshInstance3D.skeleton.isEmpty() ? nil : (meshInstance3D.getNode(path: meshInstance3D.skeleton) as? Skeleton3D)
            mesh = meshInstance3D.mesh
            if let mesh {
                materials = []
                for i in 0...mesh.getSurfaceCount() - 1 {
                    if let material = meshInstance3D.getActiveMaterial(surface: i) {
                        materials?.append(resourceCache.materialEntry(forGodotMaterial: material).getMaterial(resourceCache: resourceCache))
                    }
                }
            }
        }
        
        var entity: Entity
        
        if let mesh, let node3D = node as? Node3D, let mesh = createRealityKitMesh(node: node3D, godotMesh: mesh, godotSkeleton: skeleton3D) {
            let usedMaterials = (materials?.count ?? 0 == 0) ? [SimpleMaterial(color: .white, isMetallic: false)] : materials!
            entity = ModelEntity(mesh: mesh, materials: usedMaterials)
        } else {
            entity = Entity()
        }

        let instanceID = Int64(node.getInstanceId())
        
        entity.name = "\(node.name)"
        godotInstanceIDToEntity[instanceID] = entity
        godotEntitiesParent.addChild(entity)
        
        // we only want to set shadows on entities with a mesh
        if mesh != nil {
            entity.components.set(GroundingShadowComponent(castsShadow: true))
        }
        
        let hoverEffect = Bool(node.getMeta(name: "hover_effect", default: Variant(false))) ?? false
        
        // TODO: we could have more fine-graned input ray pickable shaeps
        let inputRayPickable: ShapeSubType? = ((node as? CollisionObject3D)?.inputRayPickable ?? false) ? .Box(size: .one) : nil
        if inputRayPickable != nil {
            DispatchQueue.main.async {
                let bounds = entity.visualBounds(relativeTo: entity.parent)
                let collisionShape: RealityKit.ShapeResource = .generateBox(size: bounds.extents)
                var collision = CollisionComponent(shapes: [collisionShape])
                collision.filter = .init(group: [], mask: []) // disable for collision detection
                
                // TODO: this is a dummy collision shape from the visual bounds of the entity. we can do something smarter based on the actual godot shapes!
                
                entity.components.set(InputTargetComponent())
                
                if hoverEffect {
                    entity.components.set(HoverEffectComponent())
                }
                entity.components.set(collision)
            }
        }
        
        if let node3D = node as? Node3D {
            entity.transform = RealityKit.Transform(node3D.transform)
        }
        
        return entity
    }
    
    private func _receivedNodeDatas(_ nodeDatas: UnsafeBufferPointer<NodeData>) {
#if false
        var transformSetCount = 0
        let swiftStride = MemoryLayout<NodeData>.stride
        let swiftSize = MemoryLayout<NodeData>.size
        //print("SWIFT offsetof transform", MemoryLayout<NodeData>.offset(of: \.transform))
        print("SWIFT offsetof rotation", MemoryLayout<NodeData>.offset(of: \.rot))
        print("SWIFT stride", swiftStride, "size", swiftSize)
        print("Swift bound array has", nodeDatas.count, "items.")
        print("DATA", ptr.baseAddress, "has", data.count, "bytes of raw data")
#endif
        for nodeData in nodeDatas {
            if nodeData.objectID == 0 { continue }
            
            guard let entity = godotInstanceIDToEntity[nodeData.objectID] else {
                continue
            }
            
            // Update Transform
            var t = RealityKit.Transform()
            t.translation = .init(nodeData.pos.x, nodeData.pos.y, nodeData.pos.z)
            t.rotation = nodeData.rot
            t.scale = .init(nodeData.scl.x, nodeData.scl.y, nodeData.scl.z)
            
            entity.transform = t
            //transformSetCount += 1
            
            // print(entity.id, t.translation)
            
            // Update isEnabled
            entity.isEnabled = (nodeData.flags & NodeData.Flags.VISIBLE.rawValue) != 0
        }
    }
    
    private func isSkeletonNode(node: SwiftGodot.Node3D, entity: RealityKit.Entity) -> Bool {
        if let modelEntity = entity as? ModelEntity, let model = modelEntity.model, let _ = model.mesh.contents.skeletons.first(where: { _ in true /* TODO: hack, no */ }) {
            if let meshInstance3D = node as? MeshInstance3D, let skeleton = meshInstance3D.getNode(path: meshInstance3D.skeleton) as? Skeleton3D {
                return true
            }
        }
        
        return false
    }
    
    private func updateSkeletonNode(node: SwiftGodot.Node3D, entity: RealityKit.Entity) {
        // TODO: we might be able to register for an event when the bone poses change, and respond to that, instead of doing a per frame check. @Perf
        if let modelEntity = entity as? ModelEntity, let model = modelEntity.model, let _ = model.mesh.contents.skeletons.first(where: { _ in true /* TODO: hack, no */ }) {
            if let meshInstance3D = node as? MeshInstance3D, let skeleton = meshInstance3D.getNode(path: meshInstance3D.skeleton) as? Skeleton3D {
                var transforms: [Transform] = []
                var jointNames: [String] = []
                
                for boneIdx in 0..<skeleton.getBoneCount() {
                    transforms.append(Transform(skeleton.getBonePose(boneIdx: boneIdx)))
                    if DO_EXTRA_DEBUGGING {
                        jointNames.append(skeleton.getBoneName(boneIdx: boneIdx))
                    }
                }
                
                modelEntity.jointTransforms = transforms
                if DO_EXTRA_DEBUGGING {
                    if jointNames != modelEntity.jointNames {
                        logError("joint names do not match \(jointNames) \(modelEntity.jointNames)")
                    }
                }
            }
        }
    }
    
    private var skeletonEntities: Set<Entity> = .init()
    
    private func realityKitPerFrameTick(_ event: SceneEvents.Update) {
        if stepGodotFrame() {
            print("GODOT HAS QUIT")
            // TODO: ask visionOS application to quit? or...?
        }
        
        for (id, isRoot) in nodeIdsForNewlyEnteredNodes {
            guard let node = GD.instanceFromId(instanceId: id) as? Node else {
                logError("No new Node instance for id \(id)")
                continue
            }
            
            let entity = _createRealityKitEntityForNewNode(node)
            if let node3D = node as? Node3D, isSkeletonNode(node: node3D, entity: entity) {
                entity.components.set(GodotNode(node3D: node3D))
                skeletonEntities.insert(entity)
            }
            
            // we notice a specially named node for the "bounds"
            if node.name == VISION_VOLUME_CAMERA_GODOT_NODE_NAME, let node3D = node as? Node3D {
                didReceiveGodotVolumeCamera(node3D)
            }
            
            if let audioStreamPlayer3D = node as? AudioStreamPlayer3D {
                if node.hasSignal("on_play") {
                    let _ = node.connect(signal: "on_play", callable: .init(object: GodotSwiftBridge.instance, method: .init("onAudioStreamPlayerPlayed")))
                } else {
                    print("WARNING: You're using AudioStreamPlayer3D, but we couldn't find an 'on_play' signal. Did you use RKAudioStreamPlayer? Remember to call '.play_rk()' to trigger the sound effect as well.")
                }
                
                // See if we need to prepare the audio resource (prevents a hitch on first play).
                if let autoPrepareResource = Bool(node.get(property: "auto_prepare_resource")), autoPrepareResource {
                    GodotSwiftBridge.instance.onAudioStreamPlayerPrepare(audioStreamPlayer3D: audioStreamPlayer3D)
                }
            }
            
            if !isRoot, let nodeParent = node.getParent() {
                let parentId = Int64(nodeParent.getInstanceId())
                if let parent = godotInstanceIDToEntity[parentId] {
                    entity.setParent(parent)
                } else {
                    logError("could not find parent for id \(parentId)")
                }
            }
        }
        nodeIdsForNewlyEnteredNodes.removeAll()

        
        var retries: [AudioStreamPlay] = []
        
        defer { 
            audioStreamPlays = retries
            godotInstanceIDsRemovedFromTree.removeAll()
        }
        
        func entity(forGodotInstanceID godotInstanceId: Int64) -> Entity? {
            return godotInstanceIDToEntity[godotInstanceId]
        }
        
        // Play any AudioStreamPlayer3D sounds
        for var audioStreamPlay in audioStreamPlays {
            guard let entity = entity(forGodotInstanceID: audioStreamPlay.godotInstanceID) else {
                audioStreamPlay.retryCount += 1
                if audioStreamPlay.retryCount < 100 {
                    retries.append(audioStreamPlay) // we may not have seen the instance yet.
                }
                continue
            }
            
            if let audioResource = cacheAudioResource(resourcePath: audioStreamPlay.resourcePath)
            {
                if audioStreamPlay.prepareOnly {
                    let _ = entity.prepareAudio(audioResource)
                } else {
                    let audioPlaybackController = entity.playAudio(audioResource)
                    audioPlaybackController.gain = audioStreamPlay.volumeDb
                }
            }
        }
        
        // Remove any RealityKit Entities for Godot nodes that were removed from the Godot tree.
        for instanceIdRemovedFromTree in godotInstanceIDsRemovedFromTree {
            guard let entity = godotInstanceIDToEntity[Int64(instanceIdRemovedFromTree)] else { continue }
            entity.components.remove(GodotNode.self)
            entity.removeFromParent()
            skeletonEntities.remove(entity)
            godotInstanceIDToEntity.removeValue(forKey: Int64(instanceIdRemovedFromTree))
        }
        
        // Update skeletons
        for entity in skeletonEntities {
            if let node = entity.components[GodotNode.self]?.node3D {
                updateSkeletonNode(node: node, entity: entity)
            }
        }
        
        godotEntitiesParent.position = volumeCameraPosition
    }
    
    func godotInstanceFromRealityKitEntityID(_ eID: Entity.ID) -> SwiftGodot.Object? {
        for (godotInstanceID, rkEntity) in godotInstanceIDToEntity where rkEntity.id == eID {
            guard let godotInstance = GD.instanceFromId(instanceId: godotInstanceID) else {
                logError("could not get Godot instance from id \(godotInstanceID)")
                continue
            }
            
            return godotInstance
        }
        
        return nil
    }
    
    func rkGestureLocationToGodotWorldPosition(_ value: EntityTargetValue<DragGesture.Value>, _ point3D: Point3D) -> SwiftGodot.Vector3 {
        // TODO: this is 100% not actually correct.
        let sceneLoc = value.convert(point3D, from: .local, to: .scene)
        let godotLoc = godotEntitiesParent.convert(position: simd_float3(sceneLoc), from: nil) + simd_float3(0, 0, volumeCameraBoxSize.z * 0.5)
        return .init(godotLoc)
    }
    
    func receivedDrag(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let obj = self.godotInstanceFromRealityKitEntityID(value.entity.id) else { return }
        if !obj.hasSignal("drag") {
            return
        }

        // pass a dictionary of values to the drag signal
        let dict: GDictionary = .init()
        dict["start_location"] = Variant(rkGestureLocationToGodotWorldPosition(value, value.startLocation3D))
        dict["location"] = Variant(rkGestureLocationToGodotWorldPosition(value, value.location3D))
        dict["predicted_end_location"] = Variant(rkGestureLocationToGodotWorldPosition(value, value.predictedEndLocation3D))
        if let startInputDevicePose3D = value.startInputDevicePose3D,
           let inputDevicePose3D = value.inputDevicePose3D 
        {
            dict["pose_rotation"] = Variant(SwiftGodot.Quaternion(inputDevicePose3D.rotation.quaternion))
            dict["start_pose_rotation"] = Variant(SwiftGodot.Quaternion(startInputDevicePose3D.rotation.quaternion))
        }
        
        obj.emitSignal("drag", Variant(dict))
    }
    
    func receivedDragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let obj = godotInstanceFromRealityKitEntityID(value.entity.id) else { return }
        if obj.hasSignal("drag_ended") {
            obj.emitSignal("drag_ended")
        }
    }
    
    /// RealityKit has received a SpatialTapGesture in the RealityView
    func receivedTap(event: EntityTargetValue<SpatialTapGesture.Value>) {
        let sceneLoc = event.convert(event.location3D, from: .local, to: .scene)
        var godotLocation = godotEntitiesParent.convert(position: simd_float3(sceneLoc), from: nil)
        godotLocation += .init(0, 0, volumeCameraBoxSize.z * 0.5)
        
        // TODO: hack. this normal is not always right. currently this just pretends everything you tap is a sphere???
        
        let realityKitNormal = normalize(event.entity.position(relativeTo: nil) - sceneLoc)
        let godotNormal = realityKitNormal
        
        guard let obj = self.godotInstanceFromRealityKitEntityID(event.entity.id) else { return }
            
        // Construct an InputEventMouseButton to send to Godot.
        
        let godotEvent = InputEventMouseButton()
        godotEvent.buttonIndex = .left
        godotEvent.doubleClick = false // TODO
        godotEvent.pressed = true
        
        let position = SwiftGodot.Vector3(godotLocation)
        let normal = SwiftGodot.Vector3(godotNormal)
        let shape_idx = 0
        
        // TODO: I think SwiftGodot provides a better way to emit signals than all these Variant() constructors
        obj.emitSignal("input_event", Variant.init(), Variant(godotEvent), Variant(position), Variant(normal), Variant(shape_idx))
    }
}


struct GodotNode: Component {
    var node3D: Node3D? = nil
}
