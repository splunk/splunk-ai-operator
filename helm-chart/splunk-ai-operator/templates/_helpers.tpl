{{/*
Expand the name of the chart.
*/}}
{{- define "splunk-ai-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride -}}
{{- end -}}

{{/* 
Create standard operator fullname for uniform installation across Helm and manifest
*/}}
{{- define "splunk-ai-operator.fullname" -}}
{{- default "splunk-ai-operator" .Values.nameOverride }}
{{- end }}

{{/*
Create the name of the service account to use for splunk operator
*/}}
{{- define "splunk-ai-operator.serviceAccountName" -}}
{{- printf "%s-%s"  (include "splunk-ai-operator.fullname" .) "controller-manager" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "splunk-ai-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "splunk-ai-operator.labels" -}}
helm.sh/chart: {{ include "splunk-ai-operator.chart" . }}
{{ include "splunk-ai-operator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "splunk-ai-operator.selectorLabels" -}}
control-plane: controller-manager
app.kubernetes.io/name: {{ include "splunk-ai-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Define namespace of release and allow for namespace override
*/}}
{{- define "splunk-ai-operator.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride }}
{{- end }}

{{/* Deployment and pre-upgrade validation use the same candidate image. */}}
{{- define "splunk-ai-operator.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion | default "latest" | toString) -}}
{{- end -}}
{{- end }}
