{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    impermanence.url = "github:nix-community/impermanence";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils, impermanence }:
    let
      lib = nixpkgs.lib;
    in
    flake-utils.lib.eachDefaultSystemPassThrough
      (system: {
        nixosModules.default = { pkgs, ... }:
          let
            resizeScript = pkgs.writeShellScriptBin "resize" ''
              # Shell version of xterm's resize tool.

              if [ -e /dev/tty ]; then
                old=$(stty -g)
                stty raw -echo min 0 time 5
                printf '\033[18t' > /dev/tty
                IFS=';t' read -r _ rows cols _ < /dev/tty
                stty "$old"
                [ -z "$cols" ] || [ -z "$rows" ] || stty cols "$cols" rows "$rows"
              fi
            '';
          in
          {
            system.stateVersion = "24.11";
            networking.hostName = "offline-pki";
            services.pcscd.enable = true;
            environment.systemPackages = [
              pkgs.yubikey-manager
              pkgs.openssl
              self.packages.${pkgs.system}.offline-pki
            ];

            # PKI user and autologin
            users.allowNoPasswordLogin = true;
            users.mutableUsers = false;
            users.users.pki = {
              isNormalUser = true;
              description = "PKI user";
            };
            services.getty.autologinUser = "pki";
            environment.loginShellInit = "${resizeScript}/bin/resize";

            # Impermanence (without any persistence)
            imports = [
              impermanence.nixosModules.impermanence
            ];
            fileSystems."/" = lib.mkForce {
              device = "none";
              fsType = "tmpfs";
              options = [ "defaults" "size=25%" "mode=755" ];
            };
          };
      })
    // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
        pyproject =
          let
            toml = pkgs.lib.importTOML ./pyproject.toml;
          in
          {
            pname = toml.project.name;
            version = toml.project.version;
            build-system = pkgs.lib.map (p: python.pkgs.${p}) toml.build-system.requires;
            dependencies = pkgs.lib.map (p: python.pkgs.${p}) toml.project.dependencies;
            scripts = toml.project.scripts;
          };
        python = pkgs.python3.override {
          self = python;
          packageOverrides = pyfinal: pyprev: {
            yubikey-manager = pkgs.yubikey-manager;
            offline-pki-editable = pyfinal.mkPythonEditablePackage {
              inherit (pyproject) pname version build-system dependencies scripts;
              root = "$OFFLINE_PKI_ROOT/src";
            };
          };
        };
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
                    # No need for firmwares (enabled by sd-image.nix)
                    hardware.enableRedistributableFirmware = lib.mkForce false;
                  })
                  self.nixosModules.default
                ];
              };
            in
            image.config.system.build.sdImage;
        }) // rec {
          offline-pki = pkgs.python3Packages.buildPythonApplication {
            inherit (pyproject) pname version build-system dependencies;
            pyproject = true;
            src = ./.;
            nativeBuildInputs = [
              pkgs.installShellFiles
            ];

            postInstall = ''
              installShellCompletion --cmd offline-pki \
                --bash <(_OFFLINE_PKI_COMPLETE=bash_source "$out/bin/offline-pki") \
                --zsh  <(_OFFLINE_PKI_COMPLETE=zsh_source  "$out/bin/offline-pki") \
                --fish <(_OFFLINE_PKI_COMPLETE=fish_source "$out/bin/offline-pki") \
            '';
          };
          default = offline-pki;

          # QEMU image for development (and only for that!)
          qemu =
            let
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
                    users.users.root.password = ".Linux.";
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
            pkgs.yubikey-manager
            (python.withPackages
              (python-pkgs: with python-pkgs; [ offline-pki-editable ]))
          ];
          shellHook = ''
            export OFFLINE_PKI_ROOT=$PWD
          '';
        };
      });
}
