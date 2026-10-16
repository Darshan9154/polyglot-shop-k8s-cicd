{{/*
Shared template helpers for the OpenTelemetry Collector chart.

Same naming and labelling convention as the application and infrastructure charts, so
one set of selectors and dashboards works across the whole deployment.
*/}}

{{- define "otel.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "otel.fullname" -}}
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

{{- define "otel.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "otel.labels" -}}
helm.sh/chart: {{ include "otel.chart" . }}
{{ include "otel.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: polyglot-shop
{{- end -}}

{{- define "otel.selectorLabels" -}}
app.kubernetes.io/name: {{ include "otel.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: otel-collector
{{- end -}}
