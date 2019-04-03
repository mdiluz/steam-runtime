#!/usr/bin/env bash

SCRIPT="$(readlink -f "$0")"
SCRIPTNAME="$(basename "$SCRIPT")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
BOOTSTRAP_SCRIPT="$SCRIPT_DIR/scripts/bootstrap-runtime.sh"
LOGFILE="$(mktemp --tmpdir steam-runtime-setup-chroot-XXX.log)"
CHROOT_PREFIX="steamrt_"
CHROOT_DIR="/var/chroots"
INSTALL_FORCE=false
BETA_ARG=""
COLOR_OFF="\033[0m"
COLOR_ON="\033[1;93m"
COLOR_ERROR_ON="\033[0;31m"

# exit on any script line that fails
set -o errexit
# bail on any unitialized variable reads
set -o nounset
# bail on failing commands before last pipe
set -o pipefail

# Output helpers
COLOR_OFF=""
COLOR_ON=""
if [[ $(tput colors 2>/dev/null || echo 0) -gt 0 ]]; then
  COLOR_ON=$'\e[93;1m'
  COLOR_OFF=$'\e[0m'
fi

sh_quote ()
{
  local quoted
  if [ $# -gt 0 ]; then
    quoted="$(printf '%q ' "$@")"
    echo "${quoted:0:-1}"
  fi
}

prebuild_chroot()
{
	# install some packages
	echo -e "\\n${COLOR_ON}Installing debootstrap schroot...${COLOR_OFF}"
	sudo -E apt-get install -y debootstrap schroot

	# Check if there are any active schroot sessions right now and warn if so...
	schroot_list=$(schroot --list --all-sessions | head -n 1)
	if [ -n "$schroot_list" ]; then
		echo -e "\\n${COLOR_ERROR_ON}WARNING: Schroot says you have a currently active session!${COLOR_OFF}\\n"
		echo "  ${schroot_list}"
		echo ""
		if [[ $- == *i* ]]; then
			read -r -p "Are you sure you want to continue (y/n)? "
			if [[ "$REPLY" != [Yy] ]]; then
				echo -e "Cancelled...\\n"
				exit 1
			fi
		else
			>&2 echo -e "${COLOR_ERROR_ON}ERROR: Cannot continue...${COLOR_OFF}"
			exit 1
		fi
	fi

	STEAM_RUNTIME_SPEW_WARNING=
	for var in "$@"; do
		dirname="${CHROOT_DIR}/${CHROOT_PREFIX}${var/--/}"
		if [ -d "${dirname}" ]; then
			STEAM_RUNTIME_SPEW_WARNING=1
			echo -e "${COLOR_ERROR_ON}About to remove ${dirname} and re-install...${COLOR_OFF}"
		fi
	done

	if [[ "$STEAM_RUNTIME_SPEW_WARNING" == "1" ]]; then
		if [[ $- == *i* ]]; then
			read -r -p "  This ok (y/n)? "
			if [[ "$REPLY" != [Yy] ]]; then
				echo -e "Cancelled...\\n"
				exit 1
			fi
		elif [[ "$INSTALL_FORCE" == false ]]; then
			>&2 echo -e "${COLOR_ERROR_ON}ERROR: Please use --force if this is intentional${COLOR_OFF}"
			exit 1
		fi
	fi
}

copy_apt_settings ()
{
	local sysroot="$1"

	if [ "$1/" -ef / ]; then
		echo "Internal error: sysroot "$1" is the same file as the real root" >&2
		exit 1
	fi

	# Copy over proxy settings from host machine
	echo -e "\\n${COLOR_ON}Adding proxy info to chroot (if set)...${COLOR_OFF}"
	set +o pipefail
	env | grep -i "_proxy=" | grep -v PERSISTENT_HISTORY_LAST | xargs -i echo export {} | sudo tee "$sysroot/etc/profile.d/steamrtproj.sh"
	env | grep -i "_proxy=" | grep -v PERSISTENT_HISTORY_LAST | xargs -i echo export {} | sudo tee -a "$sysroot/etc/environment"
	set -o pipefail
	sudo rm -rf "$sysroot/etc/apt/apt.conf"
	if [ -f /etc/apt/apt.conf ]; then sudo cp "/etc/apt/apt.conf" "$sysroot/etc/apt"; fi
}

build_chroot()
{
	# build_chroot {--amd64 | --i386} [setup options...]
	# Build a chroot for the specified architecture.

	# Check that we are running in the right environment
	if [[ ! -x $BOOTSTRAP_SCRIPT ]]; then
		echo >&2 "!! Required helper script not found: \"$BOOTSTRAP_SCRIPT\""
	fi

	case "$1" in
		"--i386" )
			pkg="i386"
			personality="linux32"
			;;
		"--amd64" )
			pkg="amd64"
			personality="linux"
			;;
		* )
			echo "Error: Unrecognized argument: $1"
			exit 1
			;;
	esac

	shift
	# Remaining arguments are for $BOOTSTRAP_SCRIPT

	CHROOT_NAME=${CHROOT_PREFIX}${pkg}

	# blow away existing directories and recreate empty ones
	echo -e "\\n${COLOR_ON}Creating ${CHROOT_DIR}/${CHROOT_NAME}..."
	sudo rm -rf "${CHROOT_DIR}/${CHROOT_NAME}"
	sudo mkdir -p "${CHROOT_DIR}/${CHROOT_NAME}"

	# Create our schroot .conf file
	echo -e "\\n${COLOR_ON}Creating /etc/schroot/chroot.d/${CHROOT_NAME}.conf...${COLOR_OFF}"
	printf '[%s]\ndescription=Ubuntu 12.04 Precise for %s\ndirectory=%s/%s\npersonality=%s\ngroups=sudo\nroot-groups=sudo\npreserve-environment=true\ntype=directory\n' "${CHROOT_NAME}" "${pkg}" "${CHROOT_DIR}" "${CHROOT_NAME}" "${personality}" | sudo tee "/etc/schroot/chroot.d/${CHROOT_NAME}.conf"

	# Create our chroot
	echo -e "\\n${COLOR_ON}Bootstrap the chroot...${COLOR_OFF}"
	sudo -E debootstrap --arch="${pkg}" --include=wget --keyring="${SCRIPT_DIR}/ubuntu-archive-keyring.gpg" precise "${CHROOT_DIR}/${CHROOT_NAME}" http://archive.ubuntu.com/ubuntu/

	copy_apt_settings "${CHROOT_DIR}/${CHROOT_NAME}"

	echo -e "\\n${COLOR_ON}Running ${BOOTSTRAP_SCRIPT}$(printf ' %q' "$@")...${COLOR_OFF}"

	# Touch the logfile first so it has the proper permissions
	rm -f "${LOGFILE}"
	touch "${LOGFILE}"

	# The chroot has access to /tmp so copy the script there and run it with --configure
	TMPNAME="$(basename "$BOOTSTRAP_SCRIPT")"
	TMPNAME="${TMPNAME%.*}-$$.sh"
	cp -f "$BOOTSTRAP_SCRIPT" "/tmp/${TMPNAME}"
	chmod +x "/tmp/${TMPNAME}"
	schroot --chroot ${CHROOT_NAME} -d /tmp --user root -- "/tmp/${TMPNAME}" --chroot "$@"
	rm -f "/tmp/${TMPNAME}"
	cp -f "$SCRIPT_DIR/write-manifest" "/tmp/${TMPNAME}"
	chmod +x "/tmp/${TMPNAME}"
	schroot --chroot ${CHROOT_NAME} -d /tmp --user root -- "/tmp/${TMPNAME}" /
	rm -f "/tmp/${TMPNAME}"
}

untar_chroot ()
{
	# untar_chroot {--amd64 | --i386} TARBALL
	# Unpack a sysroot tarball for the specified architecture.

	case "$1" in
		"--i386" )
			pkg="i386"
			personality="linux32"
			;;
		"--amd64" )
			pkg="amd64"
			personality="linux"
			;;
		* )
			echo "Error: Unrecognized argument: $1"
			exit 1
			;;
	esac

	shift

	local tarball="$1"

	CHROOT_NAME="${CHROOT_PREFIX}${pkg}"
	local sysroot="${CHROOT_DIR}/${CHROOT_NAME}"

	# blow away existing directories and recreate empty ones
	echo -e "\\n${COLOR_ON}Creating $sysroot..."
	sudo rm -rf "$sysroot"
	sudo mkdir -p "$sysroot"

	# Create our schroot .conf file
	echo -e "\\n${COLOR_ON}Creating /etc/schroot/chroot.d/${CHROOT_NAME}.conf...${COLOR_OFF}"
	printf '[%s]\ndescription=%s\ndirectory=%s\npersonality=%s\ngroups=sudo\nroot-groups=sudo\npreserve-environment=true\ntype=directory\n' "${CHROOT_NAME}" "${tarball##*/}" "${sysroot}" "${personality}" | sudo tee "/etc/schroot/chroot.d/${CHROOT_NAME}.conf"

	# Create our chroot
	echo -e "\\n${COLOR_ON}Unpacking the chroot...${COLOR_OFF}"
	sudo tar --auto-compress -C "$sysroot" -xf "$tarball"

	copy_apt_settings "$sysroot"

	# We don't run $BOOTSTRAP_SCRIPT here, so reimplement
	# --extra-apt-source.
	if [ -n "${extra_apt_sources+set}" ]; then
		for line in "${extra_apt_sources[@]}"; do
			printf '%s\n' "$line"
		done > "$sysroot/etc/apt/sources.list.d/steamrt-extra.list"
	fi

	if [ -n "$(sudo find "$sysroot" -xdev '(' -uid +99 -o -gid +99 ')' -ls)" ]; then
		echo -e "\\n${COLOR_ON}Warning: these files might have incorrect uid mapping${COLOR_OFF}" >&2
		sudo find "$sysroot" -xdev '(' -uid +99 -o -gid +99 ')' -ls >&2
	fi
}

# http://stackoverflow.com/questions/64786/error-handling-in-bash
function cleanup()
{
	echo -e "\\nenv is:\\n$(env)\\n"
	echo "ERROR: ${SCRIPTNAME} just hit error handler."
	echo "  BASH_COMMAND is \"${BASH_COMMAND}\""
	echo "  BASH_VERSION is $BASH_VERSION"
	echo "  pwd is \"$(pwd)\""
	echo "  PATH is \"$PATH\""
	echo ""

	echo -e "${COLOR_ERROR_ON}A command returned error. See the logfile: ${LOGFILE}${COLOR_OFF}"
}

usage()
{
	if [ "$1" -ne 0 ]; then
		exec >&2
	fi

	echo "Usage: $0 [--force] [--beta | --suite SUITE] [--extra-apt-source 'deb http://MIRROR SUITE COMPONENT...'] [--output-dir <DIRNAME>] [--tarball TARBALL] [--prefix <PREFIX>] --i386 | --amd64"
	exit "$1"
}

main()
{
	local getopt_temp
	getopt_temp="$(getopt -o '' --long \
	'amd64,beta,extra-apt-source:,force,i386,output-dir:,prefix:,suite:,tarball:,help' \
	-n "$0" -- "$@")"
	eval set -- "$getopt_temp"
	unset getopt_temp

	local -a arch_arguments=()
	local -a setup_arguments=()
	local suite=scout
	local suite_suffix=
	local tarball=

	while [ "$#" -gt 0 ]; do
		case "$1" in
			(--amd64|--i386)
				arch_arguments+=("$1")
				shift
				;;

			(--beta)
				setup_arguments+=(--beta)
				suite_suffix=_beta
				shift
				;;

			(--extra-apt-source)
				setup_arguments+=("$1" "$2")
				shift 2
				;;

			(--force)
				INSTALL_FORCE=true
				shift
				;;

			(--help)
				usage 0
				;;

			(--output-dir)
				CHROOT_DIR="$2"
				shift 2
				;;

			(--prefix)
				CHROOT_PREFIX="$2"
				shift 2
				;;

			(--suite)
				suite="$2"
				setup_arguments+=(--suite "$2")
				shift 2
				;;

			(--tarball)
				tarball="$2"
				shift 2
				;;

			(--)
				shift
				break
				;;

			(-*)
				usage 2
				;;

			(*)
				# no non-option arguments are currently allowed
				usage 2
				break
				;;
		esac
	done

	CHROOT_PREFIX="${CHROOT_PREFIX}${suite}${suite_suffix}_"

	case "$suite" in
		(scout*)
			# We still support doing this the hard way for scout
			;;

		(demoman*|engineer*|heavy*|medic*|pyro*|sniper*|soldier*|spy*)
			# The other TF2 class names are reserved for future Steam Runtime
			# versions, which will almost certainly be based on a suite newer
			# than Ubuntu 12.04 'precise', and will almost certainly break
			# assumptions made by scripts/bootstrap-runtime.sh. Require
			# a pre-prepared sysroot tarball instead.
			if [ -z "$tarball" ]; then
				echo "This script cannot bootstrap chroots for future runtime versions." >&2
				echo "Use --tarball to provide a pre-prepared sysroot." >&2
				usage 2
			fi
			;;
	esac

	if [ -z "${arch_arguments+set}" ]; then
		usage 2
	fi

	if [ "${arch_arguments[1]+set}" ] && [ -n "$tarball" ]; then
		echo "Only one of --amd64 or --i386 can be combined with --tarball" >&2
	fi

	# Building root(s)
	prebuild_chroot "${arch_arguments[@]}"
	trap cleanup EXIT
	for var in "${arch_arguments[@]}"; do
		if [ -n "$tarball" ]; then
			untar_chroot "$var" "$tarball"
		else
			build_chroot "$var" ${setup_arguments+"${setup_arguments[@]}"}
		fi
	done
	trap - EXIT

	echo -e "\\n${COLOR_ON}Done...${COLOR_OFF}"
}

# Launch ourselves with script so we can time this and get a log file
# HACKY HACK: disable this, as I can't interact with sudo and enter a password
# when script is redirecting input and output.
#if [[ ! -v SETUP_CHROOT_LOGGING_STARTED ]]; then
#	if command -v script >/dev/null; then
#		export SETUP_CHROOT_LOGGING_STARTED=1
#		export SHELL=/bin/bash
#		script --return --command "time $SCRIPT $(sh_quote "$@")" "${LOGFILE}"
#		exit $?
#	else
#		echo >&2 "!! 'script' command not found, will not auto-generate a log file"
		# Continue to main
#	fi
#fi

main "$@"

# vi: ts=4 sw=4 noexpandtab
