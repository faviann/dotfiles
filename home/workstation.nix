{ pkgs, lib, config, hermesPackage, ... }:

{
  home.username = "faviann";
  home.homeDirectory = "/home/faviann";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    bun
    nodejs
    uv
    gh
    jq
    ripgrep
    fd
    fzf
    hermesPackage
  ];

  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  home.activation.removeLegacyAoeUnits = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    rm -f \
      "$HOME/.config/systemd/user/aoe-serve.service" \
      "$HOME/.config/systemd/user/aoe-lan-proxy.service" \
      "$HOME/.config/systemd/user/aoe-lan-proxy.socket"
  '';

  systemd.user.startServices = "sd-switch";

  home.activation.bootstrapAgentTools = lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
    export PATH="$HOME/.local/bin:${config.home.profileDirectory}/bin:$PATH"

    _agent_tools_missing=false
    for _agent_tool in \
      aoe codex claude pi codex-acp claude-agent-acp pi-acp; do
      if ! command -v "$_agent_tool" >/dev/null 2>&1; then
        _agent_tools_missing=true
        break
      fi
    done

    if [ "$_agent_tools_missing" = true ]; then
      command -v aoe >/dev/null 2>&1 \
        || { echo "Agent-tool bootstrap requires chezmoi to install AoE first" >&2; exit 1; }
      command -v update-agent-tools >/dev/null 2>&1 \
        || { echo "Agent-tool bootstrap requires the dotfiles updater" >&2; exit 1; }
      update-agent-tools --yes
    fi
  '';

  systemd.user.services.aoe-serve = {
    Unit = {
      Description = "Agent of Empires web dashboard";
      After = [ "default.target" ];
    };

    Service = {
      Type = "simple";
      Environment = "PATH=%h/.local/bin:%h/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin";
      ExecStart = "/usr/bin/env aoe serve --host 127.0.0.1 --port 4000 --no-auth";
      Restart = "on-failure";
      RestartSec = 5;
    };

    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.aoe-lan-proxy = {
    Unit = {
      Description = "AoE LAN proxy";
      Requires = [ "aoe-serve.service" ];
      After = [ "aoe-serve.service" ];
    };

    Service.ExecStart = "/lib/systemd/systemd-socket-proxyd 127.0.0.1:4000";
  };

  systemd.user.sockets.aoe-lan-proxy = {
    Unit.Description = "AoE LAN proxy socket";

    Socket = {
      ListenStream = "0.0.0.0:4001";
      NoDelay = true;
    };

    Install.WantedBy = [ "sockets.target" ];
  };

  systemd.user.sockets.collie-origin-forwarder = {
    Socket.ListenStream = "0.0.0.0:8788";
    Install.WantedBy = [ "sockets.target" ];
  };

  systemd.user.services.collie-origin-forwarder.Service.ExecStart =
    "/lib/systemd/systemd-socket-proxyd 127.0.0.1:8787";

  systemd.user.services.hermes-gateway = {
    Unit = {
      Description = "Hermes Agent gateway";
      After = [ "default.target" ];
    };
    Service = {
      Type = "simple";
      Environment = "PATH=%h/.local/bin:%h/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin";
      ExecStart = "/usr/bin/env hermes gateway run";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.hermes-dashboard = {
    Unit = {
      Description = "Hermes Agent dashboard";
      Requires = [ "hermes-gateway.service" ];
      After = [ "default.target" "hermes-gateway.service" ];
    };
    Service = {
      Type = "simple";
      Environment = "PATH=%h/.local/bin:%h/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin";
      ExecStart = "/usr/bin/env hermes dashboard --host 0.0.0.0 --port 9119 --no-open --insecure";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "default.target" ];
  };

  programs.openclaw = {
    enable = true;
    stateDir = "${config.home.homeDirectory}/.openclaw";
    systemd.enable = true;
    systemd.unitName = "openclaw-gateway";
  };

  # The nix-openclaw module writes openclaw.json as a read-only nix-store symlink,
  # which prevents openclaw from persisting runtime state (auth tokens, model choices, etc.).
  # These two hooks bracket nix-openclaw's generated config link:
  # save it before Home Manager writes links, restore it after openclawConfigFiles.
  home.activation.openclawSaveConfig = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    _oc_config="${config.programs.openclaw.stateDir}/openclaw.json"
    _oc_saved="${config.programs.openclaw.stateDir}/openclaw.json.pre-hm"
    if [ -f "$_oc_config" ] && [ ! -L "$_oc_config" ]; then
      cp "$_oc_config" "$_oc_saved"
    fi
  '';

  home.activation.openclawMutableConfig = lib.hm.dag.entryAfter [ "openclawConfigFiles" ] ''
    _oc_config="${config.programs.openclaw.stateDir}/openclaw.json"
    _oc_saved="${config.programs.openclaw.stateDir}/openclaw.json.pre-hm"
    if [ -f "$_oc_saved" ]; then
      mv "$_oc_saved" "$_oc_config"
      chmod 600 "$_oc_config"
    elif [ -L "$_oc_config" ]; then
      cp "$(readlink "$_oc_config")" "$_oc_config.tmp"
      mv "$_oc_config.tmp" "$_oc_config"
      chmod 600 "$_oc_config"
    fi
  '';

  # The nix-openclaw module targets graphical-session.target by default.
  # Override to default.target for headless LXC (same pattern as hermes-gateway).
  # Keep logs in journald so the service does not depend on volatile /tmp paths.
  systemd.user.services.openclaw-gateway = {
    Service = {
      StandardOutput = lib.mkForce "journal";
      StandardError = lib.mkForce "journal";
    };
    Install.WantedBy = lib.mkForce [ "default.target" ];
  };
}
