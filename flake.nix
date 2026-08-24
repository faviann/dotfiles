{
  description = "Personal workstation Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    dotnet-nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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
      dotnet-nixpkgs,
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
      dotnetPkgs = import dotnet-nixpkgs {
        inherit system;
      };
      dotnetSdk = dotnetPkgs.dotnet-sdk_10;
      morainePackage = pkgs.callPackage ./packages/moraine.nix { };
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
        pkgs.unzip
        pkgs.util-linux
        pkgs.zip
      ];
      behavioralTestSource = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = ./.;
      };
      workstationHomeConfiguration = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = {
          inherit dotnetSdk morainePackage;
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
      bootstrapAgentToolsOrdering = pkgs.writeText "bootstrap-agent-tools-after" (
        builtins.toJSON workstationHomeConfiguration.config.home.activation.bootstrapAgentTools.after
      );
      workstationRenderedConfiguration = pkgs.writeText "workstation-rendered-configuration.json" (
        builtins.toJSON {
          dotnetSdkPackage =
            let
              package = builtins.head (
                builtins.filter
                  (package: (package.pname or package.name) == "dotnet-sdk-wrapped")
                  workstationHomeConfiguration.config.home.packages
              );
            in
            {
              pname = package.pname or package.name;
              inherit (package) version;
            };
          moraineRelease = {
            inherit (morainePackage) version;
            hash = morainePackage.src.outputHash;
            source = morainePackage.src.url;
            storePath = "${morainePackage}";
            hasReleasePassthru = morainePackage.passthru ? release;
          };
          moraineConfig = builtins.fromTOML (builtins.unsafeDiscardStringContext (
            workstationHomeConfiguration.config.home.file.".moraine/config.toml".text
          ));
          moraineServiceTopology =
            let
              services = workstationHomeConfiguration.config.systemd.user.services;
            in
            {
              names = builtins.filter
                (name: builtins.match "moraine.*" name != null)
                (builtins.attrNames services);
              service = services.moraine;
            };
          moraineCodexBoundary = {
            managesConfig = workstationHomeConfiguration.config.home.file ? ".codex/config.toml";
            hasRegistrationActivation =
              workstationHomeConfiguration.config.home.activation ? configureMoraineCodexMcp;
          };
          collieOriginSocket =
            workstationHomeConfiguration.config.systemd.user.sockets.collie-origin-forwarder;
          collieOriginService =
            workstationHomeConfiguration.config.systemd.user.services.collie-origin-forwarder;
          aoeLanProxySocket = workstationHomeConfiguration.config.systemd.user.sockets.aoe-lan-proxy;
          aoeLanProxyService = workstationHomeConfiguration.config.systemd.user.services.aoe-lan-proxy;
          aoeServeService = workstationHomeConfiguration.config.systemd.user.services.aoe-serve;
          collieServiceDropIn =
            workstationHomeConfiguration.config.xdg.configFile
            ."systemd/user/collie.service.d/10-origin-forwarder.conf".text;
        }
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
          ./scripts/moraine-service
          ./scripts/run-shellcheck
          ./scripts/run-tests
          ./scripts/update-dotnet-sdk
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
      packages.${system} = {
        dotnet-sdk = dotnetSdk;
        moraine = morainePackage;
      };

      apps.${system}.shellcheck = {
        type = "app";
        program = "${shellcheckCommand}/bin/dotfiles-shellcheck";
      };

      checks.${system} = {
        github-actions = pkgs.runCommand "github-actions" {
          nativeBuildInputs = [ pkgs.actionlint ];
        } ''
          actionlint ${./.github/workflows/update-dotnet-sdk.yml}
          touch "$out"
        '';

        dotnet-sdk-major = dotnetPkgs.runCommand "dotnet-sdk-major" {
          nativeBuildInputs = [ dotnetSdk ];
        } ''
          export DOTNET_CLI_HOME="$TMPDIR/dotnet-home"
          export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
          mkdir -p "$DOTNET_CLI_HOME"

          _dotnet_version="$(dotnet --version)"
          case "$_dotnet_version" in
            10.*) ;;
            *)
              echo "Expected a .NET 10 SDK, got $_dotnet_version" >&2
              exit 1
              ;;
          esac

          touch "$out"
        '';

        workstation-activation = workstationHomeConfiguration.activationPackage;

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
          TEST_BOOTSTRAP_ACTIVATION_AFTER = bootstrapAgentToolsOrdering;
          TEST_WORKSTATION_RENDERED_CONFIGURATION = workstationRenderedConfiguration;
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
