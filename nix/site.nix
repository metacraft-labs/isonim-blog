# `lib.<system>.buildSite { src, theme ? null, drafts ? false, url ? null, now ? null }`:
# a site as a sandboxed, byte-reproducible derivation.
#
# It wraps IsoNim's shared static-site builder (`nix/static-site.nix` of the
# pinned IsoNim input), which compiles one exporter program against the pinned
# IsoNim and runs it in the sandbox with SOURCE_DATE_EPOCH set. Here the
# exporter is the site's generated layout program:
#
# 1. `prepared` copies only `site.toml`, the OpenGraph template `og.svg.nim`
#    and the declared site directories
#    (nothing else in the source can reach the build) and generates the
#    layout program with the same `isonim-blog-prepare` the CLI uses.
# 2. The shared builder performs the single native compile. Its own run of
#    the exporter is a no-op (`--prepare-only`); the content export runs in
#    its standard postBuild hook, after the optional islands bundle compile.
#
# `src` must carry a positive `lastModified` (a flake input, `self`, or
# `{ outPath; lastModified; rev ? ...; }`). For a flake, `self.lastModified` is
# the time of the last commit (of a dirty tree too), so it names the source,
# not the machine or the moment of the build. It is SOURCE_DATE_EPOCH, and,
# unless `now` is given, the build clock: a post dated after it (as a civil
# date in site.toml's timezone) is future and left out. `now` overrides the
# clock only, as `--now` does: an integer (seconds since the Unix epoch), or
# a string `--now` accepts: an RFC 3339 date-time with an offset
# ("2026-11-01T00:00:00Z") or "@<seconds>". A scheduled publish therefore
# needs a build after the post's date: a new commit, or a scheduled impure
# build passing `now = builtins.currentTime`.
#
# A missing or zero `lastModified` means the source time is unknown. As the
# clock it would silently build the blog of 1970, with every post left out,
# so evaluation fails instead, unless `now` is given; `now` must then be an
# integer, because it dates the output too.
#
# `theme` defaults to the theme site.toml names: a path relative to `src`, or
# the package name of a theme isonim-blog ships (`isonim-blog-theme-minimal`).
# A theme package from elsewhere is a flake input passed as `theme`.
{
  pkgs,
  inputs,
  self,
  system,
}:
{
  src,
  theme ? null,
  drafts ? false,
  url ? null,
  now ? null,
}:
let
  lib = pkgs.lib;
  # The source time (SOURCE_DATE_EPOCH, and the default build clock); 0 when
  # it is unknown. See the header for why an unknown one is refused.
  sourceTime = if src ? lastModified && builtins.isInt src.lastModified then src.lastModified else 0;
  sourceDateEpoch =
    if sourceTime > 0 then
      sourceTime
    else if now == null then
      throw "buildSite: src carries no source time (lastModified is ${
        if src ? lastModified then toString src.lastModified else "absent"
      }), and a build clock of 1970 would leave every post out as future; pass a src with a positive lastModified (a flake input, self, or { outPath; lastModified; }), or pass now explicitly"
    else if builtins.isInt now then
      now
    else
      throw "buildSite: src carries no source time, so now also dates the output and must be an integer (seconds since the Unix epoch), not ${builtins.toJSON now}";
  config = builtins.fromTOML (builtins.readFile "${src}/site.toml");
  # site.toml names its theme by path (relative to the site) or by package
  # name. The themes isonim-blog ships resolve by name here, as they do for
  # the CLI; any other package is passed in as `theme` (a flake input), and
  # the build checks that its theme.toml names the package site.toml asks for.
  configuredTheme = config.theme or "";
  shippedPrefix = "isonim-blog-theme-";
  shippedTheme =
    name:
    let
      dir = "${self}/themes/${lib.removePrefix shippedPrefix name}";
    in
    if
      lib.hasPrefix shippedPrefix name
      && builtins.pathExists "${dir}/theme.toml"
      && (builtins.fromTOML (builtins.readFile "${dir}/theme.toml")).name or "" == name
    then
      dir
    else
      null;
  themeSrc =
    if theme != null then
      "${theme}"
    else if configuredTheme == "" then
      null
    else if lib.hasPrefix "/" configuredTheme then
      throw "buildSite: site.toml names the absolute theme path ${configuredTheme}, which the sandbox cannot read; name it relative to the site or pass theme = <path or flake input>"
    else if lib.hasInfix "/" configuredTheme || lib.hasPrefix "." configuredTheme then
      "${src}/${configuredTheme}"
    else if shippedTheme configuredTheme != null then
      shippedTheme configuredTheme
    else
      throw "buildSite: site.toml names the theme package ${configuredTheme}, which isonim-blog does not ship; pass it as buildSite { theme = inputs.<theme>; }";
  islands = ((config.output or { }).scripts or "none") == "islands";
  cli = self.packages.${system}.isonim-blog;
  python = "${pkgs.python3}/bin/python3";
  prepared = pkgs.runCommand "isonim-blog-prepared" { nativeBuildInputs = [ cli ]; } ''
    mkdir -p "$out"
    cp ${src}/site.toml "$out/site.toml"
    if [ -f ${src}/og.svg.nim ]; then cp ${src}/og.svg.nim "$out/og.svg.nim"; fi
    for dir in posts drafts pages collections layouts includes data assets static; do
      if [ -d ${src}/"$dir" ]; then cp -R ${src}/"$dir" "$out/"; fi
    done
    chmod -R u+w "$out"
    isonim-blog-prepare "$out" "$out/.program" ${lib.optionalString (themeSrc != null) themeSrc}
  '';
  buildStaticSite = import "${inputs.isonim}/nix/static-site.nix" {
    inherit (pkgs) lib stdenv nim;
    isonimSrc = inputs.isonim;
    # The builder puts IsoNim's platform sources on the exporter's path too.
    nimEverywhereSrc = inputs.nim-everywhere;
  };
  exportArgs =
    lib.optionals (themeSrc != null) [
      "--theme"
      themeSrc
    ]
    ++ lib.optional drafts "--drafts"
    ++ [
      "--now"
      (
        if now == null then
          "@${toString sourceDateEpoch}"
        else if builtins.isInt now then
          "@${toString now}"
        else
          now
      )
    ]
    ++ lib.optionals (url != null) [
      "--url"
      url
    ];
  nimPaths = [
    "${self}/src"
    "${inputs.nim-everywhere}/src"
  ];
in
buildStaticSite {
  name = "isonim-blog-site";
  src = prepared;
  exporter = ".program/site_program.nim";
  inherit nimPaths sourceDateEpoch;
  exporterArgs = [ "--prepare-only" ];
  nativeBuildInputs = [ cli ];
  env = {
    ISONIM_BLOG_PYTHON = python;
    PYTHONTZPATH = "${pkgs.tzdata}/share/zoneinfo";
    ISONIM_BLOG_VIPS = lib.getExe' pkgs.vips "vips";
    ISONIM_BLOG_RESVG = lib.getExe pkgs.resvg;
    ISONIM_BLOG_OG_FONTS = "${pkgs.dejavu_fonts}/share/fonts/truetype";
    ISONIM_BLOG_REVISION = self.rev or self.dirtyRev or "unknown";
    postBuild = ''
      bundle_args=()
      ${lib.optionalString islands ''
        "$TMPDIR/static-site-exporter" --islands > "$TMPDIR/islands.json"
        if [ "$(${python} -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$TMPDIR/islands.json")" != 0 ]; then
          isonim-blog-prepare --bundle .program "$TMPDIR/islands.json"
          nim js --hints:off -d:release --nimcache:"$TMPDIR/nimcache-js" --out:"$TMPDIR/islands.js" \
            --path:${inputs.isonim}/src ${
              lib.concatMapStringsSep " " (p: "--path:${p}") nimPaths
            } .program/islands.nim
          bundle_args=(--bundle "$TMPDIR/islands.js")
        fi
      ''}
      "$TMPDIR/static-site-exporter" public --root . ${lib.escapeShellArgs exportArgs} "''${bundle_args[@]}"
    '';
  }
  # Without a commit the build records content hashes of what it read.
  // lib.optionalAttrs (src ? rev) { ISONIM_BLOG_SOURCE_REVISION = src.rev; }
  // lib.optionalAttrs (theme != null && theme ? rev) { ISONIM_BLOG_THEME_REVISION = theme.rev; };
}
