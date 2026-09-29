//
//  EntityListView.swift
//  Chatmice
//
//  Created by Renat Notfullin on 15.09.2024.
//

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
    let onEdit: (() -> Void)?
    let onMove: ((IndexSet, Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 2) {
                ForEach(entities, id: \.objectID) { entity in
                    entityRow(for: entity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top) {
                if let selectedEntity = entities.first(where: { $0.objectID == selectedEntityID }) {
                    detailContent(selectedEntity)
                }
                else {
                    detailContent(nil)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func entityRow(for entity: Entity) -> some View {
        let row = EntityRowView(
            color: getEntityColor?(entity),
            name: getEntityName(entity),
            defaultEntity: getEntityDefault(entity),
            icon: getEntityIcon(entity),
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
            row
                .draggable(entity.objectID.uriRepresentation().absoluteString)
                .dropDestination(for: String.self) { draggedIDs, _ in
                    guard let draggedID = draggedIDs.first else { return false }
                    return moveEntity(withURI: draggedID, onto: entity)
                }
        }
        else {
            row
        }
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

struct EntityRowView: View {
    let color: Color?
    let name: String
    let defaultEntity: Bool
    let icon: String?
    let showDragHandle: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon = icon {
                Image(icon)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: 12, height: 12)
            }
            if let color = color {
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
