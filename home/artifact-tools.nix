{ pkgs, artifactServerPackage, ... }:

{
  home.packages = [
    artifactServerPackage
    pkgs.nodejs
    pkgs.chromium
    pkgs.dejavu_fonts
  ];

  fonts.fontconfig.enable = true;
}
