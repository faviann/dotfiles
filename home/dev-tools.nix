{ pkgs, dotnetSdk, ... }:

{
  home.packages = [
    dotnetSdk
    pkgs.ripgrep
    pkgs.fd
    pkgs.fzf
  ];
}
