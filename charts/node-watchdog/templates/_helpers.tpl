{{/*
Common labels applied to all resources.
*/}}
{{- define "node-watchdog.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Renders a fully-qualified image reference. Prefers digest pinning over tag when
a digest is set, producing "repository@sha256:..." instead of "repository:tag".
Usage: {{ include "node-watchdog.image" .Values.image.kubectl }}
*/}}
{{- define "node-watchdog.image" -}}
{{- if .digest -}}
{{ .repository }}@{{ .digest }}
{{- else -}}
{{ .repository }}:{{ .tag }}
{{- end -}}
{{- end }}
