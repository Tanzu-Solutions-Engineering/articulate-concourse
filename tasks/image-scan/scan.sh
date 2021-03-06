#!/bin/bash

set -e -u

exec 3>&1 # make stdout available as fd 3 for the result
exec 1>&2 # redirect all output to stderr for logging

source $(dirname $0)/common.sh

username=$username
password=$password
repository=$repository
tag=$(cat $tag)
harbor_host=$harbor_host
harbor_scan_thresholds=$harbor_scan_thresholds

export harbor_image=$(echo $repository | cut -f2- -d '/')
export harbor_project=$(echo $repository | cut -f2- -d '/' | cut -f2- -d '/')
export harbor_respoitory_encoded=$harbor_image
export scan_check_tries=10
export scan_check_interval=5

harbor_curl_scan() {
    	response=$(curl -sk --write-out "%{http_code}\n" --output /dev/null -H "Content-Type: application/json" -X POST --user $username:$password "https://$harbor_host/api/v2.0/projects/$harbor_project/repositories/$harbor_project/artifacts/$tag/scan" )
    	if [ $response != "202" ]; then
    		echo "Failed to initiate Harbor Scan on https://$harbor_host/api/v2.0/projects/$harbor_project/repositories/$harbor_project/artifacts/$tag/scan !!!"
    		exit 1
    	else
    		echo "Scan Initiated on https://$harbor_host/api/v2.0/projects/$harbor_project/repositories/$harbor_project/artifacts/$tag/scan ..."
    	fi
    }

harbor_curl_scan_check() {
    response=$(curl -sk -H "Content-Type: application/json" -X GET --user $username:$password "https://$harbor_host/api/v2.0/projects/$harbor_project/repositories/$harbor_project/artifacts/$tag?with_scan_overview=true" | jq '.scan_overview[].scan_status' | tr -d "\"")
    echo $response
}

harbor_curl_scan_summary() {
    response=$(curl -sk -H "Content-Type: application/json" -X GET --user $username:$password "https://$harbor_host/api/v2.0/projects/$harbor_project/repositories/$harbor_project/artifacts/$tag?with_scan_overview=true" | jq '.scan_overview[].summary')
        echo $response
}

echo "Triggering Image scan..."
  	harbor_curl_scan


# Check if Scan is complete or if it hasnt been triggered.

for i in $(seq 1 $scan_check_tries);
do
    echo $(harbor_curl_scan_check)
    scan_state=$(harbor_curl_scan_check)
    echo "Checking if Clair Scan is finished, attempt $i of $scan_check_tries ... RESULT: $scan_state"
    if [ $scan_state = "Success" ]; then
        echo "Clair Scan Complete"
        break
    else
        sleep $scan_check_interval
    fi
done


# Checkpipeline thresholds & print Summary Report
echo "Harbor Summary Report of CVE's found:"
harbor_curl_scan_summary=$(harbor_curl_scan_summary)

echo $harbor_curl_scan_summary | jq .

# Check Tresholds Json & Trigger if summary CVEs exceed
threshold_trigger=false

for row in $(echo "${harbor_scan_thresholds}" | jq -r '.[] | @base64'); do
    _jq() {
        echo ${row} | base64 -d | jq -r ${1}
    }

    cve_sev=$(_jq '.severity')
    cve_threshold=$(_jq '.count')

    get_count_cmd="echo '$harbor_curl_scan_summary' | jq ' .summary.$cve_sev'"
    count=$(eval $get_count_cmd)
    if [ ! -z $count ] && [ $count != null  ] && [ $count -gt $cve_threshold ]; then
        echo "Image exceed threshold of $cve_threshold for CVE-Severity:$cve_sev with a count of $count"
        threshold_trigger=true
    fi
done

if [ $threshold_trigger = true ]; then
    echo "One or more Clair Scan Thresholds have been exceeded !!!"
    echo "Collecting CVE Scan Details from Harbor ..."
    echo "==========================================================================="
    echo "DETAILED CVE ANALYSIS:"
    echo "==========================================================================="

    echo $harbor_curl_scan_summary | jq .
    exit 1
fi

jq -n "{
  version: {}
}" >&3
