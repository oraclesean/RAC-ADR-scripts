#!/bin/bash

#----------------------------------------------------------------------------------------#
#                                                                                        #
# Manage Oracle Database and GI logs via TFA                                             #
# Copyright (C) Viscosity NA, 2020                                                       #
# Author: Sean Scott (sean.scott@viscotityna.com)                                        #
#                                                                                        #
# Pass the following parameters at the command line:                                     #
#      1: Filesystem to be inspected (/u01/app/oracle)                                   #
#      2: Warning threshold percent (numeric). If the use % of the filesystem exceeds    #
#         the warning threshold, TFA is invoked to identify file consumption.            #
#      3: Critical threshold percent (numeric). If the use % of the filesystem exceeds   #
#         the critical threshold, TFA is invoked to purge files older than the specified #
#         number of days.                                                                #
#      4: Maximum age, in days, of files to keep (numeric). Files older than this will   #
#         be purged when the critical threshold is met.                                  #
#      5: Log file directory where logs session logs are written.                        #
#                                                                                        #
#----------------------------------------------------------------------------------------#


logger() {
  printf "$@ \n" | tee -a $logfile
}

error() {
  printf "ERROR: $@ \nExiting...\n" | tee -a $logfile
  exit 1
}

report() {
     if [ ! -z "$4" ]
   then _size=$(echo $4 | numfmt --to=si)
   fi

     if [ "$1" == "REPORT" ]
   then logger "Filesystem $2 is ${3}%% used.\nSkipping... (Warning threshold = ${warn}%%)\n"
   elif [ "$1" == "WARN" ]
   then logger "Filesystem $2 is ${3}%% used.\nWarning threshold (${warn}%%) exeeded!\n"
   elif [ "$1" == "CRIT" ]
   then logger "Filesystem $2 is ${3}%% used.\nCritical threshold (${crit}%%) exceeded!\nPreparing to purge...\n"
        purge=1
   elif [ "$1" == "CLUSTER" ]
   then logger "Filesystem $2: Cluster use = ${_size}\n"
   elif [ "$1" == "HOST" ]
   then logger "Filesystem $2: Host use = ${_size}\n"
   elif [ "$1" == "HOME" ]
   then logger "Filesystem $2: $3 home use = ${_size}"
   fi
}

  if [ -z "$1" ]
then error "A filesystem must be provided"
elif [ ! -d "$1" ]
then error "$1 is not a valid filesystem"
else fs=$1
fi

  if [ -z "$2" ]
then error "A warning threshold must be provided"
elif [[ ! $2 =~ [0-9]* ]]
then error "The warning threshold is not numeric"
elif [ "$2" -gt 99 -o "$2" -lt 1 ]
then error "The warning threshold must be between 1 and 99"
else warn=$2
fi

  if [ -z "$3" ]
then error "A critical threshold must be provided"
elif [[ ! $3 =~ [0-9]* ]]
then error "The critical threshold is not numeric"
elif [ "$3" -gt 99 -o "$3" -lt 1 ]
then error "The critical threshold must be between 1 and 99"
elif [ "$3" -le "$2" ]
then error "The critical threshold must be greater than the warning threshold"
else crit=$3
fi

  if [ -z "$4" ]
then error "A file age threshold must be provided"
elif [[ ! $4 =~ [0-9]* ]]
then error "The age threshold is not numeric"
elif [ "$4" -le 7 ]
then error "The age threshold cannot be less than 7 days"
else limit=$4
fi

  if [ -z "$5" ]
then error "A directory for logs must be provided"
elif [ ! -d "$5" ]
then error "$5 is not a valid filesystem"
elif [ ! -w "$5" ]
then error "The directory $5 is not writeable"
else logdir=$5
fi

# Create the log file:
logfile=$logdir/$(basename $0).$(date "+%Y%m%d%H%M").log

# The purge flag is set if the critical threshold is exceeded
unset purge

# Create a temporary file for TFA output
tfaoutput=$(mktemp)

# Show usage from TFA
tfactl managelogs -show usage > $tfaoutput
  if [ "$?" -ne 0 ]
then error "There was a problem running TFA managelogs -show usage\nSee $logfile for details"
fi

while read df
   do mount=$(echo $df | awk '{print $NF}')
      usage=$(echo $df | awk '{print $(NF-1)}' | sed "s|%||")

      # Check filesystem use and set "action" if a WARN or CRIT condition is encountered
      unset action

         if [ "$usage" -lt "$warn" ]
       then report REPORT $mount $usage
            unset action
       elif [ "$usage" -ge "$crit" ]
       then action=CRIT
       elif [ "$usage" -ge "$warn" ]
       then action=WARN
       fi

       # An action was triggered. Get filesystem use for the provided mount point
         if [ ! -z "$action" ]
       then report $action $mount $usage

            # Clean variables
            cluster_total=0
            host_total=0
            home_total=0
            unset host_name
            unset _host_name
            unset home_type
            unset _home_type

            # Report total use for each node and home
            while read tfa
               do # Limit case-sensitive checks in case TFA output changes
                  line=${tfa^^}

                  # Parse output
                     if [[ $line =~ ^HOST ]]
                  then # This line identifies the host.
                       host_name=$(echo $line | cut -d= -f2)
                       echo "In host test ($host_name) ($_host_name)"

                         if [ -z "$_host_name" ]
                       then # The host tracker is not set. This is the top of the
                            # output and node 0 in the cluster.
                            node_num=0
                       elif [ ! -z "$_host_name" ] && [ "$host_name" != "$_host_name" ]
                       then # This is not the first host in the cluster. The host has
                            # changed. Before resetting the subtotals, report space use
                            # for the prior host and home.
                            report HOME $mount $_home_type $home_total
                            report HOST $mount $_host_name $host_total

                            # Increment the node and clear host and home totals.
                            node_num=$((node_num + 1))
                            host_total=0
                            home_total=0
                       fi

                       # Set the host tracker to the current host, whether this is the
                       # first pass or a new host. When the host changes, the home type
                       # will change also. Unset the home type tracker.
                       _host_name=$host_name
                       unset _home_type

                  elif [[ $line =~ ^(GRID|DATABASE)$ ]]
                  then # This is a new home.
                       home_type=$line
                       echo "     In home test ($home_type) ($_home_type)"

                         if [ ! -z "$_home_type" ] && [ "$home_type" != "$_home_type" ]
                       then # The home has changed. Before moving on, report space use in
                            # the prior home and 0 out the subtotal.
                            report HOME $mount $_home_type $home_total
                            home_total=0
                       fi

                       # Set the home tracker to the current home type.
                       _home_type=$home_type
                       echo "     Set Home type ($_home_type)"

                  elif [[ $tfa =~ ^$mount.* ]]
                  then # The line represents a directory in the prescribed path. Get the
                       # directory name and format space use as a number.
                       dirname=$(echo $tfa | awk '{print $1}')
                       size=$(echo $line | awk '{print $2 $3}' | numfmt --from auto)

                       # Increment totals for cluster, host and home
                       cluster_total=$((cluster_total + size))
                       host_total=$((host_total + size))
                       home_total=$((home_total + size))
                  fi

             done < <(cat $tfaoutput | \
                          egrep -i "Output from host|^\|.* Usage|^\|.*$mount" | \
                          sed -e "s|\(\|\s*\)\(.*\)\(\s*\|\s*\)|\2|" \
                              -e "s|.*Output from host\s*:\s*|Host=|" \
                              -e "s|\(.*\)\s.*\sUsage.*$|\1|" \
                              -e "s|\(^${mount}.*\)\(\s*\|\s*\)\(.*\)\([B|b]\)\(.*$\)|\1\3|")

                             # Get lines that contain the host name, the HOME,
                             # and directories with the defined mount point
#                             egrep -i "Output from host|^\|.* Usage|^\|.*$mount" | \
                             # Clean up TFA formatting: Remove leading and trailing pipe (|) characters
#                             sed -e "s/\(|\s*\)\(.*\)\(\s*|\s*\)/\2/" \
                             # Clean up TFA formatting: Parse the line containing the host name
#                                 -e "s/.*Output from host\s*:\s*/Host=/" \
                             # Clean up TFA formatting: Parse the line with the HOME type (GI, DB)
#                                 -e "s/\(.*\)\s.*\sUsage.*$/\1/" \
                             # Clean up TFA formatting: For lines that match the filesystem, remove the
                             #       pipes and all but one character of the byte multiplier (if present)
                             #       and "bytes" from the output to give just the directory and its
                             #       size (in bytes, K, M, G, T)
#                                 -e "s|\(^${mount}.*\)\(\s*\|\s*\)\(.*\)\([B|b]\)\(.*$\)|\1\3|")
             done < <(cat tfaout)

            # The loop is complete; report subtotals for the last home and host
            # and the total for the cluster
            report HOME $mount $_home_type $home_total
            report HOST $mount $_host_name $host_total
            report CLUSTER $mount 0 $cluster_total
            logger "Running tfactl to show variations in files older than $limit days:\n"
            tfactl managelogs -show variation -older ${limit}d -node all | tee -a $logfile
            logger "Running tfactl to preview purging of files older than $limit days:\n"
            tfactl managelogs -purge -older ${limit}d -dryrun -node all | tee -a $logfile

      fi

 done < <(df -P $fs | grep %)

         if [ "$purge"  ]
       then logger "Purging TFA logs!\n"
            logger "Running tfactl to purge files older than $limit days:\n"
#            tfactl managelogs -purge -older ${limit}d -node all  # | tee -a $logfile
       fi

# Remove the temporary TFA output file
rm $tfaoutput
