# Aloha Backup Script
#
# Quick and dirty Windows 10 Powershell script to copy/sync files to a share on ht QRS BackOffice 
# computer and also a USB attached drive of some kind.(at some point)

# net use t: \\Backoffice\$AlohaBackup /user:alohabackup 8Pact-Remote-lobe-tows
$user			 = 'alohabackup'
$SecurePassword  = ConvertTo-SecureString '8Pact-Remote-lobe-tows' -AsPlainText -Force 
$credential      = New-Object System.Management.Automation.PSCredential($user, $SecurePassword)
$Newdrive        = New-PsDrive "Z" -PSProvider FileSystem -Root '\\Backoffice\$AlohaBackup' -Scope Global -Credential $credential
 
# Define local drive as source files
$FolderSourceEDCPath      = 'C:\AlohaEDC\'
$FolderSourceBOOTDRVPath  = 'C:\BOOTDRV\'
$FolderSourceEDCFiles     = Get-ChildItem -Path $FolderSourceEDCPath -Recurse -Force
$FolderSourceBOOTDRVFiles = Get-ChildItem -Path $FolderSourceBOOTDRVPath -Recurse -Force

# Define Z mapped drive as destination/backup files
$FolderDestEDCPath        = 'Z:\AlohaEDC'
$FolderDestBOOTDRVPath    = 'Z:\BOOTDRV'
$FolderDestEDCFiles       = Get-ChildItem -Path $FolderDestEDCPath -Recurse -Force
$FolderDestBOOTDRVFiles   = Get-ChildItem -Path $FolderDestBOOTDRVPath  -Recurse -Force
# $FolderDestBOOTDRVFiles   = "empty"


$FolderDestBOOTDRVFiles | foreach {
							Write-Output $_.Path
							
							Remove-PSDrive -Name "Z" -Force
							Exit

}


Remove-PSDrive -Name "Z" -Force
Return




#Determine differentials files
Write-Output "starting file compare"
$FileDiffs = Compare-Object -ReferenceObject $FolderSourceBOOTDRVFiles -DifferenceObject $FolderDestBOOTDRVFiles
Write-Output "finished file compare"

<# 
$FileDiffs | foreach {

				Write-Output $_
				Remove-PSDrive -Name "Z" -Force
				Exit


}
 #>



$FileDiffs | foreach {
				$copyParams = @{
					'Path' = $_.InputObject
				}
				if ($_.SideIndicator -eq '<=')
				{
					$copyParams.Destination = $FolderDestBOOTDRVPath
					# Copy-Item @copyParams
					Write-Output $copyParams
				}
} 
 
 
Remove-PSDrive -Name "Z" -Force
Return

