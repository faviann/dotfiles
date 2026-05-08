{ pkgs, lib, hermesPackage, ... }:

{
  home.username = "faviann";
  home.homeDirectory = "/home/faviann";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    nodejs
    uv
    gh
    jq
    ripgrep
    fd
    fzf
    codex
    claude-code
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

  systemd.user.services.aoe-serve = {
    Unit = {
      Description = "Agent of Empires web dashboard";
      After = [ "default.target" ];
    };

    Service = {
      Type = "simple";
      Environment = "PATH=%h/.nix-profile/bin:%h/.local/bin:/usr/local/bin:/usr/bin:/bin";
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
}
