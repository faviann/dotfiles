{ pkgs, lib, config, ... }:

let
  updaterHostTools = lib.makeBinPath [
    pkgs.util-linux
    pkgs.curl
    pkgs.unzip
    pkgs.git
  ];
in
{
  options.agentTools.commands = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    description = "Commands whose absence makes activation run update-agent-tools.";
  };

  config = {
    agentTools.commands = [ "bun" "codex" "claude" "opencode" ];

    # installPackages creates the profile the updater takes npm from. Before it,
    # ~/.nix-profile is a dangling symlink and the handoff fails.
    home.activation.bootstrapAgentTools =
      lib.hm.dag.entryAfter [ "installPackages" "linkGeneration" ] ''
        export PATH="$HOME/.local/bin:${config.home.profileDirectory}/bin:${updaterHostTools}:$PATH"

        _agent_tools_missing=false
        for _agent_tool in ${lib.escapeShellArgs config.agentTools.commands}; do
          if ! command -v "$_agent_tool" >/dev/null 2>&1; then
            _agent_tools_missing=true
            break
          fi
        done

        if [ "$_agent_tools_missing" = true ]; then
          command -v update-agent-tools >/dev/null 2>&1 \
            || { echo "Agent-tool bootstrap requires the dotfiles updater" >&2; exit 1; }
          run update-agent-tools
        fi
      '';

    systemd.user.services.herdr.Install.WantedBy = [ "default.target" ];
    # An update activation must never restart herdr: a restart ends every pane
    # process, including the agent running the update.
    systemd.user.services.herdr.Unit.X-RestartIfChanged = false;
    systemd.user.services.herdr.Service = {
      Type = "simple";
      Environment =
        "PATH=${config.home.homeDirectory}/.local/bin:${config.home.homeDirectory}/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin";
      ExecStart = "${config.home.homeDirectory}/.local/bin/herdr server";
      Restart = "on-failure";
      RestartSec = 5;
      WorkingDirectory = config.home.homeDirectory;
    };
  };
}
