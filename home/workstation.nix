{ pkgs, lib, config, dotnetSdk, hermesPackage, morainePackage, ... }:

let
  # Host tools update-agent-tools shells out to that neither home.packages nor
  # Home Manager's activation PATH provides.
  updaterHostTools = lib.makeBinPath [
    pkgs.util-linux
    pkgs.curl
    pkgs.unzip
    pkgs.findutils
  ];
  moraineRootRelative = ".moraine";
  moraineRoot = "~/${moraineRootRelative}";
  moraineConfigRelative = "${moraineRootRelative}/config.toml";
  moraineConfigPath = "%h/${moraineConfigRelative}";
  moraineControl = "${morainePackage}/bin/moraine --config ${moraineConfigPath}";
  moraineService = pkgs.writeShellApplication {
    name = "moraine-service";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = builtins.readFile ../scripts/moraine-service;
  };
  moraineConfig = ''
    [identity]
    author = "faviann@gmail.com"

    [ingest]
    backfill_on_start = true

    [[ingest.sources]]
    name = "codex-active"
    harness = "codex"
    enabled = true
    glob = "~/.codex/sessions/**/*.jsonl"
    watch_root = "~/.codex/sessions"

    [[ingest.sources]]
    name = "codex-archived"
    harness = "codex"
    enabled = true
    glob = "~/.codex/archived_sessions/*.jsonl"
    watch_root = "~/.codex/archived_sessions"

    [[ingest.sources]]
    # Do not use upstream's setup-owned `claude` signature: v0.7.3 treats an
    # exact match as legacy generated config and injects newer default sources.
    name = "claude-projects"
    harness = "claude-code"
    enabled = true
    glob = "~/.claude/projects/**/*.jsonl"
    watch_root = "~/.claude/projects"

    [backend]
    bind = "127.0.0.1"

    [monitor]
    port = 8080

    [runtime]
    root_dir = "${moraineRoot}"
    service_bin_dir = "${morainePackage}/bin"
    managed_clickhouse_dir = "${moraineRoot}/clickhouse/current"
  '';
in
{
  home.username = "faviann";
  home.homeDirectory = "/home/faviann";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    dotnetSdk
    nodejs
    uv
    gh
    jq
    ripgrep
    fd
    fzf
    hermesPackage
    morainePackage
  ];

  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  home.file.${moraineConfigRelative}.text = moraineConfig;

  home.activation.removeLegacyAoeUnits = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    rm -f \
      "$HOME/.config/systemd/user/aoe-serve.service" \
      "$HOME/.config/systemd/user/aoe-lan-proxy.service" \
      "$HOME/.config/systemd/user/aoe-lan-proxy.socket"
  '';

  systemd.user.startServices = "sd-switch";

  # Upstream owns installation, readiness, migrations, and child startup. The
  # foreground wrapper keeps this unit alive only while that complete stack is
  # healthy, so one restart policy accurately represents the operator surface.
  systemd.user.services.moraine = {
    Unit = {
      Description = "Workstation-local Moraine producer";
      X-Restart-Triggers = [ config.home.file.${moraineConfigRelative}.source ];
    };

    Service = {
      Type = "simple";
      ExecStart = "${moraineService}/bin/moraine-service ${morainePackage}/bin/moraine ${moraineConfigPath}";
      ExecStop = "${moraineControl} down";
      Restart = "on-failure";
      RestartSec = 5;
    };

    Install.WantedBy = [ "default.target" ];
  };

  # installPackages is what creates the profile this handoff reads from. Ordered
  # only after reloadSystemd, the handoff ran while ~/.nix-profile was still a
  # dangling symlink, so every home.packages tool the updater needs — npm, jq —
  # was missing and activation died on whichever one it probed first.
  home.activation.bootstrapAgentTools =
    lib.hm.dag.entryAfter [ "reloadSystemd" "installPackages" ] ''
      # Activation runs with a curated store-only PATH holding just coreutils and
      # friends, so system directories are absent. The updater's remaining host
      # tools — flock for its lock, curl for the AoE release check, unzip and find
      # for the Bun archive — come from the store rather than from whatever the
      # host happens to install.
      #
      # The system directories go last, after everything the store supplies, for
      # systemctl alone: the updater restarts a unit in this host's user session,
      # so it needs that session's own systemd rather than a store copy of one.
      export PATH="$HOME/.local/bin:${config.home.profileDirectory}/bin:${updaterHostTools}:$PATH:/usr/local/bin:/usr/bin:/bin"

      # bun is listed because the updater owns it: nixpkgs lags Bun releases badly
      # enough that a harness engine floor can outrun it, so a switch that finds
      # no bun must hand off rather than leave the harnesses without a runtime.
      _agent_tools_missing=false
      for _agent_tool in \
        aoe bun codex claude pi opencode omp codex-acp claude-agent-acp pi-acp; do
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
      # aoe-serve binds 127.0.0.1:4000; the portal reaches it only through the
      # socket-activated proxy on 4001. Starting the app without the socket leaves
      # the origin port unbound, which looks like an application fault from the
      # portal side. Wants, not Requires: the app is still useful locally if the
      # socket fails, and Wants adds no ordering to deadlock against the proxy's
      # own Requires=aoe-serve.service.
      Wants = [ "aoe-lan-proxy.socket" ];
    };

    Service = {
      Type = "simple";
      Environment = "PATH=%h/.local/bin:%h/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin";
      ExecStart = "/usr/bin/env aoe serve --host 127.0.0.1 --port 4000 --no-auth --behind-proxy --allowed-host aoe.local.faviann.com";
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

  # Collie's own unit is generated by collie-ctl and is deliberately not declared
  # here, so the socket link cannot be expressed the way aoe-serve expresses it.
  # A drop-in appends one orthogonal line without duplicating any of the generated
  # unit's contents, so Collie can keep regenerating collie.service on upgrade
  # without dropping the link or drifting from a forked copy.
  #
  # The dependency deliberately points app -> socket. The reverse, a
  # Requires=collie.service on the forwarder, would make this configuration
  # reference a unit it does not manage and would fail whenever Collie is not
  # installed. That is why collie-origin-forwarder stays free of Collie
  # dependencies, and why the test asserting so still holds.
  xdg.configFile."systemd/user/collie.service.d/10-origin-forwarder.conf".text = ''
    [Unit]
    Wants=collie-origin-forwarder.socket
  '';

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

  # Boot supervision assumes the one-time detached-server cutover is complete.
  systemd.user.services.herdr.Install.WantedBy = [ "default.target" ];
  systemd.user.services.herdr.Service = {
    Type = "simple";
    Environment =
      "PATH=/home/faviann/.local/bin:/home/faviann/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin";
    ExecStart = "/home/faviann/.local/bin/herdr server";
    Restart = "on-failure";
    RestartSec = 5;
    WorkingDirectory = "/home/faviann";
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
