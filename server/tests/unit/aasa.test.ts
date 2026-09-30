import { describe, expect, it } from "vitest";
import { GET } from "@/app/.well-known/apple-app-site-association/route";

describe("apple-app-site-association", () => {
  it("serves applinks, appclips and webcredentials as JSON", async () => {
    const response = await GET();
    expect(response.headers.get("content-type")).toContain("application/json");
    const body = await response.json();
    expect(body.applinks.details[0].appIDs).toEqual(["P9KK452K8P.com.rxlab.summary-chip"]);
    expect(body.applinks.details[0].components).toEqual([expect.objectContaining({ "/": "/s/*" })]);
    expect(body.applinks.details[0].paths).toEqual(["/s/*"]);
    expect(body.appclips.apps).toEqual(["P9KK452K8P.com.rxlab.summary-chip.Clip"]);
    expect(body.webcredentials.apps).toEqual(["P9KK452K8P.com.rxlab.summary-chip"]);
  });
});
