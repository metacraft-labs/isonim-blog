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
    inputs@{ flake-parts, nixos-modules, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ nixos-modules.modules.flake.git-hooks ];
      mcl.gitHooks.editorconfigExcludes = [ "^LICENSE$" ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
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
            ISONIM_BLOG_ISONIM_SRC = "${inputs.isonim}";
            ISONIM_BLOG_NIM_EVERYWHERE_SRC = "${inputs.nim-everywhere}";
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
                  ./config.nims
                  ./isonim_blog.nimble
                  ./LICENSE
                ];
              };
              nativeBuildInputs = [
                pkgs.nim
                pkgs.nodejs
              ];
              ISONIM_BLOG_PINNED_SOURCES = "1";
              buildPhase = ''
                runHook preBuild
                nim c -d:release --out:build/bin/isonim-blog --nimcache:build/nimcache/cli src/isonim_blog_cli.nim
                runHook postBuild
              '';
              doCheck = true;
              checkPhase = ''
                runHook preCheck
                nim c -r --out:build/tests/test_plumbing --nimcache:build/nimcache/test-c tests/test_plumbing.nim
                nim js -d:nodejs --out:build/tests/test_plumbing.js --nimcache:build/nimcache/test-js tests/test_plumbing.nim
                node build/tests/test_plumbing.js
                build/bin/isonim-blog --version
                runHook postCheck
              '';
              installPhase = ''
                runHook preInstall
                install -Dm755 build/bin/isonim-blog "$out/bin/isonim-blog"
                install -Dm644 LICENSE "$out/share/licenses/isonim-blog/LICENSE"
                runHook postInstall
              '';
              meta = {
                description = "Static blogs with IsoNim (bootstrap CLI)";
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
          formatter = pkgs.nixfmt;
        };
    };
}
