{
  description = "Personal workstation Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hermes-agent.url = "github:NousResearch/hermes-agent";
    nix-openclaw = {
      url = "github:openclaw/nix-openclaw";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      hermes-agent,
      nix-openclaw,
      ...
    }:
    let
      system = "x86_64-linux";
      openclawOverlay = import "${nix-openclaw}/nix/overlay.nix" {
        openclawToolPkgs = nix-openclaw.inputs.nix-openclaw-tools.packages.${system};
      };
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ openclawOverlay ];
        config.allowUnfree = true;
      };
      behavioralTestInputs = [
        pkgs.bash
        pkgs.chezmoi
        pkgs.coreutils
        pkgs.diffutils
        pkgs.findutils
        pkgs.git
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
        pkgs.nix
        pkgs.util-linux
      ];
      shellcheckSource = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions [
          ./.chezmoiscripts
          ./dot_bashrc.tmpl
          ./dot_local/bin/executable_update-agent-tools
          ./dot_local/bin/executable_workstation-update
          ./scripts/run-shellcheck
          ./scripts/run-tests
          ./tests
        ];
      };
      shellcheckCommand = pkgs.writeShellApplication {
        name = "dotfiles-shellcheck";
        runtimeInputs = [
          pkgs.chezmoi
          pkgs.shellcheck
        ];
        text = ''
          exec ${pkgs.bash}/bin/bash ${./scripts/run-shellcheck} ${shellcheckSource}
        '';
      };
    in
    {
      apps.${system}.shellcheck = {
        type = "app";
        program = "${shellcheckCommand}/bin/dotfiles-shellcheck";
      };

      checks.${system}.shellcheck = pkgs.runCommand "dotfiles-shellcheck" {
        nativeBuildInputs = [
          pkgs.chezmoi
          pkgs.shellcheck
        ];
      } ''
        ${pkgs.bash}/bin/bash ${./scripts/run-shellcheck} ${shellcheckSource}
        touch "$out"
      '';

      devShells.${system}.default = pkgs.mkShell {
        packages = behavioralTestInputs ++ [ pkgs.shellcheck ];
      };

      homeConfigurations.workstation = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = {
          hermesPackage = hermes-agent.packages.${system}.default;
        };
        modules = [
          nix-openclaw.homeManagerModules.openclaw
          ./home/workstation.nix
        ];
      };
    };
}
