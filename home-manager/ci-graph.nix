{ buildNpmPackage, lib, zip }:
# Firefox extension: dagre job graph + skipped-job filter for GitHub Actions
# runs. Source is vendored in ./ci-graph (upstream: ~/src/ci-graph). The xpi is
# unsigned, so it only loads on developer edition -- see firefox.nix.
buildNpmPackage {
  pname = "ci-graph";
  version = "0.5.1";
  src = ./ci-graph;
  npmDepsHash = "sha256-ziM2Y5mEQHYAiMztpfQ0RAkjW4fz0CDwEsCbGjqqXB0=";

  nativeBuildInputs = [ zip ];

  # `npm run build` (the default) writes dist/; there is nothing to npm-install.
  dontNpmInstall = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    (cd dist && zip -qr $out/ci-graph.xpi .)
    runHook postInstall
  '';
}
