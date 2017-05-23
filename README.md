# snapback
Xenserver backup script 

Exports .xva files to NFS mount 

Setup:

-- ssh to xenserver host --

copy snapback-daily.sh to /opt/

copy snapback-weekly.sh to /opt/

copy crontab to /etc/crontab

create directory /backup-daily 

create directory /backup-weekly


 ---allow write only when mounted ---
	
 chattr +i /backup-daily 
	
 chattr +i /backup-weekly
	
	
 create external NFS mount and allow to be mounted from xenserver host
	
 Replicate above to all Xenserver hosts if needed. All backups will be inside the same nfs mounted folder. So it's possible to mobe VM's between hosts without affecting backup setup.

--- Add custom fields to Xencenter --

Open VM properties > custom fields > Edit custom fields > add            ( see create_custom_fields.jpg )

          xva_retain_daily
										
          xva_retain_weekly
          
Add values how many daily and weekly backups you want to EVERY virtual machine. With empty fields VM's will not be backed up.

Example of backup files on NFS mount: example-backup-dir.jpg
