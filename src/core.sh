#!/usr/bin/env bash

set -e
[[ "$RUNNER_DEBUG" != "" ]] && set -x

nix_files=(
	$INPUT_NIX_FILE
	$INPUT_SHELL_FILE
	$INPUT_INSTANTIATED_FILES
)

nix_inputs=(
	"${nix_files[@]}"
	"$INPUT_INSTANTIATED_EXPRESSION"
	"$INPUT_NIX_INSTALL_URL"
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
		"${INPUT_NIX_INSTALL_URL}") \
		"${installer_options[@]}"
}

install_via_nix() {
	if [[ "$INPUT_NIX_FILE" != "" ]]; then
		if [[ -f "$INPUT_NIX_FILE" ]]; then
			nix-env -i \
				-f "$INPUT_NIX_FILE" \
				--arg pkgs 'import <nixpkgs> {}'
		else
			echo "File at nix_file does not exist, skipping..."
		fi
	fi
	if [[ "$INPUT_SHELL_FILE" != "" ]]; then
		if [[ -f "$INPUT_SHELL_FILE" ]]; then
			# Install our environment variables.
			local envs=$(dump_shell "$INPUT_SHELL_FILE")
			echo "$envs" >> $GITHUB_ENV
		else
			echo "File at shell_file does not exist, skipping..."
		fi
	fi
}

dump_shell() {
	{
		nix print-dev-env \
			--extra-experimental-features 'nix-command flakes' \
			--impure \
			--file "$1"
		echo env
	} \
		| env -i bash \
		| grep -o '[A-Z0-9_][A-Za-z0-9_]\+=.*' \
		| grep -v '^_='
}

set_env() {
	echo "/home/$USER/.nix-profile/bin" >> $GITHUB_PATH
	echo "/nix/var/nix/profiles/default/bin" >> $GITHUB_PATH
	echo "/nix/var/nix/profiles/per-user/$USER/profile/bin" >> $GITHUB_PATH
	export PATH="/home/$USER/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/nix/var/nix/profiles/per-user/$USER/profile/bin:$PATH"
	echo "NIX_LINK=/home/$USER/.nix-profile" >> $GITHUB_ENV
	echo "NIX_PROFILES=/nix/var/nix/profiles/default /home/$USER/.nix-profile" >> $GITHUB_ENV
	export NIX_PATH="/nix/var/nix/profiles/per-user/root/channels:${NIX_PATH}"
	if [[ "$INPUT_NIX_PATH" != "" ]]; then
		export NIX_PATH="$NIX_PATH:$INPUT_NIX_PATH"
	fi
	echo "NIX_PATH=${NIX_PATH}" >> $GITHUB_ENV
}

prepare() {
	sudo install -d -m755 -o $(id -u) -g $(id -g) /nix
	sudo install -d -m755 -o $(id -u) -g $(id -g) /etc/nix
}

instantiate_roots() {
	paths=(
		# Also add the Nix CLI itself to the root. This is needed for the cache
		# to be restored later.
		$(nix-instantiate '<nixpkgs>' -A nix)
	)

	# Instantiate all the files and expressions and add them to the root.
	if (( ${#nix_files_instantiables[@]} > 0 )); then
		paths+=(
			$(nix-instantiate \
				--add-root /tmp/drv-root --indirect \
				"${nix_files_instantiables[@]}")
		)
	fi
	if [[ "$INPUT_INSTANTIATED_EXPRESSION" != "" ]]; then
		paths+=(
			$(nix-instantiate \
				--add-root /tmp/drv-root --indirect \
				-E "$INPUT_INSTANTIATED_EXPRESSION")
		)
	fi

	existing_paths=(
		# Find all output paths that we have built. This excludes .drv paths
		# which are not built yet.
		$(nix-store -qR --include-outputs ${paths[@]} \
			| grep -vG '\.drv$' \
			| while read -r f; do if [[ -e "$f" ]]; then echo "$f"; fi; done)
	)

	# Anchor our inputs by realizing them into a directory. This will ensure
	# that we can GC them later if needed.
	nix-store -r \
		--add-root /tmp/output-root --indirect ${existing_paths[@]} \
		> /dev/null

	echo "Added ${#existing_paths[@]} paths to the GC roots"
}

prepare_save() {
	echo "Adding known derivations and outputs to gcroots..."
	instantiate_roots

	echo "Running Nix garbage collector..."
	time nix-store --gc |& as_debug

	if [[ "$INPUT_AUTO_OPTIMISE" != false ]]; then
		echo "Optimising Nix store before caching..."
		time nix-store --optimise -v |& as_debug
	fi
}

instantiate_key() {
	# For the first layer of the cache key, we'll just use the input names. This
	# ensures we'll still match the best cache if there's no exact match.
	nix_cache1=$(sha1sum <<< "${nix_inputs[@]}" | cut -d' ' -f1 | head -c8)
	# TODO: add another layer that hashes the nix paths. We'll need a way to
	# figure out impure paths like nixos-unstable commits.
	nix_cache2=
	nix_cache3=

	if command -v nix &> /dev/null; then
		# For the second layer of the cache key, we'll use the hash of the
		# instantiated nix files. This ensures we'll match the best cache if
		# there's an exact match.
		nix_roots=()
		if (( ${#nix_files_instantiables[@]} > 0 )); then
			nix_roots+=( $(nix-instantiate "${nix_files_instantiables[@]}") )
		fi
		if [[ "$INPUT_INSTANTIATED_EXPRESSION" != "" ]]; then
			nix_roots+=( $(nix-instantiate -E "$INPUT_INSTANTIATED_EXPRESSION") )
		fi

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

as_debug() {
	while read -r line; do
		echo "::debug::$line"
	done
}

case "$1" in
prepare-restore)
	prepare
	;;
install-with-nix)
	install_nix
	set_env
	install_via_nix
	;;
install-from-cache)
	set_env
	install_via_nix
	;;
prepare-save)
	prepare_save
	prepare
	;;
instantiate-key)
	instantiate_key
	;;
*)
	echo "Unknown argument given to core.sh: $1"
	exit 1
	;;
esac
