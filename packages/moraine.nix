{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  libgcc,
}:

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

    mkdir -p "$out/bin" "$out/web/monitor"
    cp bin/moraine bin/moraine-ingest bin/moraine-monitor bin/moraine-mcp "$out/bin/"
    cp -R web/monitor/dist "$out/web/monitor/"

    runHook postInstall
  '';

  passthru.release = {
    version = "v${finalAttrs.version}";
    target = "x86_64-unknown-linux-gnu";
    hash = finalAttrs.src.outputHash;
    executables = [
      "moraine"
      "moraine-ingest"
      "moraine-monitor"
      "moraine-mcp"
    ];
  };

  meta = {
    description = "Local-first coding-agent observability and retrieval";
    homepage = "https://moraine.sh";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
