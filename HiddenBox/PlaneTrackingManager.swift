//
//  PlaneTrackingManager.swift
//  RealityKitContent
//
//  Created by boardguy.vision on 2025/01/03.
//

import ARKit
import RealityKit
import SwiftUI

@Observable
class PlaneTrackingManager {
    let session = ARKitSession()
    let planeDetectionProvider = PlaneDetectionProvider()
    
    var contentEntity = Entity()
    
    // 検出された平面ごとに UUIDで Entityを管理
    private var planeEntities = [UUID: Entity]()
 
    // sessionEventをモニターするだけなので、実装には必要ない
    func monitorSessionEvents() async {
        for await event in session.events {
            switch event {
            case .authorizationChanged(type: _, status: let status):
                print("Authorization changed to: \(status)")
                
                if status == .denied {
                    print("ARKit authorization is denied by the user")
                }
            case .dataProviderStateChanged(dataProviders: let providers, newState: let state, error: let error):
                if let error {
                    print("Data Provider reached an error state: \(error)")
                }
            @unknown default:
                fatalError("Unhandled new event \(event)")
            }
        }
    }
    
    func runARKitSession() async {
        do {
            try await session.run([self.planeDetectionProvider])
        } catch {
            print("error starting arkit session: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    func processPlaneDetectionUpdates() async {
            for await anchorUpdate in planeDetectionProvider.anchorUpdates {

                let anchor = anchorUpdate.anchor

                if anchorUpdate.event == .removed {
                    if let entity = planeEntities.removeValue(forKey: anchor.id) {
                        entity.removeFromParent()
                    }
                    return
                }

                // 検出したanchorに対して Entityを作成
                let entity = Entity()
                entity.name = "Plane \(anchor.id)"
                
                // anchor.originFromAnchorTransform:
                // matrix 4x4 検出した平面 anchorTransformからの変換行列を entityに設定
                // anchor.4x4行列データを持っているので、setTransformMatrixを使ってそのまま entity.tranformに簡単に一括設定できる
                // (これを使わないと transform.位置、.回転、.スケールにいちいち設定する手間が発生する
                entity.setTransformMatrix(anchor.originFromAnchorTransform, relativeTo: nil)

                
                // 平面のMeshを作成
                var meshResource: MeshResource?
                do {
                    let contents = MeshResource.Contents(planeGeometry: anchor.geometry)
                    meshResource = try MeshResource.generate(from: contents)
                } catch {
                    print("Failed to create a mesh resource for a plane anchor: \(error).")
                    return
                }
                
                if let meshResource = meshResource {
                    var material = UnlitMaterial(color: .red)
                    material.blending = .transparent(opacity: .init(floatLiteral: 0.1))
                    entity.components.set(ModelComponent(mesh: meshResource, materials: [material]))
                }
                
                // 衝突判定用のメッシュを作成
                var shape: ShapeResource?
                do {
                    let vertices = anchor.geometry.meshVertices.asSIMD3(ofType: Float.self)
                    shape = try await ShapeResource.generateStaticMesh(positions: vertices,
                                                                       faceIndices: anchor.geometry.meshFaces.asUInt16Array())
                    
                    if let shape = shape {
                        entity.components.set(CollisionComponent(shapes: [shape], isStatic: true))
                        let physics = PhysicsBodyComponent(mode: .static)
                        entity.components.set(physics)
                    }
                } catch {
                    print("Failed to create a static mesh for a plane anchor: \(error).")
                    return
                }
                
                if let existingEntity = planeEntities[anchor.id] {
                    existingEntity.removeFromParent()
                }

                planeEntities[anchor.id] = entity
                contentEntity.addChild(entity)
            }
        }
}

extension MeshResource.Contents {
    init(planeGeometry: PlaneAnchor.Geometry) {
        self.init()
        self.instances = [MeshResource.Instance(id: "main", model: "model")]
        var part = MeshResource.Part(id: "part", materialIndex: 0)
        part.positions = MeshBuffers.Positions(planeGeometry.meshVertices.asSIMD3(ofType: Float.self))
        
        part.triangleIndices = MeshBuffer(planeGeometry.meshFaces.asUInt32Array())
        
        self.models = [MeshResource.Model(id: "model", parts: [part])]
    }
}

// https://forums.developer.apple.com/forums/thread/695229
extension GeometrySource {
    func asArray<T>(ofType: T.Type) -> [T] {
        // stride: メモリ上に次のデータまでの間隔
        // IntやFloatのようなプリミティブ型は sizeと間隔が同じだが、SIMDなどの構造体はstride: 16byteが多い
        // SIMD3<Float>の場合、4,4,4ではなく構造体として持っているため アライメント規約により 4のpaddingが追加されて 16byteとなる
        
        // 呼び出し先で設定したTとself型の間隔をチェック
        // 異なると正確な処理が期待されないため
        assert(MemoryLayout<T>.stride == stride, "Invalid stride \(MemoryLayout<T>.stride); expected \(stride)")

        // count == meshVertices の数と同じであるはず
        // 三角頂点でなされたshapeの頂点の数
        return (0..<count).map {
            
            // MEMO: 下記の処理
            // 頂点のデータ(MTLBuffer)をメモリ上から順番に取得して、それを T型に変換する処理 (頂点の座標に変換)
            
            // 1. メモリ先頭アドレスを指すポインタを返す(生データを参照)
            buffer.contents()
                
                // advanced(by: ~) ポインタの指すメモリアドレスを、一定のbyte数だけ移動するためのメソッド
                // 先頭から順番に 型byte先へ移動
                // (Float, Float, Float)の場合、stride: 12
                // index0 - 0
                // index1 - 12
                // index2 - 24
                // ...
                // offsetは基本的に 0なので、最初のデータは 先頭から読み取れる
                // offsetを使う理由としてinterleavedされる可能性があるため
                // (よくわからないが、ARKitパフォーマンス向上のためにデータを最適化されることでoffset!=0になることがある)
                .advanced(by: offset + stride * Int($0)) //
                .assumingMemoryBound(to: T.self).pointee // 生データを T型に キャスト(変換)
        }
    }
    
    func asSIMD3<T>(ofType: T.Type) -> [SIMD3<T>] {
        // 呼び出し先で設定した型で (T, T, T) taple型として asArrayを呼び出す
        asArray(ofType: (T, T, T).self).map { .init($0.0, $0.1, $0.2)}
    }
    
    subscript(_ index: Int32) -> (Float, Float, Float) {
        precondition(format == .float3, "This subscript operator can only be used on GeometrySource instances with format .float3")
        return buffer.contents().advanced(by: offset + (stride * Int(index))).assumingMemoryBound(to: (Float, Float, Float).self).pointee
    }

}

extension GeometryElement {
    
    subscript(_ index: Int) -> [Int32] {
        precondition(bytesPerIndex == MemoryLayout<Int32>.size,
                         """
    This subscript operator can only be used on GeometryElement instances with bytesPerIndex == \(MemoryLayout<Int32>.size).
    This GeometryElement has bytesPerIndex == \(bytesPerIndex)
    """
        )
        var data = [Int32]()
        data.reserveCapacity(primitive.indexCount)
        for indexOffset in 0 ..< primitive.indexCount {
            data.append(buffer
                .contents()
                .advanced(by: (Int(index) * primitive.indexCount + indexOffset) * MemoryLayout<Int32>.size)
                .assumingMemoryBound(to: Int32.self).pointee)
        }
        return data
    }
    
    func asInt32Array() -> [Int32] {
        var array = [Int32]()
        let totalNumberOfInt32 = self.count * self.primitive.indexCount
        
        array.reserveCapacity(totalNumberOfInt32)
        
        for indexOffset in 0..<totalNumberOfInt32 {
            array.append(buffer.contents().advanced(by: indexOffset * MemoryLayout<Int32>.size).assumingMemoryBound(to: Int32.self).pointee)
        }
        return array
    }
    
    func asUInt16Array() -> [UInt16] {
        asInt32Array().map { UInt16($0) }
    }
    
    func asUInt32Array() -> [UInt32] {
        asInt32Array().map { UInt32($0) }
    }
}
