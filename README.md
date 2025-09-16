## How to install:

```bash
cd pgedge-spock-cnpg-helm
helm install my-spock ./ -n cnpg-system --create-namespace

## To verify connect with any cluster primary pod and run sql commands:

```bash

export PGPASSWORD=$(kubectl get secret cluster-b-superuser -n cnpg-system -o jsonpath='{.data.password}' | base64 -d)
psql -h cluster-b-rw.cnpg-system.svc.cluster.local -U postgres -d appdb

## To upgrade:

```bash
helm upgrade my-spock ./ -n cnpg-system --create-namespace
