//
//  PersonaSelectorView.swift
//  macai
//
//  Created by Renat Notfullin on 08.11.2024.
//

import AppKit
import CoreData
import SwiftUI

struct GlassMorphicBackground: View {
    let color: Color
    let isSelected: Bool
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Rectangle()
            .fill(color)
            .opacity(isSelected ? 0.6 : 0.12)
    }
}

struct PersonaChipView: View {
    let persona: PersonaEntity
    let isSelected: Bool
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovered = false

    private let personaColor: Color

    init(persona: PersonaEntity, isSelected: Bool) {
        self.persona = persona
        self.isSelected = isSelected
        self.personaColor = Color(hex: persona.color ?? "#FFFFFF") ?? .white
    }

    var body: some View {
        Text(persona.name ?? "")
            .foregroundStyle(.primary)
            .frame(height: 32)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(personaColor.opacity(isSelected ? 0.6 : 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(personaColor.opacity(isSelected ? 0.8 : 0.2), lineWidth: isSelected ? 2 : 1)
                    )
                    .shadow(
                        color: personaColor.opacity(isSelected ? 0.7 : (isHovered ? 0.2 : 0)),
                        radius: isSelected ? 7 : 4
                    )
            )
            .animation(.easeOut(duration: 0.2), value: isHovered)
            .animation(.easeOut(duration: 0.2), value: isSelected)
            .onHover { hovering in
                isHovered = hovering
            }
            .padding(4)
    }
}

private struct PersonaContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private final class PersonaWheelCaptureNSView: NSView {
    var onScroll: (CGFloat) -> Void = { _ in }
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }
                let rawDelta = abs(event.scrollingDeltaX) > 0.1
                    ? event.scrollingDeltaX
                    : event.scrollingDeltaY
                guard abs(rawDelta) > 0.01 else { return event }
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                self.onScroll(rawDelta * scale)
                return nil
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func removeMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    deinit {
        removeMonitor()
    }
}

private struct PersonaWheelCaptureView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> PersonaWheelCaptureNSView {
        let view = PersonaWheelCaptureNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: PersonaWheelCaptureNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

struct PersonaSelectorView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \PersonaEntity.order, ascending: true)],
        animation: .default
    )
    private var personas: FetchedResults<PersonaEntity>

    private let edgeDarkColor = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    private let edgeLightColor = Color.white

    @ObservedObject var chat: ChatEntity
    @Environment(\.colorScheme) var colorScheme
    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @GestureState private var dragTranslation: CGFloat = 0

    private func updatePersonaAndSystemMessage(to persona: PersonaEntity?) {
        chat.persona = persona
        chat.systemMessage = persona?.systemMessage ?? AppConstants.chatGptSystemMessage
        chat.objectWillChange.send()

        if let context = chat.managedObjectContext {
            try? context.save()
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                HStack(spacing: 8) {
                    ForEach(personas, id: \.self) { persona in
                        PersonaChipView(persona: persona, isSelected: chat.persona == persona)
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    updatePersonaAndSystemMessage(to: persona)
                                }
                            }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { contentGeometry in
                        Color.clear.preference(
                            key: PersonaContentWidthKey.self,
                            value: contentGeometry.size.width
                        )
                    }
                )
                .offset(x: clampedOffset(
                    scrollOffset + dragTranslation,
                    viewportWidth: geometry.size.width
                ))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .updating($dragTranslation) { value, state, _ in
                            state = value.translation.width
                        }
                        .onEnded { value in
                            scrollOffset = clampedOffset(
                                scrollOffset + value.translation.width,
                                viewportWidth: geometry.size.width
                            )
                        }
                )

                PersonaWheelCaptureView { delta in
                    scrollOffset = clampedOffset(
                        scrollOffset + delta,
                        viewportWidth: geometry.size.width
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [colorScheme == .dark ? edgeDarkColor : edgeLightColor, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 24)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                LinearGradient(
                    colors: [.clear, colorScheme == .dark ? edgeDarkColor : edgeLightColor],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 24)
                .allowsHitTesting(false)
            }
            .onChange(of: contentWidth) { _ in
                scrollOffset = clampedOffset(scrollOffset, viewportWidth: geometry.size.width)
            }
        }
        .onPreferenceChange(PersonaContentWidthKey.self) { width in
            contentWidth = width
        }
        .frame(height: 52)
        .clipped()
    }

    private func clampedOffset(_ proposedOffset: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        let minimumOffset = min(0, viewportWidth - contentWidth)
        return min(0, max(minimumOffset, proposedOffset))
    }
}

#Preview {
    let context = PersistenceController.preview.container.viewContext
    let chat = ChatEntity(context: context)
    return PersonaSelectorView(chat: chat)
        .frame(width: 400)
}
