{ lib, buildGo127Module, go_1_27, fetchurl, pkg-config, openssh, libghostty-vt }:
let
  # The pinned Ghostty nixpkgs has Go 1.27.0; our go.mod requires 1.27.1.
  go = go_1_27.overrideAttrs {
    version = "1.27.1";
    src = fetchurl {
      url = "https://go.dev/dl/go1.27.1.src.tar.gz";
      hash = "sha256-TkCKuuEm2Ra2FkYnGT8sVPDjyhMS1pO4bbRfhiqyOLE=";
    };
  };
in (buildGo127Module.override { inherit go; }) {
  pname = "illogical";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [ ../../service ../../illogical/Resources/Licenses ../../deploy/linux/licenses ];
  };
  modRoot = "service";
  vendorHash = lib.removeSuffix "\n" (builtins.readFile ./vendor-hash.txt);
  subPackages = [ "cmd/illogical" ];
  nativeBuildInputs = [ pkg-config ];
  nativeCheckInputs = [ openssh ];
  buildInputs = [ libghostty-vt.dev ];
  env.CGO_ENABLED = 1;
  preBuild = ''
    export PKG_CONFIG_PATH="${libghostty-vt.dev}/share/pkgconfig"
  '';
  preCheck = ''
    export HOME="$TMPDIR/illogical-test-home"
    mkdir -p "$HOME"
  '';
  postInstall = ''
    mkdir -p "$out/share/illogical"
    cp -R ../illogical/Resources/Licenses "$out/share/illogical/licenses"
    rm -rf "$out/share/illogical/licenses/GoModules"
    cp -R ../deploy/linux/licenses "$out/share/illogical/licenses/GoModules"
  '';
  meta = {
    description = "Persistent terminal workspace service and CLI";
    platforms = lib.platforms.linux;
    mainProgram = "illogical";
  };
}
