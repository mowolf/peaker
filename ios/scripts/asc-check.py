"""Pre-flight check of App Store Connect access for the TestFlight job.

Uses the same API key as the upload. Prints whether the key authenticates, and whether an app
record exists for the bundle ID, without printing any secret. Exits non-zero with a clear
message instead of xcodebuild's opaque "Error Downloading App Information".
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt  # PyJWT

key_id, issuer, bundle = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], os.environ["BUNDLE_ID"]
private_key = open(os.environ["ASC_KEY_PATH"]).read()
now = int(time.time())
token = jwt.encode({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                   private_key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


def get(path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
                                 headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            return e.code, json.loads(body)
        except ValueError:
            return e.code, {"raw": body[:300].decode(errors="replace")}


def fail(msg):
    print(f"::error::{msg}")
    sys.exit(1)


status, data = get("/v1/apps?limit=200&fields[apps]=bundleId,name")
if status == 401:
    fail("App Store Connect rejected the API key (401). Check APP_STORE_CONNECT_KEY_ID, "
         "APP_STORE_CONNECT_ISSUER_ID and that APP_STORE_CONNECT_PRIVATE_KEY is the full .p8 text of that key.")
if status == 403:
    fail("The API key is valid but not allowed to list apps (403). Give the key the Admin role.")
if status != 200:
    fail(f"Unexpected App Store Connect response {status}: {json.dumps(data)[:300]}")

apps = {a["attributes"]["bundleId"]: a["attributes"]["name"] for a in data.get("data", [])}
print(f"API key OK. Apps visible to this key ({len(apps)}):")
for b, n in sorted(apps.items()):
    print(f"  {b}  ({n})")

status, ids = get(f"/v1/bundleIds?filter[identifier]={bundle}&limit=5")
registered = status == 200 and any(i["attributes"]["identifier"] == bundle for i in ids.get("data", []))
print(f"Bundle ID {bundle} registered in Certificates, Identifiers & Profiles: {'yes' if registered else 'no'}")

if bundle not in apps:
    hint = "" if registered else " Register the bundle ID first (Identifiers → +), then create the app."
    fail(f"No app record for {bundle} in App Store Connect. Create it under Apps → + → New App with exactly "
         f"this bundle ID, or set the repository variable IOS_BUNDLE_ID to one of the bundle IDs listed above.{hint}")
print(f"App record found: {apps[bundle]}")
