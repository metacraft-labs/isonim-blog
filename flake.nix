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
          };
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
                  ./config.nims
                  ./isonim_blog.nimble
                  ./LICENSE
                ];
              };
              nativeBuildInputs = [
                pkgs.nim
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
              # programs against the locked inputs, with no network.
              checkPhase = ''
                runHook preCheck
                export HOME="$TMPDIR"
                for suite in test_plumbing test_model_pure test_site_model test_zero_js_default test_cli_build; do
                  nim c -r --out:build/tests/$suite --nimcache:build/nimcache/$suite tests/$suite.nim
                done
                for suite in test_plumbing test_model_pure; do
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
