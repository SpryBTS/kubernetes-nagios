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

query=$(eval $CURLCMD "$APIURL/api/v1/nodes")

if [ -z "$query" ]; then
	nagios 2 "Unable to query api for nodes: $APIURL"
fi

if ! echo $query | jq . >/dev/null 2>&1; then
        nagios 2 "Unable to parse nodes as json"
fi

if [ "$(echo $query | jq -r .kind)" = "Status" ]; then
	nagios 2 "Error querying api for nodes: "$(errortxt "$query")
fi

nodes=$(echo $query | jq -r '.items[].metadata.name')

if [ -z "$nodes" ]; then
	nagios 3 "No nodes returned in api query"
fi

checks=$(echo $query \
	| jq -r '.items[] | .status.conditions[].type' \
	| sort | uniq
)

if [ -z "$checks" ]; then
	nagios 3 "No checks returned in api query"
fi

allnode_cnt=0
healthy_cnt=0
unreach_cnt=0
unready_cnt=0
starved_cnt=0
unknown_cnt=0

unreach_txt=""
unready_txt=""
starved_txt=""
unknown_txt=""

text=""
code=0

for node in $nodes; do
	allnode_cnt=$((allnode_cnt+1))

	nodeq=$(echo $query | jq -r '.items[] | select(.metadata.name=="'$node'")')

	echo $nodeq | jq '.spec.taints[].key' 2>/dev/null | grep -q /unreachable
	if [ $? -eq 0 ]; then
		unreach_cnt=$(($unreach_cnt+1))
		unreach_txt=$(printf "%s%s" "${unreach_txt:+$unreach_txt,}" $node)
		continue
	fi

	state=0
	for check in $checks; do
	        status=$(echo $nodeq | jq -r '.status.conditions[]
	                        | select(.type=="'$check'") .status'
	        )
		case "$check-$status" in
			Ready-False) [ "$state" -lt 1 ] && state=1 ;;
			DiskPressure-True) [ "$state" -lt 2 ] && state=2 ;;
			OutOfDisk-True) [ "$state" -lt 2 ] && state=2 ;;
			MemoryPressure-True) [ "$state" -lt 2 ] && state=2 ;;
			NetworkUnavailable-True) [ "$state" -lt 2 ] && state=2 ;;
			PIDPressure-True) [ "$state" -lt 2 ] && state=2 ;;
			*-Unknown) state=3 ;;
			Ready-*) ;;
			DiskPressure-*) ;;
			OutOfDisk-*) ;;
			MemoryPressure-*) ;;
			NetworkUnavailable-*) ;;
			PIDPressure-*) ;;
			*) state=3 ;;
		esac
	done
	
	if [ "$state" -eq 0 ]; then
		healthy_cnt=$(($healthy_cnt+1))
	elif [ "$state" -eq 1 ]; then
		unready_cnt=$(($unready_cnt+1))
		unready_txt=$(printf "%s%s" "${unready_txt:+$unready_txt,}" $node)
	elif [ "$state" -eq 2 ]; then	
		starved_cnt=$(($starved_cnt+1))
		starved_txt=$(printf "%s%s" "${starved_txt:+$starved_txt,}" $node)
	else
		unknown_cnt=$(($unknown_cnt+1))
		unknown_txt=$(printf "%s%s" "${unknown_txt:+$unknown_txt,}" $node)
	fi
	[ "$state" -gt "$code" ] && code=$state
done

text=$(printf "%d of %d node%s healthy." \
	$healthy_cnt $allnode_cnt \
	"$([[ $allnode_cnt -eq 1 ]] && echo ' is' || echo 's are')"
)

if [ "$unready_cnt" -gt 0 ]; then
	text=$(printf "%s %d unready (%s)" \
		"$text" $unready_cnt "$unready_txt"
	)
	code=1
fi
if [ "$unreach_cnt" -gt 0 ]; then
	text=$(printf "%s %s unreachable (%s)" \
		"$text" $unreach_cnt "$unreach_txt"
	)
	code=2
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

stats=$(printf "allnode=%d;; healthy=%d;; unreach=%d;;" \
	$allnode_cnt $healthy_cnt $unreach_cnt
)
stats=$(printf "%s unready=%d;; starved=%d;; unknown=%d" \
	"$stats" $unready_cnt $starved_cnt $unknown_cnt
)

nagios $code "$text|$stats"
