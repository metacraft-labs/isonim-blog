# `lib.<system>.buildSite { src, theme ? null, drafts ? false, url ? null }`:
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
# `src` must carry `lastModified` (a flake input, `self`, or
# `{ outPath; lastModified; rev ? ...; }`). `theme` defaults to the path named
# by `theme` in site.toml, relative to `src`.
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
}:
let
  lib = pkgs.lib;
  sourceDateEpoch =
    if src ? lastModified then
      src.lastModified
    else
      throw "buildSite: src must carry lastModified (use a flake input or { outPath; lastModified; })";
  config = builtins.fromTOML (builtins.readFile "${src}/site.toml");
  themeSrc =
    if theme != null then
      "${theme}"
    else if (config.theme or "") != "" then
      "${src}/${config.theme}"
    else
      null;
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
