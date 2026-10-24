#if DEBUG
import Foundation
import SummaryKit
import SwiftUI

/// `--preview-likes`: the signed-in app against canned API responses, for reviewing the library,
/// chat (with a rendered view), trips with flights, a LaTeX paper with reviews, link sheets, Likes,
/// expired likes and MCP keys without a server or an account. Stars made while it runs stay in
/// memory; the CI screenshot tests run against it. Open `summarychip://s/NightTrn01` (a shared summary) or
/// `summarychip://s/N0rthB0und` (a shared trip).
enum LikesPreviewFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--preview-likes") }

    static func environment() -> AppEnvironment {
        TripTourPreviewPhotos.registerIfEnabled()
        LikesPreviewStore.shared.setPaperMedia(image: PaperReaderPreviewHost.chartPNG(), pdf: paperPDF())
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: SummaryOnboardingStore.welcomeKey)
        defaults.set(EducationPage.features.map(\.id), forKey: SummaryOnboardingStore.readIDsKey)
        let token = SharedTokenBundle(accessToken: "preview-token", refreshToken: nil, idToken: nil,
                                      expiresAt: .now.addingTimeInterval(86_400), subject: "preview-user")
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [LikesPreviewProtocol.self]
        let environment = AppEnvironment.live(
            configuration: .live(),
            vault: InMemoryTokenVault(token),
            session: URLSession(configuration: session),
            authenticationState: .signedIn
        )
        environment.library.offline.clear()
        // Every run starts from the empty chat, not the previous run's transcript.
        environment.chatStore.remove(key: ChatTranscriptStore.libraryKey)
        return environment
    }

    /// The paper's first page, standing in for the server's LaTeX compile.
    private static func paperPDF() -> Data {
        let serif = { (size: CGFloat) in Font.system(size: size, design: .serif) }
        let page = VStack(spacing: 14) {
            Text(verbatim: "Reading Papers Natively").font(serif(22).weight(.semibold))
            Text(verbatim: "Ada Lovelace        Alan Turing").font(serif(12))
            Text(verbatim: "1 May 2025").font(serif(11))
            VStack(spacing: 6) {
                Text(verbatim: "Abstract").font(serif(11).weight(.bold))
                Text(verbatim: "We set a paper's LaTeX as native text, so it reflows and grows with the reader.").font(serif(10))
            }
            .padding(.horizontal, 48)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "1   Introduction").font(serif(14).weight(.bold))
                Text(verbatim: "Literate programming [1] treats a program as literature: an essay written for people, from which the compiler's input is extracted. Reading it first as prose makes its design visible.").font(serif(10))
                Text(verbatim: "Theorem 1 (Fermat). No three positive integers satisfy aⁿ + bⁿ = cⁿ for n > 2.").font(serif(10))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(64)
        .frame(width: 612, height: 792, alignment: .top)
        .foregroundStyle(.black)
        .background(.white)
        .environment(\.colorScheme, .light)
        let data = NSMutableData()
        ImageRenderer(content: page).render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }
        return data as Data
    }
}

/// Serves `/api/v1/*` from the fixtures below.
#endif
