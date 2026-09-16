import MessageUI
import UIKit

/// Presents the system compose sheets and reports what the user did.
///
/// This file is where the app's central honesty constraint lives. `MFMessage-`
/// and `MFMailComposeViewController` are the *only* public way for a
/// third-party iOS app to originate a text or an email, and both require the
/// user to tap Send inside a sheet the app cannot script. The delegate
/// callback is the app's sole source of truth about whether anything was
/// actually sent, so the agent reports from that callback and never from the
/// fact that it opened a sheet.
///
/// Running the model locally changes nothing here. The restriction is in
/// MessageUI, not in the model.
@MainActor
final class ComposePresenter: NSObject {
    static let shared = ComposePresenter()

    enum Result {
        case sent
        case cancelled
        case savedAsDraft
        case failed(String)
        /// Device cannot do it at all: no SIM, no mail account configured.
        case unavailable(String)

        var describedForModel: String {
            switch self {
            case .sent: return "The user tapped send and it was sent."
            case .cancelled: return "The user dismissed the compose sheet without sending."
            case .savedAsDraft: return "The user saved it as a draft instead of sending."
            case .failed(let why): return "The compose sheet reported a failure: \(why)"
            case .unavailable(let why): return "Not available on this device: \(why)"
            }
        }

        var didSend: Bool {
            if case .sent = self { return true }
            return false
        }
    }

    /// The delegate is retained here for the lifetime of the sheet. A compose
    /// controller holds its delegate weakly, so a locally-scoped delegate is
    /// deallocated immediately and the completion never fires — the await
    /// below would hang forever.
    private var continuation: CheckedContinuation<Result, Never>?

    private override init() { super.init() }

    // MARK: - Messages

    func presentMessage(recipients: [String], body: String) async -> Result {
        guard MFMessageComposeViewController.canSendText() else {
            return .unavailable("this device is not configured to send text messages")
        }
        guard let host = Self.topViewController() else {
            return .failed("no view controller was available to present from")
        }
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = self
        composer.recipients = recipients.isEmpty ? nil : recipients
        composer.body = body
        return await present(composer, from: host)
    }

    // MARK: - Mail

    func presentMail(to: [String], cc: [String], subject: String, body: String) async -> Result {
        guard MFMailComposeViewController.canSendMail() else {
            // Fall back to a mailto: URL, which can reach a third-party client
            // such as Gmail or Outlook when no account is set up in Mail.
            return .unavailable("no email account is configured in Mail. "
                + "A mailto link may still open another mail app.")
        }
        guard let host = Self.topViewController() else {
            return .failed("no view controller was available to present from")
        }
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = self
        if !to.isEmpty { composer.setToRecipients(to) }
        if !cc.isEmpty { composer.setCcRecipients(cc) }
        composer.setSubject(subject)
        composer.setMessageBody(body, isHTML: false)
        return await present(composer, from: host)
    }

    // MARK: - Presentation

    private func present(_ controller: UIViewController, from host: UIViewController) async -> Result {
        // Two sheets at once would strand the first continuation. Resolve the
        // in-flight one rather than leaking an awaiting task.
        if let pending = continuation {
            continuation = nil
            pending.resume(returning: .failed("superseded by another compose sheet"))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            continuation = cont
            host.present(controller, animated: true)
        }
    }

    private func finish(_ controller: UIViewController, with result: Result) {
        controller.dismiss(animated: true)
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: result)
    }

    /// Walks to the frontmost presented controller. Presenting on a controller
    /// that is already presenting something silently does nothing, which would
    /// look to the agent like a sheet that never returned.
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - Opening URLs

    /// Opens a URL, reporting whether iOS accepted it.
    ///
    /// `canOpenURL` is gated by `LSApplicationQueriesSchemes`: an unlisted
    /// scheme reports false even when the app is installed. So this checks the
    /// allowlist first and, for unlisted schemes, attempts the open and
    /// reports the real outcome instead of trusting the probe.
    @discardableResult
    static func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url, options: [:])
    }
}

extension ComposePresenter: MFMessageComposeViewControllerDelegate {
    func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                      didFinishWith result: MessageComposeResult) {
        let mapped: Result
        switch result {
        case .sent: mapped = .sent
        case .cancelled: mapped = .cancelled
        case .failed: mapped = .failed("the message could not be sent")
        @unknown default: mapped = .failed("unrecognised compose result")
        }
        finish(controller, with: mapped)
    }
}

extension ComposePresenter: MFMailComposeViewControllerDelegate {
    func mailComposeController(_ controller: MFMailComposeViewController,
                               didFinishWith result: MFMailComposeResult,
                               error: Error?) {
        let mapped: Result
        if let error {
            mapped = .failed(error.localizedDescription)
        } else {
            switch result {
            case .sent: mapped = .sent
            case .saved: mapped = .savedAsDraft
            case .cancelled: mapped = .cancelled
            case .failed: mapped = .failed("the mail could not be sent")
            @unknown default: mapped = .failed("unrecognised compose result")
            }
        }
        finish(controller, with: mapped)
    }
}
