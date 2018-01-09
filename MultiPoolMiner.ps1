using module .\Include.psm1

Set-Location (Split-Path $MyInvocation.MyCommand.Path)

# Get all configuration from Config.ps1
If(!(Test-Path -Path '.\Config.ps1')) {
    Throw "Configuration missing!  You must copy Config.sample.ps1 as Config.ps1 and edit the settings."  
} else {
    . .\Config.ps1
}

if (Get-Command "Unblock-File" -ErrorAction SilentlyContinue) {Get-ChildItem . -Recurse | Unblock-File}

if ($Proxy -eq "") {$PSDefaultParameterValues.Remove("*:Proxy")}
else {$PSDefaultParameterValues["*:Proxy"] = $Proxy}

$Algorithm = $Algorithm | ForEach-Object {Get-Algorithm $_}
$ExcludeAlgorithm = $ExcludeAlgorithm | ForEach-Object {Get-Algorithm $_}
$Region = $Region | ForEach-Object {Get-Region $_}

$TotalThreads = ((gwmi win32_processor).numberoflogicalprocessors | Measure-Object -Sum).Sum
$MaxThreads = $TotalThreads
if($ReserveThreads) {
	$MaxThreads = $TotalThreads - $ReserveThreads
}
if ($MaxThreads -lt 1) { $MaxThreads = 1 }
Write-Log "CPU mining limited to $MaxThreads/$TotalThreads of logical processors"

$Strikes = 3

$Timer = (Get-Date).ToUniversalTime()

$StatEnd = $Timer

$DecayStart = $Timer
$DecayPeriod = 60 #seconds
$DecayBase = 1 - 0.1 #decimal percentage

$WatchdogInterval = $Interval * $Strikes
$WatchdogReset = $Interval * $Strikes * $Strikes * $Strikes

$WatchdogTimers = @()

$ActiveMiners = @()

while ($true) {

    Get-ChildItem "APIs" | ForEach-Object {. $_.FullName}

    $Timer = (Get-Date).ToUniversalTime()

    $StatStart = $StatEnd
    $StatEnd = $Timer.AddSeconds($Interval)
    $StatSpan = New-TimeSpan $StatStart $StatEnd

    $DecayExponent = [int](($Timer - $DecayStart).TotalSeconds / $DecayPeriod)

    $WatchdogInterval = ($WatchdogInterval / $Strikes * ($Strikes - 1)) + $StatSpan.TotalSeconds
    $WatchdogReset = ($WatchdogReset / ($Strikes * $Strikes * $Strikes) * (($Strikes * $Strikes * $Strikes) - 1)) + $StatSpan.TotalSeconds

    #Load the stats
    Write-Log "Loading saved statistics..."
    $Stats = [PSCustomObject]@{}
    if (Test-Path "Stats") {Get-ChildItemContent "Stats" | ForEach-Object {$Stats | Add-Member $_.Name $_.Content}}

    #Load information about the pools
    Write-Log "Loading pool information..."
    $NewPools = @()
    if (Test-Path "Pools") {
        $NewPools = Get-ChildItemContent "Pools" -Parameters @{Wallet = $Wallet; UserName = $UserName; WorkerName = $WorkerName; StatSpan = $StatSpan} | ForEach-Object {$_.Content | Add-Member Name $_.Name -PassThru}
    }

    # This finds any pools that were already in $AllPools (from a previous loop) but not in $NewPools. Add them back to the list. Their API likely didn't return in time, but we don't want to cut them off just yet
    # since mining is probably still working.  Then it filters out any algorithms that aren't being used.
    $AllPools = @($NewPools) + @(Compare-Object @($NewPools | Select-Object -ExpandProperty Name -Unique) @($AllPools | Select-Object -ExpandProperty Name -Unique) | Where-Object SideIndicator -EQ "=>" | Select-Object -ExpandProperty InputObject | ForEach-Object {$AllPools | Where-Object Name -EQ $_}) | 
        Where-Object {$Algorithm.Count -eq 0 -or (Compare-Object $Algorithm $_.Algorithm -IncludeEqual -ExcludeDifferent | Measure-Object).Count -gt 0} | 
        Where-Object {$ExcludeAlgorithm.Count -eq 0 -or (Compare-Object $ExcludeAlgorithm $_.Algorithm -IncludeEqual -ExcludeDifferent | Measure-Object).Count -eq 0}

    #Remove non-present pools
    $AllPools = $AllPools | Where-Object {Test-Path "Pools\$($_.Name).ps1"}

    #Apply watchdog to pools
    $AllPools = $AllPools | Where-Object {
        $Pool = $_
        $Pool_WatchdogTimers = $WatchdogTimers | Where-Object PoolName -EQ $Pool.Name | Where-Object Kicked -LT $Timer.AddSeconds( - $WatchdogInterval) | Where-Object Kicked -GT $Timer.AddSeconds( - $WatchdogReset)
        ($Pool_WatchdogTimers | Measure-Object | Select-Object -ExpandProperty Count) -lt <#stage#>3 -and ($Pool_WatchdogTimers | Where-Object {$Pool.Algorithm -contains $_.Algorithm} | Measure-Object | Select-Object -ExpandProperty Count) -lt <#statge#>2
    }

    #Update the active pools
    if ($AllPools.Count -eq 0) {
        Write-Log -Level Warn "No pools available. "
        Start-Sleep $Interval
        continue
    }
    $Pools = [PSCustomObject]@{}

    Write-Log "Selecting best pool for each algorithm..."
    $AllPools.Algorithm | ForEach-Object {$_.ToLower()} | Select-Object -Unique | ForEach-Object {$Pools | Add-Member $_ ($AllPools | Sort-Object -Descending {$PoolName.Count -eq 0 -or (Compare-Object $PoolName $_.Name -IncludeEqual -ExcludeDifferent | Measure-Object).Count -gt 0}, {$ExcludePoolName.Count -eq 0 -or (Compare-Object $ExcludePoolName $_.Name -IncludeEqual -ExcludeDifferent | Measure-Object).Count -eq 0}, {$_.StablePrice * (1 - $_.MarginOfError)}, {$_.Region -EQ $Region}, {$_.SSL -EQ $SSL} | Where-Object Algorithm -EQ $_ | Select-Object -First 1)}
    if (($Pools | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name | ForEach-Object {$Pools.$_} | Measure-Object Updated -Minimum -Maximum | ForEach-Object {$_.Maximum - $_.Minimum} | Select-Object -ExpandProperty TotalSeconds) -gt $Interval * $Strikes) {
        Write-Log -Level Warn "Pool prices are out of sync. "
        $Pools | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name | ForEach-Object {$Pools.$_ | Add-Member Price_Bias ($Pools.$_.StablePrice * (1 - ($Pools.$_.MarginOfError * $SwitchingPrevention * [Math]::Pow($DecayBase, $DecayExponent)))) -Force}
    }
    else {
        $Pools | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name | ForEach-Object {$Pools.$_ | Add-Member Price_Bias ($Pools.$_.Price * (1 - ($Pools.$_.MarginOfError * $SwitchingPrevention * [Math]::Pow($DecayBase, $DecayExponent)))) -Force}
    }

    #Load information about the miners
    #Messy...?
    Write-Log "Getting miner information..."
    # Get all the miners, get just the .Content property and add the name, select only the ones that match our $Type (CPU, AMD, NVIDIA) or all of them if type is unset,
    # select only the ones that have a HashRate matching our algorithms, and that only include algorithms we have pools for
    # select only the miners that match $MinerName, if specified, and don't match $ExcludeMinerName
    $AllMiners = if (Test-Path "Miners") {
        Get-ChildItemContent "Miners" -Parameters @{Pools = $Pools; Stats = $Stats; Threads = $MaxThreads} | ForEach-Object {$_.Content | Add-Member Name $_.Name -PassThru} | 
            Where-Object {$Type.Count -eq 0 -or (Compare-Object $Type $_.Type -IncludeEqual -ExcludeDifferent | Measure-Object).Count -gt 0} | 
            Where-Object {($Algorithm.Count -eq 0 -or (Compare-Object $Algorithm $_.HashRates.PSObject.Properties.Name | Where-Object SideIndicator -EQ "=>" | Measure-Object).Count -eq 0) -and ((Compare-Object $Pools.PSObject.Properties.Name $_.HashRates.PSObject.Properties.Name | Where-Object SideIndicator -EQ "=>" | Measure-Object).Count -eq 0)} | 
            Where-Object {$ExcludeAlgorithm.Count -eq 0 -or (Compare-Object $ExcludeAlgorithm $_.HashRates.PSObject.Properties.Name -IncludeEqual -ExcludeDifferent | Measure-Object).Count -eq 0} | 
            Where-Object {$MinerName.Count -eq 0 -or (Compare-Object $MinerName $_.Name -IncludeEqual -ExcludeDifferent | Measure-Object).Count -gt 0} | 
            Where-Object {$ExcludeMinerName.Count -eq 0 -or (Compare-Object $ExcludeMinerName $_.Name -IncludeEqual -ExcludeDifferent | Measure-Object).Count -eq 0}
    }
    Write-Log "Calculating profit for each miner..."
    $AllMiners | ForEach-Object {
        $Miner = $_

        $Miner_HashRates = [PSCustomObject]@{}
        $Miner_Pools = [PSCustomObject]@{}
        $Miner_Pools_Comparison = [PSCustomObject]@{}
        $Miner_Profits = [PSCustomObject]@{}
        $Miner_Profits_Comparison = [PSCustomObject]@{}
        $Miner_Profits_MarginOfError = [PSCustomObject]@{}
        $Miner_Profits_Bias = [PSCustomObject]@{}

        $Miner_Types = $Miner.Type | Select-Object -Unique
        $Miner_Indexes = $Miner.Index | Select-Object -Unique
        $Miner_Devices = $Miner.Device | Select-Object -Unique

        $Miner.HashRates.PSObject.Properties.Name | ForEach-Object { #temp fix, must use 'PSObject.Properties' to preserve order
            $Miner_HashRates | Add-Member $_ ([Double]$Miner.HashRates.$_)
            $Miner_Pools | Add-Member $_ ([PSCustomObject]$Pools.$_)
            $Miner_Pools_Comparison | Add-Member $_ ([PSCustomObject]$Pools.$_)
            $Miner_Profits | Add-Member $_ ([Double]$Miner.HashRates.$_ * $Pools.$_.Price)
            $Miner_Profits_Comparison | Add-Member $_ ([Double]$Miner.HashRates.$_ * $Pools.$_.StablePrice)
            $Miner_Profits_Bias | Add-Member $_ ([Double]$Miner.HashRates.$_ * $Pools.$_.Price_Bias)
        }

        $Miner_Profit = [Double]($Miner_Profits.PSObject.Properties.Value | Measure-Object -Sum).Sum
        $Miner_Profit_Comparison = [Double]($Miner_Profits_Comparison.PSObject.Properties.Value | Measure-Object -Sum).Sum
        $Miner_Profit_Bias = [Double]($Miner_Profits_Bias.PSObject.Properties.Value | Measure-Object -Sum).Sum

        $Miner.HashRates | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | ForEach-Object {
            $Miner_Profits_MarginOfError | Add-Member $_ ([Double]$Pools.$_.MarginOfError * (& {if ($Miner_Profit) {([Double]$Miner.HashRates.$_ * $Pools.$_.StablePrice) / $Miner_Profit}else {1}}))
        }

        $Miner_Profit_MarginOfError = [Double]($Miner_Profits_MarginOfError.PSObject.Properties.Value | Measure-Object -Sum).Sum

        $Miner.HashRates | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | ForEach-Object {
            if (-not [String]$Miner.HashRates.$_) {
                $Miner_HashRates.$_ = $null
                $Miner_Profits.$_ = $null
                $Miner_Profits_Comparison.$_ = $null
                $Miner_Profits_Bias.$_ = $null
                $Miner_Profit = $null
                $Miner_Profit_Comparison = $null
                $Miner_Profits_MarginOfError = $null
                $Miner_Profit_Bias = $null
            }
        }

        if ($Miner_Types -eq $null) {$Miner_Types = $AllMiners.Type | Select-Object -Unique}
        if ($Miner_Indexes -eq $null) {$Miner_Indexes = $AllMiners.Index | Select-Object -Unique}

        if ($Miner_Types -eq $null) {$Miner_Types = ""}
        if ($Miner_Indexes -eq $null) {$Miner_Indexes = 0}

        $Miner.HashRates = $Miner_HashRates

        $Miner | Add-Member Pools $Miner_Pools
        $Miner | Add-Member Profits $Miner_Profits
        $Miner | Add-Member Profits_Comparison $Miner_Profits_Comparison
        $Miner | Add-Member Profits_Bias $Miner_Profits_Bias
        $Miner | Add-Member Profit $Miner_Profit
        $Miner | Add-Member Profit_Comparison $Miner_Profit_Comparison
        $Miner | Add-Member Profit_MarginOfError $Miner_Profit_MarginOfError
        $Miner | Add-Member Profit_Bias $Miner_Profit_Bias

        $Miner | Add-Member Type ($Miner_Types | Sort-Object) -Force
        $Miner | Add-Member Index ($Miner_Indexes | Sort-Object) -Force

        $Miner | Add-Member Device ($Miner_Devices | Sort-Object) -Force
        $Miner | Add-Member Device_Auto (($Miner_Devices -eq $null) | Sort-Object) -Force

        $Miner.Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Miner.Path)
        if ($Miner.PrerequisitePath) {$Miner.PrerequisitePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Miner.PrerequisitePath)}

        if (-not $Miner.API) {$Miner | Add-Member API "Miner" -Force}
    }
    $Miners = $AllMiners | Where-Object {(Test-Path $_.Path) -and ((-not $_.PrerequisitePath) -or (Test-Path $_.PrerequisitePath))}
    # Open firewall ports for all miners
    if (Get-Command "Get-MpPreference" -ErrorAction SilentlyContinue) {
        if ((Get-Command "Get-MpComputerStatus" -ErrorAction SilentlyContinue) -and (Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
            if (Get-Command "Get-NetFirewallRule" -ErrorAction SilentlyContinue) {
                if ($MinerFirewalls -eq $null) {$MinerFirewalls = Get-NetFirewallApplicationFilter | Select-Object -ExpandProperty Program}
                if (@($AllMiners | Select-Object -ExpandProperty Path -Unique) | Compare-Object @($MinerFirewalls) | Where-Object SideIndicator -EQ "=>") {
                    Start-Process (@{desktop = "powershell"; core = "pwsh"}.$PSEdition) ("-Command Import-Module '$env:Windir\System32\WindowsPowerShell\v1.0\Modules\NetSecurity\NetSecurity.psd1'; ('$(@($AllMiners | Select-Object -ExpandProperty Path -Unique) | Compare-Object @($MinerFirewalls) | Where-Object SideIndicator -EQ '=>' | Select-Object -ExpandProperty InputObject | ConvertTo-Json -Compress)' | ConvertFrom-Json) | ForEach {New-NetFirewallRule -DisplayName 'MultiPoolMiner' -Program `$_}" -replace '"', '\"') -Verb runAs
                    $MinerFirewalls = $null
                }
            }
        }
    }

    #Apply watchdog to miners
    $Miners = $Miners | Where-Object {
        $Miner = $_
        $Miner_WatchdogTimers = $WatchdogTimers | Where-Object MinerName -EQ $Miner.Name | Where-Object Kicked -LT $Timer.AddSeconds( - $WatchdogInterval) | Where-Object Kicked -GT $Timer.AddSeconds( - $WatchdogReset)
        ($Miner_WatchdogTimers | Measure-Object | Select-Object -ExpandProperty Count) -lt <#stage#>2 -and ($Miner_WatchdogTimers | Where-Object {$Miner.HashRates.PSObject.Properties.Name -contains $_.Algorithm} | Measure-Object | Select-Object -ExpandProperty Count) -lt <#stage#>1
    }

    #Update the active miners
    if ($Miners.Count -eq 0) {
        Write-Log -Level Warn "No miners available. "
        Start-Sleep $Interval
        continue
    }
    $ActiveMiners | ForEach-Object {
        $_.Profit = 0
        $_.Profit_Comparison = 0
        $_.Profit_MarginOfError = 0
        $_.Profit_Bias = 0
        $_.Best = $false
        $_.Best_Comparison = $false
    }
    $Miners | ForEach-Object {
        $Miner = $_
        $ActiveMiner = $ActiveMiners | Where-Object {
            $_.Name -eq $Miner.Name -and 
            $_.Path -eq $Miner.Path -and 
            $_.Arguments -eq $Miner.Arguments -and 
            $_.Wrap -eq $Miner.Wrap -and 
            $_.API -eq $Miner.API -and 
            $_.Port -eq $Miner.Port -and 
            (Compare-Object $_.Algorithm ($Miner.HashRates | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name) | Measure-Object).Count -eq 0
        }
        if ($ActiveMiner) {
            $ActiveMiner.Type = $Miner.Type
            $ActiveMiner.Index = $Miner.Index
            $ActiveMiner.Device = $Miner.Device
            $ActiveMiner.Device_Auto = $Miner.Device_Auto
            $ActiveMiner.Profit = $Miner.Profit
            $ActiveMiner.Profit_Comparison = $Miner.Profit_Comparison
            $ActiveMiner.Profit_MarginOfError = $Miner.Profit_MarginOfError
            $ActiveMiner.Profit_Bias = $Miner.Profit_Bias
            $ActiveMiner.Speed = $Miner.HashRates.PSObject.Properties.Value #temp fix, must use 'PSObject.Properties' to preserve order
        }
        else {
            $ActiveMiners += New-Object $Miner.API -Property @{
                Name                 = $Miner.Name
                Path                 = $Miner.Path
                Arguments            = $Miner.Arguments
                Wrap                 = $Miner.Wrap
                API                  = $Miner.API
                Port                 = $Miner.Port
                Algorithm            = $Miner.HashRates.PSObject.Properties.Name #temp fix, must use 'PSObject.Properties' to preserve order
                Type                 = $Miner.Type
                Index                = $Miner.Index
                Device               = $Miner.Device
                Device_Auto          = $Miner.Device_Auto
                Profit               = $Miner.Profit
                Profit_Comparison    = $Miner.Profit_Comparison
                Profit_MarginOfError = $Miner.Profit_MarginOfError
                Profit_Bias          = $Miner.Profit_Bias
                Speed                = $Miner.HashRates.PSObject.Properties.Value #temp fix, must use 'PSObject.Properties' to preserve order
                Speed_Live           = 0
                Best                 = $false
                Best_Comparison      = $false
                Process              = $null
                New                  = $false
                Active               = [TimeSpan]0
                Activated            = 0
                Status               = ""
                Benchmarked          = 0
            }
        }
    }

    #Don't penalize active miners
    $ActiveMiners | Where-Object Status -EQ "Running" | ForEach-Object {$_.Profit_Bias = $_.Profit}

    #Get most profitable miner
    $ActiveMiners | Sort-Object -Descending {($_ | Where-Object Profit -EQ $null | Measure-Object).Count}, {($_ | Measure-Object Profit_Bias -Sum).Sum}, {($_ | Where-Object Profit -NE 0 | Measure-Object).Count} | Select-Object -First 1 | Foreach-Object {$_.Best = $True}

    #Stop or start miners in the active list depending on if they are the most profitable
    $ActiveMiners | Where-Object Activated -GT 0 | Where-Object Best -EQ $false | ForEach-Object {
        $Miner = $_

        if ($Miner.Process -eq $null -or $Miner.Process.HasExited) {
            if ($Miner.Status -eq "Running") {
                $Miner.Status = "Failed"
                if($Miner.Process -eq $null) {
                    Write-Log -Level Warn "$($Miner.Type) miner $($Miner.Name) failed - process handle is missing"
                }
                if($Miner.Process.HasExited) {
                    Write-Log -Level Warn "$($Miner.Type) miner $($Miner.Name) failed - process exited on it's own"
                }
            }
        }
        else {
            Write-Log "Closing $($Miner.Type) miner $($Miner.Name) [PID $($_.Process.Id)] because it is no longer the most profitable"
            $Miner.StopMining()

            #Remove watchdog timer
            $Miner_Name = $Miner.Name
            $Miner.Algorithm | ForEach-Object {
                $Miner_Algorithm = $_
                $WatchdogTimer = $WatchdogTimers | Where-Object {$_.MinerName -eq $Miner_Name -and $_.PoolName -eq $Pools.$Miner_Algorithm.Name -and $_.Algorithm -eq $Miner_Algorithm}
                if ($WatchdogTimer) {
                    if ($WatchdogTimer.Kicked -lt $Timer.AddSeconds( - $WatchdogInterval)) {
                        $Miner.Status = "Failed"
                    }
                    else {
                        $WatchdogTimers = $WatchdogTimers -notmatch $WatchdogTimer
                    }
                }
            }
        }
    }

    # Kill any miners that are running that aren't expected to be running right now. This is the sledgehammer approach to fixing multiple copies of the same miner running for no good reason.
    # It's not a condition that should happen, but sometimes a PID doesn't get returned properly and a miner is left running without being accounted for.
    $ExpectedPIDs = ($ActiveMiners | Where-Object {$_.Status -eq "Running"} | Select-Object -ExpandProperty process).id
    $ActualPIDs = (Get-Process | Where-Object {$_.Path -like "$((Get-Location).Path)*" }).id
    If($ExpectedPIDs -and $ActualPIDs) {
      Compare-Object $ExpectedPIDs $ActualPIDs | Where-Object SideIndicator -eq "=>" | Select-Object -ExpandProperty InputObject | Foreach-Object {
        # Check if it's parent is an expected PID - because it was launched by Wrapper.ps1
        Write-Log -Level Error "Checking on PID $_"
        Write-Log -Level Error "Allowed PIDS: $ExpectedPIDs"
        $ParentPID = (gwmi win32_process -filter "processid='$_'").ParentProcessId
        Write-Log -Level Error "Parent: $ParentPID"
        if($ExpectedPIDs -notcontains $ParentPID) {
          Write-Log -Level Error "Killing PID $_ - it was not supposed to be running"
          Stop-Process -Force -Id $_
        }
      }
    }

    Start-Sleep $Delay #Wait to prevent BSOD
    $ActiveMiners | Where-Object Best -EQ $true | ForEach-Object {
        if ($_.Process -eq $null -or $_.Process.HasExited -ne $false) {
            Write-Log "Starting $($_.Type) miner $($_.Name): '$($_.Path) $($_.Arguments)'"
            $DecayStart = $Timer
            $_.StartMining()

            #Add watchdog timer
            if ($Watchdog -and $_.Profit -ne $null) {
                $Miner_Name = $_.Name
                $_.Algorithm | ForEach-Object {
                    $Miner_Algorithm = $_
                    $WatchdogTimer = $WatchdogTimers | Where-Object {$_.MinerName -eq $Miner_Name -and $_.PoolName -eq $Pools.$Miner_Algorithm.Name -and $_.Algorithm -eq $Miner_Algorithm}
                    if (-not $WatchdogTimer) {
                        $WatchdogTimers += [PSCustomObject]@{
                            MinerName = $Miner_Name
                            PoolName  = $Pools.$Miner_Algorithm.Name
                            Algorithm = $Miner_Algorithm
                            Kicked    = $Timer
                        }
                    }
                    elseif (-not ($WatchdogTimer.Kicked -GT $Timer.AddSeconds( - $WatchdogReset))) {
                        $WatchdogTimer.Kicked = $Timer
                    }
                }
            }
        }
    }

    if ($MinerStatusURL) {& .\ReportStatus.ps1 -Address $Wallet -WorkerName $WorkerName -ActiveMiners $ActiveMiners -Miners $Miners -MinerStatusURL $MinerStatusURL}

    #Display mining information
    $Miners | Sort-Object -Descending Type, Profit_Bias | Format-Table (
        @{Label = "Miner"; Expression = {$_.Name}}, 
        @{Label = "Algorithm"; Expression = {$_.HashRates.PSObject.Properties.Name}}, 
        @{Label = "Speed"; Expression = {$_.HashRates.PSObject.Properties.Value | ForEach-Object {if ($_ -ne $null) {"$($_ | ConvertTo-Hash)/s"}else {"Benchmarking"}}}; Align = 'right'}, 
        @{Label = "Accuracy"; Expression = {$_.Pools.PSObject.Properties.Value.MarginOfError | ForEach-Object {(1 - $_).ToString("P0")}}; Align = 'right'}, 
	@{Label = "BTC/Day"; Expression = {$_.Profits.PSObject.Properties.Value | ForEach-Object {if ($_ -ne $null) {$_.ToString("N5")}else {"Benchmarking"}}}; Align = 'right'}, 
        @{Label = "Pool"; Expression = {$_.Pools.PSObject.Properties.Value | ForEach-Object {if ($_.Info) {"$($_.Name)-$($_.Info)"}else {"$($_.Name)"}}}}
    ) | Out-Host

    #Reduce Memory
    Get-Job -State Completed | Remove-Job
    [GC]::Collect()

    #Do nothing for a few seconds as to not overload the APIs and display miner download status
    Write-Log "Waiting for $Interval seconds to start next run"
    for ($i = $Strikes; $i -gt 0 -or $Timer -lt $StatEnd; $i--) {
        Start-Sleep 10
        $Timer = (Get-Date).ToUniversalTime()
    }

    #Save current hash rates
    Write-Log "Saving hash rates..."
    $ActiveMiners | ForEach-Object {
        $Miner = $_
        $Miner.Speed_Live = 0
        $Miner_HashRate = [PSCustomObject]@{}

        if ($Miner.New) {$Miner.Benchmarked++}

        if ($Miner.Process -and -not $Miner.Process.HasExited) {
            $Miner_HashRate = $Miner.GetHashRate($Miner.Algorithm, ($Miner.New -and $Miner.Benchmarked -lt $Strikes))
            $Miner.Speed_Live = $Miner_HashRate.PSObject.Properties.Value

            $Miner.Algorithm | Where-Object {$Miner_HashRate.$_} | ForEach-Object {
                $Stat = Set-Stat -Name "$($Miner.Name)_$($_)_HashRate" -Value $Miner_HashRate.$_ -Duration $StatSpan -FaultDetection $true

                #Update watchdog timer
                $Miner_Name = $Miner.Name
                $Miner_Algorithm = $_
                $WatchdogTimer = $WatchdogTimers | Where-Object {$_.MinerName -eq $Miner_Name -and $_.PoolName -eq $Pools.$Miner_Algorithm.Name -and $_.Algorithm -eq $Miner_Algorithm}
                if ($Stat -and $WatchdogTimer -and $Stat.Updated -gt $WatchdogTimer.Kicked) {
                    $WatchdogTimer.Kicked = $Stat.Updated
                }

                $Miner.New = $false
            }
        }

        #Benchmark timeout
        if ($Miner.Benchmarked -ge ($Strikes * $Strikes) -or ($Miner.Benchmarked -ge $Strikes -and $Miner.Activated -ge $Strikes)) {
            $Miner.Algorithm | Where-Object {-not $Miner_HashRate.$_} | ForEach-Object {
                if ((Get-Stat "$($Miner.Name)_$($_)_HashRate") -eq $null) {
                    $Stat = Set-Stat -Name "$($Miner.Name)_$($_)_HashRate" -Value 0 -Duration $StatSpan
                }
            }
        }
    }
    Write-Log "Starting next run..."
}

#Stop the log
Stop-Transcript
