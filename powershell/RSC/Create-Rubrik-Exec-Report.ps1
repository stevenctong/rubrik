# https://www.rubrik.com/api
<#
.SYNOPSIS
This script creates a custom html report for Rubrik object compliance and
Rubrik tasks. The html can be emailed if SMTP details are provided.

.DESCRIPTION
This script creates a custom html report for Rubrik object compliance and
Rubrik tasks. The html can be emailed if SMTP details are provided.

Users will need to create four custom reports in RSC and provide access
to those reports via a RSC service account w/read-only permissions.

This script requires the corresponding .psd1 file that contains the variables
for this script: Create-Rubrik-Exec-Report.psd1.

This script requires communication to RSC via outbound HTTPS (TCP 443).

This script requires PowerShell v7+.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 5/1/25
Updated: 8/10/25

For authentication, use a RSC Service Account:
** RSC Settings Room -> Users -> Service Account -> Assign it a read-only reporting role
** Download the service account JSON
** Define the service account JSON path in the script: $serviceAccountPath

For Service Account custom role:
** Create a role with 'View' permission for Reports

Four RSC custom reports will need to be created:
1. Object Compliance Report - Filters: Past 24 hours
2. Protection Task Details Report - Filter: Past 24 hours, backup jobs
3. Object Capacity Report - Filters: None
4. Capacity over Time Report - Filters: Last 12 months

You can apply additional filters on the reports if you want to restrict the data
to a given view.

For each report, grab the report ID. This can be seen as the # in the URL
when you have the report open.

Fill out the report ID in these two variables:
- $reportIDdailyComplianceReport
- $reportIDdailyTaskReport
- $reportIDobjectCapacityReport
- $reportIDobjectCapacityOverTimeReport

If you want the report to be emails, fill out the SMTP information and set
the variable $sendEmail to $true.


.EXAMPLE
./Create-Rubrik-Exec-Report.ps1 -configFile <Create-Rubrik-Exec-Report.psd1>
Runs the script to generate the custom html report.
#>

### Variables section - please fill out as needed

param (
  [CmdletBinding()]
  # Location of the config file - psd1
  [Parameter(Mandatory=$false)]
  [string]$configFile = ''
)

if ($configFile -ne '') {
  $config = Import-PowerShellDataFile -Path $configFile
  foreach ($key in $Config.Keys) {
      Set-Variable -Name $key -Value $Config[$key] -Scope Script
  }
} else {
  Write-Error "Please include a .psd1 $configFile for this script to work"
  Write-Error "Exiting..."
  exit
}

$date = Get-Date
$dateString = $date.ToString("yyyy-MM-dd_HHmm")
$utcDate = $date.ToUniversalTime()

# Append the date and extensions to the various file outputs
$htmlOutput = $htmlOutput + "-$dateString.html"
# Append the date and extension to the saved report CSVs
$csvReportTasks = Join-Path $csvReportDir "$csvReportTasks-$dateString.csv"
$csvReportCompliance = Join-Path $csvReportDir "$csvReportCompliance-$dateString.csv"
$csvReportCapacity = Join-Path $csvReportDir "$csvReportCapacity-$dateString.csv"
$csvReportCapacityOverTime = Join-Path $csvReportDir "$csvReportCapacityOverTime-$dateString.csv"
# Appending email subject with the date
$emailSubject = $emailSubject + " - $($date.ToString("yyyy-MM-dd HH:MM"))"

# Variables used for testing - ignore
$useSaved = $false
# $savedCompliance = './csvReports/rubrik_compliance_report-2025-07-02_0439.csv'
# $savedTasks = './csvReports/rubrik_task_report-2025-07-02_0439.csv'
# $savedCapacity = './csvReports/rubrik_capacity_report-2025-07-02_0551.csv'
# $savedCapacityOverTime = './csvReports/rubrik_capacity_over_time_report-2025-07-02_0726.csv'

$savedCompliance = './csvReports/rubrik_compliance_report-2025-08-03_0800.csv'
$savedTasks = './csvReports/rubrik_task_report-2025-08-03_0800.csv'
$savedCapacity = './csvReports/rubrik_capacity_report-2025-08-03_0800.csv'
$savedCapacityOverTime = './csvReports/rubrik_capacity_over_time_report-2025-08-03_0800.csv'

### End Variables section

if ($PSVersionTable.PSVersion.Major -le 5) {
  Write-Error "Current PS version: $PSVersionTable.PSVersion.Major"
  Write-Error "Script requires PS version 7+"
  Write-Error "This script may have errors running"
}

###### RUBRIK AUTHENTICATION - BEGIN ######
if ($useSaved -eq $false) {
  Write-Host "Attempting to read the Service Account file: $serviceAccountPath"
  try {
    $serviceAccountFile = Get-Content -Path "$serviceAccountPath" -ErrorAction Stop | ConvertFrom-Json
  } catch {
    $errorMessage = $_.Exception | Out-String
    if($errorMessage.Contains('because it does not exist')) {
      throw "The Service Account JSON secret file was not found. Ensure the file is location at $serviceAccountPath."
    }
    throw $_.Exception
  }

  Write-Debug -Message "Determing if the Service Account file contains all required variables."
  $missingServiceAccount = @()
  if ($serviceAccountFile.client_id -eq $null) {
    $missingServiceAccount += "'client_id'"
  }

  if ($serviceAccountFile.client_secret -eq $null) {
    $missingServiceAccount += "'client_secret'"
  }

  if ($serviceAccountFile.access_token_uri -eq $null) {
    $missingServiceAccount += "'access_token_uri'"
  }

  if ($missingServiceAccount.count -gt 0){
    throw "The Service Account JSON secret file is missing the required paramaters: $missingServiceAccount"
  }

  $headers = @{
    'Content-Type' = 'application/json';
    'Accept' = 'application/json';
  }

  $payload = @{
    grant_type = "client_credentials";
    client_id = $serviceAccountFile.client_id;
    client_secret = $serviceAccountFile.client_secret
  }

  $rubrikURL = $serviceAccountFile.access_token_uri.Replace("/api/client_token", "")

  Write-Host "Connecting to RSC to get an auth token: $rubrikURL"
  $response = Invoke-RestMethod -Method POST -Uri $serviceAccountFile.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers

  $global:rubrikConnection = @{
    accessToken = $response.access_token;
    rubrikURL = $rubrikURL
  }

  if ($null -eq $rubrikConnection.accessToken) {
    throw "Error getting access token, exiting..."
  }

  # Rubrik GraphQL API URL
  $endpoint = $rubrikConnection.rubrikURL + "/api/graphql"

  $headers = @{
    'Content-Type'  = 'application/json';
    'Accept' = 'application/json';
    'Authorization' = $('Bearer ' + $rubrikConnection.accessToken);
  }

  Write-Host "Successfully connected to: $rubrikURL" -foregroundcolor green
}
###### RUBRIK AUTHENTICATION - END ######

###### FUNCTIONS - BEGIN ######

# Trigger generating a CSV for a report
Function Generate-ReportCSV {
  param (
    [CmdletBinding()]
    # Report ID
    [Parameter(Mandatory=$true)]
    [int]$reportID
  )
  $variables = @{
    "id" = $reportID
  }
  $query = "mutation (`$id: Int!, `$config: CustomReportCreate) {
    downloadReportCsvAsync(input: {id: `$id, config: `$config}) {
      jobId
      referenceId
      __typename
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $response = Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers
  if ($response.errors) {
    Write-Error $response.errors.message
  }
  return $response.data.downloadReportCsvAsync
} ### Function Generate-ReportCSV

# Get the report name with NG framework via report ID
Function Get-NGReportName {
  param (
    [CmdletBinding()]
    # Report ID
    [Parameter(Mandatory=$true)]
    [int]$reportID
  )
  $variables = @{
    "polarisReportsFilters" = @(
      @{
        "field" = "FILTER_UNSPECIFIED"
        "reportRooms" = @(
          "REPORT_ROOM_NONE"
        )
      }
    )
  }
  $query = "query (`$polarisReportsFilters: [PolarisReportsFilterInput!]) {
    allRscReportConfigs(polarisReportsFilters: `$polarisReportsFilters) {
      id
      name
      reportViewType
    }
  }"
  $payload = @{
    "query" = $query
    "variables" = $variables
  }
  $reportList = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  $reportName = $($reportList.data.allRscReportConfigs | Where-Object -Property 'id' -eq $reportID).name
  return $reportName
} ### Get-NGReportName

# Get the CSV download status
Function Get-DownloadStatus {
  $query = "query DownloadBarQuery {
  getUserDownloads {
    id
    name
    status
    progress
    identifier
    createTime
    completeTime
    __typename
  }
  allUserFiles {
    downloads {
      externalId
      createdAt
      expiresAt
      completedAt
      creator
      filename
      type
      state
      __typename
    }
    __typename
  }
}"
  $payload = @{
    "query" = $query
  }
  $response = $(Invoke-RestMethod -Method POST -Uri $endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers)
  return $response.data.allUserFiles.downloads
} ### Get-DownloadStatus

# Trigger downloading a CSV for a report and return the download link
Function Get-ReportCSVLink {
  param (
    [CmdletBinding()]
    # Report ID to get CSV for
    [Parameter(Mandatory=$true)]
    [int]$reportID
  )
  # Get the report name to check that it exists
  $reportName = Get-NGReportName -reportID $reportID
  if ($reportName -eq $null) {
    Write-Error "No report found for report ID: $reportID, exiting..."
    exit
  }
  Write-Host "Generating CSV for report: $reportName (report ID: $reportID)" -foregroundcolor green
  # Trigger creation of report CSV
  $responseCreateCSV = Generate-ReportCSV -reportID $reportID
  # Get all the recent file download requests
  $downloadStatus = Get-DownloadStatus
  # Filter by file downloads matching the report name we want
  $matchingReports = $downloadStatus | Where-Object { $_.filename -match $reportName }
  # File download job we want should be last one in the array (most recent request)
  $jobToMonitor = $matchingReports[-1]
  # Submitted job will likely be in a PENDING state - grab job ID
  # $jobToMonitor = $downloadStatus | Where-Object { $_.filename -match $reportName -and ($_.state -match 'PENDING' -or $_.status -match 'IN_PROGRESS') }
  Write-Host "Waiting for CSV to be ready, current status: $($jobToMonitor.state)"
  do {
    Start-Sleep -seconds 10
    $downloadStatus = Get-DownloadStatus | Where { $_.externalId -eq $jobToMonitor.externalId }
    Write-Host "Waiting for CSV to be ready, current status: $($jobToMonitor.state)"
  } while ( $downloadStatus.state -notmatch 'READY' )
  # $downloadURL = Get-CSVDownloadLink -downloadID $jobToMonitor.externalId
  $downloadURL = $rubrikURL + '/file-downloads/' + $jobToMonitor.externalId
  return $downloadURL
}  ### Function Get-ReportCSVLink

Function Export-PieChart {
    param(
        [Parameter(Mandatory)]
        [string]$ChartTitle,
        [Parameter(Mandatory)]
        [float[]]$DataValues,
        [Parameter(Mandatory)]
        [string[]]$DataLabels,
        [Parameter(Mandatory)]
        [string]$OutputPath
    )
    # Validate lengths match
    if($DataLabels.Length -ne $DataValues.Length) {
        throw "DataLabels array length must exactly match DataValues array length."
    }
    # Load Chart .NET Library if not yet loaded
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    # Create new chart object
    $Chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $Chart.Width  = 400
    $Chart.Height = 300
    # Always clear collections explicitly to avoid lingering items
    $Chart.ChartAreas.Clear()
    $Chart.Titles.Clear()
    $Chart.Series.Clear()
    # Chart Title
    $Title = New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $Title.Text = $ChartTitle
    $Title.Font = New-Object System.Drawing.Font("Arial",16,[System.Drawing.FontStyle]::Bold)
    $Chart.Titles.Add($Title)
    # Chart Area (required)
    $chartArea = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $ChartArea.Position.X = 0
    $ChartArea.Position.Y = 5     # move chart upwards slightly
    $ChartArea.Position = New-Object System.Windows.Forms.DataVisualization.Charting.ElementPosition(5,10,90,75)
    $Chart.ChartAreas.Add($chartArea)
    # Legend at bottom
    $legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend
    $legend.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Bottom
    $legend.Font = New-Object System.Drawing.Font("Arial", 11)
    $Chart.Legends.Add($Legend)
    # Chart series setup (Pie chart)
    $Series = New-Object System.Windows.Forms.DataVisualization.Charting.Series
    $Series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Pie
    $Series.IsValueShownAsLabel = $true
    $Series.Label = "#PERCENT{P1}"
    $Series["PieLabelStyle"] = "Outside"
    $Series["PieLineColor"] = "Black"
    $Series.Font = New-Object System.Drawing.Font("Arial",11,[System.Drawing.FontStyle]::Bold)
    # Add DataPoints
    for ($i=0; $i -lt $DataValues.Length; $i++) {
        $point = $Series.Points.Add($DataValues[$i])
        $point.LegendText = $DataLabels[$i]
        $point.AxisLabel = ""  # Prevents cluttered chart axis labels
    }
    # Optional colors (can customize these)
    $colors = @(
      [System.Drawing.ColorTranslator]::FromHtml("#2ED51A"),
      [System.Drawing.ColorTranslator]::FromHtml("#FF3355"),   # red if additional colors needed
      [System.Drawing.Color]::SteelBlue,
      [System.Drawing.Color]::Gold,
      [System.Drawing.Color]::Orange
    )
    for($i=0; $i -lt $Series.Points.Count; $i++) {
        $Series.Points[$i].Color = $colors[$i % $colors.Length]
    }
    # Percent labels outside slices
    $Series.IsValueShownAsLabel = $true
    $Series.Label = "#PERCENT{P1}"
    $Series["PieLabelStyle"] = "Outside"
    $Series["PieLineColor"] = "Black"
    # Series added last step
    $Chart.Series.Add($Series)
    $Chart.SaveImage($OutputPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    Write-Host "Pie chart saved at $OutputPath" -ForegroundColor Green
}
#
#
# Export-PieChart -ChartTitle "Compliance Rate" `
#                 -DataValues @(85,15) `
#                 -DataLabels @("In Compliance","Out Of Compliance") `
#                 -OutputPath "$HOME\Desktop\ComplianceRate.jpg"


Function Export-LineChart {
    param (
        [Parameter(Mandatory)]
        [string]$ChartTitle,
        [Parameter(Mandatory)]
        [string]$XAxisTitle,
        [Parameter(Mandatory)]
        [string]$YAxisTitle,
        [Parameter(Mandatory)]
        [string[]]$XValues,
        [Parameter(Mandatory)]
        [float[]]$YValues,
        [Parameter(Mandatory=$false)]
        [array] $chartWidthHeight,
        [Parameter(Mandatory)]
        [string]$OutputPath
    )
    if ($XValues.Count -ne $YValues.Count) {
        throw "XValues and YValues count mismatch!"
    }
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    # Create Chart object clearly fresh each run
    $Chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    if ($chartWidthHeight -eq $null -or $chartWidthHeight -eq '') {
      $chart.Width = 600
      $chart.Height = 300
    } else {
      $chart.Width = $chartWidthHeight[0]
      $chart.Height = $chartWidthHeight[1]
    }
    # Always clear collections explicitly to avoid lingering items
    $Chart.ChartAreas.Clear()
    $Chart.Titles.Clear()
    $Chart.Series.Clear()
    # Title clearly defined once
    $Title = New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $Title.Text = $ChartTitle
    $Title.Font = New-Object System.Drawing.Font("Arial",14,[System.Drawing.FontStyle]::Bold)
    $Chart.Titles.Add($Title)
    # ChartArea with no gridlines explicitly
    $ChartArea = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $ChartArea.AxisX.Title = $XAxisTitle
    $ChartArea.AxisY.Title = $YAxisTitle
    $ChartArea.AxisX.Interval = 1
    $ChartArea.AxisX.LabelStyle.Angle = -45
    $ChartArea.AxisX.MajorGrid.Enabled = $False
    $ChartArea.AxisY.MajorGrid.Enabled = $False
    $Chart.ChartAreas.Add($ChartArea)
    # Line Series configuration clearly permitting gaps
    $Series = New-Object System.Windows.Forms.DataVisualization.Charting.Series
    $Series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $Series.Color = [System.Drawing.Color]::ForestGreen
    $Series.BorderWidth = 3
    # Gaps clearly visible by enabling IsEmptyPointExplicit property
    $Series.EmptyPointStyle.Color = [System.Drawing.Color]::Transparent
    $Series.EmptyPointStyle.BorderWidth = 0
    # Add data points explicitly into series, clearly handling NaN values
    for ($i=0;$i -lt $XValues.Count;$i++){
        $point = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $point.AxisLabel = $XValues[$i]
        if ([double]::IsNaN($YValues[$i])) {
            # Missing/Gapped point explicitly marked as Empty
            $point.IsEmpty = $true
        } else {
            # Real data clearly assigned
            $point.YValues = @($YValues[$i])
        }
        $Series.Points.Add($point)
    }
    $Chart.Series.Add($Series)
    # Output JPG
    $Chart.SaveImage($OutputPath,[System.Drawing.Imaging.ImageFormat]::Jpeg)
    Write-Host "Line Chart saved at: $OutputPath" -ForegroundColor Green
}

# # Call your corrected modular chart function
# Export-LineChart `
#     -ChartTitle "Compliance With Data Gaps" `
#     -XAxisTitle "Date" `
#     -YAxisTitle "Compliance (%)" `
#     -XValues $days `
#     -YValues $values `
#     -OutputPath "$HOME\Desktop\ComplianceGaps.jpg"

Function Export-MultiLineChart {
    param (
        [Parameter(Mandatory)]
        [string]$ChartTitle,
        [Parameter(Mandatory)]
        [string]$XAxisTitle,
        [Parameter(Mandatory)]
        [string]$YAxisTitle,
        [Parameter(Mandatory)]
        [string[]]$XValues,
        # Important change: Array of Arrays for multiple Y series
        [Parameter(Mandatory)]
        [float[][]]$YValueSets,
        # New parameter: Names of each data series
        [Parameter(Mandatory)]
        [string[]]$SeriesNames,
        # Optional defined colors per series (optional)
        [Parameter(Mandatory=$false)]
        [System.Drawing.Color[]]$Colors,
        [Parameter(Mandatory=$false)]
        [array] $chartWidthHeight,
        [Parameter(Mandatory)]
        [string]$OutputPath
    )
    # Input validation
    if ($SeriesNames.Count -ne $YValueSets.Count) {
        throw "SeriesNames count must match number of YValueSets!"
    }
    foreach ($YValues in $YValueSets) {
        if ($XValues.Count -ne $YValues.Count) {
            throw "XValues and each YValues set counts must match!"
        }
    }
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    # Create a fresh Chart object
    $Chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    if (!$chartWidthHeight){
        $Chart.Width  = 600
        $Chart.Height = 300
    }
    else {
        $Chart.Width  = $chartWidthHeight[0]
        $Chart.Height = $chartWidthHeight[1]
    }
    $Chart.ChartAreas.Clear()
    $Chart.Titles.Clear()
    $Chart.Series.Clear()
    $Chart.Legends.Clear()
    # Add Title
    $Title = New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $Title.Text = $ChartTitle
    $Title.Font = New-Object System.Drawing.Font("Arial",14,[System.Drawing.FontStyle]::Bold)
    $Chart.Titles.Add($Title)
    # Add ChartArea
    $ChartArea = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $ChartArea.AxisX.Title = $XAxisTitle
    $ChartArea.AxisY.Title = $YAxisTitle
    $ChartArea.AxisX.Interval = 1
    $ChartArea.AxisX.LabelStyle.Angle = -45
    $ChartArea.AxisX.MajorGrid.Enabled = $False
    $ChartArea.AxisY.MajorGrid.Enabled = $False
    $Chart.ChartAreas.Add($ChartArea)
    # Add a Legend
    $Legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend
    $Chart.Legends.Add($Legend)
    # Default color assignment if not provided
    $defaultColors = @(
        [System.Drawing.Color]::ForestGreen,
        [System.Drawing.Color]::RoyalBlue,
        [System.Drawing.Color]::Orange,
        [System.Drawing.Color]::Red,
        [System.Drawing.Color]::Purple,
        [System.Drawing.Color]::Brown
    )
    # Loop clearly through multiple YValueSets
    for ($s = 0; $s -lt $YValueSets.Count; $s++)
    {
        $Series = New-Object System.Windows.Forms.DataVisualization.Charting.Series
        $Series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
        $Series.Name = $SeriesNames[$s]
        $Series.BorderWidth = 3
        # Assign color (use provided or default)
        if ($Colors -and ($Colors.Count -gt $s)) {
            $Series.Color = $Colors[$s]
        }
        else {
            $Series.Color = $defaultColors[$s % $defaultColors.Count]
        }
        # Handle points in each series
        for ($i = 0; $i -lt $XValues.Count; $i++){
            $point = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
            $point.AxisLabel = $XValues[$i]
            if ([double]::IsNaN($YValueSets[$s][$i])) {
                $point.IsEmpty = $true
            } else {
                $point.YValues = @($YValueSets[$s][$i])
            }
            $Series.Points.Add($point)
        }
        # Add current series to chart
        $Chart.Series.Add($Series)
    }
    # Save JPG
    $Chart.SaveImage($OutputPath,[System.Drawing.Imaging.ImageFormat]::Jpeg)
    Write-Host "Multi-Line Chart saved at: $OutputPath" -ForegroundColor Green
}


Function Export-BarChart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ChartTitle,
        [Parameter(Mandatory)]
        [string] $XAxisTitle,
        [Parameter(Mandatory)]
        [string] $YAxisTitle,
        [Parameter(Mandatory=$false)]
        [string] $YAxisMaximum,
        [Parameter(Mandatory=$false)]
        [array] $chartWidthHeight,
        [Parameter(Mandatory=$false)]
        [string] $IsValueShownAsLabel,
        [Parameter(Mandatory)]
        [string[]] $Categories,
        [Parameter(Mandatory)]
        [float[]] $Values,
        [Parameter(Mandatory)]
        [string] $OutputPath,
        [Parameter(Mandatory=$false)]
        [string] $BarColorHtml = "#00B2A9"  # Default color provided explicitly here clearly using your given color
    )
    if ($Categories.Count -ne $Values.Count) {
        throw "Categories and Values must match!"
    }
    # Load Chart .NET Library if not yet loaded
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    # Initialize explicitly the fresh chart object
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    if ($chartWidthHeight -eq $null -or $chartWidthHeight -eq '') {
      $chart.Width = 500
      $chart.Height = 300
    } else {
      $chart.Width = $chartWidthHeight[0]
      $chart.Height = $chartWidthHeight[1]
    }
    # Always clear collections explicitly to avoid lingering items
    $Chart.ChartAreas.Clear()
    $Chart.Titles.Clear()
    $Chart.Series.Clear()
    # Chart Title
    $Title = New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $Title.Text = $ChartTitle
    $Title.Font = New-Object System.Drawing.Font("Arial",14,[System.Drawing.FontStyle]::Bold)
    $Chart.Titles.Add($Title)
    # Chart Area setup clearly without gridlines
    $chartArea = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $chartArea.AxisX.Title = $XAxisTitle
    $chartArea.AxisY.Title = $YAxisTitle
    $chartArea.AxisX.MajorGrid.Enabled = $False
    $chartArea.AxisY.MajorGrid.Enabled = $False
    $chartArea.AxisX.Interval = 1
    $chartArea.AxisX.LabelStyle.Angle = -30
    if ( -not ($YAxisMaximum -eq $null -or $YAxisMaximum -eq '')) {
      $chartArea.AxisY.Maximum = $YAxisMaximum
    }
    $chart.ChartAreas.Add($chartArea)
    # Single-Series Bar chart configuration clearly defined
    $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series
    $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Column
    if ( -not ($IsValueShownAsLabel -eq $null -or $IsValueShownAsLabel -eq '')) {
      $series.IsValueShownAsLabel = $IsValueShownAsLabel
    } else {
      $series.IsValueShownAsLabel = $false
    }
    $series.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
    # Translate HTML (hex) color explicitly for uniform bar color
    $customBarColor = [System.Drawing.ColorTranslator]::FromHtml($BarColorHtml)
    # Add bars explicitly, color explicitly set
    for ($i=0;$i -lt $Categories.Count;$i++){
        $dp = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $dp.AxisLabel = $Categories[$i]
        $dp.YValues = $Values[$i]
        $dp.Color = $customBarColor
        $series.Points.Add($dp)
    }
    $chart.Series.Add($series)
    # Save chart clearly to your output path
    $chart.SaveImage($OutputPath,[System.Drawing.Imaging.ImageFormat]::Jpeg)
    Write-Host "Bar chart saved at: $OutputPath" -ForegroundColor Green
}

# # Categories (your workloads)
# $categories = @('VMware','SQL','Oracle','Hyper-V','Linux')
#
# # Random example capacities clearly shown (replace with your actual data)
# $capacityValues = @(120,95,75,60,85)
#
# # Call your updated function explicitly using default color #00B2A9
# Export-BarChart -ChartTitle 'Workload Capacities' `
#                 -XAxisTitle 'Workload Type' `
#                 -YAxisTitle 'Capacity (TB)' `
#                 -Categories $categories `
#                 -Values $capacityValues `
#                 -OutputPath "$HOME\Desktop\WorkloadCapacityUniformColor.jpg"


Function Export-GroupedBarChart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ChartTitle,
        [Parameter(Mandatory)]
        [string] $XAxisTitle,
        [Parameter(Mandatory)]
        [string] $YAxisTitle,
        [Parameter(Mandatory=$false)]
        [float] $YAxisMaximum,
        [Parameter(Mandatory=$false)]
        [array] $chartWidthHeight,
        [Parameter(Mandatory=$false)]
        [bool] $IsValueShownAsLabel = $false,
        [Parameter(Mandatory)]
        [string[]] $Categories,
        [Parameter(Mandatory)]
        [float[][]] $Values, # multiple sets for grouped bars
        [Parameter(Mandatory)]
        [string[]] $SeriesNames,
        [Parameter(Mandatory)]
        [string] $OutputPath,
        [Parameter(Mandatory=$false)]
        [string[]] $BarColorsHtml  # colors for each series, optional
    )
    # Validate Inputs Clearly
    if ($Values.Count -ne $SeriesNames.Count){
        throw "Count of Values sets must match count of SeriesNames!"
    }
    foreach ($valSet in $Values){
        if ($valSet.Count -ne $Categories.Count){
            throw "Each Values set must match Categories count!"
        }
    }
    if ($BarColorsHtml -and ($BarColorsHtml.Count -ne $SeriesNames.Count)){
        throw "When using BarColorsHtml, its count must match SeriesNames count!"
    }
    # Load Charting Assembly explicitly
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    # Initialize Chart Object explicitly
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    if (!$chartWidthHeight) {
        $chart.Width = 1000
        $chart.Height = 300
    } else {
        $chart.Width = $chartWidthHeight[0]
        $chart.Height = $chartWidthHeight[1]
    }
    # Clearing Chart collections explicitly clearly
    $Chart.ChartAreas.Clear()
    $Chart.Titles.Clear()
    $Chart.Series.Clear()
    $Chart.Legends.Clear()
    # Clearly add Title
    $Title = New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $Title.Text = $ChartTitle
    $Title.Font = New-Object System.Drawing.Font("Arial",14,[System.Drawing.FontStyle]::Bold)
    $Chart.Titles.Add($Title)
    # Define ChartArea without gridlines clearly
    $chartArea = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $chartArea.AxisX.Title = $XAxisTitle
    $chartArea.AxisY.Title = $YAxisTitle
    $chartArea.AxisX.MajorGrid.Enabled = $False
    $chartArea.AxisY.MajorGrid.Enabled = $False
    $chartArea.AxisX.Interval = 1
    $chartArea.AxisX.LabelStyle.Angle = -30
    if ($YAxisMaximum) {
        $chartArea.AxisY.Maximum = $YAxisMaximum
    }
    $chart.ChartAreas.Add($chartArea)
    # Add Legend explicitly to identify grouped sets
    $Legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend
    $Chart.Legends.Add($Legend)
    # Default colors explicitly
    $defaultColors = @("#00B2A9","#F57C00","#3E92CC","#D72631","#AE81FF","#008744","#0094FF")
    # Generate bars for each series explicitly clear looping
    for ($s = 0; $s -lt $SeriesNames.Count; $s++){
        $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series($SeriesNames[$s])
        $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Column
        $series.IsValueShownAsLabel = $IsValueShownAsLabel
        $series.Font = New-Object System.Drawing.Font("Arial",9,[System.Drawing.FontStyle]::Regular)
        # Assign explicit color or default to the Series directly:
        if ($BarColorsHtml -and $BarColorsHtml[$s]){
            $barColor = [System.Drawing.ColorTranslator]::FromHtml($BarColorsHtml[$s])
        } else {
            $barColor = [System.Drawing.ColorTranslator]::FromHtml($defaultColors[$s % $defaultColors.Count])
        }
        $series.Color = $barColor  # <-- SET COLOR ON SERIES, NOT INDIVIDUAL DATA POINTS
        # Add data points explicitly clearly
        for ($i = 0; $i -lt $Categories.Count; $i++){
            $dp = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
            $dp.AxisLabel = $Categories[$i]
            $dp.YValues = @($Values[$s][$i])
            $series.Points.Add($dp)
        }
        $chart.Series.Add($series)
    }
    # Export explicitly to JPG
    $chart.SaveImage($OutputPath,[System.Drawing.Imaging.ImageFormat]::Jpeg)
    Write-Host "Grouped Bar chart saved at: $OutputPath" -ForegroundColor Green
}


###### FUNCTIONS - END ######

if ($useSaved -eq $false) {
  # Download the Daily Protection Task Detail Report
  $dailyTaskCSVLink = Get-ReportCSVLink -reportID $reportIDdailyTaskReport
  $rubrikTasks = $(Invoke-WebRequest -Uri $dailyTaskCSVLink -Headers $headers -SkipCertificateCheck).content | ConvertFrom-CSV
  if ($saveCSV) {
    $rubrikTasks | Export-CSV -path $csvReportTasks -NoTypeInformation
  }
  Write-Host "Downloaded the Daily Protection Task Report CSV: $($rubrikTasks.count) tasks" -foregroundcolor green
  # Download the Daily Compliance Report
  $complianceCSVLink = Get-ReportCSVLink -reportID $reportIDdailyComplianceReport
  $rubrikCompliance = $(Invoke-WebRequest -Uri $complianceCSVLink -Headers $headers -SkipCertificateCheck).content | ConvertFrom-CSV
  if ($saveCSV) {
    $rubrikCompliance | Export-CSV -path $csvReportCompliance -NoTypeInformation
  }
  Write-Host "Downloaded the Daily Compliance Report CSV: $($rubrikCompliance.count) objects" -foregroundcolor green
  # Download the current Object Capacity Report
  $capacityCSVLink = Get-ReportCSVLink -reportID $reportIDobjectCapacityReport
  $rubrikCapacity = $(Invoke-WebRequest -Uri $capacityCSVLink -Headers $headers -SkipCertificateCheck).content | ConvertFrom-CSV
  if ($saveCSV) {
    $rubrikCapacity | Export-CSV -path $csvReportCapacity -NoTypeInformation
  }
  Write-Host "Downloaded the Object Capacity Report CSV: $($rubrikCapacity.count) objects" -foregroundcolor green
  # Download the Capacity over Time Report
  $capacityOverTimeCSVLink = Get-ReportCSVLink -reportID $reportIDobjectCapacityOverTimeReport
  $rubrikCapacityOverTime = $(Invoke-WebRequest -Uri $capacityOverTimeCSVLink -Headers $headers -SkipCertificateCheck).content | ConvertFrom-CSV
  if ($saveCSV) {
    $rubrikCapacityOverTime | Export-CSV -path $csvReportCapacityOverTime -NoTypeInformation
  }
  Write-Host "Downloaded the Capacity Over Time Report CSV: $($rubrikCapacityOverTime.count) objects" -foregroundcolor green
} else {
  $rubrikTasks = Import-CSV -Path $savedTasks
  $rubrikCompliance = Import-CSV -Path $savedCompliance
  $rubrikCapacity = Import-CSV -Path $savedCapacity
  $rubrikCapacityOverTime = Import-CSV -Path $savedCapacityOverTime
}

# Get unique workloads from Tasks report
$workloadTaskList = $rubrikTasks | Select-Object 'Object Type' -unique -expandProperty 'Object Type'

# Create a hash table to keep the task status and compliance counts for each workload
$workloadTaskHash = @{}
foreach ($workload in $workloadTaskList)
{
  $workloadObj = [PSCustomObject] @{
    "SucceededCount" = 0
    "SucceededWithWarningsCount" = 0
    "CanceledCount" = 0
    "FailedCount" = 0
    "TotalCount" = 0
    "SucceededRate" = [float]0
    "InCompliance" = 0
    "OutCompliance" = 0
    "TotalCompliance" = 0
    "ComplianceRate" = [float]0
  }
  $workloadTaskHash.add($($workload),$workloadObj)
}



# Get unique Clusters
$clusterList = $rubrikTasks | Select-Object 'Cluster Name' -unique -expandProperty 'Cluster Name'

# Create a hash table to keep the task status and compliance counts for each cluster
$clusterCountHash = @{}
foreach ($cluster in $clusterList)
{
  $clusterObj = [PSCustomObject] @{
    "SucceededCount" = 0
    "SucceededWithWarningsCount" = 0
    "CanceledCount" = 0
    "FailedCount" = 0
    "TotalCount" = 0
    "SucceededRate" = [float]0
    "InCompliance" = 0
    "OutCompliance" = 0
    "TotalCompliance" = 0
    "ComplianceRate" = [float]0
  }
  $clusterCountHash.add($($cluster),$clusterObj)
}

# PSCustomObject to keep track of all counts for all clusters
$clusterTotal = [PSCustomObject] @{
  "SucceededCount" = 0
  "SucceededWithWarningsCount" = 0
  "CanceledCount" = 0
  "FailedCount" = 0
  "TotalCount" = 0
  "SucceededWithWarningsRate" = [float]0
  "SucceededRate" = [float]0
  "InCompliance" = 0
  "OutCompliance" = 0
  "TotalCompliance" = 0
  "ComplianceRate" = [float]0
}

$rubrikTasksCount = $rubrikTasks.count
Write-Host "Processing $rubrikTasksCount tasks" -foregroundcolor green
$count = 1

# Process each task and calculate some values
foreach ($i in $rubrikTasks)
{
  if (($count % 500) -eq 0) {
    Write-Host "Processing tasks: $count of $rubrikTasksCount"
  }
  $count += 1
  # Track the task status counts for each workload
  $workloadTaskHash[$i.'Object Type'].'TotalCount' += 1
  # Track the task status counts for each cluster
  $clusterCountHash[$i.'Cluster Name'].'TotalCount' += 1
  if ($i.'Task Status' -contains 'Succeeded') {
    $clusterCountHash[$i.'Cluster Name'].'SucceededCount' += 1
    $workloadTaskHash[$i.'Object Type'].'SucceededCount' += 1
  } elseif ($i.'Task Status' -match 'Succeeded with Warnings') {
    $clusterCountHash[$i.'Cluster Name'].'SucceededWithWarningsCount' += 1
    $workloadTaskHash[$i.'Object Type'].'SucceededWithWarningsCount' += 1
  } elseif ($i.'Task Status' -match 'Failed') {
    $clusterCountHash[$i.'Cluster Name'].'FailedCount' += 1
    $workloadTaskHash[$i.'Object Type'].'FailedCount' += 1
  } elseif ($i.'Task Status' -match 'Canceled') {
    $clusterCountHash[$i.'Cluster Name'].'CanceledCount' += 1
    $workloadTaskHash[$i.'Object Type'].'CanceledCount' += 1
  }
  # Update the timestamps to Powershell 'datetime' format so we can do comparisons
  $i.'Start Time' = ([datetime]($i.'Start Time'.replace("UTC", "GMT"))).ToUniversalTime()
  $i.'End Time' = ([datetime]($i.'End Time'.replace("UTC", "GMT"))).ToUniversalTime()
  # Duration is in milliseconds. Calculate out the hours, min, and seconds.
  # Create a field that returns the duration as a string with hours, min, and seconds.
  $i.duration = [int]$i.duration
  $durationSeconds = $i.Duration
  $durationHours =  [math]::Floor($durationSeconds / 3600)
  $durationMinutes =  [math]::Floor(($durationSeconds / 60) - ($durationHours * 60))
  $durationSeconds = [math]::Floor($durationSeconds - ($durationHours * 3600) - ($durationMinutes * 60))
  $durationText = [string]$durationHours + " Hours " + [string]$durationMinutes + " Minutes " + [string]$durationSeconds + " Seconds"
  Add-Member -InputObject $i -MemberType NoteProperty -name 'Duration Text' -value $durationText -Force
  # Data transferred is in bytes. Calculate out the GB and store as a field.
  if ($i.'Data transferred' -ne '' -and $i.'Data transferred' -notmatch 'N/A') {
    $DataTransGB = [math]::Round([float]$i.'Data transferred' / 1000000000, 1)
    Add-Member -InputObject $i -MemberType NoteProperty -name 'Data Trans GB' -value $DataTransGB -Force
  } else {
    Add-Member -InputObject $i -MemberType NoteProperty -name 'Data Trans GB' -value 'N/A' -Force
  }
  # Data stored is in bytes. Calculate out the GB and store as a field.
  if ($i.'Data stored' -ne '' -and $i.'Data stored' -notmatch 'N/A') {
    $DataStoredGB = [math]::Round([float]$i.'Data Stored' / 1000000000, 1)
    Add-Member -InputObject $i -MemberType NoteProperty -name 'Data Stored GB' -value $DataStoredGB -Force
  } else {
    Add-Member -InputObject $i -MemberType NoteProperty -name 'Data Stored GB' -value 'N/A' -Force
  }
}

# Calculate succeeded rate for workloads
foreach ($workloadStatus in $workloadTaskHash.GetEnumerator())
{
  $value = $($workloadStatus.Value)
  $value.SucceededRate = [math]::round(($value.SucceededCount + $value.SucceededWithWarningsCount) /
    ($value.SucceededCount + $value.SucceededWithWarningsCount + $value.FailedCount) * 100, 1)
}


# Calculate succeeded rate for clusters
foreach ($clusterStatus in $clusterCountHash.GetEnumerator())
{
  $value = $($clusterStatus.Value)
  $value.SucceededRate = [math]::round(($value.SucceededCount + $value.SucceededWithWarningsCount) /
    ($value.SucceededCount + $value.SucceededWithWarningsCount + $value.FailedCount) * 100, 1)
}

# Create a table of tasks, with Failed tasks followed by Canceled, followed by Succeeded taks
# Within each grouping, sorted by "Duration" in descending order
Write-Host "Sorting tasks" -foreground green

# Need to initialize array in case there are no failed tasks to start with
$rubrikTasksSorted = @()

$rubrikTasksSorted += $rubrikTasks | Where { $_.'Task status' -match 'Fail' } |
  Sort-Object -property $sortOrder -Descending

$rubrikTasksSorted += $rubrikTasks | Where { $_.'Task status' -match 'Cancel' } |
  Sort-Object -property $sortOrder -Descending

$rubrikTasksSorted += $rubrikTasks | Where { $_.'Task status' -match 'Succeeded with Warnings' } |
  Sort-Object -property $sortOrder -Descending

$rubrikTasksSorted += $rubrikTasks | Where { $_.'Task status' -contains 'Succeeded' } |
  Sort-Object -property $sortOrder -Descending

# Calculate cluster totals for tasks
$clusterTotal.SucceededCount = @($rubrikTasks | Where { $_.'Task status' -contains 'Succeeded' }).count
$clusterTotal.SucceededWithWarningsCount = @($rubrikTasks | Where { $_.'Task status' -match 'Succeeded with Warnings' }).count
$clusterTotal.CanceledCount = @($rubrikTasks | Where { $_.'Task status' -match 'Cancel' }).count
$clusterTotal.FailedCount = @($rubrikTasks | Where { $_.'Task status' -match 'Fail' }).count
$clusterTotal.TotalCount = $clusterTotal.SucceededCount + $clusterTotal.SucceededWithWarningsCount + $clusterTotal.CanceledCount + $clusterTotal.FailedCount
$clusterTotal.SucceededRate = [math]::round(($clusterTotal.SucceededCount + $clusterTotal.SucceededWithWarningsCount) / ($clusterTotal.SucceededCount + $clusterTotal.SucceededWithWarningsCount + $clusterTotal.FailedCount) * 100, 1)

# Filter for objects that are In Compliance and separately, Out of Compliance
$objectsInCompliance = @($rubrikCompliance | Where { $_.'Compliance Status' -match 'In Compliance' -and
  $_.'Cluster Type' -ne 'Rubrik'})
$objectsOutCompliance = @($rubrikCompliance | Where { $_.'Compliance Status' -match 'Out of Compliance' -and
  $_.'Cluster Type' -ne 'Rubrik'})

# Calculate cluster totals for compliance
$clusterTotal.InCompliance = $objectsInCompliance.count
$clusterTotal.OutCompliance = $objectsOutCompliance.count
$clusterTotal.TotalCompliance = $clusterTotal.InCompliance + $clusterTotal.OutCompliance
$clusterTotal.ComplianceRate = [math]::round($clusterTotal.InCompliance / $clusterTotal.TotalCompliance * 100, 1)

# Initialze arrays for creating bar chart for compliance by cluster
$barCompCategories = @()
$barCompValues = @()

# For each cluster, get the compliance summary details
foreach ($clusterStatus in $clusterCountHash.GetEnumerator())
{
  $value = $($clusterStatus.Value)
  $value.InCompliance = @($objectsInCompliance | Where { $_.cluster -match $clusterStatus.Name }).count
  $value.OutCompliance = @($objectsOutCompliance | Where { $_.cluster -match $clusterStatus.Name }).count
  $value.TotalCompliance = $value.InCompliance + $value.OutCompliance
  if ($value.TotalCompliance -gt 0) {
    $value.ComplianceRate = [math]::round($value.InCompliance / $value.TotalCompliance * 100, 1)
  } else {
    $value.ComplianceRate = "-"
  }
  # Build Bar Chart for Compliance by Cluster
  if ($value.TotalCompliance -gt 0) {
    $barCompCategories += $clusterStatus.Name
    $barCompValues += [int]$value.ComplianceRate
  }
}

Export-BarChart -ChartTitle 'Backup Compliance - By Cluster' `
                -XAxisTitle 'Cluster' `
                -YAxisTitle 'Compliance (%)' `
                -YAxisMaximum 100 `
                -chartWidthHeight @(400, 300) `
                -IsValueShownAsLabel $true `
                -Categories $barCompCategories `
                -Values $barCompValues `
                -OutputPath "$chartsDir\BackupComplianceByCluster.jpg"

# Get unique Workloads
$workloadList = $rubrikCompliance | Select-Object 'Object Type' -unique -expandProperty 'Object Type'

# Initialze arrays for creating bar chart for compliance by workload
$barCompWorkloadCategories = @()
$barCompWorkloadValues = @()

# Workload hash table to keep capacity counts
$workloadCapacityHash = @{}

# Workload hash table to keep compliance counts
$workloadComplianceArray = @()

# Create a hash table to keep the task status and compliance counts for each workload
foreach ($workload in $workloadList)
{
  $workloadInCompliance = @($objectsInCompliance | Where { $_.'Object Type' -match $workload }).count
  $workloadOutCompliance = @($objectsOutCompliance | Where { $_.'Object Type' -match $workload }).count
  $workloadTotalCompliance = $workloadInCompliance + $workloadOutCompliance
  if ($workloadTotalCompliance -gt 0) {
    $workloadComplianceRate = [math]::round($workloadInCompliance / $workloadTotalCompliance * 100, 1)
    $barCompWorkloadCategories += $workload
    $barCompWorkloadValues += [int]$workloadComplianceRate
    $workloadComplianceItem = [PSCustomObject] @{
      "Workload" = $workload
      "In Compliance" = $workloadInCompliance
      "Out Compliance" = $workloadOutCompliance
      "Total Compliance" = $workloadTotalCompliance
      "Compliance Rate" = $workloadComplianceRate
    }
    $workloadComplianceArray += $workloadComplianceItem
  }
}

Export-BarChart -ChartTitle 'Backup Compliance - By Workload' `
                -XAxisTitle 'Workload Type' `
                -YAxisTitle 'Compliance (%)' `
                -YAxisMaximum 100 `
                -chartWidthHeight @(600, 300) `
                -Categories $barCompWorkloadCategories `
                -Values $barCompWorkloadValues `
                -OutputPath "$chartsDir\BackupComplianceByWorkload.jpg"

# Creating a historical record of the compliance data
$complianceDataDetail = [PSCustomObject] @{
  "Date" = (Get-Date).ToString("MM/dd/yyyy")
  "InCompliance" = $clusterTotal.InCompliance
  "OutCompliance" = $clusterTotal.OutCompliance
  "TotalCompliance" = $clusterTotal.TotalCompliance
  "ComplianceRate" = $clusterTotal.ComplianceRate
}
# Checking if the compliance data CSV exists already, if not create
if (-not (Test-Path -Path $csvComplianceData)) {
  Write-Host "Creating $csvComplianceData to store historical data."
  New-Item -Path $csvComplianceData -ItemType File -Force
}
# Import existing data to only add today's entry once
Write-Host "Importing $csvComplianceData"
$complianceData = @(Import-Csv $csvComplianceData)
# Get a list of all current headers
$complianceHeaders = $complianceData | Select-Object -First 1 | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
if ($complianceData.date -contains (Get-Date).ToString("MM/dd/yyyy")) {
  Write-Host "For compliance data, today's data already exists as an entry, skipping..."
} else {
  $compCount = 0
  foreach ($workloadComp in $barCompWorkloadCategories) {
    Add-Member -InputObject $complianceDataDetail -MemberType NoteProperty `
      -name $workloadComp -value $($barCompWorkloadValues[$compCount]) -Force
    # If there is a new workload, add it to the array
    if ($complianceHeaders -notcontains $workloadComp ) {
      $complianceHeaders += $workloadComp
    }
    $compCount += 1
  }
  $complianceData += $complianceDataDetail
  foreach ($obj in $complianceData) {
    foreach ($property in $complianceHeaders) {
      if (-not ($obj | Get-Member -Name $property -MemberType NoteProperty)) {
          # Add the property if it doesn't exist
          $obj | Add-Member -MemberType NoteProperty -Name $property -Value $null -Force
      }
    }
  }
  $complianceData | Export-CSV -Path $csvComplianceData -NoTypeInformation
}

# Create a pie chart of the compliance rate
Export-PieChart -ChartTitle "Daily Backup Compliance (%)" `
                -DataValues @($clusterTotal.ComplianceRate,$(100 - $clusterTotal.ComplianceRate)) `
                -DataLabels @("In Compliance","Out Of Compliance") `
                -OutputPath "$chartsDir\DailyBackupCompliance.jpg"

# Create line chart of last 30 days
$values = @()
$days = (29..0 | ForEach-Object { $date.AddDays(-$_).ToString('MM/dd/yyyy') })
foreach ($day in $days) {
  if ($complianceData.Date -contains $day) {
    $dataToGet = $complianceData | Where { $_.date -eq $day }
    $values += $dataToGet.ComplianceRate
    $compByWorkloadArray = @()
    $count = 0
    # Loop through to build compliance by workload data
    foreach ($h in $complianceHeaders) {
      if (-not $compByWorkloadArray[$count]) {
          # Write-Host "Initializing $count as a nested array"
          if ($($dataToGet.$h -ne $null)) {
            $compArray = @([double]::$dataToGet.$h)
          } else {
            $compArray = @([double]::NaN)
          }
          $compByWorkloadArray += $compArray
      }
      if ($($dataToGet.$h -ne $null)) {
        $compByWorkloadArray[$count] += [double]::$dataToGet.$h
      } else {
        $compByWorkloadArray[$count] += [double]::NaN
      }
      $count += 1
    }
  } else {
    $values += [double]::NaN
  }
}

Export-LineChart `
    -ChartTitle "Backup Compliance (%) - Last 30 Days" `
    -XAxisTitle "Date" `
    -YAxisTitle "Backup Compliance (%)" `
    -XValues $days `
    -YValues $values `
    -OutputPath "$chartsDir\BackupComplianceLast30Days.jpg"


Export-MultiLineChart -ChartTitle "Backup Compliance (%) - Last 30 Days by Workload" `
                     -XAxisTitle "Date" `
                     -YAxisTitle "Capacity (TB)" `
                     -XValues $days `
                     -YValueSets $complianceLines `
                     -SeriesNames $complianceCategories `
                     -OutputPath "$chartsDir\CapacityLast30DaysByWorkload.jpg"



# If we want to build list with objects also out of replication and archival compliance
if ($allCompliance = $true) {
  $objectsOutCompliance = @($rubrikCompliance | Where { $_.'Compliance Status' -match 'Out of Compliance' -or
    $_.'Replication Compliance Status' -match 'Out of Compliance' -or
    $_.'Archival Compliance Status' -match 'Out of Compliance'})
}

# Date format the report is in
$dateFormat = 'MM/dd/yyyy hh:mm:sstt'
# Process each object out of compliance
foreach ($j in $objectsOutCompliance)
{
  try {
    $j.'Last Successful Backup' = [DateTime]::ParseExact($j.'Last Successful Backup', $dateFormat, $null)
    $j.'Latest Replication Snapshot' = [DateTime]::ParseExact($j.'Latest Replication Snapshot', $dateFormat, $null)
    $j.'Latest Archival Snapshot' = [DateTime]::ParseExact($j.'Latest Archival Snapshot', $dateFormat, $null)
  } catch {
    # Most likely there is no value here so ignoring the error
  }
  if ($j.'Last Successful Backup' -ne 'N/A') {
      $localDaysBehind = [math]::round($($utcDate - [DateTime]$j.'Last Successful Backup').totalDays, 2)
      Add-Member -InputObject $j -MemberType NoteProperty -name 'Local Days Behind' -value $localDaysBehind -Force
  } else {
    Add-Member -InputObject $j -MemberType NoteProperty -name 'Local Days Behind' -value 'All' -Force
  }
}

$objectsOutCompliance = $objectsOutCompliance | Sort-Object -Property 'Local Days Behind' -Descending

# Get the workload list from Capacity report
$capacityWorkloadList = $rubrikCapacity | Select-Object 'Object Type' -unique -expandProperty 'Object Type'

foreach ($workload in $capacityWorkloadList) {
  $workloadObj = [PSCustomObject] @{
    "ProvisionedSize" = [double]0
    "UsedSize" = [double]0
    "LocalStored" = [double]0
    "ArchiveStored" = [double]0
    "ReplicaStored" = [double]0
  }
  $workloadCapacityHash.add($($workload),$workloadObj)
}

# Working on capacity metrics
$totalProvisionedSize = 0
$totalUsedSize = 0
$totalLocalStored = 0
$totalArchiveStored = 0
$totalReplicaStored = 0

$rubrikCapacity = $rubrikCapacity | Where { $_.'SLA Domain' -ne 'Do Not Protect' -and
  $_.'SLA Domain' -ne 'Unprotected' -and $_.'SLA Domain' -ne ''}
$rubrikCapacityCount = $rubrikCapacity.count

Write-Host "Found $rubrikCapacityCount Protected Objects, calcuating capacities..."

foreach ($obj in $rubrikCapacity) {
  $workloadType = $obj.'Object Type'
  if ($obj.'Provisioned Size' -ne 'N/A') {
    $totalProvisionedSize += [double]$obj.'Provisioned Size'
    $workloadCapacityHash[$workloadType].ProvisionedSize += [double]$obj.'Provisioned Size'
  }
  if ($obj.'Used Size' -ne 'N/A') {
    $totalUsedSize += [double]$obj.'Used Size'
    $workloadCapacityHash[$workloadType].UsedSize += [double]$obj.'Used Size'
  }
  if ($obj.'Local Storage' -ne 'N/A') {
    $totalLocalStored += [double]$obj.'Local Storage'
    $workloadCapacityHash[$workloadType].LocalStored += [double]$obj.'Local Storage'
  }
  if ($obj.'Archival Storage' -ne 'N/A') {
    $totalArchiveStored += [double]$obj.'Archival Storage'
    $workloadCapacityHash[$workloadType].ArchiveStored += [double]$obj.'Archival Storage'
  }
  if ($obj.'Replica Storage' -ne 'N/A') {
    $totalReplicaStored += [double]$obj.'Replica Storage'
    $workloadCapacityHash[$workloadType].ReplicaStored += [double]$obj.'Replica Storage'
  }
}

$capacityCategories = @('FETB Provisioned (TB)', 'FETB Used (TB)', 'Local Stored (TB)',
    'Archival (TB)', 'Replica (TB)')
$capacityValues = @([int]($totalProvisionedSize / 1000000000000),
  [int]($totalUsedSize / 1000000000000),
  [int]($totalLocalStored / 1000000000000),
  [int]($totalArchiveStored / 1000000000000),
  [int]($totalReplicaStored / 1000000000000))

# Create bar chart by total capacities
Export-BarChart -ChartTitle 'Capacity Under Protection' `
                -XAxisTitle 'Capacity' `
                -YAxisTitle 'Size (TB)' `
                -chartWidthHeight @(400, 300) `
                -IsValueShownAsLabel $true `
                -Categories $capacityCategories `
                -Values $capacityValues `
                -OutputPath "$chartsDir\TotalCapacities.jpg"


$groupedCapacityWorkloads = @()
$groupedProvisionedSize = @()
$groupedLocalStored = @()
$groupedArchival = @()
$groupedReplica = @()

foreach ($workloadCap in $workloadCapacityHash.GetEnumerator()) {
  if ( $workloadCap.value.localStored -gt 0 -or
        $workloadCap.value.archiveStored -gt 0 -or
        $workloadCap.value.replicaStored -gt 0) {
    $groupedCapacityWorkloads += $workloadCap.name
    $groupedProvisionedSize += [math]::Round($workloadCap.value.provisionedSize / 1000000000000, 2)
    $groupedLocalStored += [math]::Round($workloadCap.value.LocalStored / 1000000000000, 2)
    $groupedArchival += [math]::Round($workloadCap.value.ArchiveStored / 1000000000000, 2)
    $groupedReplica +=  [math]::Round($workloadCap.value.ReplicaStored / 1000000000000, 2)
  }
}

$groupedValues = @($groupedProvisionedSize, $groupedLocalStored,
  $groupedArchival, $groupedReplica)

$groupedLabels = @('FETB Provisioned', 'Local Stored', 'Archival', 'Replica')

# Create multi-bar grouped chart
Export-GroupedBarChart `
    -ChartTitle "Capacity by Workload" `
    -XAxisTitle "Workload" `
    -YAxisTitle "Size (TB)" `
    -Categories $groupedCapacityWorkloads `
    -Values $groupedValues `
    -SeriesNames $groupedLabels `
    -chartWidthHeight @(1000,300) `
    -IsValueShownAsLabel $false `
    -OutputPath "$chartsDir\CapacityByWorkload.jpg"

# Capacity over Time - Get unique monthly dates
$capacityDates = $rubrikCapacityOverTime | Select-Object 'Time' -unique -expandProperty 'Time'

# Create a hash table for the capacity months to store the sum of the capacities
$capacityOverTimeHash = @{}
foreach ($month in $capacityDates)
{
  $capacityObj = [PSCustomObject] @{
    "provisionedSize" = 0
    "usedSize" = 0
    "localStored" = 0
    "archiveStored" = 0
    "replicaStored" = 0
  }
  $capacityOverTimeHash.add($($month),$capacityObj)
}

foreach ($obj in $rubrikCapacityOverTime) {
  if ($obj.'Provisioned Size' -ne 'N/A') {
    $capacityOverTimeHash[$obj.Time].'provisionedSize' += [double]$obj.'Provisioned Size'
  }
  if ($obj.'Used Size' -ne 'N/A') {
    $capacityOverTimeHash[$obj.Time].'usedSize' += [double]$obj.'Used Size'
  }
  if ($obj.'Local Storage' -ne 'N/A') {
    $capacityOverTimeHash[$obj.Time].'localStored' += [double]$obj.'Local Storage'
  }
  if ($obj.'Archival Storage' -ne 'N/A') {
    $capacityOverTimeHash[$obj.Time].'archiveStored' += [double]$obj.'Archive Storage'
  }
  if ($obj.'Replica Storage' -ne 'N/A') {
    $capacityOverTimeHash[$obj.Time].'replicaStored' += [double]$obj.'Replica Storage'
  }
}

# Initialze arrays for creating capacity over time line charts
# $capacityOverTimeCategories = @()
# $capacityOverTimeValues = @()

# foreach ($capMonth in $capacityOverTimeHash.GetEnumerator())
# {
#   $capacityOverTimeCategories += $capMonth.Name
#   $capacityOverTimeValues += [int]($capMonth.value.localStored / 1000000000000)
# }

# Export-LineChart `
#     -ChartTitle "Capacity - Last 12 Months" `
#     -XAxisTitle "Date" `
#     -YAxisTitle "Local Used (TB)" `
#     -XValues $capacityOverTimeCategories `
#     -YValues $capacityOverTimeValues `
#     -chartWidthHeight @(600, 300) `
#     -OutputPath "$chartsDir\CapacityLast12Months.jpg"

$capacityMonths = @()
$capacityProvisioned = @()
$capacityLocalStored = @()
$capacityArchiveStored = @()
$capacityReplicaStored = @()
$capacityCategories = @('FETB Provisioned', 'Local Stored', 'Archival', 'Replica')

foreach ($capMonth in $capacityOverTimeHash.GetEnumerator())
{
  $capacityMonths += $capMonth.Name
  $capacityProvisioned += [int]($capMonth.value.provisionedSize / 1000000000000)
  $capacityLocalStored += [int]($capMonth.value.localStored / 1000000000000)
  $capacityArchiveStored += [int]($capMonth.value.archiveStored / 1000000000000)
  $capacityReplicaStored += [int]($capMonth.value.replicaStored / 1000000000000)
}

$capacityLines = @($capacityProvisioned, $capacityLocalStored,
  $capacityArchiveStored, $capacityReplicaStored)

Export-MultiLineChart -ChartTitle "Capacity - Last 12 Months" `
                     -XAxisTitle "Date" `
                     -YAxisTitle "Capacity (TB)" `
                     -XValues $capacityMonths `
                     -YValueSets $capacityLines `
                     -SeriesNames $capacityCategories `
                     -OutputPath "$chartsDir\CapacityLast12Months.jpg"

Write-Host "Creating HTML tables" -foregroundcolor green

# <div>
#     <img src="$chartsDir\BackupComplianceByCluster.jpg" alt="Compliance by Cluster" width="400" height="300"/>
# </div>

### Creating HTML table styles ###
### HTML formatting borrowed from: @joshuastenhouse

$reportDate = Get-Date -Format "MMMM d, yyyy"

$chartHTML = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Rubrik Daily Executive Report</title>
  <style>
    body {
      font-family: Arial, sans-serif;
      margin: 0;
      padding: 0;
    }
    .charts-container {
        display: flex;                 /* Place charts clearly side-by-side */
        justify-content: center;       /* Horizontally center charts clearly */
        align-items: flex-start;       /* Align charts to top */
        gap: 20px;                     /* Add clearly visible spacing */
        padding: 20px;                 /* Add padding around the charts */
        flex-wrap: wrap;               /* Charts clearly wrap gracefully */
    }
    .chart-box {
        display: flex;
        flex-direction: column;
        align-items: center;
    }
    .charts-container img {
        border: 1px solid #ddd;        /* Optional: add a neat clear border */
        box-shadow: 0 2px 5px rgba(0,0,0,0.1); /* Slight shadow for clarity */
    }
</style>
<html>
<head>
    <title>Rubrik Daily Executive Report</title>
</head>
<body>
    <h2 style="text-align:center;">Rubrik Daily Executive Report ($reportDate)</h2>
    <div class="charts-container">
        <div>
            <img src="$chartsDir\DailyBackupCompliance.jpg" alt="Backup Compliance" width="400" height="300"/>
        </div>
        <div>
            <img src="$chartsDir\BackupComplianceLast30Days.jpg" alt="Backup Compliance Last 30 Days " width="600" height="300"/>
        </div>
    </div>
    <div class="charts-container">
        <div>
            <img src="$chartsDir\BackupComplianceByWorkload.jpg" alt="Compliance by Workload" width="600" height="300"/>
        </div>
    </div>
    <p>Daily Compliance: SLA Protected Objects are "Out-Of-Compliance" if they Failed or Missed a backup that should have taken on that date.
                      <br>Objects are "In Compliance" if all backups that should be taken are succesful.
    <br>
    <div class="charts-container">
        <div>
            <img src="$chartsDir\TotalCapacities.jpg" alt="Capacities" width="400" height="300"/>
        </div>
        <div>
            <img src="$chartsDir\CapacityLast12Months.jpg" alt="Capacities Last 12 Months" width="600" height="300"/>
        </div>
    </div>
    <br>
    <div class="charts-container">
        <div>
            <img src="$chartsDir\CapacityByWorkload.jpg" alt="Capacity by Workload" width="1000" height="300"/>
        </div>
    </div>
    <br>
</body>
</html>
"@

$HTMLHighlightColor="#FFC000"
$HTMLRubrikColor="#00B2A9"
$HTMLRedColor="#FF3355"
$HTMLGreenColor="#2ED51A"

$HTMLStart = @"
  <!DOCTYPE html>
  <html>
  <head>
  <style>
  table.table2 {
    align: center;
    border: 1px solid black;
  }
  table.table2 th {
    text-align: center;
    border: 1px solid black;
    padding: 8px;
    background-color: white;
    color: $HTMLRubrikColor;
    font-size:14px
  }
  table.table2 td {
    text-align: center;
    border: 1px solid black;
    padding: 5px;
    font-size:14px
  }
  table.table2 tr#failed {
    color: white;
    background-color: $HTMLRedColor;
  }
  table.table2 tr#canceled {
    color: black;
    background-color: yellow;
  }
  table.table2 tr#succeeded {
    color: black;
    background-color: $HTMLGreenColor;
  }
  </style>
  </head>
  <body>
  <center>
  <div style="overflow-x:auto;">
  <br><br>
"@

$HTMLEnd = @"
  </div>
  </body>
  </html>
"@
### End HTML table styles ###

# ### Create HTML header info
# $HTMLHeader = @"
#   <b>Rubrik Daily Object Report</b>
#   <br>
#   <b>Date:</b> $date
#   <br><br>
# "@
# ### End HTML header info


### Create HTML Compliance Summary Table
$HTMLComplianceSummaryTable = $null
$HTMLComplianceSummaryTableMiddle = $null

$HTMLComplianceSummaryTableStart = @"
  <table class="table2">
    <tr>
      <th colspan="5">Daily Compliance Summary</th>
    </tr>
    <tr>
      <th>Workload</th>
      <th>Total</th>
      <th>In Compliance</th>
      <th>Out of Compliance</th>
      <th>Compliance Rate</th>
    </tr>
"@

$HTMLComplianceSummaryTableEnd = @"
  </table>
  <br>
"@

foreach ($workload in $workloadComplianceArray | Sort-Object -Property 'Workload')
{
  $HTMLComplianceSummaryTableRow = @"
  <tr>
    <td style=text-align:right>$($workload.'Workload')</td>
    <td style=color:$HTMLRubrikColor><b>$($workload.'Total Compliance')</b></td>
    <td style=color:black;background:$HTMLGreenColor>$($workload.'In Compliance')</td>
    <td style=color:white;background:$HTMLRedColor>$($workload.'Out Compliance')</td>
    <td style=color:$HTMLRubrikColor><b>$($workload.'Compliance Rate')</b></td>
  </tr>
"@
  $HTMLComplianceSummaryTableMiddle += $HTMLComplianceSummaryTableRow
}

$HTMLComplianceSummaryTableMiddle += @"
  <tr style=color:white;background:blue>
    <td>Total</td>
    <td>$($clusterTotal.TotalCompliance)</td>
    <td>$($clusterTotal.InCompliance)</td>
    <td>$($clusterTotal.OutCompliance)</td>
    <td>$($clusterTotal.ComplianceRate)</td>
  </tr>
"@

$HTMLComplianceSummaryTable += $HTMLComplianceSummaryTableStart + $HTMLComplianceSummaryTableMiddle + $HTMLComplianceSummaryTableEnd + "<br><br>"
### End HTML Compliance Summary Table


### Create HTML Task Summary Table
$HTMLTaskSummaryTable = $null
$HTMLTaskSummaryTableMiddle = $null

$HTMLTaskSummaryTableStart = @"
  <table class="table2">
    <tr>
      <th colspan="7">Daily Backup Task Summary</th>
    </tr>
    <tr>
      <th>Workload</th>
      <th>Total</th>
      <th>Succeeded</th>
      <th>Succeeded with Warnings</th>
      <th>Failed</th>
      <th>Canceled</th>
      <th>Succeeded Rate</th>
    </tr>
"@

$HTMLTaskSummaryTableEnd = @"
  </table>
  <br>
"@

foreach ($workloadStatus in $workloadTaskHash.GetEnumerator() | Sort-Object -Property 'Name' )
{
  $value = $($workloadStatus.Value)
  $HTMLTaskSummaryTableRow = @"
  <tr>
    <td style=text-align:right>$($workloadStatus.'Name')</td>
    <td style=color:$HTMLRubrikColor><b>$($value.'TotalCount')</b></td>
    <td style=color:black;background:$HTMLGreenColor>$($value.'SucceededCount')</td>
    <td style=color:black;background:$HTMLGreenColor>$($value.'SucceededWithWarningsCount')</td>
    <td style=color:white;background:$HTMLRedColor>$($value.'FailedCount')</td>
    <td style=color:black;background:yellow>$($value.'CanceledCount')</td>
    <td style=color:$HTMLRubrikColor><b>$($value.'SucceededRate')</b></td>
  </tr>
"@
  $HTMLTaskSummaryTableMiddle += $HTMLTaskSummaryTableRow
}

$HTMLTaskSummaryTableMiddle += @"
  <tr style=color:white;background:blue>
    <td>Total</td>
    <td>$($clusterTotal.TotalCount)</td>
    <td>$($clusterTotal.SucceededCount)</td>
    <td>$($clusterTotal.SucceededWithWarningsCount)</td>
    <td>$($clusterTotal.FailedCount)</td>
    <td>$($clusterTotal.CanceledCount)</td>
    <td>$($clusterTotal.SucceededRate)</td>
  </tr>
  <tr>
  <p>Tasks: A task is an individual backup job. This may differ slightly from compliance depending on when a task was scheduled.
        <br> There could be more or less daily backups for each object depending on the SLA backup frequency.
  <br>
  </tr>
"@

$HTMLTaskSummaryTable += $HTMLTaskSummaryTableStart + $HTMLTaskSummaryTableMiddle + $HTMLTaskSummaryTableEnd + "<br><br>"
### End HTML Task Summary Table


### Create HTML Object Out of Compliance Table
$HTMLOutComplianceTable = $null
$HTMLOutComplianceTableMiddle = $null

if ($allCompliance = $false) {
  $complianceTableHeader = "Daily Object Out of Compliance List - Backups"
} else {
  $complianceTableHeader = "Daily Object Out of Compliance List - Backups, Replication, Archival"
}

$HTMLOutComplianceTableStart = @"
  <table class="table2">
    <tr>
      <th colspan="7">$complianceTableHeader</th>
    </tr>
    <tr>
      <th>Name</th>
      <th>Host</th>
      <th>Cluster</th>
      <th>Local Days Behind</th>
      <th>Last Successful Backup</th>
      <th>Latest Replicated Backup</th>
      <th>Latest Archived Backup</th>
    </tr>
"@

$HTMLOutComplianceTableEnd = @"
  </table>
  <br>
"@

# Loop through each out of compliance object and create a row
foreach ($obj in $objectsOutCompliance)
{
  # Formats display based on whether backups are compliant or not
  if ($obj.'Compliance status' -match 'Out of Compliance') {
    $backupColor = 'orange'
    $backupLocalDaysBehind = $obj.'Local Days Behind'
    $backupLastLocal = $obj.'Last Successful Backup'
  } else {
    $backupColor = 'white'
    $backupLocalDaysBehind = ''
    $backupLastLocal = ''
  }
  # Formats display based on whether replication is compliant or not
  if ($obj.'Replication compliance status' -match 'Out of Compliance') {
    $replicationColor = 'orange'
    $replicationLastSnapshot = $obj.'Latest Replication Snapshot'
  } else {
    $replicationColor = 'white'
    $replicationLastSnapshot = ''
  }
  # Formats display based on whether archival is compliant or not
  if ($obj.'Archival compliance status' -match 'Out Of Compliance') {
    $archivalColor = 'orange'
    $archivalLastSnapshot = $obj.'Latest Archival Snapshot'
  } else {
    $archivalColor = 'white'
    $archivalLastSnapshot = ''
  }
  $HTMLOutComplianceTableRow = @"
  <tr>
    <td style=text-align:left>$($obj.'Object')</td>
    <td style=text-align:left>$($obj.'Location')</td>
    <td style=text-align:left>$($obj.'Cluster')</td>
    <td style=background:$backupColor>$backupLocalDaysBehind</td>
    <td style=background:$backupColor>$backupLastLocal</td>
    <td style=background:$replicationColor>$replicationLastSnapshot</td>
    <td style=background:$archivalColor>$archivalLastSnapshot</td>
  </tr>
"@
  $HTMLOutComplianceTableMiddle += $HTMLOutComplianceTableRow
}

$HTMLOutComplianceTable += $HTMLOutComplianceTableStart + $HTMLOutComplianceTableMiddle + $HTMLOutComplianceTableEnd + "<br><br>"
### End HTML Object Out of Compliance Table


### Create HTML Task Table
$HTMLTaskTable = $null
$HTMLTaskTableMiddle = $null

$HTMLTaskTableStart = @"
  <table class="table2">
    <tr>
      <th colspan="9">Daily Object Task Report</th>
    </tr>
    <tr>
      <th>Object Name</th>
      <th>Host</th>
      <th>Cluster Name</th>
      <th>Status</th>
      <th>Data Transferred (GB)</th>
      <th>Started</th>
      <th>Ended</th>
      <th>Duration</th>
      <th>Status Reason</th>
    </tr>
"@

$HTMLTaskTableEnd = @"
  </table>
  <br>
"@

if ($showSucceeded -eq $false) {
  $taskTable = $rubrikTasksSorted | Where { $_.'Task Status' -match 'Fail' -or
    $_.'Task Status' -match 'Cancel' }
}

# Loop through each report summary info and create a row
foreach ($task in $taskTable)
{
  if ($task.'Task Status' -match 'Failed')
  {
    $HTMLTaskTableRow = @"
    <tr id="failed">
"@
  } elseif ($task.'Task Status' -match 'Canceled')
  {
    $HTMLTaskTableRow = @"
    <tr id="canceled">
"@
  } else
  {
    $HTMLTaskTableRow = @"
    <tr id="succeeded">
"@
  }
  # if ($showSucceeded -eq $true)
  # {
    $HTMLTaskTableRow += @"
      <td style=text-align:left>$($task.'Object Name')</td>
      <td style=text-align:left>$($task.'Location')</td>
      <td style=text-align:left>$($task.'Cluster Name')</td>
      <td>$($task.'Task Status')</td>
      <td>$($task.'Data Trans GB')</td>
      <td>$($task.'Start Time')</td>
      <td>$($task.'End Time')</td>
      <td>$($task.'Duration Text')</td>
      <td>$($task.'Status Reason')</td>
    </tr>
"@

    $HTMLTaskTableMiddle += $HTMLTaskTableRow
  # }
}

$HTMLTaskTable += $HTMLTaskTableStart + $HTMLTaskTableMiddle + $HTMLTaskTableEnd + "<br><br>"
### End HTML Task Table

# Put all pieces of HTML together
$HTMLReport = $chartHTML + $HTMLStart + $HTMLComplianceSummaryTable + $HTMLTaskSummaryTable + $HTMLOutComplianceTable + $HTMLTaskTable + $HTMLEnd
$HTMLReport = $chartHTML + $HTMLStart + $HTMLComplianceSummaryTable + $HTMLTaskSummaryTable + $HTMLEnd

$HTMLReport | Out-File -FilePath $htmlOutput
Write-Host "`nHTML report output to: $htmlOutput" -foregroundcolor green

# Send an email with CSV attachment
if ($sendEmail) {
  Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -BodyAsHtml -Body $HTMLReport -SmtpServer $SMTPServer -Port $SMTPPort
}
