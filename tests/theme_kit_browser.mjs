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
//   them, so both schemes are checked against SC 1.4.3 and 1.4.11. Its
//   best-practice rule `landmark-unique` runs too: a page that repeats a
//   landmark role must give each one a different name (WAI-ARIA Authoring
//   Practices, https://www.w3.org/WAI/ARIA/apg/practices/landmark-regions/),
//   or a screen reader's list of landmarks cannot tell them apart. The
//   renderer's table regions are landmarks, so several tables on one page,
//   or on a listing that joins several excerpts, must have distinct names.
//
// - every page is served with the response headers of the built site's
//   `_headers` file, applied as Cloudflare Pages applies them, so the
//   generated Content-Security-Policy is enforced; a page served without
//   one is a problem, and so is every violation the browser reports
//   (`securitypolicyviolation`, https://www.w3.org/TR/CSP3/#violation-events),
//   so a theme that needs anything the policy does not allow fails.
//
// - on every page with build-time maths or diagrams, in both schemes and at
//   both widths, the browser must really lay them out: every MathML
//   `<math>` has a box, and every `<mfrac>` stacks its numerator above its
//   denominator (MathML Core layout, https://www.w3.org/TR/mathml-core/#fractions-mfrac);
//   a display formula wider than its box scrolls only in a box the
//   keyboard reaches (the renderer's focusable `.math-scroll`), so with
//   the page check above a wide formula neither widens the page nor
//   leaves the keyboard behind;
//   every inline diagram SVG has a box, and every label in it is painted in
//   a colour with at least 4.5:1 contrast (WCAG 2.2 SC 1.4.3) against the
//   shape under it, or the page background. axe does not judge text inside
//   SVG, and a diagram whose palette ignores the dark scheme loses its
//   labels there. As axe does, only what the page shows is judged: a formula
//   or diagram whose surrounding content the theme hides in the page's
//   initial state (a collapsed details layer, say) is counted as hidden,
//   while one hidden on its own, in shown content, is a problem. The counts
//   are reported, so a fixture without maths or diagrams cannot pass
//   vacuously.
//
// Requests to any other origin are refused, so the check never depends on
// the network. axe is evaluated through the DevTools protocol after the page
// has loaded, which the page's policy does not govern (an injected script
// element would be blocked by `script-src 'none'`); the theme's own pages
// carry no script (the kit checks that separately).
//
// Writes one line of JSON, {"report": {"problems": [...], ...}}, last.
// Exit status 1 when a problem was found.

import { createServer } from "node:http";
import { readFileSync, existsSync, statSync } from "node:fs";
import { join, normalize, extname, sep } from "node:path";
import { pathToFileURL } from "node:url";

const AXE_TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"];
// Rules outside those tags that the kit runs as well. axe runs a rule that
// `rules` enables even when `runOnly` selects by tag
// (https://github.com/dequelabs/axe-core/blob/develop/doc/API.md#options-parameter).
const AXE_EXTRA_RULES = ["landmark-unique"];
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

// The rules of a Cloudflare Pages `_headers` file
// (https://developers.cloudflare.com/pages/configuration/headers/): a line
// that starts without indentation is a URL pattern (`*` matches anything,
// `:name` one path segment), the indented `Name: value` lines under it are
// its headers, and `! Name` removes a header an earlier rule set. Patterns
// here are paths; the kit serves one origin. Comments start with `#`.
function headerRules(root) {
  const file = join(root, "_headers");
  if (!existsSync(file)) return [];
  const rules = [];
  for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
    if (line.trim() === "" || line.trimStart().startsWith("#")) continue;
    if (!/^\s/.test(line)) {
      const source = line
        .trim()
        .split(/(\*|:[A-Za-z_]\w*)/)
        .map((part) =>
          part === "*"
            ? ".*"
            : part.startsWith(":")
              ? "[^/]+"
              : part.replace(/[.+?^${}()|[\]\\]/g, "\\$&"),
        )
        .join("");
      rules.push({ pattern: new RegExp(`^${source}$`), set: [], detach: [] });
    } else if (rules.length > 0) {
      const text = line.trim();
      if (text.startsWith("!")) {
        rules.at(-1).detach.push(text.slice(1).trim().toLowerCase());
      } else {
        const colon = text.indexOf(":");
        if (colon > 0)
          rules
            .at(-1)
            .set.push([
              text.slice(0, colon).trim().toLowerCase(),
              text.slice(colon + 1).trim(),
            ]);
      }
    }
  }
  return rules;
}

// The headers the rules give a request path: values of a header set by
// several matching rules are joined with ", ", as Pages does.
function headersFor(rules, urlPath) {
  const path = urlPath.split("?")[0].split("#")[0];
  const headers = {};
  for (const rule of rules) {
    if (!rule.pattern.test(path)) continue;
    for (const [name, value] of rule.set)
      headers[name] = name in headers ? `${headers[name]}, ${value}` : value;
    for (const name of rule.detach) delete headers[name];
  }
  return headers;
}

function serve(root) {
  const rules = headerRules(root);
  const server = createServer((request, response) => {
    const file = fileFor(root, request.url ?? "/");
    if (file === null) {
      response.writeHead(404, { "content-type": "text/plain" });
      response.end("not found");
      return;
    }
    response.writeHead(200, {
      ...headersFor(rules, request.url ?? "/"),
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
  // Evaluated by the DevTools protocol, which the page's policy does not
  // govern; a script element would be refused by script-src 'none'.
  await page.evaluate(source);
  return await page.evaluate(
    async ({ tags, extra }) => {
      const result = await globalThis.axe.run(document, {
        runOnly: { type: "tag", values: tags },
        rules: Object.fromEntries(extra.map((id) => [id, { enabled: true }])),
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
    },
    { tags: AXE_TAGS, extra: AXE_EXTRA_RULES },
  );
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

// Build-time maths and diagrams as the browser lays them out: counts, and a
// problem for each formula or diagram that does not render or whose label
// is unreadable.
async function generated(page) {
  return await page.evaluate(() => {
    const problems = [];
    const counts = {
      present: 0,
      hidden: 0,
      maths: 0,
      displays: 0,
      fractions: 0,
      diagrams: 0,
      labels: 0,
    };
    // Computed colours are `rgb(r, g, b)` or `rgba(r, g, b, a)`.
    const parse = (value) => {
      const m =
        /^rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)$/.exec(
          value,
        );
      return m
        ? {
            rgb: [m[1], m[2], m[3]].map(Number),
            alpha: m[4] === undefined ? 1 : Number(m[4]),
          }
        : null;
    };
    // WCAG 2.2 relative luminance and contrast ratio
    // (https://www.w3.org/TR/WCAG22/#dfn-relative-luminance).
    const luminance = ({ rgb }) => {
      const [r, g, b] = rgb.map((c) => {
        const s = c / 255;
        return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
      });
      return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    };
    const contrast = (a, b) => {
      const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
      return (x + 0.05) / (y + 0.05);
    };
    const shown = (el) => {
      const box = el.getBoundingClientRect();
      return box.width > 0 && box.height > 0;
    };
    // Whether the content around `el` is rendered at all: false inside a
    // subtree the theme hides (display: none), where nothing is judged.
    const inShownContent = (el) => el.parentElement.getClientRects().length > 0;
    const page = parse(getComputedStyle(document.body).backgroundColor);
    for (const math of document.querySelectorAll("math")) {
      counts.present += 1;
      if (!inShownContent(math)) {
        counts.hidden += 1;
        continue;
      }
      counts.maths += 1;
      if (!shown(math))
        problems.push(`a formula is not laid out: ${math.textContent.trim()}`);
      // A display formula wider than the column (MathML does not break it)
      // must scroll in a box the keyboard reaches, as axe requires of
      // scrolling boxes (scrollable-region-focusable, WCAG 2.2 SC 2.1.1): the
      // renderer wraps each one in a focusable `.math-scroll`, and a theme
      // that scrolls the formula itself, or another box around it, fails.
      if (math.getAttribute("display") === "block" && shown(math)) {
        counts.displays += 1;
        for (let el = math; el && el !== document.body; el = el.parentElement) {
          const style = getComputedStyle(el);
          if (
            (style.overflowX === "auto" || style.overflowX === "scroll") &&
            el.scrollWidth > el.clientWidth + 1 &&
            el.tabIndex < 0
          ) {
            problems.push(
              `a display formula scrolls in a box the keyboard cannot reach (${el.tagName.toLowerCase()}): ${math.textContent.trim()}`,
            );
            break;
          }
        }
      }
    }
    for (const frac of document.querySelectorAll("math mfrac")) {
      const math = frac.closest("math");
      if (!inShownContent(math) || !shown(math)) continue;
      counts.fractions += 1;
      const [top, bottom] = [...frac.children].map((c) =>
        c.getBoundingClientRect(),
      );
      if (!top || !bottom || top.bottom > bottom.top + 1)
        problems.push(`a fraction is not stacked: ${frac.textContent.trim()}`);
    }
    for (const svg of document.querySelectorAll("svg.isonim-diagram")) {
      counts.present += 1;
      if (!inShownContent(svg)) {
        counts.hidden += 1;
        continue;
      }
      counts.diagrams += 1;
      if (!shown(svg)) {
        problems.push(`a diagram is not laid out: ${svg.id}`);
        continue;
      }
      for (const text of svg.querySelectorAll("text")) {
        const label = text.textContent.trim();
        if (label === "") continue;
        counts.labels += 1;
        // Hit-testing sees only the viewport, so bring the label into it.
        text.scrollIntoView({ block: "center", inline: "center" });
        const box = text.getBoundingClientRect();
        const ink = parse(getComputedStyle(text).fill);
        if (box.width <= 0 || !ink || ink.alpha === 0) {
          problems.push(`the diagram label "${label}" is not painted`);
          continue;
        }
        // The topmost painted shape under the label's centre, else the page.
        let under = page;
        const x = box.left + box.width / 2;
        const y = box.top + box.height / 2;
        const stack = document.elementsFromPoint(x, y);
        if (!stack.includes(text)) {
          problems.push(
            `the diagram label "${label}" is not on top where it is drawn`,
          );
          continue;
        }
        for (const el of stack) {
          if (el === text || el.closest("text") || !svg.contains(el)) continue;
          if (["svg", "g"].includes(el.tagName)) continue;
          const fill = parse(getComputedStyle(el).fill);
          if (fill && fill.alpha > 0) {
            under = fill;
            break;
          }
        }
        const ratio = contrast(ink, under);
        if (ratio < 4.5)
          problems.push(
            `the diagram label "${label}" has contrast ${ratio.toFixed(2)}:1 against what is under it (rgb(${under.rgb}) under rgb(${ink.rgb})), below 4.5:1`,
          );
      }
    }
    window.scrollTo(0, 0);
    return { problems, counts };
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
    generated: {
      present: 0,
      hidden: 0,
      maths: 0,
      displays: 0,
      fractions: 0,
      diagrams: 0,
      labels: 0,
    },
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
      // Collect every Content-Security-Policy violation from the start of
      // each document; init scripts are not subject to the page's policy.
      await context.addInitScript(() => {
        globalThis.__cspViolations = [];
        document.addEventListener("securitypolicyviolation", (event) =>
          globalThis.__cspViolations.push(
            `${event.effectiveDirective} ${event.blockedURI || "(inline)"}`,
          ),
        );
      });
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
          // Vacuity guard: the policy under test was really in force.
          if (!(await response.allHeaders())["content-security-policy"]) {
            problems.push(
              `${path}: served without a Content-Security-Policy (the built _headers has no rule for it)`,
            );
            report.unprotected = (report.unprotected ?? 0) + 1;
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
          const content = await generated(page);
          for (const [key, count] of Object.entries(content.counts))
            report.generated[key] += count;
          for (const problem of content.problems)
            problems.push(`${path} (${scheme}, ${width}px): ${problem}`);
          const axe = await axeRun(page, axeSource);
          report.axe = axe.version;
          report.runs += 1;
          for (const v of axe.violations)
            problems.push(
              `${path} (${scheme}, ${width}px): axe ${v.id} (${v.impact}, ${v.nodes} node${v.nodes === 1 ? "" : "s"}, first ${v.target}): ${v.help}`,
            );
          // Read after axe, so resources loaded late (fonts, background
          // images) have been requested too.
          const blocked = await page.evaluate(() => [
            ...new Set(globalThis.__cspViolations ?? []),
          ]);
          for (const violation of blocked)
            problems.push(
              `${path} (${scheme}, ${width}px): Content-Security-Policy blocked ${violation}`,
            );
          report.policyChecks = (report.policyChecks ?? 0) + 1;
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
  if ((report.policyChecks ?? 0) !== expected)
    problems.push(
      `the Content-Security-Policy was checked ${report.policyChecks ?? 0} times; expected ${expected}`,
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
