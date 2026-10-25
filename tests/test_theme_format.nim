## The theme package format: theme.toml validation, default configuration
## under site.toml, required keys, DTCG tokens to CSS custom properties and
## theme-color (backend-independent, run on C and JavaScript), then, natively,
## the shipped theme's manifest, package-name resolution, the site
## configuration a theme contributes to, and the Nimble package's file set.
##
## No test doubles: the native cases read real theme directories with the
## real TOML decoder, and the Nimble case runs the real `nimble dump`.
import std/[unittest, json, strutils]
import isonim_blog/[model, theme_format]

proc manifest(toml: JsonNode): ThemeManifest = parseThemeManifest(toml)

proc failsWith(body: proc(); fragment: string): bool =
  try:
    body()
    false
  except BlogError as cause:
    if fragment notin cause.msg: echo "unexpected message: ", cause.msg
    fragment in cause.msg

suite "theme.toml":
  test "a complete manifest is decoded":
    let m = manifest(%*{"name": "isonim-blog-theme-example", "version": "1.2.0",
      "description": "Example", "tokens": ["tokens/ref.json", "tokens/sys.json"],
      "stylesheets": ["assets/a.css", "assets/print/b.css"], "theme_color": "sys.color.surface",
      "required": ["description", "author.name"], "directives": ["pullquote"],
      "config": {"paginate": 4, "feeds": {"per_tag": false}}})
    check m.name == "isonim-blog-theme-example"
    check m.version == "1.2.0"
    check m.tokenFiles == @["tokens/ref.json", "tokens/sys.json"]
    check m.stylesheets == @["assets/a.css", "assets/print/b.css"]
    check m.themeColor == "sys.color.surface"
    check m.required == @["description", "author.name"]
    check m.directives == @["pullquote"]
    check m.config["feeds"]["per_tag"].getBool == false

  test "only a name is required":
    let m = manifest(%*{"name": "plain"})
    check m.tokenFiles.len == 0 and m.stylesheets.len == 0 and m.required.len == 0
    check m.config.kind == JObject and m.config.len == 0

  test "invalid manifests fail naming the problem":
    check failsWith(proc() = discard manifest(%*{"name": "x", "stylesheet": ["a.css"]}), "unknown key stylesheet")
    check failsWith(proc() = discard manifest(%*{"version": "1"}), "name must be a package name")
    check failsWith(proc() = discard manifest(%*{"name": "Bad_Name"}), "Bad_Name")
    check failsWith(proc() = discard manifest(%*{"name": "x", "tokens": "t.json"}), "tokens must be a list")
    check failsWith(proc() = discard manifest(%*{"name": "x", "tokens": ["../t.json"]}), "inside the theme: ../t.json")
    check failsWith(proc() = discard manifest(%*{"name": "x", "tokens": ["/abs.json"]}), "inside the theme")
    check failsWith(proc() = discard manifest(%*{"name": "x", "stylesheets": ["layouts/a.css"]}), "under assets/")
    check failsWith(proc() = discard manifest(%*{"name": "x", "stylesheets": ["assets/a.scss"]}), "under assets/")
    check failsWith(proc() = discard manifest(%*{"name": "x", "tokens": ["t.json"],
      "stylesheets": [tokenStylesheetPath]}), "generated from the tokens")
    check failsWith(proc() = discard manifest(%*{"name": "x", "theme_color": "sys.color.bg"}),
      "declares no tokens")
    check failsWith(proc() = discard manifest(%*{"name": "x", "required": ["author..name"]}), "author..name")
    check failsWith(proc() = discard manifest(%*{"name": "x", "directives": ["1st"]}), "1st")
    check failsWith(proc() = discard manifest(%*{"name": "x", "directives": ["a", "a"]}), "lists a twice")
    for key in ["theme", "url", "base_path"]:
      check failsWith(proc() = discard manifest(%*{"name": "x", "config": {key: "v"}}), "may not set " & key)

suite "default configuration and required keys":
  test "the site's values win; tables merge key by key; lists are replaced":
    let defaults = %*{"paginate": 4, "description": "theme default",
      "feeds": {"rss": "/rss.xml", "per_tag": false}, "markdown": {"diagrams": ["d2"]}}
    let site = %*{"title": "Site", "feeds": {"rss": "/feed.xml"}, "markdown": {"diagrams": ["dot"]},
      "paginate": 7}
    let merged = mergeDefaults(site, defaults)
    check merged["paginate"].getInt == 7
    check merged["description"].getStr == "theme default"
    check merged["feeds"] == %*{"rss": "/feed.xml", "per_tag": false}
    check merged["markdown"]["diagrams"] == %*["dot"]
    check merged["title"].getStr == "Site"
    # Neither input is modified.
    check site["feeds"] == %*{"rss": "/feed.xml"}
    check defaults["feeds"]["rss"].getStr == "/rss.xml"

  test "required keys are reported together; empty values count as missing":
    let theme = manifest(%*{"name": "needs", "required": ["description", "author.name", "author.url", "social"]})
    let config = %*{"title": "T", "description": "", "author": {"name": "A"}, "social": []}
    check missingRequired(config, theme.required) == @["description", "author.url", "social"]
    check failsWith(proc() = requireKeys(config, theme),
      "theme needs requires site.toml keys description, author.url, social")
    requireKeys(%*{"description": "d", "author": {"name": "A", "url": "/a/"}, "social": ["x"]}, theme)

suite "design tokens":
  const reference = """{"ref": {"color": {"$type": "color",
    "white": {"$value": "#ffffff"}, "black": {"$value": "#000000"}, "blue": {"$value": "#1d4ed8"}}}}"""
  const system = """{"sys": {"color": {"$type": "color",
    "surface": {"$value": "{ref.color.white}", "$extensions": {"modes": {"Light": "{ref.color.white}", "Dark": "{ref.color.black}"}}},
    "link": {"$value": "{ref.color.blue}", "$extensions": {"modes": {"light": "{ref.color.blue}", "dark": "{ref.color.blue}"}}},
    "rule": {"$value": "#cccccc"}},
    "size": {"gap": {"$type": "dimension", "$value": "1rem"}},
    "type": {"body": {"$type": "typography", "$value": {"fontFamily": "serif"}}}}}"""

  test "aliases resolve across documents; dark values come from $extensions.modes":
    let tokens = themeTokens([reference, system])
    check tokens["sys.color.surface"] == %*{"value": "#ffffff", "dark": "#000000"}
    # A dark value equal to the light one is not repeated.
    check tokens["sys.color.link"] == %*{"value": "#1d4ed8"}
    check tokens["sys.color.rule"] == %*{"value": "#cccccc"}
    check tokens["sys.size.gap"] == %*{"value": "1rem"}
    check tokens["ref.color.black"] == %*{"value": "#000000"}
    # A composite token has no single CSS value and is left out.
    check not tokens.hasKey("sys.type.body")
    var keys: seq[string]
    for key, _ in tokens: keys.add key
    check keys == @["ref.color.black", "ref.color.blue", "ref.color.white", "sys.color.link",
      "sys.color.rule", "sys.color.surface", "sys.size.gap"]

  test "the stylesheet writes every token, dark values under prefers-color-scheme":
    let css = tokenStylesheet(themeTokens([reference, system]))
    check css == ":root {\n  color-scheme: light dark;\n" &
      "  --ref-color-black: #000000;\n  --ref-color-blue: #1d4ed8;\n  --ref-color-white: #ffffff;\n" &
      "  --sys-color-link: #1d4ed8;\n  --sys-color-rule: #cccccc;\n  --sys-color-surface: #ffffff;\n" &
      "  --sys-size-gap: 1rem;\n}\n" &
      "@media (prefers-color-scheme: dark) {\n  :root {\n    --sys-color-surface: #000000;\n  }\n}\n"

  test "broken tokens fail naming the token":
    check failsWith(proc() = discard themeTokens(["""{"a": {"$value": "{missing.token}"}}"""]), "missing.token")
    check failsWith(proc() = discard themeTokens(["""{"a": {"$value": "#fff",
      "$extensions": {"modes": {"dark": "{nowhere}"}}}}"""]), "token a")
    check failsWith(proc() = discard themeTokens(["""{"a": {"$value": "{b}"}, "b": {"$value": "{a}"}}"""]), "cyclic")
    check failsWith(proc() = discard themeTokens(["not json"]), "token document")

  test "a value that could escape its declaration is refused":
    for value in ["red; } body { display: none", "red</style>", "a /* comment", "url(x)\nnext"]:
      let tokens = %*{"sys.color.bad": {"value": value}}
      check failsWith(proc() = discard tokenStylesheet(tokens), "cannot be written to CSS")
    check failsWith(proc() = discard tokenStylesheet(%*{"sys.color bad": {"value": "red"}}), "custom property")

  test "theme-color follows both schemes, or one value for both":
    let tokens = themeTokens([reference, system])
    check themeColors(tokens, "sys.color.surface") == @[("#ffffff", "(prefers-color-scheme: light)"),
      ("#000000", "(prefers-color-scheme: dark)")]
    check themeColors(tokens, "sys.color.rule") == @[("#cccccc", "")]
    check themeColors(tokens, "").len == 0
    check failsWith(proc() = discard themeColors(tokens, "sys.color.none"), "names no token")

when not defined(js):
  import std/[os, algorithm]
  import isonim_blog/inputs
  import ./site_helpers

  proc writeTheme(dir, toml: string) =
    createDir(dir)
    writeFile(dir / "theme.toml", toml)

  suite "theme directories":
    test "the shipped minimal theme is valid and its tokens resolve in both schemes":
      let theme = repoRoot / "themes/minimal"
      let (m, info) = loadThemeInfo(theme)
      check m.name == "isonim-blog-theme-minimal"
      check info.name == m.name and info.version == m.version
      check m.stylesheets == @["assets/minimal.css"]
      for key in ["sys.color.surface", "sys.color.text", "sys.color.text-muted", "sys.color.link"]:
        check info.tokens[key].hasKey("dark")
      for layout in requiredLayouts: check fileExists(theme / "layouts" / layout & ".nim")
      check themeTreeHash(theme).startsWith("sha256-")

    test "files a theme.toml names must exist; the generated stylesheet path is reserved":
      let dir = createTempDir("isonim-blog-theme-", "")
      defer: removeDir(dir)
      writeTheme(dir, "name = \"t\"\ntokens = [\"tokens.json\"]\n")
      check failsWith(proc() = discard readThemeManifest(dir), "names tokens.json, which the theme does not have")
      writeFile(dir / "tokens.json", "{}")
      discard readThemeManifest(dir)
      createDir(dir / "assets")
      writeFile(dir / tokenStylesheetPath, ":root{}")
      check failsWith(proc() = discard readThemeManifest(dir), "a theme cannot ship it")
      check failsWith(proc() = discard readThemeManifest(dir / "nothing"), "needs a theme.toml")

    test "package names resolve through ISONIM_BLOG_THEME_PATH, then the shipped themes":
      let dir = createTempDir("isonim-blog-themes-", "")
      let previous = getEnv("ISONIM_BLOG_THEME_PATH")
      defer:
        putEnv("ISONIM_BLOG_THEME_PATH", previous)
        removeDir(dir)
      putEnv("ISONIM_BLOG_THEME_PATH", "")
      check findThemePackage("isonim-blog-theme-minimal") == absolutePath(repoRoot / "themes/minimal")
      # A directory of themes, holding the package under its name ...
      writeTheme(dir / "shelf/acme-theme", "name = \"acme-theme\"\n")
      # ... and a search entry that is itself a theme root.
      writeTheme(dir / "standalone", "name = \"solo-theme\"\n")
      putEnv("ISONIM_BLOG_THEME_PATH", dir / "shelf" & PathSep & dir / "standalone")
      check findThemePackage("acme-theme") == absolutePath(dir / "shelf/acme-theme")
      check findThemePackage("solo-theme") == absolutePath(dir / "standalone")
      # The search path comes before the shipped themes.
      writeTheme(dir / "shelf/isonim-blog-theme-minimal", "name = \"isonim-blog-theme-minimal\"\n")
      check findThemePackage("isonim-blog-theme-minimal") == absolutePath(dir / "shelf/isonim-blog-theme-minimal")
      # A directory named for the package that is another package is an error.
      writeTheme(dir / "shelf/mislabelled", "name = \"other-theme\"\n")
      check failsWith(proc() = discard findThemePackage("mislabelled"), "names other-theme, not mislabelled")
      check failsWith(proc() = discard findThemePackage("absent-theme"),
        "theme package absent-theme not found in " & dir / "shelf")
      check failsWith(proc() = discard findThemePackage("Not A Name"), "invalid theme package name")

    test "an explicit theme must be the package site.toml names":
      let site = createTempDir("isonim-blog-site-", "")
      defer: removeDir(site)
      writeFile(site / "site.toml", "title = \"S\"\ndescription = \"d\"\ntheme = \"isonim-blog-theme-minimal\"\n")
      check resolveTheme(site) == absolutePath(repoRoot / "themes/minimal")
      check resolveTheme(site, repoRoot / "themes/minimal") == absolutePath(repoRoot / "themes/minimal")
      check failsWith(proc() = discard resolveTheme(site, repoRoot / "tests/fixtures/theme"),
        "names theme isonim-blog-theme-minimal, but the theme given is fixture-theme")
      writeFile(site / "site.toml", "title = \"S\"\ntheme = \"themes/none\"\n")
      check failsWith(proc() = discard resolveTheme(site), "theme path does not exist: themes/none")

    test "site.toml over the theme's defaults, with its required keys checked":
      let site = createTempDir("isonim-blog-site-", "")
      defer: removeDir(site)
      let theme = repoRoot / "tests/fixtures/theme-capabilities"
      writeFile(site / "site.toml", "title = \"S\"\ntheme = " & $(%theme) & "\nauthor = { name = \"A\" }\n")
      var config = readSiteConfig(site)
      check config.paginate == 3            # the theme's default
      check config.perTagFeeds == false     # a nested default
      check config.rssPath == "/feed.xml"   # untouched framework default
      writeFile(site / "site.toml", "title = \"S\"\ntheme = " & $(%theme) &
        "\nauthor = { name = \"A\" }\npaginate = 9\n[feeds]\nper_tag = true\n")
      config = readSiteConfig(site)
      check config.paginate == 9 and config.perTagFeeds
      writeFile(site / "site.toml", "title = \"S\"\ntheme = " & $(%theme) & "\n")
      check failsWith(proc() = discard readSiteConfig(site),
        "theme fixture-capabilities requires site.toml key author.name")

    test "the Nimble package installs every file of the theme":
      let theme = repoRoot / "themes/minimal"
      let home = createTempDir("isonim-blog-nimble-home-", "")
      defer: removeDir(home)
      let dumped = runProcess(tool("nimble"), ["dump", "--json"], cwd = theme,
        extraEnv = [("HOME", home)])
      check dumped.code == 0
      let package = parseJson(dumped.output[dumped.output.find('{') .. ^1])
      check package["name"].getStr == "isonim_blog_theme_minimal"
      check package["version"].getStr == readThemeManifest(theme).version
      var installed: seq[string]
      for file in package["installFiles"]: installed.add file.getStr
      for dir in package["installDirs"]:
        for file in walkDirRec(theme / dir.getStr, relative = true):
          installed.add dir.getStr & "/" & file.replace('\\', '/')
      var present: seq[string]
      for file in walkDirRec(theme, relative = true):
        if not file.endsWith(".nimble"): present.add file.replace('\\', '/')
      check sorted(installed) == sorted(present)
