#!/bin/bash

function usage() {
        if [ -t 0 ]; then
                cat << _EOF_
Usage: $(basename $0) [-t token] [-c curlcmd ] [-a apiurl] [-n namespace]

   -t <token>        # barer toekn for api authorization
   -c <curlcmd>      # override the default curl command line
   -a <apiurl>       # the endpoint for the kubernetes api
   -n <namespace>    # the kubernetes namespace to check

_EOF_
                exit 0
        else
                nagios 2 "Usage: $(basename $0) [-t token] [-c curlcmd ] [-a apiurl] [-n namespace]"
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

while getopts ":t:a:c:n:h" OPTIONS; do
        case "${OPTIONS}" in
                t) TOKEN=${OPTARG} ;;
                a) APIURL=${OPTARG} ;;
                c) CURLCMD=${OPTARG} ;;
                n) NAMESPC=${OPTARG} ;;
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

if [ -n "$NAMESPC" ]; then
	names=$NAMESPC
else
	query=$(eval $CURLCMD "$APIURL/api/v1/namespaces")
	
	if [ -z "$query" ]; then
		nagios 2 "Unable to query api for names: $APIURL"
	fi
	
	if ! echo $query | jq . >/dev/null 2>&1; then
	        nagios 2 "Unable to parse names as json"
	fi
	
	if [ "$(echo $query | jq -r .kind)" = "Status" ]; then
		nagios 2 "Error quering api for names: "$(errortxt "$query")
	fi
	
	names=$(echo $query | jq -r '.items[].metadata.name')
	
	if [ -z "$names" ]; then
		nagios 3 "No namespaces returned in api query"
	fi
fi

allstatefuls_cnt=0
podsmatch_cnt=0
badstatefuls_cnt=0
badstatus_cnt=0

badstatefuls_txt=""
badstatus_txt=""

text=""
code=0

for name in $names; do
	query=$(eval $CURLCMD "$APIURL/apis/apps/v1beta1/namespaces/$name/statefulsets/")

        if [ -z "$query" ]; then
                nagios 2 "Unable to query $name for statefulsets: $APIURL"
        fi
        
        if ! echo $query | jq . >/dev/null 2>&1; then
                nagios 2 "Unable to parse statefulsets in $name as json"
        fi
        
        if [ "$(echo $query | jq -r .kind)" = "Status" ]; then
                nagios 2 "Error quering api for statefulsets in $name: "$(errortxt "$query")
        fi

        statefulss=$(echo $query | jq -r '.items[].metadata.name')
        
        if [ -z "$statefulss" ]; then
		if [ -n "$NAMESPC" ]; then
	                nagios 3 "No statefulsets in $name returned in api query"
		else
			continue
		fi
        fi

	for statefuls in $statefulss; do
		allstatefuls_cnt=$((allstatefuls_cnt+1))
		specr=$(echo $query | jq '.items[] 
				| select(.metadata.name=="'$statefuls'")
				| .spec.replicas')
                statr=$(echo $query | jq '.items[] 
                                | select(.metadata.name=="'$statefuls'")
                                | .status.replicas')

		ready=$(echo $query | jq '.items[] 
				| select(.metadata.name=="'$statefuls'")
				| .status.readyReplicas')
		if ! echo "$ready" | grep -q ^[0-9]; then
			ready=0
		fi

		if [ "$ready" -eq "$specr" ]; then
			podsmatch_cnt=$(($podsmatch_cnt+1))
		elif [ "$statr" -eq "$specr" ]; then
			badstatefuls_cnt=$((badstatefuls_cnt+1))
			if [ -n "$NAMESPC" ]; then
				badstatefuls_txt=$(printf "%s%s" "${badstatefuls_txt:+$badstatefuls_txt,}" "$statefuls")
			else
				badstatefuls_txt=$(printf "%s%s" "${badstatefuls_txt:+$badstatefuls_txt,}" "$name/$statefuls")
			fi
		else
			badstatus_cnt=$(($badstatus_cnt+1))
			if [ -n "$NAMESPC" ]; then
				badstatus_txt=$(printf "%s%s" "${badstatus_txt:+$badstatus_txt,}" "$statefuls")
			else
				badstatus_txt=$(printf "%s%s" "${badstatus_txt:+$badstatus_txt,}" "$name/$statefuls")
			fi
		fi
	done
done

text=$(printf "%d of %d statefulsetset%s healthy." \
        $podsmatch_cnt $allstatefuls_cnt \
        "$([[ $allnode_cnt -eq 1 ]] && echo ' is' || echo 's are')"
)

if [ "$badstatefuls_cnt" -gt 0 ]; then
        text=$(printf "%s %s unhealthy (%s)" \
                "$text" $badstatefuls_cnt "$badstatefuls_txt"
        )
        code=2	
fi

if [ "$badstatus_cnt" -gt 0 ]; then
        text=$(printf "%s %s mismatched (%s)" \
                "$text" $badstatus_cnt "$badstatus_txt"
        )
        code=2	
fi

stats=$(printf "allstatefuls=%d;; healthy=%d;; unhealthy=%d;; mismatch=%d" \
        $allstatefuls_cnt $podsmatch_cnt $badstatefuls_cnt $badstatus_cnt
)

nagios $code "$text|$stats"
