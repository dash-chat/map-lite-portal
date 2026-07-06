{
  description = "Captive portal webapp + provisioning tooling for MikroTik mAP lite";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, system, ... }:
        let
          # MikroTik's Netinstall for Linux — a prebuilt, statically-linked
          # 32-bit binary, so it runs on NixOS as-is (no FHS/patchelf needed).
          # Update version + hash together; get the hash with:
          #   nix hash file --sri netinstall-<ver>.tar.gz
          netinstall-cli = pkgs.stdenvNoCC.mkDerivation {
            pname = "mikrotik-netinstall-cli";
            version = "7.23.1";
            src = pkgs.fetchurl {
              url = "https://download.mikrotik.com/routeros/7.23.1/netinstall-7.23.1.tar.gz";
              hash = "sha256-tTe0SE5YqgfODO6xGoCDP3YZ9BkGh9muYmMzcSiss4k=";
            };
            sourceRoot = ".";
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true; # leave the vendor static binary untouched
            installPhase = ''
              runHook preInstall
              install -Dm755 netinstall-cli $out/bin/netinstall-cli
              runHook postInstall
            '';
            meta.platforms = [ "x86_64-linux" "i686-linux" ];
          };
        in
        {
          devShells.default = pkgs.mkShell {
            packages =
              (with pkgs; [
                just
                openssh
                sshpass
                nodejs_22
                pnpm
              ])
              # netinstall-cli is a Linux/x86 binary; only offer it there
              ++ pkgs.lib.optional (system == "x86_64-linux") netinstall-cli;
          };
        };
    };
}
