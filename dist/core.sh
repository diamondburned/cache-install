#!/bin/bash 

set -e

install_nix() {
	# Source: https://github.com/cachix/install-nix-action/blob/master/lib/install-nix.sh
	if [ -d "/nix/store" ]; then
		echo "The folder /nix/store exists; assuming Nix was restored from cache"
		export CACHE_HIT=true
		export PATH=$PATH:/run/current-system/sw/bin
		set_paths
		exit 0
	fi

	add_config() {
		echo "$1" | sudo tee -a /tmp/nix.conf >/dev/null
	}
	add_config "max-jobs = auto"
	# Allow binary caches for runner user.
	add_config "trusted-users = root $USER"

	installer_options=(
		--daemon
		--daemon-user-count 4
		--darwin-use-unencrypted-nix-store-volume
		--nix-extra-conf-file /tmp/nix.conf
		--no-channel-add
	)

	sh <(curl --silent --retry 5 --retry-connrefused -L "${INPUT_INSTALL_URL:-https://nixos.org/nix/install}") \
		"${installer_options[@]}"

	if [[ $OSTYPE =~ darwin ]]; then
		# Disable spotlight indexing of /nix to speed up performance
		sudo mdutil -i off /nix

		# macOS needs certificates hints
		cert_file=/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt
		echo "NIX_SSL_CERT_FILE=$cert_file" >> $GITHUB_ENV
		export NIX_SSL_CERT_FILE=$cert_file
		sudo launchctl setenv NIX_SSL_CERT_FILE "$cert_file"
	fi
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

set_paths() {
	echo "/nix/var/nix/profiles/per-user/$USER/profile/bin" >> $GITHUB_PATH
	echo "/nix/var/nix/profiles/default/bin" >> $GITHUB_PATH
	# Path is set correctly by set_paths but that is only available outside of this Action.
	export PATH=/nix/var/nix/profiles/default/bin/:$PATH
}

set_nix_path() {
	export NIX_PATH="/nix/var/nix/profiles/per-user/root/channels"
	if [[ "$INPUT_NIX_PATH" != "" ]]; then
		export NIX_PATH="$NIX_PATH:$INPUT_NIX_PATH"
	fi
	echo "NIX_PATH=${NIX_PATH}" >> $GITHUB_ENV
}

prepare() {
	sudo mkdir -p --verbose /nix
	sudo chown --verbose "$USER:" /nix 
}

prepare_save() {
	if [[ "$INPUT_AUTO_OPTIMISE" != false ]]; then
		echo "Optimising Nix store before caching..."
		nix-store --gc
		nix-store --optimise -vv
	fi
}

undo_prepare() {
	sudo rm -rf /nix
}

instantiate_key() {
	nix_files=(
		$INPUT_NIX_FILE
		$INPUT_SHELL_FILE
		$INPUT_INSTANTIATED_FILES
	)

	# For the first layer of the cache key, we'll just use the input names. This
	# ensures we'll still match the best cache if there's no exact match.
	nix_cache1=$(sha1sum \
		<<< "${nix_files[@]}" \
		| cut -d' ' -f1 \
		| head -c8)
	# TODO: add another layer that hashes the nix paths. We'll need a way to
	# figure out impure paths like nixos-unstable commits.
	nix_cache2=

	if command -v nix-instantiate >/dev/null 2>&1; then
		instantiables=()
		for nix_file in "${nix_files[@]}"; do
			if [[ -e "$nix_file" ]]; then
				instantiables+=("$nix_file")
			fi
		done

		# For the second layer of the cache key, we'll use the hash of the
		# instantiated nix files. This ensures we'll match the best cache if
		# there's an exact match.
		nix_cache2=$(sha1sum \
			< <(nix-instantiate --add-root /tmp --indirect ${instantiables[*]}) \
			| cut -d' ' -f1 \
			| head -c16)
	fi

	echo $nix_cache1
	echo $nix_cache2
}

TASK="$1"
if [ "$TASK" == "prepare-restore" ]; then
	prepare
elif [ "$TASK" == "install-with-nix" ]; then
	undo_prepare
	set_nix_path
	install_nix
	set_paths
	install_via_nix
elif [ "$TASK" == "install-from-cache" ]; then
	set_nix_path
	set_paths
elif [ "$TASK" == "prepare-save" ]; then
	prepare_save
	prepare
elif [ "$TASK" == "instantiate-key" ]; then
	instantiate_key
else
	echo "Unknown argument given to core.sh: $TASK"
	exit 1
fi
