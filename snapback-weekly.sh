#!/bin/bash
# snapback.sh 1.4 modified by renx123
# Simple script to create regular snapshot-based backups for Citrix Xenserver
# Mark Round, scripts@markround.com
# http://www.markround.com/snapback
#
# 1.4 : Modifications by Luis Davim to support XVA backups with independent scheduling
# 1.3 : Added basic lockfile
# 1.2 : Tidied output, removed VDIs before deleting snapshots and templates
# 1.1 : Added missing force=true paramaters to snapshot uninstall calls.
#For more info on XenServer backups read:
# http://docs.vmd.citrix.com/XenServer/6.0.0/1.0/en_gb/reference.html#backups
#
# Variables
#
#Backup only running VMs or every VM?
ONLY_RUNNING="True"
#Oraganize backups in folders?
USE_FOLDERS="False"
FOLDER_RETAIN="14"
# Temporary snapshots will be use this as a suffix
SNAPSHOT_SUFFIX=snapback
# Temporary backup templates will use this as a suffix
TEMP_SUFFIX=newbackup
# Backup templates will use this as a suffix, along with the date
BACKUP_SUFFIX=backup
# What day to run weekly backups on
WEEKLY_ON="Sat"
# What day to run monthly backups on. These will run on the first day
# specified below of the month.
MONTHLY_ON="Sat"
# Temporary file
TEMP=/tmp/snapback.$$
# UUID of the destination SR for backups
#TEMPLATE_SR=db3e2696-a115-0810-a6bf-42933f3b9d02
# UUID of the destination SR for XVA files it must be an NFS SR
#XVA_SR=db3e2696-a115-0810-a6bf-42933f3b9d02
XVA_SR="Server1"
#Suspend VM or create a snapshot
SUSPEND=0
POWERSTATE=""
#NFS Export
NFS_EXPORT="192.168.1.20:/mnt/xenserver/weekly/"
#MOUNT_PATH="/var/run/sr-mount"
MOUNT_PATH="/backup-weekly"
#LOCKFILE=/tmp/snapback.lock
#Cicle control flags
SKIP_TEMPLATE=1
SKIP_XVA=0
COUNT=0
#if [ -f $LOCKFILE ]; then
#        echo "Lockfile $LOCKFILE exists, exiting!"
#        exit 1
#fi
#touch $LOCKFILE
#
# Don't modify below this line
#

#Check if mount point exists
if [ ! -d "$MOUNT_PATH" ]; then
    echo "Mount point does not exist, I'm going to create it.'"
    mkdir -p "$MOUNT_PATH"
fi
#check if moint point is mounted
mount | grep "$MOUNT_PATH" > /dev/null
if [ "$?" -eq "0" ]; then
    echo "== NFS already mounted, unmounting... =="
    umount $MOUNT_PATH;
fi
#Mout NFS share
echo "== Mounting NFS share =="
mount -t nfs -o soft $NFS_EXPORT $MOUNT_PATH

# Date format must be %Y%m%d so we can sort them
BACKUP_DATE=$(date +"%Y%m%d")
# Quick hack to grab the required paramater from the output of the xe command
function xe_param()
{
    PARAM=$1
    while read DATA; do
        LINE=$(echo $DATA | egrep "$PARAM")
        if [ $? -eq 0 ]; then
            echo "$LINE" | awk 'BEGIN{FS=": "}{print $2}'
        fi
    done
}
# Deletes a snapshot's VDIs before uninstalling it. This is needed as
# snapshot-uninstall seems to sometimes leave "stray" VDIs in SRs
function delete_snapshot()
{
    DELETE_SNAPSHOT_UUID=$1
    for VDI_UUID in $(xe vbd-list vm-uuid=$DELETE_SNAPSHOT_UUID empty=false | xe_param "vdi-uuid"); do
            echo "Deleting snapshot VDI : $VDI_UUID"
            xe vdi-destroy uuid=$VDI_UUID
    done
    # Now we can remove the snapshot itself
    echo "Removing snapshot with UUID : $DELETE_SNAPSHOT_UUID"
    xe snapshot-uninstall uuid=$DELETE_SNAPSHOT_UUID force=true
}
# See above - templates also seem to leave stray VDIs around...
function delete_template()
{
    DELETE_TEMPLATE_UUID=$1
    for VDI_UUID in $(xe vbd-list vm-uuid=$DELETE_TEMPLATE_UUID empty=false | xe_param "vdi-uuid"); do
            echo "Deleting template VDI : $VDI_UUID"
            xe vdi-destroy uuid=$VDI_UUID
    done
    # Now we can remove the template itself
    echo "Removing template with UUID : $DELETE_TEMPLATE_UUID"
    xe template-uninstall template-uuid=$DELETE_TEMPLATE_UUID force=true
}
function rescan_srs()
{
    echo "Rescanning SRs..."
    # Get all SRs
    SRS=$(xe sr-list | xe_param uuid)
    for SR in $SRS; do
        echo "Scanning SR: $SR"
        xe sr-scan uuid=$SR
    done
    echo "  Done - $(date)"
    echo " "
}

echo " "
echo "=== Snapshot backup started at $(date) ==="
echo " "
if [ "$ONLY_RUNNING" == "True" ]; then
    # Get all running VMs
    RUNNING_VMS=$(xe vm-list power-state=running is-control-domain=false | xe_param uuid)
else
    RUNNING_VMS=$(xe vm-list is-control-domain=false | xe_param uuid)
fi
for VM in $RUNNING_VMS; do
    VM_NAME="$(xe vm-list uuid=$VM | xe_param name-label)"
    # Useful for testing, if we only want to process one VM
    #if [ "$VM_NAME" != "testvm" ]; then
    #    continue
    #fi
    echo " "
    echo "== Backup for $VM_NAME started at $(date) =="
    echo "= Retrieving backup paramaters ="
    #Template backups
    SCHEDULE=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.backup)
    RETAIN=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.retain)
    #XVA Backups
    XVA_SCHEDULE=weekly
    XVA_RETAIN=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.xva_retain_weekly)
    SUSPEND=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.suspend)
    # Not using this yet, as there are some bugs to be worked out...
    # QUIESCE=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.quiesce)
##############################check Template schedule###########################
    SKIP_TEMPLATE=1
    if [[ "$SCHEDULE" == "" || "$RETAIN" == "" ]]; then
        echo "No schedule or retention set for template backup, skipping this VM"
        SKIP_TEMPLATE=1
    else
        echo "VM template backup schedule : $SCHEDULE"
        echo "VM template retention       : $RETAIN previous snapshots"
        if [ "$SCHEDULE" == "daily" ]; then
            SKIP_TEMPLATE=0
        else
            # If weekly, see if this is the correct day
            if [ "$SCHEDULE" == "weekly" ]; then
                if [ "$(date +'%a')" == "$WEEKLY_ON" ]; then
                    echo "On correct day for weekly backups, running..."
                    SKIP_TEMPLATE=0
                else
                    echo "Weekly backups scheduled on $WEEKLY_ON, skipping..."
                    SKIP_TEMPLATE=1
                fi
            else
                # If monthly, see if this is the correct day
                if [ "$SCHEDULE" == "monthly" ]; then
                    if [[ "$(date +'%a')" == "$MONTHLY_ON" && $(date '+%e') -le 7 ]]; then
                        echo "On correct day for monthly backups, running..."
                        SKIP_TEMPLATE=0
                    else
                        echo "Monthly backups scheduled on 1st $MONTHLY_ON, skipping..."
                        SKIP_TEMPLATE=1
                    fi
                fi
            fi
        fi
    fi
##############################check XVA schedule################################
    SKIP_XVA=1
    if [[ "$XVA_SCHEDULE" == "" || "$XVA_RETAIN" == "" ]]; then
        echo "No schedule or retention set for XVA backup, skipping this VM"
        SKIP_XVA=1
    else
        echo "VM XVA backup schedule : $XVA_SCHEDULE"
        echo "VM XVA retention       : $XVA_RETAIN previous snapshots"
        if [ "$XVA_SCHEDULE" == "daily" ]; then
            SKIP_XVA=0
        else
            # If weekly, see if this is the correct day
            if [ "$XVA_SCHEDULE" == "weekly" ]; then
                if [ "$(date +'%a')" == "$WEEKLY_ON" ]; then
                    echo "On correct day for weekly backups, running..."
                    SKIP_XVA=0
                else
                    echo "Weekly backups scheduled on $WEEKLY_ON, skipping..."
                    SKIP_XVA=1
                fi
            else
                # If monthly, see if this is the correct day
                if [ "$XVA_SCHEDULE" == "monthly" ]; then
                    if [[ "$(date +'%a')" == "$MONTHLY_ON" && $(date '+%e') -le 7 ]]; then
                        echo "On correct day for monthly backups, running..."
                        SKIP_XVA=0
                    else
                        echo "Monthly backups scheduled on 1st $MONTHLY_ON, skipping..."
                        SKIP_XVA=1
                    fi
                fi
            fi
        fi
    fi
################################################################################
    if [[ "$SKIP_TEMPLATE" == "1" && "$SKIP_XVA" == "1" ]]; then
        echo "Nothing to do for this VM!..."
        continue
    fi
    echo "= Checking snapshots for $VM_NAME - $(date) ="
    VM_SNAPSHOT_CHECK=$(xe snapshot-list name-label="$VM_NAME-$SNAPSHOT_SUFFIX" | xe_param uuid)
    if [ "$VM_SNAPSHOT_CHECK" != "" ]; then
        echo "Found old backup snapshot : $VM_SNAPSHOT_CHECK"
        echo "Deleting..."
        delete_snapshot $VM_SNAPSHOT_CHECK
    fi
    echo "  Done - $(date)"
    if [[ "$SUSPEND" != "1" ]]; then
        echo "= Creating snapshot backup - $(date) ="
        # Select appropriate snapshot command
        # See above - not using this yet, as have to work around failures
        #if [ "$QUIESCE" == "true" ]; then
        #    echo "Using VSS plugin"
        #    SNAPSHOT_CMD="vm-snapshot-with-quiesce"
        #else
        #    echo "Not using VSS plugin, disks will not be quiesced"
        #    SNAPSHOT_CMD="vm-snapshot"
        #fi
        SNAPSHOT_CMD="vm-snapshot"
        SNAPSHOT_UUID=$(xe $SNAPSHOT_CMD vm="$VM_NAME" new-name-label="$VM_NAME-$SNAPSHOT_SUFFIX")
        echo "Created snapshot with UUID : $SNAPSHOT_UUID"
    else
        # Check that it's running
        POWERSTATE=$(xe vm-param-get uuid=$VM param-name=power-state)
        if [[ ${POWERSTATE} == "running" ]]; then
            echo "Suspending VM..."
            xe vm-suspend uuid=$VM
        fi
        SNAPSHOT_UUID=$VM
    fi
    #Backup to template ################################################
    if [ "$SKIP_TEMPLATE" == "0" ]; then
        echo "= Copying snapshot to SR - $(date) ="
        # Check there isn't a stale template with TEMP_SUFFIX name hanging around from a failed job
        TEMPLATE_TEMP="$(xe template-list name-label="$VM_NAME-$TEMP_SUFFIX" | xe_param uuid)"
        if [ "$TEMPLATE_TEMP" != "" ]; then
            echo "Found a stale temporary template, removing UUID $TEMPLATE_TEMP"
            delete_template $TEMPLATE_TEMP
        fi
        if [[ "$SUSPEND" != "1" ]]; then
            COPY_CMD="snapshot-copy"
        else
            COPY_CMD="vm-copy"
        fi
        TEMPLATE_UUID=$(xe $COPY_CMD uuid=$SNAPSHOT_UUID sr-uuid=$TEMPLATE_SR new-name-description="Snapshot created on $(date)" new-name-label="$VM_NAME-$TEMP_SUFFIX")
        if [[ "$SUSPEND" != "1" ]]; then
            xe vm-param-set uuid=$TEMPLATE_UUID is-a-template=true
        fi
        echo "  Done - $(date)"
        # Check there is no template with the current timestamp.
        # Otherwise, you would not be able to backup more than once a day if you needed...
        TODAYS_TEMPLATE="$(xe template-list name-label="$VM_NAME-$BACKUP_SUFFIX-$BACKUP_DATE" | xe_param uuid)"
        if [ "$TODAYS_TEMPLATE" != "" ]; then
            echo "Found a template already for today, removing UUID $TODAYS_TEMPLATE"
            delete_template $TODAYS_TEMPLATE
        fi
        echo "= Renaming template - $(date) ="
        xe template-param-set name-label="$VM_NAME-$BACKUP_SUFFIX-$BACKUP_DATE" uuid=$TEMPLATE_UUID
        echo "  Done - $(date)"
        # List templates for all VMs, grep for $VM_NAME-$BACKUP_SUFFIX
        # Sort -n, head -n -$RETAIN
        # Loop through and remove each one
        echo "= Removing old template backups - $(date) ="
        xe template-list | grep "$VM_NAME-$BACKUP_SUFFIX" | xe_param name-label | sort -n | head -n-$RETAIN > $TEMP
        while read OLD_TEMPLATE; do
            OLD_TEMPLATE_UUID=$(xe template-list name-label="$OLD_TEMPLATE" | xe_param uuid)
            echo "Removing : $OLD_TEMPLATE with UUID $OLD_TEMPLATE_UUID"
            delete_template "$OLD_TEMPLATE_UUID"
        done < "$TEMP"
    fi
    #Backup to XVA #####################################################
    if [ "$SKIP_XVA" == "0" ]; then
        #check if a XVA file with the current timestamp exists
        if [ "$USE_FOLDERS" == "True" ]; then
            mkdir -p "$MOUNT_PATH/$XVA_SR/$BACKUP_DATE-$BACKUP_SUFFIX"
            FNAME="$MOUNT_PATH/$XVA_SR/$BACKUP_DATE-$BACKUP_SUFFIX/$VM_NAME.xva"
        else
            FNAME="$MOUNT_PATH/$VM_NAME-$BACKUP_SUFFIX-$BACKUP_DATE.xva"
        fi
        if [ -e "$FNAME" ]; then
            echo "Found a XVA already for today, removing it"
            rm -f "$FNAME"
        fi
        echo "= Exporting VM to file - $(date) ="
        #Creates a XVA file from the snapshot
        EXPORT_CMD="vm-export"
        xe $EXPORT_CMD vm=$SNAPSHOT_UUID filename="$FNAME"
        echo "  Done - $(date)"
        # List XVA files for all VMs, grep for $VM_NAME-$BACKUP_SUFFIX
        # Sort -n, head -n -$XVA_RETAIN
        # Loop through and remove each one
        echo "= Removing old XVA files - $(date) ="
        if [ "$USE_FOLDERS" != "True" ]; then
            ls -1 $MOUNT_PATH/*.xva | grep "$VM_NAME-$BACKUP_SUFFIX" | sort -n | head -n-$XVA_RETAIN > $TEMP
            while read OLD_TEMPLATE; do
                echo "Removing : $OLD_TEMPLATE"
                rm "$OLD_TEMPLATE"
            done < $TEMP
        fi
    fi
    if [ "$SUSPEND" != "1" ]; then
        echo "= Removing temporary snapshot backup ="
        delete_snapshot $SNAPSHOT_UUID
        echo "  Done - $(date)"
    else
        # If the VM was previously running resume it
        if [[ ${POWERSTATE} == "running" ]]; then
          echo "Resuming VM..."
          xe vm-resume uuid=$VM
          echo "  Done - $(date)"
        fi
    fi
    echo "== Backup for $VM_NAME finished at $(date) =="
    echo " "
    sleep 1
    #Rescan SRs every 3 backups to release space allocated by deleted snapshots
    if [ "$COUNT" == "3" ]; then
        COUNT=0
        rescan_srs
    else
        COUNT=$((COUNT+1))
    fi
    sleep 3
done
#Clear old XVA backups
if [ "$USE_FOLDERS" == "True" ]; then
    ls -1 $MOUNT_PATH/$XVA_SR/ | grep "$BACKUP_SUFFIX" | sort -n | head -n-$FOLDER_RETAIN > $TEMP
    while read OLD_TEMPLATE; do
        echo "Removing : $OLD_TEMPLATE"
        rm -rf "$MOUNT_PATH/$XVA_SR/$OLD_TEMPLATE"
    done < $TEMP
fi
xe vdi-list sr-uuid=$TEMPLATE_SR > $MOUNT_PATH/$XVA_SR/mapping.txt
xe vbd-list > $MOUNT_PATH/$XVA_SR/vbd-mapping.txt
echo "=== Snapshot backup finished at $(date) ==="
echo " "
echo "=== Metadata backup started at $(date) ==="
echo " "
#Backup Pool meta-data:
#/opt/xensource/bin/xe-backup-metadata -c -k 10 -u $TEMPLATE_SR
xe pool-dump-database file-name=$MOUNT_PATH/$XVA_SR/pool_metadata
#to restore metadata use:
# xe pool-restore-database file-name=<backup> # there is an option to test the backup with dry-run=true
echo "=== Metadata backup finished at $(date) ==="
echo " "
rescan_srs
if [ "$(date +'%a')" == "$WEEKLY_ON" ]; then
    echo "On correct day for weekly backups, running coalesce_leaf.sh..."
    /usr/local/sbin/coalesce_leaf.sh
fi
sleep 5
#unmount NFS share
echo "== Unmounting NFS share =="
umount $MOUNT_PATH;
rm $LOCKFILE
rm $TEMP
