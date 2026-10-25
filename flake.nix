{
  description = "isonim-blog — static blogs with IsoNim";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
    isonim = {
      url = "github:metacraft-labs/isonim/agents";
      flake = false;
    };
    nim-everywhere = {
      url = "github:metacraft-labs/nim-everywhere/agents";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixos-modules,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ nixos-modules.modules.flake.git-hooks ];
      mcl.gitHooks.editorconfigExcludes = [ "^LICENSE$" ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      flake.lib = builtins.listToAttrs (
        map
          (system: {
            name = system;
            value.buildSite = import ./nix/site.nix {
              pkgs = inputs.nixpkgs.legacyPackages.${system};
              inherit inputs self system;
            };
          })
          [
            "x86_64-linux"
            "aarch64-linux"
            "x86_64-darwin"
            "aarch64-darwin"
          ]
      );
      perSystem =
        {
          pkgs,
          config,
          system,
          ...
        }:
        let
          # The Nimble manifest owns the version for the library and package.
          version = builtins.head (
            builtins.match ''.*version *= *"([^"]+)".*'' (builtins.readFile ./isonim_blog.nimble)
          );
          sources = {
            ISONIM_BLOG_SRC = "${self}";
            ISONIM_BLOG_ISONIM_SRC = "${inputs.isonim}";
            ISONIM_BLOG_NIM_EVERYWHERE_SRC = "${inputs.nim-everywhere}";
            ISONIM_BLOG_PYTHON = "${pkgs.python3}/bin/python3";
            PYTHONTZPATH = "${pkgs.tzdata}/share/zoneinfo";
            # Image variants (libvips) and OpenGraph images (resvg with the
            # bundled DejaVu fonts), injected by path.
            ISONIM_BLOG_VIPS = pkgs.lib.getExe' pkgs.vips "vips";
            ISONIM_BLOG_RESVG = pkgs.lib.getExe pkgs.resvg;
            ISONIM_BLOG_OG_FONTS = "${pkgs.dejavu_fonts}/share/fonts/truetype";
            # `check --external` requests external links with curl.
            ISONIM_BLOG_CURL = pkgs.lib.getExe pkgs.curl;
          };
          # axe-core, pinned, for the browser half of the theme conformance
          # kit (`just test-theme`, tests/theme_kit_browser.mjs). nixpkgs does
          # not package it, so the npm registry tarball is a fixed-output
          # fetch pinned by the registry's own sha512 integrity, and its
          # prebuilt axe.min.js (with its licence, MPL-2.0) is all the kit
          # injects. To move the pin, change the version in both places and
          # the hash to the new tarball's integrity (`npm view axe-core@<v> dist`).
          axeCoreTarball = pkgs.fetchurl {
            url = "https://registry.npmjs.org/axe-core/-/axe-core-4.13.0.tgz";
            hash = "sha512-UzGt8zg7Ny8djbYMhxl2zuEevVa7r2gJjYY5Lwr1xM7+XU2nd6CkIWFTVcCIbAP63vSz71NaVyyuSk9lHKcy0A==";
          };
          axeCore = pkgs.runCommand "isonim-blog-axe-core-4.13.0" { } ''
            mkdir -p $out
            tar -xzf ${axeCoreTarball} -C $out --strip-components=1 \
              package/axe.min.js package/LICENSE package/package.json
          '';
          cli = pkgs.stdenv.mkDerivation (
            sources
            // {
              pname = "isonim-blog";
              inherit version;
              src = pkgs.lib.fileset.toSource {
                root = ./.;
                fileset = pkgs.lib.fileset.unions [
                  ./src
                  ./tests
                  ./examples
                  ./themes
                  ./config.nims
                  ./isonim_blog.nimble
                  ./LICENSE
                ];
              };
              nativeBuildInputs = [
                pkgs.nim
                # test_theme_format reads the theme's Nimble package (`nimble dump`).
                pkgs.nimble
                pkgs.nodejs
                pkgs.python3
                pkgs.makeWrapper
              ];
              ISONIM_BLOG_PINNED_SOURCES = "1";
              buildPhase = ''
                runHook preBuild
                nim c -d:release --out:build/bin/isonim-blog --nimcache:build/nimcache/cli src/isonim_blog_cli.nim
                nim c -d:release --out:build/bin/isonim-blog-prepare --nimcache:build/nimcache/prepare src/isonim_blog_prepare.nim
                runHook postBuild
              '';
              doCheck = true;
              # Every suite runs here too: the site suites compile real site
              # programs against the locked inputs, with no network. Two suites
              # cannot: test_cli_scaffold and test_deploy_recipe build a generated
              # site flake with `nix build`, which needs the Nix daemon; `just test`
              # runs them.
              checkPhase = ''
                runHook preCheck
                export HOME="$TMPDIR"
                for suite in test_plumbing test_model_pure test_site_model test_zero_js_default test_cli_build test_taxonomies test_feeds test_static_images test_static_ogimage test_check test_serve_reload test_theme_format test_theme_override test_theme_kit; do
                  nim c -r --out:build/tests/$suite --nimcache:build/nimcache/$suite tests/$suite.nim
                done
                for suite in test_plumbing test_model_pure test_theme_format; do
                  nim js -d:nodejs --out:build/tests/$suite.js --nimcache:build/nimcache/$suite-js tests/$suite.nim
                  node build/tests/$suite.js
                done
                build/bin/isonim-blog --version
                runHook postCheck
              '';
              installPhase = ''
                runHook preInstall
                install -Dm755 build/bin/isonim-blog "$out/bin/isonim-blog"
                install -Dm755 build/bin/isonim-blog-prepare "$out/bin/isonim-blog-prepare"
                wrapProgram "$out/bin/isonim-blog" \
                  --set ISONIM_BLOG_SRC ${self} \
                  --set ISONIM_BLOG_ISONIM_SRC ${inputs.isonim} \
                  --set ISONIM_BLOG_NIM_EVERYWHERE_SRC ${inputs.nim-everywhere} \
                  --set ISONIM_BLOG_PYTHON ${pkgs.python3}/bin/python3 \
                  --set-default ISONIM_BLOG_REVISION ${self.rev or self.dirtyRev or "unknown"} \
                  --set-default PYTHONTZPATH ${pkgs.tzdata}/share/zoneinfo \
                  --set ISONIM_BLOG_VIPS ${sources.ISONIM_BLOG_VIPS} \
                  --set ISONIM_BLOG_RESVG ${sources.ISONIM_BLOG_RESVG} \
                  --set ISONIM_BLOG_OG_FONTS ${sources.ISONIM_BLOG_OG_FONTS} \
                  --set ISONIM_BLOG_CURL ${sources.ISONIM_BLOG_CURL} \
                  --prefix PATH : ${
                    pkgs.lib.makeBinPath [
                      pkgs.nim
                      pkgs.stdenv.cc
                    ]
                  }
                install -Dm644 LICENSE "$out/share/licenses/isonim-blog/LICENSE"
                runHook postInstall
              '';
              meta = {
                description = "Static blogs with IsoNim";
                license = pkgs.lib.licenses.asl20;
                mainProgram = "isonim-blog";
                platforms = pkgs.lib.platforms.unix;
              };
            }
          );
        in
        {
          pre-commit.settings.hooks = {
            # Prettier refuses explicit symlinks; their AGENTS.md target is checked.
            prettier.excludes = [
              "^\\.agents/AGENTS\\.md$"
              "^\\.github/copilot-instructions\\.md$"
            ];
            lint = {
              enable = true;
              name = "just lint";
              entry = "just lint";
              language = "system";
              pass_filenames = false;
              always_run = true;
            };
            check-license = {
              enable = true;
              name = "Check Apache-2.0 license presence";
              entry = "bash scripts/check-license.sh";
              language = "system";
              pass_filenames = false;
              always_run = true;
            };
          };
          devShells.default = pkgs.mkShell (
            sources
            // {
              # The theme conformance kit's browser checks: Playwright's
              # Chromium from nixpkgs (never downloaded) and the pinned axe-core.
              PLAYWRIGHT_CORE_PATH = "${pkgs.playwright-driver}";
              PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
              PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
              ISONIM_BLOG_AXE = "${axeCore}";
              inputsFrom = [ config.pre-commit.devShell ];
              packages = with pkgs; [
                nim
                nimble
                nodejs
                just
                git
                nixfmt
                uv
                python3
                shellcheck
                shfmt
                actionlint
                nixos-modules.inputs.reprobuild.packages.${system}.default
              ];
              shellHook = config.mcl.gitHooks.installationScript;
            }
          );
          packages.default = cli;
          packages.isonim-blog = cli;
          checks.cli = cli;
          # The generic fixture as a sandboxed, reproducible site build.
          checks.example-basic = self.lib.${system}.buildSite {
            src = {
              outPath = ./examples/basic;
              lastModified = self.lastModified or 1;
            }
            // pkgs.lib.optionalAttrs (self ? rev) { inherit (self) rev; };
          };
          # The shipped theme, found by its package name as a new site names it
          # (`theme = "isonim-blog-theme-minimal"`), builds the theme
          # conformance fixture in the sandbox: its token and theme
          # stylesheets are linked, theme-color follows both schemes, and
          # the output is byte-reproducible (`--rebuild`).
          checks.theme-minimal =
            let
              src = pkgs.runCommand "isonim-blog-theme-conformance-src" { } ''
                cp -R ${./tests/fixtures/theme-conformance} "$out"
                chmod -R u+w "$out"
                { echo 'theme = "isonim-blog-theme-minimal"'; cat ${./tests/fixtures/theme-conformance/site.toml}; } > "$out/site.toml"
              '';
              site = self.lib.${system}.buildSite {
                src = {
                  outPath = src;
                  lastModified = 1735689600;
                };
              };
            in
            pkgs.runCommand "isonim-blog-theme-minimal-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
              set -euo pipefail
              page=${site}/posts/every-prose-feature/index.html
              tokens="$(jq -r '."assets/theme-tokens.css"' ${site}/asset-manifest.json)"
              css="$(jq -r '."assets/minimal.css"' ${site}/asset-manifest.json)"
              grep -qF "<link rel=\"stylesheet\" href=\"/$tokens\"><link rel=\"stylesheet\" href=\"/$css\">" "$page"
              cmp ${./themes/minimal/assets/minimal.css} "${site}/$css"
              grep -q -- '--sys-color-surface: #ffffff;' "${site}/$tokens"
              grep -q -- '--sys-color-surface: #111316;' "${site}/$tokens"
              grep -qF '<meta name="theme-color" content="#111316" media="(prefers-color-scheme: dark)" />' "$page"
              grep -q 'class="skip-link"' "$page"
              grep -q '<label><input type="checkbox" disabled checked> Write the content</label>' "$page"
              test "$(jq -r '.components[1].name' ${site}/build.json)" = theme
              case "$(jq -r '.components[1].revision' ${site}/build.json)" in sha256-*) ;; *) exit 1 ;; esac
              if grep -rl --include='*.html' '<script src=' ${site}; then exit 1; fi
              test -z "$(find ${site} -name '*.js')"
              mkdir "$out"
            '';
          # The wrapper's arguments reach the build: a theme's assets and
          # identity, drafts with noindex, and the canonical origin.
          checks.build-site-contract =
            let
              site = self.lib.${system}.buildSite {
                src = {
                  outPath = ./examples/basic;
                  lastModified = 1704067200;
                };
                theme = ./tests/fixtures/theme;
                drafts = true;
                url = "https://preview.example";
              };
            in
            pkgs.runCommand "isonim-blog-build-site-contract" { nativeBuildInputs = [ pkgs.jq ]; } ''
              set -euo pipefail
              grep -q 'name="robots" content="noindex"' ${site}/posts/work-in-progress/index.html
              grep -q 'class="draft-banner"' ${site}/posts/work-in-progress/index.html
              grep -q 'https://preview.example/posts/first/' ${site}/posts/first/index.html
              test ! -e ${site}/posts/future
              test ! -e ${site}/unrelated
              # A drafts build lists the draft but never feeds or maps it.
              grep -q '/posts/work-in-progress/' ${site}/tags/nim/index.html
              test -s ${site}/feed.xml && test -s ${site}/atom.xml && test -s ${site}/tags/nim/atom.xml
              # (`! grep` would not stop a `set -e` script.)
              if grep -q 'work-in-progress' ${site}/feed.xml ${site}/atom.xml ${site}/tags/nim/atom.xml ${site}/sitemap.xml; then
                exit 1
              fi
              grep -q 'https://preview.example/posts/second/</loc><lastmod>2020-06-01</lastmod>' ${site}/sitemap.xml
              css="$(jq -r '."assets/theme.css"' ${site}/asset-manifest.json)"
              cmp ${./tests/fixtures/theme/assets/theme.css} "${site}/$css"
              case "$(jq -r '.components[1].revision' ${site}/build.json)" in sha256-*) ;; *) exit 1 ;; esac
              test "$(jq -r '.sourceDateEpoch' ${site}/build.json)" = 1704067200
              mkdir "$out"
            '';
          # A declared island becomes exactly one hashed bundle, loaded by the
          # page and named by its CSP, compiled with `nim js` in the sandbox.
          checks.build-site-islands =
            let
              site = self.lib.${system}.buildSite {
                src = {
                  outPath = ./tests/fixtures/islands-site;
                  lastModified = 1704067200;
                };
              };
            in
            pkgs.runCommand "isonim-blog-build-site-islands" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
              set -euo pipefail
              bundles=("${site}"/assets/islands.*.js)
              test "''${#bundles[@]}" = 1
              test "$(find ${site} -name '*.js' | wc -l)" = 1
              name="''${bundles[0]#${site}}"
              grep -qF "<script src=\"$name\" defer>" ${site}/index.html
              grep -qF "script-src $name" ${site}/_headers
              grep -q 'data-hk="counter-1"' ${site}/index.html
              node --check "''${bundles[0]}"
              mkdir "$out"
            '';
          formatter = pkgs.nixfmt;
        };
    };
}
