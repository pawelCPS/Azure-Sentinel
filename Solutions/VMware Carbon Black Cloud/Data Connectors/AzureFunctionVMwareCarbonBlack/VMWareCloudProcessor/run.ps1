# Input bindings are passed in via param block.
param($QueueItem, $TriggerMetadata)



# Write out the queue message and insertion time to the information log.
Write-Host "PowerShell queue trigger function processed work item: $QueueItem"
Write-Host "Queue item insertion time: $($TriggerMetadata.InsertionTime)"
<#
.SYNOPSIS
This is used to process the carbon black files from AWS

.DESCRIPTION
Long description

.EXAMPLE
An example

.NOTES
General notes
#>
function ProcessBucketFiles ()
{
    $time = $env:timeInterval
    $startTime = [System.DateTime]::UtcNow.AddMinutes(-$($time))
    $OrgKey = $env:CarbonBlackOrgKey
    $now = [System.DateTime]::UtcNow
    $workspaceId = $env:workspaceId
    $workspaceSharedKey = $env:workspaceKey
    $AWSAccessKeyId = $env:AWSAccessKeyId
    $AWSSecretAccessKey = $env:AWSSecretAccessKey
    $queueName=$env:queueName
    $carbonBlackStorage=$env:AzureWebJobsStorage

        $totalEvents = GetBucketDetails -s3BucketName $QueueItem["s3BucketName"] -prefixFolder $QueueItem["keyPrefix"] -tableName $QueueItem["tableName"] -logtype $QueueItem["logtype"]
        if (-not([string]::IsNullOrWhiteSpace($totalEvents)))
        {
            try {
                    ProcessData -alleventobjs $totalEvents -logtype $QueueItem["tableName"] -endTime $([DateTime]::UtcNow)
                    Write-Host "Pushed events to $($QueueItem["tableName"])"
                }
            catch {
                    $string_err = $_ | Out-String
                    Write-Host $string_err
                }
            Write-Host("$($responseObj.count) new Carbon Black Events as of $([DateTime]::UtcNow). Pushed data to Azure sentinel Status code:$($status)")	
        }
        Write-Host "Successfully processed the carbon black files from AWS and FA instance took $(([System.DateTime]::UtcNow - $now).Seconds) seconds to process the data"
    }


    # Function to build the authorization signature to post to Log Analytics
    function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource) {
        $xHeaders = "x-ms-date:" + $date;
        $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource;
        $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash);
        $keyBytes = [Convert]::FromBase64String($sharedKey);
        $sha256 = New-Object System.Security.Cryptography.HMACSHA256;
        $sha256.Key = $keyBytes;
        $calculatedHash = $sha256.ComputeHash($bytesToHash);
        $encodedHash = [Convert]::ToBase64String($calculatedHash);
        $authorization = 'SharedKey {0}:{1}' -f $customerId, $encodedHash;
        return $authorization;
    }

# Function to POST the data payload to a Log Analytics workspace
function Post-LogAnalyticsData($customerId, $sharedKey, $body, $logType) {
    $TimeStampField = "DateValue"
    $method = "POST";
    $contentType = "application/json";
    $customerId = $customerId
    $resource = "/api/logs";
    $rfc1123date = [DateTime]::UtcNow.ToString("r");
    $contentLength = $body.Length;
    $signature = Build-Signature -customerId $customerId -sharedKey $sharedKey -date $rfc1123date -contentLength $contentLength -method $method -contentType $contentType -resource $resource;
    if ([string]::IsNullOrEmpty($logAnalyticsUri)) {
        $logAnalyticsUri = "https://" + $customerId + ".ods.opinsights.azure.com"
    }
    # Returning if the Log Analytics Uri is in incorrect format.
    # Sample format supported: https://" + $customerId + ".ods.opinsights.azure.com
    if ($logAnalyticsUri -notmatch 'https:\/\/([\w\-]+)\.ods\.opinsights\.azure.([a-zA-Z\.]+)$') {
        throw "Netskope: Invalid Log Analytics Uri."
    }
    $logAnalyticsUri = $logAnalyticsUri + $resource + "?api-version=2016-04-01"

    $headers = @{
        "Authorization"        = $signature;
        "Log-Type"             = $logType;
        "x-ms-date"            = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    };
    $response = Invoke-WebRequest -Body $body -Uri $logAnalyticsUri -Method $method -ContentType $contentType -Headers $headers -UseBasicParsing
    return $response.StatusCode
}

Function EventsFieldsMapping {
    Param (
        $events
    )
    Write-Host "Started Field Mapping for event logs"

    $fieldMappings = @{
        'shortDescription' = 'event_description'
        'createTime' = 'backend_timestamp'
        'eventId' = 'event_id'
        'longDescription' = 'event_description'
        'eventTime' = 'device_timestamp'
        'securityEventCode' = 'alert_id'
        'eventType' = 'type'
        'incidentId' = 'alert_id'
        'deviceDetails_deviceIpAddress' = 'device_external_ip'
        'deviceDetails_deviceIpV4Address' = 'device_external_ip'
        'deviceDetails_deviceId' = 'device_id'
        'deviceDetails_deviceName' = 'device_name'
        'deviceDetails_deviceType' = 'device_os'
        'deviceDetails_msmGroupName' = 'device_group'
        'netFlow_peerFqdn' = 'netconn_domain'
        'netFlow_peerIpAddress' = 'remote_ip'
        'processDetails_name' = 'process_name'
        'processDetails_commandLine' = 'process_cmdline'
        'processDetails_fullUserName' ='process_username'
        'processDetails_processId'='process_pid'
        'processDetails_parentCommandLine' = 'process_cmdline'
        'processDetails_parentName' = 'parent_path'
        'processDetails_parentPid' = 'parent_pid'
        'processDetails_targetCommandLine' = 'target_cmdline'
    }

    $fieldMappings.GetEnumerator() | ForEach-Object {
        if (!$events.ContainsKey($_.Name))
        {
            $events[$_.Name] = $events[$_.Value]
        }
    }
}

Function AlertsFieldsMapping {
    Param (
        $alerts
    )
    Write-Host "Started Field Mapping for alert logs"

    $fieldMappings = @{
        'threatHunterInfo_summary' = 'reason_code'
        'threatHunterInfo_time' = 'create_time'
        'threatHunterInfo_indicators' = 'threat_indicators'
        'threatHunterInfo_count' = '0'
        'threatHunterInfo_dismissed' = 'workflow.state'
        'threatHunterInfo_firstActivityTime' = 'first_event_time'
        'threatHunterInfo_policyId' = 'process_guid'
        'threatHunterInfo_processPath' = 'severity'
        'threatHunterInfo_reportName' = 'report_name'
        'threatHunterInfo_reportId' = 'report_id'
        'threatHunterInfo_reputation' = 'threat_cause_reputation'
        'threatHunterInfo_responseAlarmId' = 'id'
        'threatHunterInfo_responseSeverity' = 'Severity'
        'threatHunterInfo_runState' = 'run_state'
        "threatHunterInfo_sha256_" = "threat_cause_actor_sha256"
        "threatHunterInfo_status" = "status"
        "threatHunterInfo_targetPriority" = "target_value"
        "threatHunterInfo_threatCause_reputation" = "threat_cause_reputation"
        "threatHunterInfo_threatCause_actor" = "threat_cause_actor_sha256"
        "threatHunterInfo_threatCause_actorName" = "threat_cause_actor_name"
        "threatHunterInfo_threatCause_reason" = "reason_code"
        "threatHunterInfo_threatCause_threatCategory" = "threat_cause_threat_category"
        "threatHunterInfo_threatCause_originSourceType" = "threat_cause_vector"
        "threatHunterInfo_threatId" = "threat_id"
        "threatHunterInfo_lastUpdatedTime" = "last_update_time"
        #"threatHunterInfo_orgId_d": "12261",
        "threatInfo_incidentId" = "legacy_alert_id"
        "threatInfo_score" = "severity"
        "threatInfo_summary" = "reason"
        #"threatInfo_time_d": "null",
        "threatInfo_indicators" = "threat_indicators"
        "threatInfo_threatCause_reputation" = "threat_cause_reputation"
        "threatInfo_threatCause_actor" = "threat_cause_actor_sha256"
        "threatInfo_threatCause_reason" = "reason_code"
        "threatInfo_threatCause_threatCategory" = "threat_cause_threat_catego"
        "threatInfo_threatCause_actorProcessPPid" = "threat_cause_actor_process_pid"
        "threatInfo_threatCause_causeEventId" = "threat_cause_cause_event_id"
        "threatInfo_threatCause_originSourceType" = "threat_cause_vector"
        "url" = "alert_url"
        "eventTime" = "create_time"
        #"eventDescription_s": "[AzureSentinel] [Carbon Black has detected a threat against your company.] [https://defense-prod05.conferdeploy.net#device/20602996/incident/NE2F3D55-013a6074-000013b0-00000000-1d634654ecf865f-GUWNtEmJQhKmuOTxoRV8hA-6e5ae551-1cbb-45b3-b7a1-1569c0458f6b] [Process powershell.exe was detected by the report \"Execution - Powershell Execution With Unrestriced or Bypass Flags Detected\" in watchlist \"Carbon Black Endpoint Visibility\"] [Incident id: NE2F3D55-013a6074-000013b0-00000000-1d634654ecf865f-GUWNtEmJQhKmuOTxoRV8hA-6e5ae551-1cbb-45b3-b7a1-1569c0458f6b] [Threat score: 6] [Group: Standard] [Email: sanitized@sanitized.com] [Name: Endpoint2] [Type and OS: WINDOWS pscr-sensor] [Severity: 6]\n",
        "deviceInfo_deviceId" = "device_id"
        "deviceInfo_deviceName" = "device_name"
        "deviceInfo_groupName" = "policy_name"
        "deviceInfo_email" = "device_username"
        "deviceInfo_deviceType" = "device_os"
        "deviceInfo_deviceVersion" = "device_os_version"
        "deviceInfo_targetPriorityType" = "target_value"
       # "deviceInfo_targetPriorityCode_d": "0",
        "deviceInfo_uemId" = "device_uem_id"
        "deviceInfo_internalIpAddress" = "device_internal_ip"
        "deviceInfo_externalIpAddress" = "device_external_ip"
    }

    $fieldMappings.GetEnumerator() | ForEach-Object {
        if (!$alerts.ContainsKey($_.Name))
        {
            $alerts[$_.Name] = $alerts[$_.Value]
        }
    }
}
<#
.SYNOPSIS
This method is extract the GZ file format

.DESCRIPTION
Long description

.PARAMETER infile
Parameter description

.PARAMETER outfile
Parameter description

.EXAMPLE
An example

.NOTES
General notes
#>


<#
.SYNOPSIS
This method is used to split the data based on size and post to log analytics work space

.DESCRIPTION
Long description

.PARAMETER customerId
Parameter description

.PARAMETER sharedKey
Parameter description

.PARAMETER payload
Parameter description

.PARAMETER logType
Parameter description

.EXAMPLE
An example

.NOTES
General notes
#>
function SplitDataAndProcess($customerId, $sharedKey, $payload, $logType) {
    $tempdata = @()
    $tempdataLength = 0
    $tempDataSize = 0
    $StartTime = (Get-Date).ToUniversalTime()
    try {
        if ((($payload |  Convertto-json -depth 3).Length) -gt 25MB) {
            Write-Host "Upload is over 25MB, needs to be split"
            foreach ($record in $payload) {
                $tempdata += $record
                $tempdataLength = $tempdata.Count
                $tempDataSize += ($record  | ConvertTo-Json).Length
                if ($tempDataSize -gt 25MB) {
                    write-Host "Sending data to log analytics when data size = $TempDataSize greater than 25mb post chuncking the data and length of events = $tempdataLength"
                    $responseCode = Post-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes(($tempdata | ConvertTo-Json))) -logType $logType
                    Write-Host "Post-LogAnalyticsData response code is $($responseCode) for LogType : $($logType)"
                    $tempdata = $null
                    $tempdata = @()
                    $tempDataSize = 0
                    $tempdataLength = 0
                }
            }
            Write-Host "Sending left over data = $Tempdatasize after all the chuncking of done is completed. Now datasize will be < 25mb and length of events = $tempdataLength"
            $responseCode = Post-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes(($tempdata | ConvertTo-Json))) -logType $logType
            $elapsedTime = (Get-Date).ToUniversalTime() - $StartTime
        }
        $totalTime = "{0:HH:mm:ss}" -f ([datetime]$elapsedTime.Ticks)
        Write-Host "Total Time taken to Split and Process this data = $totalTime"
        return $responseCode
    }
    catch {
        Write-Host "Error, error message: $($Error[0].Exception.Message)"
    }
}   

<#
.SYNOPSIS
This is used to process the carbon black data

.DESCRIPTION
Long description

.PARAMETER alleventobjs
Parameter description

.PARAMETER logtype
Parameter description

.PARAMETER endTime
Parameter description

.EXAMPLE
An example

.NOTES
General notes
#>
 function ProcessData($alleventobjs, $logtype, $endTime) {
    Write-Host "Process Data function:- EventsLength - $($alleventobjs), Logtype - $($logtype) and Endtime - $($endTime)"
    $customerId = $env:workspaceId
    $sharedKey = $env:workspacekey
    $responseCode = 200
    if ($null -ne $alleventobjs ) {
        $jsonPayload = $alleventobjs | ConvertTo-Json -Depth 3
        $mbytes = ([System.Text.Encoding]::UTF8.GetBytes($jsonPayload)).Count / 1024 / 1024
        Write-Host "Total mbytes :- $($mbytes) for type :- $($logtype)"
        # Check the payload size, if under 30MB post to Log Analytics.
        if (($mbytes -le 30)) {
            $responseCode = Post-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonPayload)) -logType $logtype
            if($responseCode -eq 200){
                Write-Host "SUCCESS: $alleventobjs total '$logType' events posted to Log Analytics: $mbytes MB" -ForegroundColor Green
                #DeleteMessageFromQueue
            }
        }
        else {
            Write-Host "Warning!: Total data size is > 30mb hence performing the operation of split and process."
            $responseCode = SplitDataAndProcess -customerId $customerId -sharedKey $sharedKey -payload $alleventobjs -logType $logtype
        }
    }
    else {
        $startInterval = (Get-Date 01.01.1970) + ([System.TimeSpan]::fromseconds($startTime))
        $endInterval = (Get-Date 01.01.1970) + ([System.TimeSpan]::fromseconds($endTime))
        Write-Host "INFO: No new '$logtype' records created between $startInterval and $endInterval"
    }
    return $responseCode
}
<#
.SYNOPSIS
This method is used to delete message from queue

.DESCRIPTION
Long description

.EXAMPLE
An example

.NOTES
General notes
#>
<#
.SYNOPSIS
This method is used to get the bucket details i.e. carbon black cloud files from AWS

.DESCRIPTION
Long description

.PARAMETER s3BucketName
Parameter description

.PARAMETER prefixFolder
Parameter description

.PARAMETER tableName
Parameter description

.PARAMETER logtype
Parameter description

.EXAMPLE
An example

.NOTES
General notes
#>
function  GetBucketDetails {
    param (
        $s3BucketName,
        $prefixFolder,
        $tableName,
        $logtype
    )
    $aggregatedEvents = [System.Collections.ArrayList]::new()
    try {
        IF ($Null -ne $s3BucketName) {
            Set-AWSCredentials -AccessKey $AWSAccessKeyId -SecretKey $AWSSecretAccessKey
            if($startTime -le $now) {
                $keyValuePairs = $prefixFolder -split '\\'
                $s3Dict = @{}
                foreach ($pair in $keyValuePairs) {
                    $key, $value = $pair -split '='
                    $s3Dict[$key] = $value
                }
                $keyPrefix = "$($keyValuePairs[0])/org_key=$OrgKey/year=$($s3Dict["year"])/month=$($s3Dict["month"])/day=$($s3Dict["day"])/hour=$($s3Dict["hour"])/minute=$($s3Dict["minute"])/second=$($s3Dict["second"])"
                $obj = Get-S3Object -BucketName $s3BucketName -keyPrefix $keyPrefix
                if ($null -eq $obj -or $obj -eq "") {
                    Write-Host "The folder/file $keyPrefix does not exist in the bucket $s3BucketName"
                    exit
                } else {
                Write-Host "Object $key is $($obj.Size) bytes"
                $sql = "select * from s3object"
                $inputSerialization = New-Object Amazon.S3.Model.InputSerialization
                $inputSerialization.JSON = New-Object Amazon.S3.Model.JSONInput
                $inputSerialization.JSON.JsonType = 'DOCUMENT'
                $inputSerialization.CompressionType = 'GZIP'
                $outSerialization = New-Object Amazon.S3.Model.OutputSerialization
                $outSerialization.JSON = New-Object Amazon.S3.Model.JSONOutput
                $obj | % {
                    try {
                        if ($_.Size -gt 0) {
                            $loopItem = $_
                            $time = [System.DateTime]::UtcNow
                            Write-Host "Making request to AWS for downloading file startTime: $time, S3Bucket: $($_.BucketName), S3File: $($_.Key) "
                            $result = Select-S3ObjectContent `
                            -Expression $sql `
                            -Bucket $_.BucketName `
                            -ExpressionType "SQL" `
                            -InputSerialization $inputSerialization `
                            -OutputSerialization $outSerialization `
                            -Key $_.Key
                            # read the data from $result.Payload which is a memorystream
                            $data = New-Object System.IO.StreamReader($result.Payload)
                            $outputStream = $data.ReadToEnd()
                            Write-Host "Download from AWS completed.  S3File: $($_.Key), S3Bucket: $($_.BucketName), FileSize in mb: $($outputStream.Length/1MB), from AWS S3 successfully time in Seconds: $(([System.DateTime]::UtcNow - $time).Seconds)"
                            $data.Close()
                            #clean
                            $data.Dispose()
                            $events = DataTransformation -data $outputStream -tableName $tableName -logtype $logtype
                            $aggregatedEvents.Add($events)
                            }
                    }
                    catch {
                        $err = $_.Exception.Message
                        Write-Host "Error in downloading file from AWS S3. S3File: $($loopItem.Key), S3Bucket: $($loopItem.BucketName), Error: $err"
                    }
                }
            }
            }
        }
    }
    catch {
        $string_err = $_ | Out-String
         Write-Host $string_err
    }
    return $aggregatedEvents
}

function DataTransformation
{
    param (
        $data,
        $tableName,
        $logtype
    )
        $logs = $data | ConvertFrom-Json
        $hash = @{}
        $logs.psobject.properties | foreach{$hash[$_.Name]= $_.Value}
        $logevents = $hash

        if($logtype -eq "event")
        {
            EventsFieldsMapping -events $logevents
        }
        if($logtype -eq "alert")
        {
            AlertsFieldsMapping -alerts $logevents
        }
        return $logevents
    }

ProcessBucketFiles