# RAC-ADR-scripts
Scripts for managing RAC, GI, AHF/TFA, and ADR. These were developed for troubleshooting a specific Exadata environment and therefore may not work in yours. They are therefore for information/education purposes only. You assume all risk if you choose to run these in your own environment. Since these scripts will potentially delete files and/or reconfigure the environment, be sure you understand fully what these scripts do.

## `check_services.sh`
Reports services that are not running on their assigned/preferred instance.

## `purge_tfa.sh`
This script runs `tfactl managelogs` against the (provided) ADR home directory, reporting (and optionally purging based on file age).

## `purge_adr.sh`
This script resports a handful of issues that prevent AHF/TFA from managing and purging files within the ADR. Features:
- Generates a report for ADR directories, showing directories, their total size, the total file count, and counts of files over 60, 30, 14, and 7 days old. If files are older than the ADR retention policy, it may be an indication that ADR can't properly manage files.
- Reports the ADR schema and library versions, and warns if there is a mismatch. The script will attempt to correct the issue my migrating the schema.
- Reports/sets the long and short ADR retention policies.
- Checks for files and directories with incorrect permissions. If directories (or subdirectories) under an ADR_HOME are not owned by `oracle` or `grid` or if they do not belong to the `dba` group, ADR won't be able to manage anything beyond that path. This may allow files to accumulate and potentially fill the filesystem.
- Purges files older than a given retention age. ADR, by design, does not automatically purge files from certain directories. The script loops over the directory structure, purging files, and showing the space use before and after.
- Discovers and processes all ADR homes present on the host, checking for:
  - Obsolete schema versions
  - Homes owned by an orphaned CRS user
  - Listener homes that may be associated with a non-existent listener
  - Listener homes for a listener that isn't running on the host
  - ADR homes not owned by `oracle` or `grid`
  - ADR homes for ORACLE_SID not present in the `oratab`
  - ADR homes for instances with unique names not based on the SID
  - Multiple ADR homes for a single SID
  - Non-RDBMS ADR homes
- Scans the `oratab` and checks for:
  - SID are not running on the host
  - Duplicate SID
  - Instance with non-existent ADR
  - Confirms that the expected ADR log directories exist and creates them if missing
  - Checks for the ADR configuration file, verifies that it contains the correct directories, and creates if missing

## adr_check.sh
Similar to `purge_adr.sh`, this script processes the ADR homes on the host and checks for:
- ADR library and schema versions match, attempting to resolve any mismatch
- ADR directories with obsolete schema versions
- Directories under orphaned CRS homes
- Directories with incorrect ownership
- Directories for inactive listeners
- Directories for SIDs not present in the oratab
- RDBMS homes with mismatched SID/unique names
- Multiple ADR homes for a SID or unique name
- Non-RDBMS ADR homes
- SID not running on the host
- Multiple SID in the oratab
- Missing ADR repositories
- Missing ADR log/diagnostic directory, missing configuration file
- ADR configurations with incorrect paths

## NOTE
`adr_check.sh` and `purge_adr.sh` are similar scripts that were developed to address slightly different needs, but are likely similar if not interchangeable.
