#!/bin/bash
age=${1:-14}
adr_age=$(($age * 24))
errfile=$(mktemp -t $(hostname)_$(whoami)_$(date '+%Y%m%d%H%M').XXXX.err)
outfile=$(mktemp -t $(hostname)_$(whoami)_$(date '+%Y%m%d%H%M').XXXX.out)

  if [ "$(whoami)" = "grid" ]
then ORACLE_HOME=$(egrep -v "^#|^$" /etc/oratab | grep grid | cut -d: -f2 | sort | uniq)
     adr_base=/u01/app/grid
else ORACLE_HOME=$(egrep -v "^#|^$|grid" /etc/oratab | cut -d: -f2 | sort | uniq | tail -1)
     adr_base=/u01/app/oracle
fi

ADR=$ORACLE_HOME/bin/adrci

logger() {
  printf "$1 \n" | tee -a $outfile
}

error() {
  printf "$1 \n" | tee -a $errfile
}

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

dostat() {
  stat -c '%A User: %U/%u Group: %G/%g %y %n' $1
}

dodu() {
  logger "Space ${1,,} ($(date '+%Y-%m-%d %H:%M'))"
  printf "%116s\n" ".tr* file count by age:" | tee -a $outfile
  printf "%127s\n" "--------------------------------------------" | tee -a $outfile
  printf "%-60s %10s %10s %8s %8s %8s %8s %8s %8s\n" "Directory" "Size (KB)" "File Count" "60+ Days" "30+ Days" "14+ Days" "7+ Days" "All" | tee -a $outfile
  printf -- "------------------------------------------------------------ ---------- ---------- -------- -------- -------- -------- --------\n" | tee -a $outfile
   for d in $(find $2 -maxdepth 1 -type d | sort)
    do d_kbs=$(du -s $d 2>/dev/null | awk '{print $1}')
       d_a00=$(find $d/* -type f 2>/dev/null | wc -l)
       d_t15=$(find $d/*.tr* -type f -mtime +60 2>/dev/null | wc -l)
       d_t14=$(find $d/*.tr* -type f -mtime +30 2>/dev/null | wc -l)
       d_t08=$(find $d/*.tr* -type f -mtime +14 2>/dev/null | wc -l)
       d_t07=$(find $d/*.tr* -type f -mtime +7  2>/dev/null | wc -l)
       d_t00=$(find $d/*.tr* -type f 2>/dev/null | wc -l)
       printf "%-60s %10d %10d %8d %8d %8d %8d %8d %8d\n" "$d" $d_kbs $d_a00 $d_t15 $d_t14 $d_t08 $d_t07 $d_t00 | tee -a $outfile
  done
}

check_home() {
  local __adr_home="$1"
  unset rc
  logger " "
  logger "Checking ADR Home $__adr_home:"
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
  logger " "; logger "Checking for unmanaged files and directories..."
   for f in $(find ${adr_base}/${__adr_home} \( ! -user oracle -a ! -user grid \) -a \( ! -group dba -a ! -perm g+x \) -print 2>/dev/null | sort -u)
    do logger "$f"
       dostat "$f" 2>/dev/null || error "FAIL: Cannot stat $f; Checking parent..."; error "$(dostat "${f%/*}")"
  done
    if [ "$rc" = "0" ]
  then logger " "; logger "INFO: Purging files..."
       dodu "before" "${adr_base}/${__adr_home}"
       logger "Purging files older than $age days"
        for t in CDUMP INCIDENT UTSCDMP ALERT TRACE HM
         do logger "   Purging $t ($(date '+%Y-%m-%d %H:%M'))"
            $ADR exec="set base $adr_base;set home $__adr_home;purge -age $adr_age -type $t" | tee -a $outfile
       done
       find "${adr_base}/${__adr_home}"/* -type f -mtime +"${age}" -delete
       dodu "after" "${adr_base}/${__adr_home}"
       logger " "
  else dodu "used" "${adr_base}/${__adr_home}"
                  if [ $fc < 51 ]
                then find $adr_home -type f -printf '%T+\t%s\t%u\t%g\t%p\n' | sort -r | tee -a $outfile
                else printf "%s files are present" "$fc"
                     printf "Newest files:\n" | tee -a $outfile
                     find $adr_home -type f -printf '%T+\t%s\t%u\t%g\t%p\n' | sort -r | head -n 10 | tee -a $outfile
                     printf "Oldest files:\n" | tee -a $outfile
                     find $adr_home -type f -printf '%T+\t%s\t%u\t%g\t%p\n' | sort    | head -n 10 | tee -a $outfile
                fi

  fi
}

logger " "
logger "Disk use in $adr_base before:"
df -hP $adr_base | tee -a $outfile
logger " "

logger "INFO: All ADR Home directories:"
$ADR exec="set base $adr_base;show homes" | tee -a $outfile

while read adr_home
   do # ADR Home pattern matches an older ADR schema
        if [[ ${adr_home##*/} =~ [0-9]*_(82|107) ]]
      then error "$adr_home may be for an obsolete schema"
      # CRS Home for a user
      elif [ "$(egrep -c "^${adr_home##*/crs_}:" /etc/passwd)" -gt 0 ]
      then error "$adr_home may be an orphaned CRS user home"
      # ADR Listener Home pattern matches a non-existent listener
      elif ! [[ ${adr_home} =~ user_^(grid|oracle) ]]
      then error "$adr_home is a non- oracle/grid user directory"
      elif [ "$(ps -ef | grep tns | grep -v grep | egrep -ic "${adr_home##*/tnslsnr/[a-zA-Z0-9]*/}")" -eq 0 ]
        && ! [[ ${adr_home} =~ tnslsnr/[a-zA-Z0-9]*/listener_scan ]]
      then error "$adr_home is a for a listener not currently running on this host"
      # ADR Database Home pattern matches a SID that is not present in /etc/oratab
      elif [ "$(egrep -ci "^${adr_home##*/rdbms/[^/]*/}:" /etc/oratab)" -eq 0 ]
      then error "$adr_home is for a SID not present in /etc/oratab"
      # ADR Database Home Unique Name is not a subset of the SID
      elif [[ $adr_home =~ /diag/rdbms ]]
        && ! [[ $(echo ${adr_home,,} | cut -d/ -f4) =~ $(echo ${adr_home,,} | cut -d/ -f3) ]]
      then error "$adr_home mismatch between Database Unique Name and SID"
      fi
 done < <($ADR exec="set base $adr_base;show homes" | egrep -v "^$|ADR Homes" | sort)

while read dbun
   do error "Multiple ADR homes exist for DB unique name ${dbun}:"
   $ADR exec="set base $adr_base;show homes" | egrep "/rdbms/${dbun}/" | tee -a $errfile
 done < <($ADR exec="set base $adr_base;show homes" | egrep "/rdbms/[A-Za-z0-9]" | sort | cut -d/ -f3 | uniq -c | awk '$1 > 0 {print $2}')

# Check the non-RDBMS ADR Homes under this base:
while read adr_home
   do check_home "$adr_home"
 done < <($ADR exec="set base $adr_base;show homes" | egrep -v "/rdbms/[A-Za-z0-9]" | sort)

  if [ "$(whoami)" = "oracle" ]
then while read adr_home
        do sid="${adr_home##*/}"
           logger " "
           logger "Checking SID $sid for RDBMS home $adr_home"
             if [ "$(ps -ef | egrep -c "ora_pmon_${sid}$")" -eq 1 ]
           then . oraenv <<< $sid > /dev/null
           else logger "SID $sid is not running"
           fi
             if [ "$(egrep -c "^${sid}:" /etc/oratab | cut -d: -f2)" -gt 1 ]
           then error "Multiple entries for SID $sid are present in the oratab!"
                egrep "^${sid}:" /etc/oratab | tee -a $outfile
                unset ORACLE_HOME
           else export ORACLE_HOME=$(egrep "^${sid}:" /etc/oratab | cut -d: -f2)
           fi
             if [ ! -d "${adr_base}/${adr_home}" ]
           then error "ERROR: The ADR repository at ${adr_base}/${adr_home} does not exist!"
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

logger " "
logger "Disk use in $adr_base after:"
df -hP $adr_base | tee -a $outfile

  if [ -s $errfile ]
then mailx -a $outfile -a $errfile sscott10@wellcare.com </dev/null 2>/dev/null
else mailx -a $outfile sscott10@wellcare.com </dev/null 2>/dev/null
fi

rm $errfile
rm $outfile
