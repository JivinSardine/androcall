import AndroCallCore
import SwiftUI

/// The details of one contact, with the actions that the phone supports.
struct ContactDetailView: View {
    @ObservedObject var model: AppModel
    let contact: Contact
    @State private var selectedNumber: PhoneNumber?

    private var numbers: [PhoneNumber] {
        contact.phoneNumbers
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.xLarge) {
                HStack(spacing: Design.Spacing.large) {
                    ContactAvatar(contact: contact, size: 72)
                    VStack(alignment: .leading, spacing: Design.Spacing.xSmall) {
                        Text(contact.displayName)
                            .font(.system(size: 20, weight: .semibold))
                        if let organization = contact.organization, !organization.isEmpty {
                            Text(organization)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        model.toggleFavorite(contact)
                    } label: {
                        Image(systemName: contact.starred ? "star.fill" : "star")
                            .font(.system(size: 16))
                            .foregroundColor(contact.starred ? Design.warning : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                if !numbers.isEmpty {
                    SectionHeader("Phone numbers")
                    VStack(spacing: Design.Spacing.small) {
                        ForEach(numbers) { number in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(number.number)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(number.label.isEmpty ? number.type : number.label)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Call") {
                                    model.placeCall(number: number.number, contact: contact)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.connectionState.isConnected)
                            }
                            .padding(Design.Spacing.medium)
                            .background(
                                RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                                    .fill(Color.secondary.opacity(0.06))
                            )
                        }
                    }
                } else {
                    Text("This contact has no phone numbers.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                if !contact.emails.isEmpty {
                    SectionHeader("Email")
                    ForEach(contact.emails) { email in
                        DetailRow(email.label.isEmpty ? "email" : email.label, email.address)
                    }
                }
            }
            .padding(Design.Spacing.xLarge)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(contact.displayName)
    }
}
