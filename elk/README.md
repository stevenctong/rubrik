# Rubrik for ELK
These set of files help integrate Rubrik with ELK stack.

Notifications from Rubrik can be pushed using Syslog. Additional metrics can be gathered via pull/poll using the REST API. 

![image](https://user-images.githubusercontent.com/32583640/138604534-f545febc-9d47-4431-99fa-858310b14243.png)

## Components

1) Syslog - Configure in Rubrik to send Syslog events to Logstash
2) Logstash - Parses the Syslog messages using ‘grok’ patterns. ‘Grok’ patterns are based on regular expressions to decipher our Syslog messages and split the contents into specific fields. The parsed fields are then sent to Elasticsearch
3) Elasticsearch - Database that stores the log files as documents and indexes. It is also possible to send data directly to Elasticsearch without going through Logstash
4) Kibana - Used to visualize and discover patterns in data stored in Elasticsearch

For data that is gathered via the REST API:
1) Script on a Host - A script to pull the data you want from the Rubrik cluster over the REST API and scheduled to run at periodic intervals. The output for the script should be a JSON file written to a certain directory on the host its run on, eg `var/log/rubrikelk`
2) Filebeat - Filebeat (lightweight software also from Elastic) is installed on the script host to monitor for any updates to the directory that the script is writing to. If it sees an update, Filebeat will send the new data to a destination, either to Logstash or directly to Elasticsearch 

## Syslog

Rubrik Syslog messages are in a standard format. Therefore, it is easy to create 'grok' patterns for Logstash to match the rule and pull out the relevant fields. These rules are contained in: 

- `10-logstash-rubrik-syslog.conf`

We only need two different 'grok' patterns to match all Syslog message types. Once matched, the message can be sent to Elasticsearch. Any 'grok' pattern failures can also be logged.

## Metrics via Script

Additional metrics or data can be gathered via a script. The scripts can be run from any host that has connectivity to the Rubrik cluster(s). The script can be scheduled to run periodically using `cron` (Linux) or as a Windows Scheduled Task.

Two scripts are available to use as examples:

- `get_rubrik_stats.sh` - Bash
- `Get-RubrikStats.ps1` - Powershell (contains more recent updates)

The script formats all the desired data as a JSON and appends it to a log file.

Filebeat is used to monitor the log file folder for any updates to that log file folder and ships the update to Logstash.

The conf file examples for Filebeat are contained here: 

- `filebeat.yml`
- `20-logstash-rubrik-filebeat.conf`

## Kibana

Kibana is used to visualize the documents from Elasticsearch. In Kibana, you can create an index pattern to create an index for the Rubrik documents in Elasticsearch.

Once the index is available you can use it to search for data or create dashboards.

An example dashboard can be found here: `kibana_export_2020-02-23.ndjson`

![image](https://user-images.githubusercontent.com/32583640/138605335-bac9458a-0587-47a7-8cbd-92fc8c8562b6.png)

![image](https://user-images.githubusercontent.com/32583640/138605343-ed2b6040-994b-4c00-89bf-666a850c2cc7.png)

## Additional Details

See: `Rubrik-Integrating_with_ELK_Syslog_REST_2021-02-24.pdf`
