@{
  # Filepath for the RSC Service Account json creds
  serviceAccountPath = './rsc-gaia.json'
  # The RSC report IDs for each of the reports used in this script
  reportIDdailyComplianceReport = 3170
  reportIDdailyTaskReport = 3173
  reportIDobjectCapacityReport = 3189
  reportIDobjectCapacityOverTimeReport = 3190
  # Filename prefix for html report - the date and .html will be appended to it
  htmlOutput = './Rubrik-Daily_Exec_Report'
  # Filepath to to save historical object compliance data
  csvComplianceData = './csvData/rubrik_compliance_data.csv'
  # Directory to save the working jpg charts into
  chartsDir = 'C:\scripts\charts'
  # Whether save the report CSVs
  saveCSV = $true
  # Directory to save the report CSVs to
  csvReportDir = './csvReports/'
  # Filename prefixes for each of the CSV reports to be saved in the csvReportDir
  # The date and .csv appended to this filename
  csvReportTasks = 'rubrik_task_report'
  csvReportCompliance = 'rubrik_compliance_report'
  csvReportCapacity = 'rubrik_capacity_report'
  csvReportCapacityOverTime = 'rubrik_capacity_over_time_report'
  # Whether to send out an email at the end of this script
  sendEmail = $false
  # SMTP configuration if sending an email at the end of this script
  emailTo = @('')
  emailFrom = ''
  SMTPServer = ''
  SMTPPort = 25
  # Email subject will also be appended with the date
  emailSubject = 'Rubrik Daily Exec Report'
  # Whether to show objects that are out of archival and replication compliance
  # in the compliance table. These will not be added to the compliance counts,
  # only backup compliance is included in the compliance counts.
  allCompliance = $true
  # Whether to show successful tasks in the task table
  showSucceeded = $false
  # Sort order options: "Start time", "End time", "Duration", "Data transferred"
  sortOrder = 'Start time'
}
