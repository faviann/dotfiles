{ pkgs, lib, config, dotnetSdk, hermesPackage, morainePackage, ... }:

let
  lobuContextName = "homelab";
  lobuControlPlaneOrigin = "https://lobu.admin.faviann.com";
  lobuBootstrap = pkgs.writeShellApplication {
    name = "lobu-bootstrap";
    runtimeInputs = [ pkgs.nodejs ];
    text = builtins.readFile ../scripts/lobu-bootstrap;
  };
  # Host tools update-agent-tools shells out to that neither home.packages nor
  # Home Manager's activation PATH provides.
  updaterHostTools = lib.makeBinPath [
    pkgs.util-linux
    pkgs.curl
    pkgs.unzip
  ];
  collieBootstrap = pkgs.writeShellApplication {
    name = "collie-bootstrap";
    runtimeInputs = [ pkgs.bash pkgs.coreutils pkgs.jq ];
    text = builtins.readFile ../scripts/collie-bootstrap;
  };
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
  # The publish-artifact skill rereads this mapping on every publication.
  # HomeLab-iac owns the directory, static server, routing, and retention
  # behind these values (https://github.com/faviann/homelab-iac/issues/272);
  # dotfiles owns only the user's mapping file. The public tier serves
  # publications to anyone holding the URL, with no forward-auth in front of
  # it, so nothing private belongs in the publishing root. There is no
  # automatic synchronization between the two repositories, so change both
  # together.
  artifactPublisherMapping = {
    directory = "/ephemeral/workstation/artifacts";
    baseUrl = "https://artifacts.public.faviann.com";
  };
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
    azure-cli
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

  xdg.configFile."faviann-skills/artifacts.json".text =
    builtins.toJSON artifactPublisherMapping;

  systemd.user.startServices = "sd-switch";

  # Interactive Lobu use follows the self-hosted control plane by default,
  # instead of whichever context the CLI happens to have selected. Declared for
  # both shell sessions and the systemd user manager so a daemon started from a
  # terminal, Codex, or a user service such as Herdr resolves the same context.
  # This is a default, not a lock: the hosted `lobu` context stays selectable,
  # and an explicit `LOBU_CONTEXT` or `--context` still wins. `lobu.service`
  # sets the variable itself and does not depend on this.
  home.sessionVariables.LOBU_CONTEXT = lobuContextName;
  systemd.user.sessionVariables.LOBU_CONTEXT = lobuContextName;

  # The profile must exist before npm runs; install before sd-switch can start
  # the daemon. Home Manager's run helper preserves activation dry-run behavior.
  home.activation.bootstrapLobu =
    lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "installPackages" ] ''
      run ${lobuBootstrap}/bin/lobu-bootstrap
    '';

  systemd.user.services.lobu = {
    Unit = {
      Description = "Lobu workstation headless device";
      ConditionPathExists = "%h/.config/lobu/credentials.json";
    };
    Service = {
      Type = "simple";
      # The daemon resolves this named context directly. Verify its origin
      # without making it the active interactive CLI context.
      ExecCondition = lib.escapeShellArgs [
        "${pkgs.jq}/bin/jq"
        "-e"
        "--arg"
        "context"
        lobuContextName
        "--arg"
        "origin"
        lobuControlPlaneOrigin
        ".contexts[$context].url == $origin"
        "%h/.config/lobu/config.json"
      ];
      Environment = [
        "HOME=${config.home.homeDirectory}"
        "LOBU_CONTEXT=${lobuContextName}"
        "PATH=${config.home.homeDirectory}/.local/bin:${config.home.profileDirectory}/bin:/usr/local/bin:/usr/bin:/bin"
      ];
      UnsetEnvironment = "LOBU_API_URL";
      WorkingDirectory = config.home.homeDirectory;
      ExecStart = "${config.home.homeDirectory}/.local/bin/lobu daemon --no-interactive-session";
      # Longer than the local units' five seconds: a stale credential fails
      # every start, and the default rate limiter never trips at a flat
      # interval, so this is the actual request rate against the control plane
      # during a permanent authentication fault. Deliberately flat rather than
      # backed off, because systemd's restart counter accumulates for the
      # unit's lifetime and does not reset on a successful start.
      Restart = "on-failure";
      RestartSec = 30;
      UMask = "0077";
    };
    Install.WantedBy = [ "default.target" ];
  };

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

  # installPackages creates the profile the updater takes npm from. Before it,
  # ~/.nix-profile is a dangling symlink and the handoff fails.
  home.activation.bootstrapAgentTools =
    lib.hm.dag.entryAfter [ "installPackages" ] ''
      export PATH="$HOME/.local/bin:${config.home.profileDirectory}/bin:${updaterHostTools}:$PATH"

      _agent_tools_missing=false
      for _agent_tool in \
        bun codex claude pi opencode omp; do
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

  # Collie's generated unit is lost on an LXC rebuild. Resolve the persisted
  # installation at each boot rather than retaining its generated executable paths.
  systemd.user.services.collie-bootstrap = {
    Unit = {
      Description = "Regenerate and start the installed Collie bridge";
      # Collie's start waits for a unit ordered After=default.target. Running
      # before that target would deadlock the first boot after a rebuild.
      After = [ "default.target" ];
    };
    Install.WantedBy = [ "default.target" ];
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment =
        "PATH=/home/faviann/.local/bin:/home/faviann/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin";
      ExecStart = "${collieBootstrap}/bin/collie-bootstrap";
      WorkingDirectory = "/home/faviann";
      TimeoutStartSec = 300;
    };
  };

  systemd.user.sockets.collie-origin-forwarder = {
    Socket.ListenStream = "0.0.0.0:8788";
    Install.WantedBy = [ "sockets.target" ];
  };

  systemd.user.services.collie-origin-forwarder.Service.ExecStart =
    "/lib/systemd/systemd-socket-proxyd 127.0.0.1:8787";

  # Collie's own unit is generated by collie-ctl and is deliberately not declared
  # here, so the socket link cannot be declared in the unit itself.
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
