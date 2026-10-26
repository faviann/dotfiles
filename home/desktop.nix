{ ... }:

let
  envOrPureEvalFallback =
    name: fallback:
    let
      value = builtins.getEnv name;
    in
    if value == "" then fallback else value;
in
{
  imports = [ ./artifact-tools.nix ];

  home.username = envOrPureEvalFallback "USER" "faviann";
  home.homeDirectory = envOrPureEvalFallback "HOME" "/home/faviann";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;
}
