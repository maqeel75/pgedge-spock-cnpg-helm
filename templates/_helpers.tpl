{{/*
Spock cluster environment variables (passwords from secrets)
*/}}
{{- define "pgedge-spock.cluster-env-vars" -}}
{{- range $i, $c := .Values.spock.clusters }}
- name: PGPASSWORD_{{ upper (replace $c.name "-" "_") }}
  valueFrom:
    secretKeyRef:
      name: {{ $c.superuserSecretName }}
      key: {{ $c.superuserSecretKey }}
{{- end }}
{{- end }}

{{/*
Generate HAProxy backend servers list
*/}}
{{- define "pgedge-spock.haproxy-backend-servers" -}}
{{- $clusters := .clusters -}}
{{- $suffix := .suffix -}}
{{- $Release := .Release -}}
{{- range $i, $c := $clusters }}
  server {{ $c.name }} {{ $c.name }}-{{ $suffix }}.{{ $Release.Namespace }}.svc.cluster.local:5432 check
{{- end }}
{{- end }}

