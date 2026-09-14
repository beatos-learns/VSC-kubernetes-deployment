{{/* Labels for every policy of this chart */}}
{{- define "policies.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
  Preconditions that skip cert-manager's HTTP-01 solver pods, and only those:
  the rule still applies unless the pod carries the solver label AND runs
  nothing but the solver image. Autogen rewrites request.object.metadata and
  .spec to the pod template for controllers.
*/}}
{{- define "policies.notAcmeSolver" -}}
any:
  - key: >-
      {{ "{{" }} request.object.metadata.labels."acme.cert-manager.io/http01-solver" || '' {{ "}}" }}
    operator: NotEquals
    value: "true"
  - key: "{{ "{{" }} request.object.spec.containers[].image {{ "}}" }}"
    operator: AnyNotIn
    value:
      - {{ printf "%s:*" .Values.images.acmeSolver | quote }}
{{- end -}}
