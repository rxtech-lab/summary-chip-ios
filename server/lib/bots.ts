/** Link-preview crawlers and bots that should not count as a view. */
const BOT_PATTERN = /bot|crawl|spider|slurp|facebookexternalhit|facebookcatalog|embedly|quora link preview|outbrain|pinterest|vkshare|w3c_validator|whatsapp|telegram|slack|discord|skype|linkedin|twitterbot|applebot|iframely|mastodon|preview|headless|lighthouse|curl|wget|python-requests|go-http-client|node-fetch|axios/i;

export function isBotUserAgent(userAgent: string | null | undefined): boolean {
  if (!userAgent) return true;
  return BOT_PATTERN.test(userAgent);
}
