#!/bin/sh
set -eu

# Determine path to script
SCRIPT_PATH="$(dirname "$(readlink -f "$0")")"

# Default configuration
OPENBGPD_CONFIG="/etc/bgpd.conf"
PREFIXSETS_FILE="/etc/filters/openbgpd.conf"
BGPQ3_PATH="/usr/local/bin/bgpq3"
BGPQ3_DEFAULT_SOURCES="RIPE,RADB"
BGPQ3_PREFLEN4_MAX=24
BGPQ3_PREFLEN4_UPTO=24
BGPQ3_PREFLEN6_MAX=48
BGPQ3_PREFLEN6_UPTO=48
MAX_DELTA_PERCENTAGE=20

# Load user configuration if available
if [ -r "${SCRIPT_PATH}/filtergen.conf" ]; then
	set -o allexport
	# shellcheck source=/dev/null
	. "${SCRIPT_PATH}/filtergen.conf"
	set +o allexport
fi

# Additional default configuration (based on previous values)
NEW_PREFIXSETS_FILE="${NEW_PREFIXSETS_FILE:-${PREFIXSETS_FILE}.new}"

# Check if force flag has been passed
ignore_delta="$([ "${1:-}" = "force" ] && echo "yes" || echo "no")"

# Ensure OpenBGPD configuration exists
if [ ! -r "${OPENBGPD_CONFIG}" ]; then
	echo "> Could not read OpenBGPD configuration from [${OPENBGPD_CONFIG}]. Exiting now!"
	exit 1
fi

# Ensure output file exists and is writable
if [ ! -f "${PREFIXSETS_FILE}" ]; then
	echo "> Could not find existing prefixsets file, creating empty file at [${PREFIXSETS_FILE}]..."
	touch "${PREFIXSETS_FILE}"
fi
if [ ! -w "${PREFIXSETS_FILE}" ]; then
	echo "> Could not open prefixsets file for writing, please check your permissions. Exiting now!"
	exit 1
fi

# Ensure bgpq3 exists and is executable
if [ ! -x "${BGPQ3_PATH}" ]; then
	echo "> Could not find bgpq3, ensure [${BGPQ3_PATH}] exists and is executable. Exiting now!"
	exit 1
fi

# Prepare temporary file for generation
genfile="$(mktemp /tmp/filtergen.XXXXXX)"
trap 'rm -f "${genfile}"' EXIT

# Fetch all configured prefix sets
prefixsets="$(sed -En 's/^.*[[:space:]]+prefix-set (irr(4|6)-as([0-9]+))[[:space:]]+#[[:space:]]+([^ \t]+)[[:space:]]*$/\1 ipv\2 \3 \4/p' "${OPENBGPD_CONFIG}")"

# Regenerate all prefix sets
echo "${prefixsets}" | while IFS= read -r line; do
	# Retrieve individual values from peer
	prefixset="$(echo "${line}" | cut -d' ' -sf1)"
	family="$(echo "${line}" | cut -d' ' -sf2)"
	asn="$(echo "${line}" | cut -d' ' -sf3)"
	spec="$(echo "${line}" | cut -d' ' -sf4)"

	# Parse spec to support override of sources
	case "${spec}" in
		*@*)
			irr="$(echo "${spec}" | cut -d@ -sf1)"
			sources="$(echo "${spec}" | cut -d@ -sf2)"
			;;
		*)
			irr="${spec}"
			sources="${BGPQ3_DEFAULT_SOURCES}";
			;;
	esac

	# Print log message about current peer
	echo "> Processing AS${asn} (prefix-set: ${prefixset}, family: ${family}, irr: ${irr}, sources: ${sources})..."

	# Convert special value of "ALL" for sources into empty string which bgpq3 understands as any
	if [ "${sources}" = "ALL" ]; then
		sources=""
	fi

	# Generate prefix filters
	if [ "${family}" = "ipv4" ]; then
		if ! "${BGPQ3_PATH}" -4 -B -A -E -R "${BGPQ3_PREFLEN4_UPTO}" -m "${BGPQ3_PREFLEN4_MAX}" -l "${prefixset}" -S "${sources}" "${irr}" >> "${genfile}"; then
			echo "> Could not generate IPv4 filters for AS${asn}. Exiting now!"
			exit 2
		fi
	elif [ "${family}" = "ipv6" ]; then
		if ! "${BGPQ3_PATH}" -6 -B -A -E -R "${BGPQ3_PREFLEN6_UPTO}" -m "${BGPQ3_PREFLEN6_MAX}" -l "${prefixset}" -S "${sources}" "${irr}" >> "${genfile}"; then
			echo "> Could not generate IPv6 filters for AS${asn}. Exiting now!"
			exit 2
		fi
	fi
done

# Create copy of generated file for manual inspection
cp -f "${genfile}" "${NEW_PREFIXSETS_FILE}"

# Diff against current version and calculate delta
current_lines="$(wc -l "${PREFIXSETS_FILE}" | awk '{$1=$1;print $1}' || exit 0)"
changed_lines="$(sdiff -W -b -s "${PREFIXSETS_FILE}" "${genfile}" | wc -l | awk '{$1=$1;print $1}' || exit 0)"
if [ "${current_lines}" -gt 0 ]; then
	delta_percentage="$((changed_lines * 100 / current_lines))"
else
	delta_percentage=100
	ignore_delta="yes"
fi
echo "> Statistics: Changed ${changed_lines} of ${current_lines} lines with ${delta_percentage}% delta"

# Abort if delta is zero
if [ "${delta_percentage}" -eq "0" ] && [ "${changed_lines}" -eq "0" ]; then
	echo "> The generated file has been placed at [${NEW_PREFIXSETS_FILE}] for manual inspection."
	echo "> Everything already up-to-date, exiting now..."
	exit 0
fi

# Abort if delta is above threshold and not being ignored
if [ "${ignore_delta}" != "yes" ] && [ "${delta_percentage}" -gt "${MAX_DELTA_PERCENTAGE}" ]; then
	echo "> Too many changes (over ${MAX_DELTA_PERCENTAGE}% delta), aborting generation..."
	echo "> The generated file has been placed at [${NEW_PREFIXSETS_FILE}] for manual inspection."
	echo "> Run as [${0} force] to force generation. Exiting now!"
	exit 3
fi

# Generate fake config for standalone verification
tmpcfg="$(mktemp /tmp/filtergen.XXXXXX)"
trap 'rm -f "${tmpcfg}"' 0 2 3 15
echo "AS 1" > "${tmpcfg}"
cat "${genfile}" >> "${tmpcfg}"

echo "> Verifying built configuration..."
if ! bgpd -nf "${tmpcfg}"; then
	echo "> Could not verify configuration, please check the output..."
	cat "${tmpcfg}"
	echo "> The generated file has also been placed at [${NEW_PREFIXSETS_FILE}] for manual inspection."
	echo "> Exiting now!"
	exit 4
fi

# Backup and update daemon configuration
cp -p "${PREFIXSETS_FILE}" "${PREFIXSETS_FILE}.bak"
mv "${genfile}" "${PREFIXSETS_FILE}"

# Verify whole configuration for extra safety
echo "> Verifying final configuration..."
if ! bgpd -n; then
	echo "> Could not verify final configuration, please check the output..."
	echo "> The generated file has also been placed at [${NEW_PREFIXSETS_FILE}] for manual inspection."
	echo "> Restoring old config and exiting now!"
	mv "${PREFIXSETS_FILE}.bak" "${PREFIXSETS_FILE}"
	exit 4
fi

# Remove previous copy of generated configuration
if [ -f "${NEW_PREFIXSETS_FILE}" ]; then
	rm -f "${NEW_PREFIXSETS_FILE}"
fi

# Reload daemon configuration
echo "> Reloading BGP daemon..."
if ! bgpctl reload; then
	echo "> Could not reload BGP daemon. Exiting now!"
	exit 5
fi

# Inform about completion
echo "> Successfully updated filters. Exiting now..."
