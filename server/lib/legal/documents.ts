const effectiveDate = "October 1, 2026";

export const privacyPolicyMarkdown = `# Privacy Policy

*Effective date: ${effectiveDate}*

Chippy is provided by RxLab. This policy explains how Chippy handles information when you use the iPhone and iPad app, the share extension, the Messages app, the App Clip, and shared summary pages on the web.

## Information we process

- **Account information.** We receive the account identifier, name, email address, and profile image made available by your RxLab sign-in.
- **Content you summarize.** We process the links, web pages, PDFs, and text you send to Chippy, the summaries, highlights, and images generated from them, and your chat messages about your summaries.
- **Library activity.** We record which shared summaries you open so they appear in your library, and count views of each summary.
- **Service information.** We process request, device, and diagnostic information needed to operate, secure, and troubleshoot Chippy.

## How we use information

We use this information to authenticate you, fetch and summarize the content you choose, generate cover images, answer your chat questions, keep your library in sync, and maintain and protect the service. Content may be sent to AI and infrastructure providers only as needed to fulfill your request and operate Chippy.

## Sharing and visibility

Summaries are **public by default**: anyone with a summary's link can open it, and its preview may appear wherever you share the link. Public links expire after 7 days by default; you can change how long a link stays open, make a summary private, or delete it at any time. Your summaries stay in your library until you delete them. We may also disclose information to service providers that process it for Chippy, or when disclosure is required to protect users, RxLab, or comply with law.

## Storage and retention

Summaries are stored in the service database; uploaded PDFs and generated images are stored in object storage. Chat messages are used to answer your question and are not stored by Chippy. Summaries are kept until you delete them — when a link expires, only public access ends — and deleting a summary removes its record, uploaded file, and generated image. Some limited information may be retained when required for security, legal compliance, or resolving abuse.

The app stores sign-in credentials in a keychain shared with its extensions so they can work together. Signing out removes those credentials from the device.

## Deleting your account

You can delete your account from Settings in the app. The account is deleted 7 days after you ask, and you can cancel any time before then. When it is deleted, your summaries, uploaded files, generated images, and library history are permanently removed, and your shared links stop working.

## Changes and questions

We may update this policy as Chippy changes. The effective date above identifies the current version. For privacy questions or requests, contact RxLab support.
`;

export const termsOfServiceMarkdown = `# Terms of Service

*Effective date: ${effectiveDate}*

These Terms govern your use of Chippy, a service provided by RxLab. By using Chippy, you agree to these Terms.

## Your account

Use your own RxLab account and keep access to your account and devices secure. You are responsible for activity performed through your account.

## Your content

You keep any rights you hold in the content you submit. You give RxLab permission to fetch, host, process, and transform that content only as needed to operate and secure Chippy and to fulfill your requests, including publishing summaries you leave public at their shared link.

Only submit content you have the right to use, and make sure sharing a summary of it is appropriate. You are responsible for the summaries you share.

## Acceptable use

Do not use Chippy to:

- violate law or another person's rights, including copyright and privacy;
- create or distribute harmful, deceptive, abusive, or illegal content;
- probe, disrupt, overload, or bypass the service's security or access controls; or
- automate access in a way that harms the service or other users.

## AI-generated output

Summaries, highlights, images, and chat answers are generated automatically and may be incomplete, inaccurate, or misleading. Check important details against the original source before relying on or sharing them.

## Service changes

We may add, change, suspend, or discontinue features. We may limit or suspend access, or remove content, when reasonably necessary to protect the service, comply with law, or address a violation of these Terms.

## Disclaimers

Chippy is provided on an "as is" and "as available" basis to the extent permitted by law. RxLab does not promise uninterrupted availability or that generated content will meet every requirement.

## Liability

To the extent permitted by law, RxLab is not responsible for indirect, incidental, special, consequential, or punitive damages, or for loss of data, profits, or business arising from your use of Chippy. Rights that cannot legally be limited remain unaffected.

## Changes and questions

We may update these Terms as the service changes. Continued use after updated Terms take effect means you accept them. The effective date above identifies the current version. Contact RxLab support with questions about these Terms.
`;

export function markdownDocumentResponse(
  markdown: string,
  cacheControl = "public, max-age=3600, stale-while-revalidate=86400",
): Response {
  return new Response(markdown, {
    headers: {
      "cache-control": cacheControl,
      "content-language": "en",
      "content-type": "text/markdown; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
}
