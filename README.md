## How to install:

```bash
cd pgedge-spock-cnpg-helm
helm install my-spock ./ -n cnpg-system --create-namespace

## To verify connect with any cluster primary pod and run sql commands:
export PGPASSWORD=$(kubectl get secret cluster-b-superuser -n cnpg-system -o jsonpath='{.data.password}' | base64 -d)
psql -h cluster-b-rw.cnpg-system.svc.cluster.local -U postgres -d appdb

## To upgrade:
helm upgrade my-spock ./ -n cnpg-system --create-namespace

## You can access via haproxy.
export PGPASSWORD=<Password mentioned in values.yaml for superuser>
psql -h haproxy.cnpg-system.svc.cluster.local -U postgres -d appdb -c "SELECT * from test_table;"

## To get monitoring on Grafana
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace

## Check installation
kubectl get pods -n monitoring

## Get Grafana admin password
kubectl -n monitoring get secret kube-prometheus-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d ; echo

## Port forward Grafana service
kubectl -n monitoring port-forward svc/kube-prometheus-grafana 3000:80

## Port forward Prometheus
kubectl -n monitoring port-forward svc/kube-prometheus-kube-prome-prometheus 9090:9090

## Now open in browser:
http://localhost:3000


Provide user name and password
You can see CNPG Overview dashboard
