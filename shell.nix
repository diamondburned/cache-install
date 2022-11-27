{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
	buildInputs = with pkgs; [
		nodejs-16_x
		esbuild
	];

	shellHook = ''
		PATH="$PWD/node_modules/.bin:$PATH"
	'';

	# ncc is trash and doesn't work otherwise.
	NODE_OPTIONS = "--openssl-legacy-provider";
}
