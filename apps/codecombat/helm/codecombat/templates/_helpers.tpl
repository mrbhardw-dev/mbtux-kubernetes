{{/*
Expand the name of the chart.
*/}}
{{- define "codecombat.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "codecombat.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "codecombat.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "codecombat.labels" -}}
helm.sh/chart: {{ include "codecombat.chart" . }}
{{ include "codecombat.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "codecombat.selectorLabels" -}}
app.kubernetes.io/name: {{ include "codecombat.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
CodeCombat app labels
*/}}
{{- define "codecombat.appLabels" -}}
{{ include "codecombat.labels" . }}
app.kubernetes.io/component: application
{{- end }}

{{/*
CodeCombat app selector labels
*/}}
{{- define "codecombat.appSelectorLabels" -}}
{{ include "codecombat.selectorLabels" . }}
app.kubernetes.io/component: application
{{- end }}

{{/*
MongoDB labels
*/}}
{{- define "codecombat.mongodbLabels" -}}
{{ include "codecombat.labels" . }}
app.kubernetes.io/component: database
{{- end }}

{{/*
MongoDB selector labels
*/}}
{{- define "codecombat.mongodbSelectorLabels" -}}
{{ include "codecombat.selectorLabels" . }}
app.kubernetes.io/component: database
{{- end }}

{{/*
MongoDB connection URL
*/}}
{{- define "codecombat.mongodbUrl" -}}
{{- if .Values.mongodb.enabled -}}
{{- if .Values.mongodb.auth.enabled -}}
mongodb://{{ .Values.mongodb.auth.rootUser }}:{{ .Values.mongodb.auth.rootPassword }}@mongodb:{{ .Values.mongodb.service.port }}/{{ .Values.mongodb.auth.database }}?authSource=admin
{{- else -}}
mongodb://mongodb:{{ .Values.mongodb.service.port }}/{{ .Values.mongodb.auth.database }}
{{- end -}}
{{- else -}}
{{- if .Values.externalMongoDB.username -}}
mongodb://{{ .Values.externalMongoDB.username }}:{{ .Values.externalMongoDB.password }}@{{ .Values.externalMongoDB.host }}:{{ .Values.externalMongoDB.port }}/{{ .Values.externalMongoDB.database }}
{{- else -}}
mongodb://{{ .Values.externalMongoDB.host }}:{{ .Values.externalMongoDB.port }}/{{ .Values.externalMongoDB.database }}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Namespace
*/}}
{{- define "codecombat.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride }}
{{- end }}
