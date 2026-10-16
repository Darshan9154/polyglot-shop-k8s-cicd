{{/*
Shared template helpers for the checkout chart. Identical in structure to the cart
chart deliberately: one helper convention across the charts means a label change is
made in one shape everywhere, and the NetworkPolicies can rely on
app.kubernetes.io/component being set consistently.
*/}}

{{- define "checkout.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "checkout.fullname" -}}
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

{{- define "checkout.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "checkout.labels" -}}
helm.sh/chart: {{ include "checkout.chart" . }}
{{ include "checkout.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: polyglot-shop
{{- end -}}

{{/* Selector labels are immutable on a Deployment, so they must never change. */}}
{{- define "checkout.selectorLabels" -}}
app.kubernetes.io/name: {{ include "checkout.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: checkout
{{- end -}}

{{/* Prefer a digest over a tag: a tag can be moved after deployment. */}}
{{- define "checkout.image" -}}
{{- $repo := .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{/*
Emit the literal open- and close-brace pair used by Go templating.

Why this helper exists: the generator that writes this chart is itself a Python
f-string, where a literal brace must be doubled. Nesting an expression inside
another expression - as in a conditional wrapping a pipeline - needs four levels of
escaping and produced a broken template. Defining the delimiters once here means the
rest of the templates can use plain {{ ... }} syntax with no nesting at all.
*/}}
{{- define "checkout.braceopen" -}}{{ "{" }}{{ end -}}
{{- define "checkout.braceclose" -}}{{ "}" }}{{ end -}}
