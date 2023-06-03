{ pkgs ? import <nixpkgs> {
	overlays = [
		(self: super: {
			# nodejs = super.nodejs-16_x;
		})
	];
} }:

pkgs.mkShell {
	buildInputs = with pkgs; [
		nodejs
		esbuild
	];

	shellHook = ''
		PATH="$PWD/node_modules/.bin:$PATH"
	'';

	# ncc is trash and doesn't work otherwise.
	# NODE_OPTIONS = "--openssl-legacy-provider";
}
