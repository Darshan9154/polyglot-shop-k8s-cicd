{{/*
Shared template helpers for redis. Same convention as the application charts so that
labels, selectors and naming stay consistent across the whole deployment.
*/}}

{{- define "redis.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis.fullname" -}}
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

{{- define "redis.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis.labels" -}}
helm.sh/chart: {{ include "redis.chart" . }}
{{ include "redis.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: polyglot-shop
{{- end -}}

{{/*
Selector labels.

app.kubernetes.io/component uses the component value rather than the chart name on
purpose: the application NetworkPolicies select on this exact value, so it is the
contract between the application and its dependency.
*/}}
{{- define "redis.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .Values.component }}
{{- end -}}

{{/* Headless service name used for the StatefulSet's stable identity. */}}
{{- define "redis.headless" -}}
{{- printf "%s-headless" (include "redis.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
