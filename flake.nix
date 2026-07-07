{
  description = "hledger, built from upstream source";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # hledger source tree. `flake = false` -> we just want the raw checkout.
    # update with: nix flake update hledger-src
    # A release tag lines up best with nixpkgs' Haskell set (fewer overrides).
    hledger-src = {
      url = "github:simonmichael/hledger";
      flake = false;
    };
    # Bleeding edge:   url = "github:simonmichael/hledger";
    # Specific commit: url = "github:simonmichael/hledger/<full-40-char-sha>";
    # Specific version: url = "github:simonmichael/hledger/hledger-1.52.1";
  };

  outputs = { self, nixpkgs, flake-utils, hledger-src }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs.haskell.lib) doJailbreak dontCheck justStaticExecutables;

        # --- Per-package source, with hledger's symlinks handled --------------
        # hledger embeds documentation at compile time (file-embed Template
        # Haskell in Hledger/Cli/DocFiles.hs). The embedded files live under each
        # package's embeddedfiles/ dir as SYMLINKS pointing UP to the repo root
        # (../../doc/tldr/..., sibling packages, ../hledger.1, etc). callCabal2nix
        # builds a single package subdir, which would leave those links dangling.
        # The test/ dirs additionally symlink into examples/, whose targets may be
        # absent from the fetched tree.
        #
        # Strategy: copy the subdir with `cp -a` (preserves symlinks WITHOUT
        # following them, so it never fails on a dangling link), then resolve each
        # symlink against the FULL source tree -- materialising it into a real file
        # when the target exists, or dropping it when it doesn't (those are unused
        # test fixtures; dontCheck skips the suites, so they're never needed).
        # The doc files that are actually embedded always resolve, so they always
        # get materialised.
        mkPkgSrc = subdir:
          pkgs.runCommand "hledger-src-${subdir}" { } ''
          mkdir -p $out
            cp -a ${hledger-src}/${subdir}/. $out
            chmod -R u+w $out
            find $out -type l | while IFS= read -r link; do
              rel=''${link#"$out"/}
              real="${hledger-src}/${subdir}/$(dirname "$rel")/$(readlink "$link")"
              if [ -e "$real" ]; then
                rm "$link"; cp -rL "$real" "$link"
              else
                rm -f "$link"
              fi
            done
          '';

        # nixpkgs' default GHC. For a specific GHC use e.g. pkgs.haskell.packages.ghc966.
        hp = pkgs.haskellPackages.override {
          overrides = hself: hsuper:
            let
              # callCabal2nix parses the real .cabal (so deps stay correct), and
              # nixpkgs sets the build src to exactly the (fixed-up) tree we pass.
              #   doJailbreak -> relax upstream version bounds (see megaparsec note)
              #   dontCheck   -> skip test suites (faster; also why dropped test
              #                  fixtures above are harmless)
              fromSrc = name:
                doJailbreak (dontCheck
                  (hself.callCabal2nix name (mkPkgSrc name) { }));
            in {
              hledger-lib = fromSrc "hledger-lib";
              hledger     = fromSrc "hledger";
              hledger-ui  = fromSrc "hledger-ui";
              hledger-web = fromSrc "hledger-web";

              # --- Dependency-conflict escape hatch --------------------------
              # hledger's upper bound on megaparsec regularly lags nixpkgs.
              # doJailbreak usually handles it; if the API actually differs, pin
              # the version hledger wants instead (slow: rebuilds megaparsec and
              # all its reverse-deps locally, so prefer jailbreak):
              #
              # megaparsec = hself.callHackage "megaparsec" "9.6.1" { };
            };
        };
      in {
        packages = {
          default     = justStaticExecutables hp.hledger;
          hledger     = justStaticExecutables hp.hledger;
          hledger-ui  = justStaticExecutables hp.hledger-ui;
          hledger-web = justStaticExecutables hp.hledger-web;
          debug-src = mkPkgSrc "hledger";
        };

        apps.default = {
          type = "app";
          program = "${justStaticExecutables hp.hledger}/bin/hledger";
        };

        devShells.default = hp.shellFor {
          packages = p: [ p.hledger p.hledger-lib ];
          nativeBuildInputs = [ pkgs.cabal-install pkgs.haskell-language-server ];
        };
      });
}

