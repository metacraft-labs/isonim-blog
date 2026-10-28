// The browser half of the theme conformance kit (tests/theme_kit.nim).
//
// Reads {"root": <built site>, "pages": [<relative .html paths>]} on stdin,
// serves the site over loopback HTTP (clean URLs, as a static host does),
// and opens every page in the dev shell's pinned Playwright Chromium, in
// the light and the dark colour scheme:
//
// - at 360 CSS pixels wide, the page must not scroll horizontally
//   (WCAG 2.2 SC 1.4.10 Reflow, https://www.w3.org/TR/WCAG22/#reflow,
//   asks for no two-dimensional scrolling at 320px; 360px is the narrowest
//   common phone the kit targets);
// - at 360 pixels, the boxes that scroll sideways inside the page (code
//   blocks, table wrappers: any element whose overflow-x is auto or scroll
//   and whose content is wider than it) are counted by tag and class and
//   reported, so a theme's choice to scroll or wrap wide content is
//   visible; axe's scrollable-region-focusable rule (WCAG 2.2 SC 2.1.1)
//   then requires each of them to be reachable from the keyboard;
// - at 360 and at 1280 pixels, the pinned axe-core
//   (https://github.com/dequelabs/axe-core) reports no violation of its
//   WCAG 2.0, 2.1 and 2.2 level A and AA rules. Colour contrast is among
//   them, so both schemes are checked against SC 1.4.3 and 1.4.11.
//
// Requests to any other origin are refused, so the check never depends on
// the network. axe is injected after the page has loaded; the theme's own
// pages carry no script (the kit checks that separately).
//
// Writes one line of JSON, {"report": {"problems": [...], ...}}, last.
// Exit status 1 when a problem was found.

import { createServer } from "node:http";
import { readFileSync, existsSync, statSync } from "node:fs";
import { join, normalize, extname, sep } from "node:path";
import { pathToFileURL } from "node:url";

const AXE_TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"];
const WIDTHS = [360, 1280];
const NARROW = 360;
const SCHEMES = ["light", "dark"];
const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".avif": "image/avif",
  ".webp": "image/webp",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".xml": "application/xml",
  ".json": "application/json",
  ".txt": "text/plain; charset=utf-8",
  ".woff2": "font/woff2",
};

function readInput() {
  return JSON.parse(readFileSync(0, "utf8"));
}

// The file a request path names under `root`: `/x/` is `/x/index.html`.
function fileFor(root, urlPath) {
  let path;
  try {
    path = decodeURIComponent(urlPath.split("?")[0].split("#")[0]);
  } catch {
    return null;
  }
  if (path.endsWith("/")) path += "index.html";
  const full = normalize(join(root, path));
  if (full !== root && !full.startsWith(root + sep)) return null;
  if (!existsSync(full) || !statSync(full).isFile()) return null;
  return full;
}

function serve(root) {
  const server = createServer((request, response) => {
    const file = fileFor(root, request.url ?? "/");
    if (file === null) {
      response.writeHead(404, { "content-type": "text/plain" });
      response.end("not found");
      return;
    }
    response.writeHead(200, {
      "content-type":
        TYPES[extname(file).toLowerCase()] ?? "application/octet-stream",
    });
    response.end(readFileSync(file));
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

async function axeRun(page, source) {
  await page.addScriptTag({ content: source });
  return await page.evaluate(async (tags) => {
    const result = await globalThis.axe.run(document, {
      runOnly: { type: "tag", values: tags },
      resultTypes: ["violations"],
    });
    return {
      version: globalThis.axe.version,
      violations: result.violations.map((v) => ({
        id: v.id,
        impact: v.impact,
        help: v.help,
        nodes: v.nodes.length,
        target: v.nodes.length > 0 ? String(v.nodes[0].target) : "",
      })),
    };
  }, AXE_TAGS);
}

// The horizontal overflow of the page and the outermost elements that
// stick out past the viewport, by their tag and class.
async function overflow(page) {
  return await page.evaluate(() => {
    const doc = document.documentElement;
    const width = doc.clientWidth;
    const excess = doc.scrollWidth - width;
    const offenders = [];
    if (excess > 0) {
      for (const el of document.body.querySelectorAll("*")) {
        const box = el.getBoundingClientRect();
        if (
          box.right > width + 0.5 &&
          !(
            el.parentElement &&
            el.parentElement.getBoundingClientRect().right > width + 0.5
          )
        ) {
          const name =
            el.tagName.toLowerCase() +
            (el.className && typeof el.className === "string"
              ? "." + el.className.trim().split(/\s+/).join(".")
              : "");
          offenders.push(`${name} (right edge ${Math.round(box.right)}px)`);
          if (offenders.length >= 3) break;
        }
      }
    }
    return { excess, offenders };
  });
}

// The elements that scroll horizontally inside the page: computed
// overflow-x auto or scroll, content wider than the box. Named by tag and
// class, as in `overflow`.
async function scrollers(page) {
  return await page.evaluate(() => {
    const names = [];
    for (const el of document.body.querySelectorAll("*")) {
      const style = getComputedStyle(el);
      if (
        (style.overflowX === "auto" || style.overflowX === "scroll") &&
        el.scrollWidth > el.clientWidth + 1
      )
        names.push(
          el.tagName.toLowerCase() +
            (el.className && typeof el.className === "string"
              ? "." + el.className.trim().split(/\s+/).join(".")
              : ""),
        );
    }
    return names;
  });
}

async function main() {
  const input = readInput();
  const root = normalize(input.root);
  const driverDir = process.env.PLAYWRIGHT_CORE_PATH ?? "";
  const axeDir = process.env.ISONIM_BLOG_AXE ?? "";
  const problems = [];
  const report = {
    problems,
    pages: input.pages.length,
    runs: 0,
    scrollers: {},
  };
  if (!existsSync(join(driverDir, "index.mjs")))
    throw new Error(`no playwright-core at ${driverDir}`);
  if (!existsSync(join(axeDir, "axe.min.js")))
    throw new Error(`no axe.min.js in ${axeDir}`);
  const axeSource = readFileSync(join(axeDir, "axe.min.js"), "utf8");
  const { chromium } = await import(
    pathToFileURL(join(driverDir, "index.mjs")).href
  );
  const server = await serve(root);
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch();
  report.browser = browser.version();
  try {
    for (const scheme of SCHEMES) {
      const context = await browser.newContext({
        colorScheme: scheme,
        viewport: { width: NARROW, height: 800 },
      });
      await context.route("**/*", (route) =>
        route
          .request()
          .url()
          .startsWith(origin + "/")
          ? route.continue()
          : route.abort(),
      );
      const page = await context.newPage();
      for (const path of input.pages) {
        const url = origin + "/" + path.replace(/index\.html$/, "");
        for (const width of WIDTHS) {
          await page.setViewportSize({ width, height: 800 });
          const response = await page.goto(url, { waitUntil: "load" });
          if (!response || response.status() !== 200) {
            problems.push(
              `${path}: HTTP ${response ? response.status() : "no response"}`,
            );
            break;
          }
          if (width === NARROW) {
            const o = await overflow(page);
            if (o.excess > 0)
              problems.push(
                `${path} (${scheme}, ${width}px): scrolls horizontally by ${o.excess}px: ${o.offenders.join(", ")}`,
              );
            if (scheme === SCHEMES[0])
              for (const name of await scrollers(page))
                report.scrollers[name] = (report.scrollers[name] ?? 0) + 1;
          }
          const axe = await axeRun(page, axeSource);
          report.axe = axe.version;
          report.runs += 1;
          for (const v of axe.violations)
            problems.push(
              `${path} (${scheme}, ${width}px): axe ${v.id} (${v.impact}, ${v.nodes} node${v.nodes === 1 ? "" : "s"}, first ${v.target}): ${v.help}`,
            );
        }
      }
      await context.close();
    }
  } finally {
    await browser.close();
    server.close();
  }
  // Vacuity guard: every page was checked at every width in every scheme.
  const expected = input.pages.length * WIDTHS.length * SCHEMES.length;
  if (report.runs !== expected || expected === 0)
    problems.push(
      `axe ran ${report.runs} times; expected ${expected} (pages x widths x schemes)`,
    );
  process.stdout.write("\n" + JSON.stringify({ report }) + "\n");
  process.exit(problems.length > 0 ? 1 : 0);
}

main().catch((error) => {
  process.stdout.write(
    "\n" +
      JSON.stringify({
        report: { problems: [`browser driver: ${error.stack ?? error}`] },
      }) +
      "\n",
  );
  process.exit(1);
});
