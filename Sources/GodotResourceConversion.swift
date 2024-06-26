/**
 
Convert Godot Resources (meshes, textures, materials, etc.) to their RealityKit counterparts.
 
 */

//  Created by Kevin Watters on 1/19/24.

import SwiftGodot
import RealityKit
import Foundation

class ResourceCache {
    var projectContext: GodotProjectContext? = nil
    var materials: [SwiftGodot.Material: MaterialEntry] = .init()
    var textures:  [SwiftGodot.Texture: TextureEntry] = .init()
    
    func reset() {
        materials.removeAll()
        textures.removeAll()
    }
    
    func materialEntry(forGodotMaterial godotMaterial: SwiftGodot.Material) -> MaterialEntry {
        if materials[godotMaterial] == nil {
            materials[godotMaterial] = MaterialEntry(godotResource: godotMaterial)
        }
        return materials[godotMaterial]!
    }
    
    func textureEntry(forGodotTexture godotTexture: SwiftGodot.Texture) -> TextureEntry {
        if textures[godotTexture] == nil {
            textures[godotTexture] = TextureEntry(godotResource: godotTexture)
        }
        return textures[godotTexture]!
    }
    
    func rkTexture(forGodotTexture godotTexture: SwiftGodot.Texture) -> RealityKit.TextureResource {
        textureEntry(forGodotTexture: godotTexture).getTexture(resourceCache: self)
    }
}

class ResourceEntry<G, R> where G: SwiftGodot.Resource {
    fileprivate var godotResource: G? = nil
    fileprivate var rkResource: R? = nil
    fileprivate var changedToken: SwiftGodot.Object? = nil
    
    private func onChanged() {
        // TODO: haven't actually verified this works...
        
        print("\(Self.self) CHANGED", String(describing: godotResource))
        DispatchQueue.main.async {
            self.rkResource = nil
        }
    }
    
    init(godotResource: G) {
        self.godotResource = godotResource
        changedToken = godotResource.changed.connect(onChanged)
    }
    
    deinit {
        if let changedToken, let godotResource {
            godotResource.changed.disconnect(changedToken)
        }
        
        changedToken = nil
        godotResource = nil
    }
}

class TextureEntry: ResourceEntry<SwiftGodot.Texture, RealityKit.TextureResource> {
    func getTexture(resourceCache: ResourceCache) -> RealityKit.TextureResource {
        if let godotTex = godotResource as? SwiftGodot.Texture2D {
            if let projectContext = resourceCache.projectContext {
                return try! .load(contentsOf: projectContext.fileUrl(forGodotResourcePath: godotTex.resourcePath))
            } else {
                logError("projectContext not set in ResourceCache")
            }
        }
        
        return try! .load(named: "error-unknown-texture")
    }
}

class MaterialEntry: ResourceEntry<SwiftGodot.Material, RealityKit.Material> {
    func getMaterial(resourceCache: ResourceCache) -> RealityKit.Material {
        if rkResource == nil, let godotResource {
            if let stdMat = godotResource as? StandardMaterial3D {
                var rkMat = PhysicallyBasedMaterial()
                
                // TODO: flesh this out so that we respect as many Godot PBR fields as possible.
                // also should work for godot's ORMMaterial as well
                
                //
                // ALBEDO (base color)
                //
                if let albedoTexture = stdMat.albedoTexture {
                    rkMat.baseColor = .init(tint: uiColor(forGodotColor: stdMat.albedoColor), texture: .init(resourceCache.rkTexture(forGodotTexture: albedoTexture)))
                } else {
                    if stdMat.transparency == .alpha {
                        rkMat.baseColor = .init(tint: uiColor(forGodotColor: stdMat.albedoColor).withAlphaComponent(1.0))
                        rkMat.blending = .transparent(opacity: .init(floatLiteral: stdMat.albedoColor.alpha))
                    } else {
                        rkMat.baseColor = .init(tint: uiColor(forGodotColor: stdMat.albedoColor))
                    }
                }
                
                rkMat.metallic = PhysicallyBasedMaterial.Metallic(floatLiteral: Float(stdMat.metallic))
                rkMat.roughness = PhysicallyBasedMaterial.Roughness(floatLiteral: Float(stdMat.roughness))
                rkMat.textureCoordinateTransform = .init(offset: SIMD2<Float>(x: stdMat.uv1Offset.x, y: stdMat.uv1Offset.y), scale: SIMD2<Float>(x: stdMat.uv1Scale.x, y: stdMat.uv1Scale.y))
                
                //
                // EMISSION
                //
                if stdMat.emissionEnabled {
                    let emissiveColor: PhysicallyBasedMaterial.EmissiveColor
                    if let emissionTexture = stdMat.emissionTexture {
                        emissiveColor  = .init(color: uiColor(forGodotColor: stdMat.emission), texture: .init(resourceCache.rkTexture(forGodotTexture: emissionTexture)))
                    } else {
                        emissiveColor = .init(color: uiColor(forGodotColor: stdMat.emission))
                    }
                    
                    rkMat.emissiveColor = emissiveColor
                    rkMat.emissiveIntensity = Float(stdMat.emissionIntensity / 1000.0) // TODO: Godot docs say Material.emission_intensity is specified in nits and defaults to 1000. not sure how to convert this, since the RealityKit docs don't specify a unit.
                }
                
                rkResource = rkMat
            }
        }
        
        if rkResource == nil {
            logError("generating material from \(String(describing: godotResource))")
            rkResource = SimpleMaterial(color: .systemPink, isMetallic: false)
        }
        
        return rkResource!
    }
}

struct MeshCreationInfo: Hashable {
    var godotMesh: SwiftGodot.Mesh
    var godotSkeleton: SwiftGodot.Skeleton3D? = nil
    var isCsgMesh: Bool = false
}

private var meshCache: [MeshCreationInfo: MeshResource] = [:] // TODO @Leak



func createRealityKitMesh(node: Node3D, meshCreationInfo: MeshCreationInfo) -> MeshResource? {
    if let meshResource = meshCache[meshCreationInfo] {
        return meshResource
    }
    
    var meshResource: MeshResource? = nil
    doLoggingErrors {
        let meshContents = try meshContents(node: node, meshCreationInfo: meshCreationInfo, verbose: false)
        meshResource = try MeshResource.generate(from: meshContents)
    }

    if let meshResource {
        meshCache[meshCreationInfo] = meshResource
    }
    
    return meshResource
}
    
private func getInverseBindPoseMatrix(skeleton: Skeleton3D, boneIdx: Int32) -> simd_float4x4 {
    var mat: simd_float4x4 = .init(diagonal: .one)
    
    if boneIdx == -1 {
        return mat
    }
    
    var boneIdx = boneIdx
    while true {
        mat *= simd_inverse(simd_float4x4(skeleton.getBonePose(boneIdx: boneIdx)))
        
        let parentIdx = skeleton.getBoneParent(boneIdx: boneIdx)
        if parentIdx != -1 {
            boneIdx = parentIdx
        } else {
            break
        }
    }
    
    return mat
}


func createRealityKitSkeleton(skeleton: SwiftGodot.Skeleton3D) -> MeshResource.Skeleton? {
    var jointNames: [String] = []
    var inverseBindPoseMatrices: [simd_float4x4] = []
    var restPoseTransforms: [RealityKit.Transform] = []
    var parentIndices: [Int] = []

    for boneIdx in 0..<skeleton.getBoneCount() {
        jointNames.append(skeleton.getBoneName(boneIdx: boneIdx))
        inverseBindPoseMatrices.append(getInverseBindPoseMatrix(skeleton: skeleton, boneIdx: boneIdx))
        restPoseTransforms.append(RealityKit.Transform(skeleton.getBoneRest(boneIdx: boneIdx)))
        parentIndices.append(Int(skeleton.getBoneParent(boneIdx: boneIdx)))
    }
    
    let skeletonName = String(skeleton.name)
    return MeshResource.Skeleton(id: skeletonName.count > 0 ? skeletonName : "skeleton",
                                 jointNames: jointNames,
                                 inverseBindPoseMatrices: inverseBindPoseMatrices,
                                 restPoseTransforms: restPoseTransforms,
                                 parentIndices: parentIndices
    )
}

private func meshContents(node: Node3D,
                          meshCreationInfo: MeshCreationInfo,
                          verbose: Bool = false) throws -> MeshResource.Contents
{
    
    let mesh = meshCreationInfo.godotMesh
    let skeleton = meshCreationInfo.godotSkeleton
    let isCsgMesh = meshCreationInfo.isCsgMesh

    if mesh.getSurfaceCount() == 0 {
        return MeshResource.Contents()
    }
    
    enum ArrayType: Int { // TODO: are these already exposed from SwiftGodot somewhere?
        case ARRAY_VERTEX = 0
        case ARRAY_NORMAL = 1
        case ARRAY_TANGENT = 2
        case ARRAY_TEX_UV = 4
        case ARRAY_BONES = 10 /// PackedFloat32Array or PackedInt32Array of bone indices. Contains either 4 or 8 numbers per vertex depending on the presence of the ARRAY_FLAG_USE_8_BONE_WEIGHTS flag.
        case ARRAY_WEIGHTS = 11 /// PackedFloat32Array or PackedFloat64Array of bone weights in the range 0.0 to 1.0 (inclusive). Contains either 4 or 8 numbers per vertex depending on the presence of the ARRAY_FLAG_USE_8_BONE_WEIGHTS flag.
        case ARRAY_INDEX = 12
    }
    
    if verbose {
        print("--------\nmeshContents for node: \(node.name)")
    }
    
    var newContents = MeshResource.Contents()
    
    var rkSkeleton: MeshResource.Skeleton? = nil
    if let skeleton, let newSkeleton = createRealityKitSkeleton(skeleton: skeleton) {
        rkSkeleton = newSkeleton
        newContents.skeletons = MeshSkeletonCollection([newSkeleton])
    }
    

    var meshParts: [MeshResource.Part] = []
    for surfIdx in 0..<mesh.getSurfaceCount() {
        var meshPart = MeshResource.Part(id: "part\(surfIdx)", materialIndex: Int(surfIdx))
        defer { meshParts.append(meshPart) }
        
        if let arrayMesh = mesh as? ArrayMesh {
            let primitiveType = arrayMesh.surfaceGetPrimitiveType(surfIdx: surfIdx)
            if primitiveType != Mesh.PrimitiveType.triangles {
                logError("cannot make mesh for surfIdx \(surfIdx)--primitive type is \(primitiveType)")
                continue
            }
        }
        
        if verbose { print("surfIdx: \(surfIdx)") }
        
        let surfaceArrays = mesh.surfaceGetArrays(surfIdx: surfIdx)
        
        //
        // positions
        //
        guard let vertices = surfaceArrays[ArrayType.ARRAY_VERTEX.rawValue].cast(as: PackedVector3Array.self, debugName: "mesh vertices") else { continue }
        let verticesArray = vertices.map { simd_float3($0) }
        meshPart.positions = MeshBuffers.Positions(verticesArray)
        
        //
        // triangleIndices
        //
        let indicesVariant = surfaceArrays[ArrayType.ARRAY_INDEX.rawValue]
        var primitivesCount: Int? = nil
        switch indicesVariant.gtype {
        case .nil:
            if isCsgMesh {
                // Hack for CGS meshes whose vertices come in reverse winding order (for some reason?)
                // Note they have no index buffer.
                let indicesArray: [UInt32] = (0..<UInt32(verticesArray.count)).reversed()
                meshPart.triangleIndices = MeshBuffers.TriangleIndices(indicesArray)
            }
        case .packedInt32Array:
            guard let indices = surfaceArrays[ArrayType.ARRAY_INDEX.rawValue].cast(as: PackedInt32Array.self, debugName: "mesh indices") else { continue }
            let indicesArray: [UInt32]
            indicesArray = reverseWindingOrderOfIndexBuffer(indices.map { UInt32($0) })
            primitivesCount = indicesArray.count
            meshPart.triangleIndices = MeshBuffers.TriangleIndices(indicesArray)
        default:
            logError("ARRAY_INDEX was unexpected Variant type \(indicesVariant.gtype)")
        }
        

        //
        // normals
        //
        let normalsVariant = surfaceArrays[ArrayType.ARRAY_NORMAL.rawValue]
        if normalsVariant != .init(), let normals = normalsVariant.cast(as: PackedVector3Array.self, debugName: "normals") {
            let normalsArray = normals.map { simd_float3($0) }
            if verbose { print("  setting normals: \(normals.count)") }
            meshPart.normals = MeshBuffers.Normals(normalsArray)
        }
        
        //
        // tangents
        //
        let tangentsVariant = surfaceArrays[ArrayType.ARRAY_TANGENT.rawValue]
        if tangentsVariant != .init(), let tangents = tangentsVariant.cast(as: PackedFloat32Array.self, debugName: "tangents") {
            var i = 0
            var tangentsArray: [simd_float3] = []
            while i < tangents.count {
                let x: Float = tangents[i + 0]
                let y: Float = tangents[i + 1]
                let z: Float = tangents[i + 2]
                tangentsArray.append(simd_float3(x, y, z))
                // tangents[i + 3] is the binormal direction
                i += 4
            }
            meshPart.tangents = MeshBuffers.Tangents(tangentsArray)
        }
        
        if verbose {
            print("  primitives count: \(String(describing: primitivesCount))")
            print("  positions.count:", verticesArray.count)
        }
        
        //
        // uvs
        //
        let uvsVariant = surfaceArrays[ArrayType.ARRAY_TEX_UV.rawValue]
        if uvsVariant != .init(), let uvs = uvsVariant.cast(as: PackedVector2Array.self, debugName: "uvs") {
            let uvsArray = uvs.map { simd_float2(x: $0.x, y: 1 - $0.y) }
            if verbose { print("  setting texture coordinates: \(uvsArray.count)") }
            meshPart.textureCoordinates = MeshBuffers.TextureCoordinates(uvsArray)
        }
        
        //
        // jointInfluences
        //
        var jointInfluences: [MeshJointInfluence] = []

        // ARRAY_BONES
        do {
            let bonesVariant = surfaceArrays[ArrayType.ARRAY_BONES.rawValue]
            switch bonesVariant.gtype {
            case .nil:
                ()
            case .packedInt32Array:
                if let bones = bonesVariant.cast(as: PackedInt32Array.self, debugName: "ARRAY_BONES") {
                    jointInfluences = bones.map { boneIndex in MeshJointInfluence(jointIndex: Int(boneIndex), weight: 0) }
                }
            case .packedFloat32Array:
                if let bones = bonesVariant.cast(as: PackedFloat32Array.self, debugName: "ARRAY_BONES") {
                    jointInfluences = bones.map { MeshJointInfluence(jointIndex: Int($0), weight: 0) }
                }
            default:
                logError("ARRAY_BONES array had unexpected gtype: \(bonesVariant.gtype)")
            }
        }
        
        if verbose && jointInfluences.count > 0 {
            print("  jointInfluences.count: \(jointInfluences.count)")
        }
        
        // ARRAY_WEIGHTS
        do {
            let weightsVariant = surfaceArrays[ArrayType.ARRAY_WEIGHTS.rawValue]
            switch weightsVariant.gtype {
            case .nil:
                if jointInfluences.count > 0 {
                    logError("nil ARRAY_WEIGHTS but ARRAY_BONES present")
                }
            case .packedFloat32Array:
                if let weights = weightsVariant.cast(as: PackedFloat32Array.self, debugName: "ARRAY_WEIGHTS") {
                    if jointInfluences.count <= weights.count {
                        weights.enumerated().forEach { (idx, weight) in jointInfluences[idx].weight = weight }
                    } else {
                        logError("more weights than bone indices")
                    }
                }
            case .packedFloat64Array:
                if let weights = weightsVariant.cast(as: PackedFloat64Array.self, debugName: "ARRAY_WEIGHTS") {
                    if jointInfluences.count <= weights.count {
                        weights.enumerated().forEach { (idx, weight) in jointInfluences[idx].weight = Float(weight) } // note: precision loss from 64 to 32 bit
                    } else {
                        logError("more weights than bone indices")
                    }
                }
            default:
                logError("ARRAY_WEIGHTS array had unexpected gtype: \(weightsVariant.gtype)")
            }
        }
        
        let influencesPerVertex = jointInfluences.count / verticesArray.count
        if influencesPerVertex > 0 {
            if !(influencesPerVertex == 4 || influencesPerVertex == 8) {
                logError("expected influencesPerVertex to be 4 or 8, but it was \(influencesPerVertex) - omitting jointInfluences")
            } else {
                meshPart.jointInfluences = .init(influences: MeshBuffers.JointInfluences(jointInfluences), influencesPerVertex: influencesPerVertex)
                meshPart.skeletonID = rkSkeleton?.id
                if let skeletonID = meshPart.skeletonID, newContents.skeletons[skeletonID] == nil {
                    logError("no skeleton passed for id '\(skeletonID)'")
                }
            }
        }
    }
    
    var modelCollection = MeshModelCollection()
    modelCollection.insert(MeshResource.Model(id: "model_\(node.name)", parts: meshParts))
    newContents.models = modelCollection
    
    return newContents
}

private func reverseWindingOrderOfIndexBuffer<T>(_ buffer: [T]) -> [T]  where T: BinaryInteger {
    var result: [T] = Array.init(repeating: T(), count: buffer.count)
    
    assert(buffer.count % 3 == 0)
    
    var i = 0
    while i < buffer.count {
        result[i + 0] = buffer[i + 0]
        result[i + 1] = buffer[i + 2]
        result[i + 2] = buffer[i + 1]
        
        i += 3
    }
    
    return result
}
