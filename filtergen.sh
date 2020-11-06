#!/bin/sh
set -euo pipefail

# Configuration
OPENBGPD_CONFIG="/etc/bgpd.conf"
PREFIXSETS_FILE="/etc/filters/openbgpd.conf"
MAX_DELTA_PERCENTAGE=20

# Prepare temporary file for generation
genfile="$(mktemp /tmp/filtergen.XXXXXX)"
trap "rm -f '${genfile}'" EXIT

# Fetch all configured prefix sets
prefixsets="$(sed -En 's/^.*[[:space:]]+prefix-set (irr(4|6)-as([0-9]+))[[:space:]]+#[[:space:]]+([^ \t]+)[[:space:]]*$/\1 ipv\2 \3 \4/p' "${OPENBGPD_CONFIG}")"

# Regenerate all prefix sets
echo "${prefixsets}" | while IFS= read -r line; do
	# Retrieve individual values from peer
	prefixset="$(echo "${line}" | cut -d' ' -sf1)"
	family="$(echo "${line}" | cut -d' ' -sf2)"
	asn="$(echo "${line}" | cut -d' ' -sf3)"
	irr="$(echo "${line}" | cut -d' ' -sf4)"

	# Print log message about current peer
	echo "> Processing AS${asn} (prefix-set: ${prefixset}, family: ${family}, irr: ${irr})..."

	# Generate prefix filters
	if [ "${family}" = "ipv4" ]; then
		if ! /usr/local/bin/bgpq3 -4 -B -A -E -R 24 -l "${prefixset}" -S RIPE,RADB "${irr}" >> "${genfile}"; then
			echo "> Could not generate IPv4 filters for AS${asn}, exiting now..."
			exit 1
		fi
	elif [ "${family}" = "ipv6" ]; then
		if ! /usr/local/bin/bgpq3 -6 -B -A -E -R 48 -l "${prefixset}" -S RIPE,RADB "${irr}" >> "${genfile}"; then
			echo "> Could not generate IPv6 filters for AS${asn}, exiting now..."
			exit 1
		fi
	fi
done

# Diff against current version and calculate delta
current_lines="$(wc -l "${PREFIXSETS_FILE}" | awk '{$1=$1;print $1}' || exit 0)"
changed_lines="$(sdiff -W -b -s "${PREFIXSETS_FILE}" "${genfile}" | wc -l | awk '{$1=$1;print $1}' || exit 0)"
if [ "${current_lines}" -gt 0 ]; then
	delta_percentage="$((changed_lines * 100 / current_lines))"
else
	delta_percentage=100
fi
echo "> Statistics: Changed ${changed_lines} of ${current_lines} lines with ${delta_percentage}% delta"

# Abort if delta is zero
if [ "${delta_percentage}" -eq "0" ]; then
	echo "> Everything already up-to-date, exiting now..."
	exit 0
fi

# Abort if delta is above threshold and force has not been specified
if [ "${1:-}" != "force" ] && [ "${delta_percentage}" -gt "${MAX_DELTA_PERCENTAGE}" ]; then
	echo "> Too many changes (over ${MAX_DELTA_PERCENTAGE}% delta), aborting generation..."
	echo "> Run as [${0} force] to force generation. Exiting now!"
	exit 2
fi

# Generate fake config for standalone verification
tmpcfg="$(mktemp /tmp/filtergen.XXXXXX)"
trap "rm -f '${tmpcfg}'" 0 2 3 15
echo "AS 1" > "${tmpcfg}"
cat "${genfile}" >> "${tmpcfg}"

echo "> Verifying built configuration..."
if ! bgpd -nf "${tmpcfg}"; then
	echo "> Could not verify configuration, please check the output..."
	cat "${tmpcfg}"
	echo "> Exiting now!"
	exit 3
fi

# Backup and update daemon configuration
cp -p "${PREFIXSETS_FILE}" "${PREFIXSETS_FILE}.bak"
mv "${genfile}" "${PREFIXSETS_FILE}"

# Verify whole configuration for extra safety
echo "> Verifying final configuration..."
if ! bgpd -n; then
	echo "> Could not verify final configuration, please check the output..."
	echo "> Restoring old config and exiting now!"
	mv "${PREFIXSETS_FILE}.bak" "${PREFIXSETS_FILE}"
	exit 4
fi

# Reload daemon configuration
echo "> Reloading BGP daemon..."
if ! bgpctl reload; then
	echo "> Could not reload BGP daemon, exiting now!"
	exit 5
fi

# Inform about completion
echo "> Successfully updated filters, exiting now..."
