{
  description = "Raxol: multi-surface application runtime for Elixir (one TEA module, four render targets)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          # Match .tool-versions: OTP 29 / Elixir 1.20 (also the memory-regression
          # CI toolchain). Use the beam package set; the bare elixir_1_20/erlang_29
          # top-level attrs are deprecated.
          beam = pkgs.beam.packages.erlang_29;
        in
        {
          default = pkgs.mkShell {
            packages =
              [
                beam.elixir_1_20
                beam.erlang
              ]
              # termbox2 NIF build toolchain (vendored under packages/raxol_terminal)
              ++ (with pkgs; [
                gcc
                gnumake
                cmake
                pkg-config
              ])
              # raxol_speech optional extras (Whisper STT / TTS)
              ++ (with pkgs; [
                sox
                espeak-ng
                ffmpeg
              ])
              # assets + misc (nodejs = current maintained LTS; _20 is EOL/insecure)
              ++ (with pkgs; [
                nodejs
                git
                openssl
                ncurses
              ])
              # `script` allocates a controlling pseudo-terminal so the termbox2
              # NIF suite runs under a real tty on Linux self-hosted runners.
              # util-linux is Linux-only, so guard it for the Darwin systems.
              ++ nixpkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.util-linux ];

            shellHook = ''
              export MIX_ENV="''${MIX_ENV:-dev}"
              echo "raxol dev shell: $(elixir --version | tail -n1)"
              echo "  first run: mix deps.get"
              echo "  tests:     MIX_ENV=test mix test --exclude slow --exclude integration --exclude docker"
            '';
          };
        }
      );

      # Self-hosted GitHub Actions runner for the FATE bench, as a reusable
      # NixOS module. A host imports it and sets the token/key files (via
      # agenix); see docs/testing/FATE_BENCH.md for a full host example. Shipped
      # as a module rather than a nixosConfigurations entry so the hosted flake
      # check stays green without this repo carrying a machine's hardware config.
      nixosModules.githubRunner =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.raxol.ci.githubRunner;
        in
        {
          options.raxol.ci.githubRunner = {
            enable =
              lib.mkEnableOption "the Raxol self-hosted GitHub Actions runner";

            repoUrl = lib.mkOption {
              type = lib.types.str;
              default = "https://github.com/DROOdotFOO/raxol";
              description = "Repository the runner registers against.";
            };

            tokenFile = lib.mkOption {
              type = lib.types.path;
              description = ''
                File holding a GitHub runner registration token or a PAT with
                repo scope. Keep it out of the Nix store and git; provision it
                with agenix or sops-nix.
              '';
            };

            tailscaleAuthKeyFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = ''
                Optional Tailscale auth key file for headless mesh join. Leave
                null to join manually with `tailscale up`.
              '';
            };

            extraLabels = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Extra runner labels beyond raxol + the arch label.";
            };
          };

          config = lib.mkIf cfg.enable {
            services.github-runners.raxol = {
              enable = true;
              url = cfg.repoUrl;
              tokenFile = cfg.tokenFile;
              # Ephemeral: a clean workspace per job, no persisted foothold. A
              # PAT tokenFile re-registers automatically after each job.
              ephemeral = true;
              replace = true;
              extraLabels =
                [
                  "raxol"
                  "nix"
                  pkgs.stdenv.hostPlatform.system
                ]
                ++ cfg.extraLabels;
              extraPackages = with pkgs; [
                util-linux
                ncurses
                gnumake
                gcc
                git
                openssl
              ];
            };

            services.tailscale = {
              enable = true;
              authKeyFile = cfg.tailscaleAuthKeyFile;
            };

            # The workflow drives the toolchain through `nix develop`, so flakes
            # must be available system-wide.
            nix.settings.experimental-features = [
              "nix-command"
              "flakes"
            ];
          };
        };

      # Follow-up (needs a machine with nix): packages.default via
      # beam.packages.erlang_27.mixRelease + fetchMixDeps (fill the fixed-output
      # deps hash on the first build), and apps.default so `nix run` launches the
      # playground -- which also needs a releases/0 entrypoint in mix.exs.
      # Tracked in ROADMAP under "Install funnel".
    };
}
