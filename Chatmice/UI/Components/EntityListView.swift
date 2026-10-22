//
//  EntityListView.swift
//  Chatmice
//
//  Created by Renat Notfullin on 15.09.2024.
//

import AppKit
import CoreData
import SwiftUI

struct EntityListView<Entity: NSManagedObject & Identifiable, DetailContent: View>: View {
    @Binding var selectedEntityID: NSManagedObjectID?
    let entities: FetchedResults<Entity>
    let detailContent: (Entity?) -> DetailContent
    let getEntityColor: ((Entity) -> Color?)?
    let getEntityName: (Entity) -> String
    var getEntityDefault: (Entity) -> Bool = { _ in false }
    var getEntityIcon: (Entity) -> String? = { _ in nil }
    var getEntityOverlayIcon: (Entity) -> String? = { _ in nil }
    let onEdit: (() -> Void)?
    let onMove: ((IndexSet, Int) -> Void)?
    @State private var draggedEntityID: NSManagedObjectID?
    @State private var dropTarget: (id: NSManagedObjectID, before: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entities, id: \.objectID) { entity in
                entityRow(for: entity)
            }

            if entities.isEmpty {
                HStack(alignment: .top) {
                    detailContent(nil)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.16), value: selectedEntityID)
        .onDisappear {
            draggedEntityID = nil
            dropTarget = nil
        }
    }

    @ViewBuilder
    private func entityRow(for entity: Entity) -> some View {
        let row = EntityRowView(
            color: getEntityColor?(entity),
            name: getEntityName(entity),
            defaultEntity: getEntityDefault(entity),
            icon: getEntityIcon(entity),
            overlayIcon: getEntityOverlayIcon(entity),
            showDragHandle: onMove != nil
        )
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selectedEntityID == entity.objectID ? Color.accentColor.opacity(0.2) : .clear)
        )
        .onTapGesture(count: 2) {
            selectedEntityID = entity.objectID
            onEdit?()
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                selectedEntityID = entity.objectID
            }
        )

        if onMove != nil {
            VStack(spacing: 2) {
                if dropTarget?.id == entity.objectID, dropTarget?.before == true {
                    ReorderDropPlaceholder()
                }
                row
                    .overlay {
                        ReorderDragSource(
                            payload: { entity.objectID.uriRepresentation().absoluteString },
                            preview: row,
                            onStarted: { draggedEntityID = entity.objectID },
                            onEnded: {
                                if draggedEntityID == entity.objectID {
                                    draggedEntityID = nil
                                    dropTarget = nil
                                }
                            },
                            onClick: { count in
                                selectedEntityID = entity.objectID
                                if count == 2 { onEdit?() }
                            }
                        )
                    }
                    .opacity(draggedEntityID == entity.objectID ? 0.6 : 1)
                if selectedEntityID == entity.objectID {
                    inlineDetail(for: entity)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if dropTarget?.id == entity.objectID, dropTarget?.before == false {
                    ReorderDropPlaceholder()
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self, action: { draggedIDs, _ in
                defer {
                    draggedEntityID = nil
                    dropTarget = nil
                }
                guard let draggedID = draggedIDs.first else { return false }
                return moveEntity(withURI: draggedID, onto: entity)
            }, isTargeted: { targeted in
                if targeted,
                    let sourceIndex = entities.firstIndex(where: { $0.objectID == draggedEntityID }),
                    let targetIndex = entities.firstIndex(where: { $0.objectID == entity.objectID }),
                    sourceIndex != targetIndex
                {
                    dropTarget = (entity.objectID, sourceIndex > targetIndex)
                }
                else if dropTarget?.id == entity.objectID {
                    dropTarget = nil
                }
            })
        }
        else {
            VStack(spacing: 2) {
                row
                if selectedEntityID == entity.objectID {
                    inlineDetail(for: entity)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func inlineDetail(for entity: Entity) -> some View {
        HStack(alignment: .top) {
            detailContent(entity)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                )
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private func moveEntity(withURI draggedURI: String, onto target: Entity) -> Bool {
        guard let onMove else { return false }

        let currentEntities = Array(entities)
        guard
            let sourceIndex = currentEntities.firstIndex(where: {
                $0.objectID.uriRepresentation().absoluteString == draggedURI
            }),
            let targetIndex = currentEntities.firstIndex(where: { $0.objectID == target.objectID }),
            sourceIndex != targetIndex
        else {
            return false
        }

        let destination = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        onMove(IndexSet(integer: sourceIndex), destination)
        return true
    }
}

struct ReorderDropPlaceholder: View {
    var body: some View {
        Text("Drop here")
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
            .accessibilityLabel("Drop here to reorder")
    }
}

struct EntityRowView: View {
    let color: Color?
    let name: String
    let defaultEntity: Bool
    let icon: String?
    let overlayIcon: String?
    let showDragHandle: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                PersonaIconView(
                    color: color ?? .accentColor,
                    symbolName: icon,
                    overlaySymbolName: overlayIcon,
                    size: 18
                )
            }
            else if let color {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
            }
            Text(name)
                .lineLimit(1)

            Spacer(minLength: 8)

            if defaultEntity {
                Text("Default")
                    .foregroundColor(.white)
                    .font(.caption)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue)
                    )
            }

            if showDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }
}

/// Keeps native drag completion (including cancellation outside the app) separate from the drop destination.
struct ReorderDragSource<Preview: View>: NSViewRepresentable {
    let payload: () -> String
    let preview: Preview
    let onStarted: () -> Void
    let onEnded: () -> Void
    let onClick: (Int) -> Void

    func makeNSView(context: Context) -> ReorderDragSourceView {
        let view = ReorderDragSourceView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: ReorderDragSourceView, context: Context) {
        nsView.payload = payload
        nsView.onStarted = onStarted
        nsView.onEnded = onEnded
        nsView.onClick = onClick
        let environment = context.environment
        nsView.makeImage = { size, scale in
            let renderer = ImageRenderer(content: preview.environment(\.self, environment))
            renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
            renderer.scale = scale
            return renderer.nsImage
        }
    }
}

final class ReorderDragSourceView: NSView, NSDraggingSource {
    var payload: (() -> String)?
    var makeImage: ((NSSize, CGFloat) -> NSImage?)?
    var onStarted: (() -> Void)?
    var onEnded: (() -> Void)?
    var onClick: ((Int) -> Void)?
    private var initialMouseEvent: NSEvent?
    private var finishDrag: (() -> Void)?
    private var previewPanel: NSPanel?
    private var previewOffset = NSPoint.zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        initialMouseEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let initialMouseEvent,
              hypot(event.locationInWindow.x - initialMouseEvent.locationInWindow.x,
                    event.locationInWindow.y - initialMouseEvent.locationInWindow.y) >= 3,
              let payload, let window,
              let image = makeImage?(bounds.size, window.backingScaleFactor) else { return }
        self.initialMouseEvent = nil
        let frame = window.convertToScreen(convert(bounds, to: nil))
        let cursor = window.convertPoint(toScreen: event.locationInWindow)
        previewOffset = NSPoint(x: frame.minX - cursor.x, y: frame.minY - cursor.y)
        image.size = frame.size
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.image = image
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 1
        panel.contentView = imageView
        previewPanel = panel
        let item = NSDraggingItem(pasteboardWriter: payload() as NSString)
        // AppKit fades native drag images. Keep its data session, but draw an opaque, non-interactive preview.
        item.setDraggingFrame(bounds, contents: nil)
        finishDrag = onEnded
        // Render before changing the source's opacity.
        onStarted?()
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let initialMouseEvent else { return }
        self.initialMouseEvent = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(initialMouseEvent.clickCount)
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // SwiftUI's String destination negotiates a copy transfer; its action performs the reorder.
        [.copy, .move]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        draggingSession(session, movedTo: screenPoint)
        previewPanel?.orderFrontRegardless()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        previewPanel?.setFrameOrigin(NSPoint(x: screenPoint.x + previewOffset.x, y: screenPoint.y + previewOffset.y))
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        initialMouseEvent = nil
        previewPanel?.close()
        previewPanel = nil
        let finish = finishDrag
        finishDrag = nil
        finish?()
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
