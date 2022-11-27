# Cache install Nix packages

This actions allows caching of installations done via the [Nix package
manager](https://nixos.org) to improve workflow execution time.

[![][tests-img]][tests-url]

Installing packages via the Nix package manager is generally quite quick.
However, sometimes the packages take a long time to compile or to download from
their original sources. For example, this occurs with R packages and LaTeX which
are downloaded from respectively `CRAN` and `math.utah.edu`.

This GitHub Action speeds up the installation by simply caching the Nix store
and the symlinks to the packages in the store in the [GitHub Actions
cache][gha-cache]. So, the installed packages are restored from the cache by
copying back `/nix/store`, the symlinks to `/nix/store/*` and some paths for the
PATH environment variable.

This repository was a fork of
[rikhuijzer/cache-install][rikhuijzer_cache-install], which achieved a similar
goal. The fork adds `shell.nix` support and removes the need to specify a cache
key, since they're now automatically generated from Nix hashes.

For inputs, see the [action.yml](./action.yml) file.

## Example workflow

```yml
name: latex

on: push

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v2

      - name: Cache install Nix packages
        uses: diamondburned/cache-install@main
        with:
          shell-file: shell.nix

      - name: Calculate some things
        run: julia -e 'using MyPackage; MyPackage.calculate()'

      - name: Build LaTeX
        run: latexmk -f -pdf example.tex

      - name: Build website
        run: hugo --gc --minify
```

where the file `shell.nix` contains

```nix
let
	# Pinning explicitly to 20.03. This is important because caches will be
	# reused, so the behavior of impure channels are erratic.
	rev = "5272327b81ed355bbed5659b8d303cf2979b6953";
	pkgs = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz") {};

	myTex = with pkgs; texlive.combine {
		inherit (texlive) scheme-medium pdfcrop;
	};

in pkgs.mkShell {
	buildInputs = with pkgs; [
		hugo
		julia
		myTex
	];
}
```

[gha-cache]: https://github.com/actions/cache
[tests-img]: https://github.com/diamondburned/cache-install/workflows/test/badge.svg
[tests-url]: https://github.com/diamondburned/cache-install/actions
[rikhuijzer_cache-install]: https://github.com/rikhuijzer/cache-install
