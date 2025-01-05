//
//  ImmersiveView.swift
//  HiddenBox
//
//  Created by boardguy.vision on 2024/12/30.
//

import Combine
import SwiftUI
import RealityKit
import RealityKitContent

struct ImmersiveView: View {

    @State var boxTopLeft = Entity()
    @State var boxTopRight = Entity()
    @State var boxTopCollision = Entity()
    @State var openParticleEntity = Entity()
    @State var inviteParticleEntity = Entity()

    @State var isBoxOpen = false
    
    @State var animationCompletionSubscription: AnyCancellable?
    
    @State var planeTrackingManager = PlaneTrackingManager()
    
    init() {
        ToyComponent.registerComponent()
    }

    var body: some View {
        RealityView { content in

            // 最小0.5m x 0.5mの tableをキャッチし、そのpositionに anchor.plainを content に add
            let anchor = AnchorEntity(.plane(.horizontal, classification: .table, minimumBounds: [0.5, 0.5]))
            content.add(anchor)
            
            content.add(planeTrackingManager.contentEntity)
            
            
            // Add the initial RealityKit content
            if let scene = try? await Entity(named: "Immersive", in: realityKitContentBundle) {
                // box.topをtableの平面に合わせるため
                scene.position = SIMD3(0, -0.25, 0)
                // その anchorに sceneを addする
                anchor.addChild(scene)
                
               // content.add(scene)
                
                self.boxTopLeft = scene.findEntity(named: "TopLeft_Occlusion")!
                self.boxTopRight = scene.findEntity(named: "TopRight_Occlusion")!
                self.boxTopCollision = scene.findEntity(named: "Top_Collision")!
                self.openParticleEntity = scene.findEntity(named: "OpenParticleEmitter")!
                self.inviteParticleEntity = scene.findEntity(named: "InviteParticleEmitter")!

            }
        }
        .gesture(
            DragGesture()
                .targetedToEntity(where: .has(ToyComponent.self))
                .onChanged({ value in
                    value.entity.position = value.convert(value.location3D, from: .local, to: value.entity.parent!)
                    
                    // drag中(position更新中は PhysicsBodyは「なし」として設定
                    value.entity.components[PhysicsBodyComponent.self] = .none
                })
                .onEnded({ value in
                    // 指を離した時に重力を割り当て
                    assignPhysicsBody(to: value.entity)
                    
                    planeTrackingManager.contentEntity.addChild(value.entity, preservingWorldTransform: true)
                })
        )
        .gesture(
            SpatialTapGesture()
                .targetedToEntity(boxTopCollision)
                .onEnded({ value in
                    openBoxAnimation()
                    
                })
        )
        .onAppear {
            Task {
                await planeTrackingManager.monitorSessionEvents()
            }
            
            Task {
                await planeTrackingManager.runARKitSession()
                await planeTrackingManager.processPlaneDetectionUpdates()
            }
        }
    }
    
    func assignPhysicsBody(to entity: Entity) {
        // friction: 摩擦の強さ - 床や他の物体との接触時に、滑り度合いを設定 (高いほど滑りにくくなる)
        // restitution: 物体の跳ね返りの強さ (0~1.0)
        let material = PhysicsMaterialResource.generate(friction: 0.8, restitution: 0)
        let pbComponent = PhysicsBodyComponent(material: material)
        entity.components.set(pbComponent)
    }
    
    func openBoxAnimation() {
        guard !isBoxOpen else { return }
        isBoxOpen.toggle()
        
        var leftTransform = boxTopLeft.transform
        var rightTransform = boxTopRight.transform
        
        leftTransform.translation += SIMD3(-0.25, 0, 0)
        rightTransform.translation += SIMD3(0.25, 0, 0)
        
        boxTopLeft.move(to: leftTransform, relativeTo: boxTopLeft.parent, duration: 3, timingFunction: .easeInOut)
        boxTopRight.move(to: rightTransform, relativeTo: boxTopRight.parent, duration: 3, timingFunction: .easeInOut)
        
        animationCompletionSubscription = boxTopLeft.scene?.publisher(for: AnimationEvents.PlaybackCompleted.self, on: boxTopLeft).sink(receiveValue: { _ in

            // boxをopenした後のtopParticleは非表示させる
            if var particleEmitter = inviteParticleEntity.components[ParticleEmitterComponent.self] {
                particleEmitter.isEmitting = false
                self.inviteParticleEntity.components[ParticleEmitterComponent.self] = particleEmitter
            }
            
            if var particleEmitter = openParticleEntity.components[ParticleEmitterComponent.self] {
                particleEmitter.isEmitting = true
                self.openParticleEntity.components[ParticleEmitterComponent.self] = particleEmitter
            }
            
            boxTopCollision.isEnabled = false
            
            animationCompletionSubscription = nil
        })
        
        
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
