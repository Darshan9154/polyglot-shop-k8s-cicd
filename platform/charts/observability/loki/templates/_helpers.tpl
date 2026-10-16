{{/*
Shared template helpers for the Loki chart. Same naming convention as the rest of the
deployment so selectors and dashboards stay consistent.

Why the component label is "loki": Grafana's data source and the NetworkPolicies refer to
it, so the value is part of the contract between components.
*/}}

{{- define "loki.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "loki.fullname" -}}
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

{{- define "loki.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "loki.labels" -}}
helm.sh/chart: {{ include "loki.chart" . }}
{{ include "loki.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: polyglot-shop
{{- end -}}

{{- define "loki.selectorLabels" -}}
app.kubernetes.io/name: {{ include "loki.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: loki
{{- end -}}
