{ stdenv, lib, pam }:
stdenv.mkDerivation {
  pname = "illogical-login";
  version = "0.1.0";
  src = ../linux;
  buildInputs = [ pam ];
  buildPhase = ''
    $CC -std=c11 -O2 -Wall -Wextra -Werror illogical-login.c -lpam -o illogical-login
  '';
  installPhase = ''
    mkdir -p $out/bin
    install -m755 illogical-login $out/bin/
  '';
  meta.platforms = lib.platforms.linux;
}
