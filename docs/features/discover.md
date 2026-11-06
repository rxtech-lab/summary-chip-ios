# Discover

Owners publish from the shared chip-sharing sheet or the podcast-sharing sheet. Publishing explicitly makes the item public, removes expiry, and creates an idempotent discovery record. Removing a listing does not make the default share link private. The publishing sheet explains this distinction and confirms removal.

The library toolbar opens Discover fullscreen on mobile; macOS opens it from the navigation sidebar. Author navigation lists that author's published content. Following and unfollowing use a dedicated sheet; followed authors are available in Discover. Each author byline has a Follow/Following button opening the dedicated follow sheet. Successful follow changes refresh the library. The default feed includes followed authors’ published, public, unexpired chips, excluding accounts scheduled for deletion. Mine, Viewed and Likes scopes retain their existing meaning. Unfollowing removes follow-only posts; previously opened chips remain in Viewed. Community chips use an indigo outline and an author byline with Following/Shared status. The summaries list adds optional `authorId`, `authorName`, and `isFollowingAuthor` fields for public community cards. Web discovery is available without signing in at `/discover`, which has its own link previews (`/discover/og.png`, named for the author on author pages), with author attribution on shared summary and podcast pages. Following currently uses the signed-in native app; the website has no account session.

Standalone daily episodes become library podcasts when published (explained before confirmation). Discover podcast URLs use the existing public player, embedded in an app sheet for non-owner playback. Listing removal revokes these Discover player URLs. Other independently created share links retain their own lifetime.

## Deployment

Apply the checked-in Drizzle migration through the existing migration pipeline before deploying the server and new clients. No production migration or deployment was performed during implementation. Debug continues using localhost and Release uses summary.rxlab.app. No media is uploaded through these endpoints.

## Verification

- Isolated database integration tests apply the migration and exercise owner authorization, idempotent publication, private/expired/account-deletion filtering, author filtering, follow/unfollow, standalone podcast publication, public player access, and listing revocation.
- Focused marketplace and daily-podcast suite: 39 passed, two existing skips.
- TypeScript typecheck, targeted ESLint, and diff whitespace checks passed.
- macOS and iOS Simulator Debug compilation checked without code signing.
- Follow/feed regression verification: 58 integration tests passed across marketplace, summaries and semantic search, including access filtering, scope preservation, keyset pagination, deduplication and opened-chip retention after unfollowing.
- Follow/feed changes passed macOS and iOS Simulator Debug builds without code signing, TypeScript typecheck, targeted ESLint and whitespace checks.
- Live UI interaction, device haptics, and production deployment remain unverified.
