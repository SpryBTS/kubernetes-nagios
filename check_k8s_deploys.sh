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

alldeploy_cnt=0
nobadcond_cnt=0
baddeploy_cnt=0

baddeploy_txt=""

text=""
code=0

for name in $names; do
	query=$(eval $CURLCMD "$APIURL/apis/extensions/v1beta1/namespaces/$name/deployments/")

        if [ -z "$query" ]; then
                nagios 2 "Unable to query $name for deployments: $APIURL"
        fi
        
        if ! echo $query | jq . >/dev/null 2>&1; then
                nagios 2 "Unable to parse deployments in $name as json"
        fi
        
        if [ "$(echo $query | jq -r .kind)" = "Status" ]; then
                nagios 2 "Error quering api for deployments in $name: "$(errortxt "$query")
        fi

        deploys=$(echo $query | jq -r '.items[].metadata.name')
        
        if [ -z "$deploys" ]; then
		if [ -n "$NAMESPC" ]; then
	                nagios 3 "No deployments in $name returned in api query"
		else
			continue
		fi
        fi

	for deploy in $deploys; do
		alldeploy_cnt=$((alldeploy_cnt+1))
		badconds=$(echo $query | jq '.items[] 
				| select(.metadata.name=="'$deploy'")
				| .status.conditions[] 
				| select(.status != "True") | .type')
		if [ -z "$badconds" ]; then
			nobadcond_cnt=$(($nobadcond_cnt+1))
		else
			baddeploy_cnt=$((baddeploy_cnt+1))
			if [ -n "$NAMESPC" ]; then
				baddeploy_txt=$(printf "%s%s" "${baddeploy_txt:+$baddeploy_txt,}" "$deploy")
			else
				baddeploy_txt=$(printf "%s%s" "${baddeploy_txt:+$baddeploy_txt,}" "$name/$deploy")
			fi
		fi
	done
done

text=$(printf "%d of %d deployment%s healthy." \
        $nobadcond_cnt $alldeploy_cnt \
        "$([[ $allnode_cnt -eq 1 ]] && echo ' is' || echo 's are')"
)

if [ "$baddeploy_cnt" -gt 0 ]; then
        text=$(printf "%s %s unhealthy (%s)" \
                "$text" $baddeploy_cnt "$baddeploy_txt"
        )
        code=2	
fi

stats=$(printf "alldeploys=%d;; healthy=%d;; unhealthy=%d;;" \
        $alldeploy_cnt $nobadcond_cnt $baddeploy_cnt
)

nagios $code "$text|$stats"
