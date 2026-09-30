import { APP_BUNDLE_ID, APP_CLIP_BUNDLE_ID, appleTeamId } from "@/lib/config";

/** apple-app-site-association: universal links for /s/*, the App Clip, and shared web credentials. */
export function appSiteAssociation() {
  const team = appleTeamId();
  const app = `${team}.${APP_BUNDLE_ID}`;
  return {
    applinks: {
      apps: [],
      details: [{ appIDs: [app], appID: app, paths: ["/s/*"], components: [{ "/": "/s/*", comment: "Shared summaries" }] }],
    },
    appclips: { apps: [`${team}.${APP_CLIP_BUNDLE_ID}`] },
    webcredentials: { apps: [app] },
  };
}
