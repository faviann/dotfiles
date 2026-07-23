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
      behavioralTestSource = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = ./.;
      };
      workstationHomeConfiguration = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = {
          hermesPackage = hermes-agent.packages.${system}.default;
        };
        modules = [
          nix-openclaw.homeManagerModules.openclaw
          ./home/workstation.nix
        ];
      };
      bootstrapAgentToolsActivation = pkgs.writeText "bootstrap-agent-tools" (
        workstationHomeConfiguration.config.home.activation.bootstrapAgentTools.data
      );
      shellcheckSource = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions [
          ./.chezmoiscripts
          ./dot_bash_profile.tmpl
          ./dot_bashrc.tmpl
          ./dot_local/bin/executable_update-agent-tools
          ./dot_local/bin/executable_workstation-login
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

      checks.${system} = {
        shellcheck = pkgs.runCommand "dotfiles-shellcheck" {
          nativeBuildInputs = [
            pkgs.chezmoi
            pkgs.shellcheck
          ];
        } ''
          ${pkgs.bash}/bin/bash ${./scripts/run-shellcheck} ${shellcheckSource}
          touch "$out"
        '';

        test-runner = pkgs.runCommand "dotfiles-test-runner" {
          nativeBuildInputs = behavioralTestInputs;
        } ''
          export HOME="$TMPDIR/home"
          export XDG_CACHE_HOME="$TMPDIR/cache"
          export XDG_CONFIG_HOME="$TMPDIR/config"
          export XDG_STATE_HOME="$TMPDIR/state"
          mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"

          ${pkgs.bash}/bin/bash ${behavioralTestSource}/tests/contracts/test-runner.bash
          touch "$out"
        '';

        behavioral-tests = pkgs.runCommand "dotfiles-behavioral-tests" {
          nativeBuildInputs = behavioralTestInputs;
          NIX_CONFIG = ''
            experimental-features = nix-command flakes
            offline = true
          '';
          TEST_BOOTSTRAP_ACTIVATION_SCRIPT = bootstrapAgentToolsActivation;
        } ''
          export HOME="$TMPDIR/home"
          export XDG_CACHE_HOME="$TMPDIR/cache"
          export XDG_CONFIG_HOME="$TMPDIR/config"
          export XDG_STATE_HOME="$TMPDIR/state"
          mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"

          ${pkgs.bash}/bin/bash ${behavioralTestSource}/scripts/run-tests
          touch "$out"
        '';
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = behavioralTestInputs ++ [ pkgs.shellcheck ];
      };

      homeConfigurations.workstation = workstationHomeConfiguration;
    };
}
