{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    {
      # NixOS module for PKI
      nixosModules.default = { pkgs, ... }: {
        system.stateVersion = "24.11";
        networking.hostName = "offline-pki";
        users.users.pki = {
          isNormalUser = true;
          description = "PKI user";
        };
        services.pcscd.enable = true;
        environment.systemPackages = [
          pkgs.yubikey-manager
          self.packages.${pkgs.system}.pkiScript
        ];
      };

      # sdcard for Libre Computer or Raspberry Pi
      packages.aarch64-linux.sdcard =
        let
          image = nixpkgs.lib.nixosSystem {
            system = "aarch64-linux";
            modules = [
              "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
              "${nixpkgs}/nixos/modules/profiles/minimal.nix"
              self.nixosModules.default
            ];
          };
        in
        image.config.system.build.sdImage;
    } // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
        runtimeInputs = [
            (pkgs.python3.withPackages
              (python-pkgs: with python-pkgs; [
                click
                cryptography
                ipython
                pkgs.yubikey-manager
              ]))
          ];
      in
      {
        # Development shell
        devShells.default = pkgs.mkShell {
          name = "offline-pki";
          nativeBuildInputs = [
            self.packages.${system}.pkiScript
          ] ++ runtimeInputs;
        };

        packages.resizeScript = pkgs.writeShellScriptBin "resize" ./scripts/resize;

        # Interactive menu
        packages.pkiScript = pkgs.writeShellApplication {
          inherit runtimeInputs;
          name = "pki";
          text = ''
            exec ${./scripts/pki} "$@"
          '';
        };

        # QEMU image for development (and only for that!)
        packages.qemu =
          let
            image = nixpkgs.lib.nixosSystem {
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
                      # Yubikey passthrough
                      "-device usb-host,vendorid=0x1050,productid=0x0407"
                      "-device usb-host,vendorid=0x1050,productid=0x0404"
                    ];
                  };
                  services.getty.autologinUser = "pki";
                  users.users.root.password = ".Linux.";
                  environment.loginShellInit = "${self.packages.${system}.resizeScript}/bin/resize";
                })
                self.nixosModules.default
              ];
            };
          in
          image.config.system.build.vm;
      });
}
