import AppKit
import MurmurCore
import SwiftUI

/// "Unlimited words": Annual or Monthly, then checkout in the browser. Murmur for Mac is a
/// download, not an App Store app, so Pro is bought on the web and lands on the account; the
/// sheet waits, checking the account, and closes once it's Pro.
///
/// The checkout is Paddle's (the user's choice, 2026-11-16): `paddle-checkout` makes one for the
/// signed-in account and answers with its link. Until Paddle is set up and the function deployed,
/// the sheet says buying on the Mac isn't open yet.
struct PaywallSheet: View {
    enum Plan { case annual, monthly }

    let model: MacAppModel
    @State private var plan: Plan = .annual
    @State private var waiting = false
    @State private var busy = false
    @State private var notOpenYet = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IconButton(symbol: "xmark", label: "Close", size: 32, iconSize: 14) { dismiss() }
                .padding(.leading, -14)
            if waiting { waitingView } else { choosing }
        }
        .padding(.horizontal, 32).padding(.top, 18).padding(.bottom, 24)
        .frame(width: 500, height: 652)
        .background(Mac.Palette.canvas)
        .foregroundStyle(Mac.Palette.ink)
        .task(id: waiting) {
            // Back from the browser: the account turns Pro on its own.
            guard waiting else { return }
            while !Task.isCancelled {
                await model.refreshAccount()
                if model.quota?.isPro == true, model.quota?.onTrial == false {
                    dismiss()
                    return
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MarkView(size: 22)
                Text("murmur").font(.system(size: 20, weight: .semibold)).tracking(-0.5)
                Text("Pro").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule(style: .circular).fill(Mac.Palette.ink))
            }
            .padding(.top, 4)
            Text("Unlimited words").font(.system(size: 34, weight: .bold)).tracking(-1)
                .padding(.top, 12).padding(.bottom, 16)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(["Unlimited words, every week", "Translate and polish as much as you like",
                         "Command mode in any app", "On your Mac and your iPhone"], id: \.self) { line in
                    Label(line, systemImage: "checkmark").font(.system(size: 15))
                }
            }
            VStack(spacing: 10) {
                planCard(.annual, title: "Annual", badge: "Save 33%", line: "$79.99 a year", trailing: "$6.67 / month")
                planCard(.monthly, title: "Monthly", badge: nil, line: "$9.99 a month", trailing: nil)
            }
            .padding(.top, 20)
            Text("Basic stays free, with 1,000 words a week.")
                .font(Mac.Font.small).foregroundStyle(Mac.Palette.third).frame(maxWidth: .infinity).padding(.top, 10)
            Spacer(minLength: 12)
            Button(action: checkout) {
                HStack(spacing: 8) {
                    Text("Continue to checkout")
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(InkButtonStyle(height: 46))
            .disabled(busy || notOpenYet || !model.isSignedIn)
            if let failure {
                Text(failure).font(Mac.Font.caption).frame(maxWidth: .infinity).padding(.top, 8)
            }
            Text(footnote)
                .font(Mac.Font.caption).foregroundStyle(Mac.Palette.third).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.top, 10)
            HStack(spacing: 16) {
                Link("Terms of Use", destination: MacLinks.terms)
                Link("Privacy Policy", destination: MacLinks.privacy)
            }
            .font(Mac.Font.caption).tint(Mac.Palette.ink).frame(maxWidth: .infinity).padding(.top, 8)
        }
    }

    private var footnote: String {
        if notOpenYet {
            return "Buying Pro on the Mac isn’t open yet. Already Pro on your iPhone? It’s on here when you sign in with that account."
        }
        return "Checkout opens in your browser. Renews until you cancel; cancel any time from your account page. Already Pro on your iPhone? Sign in with that account instead."
    }

    private var waitingView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "safari").font(.system(size: 34, weight: .regular))
            Text("Finish in your browser").font(.system(size: 26, weight: .bold)).tracking(-0.6)
            Text("Checkout is open in your browser. Murmur switches to Pro by itself when you’re done.")
                .font(.system(size: 15)).foregroundStyle(Mac.Palette.second).multilineTextAlignment(.center)
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Waiting for checkout")
            }
            .font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
            VStack(spacing: 8) {
                Button(action: checkout) { Text("Open checkout again").frame(maxWidth: .infinity) }
                    .buttonStyle(OutlineButtonStyle(height: 44))
                Button("Back") { waiting = false }.buttonStyle(.plain).font(.system(size: 14, weight: .semibold))
                    .frame(height: 40)
            }
            .padding(.top, 10)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    private func planCard(_ value: Plan, title: String, badge: String?, line: String, trailing: String?) -> some View {
        let on = plan == value
        return Button { plan = value } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 15, weight: .semibold))
                        if let badge {
                            Text(badge).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule(style: .circular).fill(Mac.Palette.ink))
                        }
                    }
                    Text(line).font(Mac.Font.small.monospacedDigit()).foregroundStyle(Mac.Palette.second)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing { Text(trailing).font(.system(size: 14, weight: .semibold).monospacedDigit()) }
                RadioMark(on: on)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(on ? Mac.Palette.ink : Mac.Palette.line, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func checkout() {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do throws(MacAppModel.CheckoutFailure) {
                var url = try await model.checkoutURL(annual: plan == .annual)
                if let email = model.accountEmail, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "email", value: email)]
                    url = components.url ?? url
                }
                openURL(url)
                waiting = true
            } catch .notOpenYet {
                notOpenYet = true
            } catch .signedOut {
                failure = "Sign in to Murmur first."
            } catch {
                failure = "Couldn’t open checkout. Check your connection and try again."
            }
        }
    }
}
