##Using Dirsync to find changes between Profile store and AD
##Author:adamsor
##Version: 2.0
##2.0 - Added Dnlookup, Fixed GetUsername, Added progress bar

Add-PSSnapin "Microsoft.SharePoint.PowerShell"
#First time running, just run "DirSync" then "DecodeAttributes $adusers"
#Update RootDSE to match your domain
$RootDSE = [ADSI]"LDAP://dc=contoso,dc=com"
$cookiepath = "C:\dirsync\cookie.bin"
$site	  = Get-SpSite http://mysite
$domain = "contoso\"
#Add additional mappings to this file.
[xml]$mappings = Get-Content -Path "C:\dirsync\mappings.xml"
[xml]$DNlookup = Get-Content -Path "C:\dirsync\DNLookup.xml"
$log = "c:\dirsync\out.log"
$fileloc = "c:\dirsync\DNLookup.xml"
$username = $null
$global:ADUsers = $null
#[array]$attributes = "mail", "dn", "sn", "givenname", "sAMAccountName"
$context  = Get-SPServiceContext($site) 
$pm       = new-object Microsoft.Office.Server.UserProfiles.UserProfileManager($context, $true) 
if ($cred -eq $null) { $cred=(Get-Credential).GetNetworkCredential() }

 function Byte2DArrayToString
{
    param([System.DirectoryServices.Protocols.DirectoryAttribute] $attr)

    $len = $attr[0].length
    $val = [string]::Empty
   
    for($i = 0; $i -lt $len; $i++)
    {
         $val += [system.text.encoding]::UTF8.GetChars($attr[0][$i])

    }
    return $val

}


Add-Type -AssemblyName System.DirectoryServices.Protocols


$optIn = Read-Host -Prompt "We would like to track usage of this application which includes a hashed representation of your IP address. Is this ok? (y/n)"
    if($optIn -eq "y"){
	
    #This code calls to a Microsoft web endpoint to track how often it is used. 
    #No data is sent on this call other than the application identifier
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object -TypeName System.Net.Http.Httpclient
    $cont = New-Object -TypeName System.Net.Http.StringContent("", [system.text.encoding]::UTF8, "application/json")
    $tsk = $client.PostAsync("https://msapptracker.azurewebsites.net/api/Hits/189997b2-5811-490a-b675-7016edc650e1",$cont)
    #if you want to make sure the call completes, add this to the end of your code
    #$tsk.Wait()

}

 

function Dirsync
{
Write-Progress -Activity "Querying AD..." -Status "Please wait."
If (Test-Path $cookiepath –PathType leaf) {[byte[]] $Cookie = Get-Content -Encoding byte –Path $cookiepath}else {$Cookie = $null}
$global:ADUsers = @()
$LDAPConnection = New-Object System.DirectoryServices.Protocols.LDAPConnection($RootDSE.dc) 
$LDAPConnection.Credential=$cred
$Request = New-Object System.DirectoryServices.Protocols.SearchRequest($RootDSE.distinguishedName, "(&(objectCategory=person)(objectclass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))", "Subtree", $null) 
$DirSyncRC = New-Object System.DirectoryServices.Protocols.DirSyncRequestControl($Cookie, [System.DirectoryServices.Protocols.DirectorySynchronizationOptions]::IncrementalValues, [System.Int32]::MaxValue) 
$Request.Controls.Add($DirSyncRC) | Out-Null 
$Response = $LDAPConnection.SendRequest($Request)
$MoreData = $true
while ($MoreData) {
    $Response.Entries | ForEach-Object { 
        write-host $_.distinguishedName 
        $global:ADUsers += $_ 
    }
    ForEach ($Control in $Response.Controls) { 
        If ($Control.GetType().Name -eq "DirSyncResponseControl") { 
            $Cookie = $Control.Cookie 
            $MoreData = $Control.MoreData 
        } 
    } 
    $DirSyncRC.Cookie = $Cookie 
    $Response = $LDAPConnection.SendRequest($Request) 
}
Set-Content -Value $Cookie -Encoding byte –Path $cookiepath
$global:ADUsers | export-clixml C:\dirsync\aduser.clixml
return $global:adusers
}


Function GetUsername
{
    param($aduser)
    $sam = $aduser.DistinguishedName | dnlookup
    If($sam -ne $null)
    {    
        $username = $domain + $sam
        return $username
    }
return $false
}

function mappinglookup
{
param($ADProps)
$map=@()
foreach ($ADProp in $ADProps)
    {
    Try
        {
        $map+=$mappings.attributes.attr | where {$_.ad -eq $ADprop}
        }
    Catch
        {
        Continue
        }
    }
Return $map
}



Function DnLookup
{
    param([Parameter(ValueFromPipeline=$true)]$DN)
    $lookup=$null
    #DNLookup check to see if the file is created.
    If($DNlookup -eq $null)
    {
        Try
        {
            "Trying to create DNlookup.xml" | out-file $log -Append -noclobber
            $xmlpath = $Location+"DNlookup.xml"
            $xml = New-Object System.XML.XmlTextWriter($xmlpath,$null)
            $xml.Formatting = "Indented"
            $xml.Indentation = 1
            $xml.IndentChar = "`t"
            $xml.WriteStartDocument()
            $xml.WriteProcessingInstruction("xml-stylesheet", "type='text/xsl' href='style.xsl'")
            $xml.WriteStartElement("Users")
            $xml.WriteStartElement("UR")
            $xml.WriteElementString("dn",[string]$DN)

            $dsam=$aduser.Attributes["samaccountname"]
            $sam=Byte2DArrayToString -attr $dsam

            $xml.WriteElementString("sAMAccountName",[string]$sam)

            $xml.WriteEndElement()
            $xml.WriteEndElement()
            $xml.WriteEndDocument()
            $xml.Flush()
            $xml.close()
            [xml]$global:DNlookup = Get-Content -Path $Location"DNLookup.xml"
            "XML Created Successfully" | out-file $log -Append -noclobber
        }
        Catch
        {
            "Failed to create XML file" | out-file $log -Append -noclobber
            $PSItem.Exception | out-file $log -Append -noclobber
            Throw
        }
        Return $sam
    }

    $lookup=$DNlookup.Users.ur | where {$_.dn -eq $DN}

    If ($lookup -eq $null)
    {
       #$newDN=$DNLookup.CreateElement("UR")
       $olddn = @($DNlookup.users.UR)[0]
       $newDN=$olddn.clone()
       If($aduser.Attributes["samaccountname"] -eq $null)
       {
            $adsi = [adsisearcher]""
            $adsi.SearchRoot.Path = $RootDSE.path
            $adsi.filter = "(distinguishedName=$dn)"
            $adsiuser = $adsi.FindOne()
            $sam = $adsiuser.Properties.samaccountname
       }
       Else
       {
            $dsam=$aduser.Attributes["samaccountname"]
            $sam=Byte2DArrayToString -attr $dsam
       }
       $newDN.dn = [string]$DN
       $newDN.samaccountname = [string]$sam
       $DNlookup.Users.AppendChild($newDN) 
       $dnlookup.Save($fileloc)
       return $sam
    }
    $sam = $lookup.samaccountname
    Return $sam
}


Function FindUserProfile
{
param([Parameter(ValueFromPipeline=$true)]$username)

$UserProfile = $pm.GetUserProfile($username)
return $userprofile
}



Function DecodeAttributes
{
    param([Parameter(ValueFromPipeline=$true)]$adusers)
    $date = Get-Date
    [int]$i=1
    $c = $adusers.count
    "New compare started at $date for $($adusers.Count) users"

    Foreach ($ADUser in $adusers)
    {
        $decoded=@()
        [int]$p = ($i/$c)*100
        Write-Progress -Activity "Comparing AD Accounts" -CurrentOperation $aduser.DistinguishedName -PercentComplete $p -Status "$i of $c"
        $un= GetUsername $ADUser
        If($un -eq $false)
        {
            "Could not find $aduser"
            $i++
            Continue
        }
        try 
        {
            $UPAProfile=GetUsername $ADUser | FindUserProfile
        } 
        catch 
        {
            "Could not find User Profile for $un"
            $i++
            Continue
        }
        $maps=mappinglookup $aduser.attributes.AttributeNames
        $ADAtt = $ADUser.attributes
        Foreach ($map in $maps)
        {
            try
            {
                $map
                $m=$map.ad
                $u = $map.upa
                $dd = Byte2DArrayToString -attr $adatt[$m]
                $decoded += @{"$u" = "$dd"}
            }
            Catch
            {
                Continue
            }
        }
    foreach ($d in $decoded)
    {
        $dname = ($d.GetEnumerator()).name
        $upaprop=$upaprofile[$dname].Value
        
        If($upaprop -eq $d.Values)
        {
           Write-Host "$un matches for matches $dname"
        }
        Else
        {
            $adval = $d.values
            "$un has a different value for $dname. AD = $adval; UPA = $upaprop" | out-File $log -Append -NoClobber 
        }

    }

    $i++
    }

}
