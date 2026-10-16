{{/*
Shared template helpers for the cart chart.

Why these exist: every object needs a consistent name, a consistent label set and a
consistent selector. Repeating that logic in each template is how labels drift and
selectors stop matching, which produces objects that silently belong to no Service.
*/}}

{{/* Base name, overridable so two releases can coexist in one namespace. */}}
{{- define "cart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified name, conventionally <release>-<chart>. */}}
{{- define "cart.fullname" -}}
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

{{- define "cart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels. These follow the Kubernetes recommended label set so that tooling
(kubectl, Prometheus relabeling, Grafana dashboards) can select objects without
knowing anything project-specific.

app.kubernetes.io/component is the important one here: the NetworkPolicies select
pods by it. Changing the value in a values file without updating the policies would
silently break connectivity, so it is set from the chart name rather than free text.
*/}}
{{- define "cart.labels" -}}
helm.sh/chart: {{ include "cart.chart" . }}
{{ include "cart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: polyglot-shop
{{- end -}}

{{/* Selector labels. These must never change: a Deployment's selector is immutable. */}}
{{- define "cart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: cart
{{- end -}}

{{/*
Resolve the image reference.

Why this is a helper and not inline: the precedence rule (digest beats tag) has to
be identical in every chart or one service ends up deployed differently from the
others. A digest is preferred where supplied because a tag can be moved after the
fact, which makes a deployment unreproducible.
*/}}
{{- define "cart.image" -}}
{{- $repo := .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo .Values.image.tag -}}
{{- end -}}
{{- end -}}
