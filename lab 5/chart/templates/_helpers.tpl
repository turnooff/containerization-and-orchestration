{{- define "shop.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "shop.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "shop.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "shop.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "shop.selectorLabels" -}}
app.kubernetes.io/name: {{ include "shop.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "shop.podLabels" -}}
{{ include "shop.labels" . }}
owner: {{ .Values.owner | quote }}
env: {{ .Values.env | quote }}
{{- end -}}

{{- define "shop.api.selectorLabels" -}}
{{ include "shop.selectorLabels" . }}
app.kubernetes.io/component: api
{{- end -}}

{{- define "shop.api.podLabels" -}}
{{ include "shop.podLabels" . }}
app.kubernetes.io/component: api
{{- end -}}

{{- define "shop.worker.selectorLabels" -}}
{{ include "shop.selectorLabels" . }}
app.kubernetes.io/component: worker
{{- end -}}

{{- define "shop.worker.podLabels" -}}
{{ include "shop.podLabels" . }}
app.kubernetes.io/component: worker
{{- end -}}