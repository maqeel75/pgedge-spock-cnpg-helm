{{- define "pgedge-spock.cluster-env-vars" -}}
{{- range $i, $c := .Values.spock.clusters }}
- name: PGPASSWORD_{{ upper (replace $c.name "-" "_") }}
  valueFrom:
    secretKeyRef:
      name: {{ $c.superuserSecretName }}
      key: {{ $c.superuserSecretKey }}
{{- end }}
{{- end }}

