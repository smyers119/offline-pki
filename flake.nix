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
        nixosModules.default = { pkgs, ... }:
          let
            shellInitScript = pkgs.writeShellScriptBin "shell-init" ''
              # Shell version of xterm's resize tool.
              if [ -e /dev/tty ]; then
                old=$(stty -g)
                stty raw -echo min 0 time 5
                printf '\033[18t' > /dev/tty
                IFS=';t' read -r _ rows cols _ < /dev/tty
                stty "$old"
                [ -z "$cols" ] || [ -z "$rows" ] || stty cols "$cols" rows "$rows"
              fi

              # Set date/time
              echo "Current date and time: $(date +"%Y-%m-%d %H:%M:%S")"
              echo -n "New date/time (YYYY-MM-DD HH:MM:SS): "
              read datetime
              [ -z "$datetime" ] || doas date -s "$datetime"
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
            environment.loginShellInit = "${shellInitScript}/bin/shell-init";
            security.doas = {
              enable = true;
              extraRules = [
                { users = [ "pki" ]; cmd = "date"; noPass = true; }
              ];
            };

            # Lustrate the system at every boot
            system.activationScripts.lustrate = ''
              # Lustrate on next boot
              touch /etc/NIXOS_LUSTRATE
            '';
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
          sdcard = {
            # sdcard for Libre Computer Amlogic card. This may not work with other
            # devices, notably Raspberry Pi.
            potato =
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
                      # Do not embed nixpkgs to make the system smaller
                      nixpkgs.flake = {
                        setFlakeRegistry = false;
                        setNixPath = false;
                      };
                    })
                    self.nixosModules.default
                  ];
                };
              in
              image.config.system.build.sdImage;
            # This one is more likely to work with other SBCs.
            generic =
              let
                image = lib.nixosSystem {
                  inherit system;
                  modules = [
                    "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
                    self.nixosModules.default
                  ];
                };
              in
              image.config.system.build.sdImage;
          };
        }) // rec {
          offline-pki = python.pkgs.buildPythonApplication {
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
                        # YubiKey passthrough
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
            pkgs.tio
            pkgs.openssl
            pkgs.yubikey-manager
            (python.withPackages
              (python-pkgs: with python-pkgs; [ offline-pki-editable ]))
          ];
          shellHook = ''
            export OFFLINE_PKI_ROOT=$PWD
            source <(_OFFLINE_PKI_COMPLETE=bash_source offline-pki)
          '';
        };
      });
}
