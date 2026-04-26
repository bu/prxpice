import SwiftUI
import StoreKit

private extension Product.SubscriptionPeriod {
    var localizedDescription: String {
        switch unit {
        case .day:   return value == 1 ? "day" : "\(value) days"
        case .week:  return value == 1 ? "week" : "\(value) weeks"
        case .month: return value == 1 ? "month" : "\(value) months"
        case .year:  return value == 1 ? "year" : "\(value) years"
        @unknown default: return "\(value) period(s)"
        }
    }
}

struct PaywallView: View {
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    header
                    features
                    if subscriptionManager.products.isEmpty {
                        ProgressView("Loading plans...")
                            .padding()
                    } else {
                        planCards
                    }
                    if let error = subscriptionManager.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    legalFooter
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            if subscriptionManager.products.isEmpty {
                await subscriptionManager.refresh()
            }
        }
        .onChange(of: subscriptionManager.isSubscribed) { _, subscribed in
            if subscribed { dismiss() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("PrXpice Pro")
                .font(.largeTitle.bold())
            Text("Remote desktop access to your\nProxmox VMs, anywhere.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            FeatureRow(icon: "display.2", text: "Connect to unlimited SPICE VMs")
            FeatureRow(icon: "waveform", text: "Full audio playback and microphone")
            FeatureRow(icon: "square.stack.3d.up", text: "Multi-VM sessions simultaneously")
            FeatureRow(icon: "lock.shield", text: "Secure TLS-encrypted connections")
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var planCards: some View {
        VStack(spacing: 12) {
            ForEach(subscriptionManager.products, id: \.id) { product in
                PlanCard(
                    product: product,
                    isBestValue: product.id == SubscriptionManager.yearlyID,
                    isPurchasing: subscriptionManager.isPurchasing
                ) {
                    Task { await subscriptionManager.purchase(product) }
                }
            }
            Button {
                Task { await subscriptionManager.restorePurchases() }
            } label: {
                Text("Restore Purchases")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            .disabled(subscriptionManager.isPurchasing)
        }
    }

    private var legalFooter: some View {
        let hasIntroOffer = subscriptionManager.products.contains {
            $0.subscription?.introductoryOffer != nil
        }
        let trialText = hasIntroOffer ? " Free trial converts to paid after the trial period." : ""
        return Text("Subscriptions auto-renew unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in App Store Settings.\(trialText)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
    }
}

// MARK: - Subviews

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
        }
    }
}

private struct PlanCard: View {
    let product: Product
    let isBestValue: Bool
    let isPurchasing: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(product.displayName)
                            .font(.headline)
                        if isBestValue {
                            Text("BEST VALUE")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    if let subscription = product.subscription {
                        if let introOffer = subscription.introductoryOffer {
                            Text("\(introOffer.period.localizedDescription) free trial")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice)
                        .font(.title3.bold())
                    if let subscription = product.subscription {
                        Text("/ \(subscription.subscriptionPeriod.localizedDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isBestValue ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing)
        .overlay {
            if isPurchasing {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.background.opacity(0.5))
                ProgressView()
            }
        }
    }
}
