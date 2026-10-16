{{/*
Shared template helpers for the Jaeger chart. Same convention as the other charts so
selectors and dashboards stay consistent.

Why the component label is "jaeger": the OpenTelemetry Collector's NetworkPolicy selects
its egress peer by this exact value. Changing it here without changing that policy would
silently cut traces off.
*/}}

{{- define "jaeger.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "jaeger.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $n := default .Chart.Name .Values.nameOverride -}}
{{- if contains $n .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $n | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "jaeger.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "jaeger.labels" -}}
helm.sh/chart: {{ include "jaeger.chart" . }}
{{ include "jaeger.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: polyglot-shop
{{- end -}}

{{- define "jaeger.selectorLabels" -}}
app.kubernetes.io/name: {{ include "jaeger.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: jaeger
{{- end -}}
