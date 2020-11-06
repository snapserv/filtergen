# filtergen

## Summary
This script parses the OpenBGPD configuration file to automatically determine which prefix sets are required to filter one or more BGP peers. For this script to work properly, your filter configuration should look like this:

```
# AS3856 - Packet Clearing House
allow quick from AS 3856 prefix-set irr4-as3856 # AS-PCH
allow quick from AS 3856 prefix-set irr6-as3856 # AS-PCH

# AS6939 - Hurricane Electric
allow quick from AS 6939 prefix-set irr4-as6939 # AS-HURRICANE
allow quick from AS 6939 prefix-set irr6-as6939 # AS-HURRICANEv6
```

This will result in generating 4 prefix sets in total:

- **irr4-as3856** will contain all IPv4 prefixes for the given AS macro `AS-PCH`
- **irr6-as3856** will contain all IPv6 prefixes for the given AS macro `AS-PCH`
- **irr4-as6939** will contain all IPv4 prefixes for the given AS macro `AS-HURRICANE`
- **irr6-as6939** will contain all IPv6 prefixes for the given AS macro `AS-HURRICANEv6`

All the prefix data is being fetched using bgpq3, which can be installed using `pkg_add(1)`. Aside from this dependency, the script should work out of the box on OpenBSD 6.8 systems.

## Usage
You can either deploy this script to the recommended path `/etc/filters/filtergen.sh` or pick your own path and adjust the configuration (see next section) accordingly. You may then start by manually running the script once to generate an initial output file. Please note that while this output file is not being included into your BGP configuration yet, `bgpctl reload` will still get triggered once generation has completed!

Once you are happy with the contents of your initial output file it can be included into the main OpenBGPD configuration, e.g. by adding this line to `/etc/bgpd.conf`:

```
include "/etc/filters/openbgpd.conf"
```

Now whenever the script is being launched, all prefix filters get updated and OpenBGPD gets automatically reloaded once the updated prefix sets are in place. You can automate this procedure using a regular crontab, e.g.:

```
~	*	*	*	*	-ns /bin/sh /etc/filters/filtergen.sh
```

Please note that the script will never update the existing prefix sets and exit with an error if the delta compared to the current file is greater than `MAX_DELTA_PERCENTAGE` percent, which defaults to `20` percent. You may change this by updating the configuration file (see next section) or temporarily override this safety feature by calling the script with the argument `force`.

## Configuration
This script has a sane default configuration which can be used without further changes when being deployed to `/etc/filters/filtergen.sh`. Should your specific setup require any overrides, you can create a configuration file `filtergen.conf` in the same directory as the script. Each line should only contain a `KEY=VALUE` mapping, e.g.:

```
BGPQ3_SOURCES="RIPE"
MAX_DELTA_PERCENTAGE=25
```

All available configuration options can be found by checking the top of the script.

## Recognized Syntax
The script only recognizes lines with one of the following patterns:

```
<anything><whitespace>prefix-set irr4-as<AS NUMBER><whitespace>#<whitespace><AS MACRO><optional whitespace><end of line>
<anything><whitespace>prefix-set irr6-as<AS NUMBER><whitespace>#<whitespace><AS MACRO><optional whitespace><end of line>
```

You must strictly adhere to this syntax for this script to work.

## Task Sequence
The script implements several safe guards and follows this sequence:

1. Ensure OpenBGPD configuration file can be read
2. Ensure output file exists and create if missing
3. Ensure output file is writable
4. Ensure bgpq3 exists and is executable
5. Parse OpenBGPD configuration file to gather required prefix sets
6. Generate all prefix-sets into temporary file using bgpq3
7. Calculate delta against existing configuration file and abort if above threshold (unless `force` has been used)
8. Create a temporary minimal configuration with only the prefix sets and validate it with `bgpd`
9. Create a backup of the existing output file
10. Write new output file and validate it whole system configuration with `bgpd`. Rollback previous version on failure.
11. Trigger `bgpctl reload` to apply the new configuration.
