## The theme package format, backend-independent: `theme.toml` (decoded to
## JSON by the native input adapter), the theme's default configuration
## merged under `site.toml`, the `site.toml` keys a theme requires, and its
## design tokens turned into CSS custom properties.
##
## A theme's root mirrors a site: `layouts/`, `includes/` and `assets/`, an
## optional `og.svg.nim`, a `README.md` and `theme.toml`:
##
## ```toml
## name = "isonim-blog-theme-example"   # required: the package name
## version = "0.1.0"
## description = "One line about the theme"
## tokens = ["tokens.json"]             # DTCG documents, merged in order
## stylesheets = ["assets/theme.css"]   # linked by every page, in order
## theme_color = "sys.color.surface"    # a color token: <meta name="theme-color">
## required = ["description"]           # site.toml keys the theme needs
## directives = ["pullquote"]           # registered by includes/directives.nim
##
## [config]                             # defaults; the site's own values win
## paginate = 8
## ```
##
## Tokens follow the W3C Design Tokens Community Group format
## (https://tr.designtokens.org/format/), resolved by `isonim/theming/dtcg`.
## A token that differs between colour schemes carries its scheme values in
## `$extensions.modes` (`{"light": ..., "dark": ...}`, names matched without
## regard to case), the convention design tools such as Figma export.
import std/[json, strutils, tables, algorithm]
import isonim/theming/dtcg
import ./model

type
  ThemeManifest* = object
    ## A decoded, validated `theme.toml`.
    name*, version*, description*: string
    tokenFiles*: seq[string]   ## DTCG documents, relative to the theme root
    stylesheets*: seq[string]  ## asset paths (`assets/...`) every page links
    themeColor*: string        ## a color token key, or ""
    required*: seq[string]     ## dotted site.toml keys, e.g. "author.name"
    directives*: seq[string]   ## directive names includes/directives.nim registers
    config*: JsonNode          ## default site.toml values (a table)

const
  themeManifestName* = "theme.toml"
  tokenStylesheetPath* = "assets/theme-tokens.css"
    ## The stylesheet generated from a theme's tokens. A site's own file at
    ## this path replaces it, like any other asset; a theme may not ship one.
  requiredLayouts* = ["post", "page", "index", "tag", "category", "archive"]
    ## The layouts the build selects by default for every page kind: content
    ## posts and pages, the paginated index, term pages and date archives.
    ## A complete theme provides all of them (`just test-theme` checks).
  themeFileDirs* = ["layouts", "includes", "assets"]
    ## The directories of a theme that resolve against the site's.
  siteOnlyKeys = ["theme", "url", "base_path"]
    ## Keys that describe one site, never its look: a theme cannot default them.
  manifestKeys = ["name", "version", "description", "tokens", "stylesheets",
    "theme_color", "required", "directives", "config"]

proc validThemeName*(name: string): bool =
  ## A theme package name: lower-case letters, digits and dashes, starting
  ## with a letter (`isonim-blog-theme-minimal`).
  if name.len == 0 or name[0] notin {'a'..'z'}: return false
  for c in name:
    if c notin {'a'..'z', '0'..'9', '-'}: return false
  true

proc relativeThemePath(value, key: string): string =
  ## A path inside the theme: relative, `/`-separated, no empty, `.` or
  ## `..` segments, no backslashes or control characters.
  if value.len == 0 or value[0] == '/' or value.contains({'\\', '\0'..'\x1f'}):
    fail("theme.toml: " & key & " must be a relative path inside the theme: " & value)
  for part in value.split('/'):
    if part in ["", ".", ".."]:
      fail("theme.toml: " & key & " must be a relative path inside the theme: " & value)
  value

proc stringList(node: JsonNode; key: string): seq[string] =
  if not node.hasKey(key): return
  if node[key].kind != JArray: fail("theme.toml: " & key & " must be a list of strings")
  for item in node[key]:
    if item.kind != JString: fail("theme.toml: " & key & " must be a list of strings")
    if item.getStr in result: fail("theme.toml: " & key & " lists " & item.getStr & " twice")
    result.add item.getStr

proc validKeyPath(path: string): bool =
  ## A dotted key path such as `author.name` or `sys.color.text`.
  if path.len == 0: return false
  for part in path.split('.'):
    if part.len == 0: return false
    for c in part:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: return false
  true

proc parseThemeManifest*(node: JsonNode): ThemeManifest =
  ## Validate a decoded `theme.toml`. Unknown keys are errors: a misspelt
  ## key would otherwise silently do nothing.
  if node.kind != JObject: fail("theme.toml must be a table")
  for key, _ in node:
    if key notin manifestKeys:
      fail("theme.toml: unknown key " & key & " (known: " & manifestKeys.join(", ") & ")")
  for key in ["name", "version", "description", "theme_color"]:
    if node.hasKey(key) and node[key].kind != JString: fail("theme.toml: " & key & " must be a string")
  result.name = node.stringValue("name")
  if not validThemeName(result.name):
    fail("theme.toml: name must be a package name of lower-case letters, digits and dashes: " &
      (if result.name.len == 0: "(missing)" else: result.name))
  result.version = node.stringValue("version")
  result.description = node.stringValue("description")
  for path in node.stringList("tokens"):
    result.tokenFiles.add relativeThemePath(path, "tokens")
  for path in node.stringList("stylesheets"):
    discard relativeThemePath(path, "stylesheets")
    if not path.startsWith("assets/") or not path.endsWith(".css"):
      fail("theme.toml: a stylesheet must be a .css file under assets/: " & path)
    if path == tokenStylesheetPath:
      fail("theme.toml: " & tokenStylesheetPath & " is generated from the tokens; do not list it")
    result.stylesheets.add path
  result.themeColor = node.stringValue("theme_color")
  if result.themeColor.len > 0 and not validKeyPath(result.themeColor):
    fail("theme.toml: theme_color must be a token key: " & result.themeColor)
  if result.themeColor.len > 0 and result.tokenFiles.len == 0:
    fail("theme.toml: theme_color names a token, but the theme declares no tokens")
  for key in node.stringList("required"):
    if not validKeyPath(key): fail("theme.toml: required lists an invalid key: " & key)
    result.required.add key
  for name in node.stringList("directives"):
    validateName(name)
    result.directives.add name
  result.config = if node.hasKey("config"): node["config"].copy else: newJObject()
  if result.config.kind != JObject: fail("theme.toml: config must be a table")
  for key in siteOnlyKeys:
    if result.config.hasKey(key):
      fail("theme.toml: config may not set " & key & ": it describes the site, not the theme")

proc mergeDefaults*(site, defaults: JsonNode): JsonNode =
  ## `site` over `defaults`: a key the site sets wins; tables present in
  ## both are merged key by key, so a site that sets `[feeds] rss` keeps
  ## the theme's other `[feeds]` defaults. Lists and scalars are replaced
  ## whole. Neither argument is modified.
  if site.kind != JObject or defaults.kind != JObject: return site.copy
  result = defaults.copy
  for key, value in site:
    if result.hasKey(key) and result[key].kind == JObject and value.kind == JObject:
      result[key] = mergeDefaults(value, result[key])
    else:
      result[key] = value.copy

proc missingRequired*(config: JsonNode; required: openArray[string]): seq[string] =
  ## The required keys `config` (the merged site.toml) does not set: absent,
  ## or set to an empty string, list or table.
  for key in required:
    var node = config
    var present = true
    for part in key.split('.'):
      if node.kind != JObject or not node.hasKey(part):
        present = false
        break
      node = node[part]
    if present:
      case node.kind
      of JString: present = node.getStr.len > 0
      of JArray, JObject: present = node.len > 0
      of JNull: present = false
      else: discard
    if not present: result.add key

proc requireKeys*(config: JsonNode; theme: ThemeManifest) =
  ## Fail naming every required key the site does not set.
  let missing = missingRequired(config, theme.required)
  if missing.len > 0:
    fail("theme " & theme.name & " requires site.toml " &
      (if missing.len == 1: "key " else: "keys ") & missing.join(", "))

# -- Tokens -------------------------------------------------------------------

proc modeValues(node: JsonNode): tuple[light, dark: JsonNode] =
  ## The `light` and `dark` entries of a token's `$extensions.modes`.
  if node.hasKey("$extensions") and node["$extensions"].kind == JObject and
      node["$extensions"].hasKey("modes") and node["$extensions"]["modes"].kind == JObject:
    for name, value in node["$extensions"]["modes"]:
      case name.toLowerAscii
      of "light": result.light = value
      of "dark": result.dark = value
      else: discard

proc collectLeaves(node: JsonNode; prefix: string;
    leaves: var OrderedTable[string, JsonNode]) =
  ## Every token leaf (an object with `$value`) by dotted path; later
  ## documents replace earlier leaves of the same path, as dtcg merges them.
  if node.kind != JObject: return
  if node.hasKey("$value"):
    leaves[prefix] = node
    return
  for key, child in node:
    if key.startsWith("$"): continue
    collectLeaves(child, if prefix.len == 0: key else: prefix & "." & key, leaves)

proc resolveValue(tokens: TokenSet; key: string; value: JsonNode): string =
  ## A mode value: an alias resolved through the merged set, or a scalar.
  if value.kind == JString and value.getStr.startsWith("{") and value.getStr.endsWith("}"):
    let target = value.getStr[1 ..< value.getStr.len - 1]
    try: result = tokens.resolve(target)
    except TokenError as cause: fail("token " & key & ": " & cause.msg)
  else:
    case value.kind
    of JString: result = value.getStr
    of JInt: result = $value.getInt
    of JFloat: result = $value.getFloat
    else: fail("token " & key & ": a mode value must be a scalar or an alias")

proc themeTokens*(documents: openArray[string]): JsonNode =
  ## Resolve DTCG documents (JSON text, merged in order) to
  ## `{key: {"value": light, "dark": dark?}}`, keys sorted. A token whose
  ## `$value` is a composite (an object or list, such as `typography`) has
  ## no single CSS value and is left out; aliases are followed across every
  ## document, and a dangling or cyclic alias fails naming the token.
  var leaves = initOrderedTable[string, JsonNode]()
  for document in documents:
    var parsed: JsonNode
    try: parsed = parseJson(document)
    except CatchableError as cause: fail("token document: " & cause.msg)
    except:
      # On the JavaScript backend the parser is the host's JSON.parse, whose
      # SyntaxError is a foreign exception rather than a CatchableError.
      fail("token document: " & getCurrentExceptionMsg())
    collectLeaves(parsed, "", leaves)
  let tokens = loadTokensFromStrings(documents)
  var keys: seq[string]
  for key in leaves.keys: keys.add key
  keys.sort()
  result = newJObject()
  for key in keys:
    let leaf = leaves[key]
    if leaf["$value"].kind in {JObject, JArray}: continue
    let (light, dark) = modeValues(leaf)
    var entry = newJObject()
    let base =
      if light.isNil:
        try: tokens.resolve(key)
        except TokenError as cause: fail("token " & key & ": " & cause.msg)
      else: resolveValue(tokens, key, light)
    entry["value"] = %base
    if not dark.isNil:
      let darkValue = resolveValue(tokens, key, dark)
      if darkValue != base: entry["dark"] = %darkValue
    result[key] = entry

proc cssPropertyName*(key: string): string =
  ## `sys.color.text` -> `--sys-color-text`.
  if not validKeyPath(key): fail("token key cannot be a CSS custom property: " & key)
  "--" & key.replace('.', '-')

proc cssValue(key, value: string): string =
  ## Token values are copied into a stylesheet; refuse anything that could
  ## end the declaration or the rule, open a comment or break the markup.
  if value.len == 0 or value.contains({';', '{', '}', '<', '>', '\\', '\0'..'\x1f', '\x7f'}) or
      "/*" in value or "*/" in value:
    fail("token " & key & " has a value that cannot be written to CSS: " & value)
  value

proc tokenStylesheet*(tokens: JsonNode): string =
  ## The custom properties of every token on `:root`, with the dark values
  ## under `prefers-color-scheme: dark`. No script and no class toggle:
  ## the scheme follows the reader's system setting (spec: zero JavaScript).
  result = ":root {\n  color-scheme: light dark;\n"
  var dark = ""
  for key, entry in tokens:
    let name = cssPropertyName(key)
    result.add "  " & name & ": " & cssValue(key, entry["value"].getStr) & ";\n"
    if entry.hasKey("dark"):
      dark.add "    " & name & ": " & cssValue(key, entry["dark"].getStr) & ";\n"
  result.add "}\n"
  if dark.len > 0:
    result.add "@media (prefers-color-scheme: dark) {\n  :root {\n" & dark & "  }\n}\n"

proc themeColors*(tokens: JsonNode; key: string): seq[tuple[color, media: string]] =
  ## The `theme-color` metas for `key`: one per scheme when it has a dark
  ## value, else one for both.
  if key.len == 0: return
  if not tokens.hasKey(key): fail("theme.toml: theme_color names no token: " & key)
  let entry = tokens[key]
  let light = cssValue(key, entry["value"].getStr)
  if entry.hasKey("dark"):
    result.add (light, "(prefers-color-scheme: light)")
    result.add (cssValue(key, entry["dark"].getStr), "(prefers-color-scheme: dark)")
  else:
    result.add (light, "")
