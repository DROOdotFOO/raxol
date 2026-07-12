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
              ]);

            shellHook = ''
              export MIX_ENV="''${MIX_ENV:-dev}"
              echo "raxol dev shell: $(elixir --version | tail -n1)"
              echo "  first run: mix deps.get"
              echo "  tests:     MIX_ENV=test mix test --exclude slow --exclude integration --exclude docker"
            '';
          };
        }
      );

      # Follow-up (needs a machine with nix): packages.default via
      # beam.packages.erlang_27.mixRelease + fetchMixDeps (fill the fixed-output
      # deps hash on the first build), and apps.default so `nix run` launches the
      # playground -- which also needs a releases/0 entrypoint in mix.exs.
      # Tracked in ROADMAP under "Install funnel".
    };
}
