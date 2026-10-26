{ ... }:

let
  # Home Manager reads these at switch time with `--impure`. Pure evaluation,
  # as in `nix flake check`, sees empty values and takes the fallbacks.
  fromEnvironment =
    name: fallback:
    let
      value = builtins.getEnv name;
    in
    if value == "" then fallback else value;
in
{
  imports = [ ./artifact-tools.nix ];

  home.username = fromEnvironment "USER" "faviann";
  home.homeDirectory = fromEnvironment "HOME" "/home/faviann";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;
}
