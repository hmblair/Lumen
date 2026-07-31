// GroupChipsView.swift
// Group UI, option A: a row of chips above the light list. Clicking a chip
// selects its members (manual writes then go through the atomic group
// endpoint); double-click renames; the context menu updates membership to
// the current selection or deletes; "+" creates a group from the current
// selection. Self-contained by design — switching to another group UI
// (e.g. grouped list sections) means replacing this one component at its
// single insertion point in ControlPanel.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import LumenCore

struct GroupChipsView: View {
    @ObservedObject var controller: LightController

    @State private var renamingID: String?
    @State private var creating = false
    @State private var nameText = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GROUPS").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(controller.groups.sorted(by: { $0.value.name < $1.value.name }),
                            id: \.key) { id, group in
                        chip(id: id, group: group)
                    }
                    if creating {
                        nameField(placeholder: "Group name") { name in
                            // Reject duplicates immediately; on any failure
                            // keep the field open so the name isn't lost.
                            if nameClash(name, excluding: nil) {
                                errorMessage = "A group named '\(name)' already exists"
                                return
                            }
                            Task {
                                if let error = await controller.createGroup(
                                    named: name, lights: Array(controller.selection)) {
                                    errorMessage = error
                                } else {
                                    errorMessage = nil
                                    creating = false
                                }
                            }
                        }
                    } else {
                        Button {
                            nameText = ""
                            creating = true
                            renamingID = nil
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        // A group is created from the current selection.
                        .disabled(controller.selection.isEmpty)
                        .help("New group from the selected lights")
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private func chip(id: String, group: LightGroup) -> some View {
        if renamingID == id {
            nameField(placeholder: group.name) { name in
                if nameClash(name, excluding: id) {
                    errorMessage = "A group named '\(name)' already exists"
                    return
                }
                Task {
                    if let error = await controller.updateGroup(id: id, name: name) {
                        errorMessage = error
                    } else {
                        errorMessage = nil
                        renamingID = nil
                    }
                }
            }
        } else {
            // Active = all members selected (not exact match), so several
            // chips highlight together while their union is selected.
            let members = Set(group.lights)
            let isActive = !members.isEmpty && members.isSubset(of: controller.selection)
            Text(group.name)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(isActive
                                           ? Color.accentColor.opacity(0.25)
                                           : Color.primary.opacity(0.08)))
                // ⌘-click toggles the group into/out of the selection (build
                // unions like "rooms x and y"); plain click replaces. High
                // priority so the ⌘ variant wins without adding any
                // double-click-style latency to the plain click.
                .highPriorityGesture(TapGesture().modifiers(.command).onEnded {
                    if isActive {
                        controller.selection.subtract(members)
                    } else {
                        controller.selection.formUnion(members)
                    }
                })
                // Simultaneous, not sequenced: a sequenced double-tap makes
                // every single click wait out the double-click window, which
                // reads as lag. This way selection is instant and the second
                // click of a double additionally opens rename.
                .onTapGesture {
                    controller.selection = members
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    nameText = group.name
                    renamingID = id
                    creating = false
                })
                .contextMenu {
                    Button("Set lights to current selection") {
                        Task {
                            errorMessage = await controller.updateGroup(
                                id: id, lights: Array(controller.selection))
                        }
                    }
                    .disabled(controller.selection.isEmpty)
                    Button("Delete group", role: .destructive) {
                        Task { errorMessage = await controller.deleteGroup(id: id) }
                    }
                }
                .help("\(memberNames(group)) — click to select, ⌘-click to add/remove, double-click to rename")
        }
    }

    private func nameField(placeholder: String, onSubmit: @escaping (String) -> Void) -> some View {
        TextField(placeholder, text: $nameText)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 110)
            .onSubmit {
                let name = nameText.trimmingCharacters(in: .whitespaces)
                if name.isEmpty {
                    dismissField()
                } else {
                    onSubmit(name)
                }
            }
            .onExitCommand { dismissField() }
    }

    /// Closing the name field also retires any rejection message — it refers
    /// to input that no longer exists.
    private func dismissField() {
        creating = false
        renamingID = nil
        errorMessage = nil
    }

    /// Case-insensitive duplicate check against the loaded groups, ignoring
    /// the group being renamed. The daemon enforces this too; checking here
    /// gives instant feedback.
    private func nameClash(_ name: String, excluding id: String?) -> Bool {
        controller.groups.contains { key, group in
            key != id && group.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    private func memberNames(_ group: LightGroup) -> String {
        let names = controller.lights
            .filter { group.lights.contains($0.id) }
            .map(\.name)
        return names.isEmpty ? "no lights" : names.joined(separator: ", ")
    }
}
