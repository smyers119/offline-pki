{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    let
      lib = nixpkgs.lib;
    in
    flake-utils.lib.eachDefaultSystemPassThrough
      (system: {
        # NixOS module for PKI
        nixosModules.default = { pkgs, ... }: {
          system.stateVersion = "24.11";
          networking.hostName = "offline-pki";
          services.pcscd.enable = true;
          environment.systemPackages = [
            pkgs.yubikey-manager
            pkgs.openssl
            self.packages.${pkgs.system}.pki
          ];
        };
      })
    // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
        runtimeInputs = [
          (pkgs.python3.withPackages
            (python-pkgs: with python-pkgs;
            [
              click
              cryptography
              ipython
              pkgs.yubikey-manager
            ]))
        ];
      in
      {
        packages = (lib.optionalAttrs (system == "aarch64-linux") {
          # sdcard for Libre Computer Amlogic card
          sdcard =
            let
              image = lib.nixosSystem {
                inherit system;
                modules = [
                  "${nixpkgs}/nixos/modules/profiles/minimal.nix"
                  "${nixpkgs}/nixos/modules/installer/sd-card/sd-image.nix"
                  ({ config, ... }: {
                    # This is a reduced version of sd-image-aarch64
                    boot.loader.grub.enable = false;
                    boot.loader.generic-extlinux-compatible.enable = true;
                    boot.consoleLogLevel = lib.mkDefault 7;
                    sdImage = {
                      populateFirmwareCommands = "";
                      populateRootCommands = ''
                        mkdir -p ./files/boot
                        ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
                          -c ${config.system.build.toplevel} \
                          -d ./files/boot
                      '';
                    };
                    # For Amlogic boards, the console is on ttyAML0.
                    boot.kernelParams = [ "console=ttyAML0,115200n8" "console=ttyS0,115200n8" "console=tty0" ];
                  })
                  {
                    # Create a PKI user with autologin
                    users.users.pki = {
                      isNormalUser = true;
                      description = "PKI user";
                    };
                    services.getty.autologinUser = "pki";
                  }
                  self.nixosModules.default
                ];
              };
            in
            image.config.system.build.sdImage;
        }) // rec {
          pki = pkgs.stdenvNoCC.mkDerivation {
            name = "offline-pki";
            src = ./.;
            nativeBuildInputs = [
              pkgs.installShellFiles
              pkgs.makeWrapper
            ];
            buildInputs = runtimeInputs;
            phases = [ "installPhase" ];
            installPhase = ''
              install -D ${./scripts/pki} $out/bin/pki
              patchShebangs --build $out

              installShellCompletion --cmd pki \
                --bash <(_PKI_COMPLETE=bash_source "$out/bin/pki") \
                --zsh  <(_PKI_COMPLETE=zsh_source  "$out/bin/pki") \
                --fish <(_PKI_COMPLETE=fish_source "$out/bin/pki") \
            '';
          };
          default = pki;

          # QEMU image for development (and only for that!)
          qemu =
            let
              resizeScript = pkgs.writeShellScriptBin "resize" ./scripts/resize;
              image = lib.nixosSystem {
                inherit system;
                modules = [
                  "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
                  "${nixpkgs}/nixos/modules/profiles/qemu-guest.nix"
                  "${nixpkgs}/nixos/modules/profiles/minimal.nix"
                  ({ pkgs, ... }: {
                    virtualisation = {
                      graphics = false;
                      qemu.options = [
                        "-serial mon:stdio"
                        "-usb"
                      ] ++ (
                        # Yubikey passthrough
                        lib.map
                          (id: "-device usb-host,vendorid=0x1050,productid=0x040${toString id}")
                          (lib.range 1 8)
                      );
                    };
                    services.getty.autologinUser = "pki";
                    users.users.root.password = ".Linux.";
                    environment.loginShellInit = "${resizeScript}/bin/resize";
                  })
                  self.nixosModules.default
                ];
              };
            in
            image.config.system.build.vm;
        };

        # Development shell
        devShells.default = pkgs.mkShell {
          name = "offline-pki";
          nativeBuildInputs = [
            pkgs.openssl
          ] ++ runtimeInputs;
        };
      });
}
