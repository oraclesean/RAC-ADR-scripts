#!/bin/bash

#----------------------------------------------------------------------------------------#
#  adrcheck.sh                                                                           #
#                                                                                        #
#   Author: Sean Scott, Viscosity North America                                          #
#     Date: 2022-02-27                                                                   #
#  Purpose: Clean up ADR home directories                                                #
#                                                                                        #
#----------------------------------------------------------------------------------------#

# Pass the notification email in the first parameter:
notification_email=$1

# Pass the maximum age of files to retain in the second parameter (optional; default=14)
age=${2:-14}
adr_age=$(($age * 24))
errfile=$(mktemp -t $(hostname)_$(whoami)_$(date '+%Y%m%d%H%M').XXXX.err)
outfile=$(mktemp -t $(hostname)_$(whoami)_$(date '+%Y%m%d%H%M').XXXX.out)

# Check whether this is the GRID user:
# Get the names of all running instances:
 if [ "$(whoami)" = "grid" ]
then . oraenv <<< $(ps -ef | egrep "$(whoami).*pmon.*ASM" | grep -v grep | awk '{print $NF}' | cut -d_ -f3-)
else . oraenv <<< $(ps -ef | grep pmon | egrep -v "grep|+A|-MGMT" | head -1 | awk '{print $NF}' | cut -d_ -f3-)
fi

# Set the assumed ADR base:
adr_base="/u01/app/$(whoami)"
ADR=$ORACLE_HOME/bin/adrci

# Standard functions:
logger() {
   if [ -z "$2" ]; then printf "\n"; fi
 printf "$1 \n" | tee -a $outfile
}

error() {
   if [ -z "$2" ]; then printf "\n"; fi
 printf "$1 \n" | tee -a $errfile
}

print_string() {
 v=$(printf "%-${1}s" " ")
 echo "${v// /${2}}"
}

# Set policy function:
set_policy() {
 local __policy="${4,,} policy"
 local __POLICY="${4^^}P_POLICY"
 local __age=$(($1+0))
 local __current=$(($2+0))
   if [ "$__current" -ne "$__age" ]
 then logger "INFO: Updating the $__policy from $__current to $__age."
      rc="$($ADR exec="set base $adr_base;set homepath $3;set control \(${__POLICY}=$__age\)" | egrep -c "^DIA-")"
 else logger "PASS: The $__policy is already set to $__age"
 fi
}

# File stat function:
dostat() {
 stat -c '%A User: %U/%u Group: %G/%g %y %n' $1 | sort -u
}

# Print directory space use function:
dodu() {
 logger "Space ${1,,} ($(date '+%Y-%m-%d %H:%M'))" 1
 printf "%-40s %10s %8s %8s %8s %8s %8s %8s\n" "Subdirectory" "Size (KB)" "60+ Days" "30+ Days" "14+ Days" "7+ Days" "All" | tee -a $outfile
 printf -- "---------------------------------------- ---------- -------- -------- -------- -------- --------\n" | tee -a $outfile
  for d in $(find $2 -maxdepth 1 -type d | sort)
   do d_kbs=$(du -s $d 2>/dev/null | awk '{print $1}')
      d00=$(find $d/* -type f 2>/dev/null | wc -l)
      d60=$(find $d/* -type f -mtime +60 2>/dev/null | wc -l)
      d30=$(find $d/* -type f -mtime +30 2>/dev/null | wc -l)
      d14=$(find $d/* -type f -mtime +14 2>/dev/null | wc -l)
      d07=$(find $d/* -type f -mtime +7  2>/dev/null | wc -l)
      printf "%-40s %10d %8d %8d %8d %8d %8d\n" "${d##*/}" $d_kbs $d60 $d30 $d14 $d07 $d00 | tee -a $outfile
 done
}

# Check home function:
check_home() {
 local __adr_home="$1"
 unset rc
 logger "Checking ADR Home $__adr_home:" 1
 v=($($ADR exec="set base $adr_base;set home $__adr_home;show version schema" | grep -i "Schema version" | awk '{print $NF}' | tr '/n' ' '))
   if [ -z "${v[0]}" ] || [ -z "${v[1]}" ]
 then logger "WARN: Error obtaining schema versions"
      rc=1
 elif [ "${v[0]}" = "${v[1]}" ]
 then logger "PASS: The schema version and library versions match (${v[0]})."
      rc=0
 else logger "WARN: The schema version (${v[0]}) does not match the library version (${v[1]})."
      logger "INFO: Attempting to migrate the schema..."
        if [ "${v[0]}" -gt "${v[1]}" ]
      then downgrade="-downgrade"
      else unset downgrade
      fi
      rc="$($ADR exec="set base $adr_base;set home $__adr_home;migrate schema $downgrade" | egrep -c "^DIA-")"
      $ADR exec="set base $adr_base;set home $__adr_home;show version schema" | tee -a $outfile
 fi
   if [ "$rc" != "0" ]
 then logger "WARN: The schema version was not migrated!"
 else p=($($ADR exec="set base $adr_base;set home $__adr_home;show control" | egrep -v "^ADR|^\*|^-|^$|fetched" | awk '{print $2, $3}'))
      set_policy "$adr_age" "${p[0]}" "$adr_home" "short"
      set_policy "$adr_age" "${p[1]}" "$adr_home" "long"
 fi

#  logger "Checking for unmanaged files and directories..." 1
#   for f in $(find ${adr_base}/${__adr_home} \( ! -user oracle -a ! -user grid \) -a \( ! -group dba -a ! -perm g+x \) -print 2>/dev/null | sort -u)
#    do error "$f"; dostat "$f" 2>/dev/null || error "$(dostat "${f%/*}")"
#  done

   if [ "$rc" = "0" ]
 then logger "INFO: Purging files..." 1
      dodu "before" "${adr_base}/${__adr_home}"
      logger "Purging files older than $age days"
       for t in CDUMP INCIDENT UTSCDMP ALERT TRACE HM
        do logger "   Purging $t ($(date '+%Y-%m-%d %H:%M'))"
           $ADR exec="set base $adr_base;set home $__adr_home;purge -age $adr_age -type $t" | tee -a $outfile
      done
      find "${adr_base}/${__adr_home}"/* -type f -mtime +"${age}" -delete
      dodu "after" "${adr_base}/${__adr_home}"
      logger " "
 else logger " "; dodu "used" "${adr_base}/${__adr_home}"
 fi
}

error_check() {
 while read adr_home
    do # Get the most notable exception for each directory
       # Don't repeat the directories; place them in condition-specific arrays
         if [[ ${adr_home##*/} =~ [0-9]*_(82|107) ]]
       then e1+=("${adr_base}/${adr_home}")
       elif [ "$(egrep -c "^${adr_home##*/crs_}:" /etc/passwd)" -gt 0 ]
       then e2+=("${adr_base}/${adr_home}")
       elif [[ ${adr_home} =~ /user_ ]] && ! [[ ${adr_home} =~ (user_grid|user_oracle) ]]
       then e3+=("${adr_base}/${adr_home}")
       elif [[ ${adr_home} =~ /tnslsnr/ ]] && ! [[ ${adr_home} =~ (/listener_scan|/mgmtlsnr) ]] && [ "$(ps -ef | grep tns | grep -v grep | egrep -ic "${adr_home##*/}")" -eq 0 ]
       then e4+=("${adr_base}/${adr_home}")
       elif [[ ${adr_home} =~ /rdbms/ ]] && ! [[ ${adr_home} =~ /-MGMTDB ]] && [ "$(egrep -ci "^${adr_home##*/}:" /etc/oratab)" -eq 0 ]
       then e5+=("${adr_base}/${adr_home}")
       fi
  done < <($ADR exec="set base $adr_base;show homes" | egrep -v "^$|ADR Home" | sort)

  # Loop over the arrays and print summaries for each error (if present)
   if [ ${#e1[@]} -gt 0 ]; then error "Directories for obsolete schema versions:" 1
       for i in "${e1[@]}"; do error $i; done; fi
   if [ ${#e2[@]} -gt 0 ]; then error "Directories for orphaned CRS homes:" 1
       for i in "${e2[@]}"; do error $i; done; fi
   if [ ${#e3[@]} -gt 0 ]; then error "Non-grid/oracle user directories:" 1
       for i in "${e3[@]}"; do error $i; done; fi
   if [ ${#e4[@]} -gt 0 ]; then error "Directories for inactive listeners:" 1
       for i in "${e4[@]}"; do error $i; done; fi
   if [ ${#e5[@]} -gt 0 ]; then error "RDBMS directories for SID not present in /etc/oratab:" 1
       for i in "${e5[@]}"; do error $i; done; fi

 # Report RDBMS homes with mismatched SID/DBUN:
 local __header_flag=
 while read adr_home
    do
         if [[ ${adr_home} =~ /diag/rdbms ]] && ! [[ $(echo ${adr_home,,} | cut -d/ -f4) =~ $(echo ${adr_home,,} | cut -d/ -f3) ]]
       then
              if [ -z "$__header_flag" ]
            then error "RDBMS directories with mismatched DBUN/SID:" 1
                 local __header_flag=1
            fi
            error "${adr_base}/${adr_home}"
       fi
  done < <($ADR exec="set base $adr_base;show homes" | egrep "/rdbms/[A-Za-z0-9]" | sort)

 # Report RDBMS homes with multiple SIDs per DBUN:
 while read dbun
    do error "Multiple ADR homes exist for DB unique name ${dbun}:" 1
       $ADR exec="set base $adr_base;show homes" | egrep "/rdbms/${dbun}/" | sed 's/^/$adr_base/g' | tee -a $errfile
  done < <($ADR exec="set base $adr_base;show homes" | egrep "/rdbms/[A-Za-z0-9]" | sort | cut -d/ -f3 | uniq -c | awk '$1 > 1 {print $2}')

 local __header_flag=
 while read adr_home
    do
        for f in $(find ${adr_base}/${__adr_home} \( ! -user oracle -a ! -user grid \) -a \( ! -group dba -a ! -perm g+x \) -print 2>/dev/null | sort -u)
         do
              if [ -z "$__header_flag" ]
            then error "Directories with incorrect ownership:" 1
                 local __header_flag=1
            fi
            error "$f"; dostat "$f" 2>/dev/null || error "$(dostat "${f%/*}")"
       done
       bad_owner+="${adr_home}" # Populate an array of directories with incorrect ownership
  done < <($ADR exec="set base $adr_base;show homes" | egrep -v "^$|ADR Home" | sort)
}

logger "Disk use in $adr_base before:" 1
df -hP $adr_base | tee -a $outfile
logger "INFO: All ADR Home directories:" 1
$ADR exec="set base $adr_base;show homes" | tee -a $outfile

error_check

# Check the non-RDBMS ADR Homes under this base:
while read adr_home
  do check_home "$adr_home"
done < <($ADR exec="set base $adr_base;show homes" | egrep -v "/rdbms/[A-Za-z0-9]|^$|ADR Home" | sort)

 if [ "$(whoami)" = "oracle" ]
then while read adr_home
       do sid="${adr_home##*/}"
          logger "Checking SID $sid for RDBMS home $adr_home" 1
            if [ "$(ps -ef | egrep -c "ora_pmon_${sid}$")" -eq 1 ]
          then . oraenv <<< $sid > /dev/null
          else logger "SID $sid is not running"
          fi
            if [ "$(egrep -c "^${sid}:" /etc/oratab | cut -d: -f2)" -gt 1 ]
          then error "Multiple entries for SID $sid are present in the oratab!" 1
               egrep "^${sid}:" /etc/oratab | tee -a $outfile
               unset ORACLE_HOME
          else export ORACLE_HOME=$(egrep "^${sid}:" /etc/oratab | cut -d: -f2)
          fi
            if [ ! -d "${adr_base}/${adr_home}" ]
          then error "ERROR: The ADR repository at ${adr_base}/${adr_home} does not exist!" 1
          fi
            if [ ! -z "$ORACLE_HOME" ]
          then # Check for the log/diag directory:
                 if [ ! -d "$ORACLE_HOME/log/diag" ]
               then logger "INFO: Creating the $ORACLE_HOME/log/diag directory..."
                    mkdir -p $ORACLE_HOME/log/diag || error "ERROR: Could not create the directory!"
               else logger "PASS: The $ORACLE_HOME/log/diag directory exists"
               fi

               # Check for the configuration file:
                 if [ ! -f "$ORACLE_HOME/log/diag/adrci_dir.mif" ]
               then logger "WARN: Creating the $ORACLE_HOME/log/diag/adrci_dir.mif file..."
                    logger "%s" $adr_base > $ORACLE_HOME/log/diag/adrci_dir.mif || error "ERROR: Could not create the file!"
               elif [[ ! $(cat $ORACLE_HOME/log/diag/adrci_dir.mif) =~ $adr_base ]]
               then logger "WARN: $ORACLE_HOME/log/diag/adrci_dir.mif does not include the ADR base path, $adr_base"
                    logger "WARN: Contents of $ORACLE_HOME/log/diag/adrci_dir.mif:"
                    cat $ORACLE_HOME/log/diag/adrci_dir.mif | tee -a $outfile
                    logger " "
               else logger "PASS: $ORACLE_HOME/log/diag/adrci_dir.mif exists and includes the ADR Base directory"
               fi

                for adr_home in $($ADR exec="set base $adr_base;set home $adr_home;show homes" | grep -v :)
                 do check_home "$adr_home"
               done
          fi
     done < <($ADR exec="set base $adr_base;show homes" | egrep "/rdbms/[A-Za-z0-9]" | sort)
fi

logger "Disk use in $adr_base after:" 1
df -hP $adr_base | tee -a $outfile

 if [ -s $errfile ]
then sed -i "1s/^/$(hostname)\n$(print_string `expr length $(hostname)` '=')\n$(whoami)\n$(print_string `expr length $(whoami)` '-')\n/" $errfile
    mailx -a $outfile -a $errfile $notification_email </dev/null 2>/dev/null
else mailx -a $outfile $notification_email </dev/null 2>/dev/null
fi

rm $errfile
rm $outfile
