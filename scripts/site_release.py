#!/usr/bin/env python3
"""Write the release facts into the site from CHANGELOG.md (one source for the version and the notes).

  scripts/site_release.py [--dmg path/to/MaruDoc.dmg]

- site/update/index.html: the page "Check for Updates…" opens (marudoc.app/update/?v=1.0.4). It knows the latest
  version and every note at build time, so it needs no fetch (the site's CSP has connect-src 'none').
- site/version.json: what the app's "Check for Updates…" fetches when the user clicks it.
- site/index.html: every "Version x.y.z" and the DMG size ("7.7 MB"), so the page never shows two different numbers.
"""
import argparse, html, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")


def releases():
    text = open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8").read()
    out = []
    for m in re.finditer(r"^## (\d+\.\d+\.\d+) \((\d{4}-\d{2}-\d{2})\)\n(.*?)(?=^## |\Z)", text, re.S | re.M):
        items = [l[2:].strip() for l in m.group(3).splitlines() if l.startswith("- ")]
        out.append({"version": m.group(1), "date": m.group(2), "items": items})
    if not out:
        sys.exit("CHANGELOG.md has no '## x.y.z (yyyy-mm-dd)' entries")
    return out


def notes_html(rels):
    parts = []
    for r in rels:
        lis = "".join(f"<li>{html.escape(i)}</li>" for i in r["items"])
        parts.append(f'<section class="rel" id="v{r["version"]}"><h3>{r["version"]} <span>{r["date"]}</span></h3><ul>{lis}</ul></section>')
    return "\n      ".join(parts)


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Check for updates | MaruDoc</title>
<meta name="description" content="The latest version of MaruDoc for Mac and what changed in each version.">
<link rel="canonical" href="https://marudoc.app/update/">
<link rel="icon" href="/img/favicon.png">
<meta name="theme-color" content="#04060f">
<style>
  :root { --bg: #04060f; --text: #f4f6ff; --sub: #aab3d4; --dim: #7a84a8; --line: rgba(150, 180, 255, 0.14); --accent: #2f7bff; --accent2: #6e9bff; --ok: #30d158;
    --chrome: linear-gradient(180deg, #ffffff 0%, #ffffff 42%, #c2cbe6 64%, #9eabd2 76%, #eef2ff 100%); }
  * { box-sizing: border-box; }
  body { margin: 0; color: var(--text); font: 17px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", "Segoe UI", Roboto, sans-serif; -webkit-font-smoothing: antialiased;
    background: radial-gradient(90% 40% at 50% 0%, #1c2757 0%, #0d1434 40%, #04060f 80%) no-repeat, #04060f; }
  a { color: var(--accent2); }
  main { max-width: 720px; margin: 0 auto; padding: 0 20px 96px; }
  header { display: flex; align-items: center; justify-content: space-between; padding: 18px 0 0; font-size: 14px; }
  header a.brand { display: flex; align-items: center; gap: 10px; color: var(--text); font-weight: 650; text-decoration: none; }
  header img { width: 28px; height: 28px; }
  h1 { font-size: clamp(32px, 6vw, 46px); line-height: 1.1; letter-spacing: -0.03em; margin: 64px 0 12px; font-weight: 740;
    background: var(--chrome); -webkit-background-clip: text; background-clip: text; color: transparent; }
  .lead { color: var(--sub); font-size: 18px; margin: 0; }
  .card { margin: 28px 0 0; padding: 22px; border-radius: 16px; border: 1px solid var(--line); background: rgba(13, 20, 52, 0.55); }
  .card p { margin: 0 0 12px; color: var(--sub); }
  .card p:last-child { margin-bottom: 0; }
  .card b { color: var(--text); }
  .ok b::before { content: ""; display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: var(--ok); margin-right: 9px; vertical-align: 2px; box-shadow: 0 0 8px rgba(48, 209, 88, 0.8); }
  .btn { display: inline-block; color: #fff; background: var(--accent); border-radius: 980px; padding: 12px 24px; font-weight: 650; text-decoration: none;
    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.25), 0 8px 30px rgba(47, 123, 255, 0.35); }
  code { font: 13.5px ui-monospace, "SF Mono", Menlo, monospace; background: rgba(170, 190, 255, 0.1); padding: 2px 6px; border-radius: 5px; color: #dfe6ff; }
  h2 { font-size: 22px; margin: 64px 0 4px; }
  .rel { border-top: 1px solid var(--line); padding: 16px 0 4px; }
  .rel h3 { margin: 0; font-size: 17px; }
  .rel h3 span { color: var(--dim); font-weight: 500; font-size: 14px; margin-left: 8px; }
  .rel ul { margin: 8px 0 12px; padding-left: 1.2em; color: var(--sub); font-size: 15.5px; }
  .rel.new h3::after { content: "New"; margin-left: 10px; font-size: 11px; font-weight: 700; letter-spacing: 0.05em; text-transform: uppercase; color: var(--accent2); }
  [hidden] { display: none !important; }
  footer { margin-top: 64px; font-size: 13.5px; color: var(--dim); }
</style>
</head>
<body>
<main>
  <header><a class="brand" href="/"><img src="/img/icon.png" alt="">MaruDoc</a><a href="/">Home</a></header>
  <h1>Check for updates</h1>
  <p class="lead">The latest version is <b>__LATEST__</b>, released __DATE__.</p>

  <div class="card ok" id="current" hidden>
    <p><b>You have the latest version.</b></p>
    <p>MaruDoc __LATEST__ is running on your Mac. There is nothing to do.</p>
  </div>

  <div class="card" id="newer" hidden>
    <p><b>MaruDoc __LATEST__ is available.</b> You have <span id="yours"></span>.</p>
    <p>Download it, open the DMG and drag MaruDoc to Applications, replacing the old one. Your settings stay.</p>
    <p><a class="btn" href="/MaruDoc.dmg">Download MaruDoc __LATEST__</a></p>
    <p>Installed with Homebrew? Run <code>brew upgrade --cask marudoc</code>.</p>
  </div>

  <div class="card" id="plain">
    <p>In MaruDoc, choose <b>Check for Updates…</b> from the menu bar icon to compare with the version on your Mac.</p>
    <p><a class="btn" href="/MaruDoc.dmg">Download MaruDoc __LATEST__</a></p>
    <p>The Mac App Store version updates through the App Store. Homebrew: <code>brew upgrade --cask marudoc</code>.</p>
  </div>

  <h2>What's new</h2>
  <div id="notes">
      __NOTES__
  </div>
  <footer>Check for Updates in MaruDoc reads only marudoc.app/version.json, and only when you click it. Your files never leave your Mac.</footer>
</main>
<script>
(function () {
  var LATEST = "__LATEST__";
  var v = new URLSearchParams(location.search).get("v");
  if (!v || !/^\\d+(\\.\\d+){0,3}/.test(v)) { return; }
  v = v.match(/^\\d+(\\.\\d+){0,3}/)[0];
  var cmp = function (a, b) {
    var x = a.split(".").map(Number), y = b.split(".").map(Number);
    for (var i = 0; i < Math.max(x.length, y.length); i++) { var d = (x[i] || 0) - (y[i] || 0); if (d) { return d; } }
    return 0;
  };
  document.getElementById("plain").hidden = true;
  if (cmp(v, LATEST) >= 0) { document.getElementById("current").hidden = false; return; }
  document.getElementById("newer").hidden = false;
  document.getElementById("yours").textContent = v;
  document.querySelectorAll(".rel").forEach(function (s) { if (cmp(s.id.slice(1), v) > 0) { s.classList.add("new"); } });
})();
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dmg", help="the release DMG, to write its size into the site")
    a = ap.parse_args()
    rels = releases()
    latest = rels[0]
    page = PAGE.replace("__LATEST__", latest["version"]).replace("__DATE__", latest["date"]).replace("__NOTES__", notes_html(rels))
    os.makedirs(os.path.join(SITE, "update"), exist_ok=True)
    open(os.path.join(SITE, "update", "index.html"), "w", encoding="utf-8").write(page)
    # what "Check for Updates…" in the app fetches (only when the user clicks it)
    info = {"version": latest["version"], "date": latest["date"], "download": "https://marudoc.app/MaruDoc.dmg",
            "page": "https://marudoc.app/update/", "notes": latest["items"]}
    json.dump(info, open(os.path.join(SITE, "version.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    p = os.path.join(SITE, "index.html")
    s = open(p, encoding="utf-8").read()
    s, n = re.subn(r"Version \d+\.\d+\.\d+", f"Version {latest['version']}", s)
    if a.dmg:
        mb = os.path.getsize(a.dmg) / 1_000_000
        s = re.sub(r"(?<=· )\d+(\.\d)? MB", f"{mb:.1f} MB", s)  # only the details lines ("· 7.7 MB"), never "44.6 MB to 7.7 MB"
    s = s.replace('href="https://github.com/MaruDoc/marudoc/releases">Release notes', 'href="/update/">Release notes')
    open(p, "w", encoding="utf-8").write(s)
    print(f"site: latest {latest['version']} ({latest['date']}), {n} version mentions, {len(rels)} releases on /update/")


if __name__ == "__main__":
    main()
