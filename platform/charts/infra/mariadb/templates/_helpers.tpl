{{/*
Shared template helpers for mariadb. Same convention as the application charts so that
labels, selectors and naming stay consistent across the whole deployment.
*/}}

{{- define "mariadb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mariadb.fullname" -}}
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

{{- define "mariadb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mariadb.labels" -}}
helm.sh/chart: {{ include "mariadb.chart" . }}
{{ include "mariadb.selectorLabels" . }}
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
{{- define "mariadb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mariadb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .Values.component }}
{{- end -}}

{{/* Headless service name used for the StatefulSet's stable identity. */}}
{{- define "mariadb.headless" -}}
{{- printf "%s-headless" (include "mariadb.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
