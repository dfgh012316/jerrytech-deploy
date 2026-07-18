{{- define "actions-runner.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "actions-runner.labels" -}}
app.kubernetes.io/name: {{ include "actions-runner.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "actions-runner.selectorLabels" -}}
app.kubernetes.io/name: {{ include "actions-runner.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "actions-runner.serviceAccountName" -}}
{{- default (include "actions-runner.name" .) .Values.serviceAccount.name -}}
{{- end -}}
