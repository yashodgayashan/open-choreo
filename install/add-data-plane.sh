#!/bin/bash

# OpenChoreo DataPlane Creation Script
# Creates a DataPlane resource in the control plane that uses cluster agent for communication

set -e

# Color codes for errors
RED='\033[0;31m'
RESET='\033[0m'

# Helper function for error output
error() {
  echo -e "${RED}$*${RESET}" >&2
}

# Show help text
show_help() {
  local script_name
  script_name=$(basename "$0")
  cat << EOF
Create an OpenChoreo DataPlane resource that uses cluster agent for communication.

Usage:
  $script_name [OPTIONS]

Options:
  --control-plane-context CONTEXT   Kubernetes context where DataPlane resource will be created
                                    Default: current context

  --name NAME                       Name for the DataPlane resource
                                    Default: default

  --namespace NAMESPACE             Namespace for the DataPlane resource
                                    Default: default

  --dataplane-context CONTEXT       Kubernetes context of data plane to extract cluster agent CA from
                                    Used for auto-extraction mode (default mode)
                                    Default: same as control-plane-context

  --agent-ca-secret NAME            Name of secret in control plane containing the cluster agent CA
                                    If provided, uses secret reference mode instead of auto-extraction
                                    Secret must exist in the control plane

  --agent-ca-namespace NAMESPACE    Namespace of the agent CA secret in control plane
                                    Only used with --agent-ca-secret
                                    Default: same as --namespace

  --agent-ca-key KEY                Key within the secret containing the CA certificate
                                    Only used with --agent-ca-secret
                                    Default: ca.crt

  --ca-cert CA_CERT                 Base64-encoded cluster agent CA certificate for inline value mode
                                    If provided, uses inline value mode
                                    Mutually exclusive with --agent-ca-secret

  --dry-run                         Preview the YAML without applying changes

  --help, -h                        Show this help message

Examples:

  # Auto-extract mode (default) - single cluster
  $script_name

  # Auto-extract mode - multi-cluster
  $script_name --control-plane-context k3d-openchoreo-cp \\
    --dataplane-context k3d-openchoreo-dp \\
    --name default

  # Secret reference mode - reference existing secret in control plane
  $script_name --control-plane-context k3d-openchoreo \\
    --agent-ca-secret dataplane-ca \\
    --agent-ca-namespace openchoreo-control-plane

  # Inline value mode - explicit CA certificate
  $script_name --control-plane-context k3d-openchoreo \\
    --ca-cert "LS0tLS1CRUdJTi..." \\
    --name default

  # Preview without applying
  $script_name --dry-run

Note:
  Three modes for providing cluster agent CA:
  1. Auto-extract (default): Extracts CA from data plane cluster
  2. Secret reference: References existing secret in control plane
  3. Inline value: Provides CA certificate directly
EOF
}

# Defaults
CONTROL_PLANE_CONTEXT=""
DATAPLANE_CONTEXT=""
DATAPLANE_NAME="default"
NAMESPACE="default"
DRY_RUN=false
CA_CERT=""
CA_CERT_EXPLICIT=false
AGENT_CA_SECRET=""
AGENT_CA_NAMESPACE=""
AGENT_CA_KEY="ca.crt"
USE_SECRET_REF=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --ca-cert)
      if [ -z "$2" ] || [[ "$2" == --* ]]; then
        error "Error: --ca-cert requires a value"
        exit 1
      fi
      CA_CERT="$2"
      CA_CERT_EXPLICIT=true
      shift 2
      ;;
    --agent-ca-secret)
      if [ -z "$2" ] || [[ "$2" == --* ]]; then
        error "Error: --agent-ca-secret requires a value"
        exit 1
      fi
      AGENT_CA_SECRET="$2"
      USE_SECRET_REF=true
      shift 2
      ;;
    --agent-ca-namespace)
      if [ -z "$2" ] || [[ "$2" == --* ]]; then
        error "Error: --agent-ca-namespace requires a value"
        exit 1
      fi
      AGENT_CA_NAMESPACE="$2"
      shift 2
      ;;
    --agent-ca-key)
      if [ -z "$2" ] || [[ "$2" == --* ]]; then
        error "Error: --agent-ca-key requires a value"
        exit 1
      fi
      AGENT_CA_KEY="$2"
      shift 2
      ;;
    --dataplane-context)
      if [ -z "$2" ] || [[ "$2" == --* ]]; then
        error "Error: --dataplane-context requires a value"
        exit 1
      fi
      DATAPLANE_CONTEXT="$2"
      shift 2
      ;;
    --control-plane-context)
      if [ -z "$2" ] || [[ "$2" == --* ]]; then
        error "Error: --control-plane-context requires a value"
        exit 1
      fi
      CONTROL_PLANE_CONTEXT="$2"
      shift 2
      ;;
    --name)
      if [ -z "$2" ] || [[ "$2" == --* ]]; then
        error "Error: --name requires a value"
        exit 1
      fi
      DATAPLANE_NAME="$2"
      shift 2
      ;;
    --namespace)
      if [ -z "$2" ] || [[ "$2" == --* ]]; then
        error "Error: --namespace requires a value"
        exit 1
      fi
      NAMESPACE="$2"
      shift 2
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

# Validate mutually exclusive options
if [ "$CA_CERT_EXPLICIT" = true ] && [ "$USE_SECRET_REF" = true ]; then
  error "Error: --ca-cert and --agent-ca-secret are mutually exclusive"
  exit 1
fi

# Set control plane context to current if not specified
if [ -z "$CONTROL_PLANE_CONTEXT" ]; then
  CONTROL_PLANE_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
  if [ -z "$CONTROL_PLANE_CONTEXT" ]; then
    error "Error: No current context set and --control-plane-context not specified"
    exit 1
  fi
  echo "Using current context as control plane: $CONTROL_PLANE_CONTEXT"
fi

# Verify control plane context exists
if ! kubectl config get-contexts "$CONTROL_PLANE_CONTEXT" &> /dev/null; then
  error "Error: Control plane context '$CONTROL_PLANE_CONTEXT' not found"
  exit 1
fi

# Build the CA cert configuration section based on mode
CA_CERT_CONFIG=""

if [ "$USE_SECRET_REF" = true ]; then
  # Secret reference mode
  echo "Using secret reference mode: secret=$AGENT_CA_SECRET"

  # Set default namespace if not provided
  if [ -z "$AGENT_CA_NAMESPACE" ]; then
    AGENT_CA_NAMESPACE="$NAMESPACE"
  fi

  # Verify secret exists in control plane
  if ! kubectl --context="$CONTROL_PLANE_CONTEXT" get secret "$AGENT_CA_SECRET" -n "$AGENT_CA_NAMESPACE" &> /dev/null; then
    error "Error: Secret '$AGENT_CA_SECRET' not found in namespace '$AGENT_CA_NAMESPACE' in control plane"
    echo ""
    echo "Please ensure the secret exists:"
    echo "  kubectl --context=$CONTROL_PLANE_CONTEXT get secret $AGENT_CA_SECRET -n $AGENT_CA_NAMESPACE"
    exit 1
  fi

  CA_CERT_CONFIG="    caCert:
      secretRef:
        name: $AGENT_CA_SECRET
        namespace: $AGENT_CA_NAMESPACE
        key: $AGENT_CA_KEY"

elif [ "$CA_CERT_EXPLICIT" = true ]; then
  # Inline value mode with explicit CA cert
  echo "Using inline value mode with explicit CA certificate"

  # Validate provided CA cert is base64 encoded
  if ! echo "$CA_CERT" | base64 -d &> /dev/null; then
    error "Error: Provided --ca-cert is not valid base64"
    exit 1
  fi
  CLIENT_CA_CERT=$(echo "$CA_CERT" | base64 -d)

  CA_CERT_CONFIG="    caCert:
      value: |
$(echo "$CLIENT_CA_CERT" | sed 's/^/        /')"

else
  # Auto-extract mode (default)
  # Set dataplane context to control plane context if not specified
  if [ -z "$DATAPLANE_CONTEXT" ]; then
    DATAPLANE_CONTEXT="$CONTROL_PLANE_CONTEXT"
  fi

  # Verify dataplane context exists
  if ! kubectl config get-contexts "$DATAPLANE_CONTEXT" &> /dev/null; then
    error "Error: Data plane context '$DATAPLANE_CONTEXT' not found"
    exit 1
  fi

  echo "Auto-extracting cluster agent CA certificate from data plane context: $DATAPLANE_CONTEXT"

  # Try to extract CA from cluster-agent-tls secret in openchoreo-data-plane namespace
  CLIENT_CA_CERT=$(kubectl --context="$DATAPLANE_CONTEXT" get secret cluster-agent-tls \
    -n openchoreo-data-plane \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

  if [ -z "$CLIENT_CA_CERT" ]; then
    error "Error: Failed to extract cluster agent CA certificate from data plane"
    echo ""
    echo "Please ensure:"
    echo "  1. The data plane cluster is accessible via context: $DATAPLANE_CONTEXT"
    echo "  2. The openchoreo-data-plane namespace exists"
    echo "  3. The cluster-agent-tls secret exists and contains ca.crt"
    echo ""
    echo "You can check the status with:"
    echo "  kubectl --context=$DATAPLANE_CONTEXT get secret cluster-agent-tls -n openchoreo-data-plane"
    echo ""
    echo "Alternatively, use --ca-cert or --agent-ca-secret to provide the CA certificate"
    exit 1
  fi

  CA_CERT_CONFIG="    caCert:
      value: |
$(echo "$CLIENT_CA_CERT" | sed 's/^/        /')"
fi

# Generate the DataPlane YAML with cluster agent configuration
DATAPLANE_YAML=$(cat <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: DataPlane
metadata:
  name: $DATAPLANE_NAME
  namespace: $NAMESPACE
  annotations:
    openchoreo.dev/description: "DataPlane created via $(basename $0) script"
    openchoreo.dev/display-name: "DataPlane $DATAPLANE_NAME"
spec:
  clusterAgent:
$CA_CERT_CONFIG
  secretStoreRef:
    name: default
  gateway:
    organizationVirtualHost: openchoreoapis.internal
    publicVirtualHost: openchoreoapis.localhost
EOF
)

# Apply or preview the manifest
if [ "$DRY_RUN" = true ]; then
  echo "$DATAPLANE_YAML"
  exit 0
else
  if echo "$DATAPLANE_YAML" | kubectl --context="$CONTROL_PLANE_CONTEXT" apply -f - ; then
    echo ""
    echo "DataPlane '$DATAPLANE_NAME' created successfully in namespace '$NAMESPACE'"
    echo ""
    echo "Next steps:"
    echo "  1. Ensure the cluster agent is deployed and running in the data plane"
    echo "  2. Verify the agent connects to the cluster gateway in the control plane"
    echo "  3. Check the DataPlane status:"
    echo "     kubectl --context=$CONTROL_PLANE_CONTEXT get dataplane $DATAPLANE_NAME -n $NAMESPACE"
  else
    error "Failed to create DataPlane resource"
    exit 1
  fi
fi
