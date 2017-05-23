#!/bin/bash

DATE=$(date +%d%B%y)
XSNAME=`echo $HOSTNAME`
mkdir -p /metadata

mount -t nfs 192.168.1.20:/mnt/xenserver/ /backup-metadata

BACKUPPATH=/metadata/metadata/$XSNAME/$DATE
mkdir -p $BACKUPPATH

xe vm-list is-control-domain=false is-a-snapshot=false | grep uuid | cut -d":" -f2 >  /tmp/uuids.txt

while read line
do
    VMNAME=`xe vm-list uuid=$line | grep name-label | cut -d":" -f2 | sed 's/^ *//g'`
    xe vm-export filename="$BACKUPPATH/$XSNAME-$VMNAME-$DATE" uuid=$line metadata=true
done < /tmp/uuids.txt
umount /backup-metadata
