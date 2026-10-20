import AndroCallCore
import SwiftUI

/// The contacts list with search and favourites.
struct ContactsView: View {
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @State private var showFavouritesOnly = false
    @State private var selectedContact: Contact?

    private var results: [Contact] {
        let base = showFavouritesOnly ? model.starredContacts : model.contacts
        guard !searchText.isEmpty else { return base }
        return base.filter { contact in
            let needle = searchText.lowercased()
            return contact.displayName.lowercased().contains(needle)
                || contact.phoneNumbers.contains { $0.number.lowercased().contains(needle) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if results.isEmpty {
                EmptyStateView(
                    symbol: "person.crop.circle.badge.questionmark",
                    title: model.contacts.isEmpty ? "No contacts yet" : "No matches",
                    message: model.contacts.isEmpty
                        ? "Connect your Android phone and sync your contacts to see them here."
                        : "No contact matches “\(searchText)”.",
                    actionTitle: model.contacts.isEmpty ? "Sync contacts" : nil,
                    action: model.contacts.isEmpty ? {
                        Task { await model.syncContacts() }
                    } : nil
                )
            } else {
                list
            }
        }
        .navigationTitle("Contacts")
    }

    private var toolbar: some View {
        HStack(spacing: Design.Spacing.medium) {
            HStack(spacing: Design.Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search contacts", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Design.Spacing.small)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )

            Button {
                showFavouritesOnly.toggle()
            } label: {
                Image(systemName: showFavouritesOnly ? "star.fill" : "star")
                    .foregroundColor(showFavouritesOnly ? Design.warning : .secondary)
            }
            .buttonStyle(.plain)
            .help("Show only favourites")

            if model.contactSyncProgress != nil {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(Design.Spacing.medium)
    }

    private var list: some View {
        List(results) { contact in
            NavigationLink(destination: ContactDetailView(model: model, contact: contact)) {
                HStack(spacing: Design.Spacing.medium) {
                    ContactAvatar(contact: contact)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName)
                            .font(.system(size: 13, weight: .medium))
                        if let numbers = contact.phoneNumbers, !numbers.isEmpty {
                            Text(numbers.map(\.number).joined(separator: " · "))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if contact.starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Design.warning)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
    }
}
