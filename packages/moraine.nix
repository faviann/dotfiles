{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  libgcc,
}:

let
  executables = [
    "moraine"
    "moraine-ingest"
    "moraine-monitor"
    "moraine-mcp"
  ];
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "moraine";
  version = "0.7.3";

  src = fetchurl {
    url = "https://github.com/eric-tramel/moraine/releases/download/v${finalAttrs.version}/moraine-bundle-x86_64-unknown-linux-gnu.tar.gz";
    hash = "sha256-JqjV/LL43yt1REfSyZBpYe/kHt7Y4ISqPfOB7C6ArX0=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ libgcc ];

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/web/monitor"
    for executable in ${lib.escapeShellArgs executables}; do
      install -Dm755 "bin/$executable" "$out/bin/$executable"
    done
    cp -R web/monitor/dist "$out/web/monitor/"

    runHook postInstall
  '';

  meta = {
    description = "Local-first coding-agent observability and retrieval";
    homepage = "https://moraine.sh";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
