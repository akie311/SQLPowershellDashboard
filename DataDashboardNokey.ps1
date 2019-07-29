function messageSlack ($channel,$metric,$value) {
    $percentOrValue = '%'
    if ($metric -eq 'PageLifeExpectancy')
        {$percentOrValue = ''}
    $token=''
    Send-SlackMessage -Token $token -Channel "$channel" -Text "The $metric is over the threshold. It is currently at $value$percentOrValue. Please resolve."
}

function loadCPUData ($dbname, $serverName, $instanceName, $user, $password) {
    $CpuLoad = (Get-WmiObject win32_processor | Measure-Object -property LoadPercentage -Average | Select Average ).Average
    $violationBit=0
    $CpuThreshold = Invoke-sqlcmd -Query "select threshold from $dbname.dbo.Metrics where MetricName='CPU'" -ServerInstance "$serverName\$instanceName" -Username $user -Password $password
    if ($CpuLoad -gt $CpuThreshold[0]) {$violationBit=1}
    Invoke-Sqlcmd -Query "insert into $dbname.dbo.CurrentMetric values (1,$CpuLoad,$violationBit)" -ServerInstance "$serverName\$instanceName" -Username $user -Password $password
}

function gatherDisplayData ($dbname, $metricID, $serverName, $instanceName, $userName, $password) {
    $Results = Invoke-Sqlcmd -Query "select CM.Value, CM.ViolationBit,  M.MetricName, C.ContactName 
                                    from $dbname.dbo.CurrentMetric CM 
                                    inner join $dbname.dbo.Metrics M on M.MetricID=CM.MetricId 
                                    inner join $dbname.dbo.Contacts C on M.ContactID=C.ContactID 
                                    where CM.MetricID=$metricID"  -ServerInstance "$serverName\$instanceName" -Username $userName -Password $password 
    $Metric = $Results[2]
    $Value = $Results[0]
    #if the violation detection bit is set to true, message the sysadmin channel on slack
    if ($Results[1] -eq 1) {
        messageSlack -channel $Results[3] -metric $Results[2] -value $Results[0] > $null
        $ErrorDate = Invoke-Sqlcmd -Query "select Date from $dbname.dbo.Violations where MetricID=$metricID" -ServerInstance "$serverName\$instanceName" -Username $user -Password $password
        $ErrorDate=$ErrorDate[0]
        Write-Host -ForegroundColor Red "- $Metric - Currently in violation beginning at $ErrorDate"
        echo "$Value`n"
        }
    else {
        echo "- $Metric -"
        echo "$Value`n"
    }
}

function displayLiveData ($dbname, $serverName, $instanceName, $user, $password) {
    #run stored procedure that gathers all of the statistics for memory and PLE
    Invoke-Sqlcmd -Query "exec $dbname.[dbo].[GatherMetrics]" -ServerInstance "$serverName\$instanceName" -Username $user -Password $password -QueryTimeout 2
    #clear the shell to make the dashboard appear to refresh instantly
    clear
    $numOfMetrics = Invoke-Sqlcmd -Query "select count(*) from $dbname.dbo.CurrentMetric" -ServerInstance "$serverName\$instanceName" -Username $user -Password $password
    $numOfMetricsCounter = [int]$numOfMetrics[0]
    while ($numOfMetricsCounter -gt 0)
        { 
            gatherDisplayData -dbname $dbname -metricID $numOfMetricsCounter -serverName $serverName -instanceName $instanceName -userName $user -password $password
            $numOfMetricsCounter= $numOfMetricsCounter-1 
        }
    
    #truncate the current data table to make room for the next batch of data
    Invoke-Sqlcmd -Query "truncate table $dbname.dbo.CurrentMetric" -ServerInstance "$serverName\$instanceName" -Username $user -Password $password
}



#prompt the user for information about the database they are connecting to and querying
$dbInput = Read-Host -Prompt "Database Name: "
$serverInput = Read-Host -Prompt "Server Name: "
$instanceInput = Read-Host -Prompt "Instance Name: "
$userInput = Read-Host -Prompt "Username: "

#hide the password from the console
$passwordInput = Read-Host -Prompt "Password: " -asSecureString         
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($passwordInput)            
$passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

#continue to run the command, refreshing the data and alerting the user, sleeping for 5 seconds, and then refreshing
while (1 -eq 1) {
    loadCPUData -dbname $dbInput -servername $serverInput -instanceName $instanceInput -user $userInput -password $passwordPlain
    displayLiveData -dbname $dbInput -servername $serverInput -instanceName $instanceInput -user $userInput -password $passwordPlain
    Start-Sleep -Seconds 5
    }
