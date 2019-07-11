# kubernetes-nagios

Some checks for Kubernetes clusters, which can be use with Nagios, Zabbix, Icinga, or any other
monitoring system that can be configured to use an external shell script.

Too much remaining from colebrooke's work to really be its own thing, too much changed to really be the same.

Rrefactored to:

  - give simplified single line output for checks
  - provide some basic stats output for checks
  - use token authentication for k8s API
  - remove option to use kubectl instead
  - seperate plugin for single node check

Just because that suited my needs better.

### nagios-rbac.yaml

A kubernetes manifest to create a service account and associated role for use with these plugins.

Apply the manifest:
```
kubectl apply -f ./nagios-rbac.yaml
```

Extract the created token:
```
kubectl get secret  -o 'jsonpath={.data.token}' -n kube-system $(kubectl get secret -n kube-system | awk '/^nagios/{print $1}') | base64 --decode; echo
```

### nagios

Some example nagios configurations making use of the plugins to check a kubernetes cluster.

# check scripts

### check_kube_cluster.sh

Check the overall health of the cluster and its nodes.  Returns summary of states in stats.

#### Usage
```
./check_k8s_cluster.sh [-t token] [-c curlcmd ] [-a apiurl]
```

#### Options
```
   -t <token>        # barer toekn for api authorization
   -c <curlcmd>      # override the default curl command line
   -a <apiurl>       # the endpoint for the kubernetes api
```

#### Example Output
```
$ ./check_k8s_cluster.sh -t "$TOKEN" -a "$APIURL"
OK - 9 of 9 nodes are healthy.|allnode=9;; healthy=9;; unreach=0;; unready=0;; starved=0;; unknown=0
$
```
```
$ ./check_k8s_cluster.sh -t "$TOKEN" -a "$APIURL"
CRITICAL - 8 of 9 nodes are healthy. 1 unreachable (kube-worker001)|allnode=9;; healthy=8;; unreach=1;; unready=0;; starved=0;; unknown=0
$
```

### check_k8s_node.sh

Check the healthy of individual nodes.  Returns node resource details in stats.

#### Usage
```
check_k8s_node.sh [-t token] [-c curlcmd ] [-a apiurl] <nodename>
```

#### Options
```
   -t <token>        # barer toekn for api authorization
   -c <curlcmd>      # override the default curl command line
   -a <apiurl>       # the endpoint for the kubernetes api
   <nodename>        # the kubernetes node to query details for
```

#### Example Output
```
$ ./check_k8s_node.sh -t "$TOKEN" -a "$APIURL" kube-worker001
OK - 4 of 4 conditions are healthy.| cpu=2;; ephemeral-storage=4693288543;; hugepages-2Mi=0;; memory=1938636Ki;; pods=110;;
$
```
```
$ ./check_k8s_node.sh -t "$TOKEN" -a "$APIURL" kube-worker001
CRITICAL - Node is unreachable.
$
```

### check_k8s_deploys.sh

Checks the health of deployents.  Can be optionally restricted to a given namespace.

#### Usage
```
./check_k8s_deploys.sh [-t token] [-c curlcmd ] [-a apiurl] [-n namespace]
```
#### Options
```
   -t <token>        # barer toekn for api authorization
   -c <curlcmd>      # override the default curl command line
   -a <apiurl>       # the endpoint for the kubernetes api
   -n <namespace>    # the kubernetes namespace to check
```

#### Example Output
```
$ ./check_k8s_deploys.sh -t "$TOKEN" -a "$APIURL"
OK - 5 of 5 deployments are healthy.;; healthy=5;; unhealthy=0;;
$
```
```
$ ./check_k8s_deploys.sh -t "$TOKEN" -a "$APIURL"
CRITICAL - 4 of 5 deployments are healthy. 1 unhealthy (metallb-system/controller)|alldeploys=5;; healthy=4;; unhealthy=1;;
$
```

### check_k8s_pods.sh

Checks the health of pods.  Can be optionally restricted to a given namespace and / or pod name regex.

#### Usage
```
check_k8s_pods.sh [-t token] [-c curlcmd ] [-a apiurl] [-n namespace] [-p podname]A
```

#### Options
```
   -t <token>        # barer toekn for api authorization
   -c <curlcmd>      # override the default curl command line
   -a <apiurl>       # the endpoint for the kubernetes api
   -n <namespace>    # the kubernetes namespace to check
   -p <podname>      # search string for pod names to check
```

#### Example Output
```
$ ./check_k8s_pods.sh -t "$TOKEN" -a "$APIURL"
CRITICAL - 44 of 44 pods are ready.|allpods=44;; healthy=44;; unready=0;; unreach=0;;

```
```
$ ./check_k8s_pods.sh -t "$TOKEN" -a "$APIURL"
CRITICAL - 43 of 44 pods are ready. 1 unready (controller-cd8657667-t26np)|allpods=44;; healthy=43;; unready=1;; unreach=0;;
$
```
```
$ ./check_k8s_pods.sh -t "$TOKEN" -a "$APIURL"
WARNING - 40 of 44 pods are ready. 4 unreachable (kube-proxy-bqz98,weave-net-6md9g,controller-cd8657667-t26np,speaker-2k8t2)|allpods=44;; healthy=40;; unready=0;; unreach=4;;
$
```
```
$ ./check_k8s_pods.sh -t "$TOKEN" -a "$APIURL" -p nginx
OK - 1 of 1 pod is ready.|allpods=1;; healthy=1;; unready=0;; unreach=0;;
$
```

### check_k8s_api.sh

Checks the basic health of the API.  Useful as a dependency for the other checks.

#### Usage
```
Usage: check_k8s_api.sh [-t token] [-c curlcmd ] [-a apiurl]

```

#### Options
```
   -t <token>        # barer toekn for api authorization
   -c <curlcmd>      # override the default curl command line
   -a <apiurl>       # the endpoint for the kubernetes api
```

#### Example Output
```
$ ./check_k8s_api.sh -t "$TOKEN" -a "$APIURL"
OK - api returned ok status
$
```
```
$ ./check_k8s_api.sh -t "$TOKEN" -a "$APIURL"
api returned not ok: [-]etcd failed: reason withheld healthz check failed
$
```

### Dependancies

These scripts call the Kubernetes API, so this must be exposed to the machine running the script.

The jq utility for parsing json is required.

