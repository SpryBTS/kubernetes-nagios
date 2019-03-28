#!/bin/bash

function usage() {
	if [ -t 0 ]; then
		cat << _EOF_
Usage: $(basename $0) [-t token] [-c curlcmd ] [-a apiurl]

   -t <token>        # barer toekn for api authorization
   -c <curlcmd>      # override the default curl command line
   -a <apiurl>       # the endpoint for the kubernetes api

_EOF_
		exit 0
	else
		nagios 2 "Usage: $(basename $0) [-t token] [-c curlcmd ] [-a apiurl]"
	fi
}

function nagios() {
        code=$1
        shift
        if [ $code -eq 0 ]; then
                text="OK - $@"
        elif [ $code -eq 1 ]; then
                text="WARNING - $@"
        elif [ $code -eq 2 ]; then
                text="CRITICAL - $@"
        else
                code=3
                text="UNKNOWN - $@"
        fi
        echo $text
        exit $code
}

function errortxt() {
	json=$1
	text=$(printf "%s: %s (%d): %s" \
		"$(echo $json | jq -r .status)" \
		"$(echo $json | jq -r .message)" \
		"$(echo $json | jq -r .code)" \
		"$(echo $json | jq -r .reason)"
	)
	echo "$text"
}

while getopts ":t:a:c:h" OPTIONS; do
        case "${OPTIONS}" in
                t) TOKEN=${OPTARG} ;;
                a) APIURL=${OPTARG} ;;
		c) CURLCMD=${OPTARG} ;;
                h) usage ;;
                *) usage ;;
        esac
done
shift $((OPTIND-1))

[ -z "$CURLCMD" ] && CURLCMD="curl -s -k"
[ -n "$TOKEN" ] && CURLCMD="$CURLCMD --header 'Authorization: Bearer $TOKEN'"
[ -z "$APIURL" ] && APIURL="https://127.0.0.1:6443"

if [ -n "$1" ]; then
	usage
fi

status=$(eval $CURLCMD "$APIURL/healthz$i")

if [ -z "$status" ]; then
        nagios 2 "Unable to query api: $APIURL"
fi

if [ "$status" != "ok" ]; then
	nagios 2 "api returned not ok: $(IFS=' '; echo $status | grep -v ok$)"
fi

nagios 0 "api returned ok status"
