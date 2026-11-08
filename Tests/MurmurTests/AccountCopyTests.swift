import Foundation
import Testing
@testable import Murmur

/// How the sign-in copy names the remembered account, and what it promises.
struct AccountCopyTests {
    private func account(_ email: String?, _ provider: String?) -> AccountModel.Account {
        AccountModel.Account(userID: UUID(), email: email, provider: provider)
    }

    @Test func namesTheMethodAndAnAddressPeopleRecognize() {
        #expect(account("olga@example.com", "email").phrase == "as olga@example.com")
        #expect(account("olga@gmail.com", "google").phrase == "with Google as olga@gmail.com")
        #expect(account("olga@icloud.com", "apple").phrase == "with Apple as olga@icloud.com")
        // Hide My Email: the relay address is no help.
        #expect(account("x7k2q9@privaterelay.appleid.com", "apple").phrase == "with Apple")
        // Remembered without its provider: only Apple hands out relay addresses.
        #expect(account("x7k2q9@PrivateRelay.AppleID.com", nil).phrase == "with Apple")
        #expect(account("olga@example.com", nil).phrase == "as olga@example.com")
        #expect(account(nil, "apple").phrase == "with Apple")
        #expect(account(nil, nil).phrase == nil)
    }

    /// An account remembered before its provider was still reads back.
    @Test func readsAnAccountStoredWithoutItsProvider() throws {
        let json = #"{"signedOut":{"_0":{"userID":"00000000-0000-4000-8000-000000000001","email":"olga@example.com"}}}"#
        let state = try JSONDecoder().decode(AccountModel.State.self, from: Data(json.utf8))
        let id = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        #expect(state == .signedOut(AccountModel.Account(userID: id, email: "olga@example.com")))
    }

    /// The same name everywhere, and no promise of a plan: every new user, a guest included,
    /// starts on whatever the server grants (today a trial, not the free plan).
    @MainActor @Test func theCopyNamesTheAccountAndPromisesNoPlan() {
        #expect(SignInAgainView.subtitle(phrase: "with Apple", guest: false)
            == "You were signed in with Apple. Use the same account to keep cloud dictation and your plan.")
        #expect(SignInAgainView.subtitle(phrase: nil, guest: true)
            == "Use the account you signed in with before to get your plan back.")
        #expect(SettingsView.accountFooter(phrase: "as olga@example.com", guest: false)
            == "You're signed out. Sign in again as olga@example.com to keep cloud dictation and your plan.")
        let guest = SettingsView.accountFooter(phrase: "with Google as olga@gmail.com", guest: true)
        #expect(guest == "You're using Murmur as a guest, without your account's plan. Sign in with Google as olga@gmail.com to get it back.")
        #expect(!guest.localizedCaseInsensitiveContains("free plan"))
        #expect(TrialOfferView.signedOutDetail("with Apple") == "Sign in again with Apple to load your plan.")
        #expect(TrialOfferView.signedOutDetail(nil) == "Sign in again to load your plan.")
    }
}
