{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  rustPlatform,
  pkg-config,
}:

let
  sourceVersion = "0.7.3";
  sourceRevision = "91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9";
  sourceShortRevision = builtins.substring 0 12 sourceRevision;
  sourceHash = "sha256-5ngGU2CjP8X+0rsL2wquvrMpvJK4Z4Gpl8AfiiqI/sM=";
  releaseAssetHash = "sha256-JqjV/LL43yt1REfSyZBpYe/kHt7Y4ISqPfOB7C6ArX0=";
  releaseAssets = fetchurl {
    url = "https://github.com/eric-tramel/moraine/releases/download/v${sourceVersion}/moraine-bundle-x86_64-unknown-linux-gnu.tar.gz";
    hash = releaseAssetHash;
  };
  executables = [
    "moraine"
    "moraine-ingest"
    "moraine-monitor"
    "moraine-mcp"
  ];
in
rustPlatform.buildRustPackage (_finalAttrs: {
  pname = "moraine";
  version = "${sourceVersion}+g${sourceShortRevision}";

  src = fetchFromGitHub {
    owner = "eric-tramel";
    repo = "moraine";
    rev = sourceRevision;
    hash = sourceHash;
  };

  # Temporary workaround for upstream issue #599. Session discovery expands a
  # wide view before applying selective filters. Give local interactive queries
  # 8 GiB, the Moraine ClickHouse user 16 GiB, and the managed server 48 GiB on
  # this 64 GiB host while keeping background work at its upstream limit.
  patches = [ ./moraine-managed-memory-headroom.patch ];

  cargoHash = "sha256-lnM4IQ20UnNAOkBQ20s95viS10S5Qxl79wYcBjJZJTM=";

  nativeBuildInputs = [ pkg-config ];

  cargoBuildFlags = lib.concatMap (package: [ "-p" package ]) executables;
  doCheck = false;

  MORAINE_BUILD_GIT_SHA = sourceShortRevision;

  installPhase = ''
    runHook preInstall

    for executable in ${lib.escapeShellArgs executables}; do
      install -Dm755 \
        "target/${stdenv.hostPlatform.rust.rustcTarget}/release/$executable" \
        "$out/bin/$executable"
    done

    assets_dir="$(mktemp -d)"
    tar -xzf ${releaseAssets} -C "$assets_dir"
    mkdir -p "$out/web/monitor"
    cp -R "$assets_dir/web/monitor/dist" "$out/web/monitor/"

    runHook postInstall
  '';

  passthru.release = {
    inherit
      releaseAssetHash
      sourceHash
      sourceRevision
      sourceVersion
      ;
    rustToolchainVersion = "1.96.0";
    interactiveQueryMemoryBytes = 8589934592;
    userQueryMemoryBytes = 17179869184;
    serverMemoryBytes = 51539607552;
  };

  meta = {
    description = "Local-first coding-agent observability and retrieval";
    homepage = "https://moraine.sh";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
})
