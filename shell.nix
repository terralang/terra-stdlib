{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  nativeBuildInputs = 
    let
      fundament-terra = import (pkgs.fetchFromGitHub {
        owner = "Fundament-Software";
        repo = "terra";
        rev = "fb410b202e26c58003dcad4138d42f1189d5954c";
        sha256 = "1x0f2k5wm1vpazg7v57r7bp5hyfsp5075az4j00qn06y5wyq7g8a";
      }) { inherit pkgs; };
    in
      [ fundament-terra ];
}
