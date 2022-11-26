#!/usr/bin/env bash

set -e

nix_files=(
	$INPUT_NIX_FILE
	$INPUT_SHELL_FILE
	$INPUT_INSTANTIATED_FILES
)

nix_files_instantiables=()
for nix_file in "${nix_files[@]}"; do
	if [[ -e "$nix_file" ]]; then
		nix_files_instantiables+=("$nix_file")
	fi
done

install_nix() {
	{
		echo "max-jobs = auto"
		echo "trusted-users = root $USER"
	} | sudo tee -a /tmp/nix.conf > /dev/null

	installer_options=(
		--nix-extra-conf-file /tmp/nix.conf
		--no-channel-add
	)

	sh <(curl --silent --retry 5 --retry-connrefused -L \
		"${INPUT_INSTALL_URL:-https://nixos.org/nix/install}") \
		"${installer_options[@]}"

	source $HOME/.nix-profile/etc/profile.d/nix.sh
}

install_via_nix() {
	if [[ "$INPUT_NIX_FILE" != "" ]]; then
		if [[ -f "$INPUT_NIX_FILE" ]]; then
			nix-env --install --file "$INPUT_NIX_FILE"
		else
			echo "File at nix_file does not exist, skipping..."
		fi
	fi
	if [[ "$INPUT_SHELL_FILE" != "" ]]; then
		if [[ -f "$INPUT_SHELL_FILE" ]]; then
			local path=$(realpath "$INPUT_SHELL_FILE")
			nix-env --install -E "{ ... }: (import ${path} {}).buildInputs"
		else
			echo "File at shell_file does not exist, skipping..."
		fi
	fi
}

set_env() {
	echo "/home/$USER/.nix-profile/bin" >> $GITHUB_PATH
	echo "/nix/var/nix/profiles/default/bin" >> $GITHUB_PATH
	echo "/nix/var/nix/profiles/per-user/$USER/profile/bin" >> $GITHUB_PATH
	export PATH="/home/$USER/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/nix/var/nix/profiles/per-user/$USER/profile/bin:$PATH"
	echo "NIX_LINK=/home/$USER/.nix-profile" >> $GITHUB_ENV
	echo "NIX_PROFILES=/nix/var/nix/profiles/default /home/$USER/.nix-profile" >> $GITHUB_ENV
	export NIX_PATH="/nix/var/nix/profiles/per-user/root/channels"
	if [[ "$INPUT_NIX_PATH" != "" ]]; then
		export NIX_PATH="$NIX_PATH:$INPUT_NIX_PATH"
	fi
	echo "NIX_PATH=${NIX_PATH}" >> $GITHUB_ENV
}

instantiate_roots() {
	# Anchor our inputs by instantiating them into a directory. This will
	# ensure that we can GC them later if needed.
	paths=$(nix-instantiate \
		--add-root /nix/var/nix/gcroots/per-user/$USER/cache-install \
		${nix_files_instantiables[*]})

	echo "::debug::Instantiated roots:"
	for path in "$paths"; do
		echo "::debug::$(ls -l $path)"
	done
}

prepare() {
	sudo install -d -m755 -o $(id -u) -g $(id -g) /nix
	sudo install -d -m755 -o $(id -u) -g $(id -g) /etc/nix
}

prepare_save() {
	if [[ "$INPUT_AUTO_OPTIMISE" != false ]]; then
		echo "Optimising Nix store before caching..."
		nix-store --gc
		nix-store --optimise -vv
	fi
}

instantiate_key() {
	# For the first layer of the cache key, we'll just use the input names. This
	# ensures we'll still match the best cache if there's no exact match.
	nix_cache1=$(sha1sum <<< "${nix_files[@]}" | cut -d' ' -f1 | head -c8)
	# TODO: add another layer that hashes the nix paths. We'll need a way to
	# figure out impure paths like nixos-unstable commits.
	nix_cache2=
	nix_cache3=

	if command -v nix &> /dev/null; then
		# For the second layer of the cache key, we'll use the hash of the
		# instantiated nix files. This ensures we'll match the best cache if
		# there's an exact match.
		nix_roots=( $(nix-instantiate ${nix_files_instantiables[*]}) )
		nix_cache2=$(sha1sum <<< "${nix_roots[@]}" | cut -d' ' -f1 | head -c16)

		# For the third layer of the cache key, we'll use the hash of the
		# nix store paths. This prevents cases where we didn't fetch everything
		# that we should have.
		nix_cache3=$(nix-store -qR --include-outputs "${nix_roots[@]}" \
			| while read -r f; do if [[ -e "$f" ]]; then echo "$f"; fi; done \
			| sha1sum \
			| cut -d' ' -f1 \
			| head -c16)
	fi

	printf "%s-%s-%s\n" "$nix_cache1" "$nix_cache2" "$nix_cache3"
}

TASK="$1"
if [ "$TASK" == "prepare-restore" ]; then
	prepare
elif [ "$TASK" == "install-with-nix" ]; then
	install_nix
	install_via_nix
	set_env
elif [ "$TASK" == "install-from-cache" ]; then
	set_env
elif [ "$TASK" == "prepare-save" ]; then
	instantiate_roots
	prepare_save
	prepare
elif [ "$TASK" == "instantiate-key" ]; then
	instantiate_key
else
	echo "Unknown argument given to core.sh: $TASK"
	exit 1
fi
