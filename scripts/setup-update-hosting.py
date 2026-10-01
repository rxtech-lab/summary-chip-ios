#!/usr/bin/env python3
"""Configure only Summary Chip's GitHub Pages site and Cloudflare update hostname."""
import argparse
import json
import os
import pathlib
import ssl
import subprocess
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = "rxtech-lab/summary-chip-ios"
DOMAIN = "update.summary.rxlab.app"
TARGET = "rxtech-lab.github.io"


def github(method="GET", payload=None, allow_missing=False):
    command = ["gh", "api", f"repos/{REPOSITORY}/pages", "--method", method]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload else None,
                            text=True, capture_output=True, check=False)
    if result.returncode:
        if allow_missing and "HTTP 404" in result.stderr:
            return None
        raise RuntimeError("GitHub Pages request failed: " + result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=pathlib.Path, default=pathlib.Path("server/.env"))
    parser.add_argument("--apply", action="store_true", help="Apply changes; otherwise only inspect")
    args = parser.parse_args()
    token = os.environ.get("CLOUDFLARE_API_TOKEN")
    if not token and args.env_file.exists():
        for line in args.env_file.read_text().splitlines():
            name, separator, value = line.strip().removeprefix("export ").partition("=")
            if separator and name.strip() == "CLOUDFLARE_API_TOKEN":
                token = value.strip().strip("\"'")
                break
    if not token:
        raise RuntimeError("CLOUDFLARE_API_TOKEN with Zone Read and DNS Edit permission is required")

    def cloudflare(path, method="GET", payload=None):
        request = urllib.request.Request("https://api.cloudflare.com/client/v4/" + path,
            method=method, headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
            data=json.dumps(payload).encode() if payload is not None else None)
        try:
            # python.org macOS installations may not install a default CA bundle.
            ca_file = "/etc/ssl/cert.pem" if pathlib.Path("/etc/ssl/cert.pem").exists() else None
            with urllib.request.urlopen(request, timeout=30, context=ssl.create_default_context(cafile=ca_file)) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"Cloudflare request failed (HTTP {error.code}); check Zone Read and DNS Edit permissions") from None
        if not result.get("success"):
            raise RuntimeError("Cloudflare rejected the request")
        return result["result"]

    pages = github(allow_missing=True)
    if pages and pages.get("cname") not in (None, "", DOMAIN):
        raise RuntimeError("Repository already serves another custom domain; refusing to replace it")
    zones = cloudflare("zones?" + urllib.parse.urlencode({"name": "rxlab.app", "status": "active"}))
    if len(zones) != 1:
        raise RuntimeError("Expected access to exactly one active rxlab.app zone")
    zone = zones[0]["id"]
    records = cloudflare(f"zones/{zone}/dns_records?" + urllib.parse.urlencode({"name": DOMAIN}))
    if len(records) > 1 or any(r["type"] != "CNAME" or r["content"].rstrip(".") != TARGET for r in records):
        raise RuntimeError("Hostname already has conflicting DNS records; refusing to overwrite them")
    print(f"GitHub Pages: {REPOSITORY}, Actions publishing, custom domain {DOMAIN}")
    print(f"Cloudflare DNS: CNAME {DOMAIN} -> {TARGET}, DNS only, TTL auto")
    if not args.apply:
        print("Inspection only. Run with --apply to configure.")
        return

    # Claim the hostname in GitHub before creating its public DNS record.
    if pages is None:
        github("POST", {"build_type": "workflow"})
    github("PUT", {"build_type": "workflow", "cname": DOMAIN})
    payload = {"type": "CNAME", "name": DOMAIN, "content": TARGET, "proxied": False, "ttl": 1}
    if records:
        cloudflare(f"zones/{zone}/dns_records/{records[0]['id']}", "PATCH", payload)
    else:
        cloudflare(f"zones/{zone}/dns_records", "POST", payload)
    updated = github()
    if updated.get("https_certificate", {}).get("state") == "approved":
        github("PUT", {"https_enforced": True})
        print("HTTPS enforcement enabled.")
    else:
        print("HTTPS certificate pending. Rerun --apply after GitHub issues the certificate to enforce HTTPS.")
    print("Pages and DNS configured. The first signed release will publish appcast.xml.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, urllib.error.URLError) as error:
        raise SystemExit(str(error)) from None
