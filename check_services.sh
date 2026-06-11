#!/bin/bash

# Check for services not running on their assigned/preferred instances
#
# Author: Sean Scott, Viscosity NA
# Date:   December 18, 2019
#
# Notes:
#

error()
{
  echo "$@" 1>&2
  exit 1
}

sort_instances()
{
  # Read and sort a comma-delimited list
  IFS=',' read -r -a array <<< "$1"
  for i in "${!array[@]}"
  do
     echo "${array[i]}"
  done | sort | xargs -n"${#array[@]}"
}

err=

# Find the oratab file:
  if [ -f "/etc/oratab" ]
then ORATAB=/etc/oratab
elif [ -f "/var/opt/oracle/oratab" ]
then ORATAB=/var/opt/oracle/oratab
else error "No oratab file found"
fi

# Get the list of ORACLE_HOMEs on the host. Running srvctl from an incompatible home
# can throw an error.
for ORACLE_HOME in $(egrep -v '^$|^#|^\+' $ORATAB | cut -f2 -d: | sort | uniq)
 do

    export ORACLE_HOME=$ORACLE_HOME

    # Get the list of databases running on the host by running srvctl from each ORACLE_HOME
    for ORACLE_SID in $($ORACLE_HOME/bin/srvctl config database)
     do

        # Is there a running instance to match the SID?
        if [ $(ps -ef | egrep ${ORACLE_SID} | grep pmon | wc -l) -eq 1 ]
        then

             # Get a list of services for each database and their preferred node
             while read service_name node_list
             do

                # Only check for preferred, running instances when there's a configured service
                if [ ! -z "$service_name" ]
                then

                     # Get the sorted list of preferred instances
                     preferred_instance=$(sort_instances $node_list)
                     service_status=$($ORACLE_HOME/bin/srvctl status service -db $ORACLE_SID -service $service_name)

                     # Check to see if the service is running
                     if [ "$(echo $service_status | grep -i "is not running")" ]
                     then echo "Service $service_name on database $ORACLE_SID is not running. It is configured to run on instance(s) $preferred_instance"
                          err=1

                     # Get the sorted list of running instances
                     else running_instance=$(sort_instances $(echo $service_status | awk '{print $NF}'))

                          # Compare the preferred and running instance lists
                          if [ ! "$preferred_instance" = "$running_instance" ]
                          then echo "Service $service_name on database $ORACLE_SID is running on instance(s) $running_instance. It is configured to run on instance(s) $preferred_instance"
                               err=1
                          fi
                     fi
                fi

             done <<< "$($ORACLE_HOME/bin/srvctl config service -db $ORACLE_SID | egrep -i "^service name|^preferred instances" | xargs -n2 -d'\n' | awk '{print $3, $NF}')"

        # The instance is not running:
        else echo "Database $ORACLE_SID is not running."
             echo " "
        fi

        # If there was a misaligned service, report the database status
        if [ ! -z "$err" ]
        then $ORACLE_HOME/bin/srvctl status database -db $ORACLE_SID
        echo " "
        err=
        fi

    done # End of ORACLE_SID loop

done # End of ORACLE_HOME loop
