{
  description = "Oduna: a Git-declared home and dev server on NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      disko,
      nixpkgs,
      sops-nix,
    }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      # The demo instance (examples/demo) is the configuration the VM boot
      # test boots; ./tests/testvm.nix neutralizes every external boundary.
      demoVmModules = [
        self.nixosModules.default
        ./examples/demo/host
        ./tests/testvm.nix
      ];

      # Provisioning scripts run from the store copy of this flake, so their
      # sibling scripts and the templates resolve relative to it; they act on
      # the instance directory they are started from.
      provisioningScripts = [
        "bootstrap"
        "postinstall"
        "fetch-secrets"
        "checks"
        "validate"
        "print-escrow"
      ];
      scriptApp = pkgs: name: {
        type = "app";
        program = "${pkgs.writeShellScript name ''exec ${pkgs.bash}/bin/bash ${self}/scripts/${name}.sh "$@"''}";
      };

      lintTool =
        pkgs:
        pkgs.writeShellApplication {
          name = "lint";
          runtimeInputs = with pkgs; [
            coreutils
            deadnix
            findutils
            git
            gitleaks
            gnugrep
            markdownlint-cli
            nixfmt
            prettier
            shellcheck
          ];
          text = builtins.readFile ./tools/lint.sh;
        };
      fmtTool =
        pkgs:
        pkgs.writeShellApplication {
          name = "fmt";
          runtimeInputs = with pkgs; [
            findutils
            git
            nixfmt
          ];
          text = builtins.readFile ./tools/fmt.sh;
        };
    in
    {
      # Everything a host of an instance imports: the disk and secrets module
      # systems plus the product modules. Instances add their host directory.
      nixosModules.default = {
        imports = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          ./modules/homelab.nix
          ./modules/zfs.nix
          ./modules/networking.nix
          ./modules/secrets.nix
          ./modules/monitoring.nix
          ./modules/ingress.nix
          ./modules/backups.nix
          ./modules/immich.nix
          ./modules/appdata-dirs.nix
          ./modules/services/vaultwarden.nix
          ./modules/services/forgejo.nix
          ./modules/services/navidrome.nix
          ./modules/services/actual-budget.nix
          ./modules/services/beszel.nix
          ./modules/services/authentik.nix
          ./modules/converge.nix
        ];
      };

      checks.x86_64-linux =
        let
          # One guest, one drive script: the demo host configuration under QEMU.
          vmTest =
            name: script:
            (pkgsFor "x86_64-linux").testers.nixosTest {
              inherit name;
              nodes.machine.imports = demoVmModules;
              testScript =
                { nodes, ... }:
                builtins.replaceStrings
                  [
                    "@internalDomain@"
                    "@outpostName@"
                  ]
                  [
                    nodes.machine.homelab.internalDomain
                    "${nodes.machine.networking.hostName}-navidrome"
                  ]
                  (builtins.readFile script);
            };
        in
        {
          vm-test = vmTest "vm-test" ./tests/vm-test.py;
          restore-test = vmTest "restore-test" ./tests/restore-test.py;
        };

      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        lib.genAttrs provisioningScripts (scriptApp pkgs)
        // {
          lint = {
            type = "app";
            program = lib.getExe (lintTool pkgs);
          };
          fmt = {
            type = "app";
            program = lib.getExe (fmtTool pkgs);
          };
        }
      );

      formatter = forAllSystems (system: fmtTool (pkgsFor system));
    };
}
