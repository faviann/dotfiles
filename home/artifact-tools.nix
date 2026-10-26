{ pkgs, artifactServerPackage, ... }:

{
  home.packages = [
    artifactServerPackage
    pkgs.nodejs
    pkgs.chromium
    pkgs.dejavu_fonts
    pkgs.fontconfig
  ];

  fonts.fontconfig.enable = true;
}
