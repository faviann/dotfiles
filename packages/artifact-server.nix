{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  nodejs_24,
}:

let
  version = "0.1.2";
  url = "https://github.com/plannotator/artifact-server/releases/download/v${version}/artifact-server-${version}-node.tar.gz";
  sha256 = "f6a289c4e2c93d2e8bc9af792796b9c5c7e87e41d3c3e878e267c7db6d336fe4";
in
stdenvNoCC.mkDerivation {
  pname = "artifact-server";
  inherit version;

  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/artifactserver" "$out/bin"
    cp -r . "$out/lib/artifactserver"
    makeWrapper ${nodejs_24}/bin/node "$out/bin/artifactserver" \
      --add-flags "$out/lib/artifactserver/dist/cli/main.js"

    runHook postInstall
  '';

  passthru.release = {
    inherit version url sha256;
  };

  meta = {
    description = "Command-line client that publishes files to artifact-server";
    homepage = "https://github.com/plannotator/artifact-server";
    license = lib.licenses.asl20;
    mainProgram = "artifactserver";
  };
}
