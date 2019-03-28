#!/bin/bash

env > /tmp/env
set > /tmp/set

function usage() {
        if [ -t 0 ]; then
                cat << _EOF_
Usage: $(basename $0) [-t token] [-c curlcmd ] [-a apiurl] [-n namespace] [-p podname]

   -t <token>        # barer toekn for api authorization
   -c <curlcmd>      # override the default curl command line
   -a <apiurl>       # the endpoint for the kubernetes api
   -n <namespace>    # the kubernetes namespace to check
   -p <podname>      # search string for pod names to check

_EOF_
                exit 0
        else
                nagios 2 "Usage: $(basename $0) [-t token] [-c curlcmd ] [-a apiurl] [-n namespace] [-p podname]"
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

while getopts ":t:a:c:n:p:h" OPTIONS; do
        case "${OPTIONS}" in
                t) TOKEN=${OPTARG} ;;
                a) APIURL=${OPTARG} ;;
                c) CURLCMD=${OPTARG} ;;
                n) NAMESPC=${OPTARG} ;;
		p) PODNAME=${OPTARG} ;;
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

nodeq=$(eval $CURLCMD "$APIURL/api/v1/nodes")

if [ -z "$nodeq" ]; then
        nagios 2 "Unable to query api for nodes: $APIURL"
fi

if ! echo $nodeq | jq . >/dev/null 2>&1; then
        nagios 2 "Unable to parse nodes as json"
fi

if [ "$(echo $nodeq | jq -r .kind)" = "Status" ]; then
        nagios 2 "Error querying api for nodes: "$(errortxt "$nodeq")
fi

allpods_cnt=0
healthy_cnt=0
unready_cnt=0
unreach_cnt=0
unknown_cnt=0

unready_txt=""
unreach_txt=""
unknown_txt=""

text=""
code=0

for name in $names; do
	query=$(eval $CURLCMD "$APIURL/api/v1/namespaces/$name/pods")


        if [ -z "$query" ]; then
                nagios 2 "Unable to query $name for pods: $APIURL"
        fi
        
        if ! echo $query | jq . >/dev/null 2>&1; then
                nagios 2 "Unable to parse pods in $name as json"
        fi
        
        if [ "$(echo $query | jq -r .kind)" = "Status" ]; then
                nagios 2 "Error quering api for pods in $name: "$(errortxt "$query")
        fi

	if [ -n "$PODNAME" ]; then
	        pods=$(echo $query | jq -r '.items[].metadata.name' | grep "$PODNAME")
	else
	        pods=$(echo $query | jq -r '.items[].metadata.name')
	fi
        
        if [ -z "$pods" ]; then
		if [ -n "$NAMESPC" ]; then
			if [ -n "$PODNAME" ]; then
		                nagios 3 "No pods matching $PODNAME in $name returned in api query"
			else
		                nagios 3 "No pods in $name returned in api query"
			fi
		else
			continue
		fi
        fi

	for pod in $pods; do
		allpods_cnt=$((allpods_cnt+1))

		podq=$(echo $query | jq -r '.items[] | select(.metadata.name=="'$pod'")')
		checks=$(echo $podq | jq -r '.status.conditions[].type')

	        state=0
	        for check in $checks; do
	                status=$(echo $podq | jq -r '.status.conditions[]
	                                | select(.type=="'$check'") .status'
	                )
	                case "$check-$status" in
	                        Ready-False) [ "$state" -lt 2 ] && state=2 ;;
	                        Initialized-False) [ "$state" -lt 2 ] && state=2 ;;
	                        ContainersReady-False) [ "$state" -lt 2 ] && state=2 ;;
	                        PodScheduled-False) [ "$state" -lt 2 ] && state=2 ;;
	                        *-Unknown) state=3 ;;
	                        Ready-*) ;;
	                        Initialized-*) ;;
	                        ContainersReady-*) ;;
	                        PodScheduled-*) ;;
	                        *) state=3 ;;
	                esac
	        done
	        if [ "$state" -eq 0 ]; then
	                healthy_cnt=$(($healthy_cnt+1))
	        elif [ "$state" -eq 2 ]; then
			node=$(echo $podq | jq -r .spec.nodeName)
			if echo $nodeq | jq -r '.items[] | select(.metadata.name=="'$node'") | .spec.taints[].key' 2>/dev/null | grep -q /unreachable; then
				state=1
		                unreach_cnt=$(($unreach_cnt+1))
		                unreach_txt=$(printf "%s%s" "${unreach_txt:+$unreach_txt,}" $pod)
			else
		                unready_cnt=$(($unready_cnt+1))
		                unready_txt=$(printf "%s%s" "${unready_txt:+$unready_txt,}" $pod)
			fi
	        else
	                unknown_cnt=$(($unknown_cnt+1))
	                unknown_txt=$(printf "%s%s" "${unknown_txt:+$unknown_txt,}" $pod)
	        fi
	        [ "$state" -gt "$code" ] && code=$state	
	done
done

text=$(printf "%d of %d pod%s ready." \
        $healthy_cnt $allpods_cnt \
        "$([[ $allpods_cnt -eq 1 ]] && echo ' is' || echo 's are')"
)

if [ "$unready_cnt" -gt 0 ]; then
        text=$(printf "%s %d unready (%s)" \
                "$text" $unready_cnt "$unready_txt"
        )
        code=2
fi

if [ "$unreach_cnt" -gt 0 ]; then
        text=$(printf "%s %d unreachable (%s)" \
                "$text" $unreach_cnt "$unreach_txt"
        )
        [ "$code" -lt 1 ] && code=1
fi

stats=$(printf "allpods=%d;; healthy=%d;; unready=%d;; unreach=%d;;" \
        $allpods_cnt $healthy_cnt $unready_cnt $unreach_cnt
)

nagios $code "$text|$stats"
