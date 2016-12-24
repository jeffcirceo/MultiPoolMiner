﻿param(
    [Parameter(Mandatory=$true)]
    [String]$UserName, 
    [Parameter(Mandatory=$false)]
    [String]$WorkerName = "MultiPoolMiner", 
    [Parameter(Mandatory=$false)]
    [String]$Wallet
)

Set-Location (Split-Path $script:MyInvocation.MyCommand.Path)

. .\Include.ps1

$Interval = 60 #seconds
$Delta = 0.10 #decimal percentage

$ActiveMinerPrograms = @()

#Start the log
Start-Transcript ".\Logs\$(Get-Date -Format "yyyy-MM-dd_hh-mm-ss").txt"

while($true)
{
    #Load the Stats
    $Stats = [PSCustomObject]@{}
    if(Test-Path "Stats"){Get-ChildItemContent "Stats" | ForEach {$Stats | Add-Member $_.Name $_.Content}}

    #Load information about the Pools
    $AllPools = if(Test-Path "Pools"){Get-ChildItemContent "Pools" | ForEach {$_.Content | Add-Member @{Name = $_.Name} -PassThru}}
    $Pools = [PSCustomObject]@{}
    $AllPools.Algorithm | Get-Unique | ForEach {$Pools | Add-Member $_ ($AllPools | Where Algorithm -EQ $_ | Sort Price -Descending | Select -First 1)}
    
    #Load information about the Miners
    #Messy...?
    $Miners = if(Test-Path "Miners"){Get-ChildItemContent "Miners" | ForEach {$_.Content | Add-Member @{Name = $_.Name} -PassThru}}
    $Miners | ForEach {
        $Miner = $_

        $Miner_HashRates = [PSCustomObject]@{}
        $Miner_Pools = [PSCustomObject]@{}
        $Miner_Profits = [PSCustomObject]@{}

        $Miner.HashRates.PSObject.Properties.Name | ForEach {
            $Miner_HashRates | Add-Member $_ ([Decimal]$Miner.HashRates.$_)
            $Miner_Pools | Add-Member $_ ([PSCustomObject]$Pools.$_)
            $Miner_Profits | Add-Member $_ ([Decimal]$Miner.HashRates.$_*$Pools.$_.Price)
        }

        $Miner_Profit = [Decimal]($Miner_Profits.PSObject.Properties.Value | Measure -Sum).Sum
        
        $Miner.HashRates.PSObject.Properties | Where Value -EQ "" | Select -ExpandProperty Name | ForEach {
            $Miner_HashRates.$_ = $null
            $Miner_Profits.$_ = $null
            $Miner_Profit = $null
        }
        
        $Miner.HashRates = $Miner_HashRates
        $Miner | Add-Member Pools $Miner_Pools
        $Miner | Add-Member Profits $Miner_Profits
        $Miner | Add-Member Profit $Miner_Profit
        $Miner.Path = Convert-Path $Miner.Path
    }

    #Get all valid combinations of the miners i.e. AMD+NVIDIA+CPU
    #Over complicated...?
    $MinerCombos = [System.Collections.ArrayList]($Miners | ForEach {[Array]$_})
    for($i = ($Miners.Type | Select -Unique).Count-1; $i -ge 1; $i--)
    {
        for($iMinerCombo = $MinerCombos.Count-1; $iMinerCombo -ge 0; $iMinerCombo--)
        {
            $Miners | ForEach {
                $MinerCombo = [Array]$MinerCombos[$iMinerCombo]+$_
                if($MinerCombo.Type.Count -eq ($MinerCombo.Type | Select -Unique).Count)
                {
                    if(($MinerCombos | Where {$_.Count -eq ([Array]$_+$MinerCombo | ForEach {$Miners.IndexOf($_)} | Select -Unique).Count}).Count -eq 0)
                    {
                        $MinerCombos.Add([Array]$MinerCombo) | Out-Null
                    }
                }
            }
        }
    }
    
    #Display mining information
    Clear-Host
    $Miners | Where {$_.Profit -ge 0.000001 -or $_.Profit -eq $null} | Sort -Descending Type,Profit | Format-Table -GroupBy Type (
        @{Label = "Miner"; Expression={$_.Name}}, 
        @{Label = "Algorithm"; Expression={$_.HashRates.PSObject.Properties.Name}}, 
        @{Label = "GH/s"; Expression={$_.HashRates.PSObject.Properties.Value | ForEach {if($_ -ne $null){($_/1000000000).ToString(",0.000000")}else{"Benchmarking"}}}; Align='right'}, 
        @{Label = "BTC/Day"; Expression={$_.Profits.PSObject.Properties.Value | ForEach {if($_ -ne $null){$_.ToString(",0.000000")}else{"Benchmarking"}}}; Align='right'}, 
        @{Label = "BTC/GH/Day"; Expression={$_.Pools.PSObject.Properties.Value.Price | ForEach {($_*1000000000).ToString(",0.000000")}}; Align='right'}, 
        @{Label = "Pool"; Expression={$_.Pools.PSObject.Properties.Value.Name}}
    ) | Out-Host

    #Apply delta to miners to avoid needless switching
    $ActiveMinerPrograms | ForEach {$Miners | Where Path -EQ $_.Path | Where Arguments -EQ $_.Arguments | ForEach {$_.Profit *= 1+$Delta}}

    #Store most profitable miner combo
    $BestMinerCombo = $MinerCombos | Sort -Descending {($_ | Where Profit -EQ $null | Measure).Count},{($_ | Measure Profit -Sum).Sum} | Select -First 1

    #Stop or start existing active miners depending on if they are the most profitable
    $ActiveMinerPrograms | ForEach {
        if(($BestMinerCombo | Where Path -EQ $_.Path | Where Arguments -EQ $_.Arguments).Count -eq 0)
        {
            Stop-Process $_.Process
            $_.Status = "Idle"
        }
        elseif($_.Process.HasExited)
        {
            $_.Active += $_.Process.ExitTime-$_.Process.StartTime
            if($_.Process.Start())
            {
                $_.Status = "Running"
            }
            else
            {
                $_.Status = "Failed"
            }
        }
    }

    #Start the most profitable miners that are not already active
    $BestMinerCombo | ForEach {
        if(($ActiveMinerPrograms | Where Path -EQ $_.Path | Where Arguments -EQ $_.Arguments).Count -eq 0)
        {
            $ActiveMinerPrograms += [PSCustomObject]@{
                Name = $_.Name
                Path = $_.Path
                Arguments = $_.Arguments
                Process = Start-Process $_.Path $_.Arguments -WorkingDirectory (Split-Path $_.Path) -PassThru
                API = $_.API
                Algorithms = $_.HashRates.PSObject.Properties.Name
                Boost = 1+$Delta
                Active = [TimeSpan]0
                Status = "Running"
            }
        }
    }
    
    #Display active miners
    $ActiveMinerPrograms | Sort -Descending Status,Active | Select -First 10 | Format-Table -GroupBy Status (
        @{Label = "Active"; Expression={if($_.Process.ExitTime -gt $_.Process.StartTime){($_.Active+($_.Process.ExitTime-$_.Process.StartTime)).ToString("hh\:mm")}else{($_.Active+((Get-Date)-$_.Process.StartTime)).ToString("hh\:mm")}}}, 
        @{Label = "Path"; Expression={$_.Path.TrimStart((Convert-Path ".\"))}}, 
        @{Label = "Arguments"; Expression={$_.Arguments}}
    ) | Out-Host
    
    #Do nothing for a few seconds as to not overload the APIs
    Sleep $Interval

    #Save current hash rates
    $ActiveMinerPrograms | ForEach {
        $Miner_HashRates = $null
        if(-not $_.Process.HasExited)
        {
            $Miner_HashRates = Get-HashRate $_.API
            for($i = 0; $i -lt [Math]::Min($_.Algorithms.Count, $Miner_HashRates.Count); $i++)
            {
                $Stat = Set-Stat -Name "$($_.Name)_$($_.Algorithms | Select -Index $i)_HashRate" -Value (($Miner_HashRates | Select -Index $i)*$_.Boost)
                $_.Boost = 1
            }
        }
        for($i = [Math]::Min($_.Algorithms.Count, $Miner_HashRates.Count); $i -lt $_.Algorithms.Count; $i++)
        {
            if((Get-Stat "$($_.Name)_$($_.Algorithms | Select -Index $i)_HashRate") -eq $null)
            {
                $Stat = Set-Stat -Name "$($_.Name)_$($_.Algorithms | Select -Index $i)_HashRate" -Value (0*$_.Boost)
                $_.Boost = 1
            }
        }
    }
}

#Stop the log
Stop-Transcript