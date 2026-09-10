{{/* Labels for the wrapper chart's own (dashboard) objects */}}
{{- define "monitoring.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: kube-prometheus-stack
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
