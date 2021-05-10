﻿#If this is a new plotting machine and you haven't imported your certificates yet, share the "C:\Users\USERNAME\.chia\mainnet\config\ssl\ca" folder on your main node computer, then run these commands on your plotter(s) to sync them to the same keys and wallet target as your main node
###################################################################################
#cd "~\appdata\local\chia-blockchain\app-*\resources\app.asar.unpacked\daemon"    #
#.\chia.exe stop all -d                                                           #
#.\chia init -c \\[MAIN_COMPUTER]\ca                                              #
#.\chia configure --set-farmer-peer [MAIN_NODE_IP]:8447                           #
###################################################################################

<#
.SYNOPSIS
    The objective of this script is to maximize plotting throughput, with minimal human interaction.

.DESCRIPTION
    This script will generate plots according to the settings you specify in the #VARIABLES section. It will monitor disk, cpu and memory resources and automatically create new plots when enough free space and performance headroom are available.

.INPUTS
    null

.OUTPUTS
    void

.NOTES
    Version: 1.4.1
    Author:  /u/epidemic0110
    Email: enhancedchia [@] gmail.com (Send me feedback, please! I'm dyin here!)
    Donation: xch18n2p6ml9sud595kws9m3x38ujh4dgt60sdstk9cpzke9f0qtzrzq079jfg (Hah! Why would anyone would donate their precious Chia XCH?!)
#>


#VARIABLES - Set these to match your environment.
#MANDATORY
$tempDrives = @("F:","T:") #Drives that you want to use for temp files
$plotDir = "\\SERVERNAME\PlotFolder" #Local or shared Destination directory you want plots to be sent to (for example, \\SERVERNAME\Plots or G:\Plots)
$logDir = "C:\temp\EnhancedChiaPlotter"
$newPlots = 20 #Total number of plots to produce
#OPTIONAL - Advanced settings
$tempFolder = "\ChiaTemp" #Name of folder to be used/created on the temp drives for temp files
$temp2Dir = $null #Full path to a directory to be used for staging the finished plot file before it is moved to the final $plotDir destination directory. If set, it uses the -tmp2_dir switch. If $null it does not stage the final files anywhere other than the source temp directory.
$tempPlotSize = 270 #Size that the temp files for one k32 plot take (Currently ~260GiB/240GB as of v1.1.3)
$threadsPerPlot = 2 #How many processor each plotting process should use. Feel free to experiment with higher numbers on high core systems, but general consesus is that there are diminishing returns above 2 threads
$delayBetweenChecks = 600 #Delay (in seconds) between checks for sufficient free resources to start a new plot; DON'T SET THIS TOO LOW OR YOU RISK OVER-FILLING A DISK. 300-900 seconds (5-15 minutes) seem to be good values
$lowDiskThreshold = .60 #A queue length of 1.0 or greater means a disk is saturated and cannot handle any more concurrent requests. Anything less than 1.0 theoretically means the disk isn't fully utilized, however it may not be ideal to target full saturation, especially on mechanical drives. A threshold in the range of .5-.8 is suggested, but tweak and let me know what you find best for overall throughput
$lowCpuThreshold = 76 #How low should the CPU utilization percent be before a new plot is allowed to be started if other resources are free; This will vary depending on core count and if this is a dedicated plotter or not. If it is doing nothing else and you have lots of cores, you might want to set this to a high value, like 85%. If it is running a full node or farmer, you might want to keep it a bit lower to prevent plotting from using all of the CPU
$lowMemThreshold = 1024 #Don't start a new plot if it would make system free memory drop below this amount (MB). For example if your $memoryBuffer value is set to 4096MB per plot, and your current system free memory is less than 4096+$lowMemThreshold, it won't start a new plot
$memoryBuffer = 3390 #Amount of memory to limit each plotting process to. Default is 3390MiB but if you have lots of memory and CPU or disk I/O are your bottleneck, you can try increasing this number
$initialDelay = 0 #Stagger delay (in minutes) before the very first instance starts on each tempDrive after the first. May help distribute plotting load across phases better, but untested- not sure if helpful or harmful to overall throughput
###################################################################################

#Run initial setup and health checks
if (!(Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile) { Write-Host "WARNING: Your system is not set to use an automatically managed page file. This can cause Chia to fail with `"Bad allocation`" errors." -ForegroundColor Red }
if (!(Test-Path $plotDir)) { Write-Host "Plot directory does not exist, attempting to create."; New-Item -ItemType Directory -Force -Path $plotDir }
if (!(Test-Path $logDir)) { Write-Host "Log directory does not exist, attempting to create.";New-Item -ItemType Directory -Force -Path $logDir }
if (($temp2Dir -ne $null) -AND !(Test-Path $temp2Dir)) { Write-Host "Temp2 directory does not exist, attempting to create.";New-Item -ItemType Directory -Force -Path $temp2Dir }
foreach ($tempDrive in $tempDrives) { if (!(Test-Path $tempDrive$tempFolder)) { Write-Host "Temp directory $tempDrive$tempFolder does not exist, attempting to create."; New-Item -ItemType Directory -Force -Path $tempDrive$tempFolder } }

#Main Routine
cd "~\appdata\local\chia-blockchain\app-*\resources\app.asar.unpacked\daemon"

#Start plotting
for ($i = 1; $i -le $newPlots){
    #Cycle through temp drives
    foreach ($tempDrive in $tempDrives) {
        #Sleep for initialDelay if this is our first run through each drive
        if (($i -le $($tempDrives.Count)) -and ($i -gt 1)) {
            Write-Host "Sleeping for initial stagger delay of $initialDelay"
            sleep $($initialDelay*60)
        }

        #Check for sufficient free memory
        Write-Host "Checking for sufficient free memory..."
        $freeMemory = (Get-Counter '\Memory\Available MBytes').CounterSamples.CookedValue
        if ($freeMemory -gt $($lowMemThreshold + $memoryBuffer)) {
            Write-Host "Sufficient free memory of $freeMemory. Continuing..."

            #Check for sufficient free CPU using average of 3 samples over 3 seconds
            Write-Host "Checking for sufficient free CPU..."
            $CPUSample1 = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
            sleep 1
            $CPUSample2 = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
            sleep 1
            $CPUSample3 = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
            $CPUAvg = [math]::Round(($CPUSample1 + $CPUSample2 + $CPUSample3) / 3)
            if ($CPUAvg -lt $lowCpuThreshold) {
                Write-Host "Sufficient free CPU of $CPUAvg below threshold of $lowCPUThreshold. Continuing..."

                #Check for sufficient space
                Write-Host "Checking $tempDrive for sufficient space..."
                $tempSpace = $(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID like '$tempDrive'" | select FreeSpace)
                if ($tempSpace.FreeSpace -gt $($tempPlotSize*1024*1024*1024)){
                    Write-Host "Free space on $tempDrive $($tempSpace.FreeSpace/1024/1024) GB is at least $tempPlotSize GB. Continuing... "
                    #Check for sufficient disk IO
                    $tempQueue = [math]::Round((Get-Counter "\PhysicalDisk(* $tempDrive)\Avg. Disk Queue Length").CounterSamples.CookedValue,3)
                    if ($tempQueue -lt $lowDiskThreshold) {
                        Write-Host "Disk queue length $tempQueue is below $lowDiskThreshold. Continuing..."

                        #Start plot
                        Write-Host "GO: Spinning off plot $i of $newPlots using $tempDrive in new process" -ForegroundColor Green
                        Write-Host "NEW POWERSHELL WINDOWS WILL CLOSE AUTOMATICALLY WHEN FINISHED. Do not close them unless you want to interrupt them." -ForegroundColor Green
                        if ($temp2Dir -ne $null) { start-process powershell -ArgumentList ".\chia.exe plots create --size 32 --num 1 --num_threads $threadsPerPlot --tmp_dir `"$tempDrive$tempFolder`" --final_dir `"$plotDir`" --tmp2_dir $temp2Dir --buffer $memoryBuffer -x | Tee-Object -FilePath `"$logDir\Plot$($i)_$(Get-Date -Format dd-mm-yyyy-hh-mm).txt`"" }
                        else { start-process powershell -ArgumentList ".\chia.exe plots create --size 32 --num 1 --num_threads $threadsPerPlot --tmp_dir `"$tempDrive$tempFolder`" --final_dir `"$plotDir`" --buffer $memoryBuffer -x | Tee-Object -FilePath `"$logDir\Plot$($i)_$(Get-Date -Format dd-mm-yyyy-hh-mm).txt`"" }
                        $i++
                        #Quit if we've reached desired plot count, otherwise wait delay and start over
                        if ($i -lt $newPlots) {
                            Write-Host "Waiting $delayBetweenChecks seconds before next check..."
                            sleep $($delayBetweenChecks)
                        } 
                        else { 
                            Write-Host "Reached desired plot count. Stopping."
                            break 
                        }
                    }
                    else { Write-Host "$tempDrive queue length is higher than $lowDiskThreshold. Waiting $delayBetweenChecks seconds..."; sleep $delayBetweenChecks }
                }
                else { Write-Host "$tempDrive has insufficient space. Only $([math]::Round($tempSpace.FreeSpace/1024/1024))MiB remaining. Waiting $delayBetweenChecks seconds..."; sleep $delayBetweenChecks }
            }
            else { Write-Host "CPU average of $CPUAvg is not below low CPU threshold of $lowCpuThreshold. Waiting $delayBetweenChecks seconds..."; sleep $delayBetweenChecks }
        }
        else { Write-Host "Insufficient free memory for new plot plus $lowMemThreshold MB of headroom. Waiting $delayBetweenChecks seconds..."; sleep $delayBetweenChecks }
    }
}
