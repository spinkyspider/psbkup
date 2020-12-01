<#
 Purpose:       Rotating differential backup using 7-Zip for compression.
 Requirements:  - forfiles.exe from Microsoft
                - 7-Zip
 Author:        vocatus on reddit.com/r/sysadmin ( vocatus.gate@gmail.com ) // PGP key ID: 0x82A211A2
				spider (seechuckspin@gmail.com)
 Version:       0.2.0 + Rebase to PowerShell
 Notes:         My intention for this script was to keep the logic controlling schedules, backup type, etc out of the script and
                let an invoking program handle it (e.g. Task Scheduler). You simply run this script with a flag to perform an action.
                If you want to schedule monthly backups, purge old files, etc, just set up task scheduler jobs for those tasks, 
                where each job calls the script with a different flag.
 Usage:         Run this script without any flags for a list of possible actions. Run it with a flag to perform that action.
                Flags:
                 -full         create full backup
                 -diff         create differential backup (full backup must already exist)
                 -restrore     restore from a backup (extracts to your staging area)
                 -archive      archive (close out/rotate) the current backup set. This:
                                  1. moves all .7z files in the $destination into a folder named with the current date
                                  2. deletes all .7z files from the staging area
                 -purge        purge (delete) old backup sets from staging and destination. If you specify a number 
                                of days after the command it will run automatically without any confirmation. Be careful with this!
                 -configdump   config dump. Show job options (show what the variables are set to)
 Important:     If you want to set this script up in Windows Task Scheduler, be aware that Task Scheduler
                can't use mapped network drives (X:\, Z:\, etc) when it is set to "Run even if user isn't logged on."
                The task will simply fail to do anything (because Scheduler can't see the drives). To work around this use
                UNC paths instead (\\server\backup_folder etc) for your source, destination, and staging areas.
#>

#############
# VARIABLES # ------------------------ Set these to match your environment -------------------------- #
#############
# Rules for variables:
#  * Wrap everything in quotes     ( good:  "c:\directory\path"        )
#  * NO trailing slashes on paths! ( bad:   "c:\directory\"            )
#  * Spaces are okay               ( good:  "c:\my folder\with spaces" )
#  * Network paths are okay        ( good:  "\\server\share name"      )
param (

	# Catch which action to take

    [Parameter(Position=0,Mandatory=$false)]
    [switch]$full,	
    [Parameter(Position=0,Mandatory=$false)]
    [switch]$diff,	
    [Parameter(Position=0,Mandatory=$false)]
    [switch]$restore,	
    [Parameter(Position=0,Mandatory=$false)]
    [switch]$archive,	
    [Parameter(Position=0,Mandatory=$false)]
    [switch]$purge,	
    [Parameter(Position=0,Mandatory=$false)]
    [switch]$configdump,	
    [Parameter(Position=0,Mandatory=$false)]
    [switch]$help,	

	# Specify the folder you want to back up here.
	[string]$source = 'C:\ABTEST',

	# Key (password) for archive encryption. If blank, no encryption is used
	[string]$encryption_key = '',
	
	# Work area where everything is stored while compressing. Should be a fast drive or something that can handle a lot of writes
	# Recommend not using a network share unless it's Gigabit or faster.
	[string]$staging = 'C:\temp\ALOHABACKUPSTAGING',

	# This is the final, long-term destination for your backup after it is compressed.
	[string]$destination = 'Z:\BOOTDRV',

	# If you want to customize the prefix of the backup files, do so here. Don't use any special characters (like underscores)
	# The script automatically suffixes an underscore to this name. Recommend not changing this unless you really need to.
	#  * Spaces are NOT OKAY to use here!
	[string]$backup_prefix = 'backup',

	# OPTIONAL: If you want to exclude some files or folders, you can specify your exclude file here. The exclude file is a list of 
	# files or folders (wildcards in the form of * are allowed and recommended) to exclude
	# If you specify a file here and the script can't find it, it will abort
	# If you leave this variable blank the script will ignore it
#	[string]$exclusions_file = "R:\scripts\sysadmin\backup_differential_excludes.txt",
	[string]$exclusions_file = '',

	# Log settings. Max size is how big (in bytes) the log can be before it is archived. 1048576 bytes is one megabyte
	[string]$logpath = $env:systemdrive + '\Logs',
	[string]$logfile = $env:computername + '_' + $backup_prefix + '_differential.log',
	[string]$log_max_size = '104857600',

	# Location of 7-Zip and forfiles.exe
	[string]$sevenzip = $env:ProgramFiles + '\7-Zip\7z.exe',
	[string]$forfiles = $env:windir + '\system32\forfiles.exe',
    [string]$DAYS = '180'
)


# ----------------------------- Don't edit anything below this line ----------------------------- ::

###################
# TO DO SECTION   #
###################
<#
    Need to catch empty or unknown parameters: throw to helpout
    Need to protect purge code: make safe
    Functionize each action code block
    Fix sanity checks: debug doesn't parse them
    Full backup file not dated
    Diff backup file not included?

#>


###################
# PREP AND CHECKS #
###################
$SCRIPT_VERSION = "0.2.1"
$SCRIPT_UPDATED = "2020-11-11"
$CUR_DATE=get-date -f "yyyy-MM-dd"
$START_TIME = get-date -f "yyyy-mm-dd hh:mm:ss"

# Preload variables for use later
if     ( $full) { $JOB_TYPE = "full" }
	elseif ( $diff ) { $JOB_TYPE = "differential" }
	elseif ( $restore ) { $JOB_TYPE = "restore" }
	elseif ( $archive ) { $JOB_TYPE = "archive_backup_set" }
	elseif ( $purge ) { $JOB_TYPE = "purge_archives" }
	elseif ( $configdump ) { $JOB_TYPE = "config_dump" }
	else { $JOB_TYPE = "help"}

$JOB_ERROR    = "0"
$RESTORE_TYPE = "NUL"
$SCRIPT_NAME  = "backup_differential.ps1"


###################
#    FUNCTIONS    #
###################



# Out put help message
function helpout()
{
	""
	write-output "  $SCRIPT_NAME v$SCRIPT_VERSION"
	""
	write-output "  Usage: $SCRIPT_NAME < -full | -diff | -restore | -archive | -purge [days] -configdump -help >"
	""
	write-output "  Flags:"
	write-output "   -full:        create full backup"
	write-output "   -diff:        create differential backup (requires an existing full backup)"
	write-output "   -restore:     restore from a backup (extracts to $staging\$backup_prefix_restore)"
	write-output "   -archive:     archive current backup set. This will:"
	write-output "                    1. move all .7z files located in:"
	write-output "                       $destination"
	write-output "                       into a dated archive folder."
	write-output "                    2. purge (delete) all copies in the staging area ($staging)"
	write-output "   -purge:       purge (AKA delete) archived backup sets from staging and long-term storage"
	write-output "                 Optionally specify number of days to run automatically. Be careful with this!"
	write-output "                 Note that this requires a previously-archived backup set (-a option)"
	write-output "   -configdump:  config dump (show what parameters the script WOULD execute with)"
	""
	write-output "  Edit this script before running it to specify your source, destination, and work directories."
	exit(0)
}



function log($message, $color)
{
	if ($color -eq $null) {$color = "gray"}
	#console
	write-host (get-date -f "yyyy-mm-dd hh:mm:ss") -n -f darkgray; write-host "$message" -f $color
	#log
	(get-date -f "yyyy-mm-dd hh:mm:ss") +"$message" | out-file -Filepath $logfile -append
}

# Literal log (no date/time prefix)
function logliteral($message, $color)
{
	if ($color -eq $null) {$color = "gray"}
	#console
	write-host "$message" -f $color
	#log
	"$message" | out-file -Filepath $logfile -append
}


function configdump()
{
    logliteral ""
	logliteral " Current configuration:"
	logliteral ""
	logliteral " Script version:       $SCRIPT_VERSION"
	logliteral " Script updated:       $SCRIPT_UPDATED"
	logliteral " Source:               $source"
	logliteral " Destination:          $destination"
	logliteral " Staging area:         $staging"
	logliteral " Exclusions file:      $exclusions_file"
	logliteral " Backup prefix:        $backup_prefix"
	logliteral " Restores unpacked to: $staging\$backup_prefix_restore"
	logliteral " Log file:             $logpath\$logfile"
	logliteral ""
	logliteral "Edit this script with a text editor to customize these options."
	logliteral "" 
    exit(0)
}


###################
#  END FUNCTIONS  #
###################




# Show help if requested  #RcS#added empty case so script doesn't run without parameters
if ( $JOB_TYPE -eq "help") { helpout }


# Make logfile if it doesn't exist
if (!(test-path $logpath)) { new-item -path $logpath -itemtype directory }


#################
# SANITY CHECKS #
#################
# Test for existence of 7-Zip
if (!$SevenZip) {
	""
	""
	write-host -n " ["; write-host -n "ERROR" -f red; write-host -n "]";
	write-host " Couldn't find 7z.exe at the location specified ( $SevenZip )"
	write-host "         Edit this script and change the `$SevenZip variable to point to 7z's location"
	""
	pause
	break
}

# Test for existence of exclusions file if it was specified
if ( ($exclusions_file -ne "") -and (test-path -path $exclusions_file)  ) {
	""
	write-host -n " ["; write-host -n "ERROR" -f red; write-host -n "]";
	write-host " An exclusions file was specified but couldn't be found."
	write-host "         $exclusions_file"
	""
	pause
	break
}



###########
# EXECUTE #
###########
# wrap entire script in main function so we can put the logging function at the bottom of the script
function main {


# Welcome banner
logliteral ""
logliteral "---------------------------------------------------------------------------------------------------"
logliteral "  Differential Backup Script v$SCRIPT_VERSION - initialized  at $START_TIME by $env:userdomain\$env:username" green
logliteral ""
logliteral "  Script location:  $pwd\$SCRIPT_NAME"
logliteral "         Job type:  $JOB_TYPE"
logliteral "---------------------------------------------------------------------------------------------------"
logliteral ""



# Dump config if requested
if ( $JOB_TYPE -eq "config_dump" ) {
    configdump
	exit(0)
}





# // FULL BACKUP: begin
if ( $JOB_TYPE -eq "full" ) { 
	$BACKUP_FILE = $backup_prefix + "_full.7z"
	logliteral ""
	log "   Building full archive in staging area $staging..."
	logliteral ""
	log "------- [ Beginning of 7zip output ] -------" blue
		if ( $exclusions_file -ne "" ) { & $sevenzip a "$staging\$BACKUP_FILE" "$source" -xr@$exclusions_file  }
		if ( $exclusions_file -eq "" ) { & $sevenzip a "$staging\$BACKUP_FILE" "$source"  }
	logliteral ""
	log "------- [ End of 7zip output ] -------" blue
	logliteral ""

	# Report on the build
	if ( $? -eq "True" ) {
		log "   Archive built successfully."
	} else {
		$JOB_ERROR = "1"
		log " ! Archive built with errors." yellow
	}

	# Upload to destination
	logliteral ""
	log "   Uploading $BACKUP_FILE to $destination..."
	logliteral ""
	xcopy "$staging\$BACKUP_FILE" "$destination\" /Q /J /Y /Z 
	logliteral ""

	# Report on the upload
	if ( $? -eq "True" ) {
		log "   Uploaded full backup to $destination successfully."
	} else {
		$JOB_ERROR = "1"
		log " ! Upload of full backup to $destination failed." yellow
	}

} # // FULL BACKUP: end



# // DIFFERENTIAL BACKUP: begin
if ( $JOB_TYPE -eq "differential" ) { 

    # Define differential backup file name
    $ThisDiff = "$staging\$backup_prefix" + "_differential_" + "$CUR_DATE" + ".7z"
    $FullBack = "$staging\$backup_prefix" + "_full.7z"

	# Check for full backup existence
	if (!"$FullBack") {
		$JOB_ERROR = "1"
		log " ! ERROR: Couldn't find full backup file ($FullBack). You must create a full backup before a differential can be created." yellow
		break
	} else {
		# Backup existed, so go ahead
		log "   Performing differential backup of $source..." green
	}


	# Build archive
	log "   Building archive in staging area $staging..."
	logliteral ""
	log "------- [ Beginning of 7zip output ] -------"
	# Run if we're using an exclusions file
	if ( $exclusions_file -ne "" ) { & $sevenzip u "$FullBack" "$source" -ms=off -mx=9 -xr@$exclusions_file -t7z -u- -up0q3r2x2y2z0w2!"$ThisDiff"  }
	
	# Run if we're NOT using an exclusions file
	if ( $exclusions_file -eq "" ) { & $sevenzip u "$FullBack" "$source" -ms=off -mx=9 -t7z -u- -up0q3r2x2y2z0w2!"$ThisDiff"  }
	log "------- [ End of 7zip output ] -------" 
	logliteral ""

	# Report on the build
	if ( $? -eq "True" ) {
		log "   Archive built successfully."
	} else {
		$JOB_ERROR = "1"
		log " ! Archive built with errors." yellow
	}

	# Upload to destination
	log "   Uploading $ThisDiff to $destination..."
	xcopy "$ThisDiff" "$destination\" /Q /J /Y /Z 

	# Report on the upload
	if ( $? -eq "True" ) {
		log "   Uploaded differential file successfully."
	} else {
		$JOB_ERROR = "1"
		log " ! Upload of differential file failed." yellow
	}
} # DIFFERENTIAL BACKUP: end



# // RESTORE FROM BACKUP: begin
	#
	# ! ----------------------------------------------------  LOTS OF BROKEN STUFF BELOW HERE
	#
if ( $JOB_TYPE -eq "restore" ) { 
	
	#RcS# empty set not tested
	logliteral "RcS: Fix empty set test first." cyan
	exit(0)
	logliteral " Restoring from a backup set"
	logliteral " These backups are available:"
	logliteral ""
	cmd /c dir /b /a:-d "$staging"
	logliteral ""
	logliteral " Enter the filename to restore from exactly as it appears above."
	logliteral " (Note: archived backup sets are not shown)"
	logliteral ""


	$BACKUP_FILE = ""
	set /p BACKUP_FILE=Filename: 
	if ($BACKUP_FILE -eq "exit") {break}

	logliteral ""
	# Make sure user didn't fat-finger the file name
	if (test-path -literalpath "$staging\$BACKUP_FILE") {
		logliteral "  ! ERROR: That file wasn't found. Check your typing and try again." red
		goto restore_menu
	}

	$CHOICE = "y"
	logliteral "  ! Selected file '$BACKUP_FILE'"
	logliteral ""
	set /p CHOICE=Is this correct [y]?: 
#		if not %CHOICE%==y echo  Going back to menu... && goto restore_menu
#RcS# changed this line.  Powershell version differences??
		if (! (%CHOICE%==y)) {echo  Going back to menu...
							  goto restore_menu}
	""
	echo  Great. Press any key to get started.
	pause >NUL
	echo  ! Starting restoration at %TIME% on $CUR_DATE
	write-output   This might take a while, be patient...

	# Test if we're doing a full or differential restore.
	if ($BACKUP_FILE -eq "$backup_prefix_full.7z") {$RESTORE_TYPE = "full"}
	if (!($BACKUP_FILE -eq "$backup_prefix_full.7z")) {$RESTORE_TYPE = "differential"}

	# Detect our backup type and inform the user
	if ($RESTORE_TYPE -eq "differential") {
		log " Restoring from differential backup. Will unpack full backup then differential."
	}
	if ($RESTORE_TYPE -eq "full") {
		log "   Restoring from full backup."
		log "   Unpacking full backup..."
	}

	
	# Unpack full backup
	logliteral ""
	logliteral " ------- [ Beginning of 7zip output ] ------- " blue
		& $sevenzip x "$staging\$backup_prefix_full.7z" -y -o"$staging\$backup_prefix_restore\" >> $LOGPATH\$LOGFILE
	logliteral " ------- [    End of 7zip output    ] ------- " blue

	# Report on the unpack
	if ($? -eq "True") {
		log "   Full backup unpacked successfully."
	} else { 
		$JOB_ERROR = "1"
		log " ! Full backup unpacked with errors." yellow
	}

	# Unpack differential file if requested
	if ($RESTORE_TYPE -eq "differential") {
		logliteral ""
		log "   Unpacking differential file $BACKUP_FILE..."
		logliteral ""
		logliteral " ------- [ Beginning of 7zip output ] ------- " blue
			& $sevenzip x "$staging\$BACKUP_FILE" -aoa -y -o"$staging\$backup_prefix_restore\" >> $LOGPATH\$LOGFILE
		logliteral " ------- [    End of 7zip output    ] ------- " blue
		logliteral ""

		# Report on the unpack
		if ($? -eq "True") {			log "   Differential backup unpacked successfully."
			} else {
			$JOB_ERROR = "1"
			log " ! Differential backup unpacked with errors." yellow
		}
	}
} # // RESTORE FROM BACKUP: end


# // ARCHIVE BACKUPS: begin
if ( $JOB_TYPE -eq "archive" ) { 
	log "   Archiving current backup set to $destination\$CUR_DATE_$backup_prefix_set."

	# Final destination: Make directory, move files
	pushd "$destination"
	mkdir $CUR_DATE_$backup_prefix_set 
	move /Y *.* $CUR_DATE_$backup_prefix_set 
	popd
	log "   Deleting all copies in the staging area..."
	# Staging area: Delete old files
	del /Q /F "$staging\*.7z"
	logliteral ""

	# Report
	logliteral ""
	log "   Backup set archived. All unarchived files in staging area were deleted."
	logliteral ""
} # // ARCHIVE BACKUPS: end


# // PURGE BACKUPS: begin
<#
#RcS# I edited this section to update the if statement syntax.  I didn't comment everywhere I changed it.
#RcS# All pretty simple edits but I commented out the Purge section anyway since the changes are untested
#RcS# and that's not a function I'd want to gamble on.
 if ( $JOB_TYPE -eq "purge" ) {

	logliteral " CURRENT BACKUP SETS:"
	""
	logliteral " IN STAGING          : ($staging)"
	logliteral " ---------------------"
	dir /B /A:D "$staging"
	""
	""
	logliteral " IN LONG-TERM STORAGE: ($destination)"
	logliteral " ---------------------"
	dir /B /A:D "$destination"
	""
	set DAYS=180
	logliteral " Delete backup sets older than how many days? (you will be prompted for confirmation)"
	set /p DAYS=[%DAYS%]?: 
	if (%DAYS%==exit) {goto end}
	""
	# Tell user what will happen
	logliteral " THESE BACKUP SETS WILL BE DELETED:"
	logliteral " ----------------------------------"
	# List files that would match
	# We have to use PushD to get around forfiles.exe not using UNC paths. pushd automatically assigns the next free drive letter
	logliteral " From staging:"
	pushd "$staging"
	FORFILES /D -%DAYS% /C "cmd /c IF @isdir == TRUE echo @path" 2>NUL
	popd
	""
	logliteral " From long-term storage:"
	pushd "$destination"
	FORFILES /D -%DAYS% /C "cmd /c IF @isdir == TRUE echo @path" 2>NUL
	popd
	""
	set HMMM=n
	set /p HMMM=Is this okay [%HMMM%]?: 
	if ( %HMMM% ceq n) {""
						echo Canceled. Returning to menu.
						goto cleanup_archives_list2
						}
	if (%DAYS%==exit) {goto end}
	""
	set CHOICE=n
	set /p CHOICE=Are you absolutely sure [%CHOICE%]?: 
	if (!(%CHOICE%==y)) {""
						 echo Canceled. Returning to menu.
						 goto cleanup_archives_list2
						 }

	log "   Deleting backup sets that are older than %DAYS% days..."

	# This cleans out the staging area.
	# First FORFILES command tells the logfile what will get deleted. Second command actually deletes.
	pushd "$staging"
	FORFILES /D -%DAYS% /C "cmd /c IF @isdir == TRUE echo @path" 
	FORFILES /S /D -%DAYS% /C "cmd /c IF @isdir == TRUE rmdir /S /Q @path"
	popd

	# This cleans out the destination / long-term storage area.
	# First FORFILES command tells the logfile what will get deleted. Second command actually deletes.
	pushd "$destination"
	FORFILES /D -%DAYS% /C "cmd /c IF @isdir == TRUE echo @path" 
	FORFILES /S /D -%DAYS% /C "cmd /c IF @isdir == TRUE rmdir /S /Q @path"
	popd

	# Report results
	if ( $? -eq "True" ) {
		log "   Cleanup completed successfully."
	} else {
		$JOB_ERROR = "1"
		log " ! Cleanup completed with errors." yellow
	}
	
} # // PURGE BACKUPS: done
 #>





#####################
# COMPLETION REPORT #
#####################
# One of these displays if the operation was a restore operation
if ($RESTORE_TYPE -eq "full"){ log "   Restored full backup to $staging\$backup_prefix" }
if ($RESTORE_TYPE -eq "differential"){ log "   Restored full and differential backup to $staging\$backup_prefix" }

log "$SCRIPT_NAME complete." green
if ($JOB_ERROR -eq "1") { log " ! Note: Script exited with errors. Maybe check the log." yellow }

# Clean up our temp exclude file
#RcS# Fix if statement like -->  (!(test-path $logpath)
#if exist %TEMP%\DEATH_BY_HAMSTERS.txt del /F /Q %TEMP%\DEATH_BY_HAMSTERS.txt
if (test-path %TEMP%\DEATH_BY_HAMSTERS.txt) {del /F /Q %TEMP%\DEATH_BY_HAMSTERS.txt}

# Close the main() function. End of the script
}




#############
# FUNCTIONS #
#############





# call the main script
main