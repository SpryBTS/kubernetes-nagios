#!/bin/bash

function usage() {
	if [ -t 0 ]; then
		cat << _EOF_
Usage: $(basename $0) [-t token] [-c curlcmd ] [-a apiurl] <nodename>

   -t <token>        # barer toekn for api authorization
   -c <curlcmd>      # override the default curl command line
   -a <apiurl>       # the endpoint for the kubernetes api
   <nodename>        # the kubernetes node to query details for

_EOF_
		exit 0
	else
		nagios 2 "Usage: $(basename $0) [-t token] [-c curlcmd ] [-a apiurl] <nodename>"
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

if [ -z "$1" ] || [ -n "$2" ]; then
	usage
fi
NODE="$1"

query=$(eval $CURLCMD "$APIURL/api/v1/nodes")

if [ -z "$query" ]; then
	nagios 2 "Unable to query api for nodes: $APIURL"
fi

if ! echo $query | jq . >/dev/null 2>&1; then
	nagios 2 "Unable to parse nodes as json"
fi


if [ "$(echo $query | jq -r .kind)" = "Status" ]; then
	nagios 2 "Error querying api: "$(errortxt "$query")
fi

query=$(echo $query | jq -r '.items[] | select(.metadata.name=="'$NODE'")')

if [ -z "$query" ]; then
	nagios 3 "Node $NODE not found in api query"
fi

checks=$(echo $query | jq -r '.status.conditions[].type')

if [ -z "$checks" ]; then
	nagios 3 "No checks returned in api query"
fi

echo $query | jq '.spec.taints[].key' 2>/dev/null | grep -q /unreachable
if [ $? -eq 0 ]; then
	nagios 2 "Node is unreachable."
fi

allcond_cnt=0
healthy_cnt=0
starved_cnt=0
unknown_cnt=0

starved_txt=""
unknown_txt=""

text=""
code=0

state=0
for check in $checks; do
	[ "$check" != "Ready" ] && allcond_cnt=$((allcond_cnt+1))

	status=$(echo $query | jq -r '.status.conditions[]
			| select(.type=="'$check'") .status'
	)
	case "$check-$status" in
		Ready-False) [ "$state" -lt 1 ] && state=1 ;;
		DiskPressure-True)
			starved_cnt=$(($starved_cnt+1))
			starved_txt=$(printf "%s%s" "${starved_txt:+$starved_txt,}" $check)
			[ "$state" -lt 2 ] && state=2 ;;
		OutOfDisk-True)
			starved_cnt=$(($starved_cnt+1))
			starved_txt=$(printf "%s%s" "${starved_txt:+$starved_txt,}" $check)
			[ "$state" -lt 2 ] && state=2 ;;
		MemoryPressure-True)
			starved_cnt=$(($starved_cnt+1))
			starved_txt=$(printf "%s%s" "${starved_txt:+$starved_txt,}" $check)
			[ "$state" -lt 2 ] && state=2 ;;
		NetworkUnavailable-True)
			starved_cnt=$(($starved_cnt+1))
			starved_txt=$(printf "%s%s" "${starved_txt:+$starved_txt,}" $check)
			[ "$state" -lt 2 ] && state=2 ;;
		PIDPressure-True)
			starved_cnt=$(($starved_cnt+1))
			starved_txt=$(printf "%s%s" "${starved_txt:+$starved_txt,}" $check)
			[ "$state" -lt 2 ] && state=2 ;;
		*-Unknown)
			unknown_cnt=$(($unknown_cnt+1))
			unknown_txt=$(printf "%s%s" "${unknown_txt:+$unknown_txt,}" $check)
			state=3 ;;
		Ready-*) ;;
		DiskPressure-*) healthy_cnt=$(($healthy_cnt+1)) ;;
		OutOfDisk-*) healthy_cnt=$(($healthy_cnt+1)) ;;
		MemoryPressure-*) healthy_cnt=$(($healthy_cnt+1)) ;;
		NetworkUnavailable-*) healthy_cnt=$(($healthy_cnt+1)) ;;
		PIDPressure-*) healthy_cnt=$(($healthy_cnt+1)) ;;
		*)
			unknown_cnt=$(($unknown_cnt+1))
			unknown_txt=$(printf "%s%s" "${unknown_txt:+$unknown_txt,}" $check)
		 	state=3 ;;
	esac
done

text=$(printf "%d of %d condition%s healthy." \
	$healthy_cnt $allcond_cnt \
	"$([[ $allcond_cnt -eq 1 ]] && echo ' is' || echo 's are')"
)

if [ "$state" -eq 1 ]; then
	text=$(printf "%s Node is unready." "$text")
	code=1
fi

if [ "$starved_cnt" -gt 0 ]; then
	text=$(printf "%s %s starved (%s)" \
		"$text" $starved_cnt "$starved_txt"
	)
	code=2
fi
if [ "$unknown_cnt" -gt 0 ]; then
	text=$(printf "%s %s unknown (%s)"\
		"$text" $unknown_cnt "$unknown_txt"
	)
	code=3
fi

for stat in $(echo $query | jq -r '.status.allocatable | keys[]' | sort); do
	stats=$(printf "%s %s=%s;;" "$stats" $stat \
		$(echo $query | jq -r ".status.allocatable.\"$stat\""))
done

nagios $code "$text|$stats"
