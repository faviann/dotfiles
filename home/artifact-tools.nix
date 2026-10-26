{ pkgs, artifactServerPackage, ... }:

{
  # Chromium and DejaVu give the render check a browser and a font that draws
  # text. nixpkgs' Chromium finds fonts through the fontconfig files that
  # `fonts.fontconfig.enable` writes, not through the host's.
  home.packages = [
    artifactServerPackage
    pkgs.nodejs
    pkgs.chromium
    pkgs.dejavu_fonts
  ];

  fonts.fontconfig.enable = true;
}
