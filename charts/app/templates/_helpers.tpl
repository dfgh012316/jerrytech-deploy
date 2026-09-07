{{/*
Expand the name of the chart.
*/}}
{{- define "helm-chart.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "helm-chart.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "helm-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "helm-chart.labels" -}}
helm.sh/chart: {{ include "helm-chart.chart" . }}
{{ include "helm-chart.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "helm-chart.selectorLabels" -}}
app: {{ .Release.Name }}
{{- end }}

{{/*
Container image reference. repository / tag presence is enforced by values.schema.json.
*/}}
{{- define "helm-chart.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end }}

{{/*
Env vars injected into every workload (Deployment + CronJob).
APP_VERSION / ENV come first; entries in .Values.env override them by name.
*/}}
{{- define "helm-chart.env" -}}
{{- $base := list (dict "name" "APP_VERSION" "value" .Values.image.tag) (dict "name" "ENV" "value" .Values.environment) }}
{{- toYaml (concat $base .Values.env) }}
{{- end }}

{{/*
envFrom sources shared by every workload: the cluster-wide common ConfigMap,
the release ConfigMap, the release Secret, then any extra .Values.envFrom.
*/}}
{{- define "helm-chart.envFrom" -}}
{{- $refs := list }}
{{- with .Values.commonConfigMapName }}{{- $refs = append $refs (dict "configMapRef" (dict "name" .)) }}{{- end }}
{{- if .Values.configMap.enabled }}{{- $refs = append $refs (dict "configMapRef" (dict "name" (include "helm-chart.fullname" .))) }}{{- end }}
{{- if .Values.secret.enabled }}{{- $refs = append $refs (dict "secretRef" (dict "name" (include "helm-chart.fullname" .))) }}{{- end }}
{{- toYaml (concat $refs .Values.envFrom) }}
{{- end }}
