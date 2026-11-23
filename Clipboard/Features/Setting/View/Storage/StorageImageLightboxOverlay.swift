//
//  StorageImageLightboxOverlay.swift
//  Clipboard
//
//  存储空间透视器全尺寸大图沉浸式灯箱 (Lightbox)
//

import AppKit
import SwiftUI

struct StorageImageLightboxOverlay: View {
    let image: NSImage
    let dimensions: CGSize?
    let title: String
    let onClose: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            // 背景暗色材质遮罩
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            // 大图展示区，支持缩放和平移
            GeometryReader { proxy in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { val in
                                scale = lastScale * val
                            }
                            .onEnded { _ in
                                lastScale = max(0.5, min(scale, 4.0))
                                scale = lastScale
                            }
                            .simultaneously(with:
                                DragGesture()
                                    .onChanged { val in
                                        offset = CGSize(
                                            width: lastOffset.width + val.translation.width,
                                            height: lastOffset.height + val.translation.height
                                        )
                                    }
                                    .onEnded { _ in
                                        lastOffset = offset
                                    }
                            )
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            if scale > 1.2 {
                                scale = 1.0
                                lastScale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.0
                                lastScale = 2.0
                            }
                        }
                    }
            }

            // 顶部浮动标题与控制栏
            VStack {
                HStack(spacing: Const.space12) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)

                    if let dimensions {
                        Text("\(Int(dimensions.width)) × \(Int(dimensions.height)) 像素")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()

                    Button {
                        withAnimation(.spring()) {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        }
                    } label: {
                        Text("100% 还原")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.spring()) {
                            scale = min(scale * 1.3, 4.0)
                            lastScale = scale
                        }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.spring()) {
                            scale = max(scale / 1.3, 0.5)
                            lastScale = scale
                        }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Const.space20)
                .padding(.vertical, Const.space14)
                .background(Color.black.opacity(0.5))

                Spacer()

                Text("双击快速放大/还原 · 支持拖动与手势缩放 · 点击背景或按右上角 ✕ 退出")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, Const.space12)
            }
        }
        .transition(.opacity)
    }
}
