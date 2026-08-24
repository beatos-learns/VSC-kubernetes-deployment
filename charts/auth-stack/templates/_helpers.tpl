{{/* Labels for the wrapper chart's own (namespace policy) objects */}}
{{- define "auth-stack.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Selector matching one generic-stack component's pods (chart selectorLabels) */}}
{{- define "auth-stack.componentSelector" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}
