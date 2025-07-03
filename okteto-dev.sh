#!/bin/bash

# Okteto Development Environment Wrapper
set -e

# Configuration - can be overridden by environment variables
CLOWDAPP_NAME="${CLOWDAPP_NAME:-host-inventory}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[okteto-dev]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[okteto-dev]${NC} $1" >&2; }
error() { echo -e "${RED}[okteto-dev]${NC} $1" >&2; }

# Function to extract services from okteto.template.yaml
get_default_services() {
    if [[ ! -f "okteto/okteto.template.yaml" ]]; then
        error "okteto.template.yaml not found in okteto/ directory"
        error "This file is required to determine available services"
        exit 1
    fi
    
    # Extract service names from the dev: section
    # Use awk to extract everything from 'dev:' until the next top-level YAML key
    awk '
        /^dev:/ { in_dev=1; next }
        /^[a-zA-Z].*:/ { in_dev=0 }
        in_dev && /^  [a-zA-Z]/ && !/^  #/ { 
            gsub(/^  /, ""); 
            gsub(/:.*/, ""); 
            print 
        }
    ' okteto/okteto.template.yaml
}

# Load default services dynamically (compatible with older bash)
DEFAULT_SERVICES=()
while IFS= read -r service; do
    [[ -n "$service" ]] && DEFAULT_SERVICES+=("$service")
done < <(get_default_services)

# ClowdApp management functions
check_clowdapp_status() {
    local status
    status=$(oc get ClowdApp "$CLOWDAPP_NAME" -o jsonpath='{.spec.disabled}' 2>/dev/null)
    echo "${status:-false}"
}

disable_clowdapp() {
    log "Disabling ClowdApp reconciliation to allow Okteto deployment scaling..."
    if oc patch ClowdApp "$CLOWDAPP_NAME" --type=merge -p '{"spec":{"disabled": true}}' >/dev/null 2>&1; then
        log "✅ ClowdApp reconciliation disabled"
        return 0
    else
        warn "⚠️  Failed to disable ClowdApp - continuing anyway"
        return 1
    fi
}

enable_clowdapp() {
    log "Re-enabling ClowdApp reconciliation..."
    if oc patch ClowdApp "$CLOWDAPP_NAME" --type=merge -p '{"spec":{"disabled": false}}' >/dev/null 2>&1; then
        log "✅ ClowdApp reconciliation re-enabled"
        return 0
    else
        warn "⚠️  Failed to re-enable ClowdApp - you may need to manually run:"
        warn "    oc patch ClowdApp $CLOWDAPP_NAME --type=merge -p '{\"spec\":{\"disabled\": false}}'"
        return 1
    fi
}

# Check if development containers are active
check_dev_status() {
    local services=("${@:-${DEFAULT_SERVICES[@]}}")
    local active=() inactive=()
    
    for service in "${services[@]}"; do
        if oc get deployment "$service" >/dev/null 2>&1 && oc get deployment "${service}-okteto" >/dev/null 2>&1; then
            active+=("$service")
        elif oc get deployment "$service" >/dev/null 2>&1; then
            inactive+=("$service")
        fi
    done
    
    echo "${active[@]}|${inactive[@]}"
}

# Show development status
show_status() {
    local services=("${@:-${DEFAULT_SERVICES[@]}}")
    log "Current development status:"
    log "Repo path: ${INSIGHTS_HOST_INVENTORY_REPO_PATH:-"<NOT SET>"}"
    
    # Show ClowdApp status
    local clowdapp_disabled=$(check_clowdapp_status)
    if [[ "$clowdapp_disabled" == "true" ]]; then
        log "ClowdApp: 🔒 disabled (development mode)"
    else
        log "ClowdApp: 🔄 enabled (deployed mode)"
    fi
    
    local active_count=0 total_count=0
    for service in "${services[@]}"; do
        if ! oc get deployment "$service" >/dev/null 2>&1; then
            echo "  ❌ $service (not found)" >&2
            continue
        fi
        total_count=$((total_count + 1))
        if oc get deployment "${service}-okteto" >/dev/null 2>&1; then
            echo "  🚀 $service (development)" >&2
            active_count=$((active_count + 1))
        else
            echo "  📦 $service (deployed)" >&2
        fi
    done
    
    echo "" >&2
    if [[ $active_count -eq 0 ]]; then
        echo "  All services in deployed mode" >&2
    elif [[ $active_count -eq $total_count ]]; then
        echo "  All services in development mode" >&2
    else
        echo "  Mixed mode ($active_count/$total_count in development)" >&2
    fi
}

# Main okteto commands
okteto_up() {
    # Accept zero or one service argument only
    local service="$1"
    
    if [[ -n "$service" ]]; then
        # Validate the service exists in our list
        if [[ ! " ${DEFAULT_SERVICES[*]} " =~ " ${service} " ]]; then
            error "Invalid service: $service"
            error "Available services: ${DEFAULT_SERVICES[*]}"
            exit 1
        fi
        
        log "Starting development for service: $service"
        
        # Check if this specific service is already active
        if oc get deployment "${service}-okteto" >/dev/null 2>&1; then
            log "Service $service already in development mode (idempotent)"
            return 0
        fi
    else
        log "Starting okteto (interactive service selection)"
    fi
    
    # Disable ClowdApp reconciliation before starting development
    local clowdapp_was_disabled=$(check_clowdapp_status)
    if [[ "$clowdapp_was_disabled" != "true" ]]; then
        disable_clowdapp
    else
        log "ClowdApp reconciliation already disabled"
    fi
    
    # Update okteto.yaml with current namespace SCC settings and image info
    local namespace uid_range uid_start image_full image_name image_tag
    namespace=$(oc project -q)
    uid_range=$(oc get namespace "$namespace" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' 2>/dev/null || echo "1000000000/10000")
    uid_start=$(echo "$uid_range" | cut -d'/' -f1)
    
    # Detect current image and tag from deployed Python service (not nginx)
    image_full=$(oc get deployment host-inventory-service-reads -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "quay.io/cloudservices/insights-inventory:latest")
    image_name=$(echo "$image_full" | cut -d':' -f1)
    image_tag=$(echo "$image_full" | cut -d':' -f2)
    
    log "Using image: $image_name:$image_tag"
    
    # Generate okteto.yaml from template with current namespace values
    log "Generating okteto.yaml from template for namespace $namespace (UID: $uid_start)"
    cp okteto/okteto.template.yaml okteto/okteto.yaml
    
    # Replace environment variable placeholders with actual values
    sed -i.tmp "s/\${OKTETO_USER_ID}/$uid_start/g; s/\${OKTETO_GROUP_ID}/$uid_start/g; s/\${OKTETO_FS_GROUP_ID}/$uid_start/g; s|\${OKTETO_IMAGE}|$image_name|g; s/\${OKTETO_TAG}/$image_tag/g" okteto/okteto.yaml
    rm -f okteto/okteto.yaml.tmp
    
    # Set the repo path for okteto
    export INSIGHTS_HOST_INVENTORY_REPO_PATH
    if [[ -n "$service" ]]; then
        okteto up --file okteto/okteto.yaml --namespace "$(oc project -q)" "$service"
    else
        okteto up --file okteto/okteto.yaml --namespace "$(oc project -q)"
    fi
}

okteto_down() {
    local status=$(check_dev_status "${DEFAULT_SERVICES[@]}")
    local active=$(echo "$status" | cut -d'|' -f1)
    
    if [[ -z "$active" ]]; then
        log "No development containers active (idempotent)"
        # Still check if we need to re-enable ClowdApp
        local clowdapp_disabled=$(check_clowdapp_status)
        if [[ "$clowdapp_disabled" == "true" ]]; then
            enable_clowdapp
        fi
        return 0
    fi
    
    # Use existing okteto.yaml if available, otherwise create temporary one
    local created_temp_yaml=false
    if [[ ! -f "okteto/okteto.yaml" ]]; then
        log "Creating temporary okteto.yaml for cleanup"
        cp okteto/okteto.template.yaml okteto/okteto.yaml
        # Use dummy values - actual values don't matter for cleanup operations
        sed -i.tmp "s/\${OKTETO_USER_ID}/1000000000/g; s/\${OKTETO_GROUP_ID}/1000000000/g; s/\${OKTETO_FS_GROUP_ID}/1000000000/g; s|\${OKTETO_IMAGE}|quay.io/cloudservices/insights-inventory|g; s/\${OKTETO_TAG}/latest/g" okteto/okteto.yaml
        rm -f okteto/okteto.yaml.tmp
        created_temp_yaml=true
    fi
    
    log "Stopping development containers: $active"
    okteto down --file okteto/okteto.yaml --namespace "$(oc project -q)" --all
    
    # Automated cleanup fallback for okteto bug
    log "Running automated cleanup of any remaining okteto deployments..."
    oc get deployments -o name | grep -- '-okteto$' | xargs -r oc delete >/dev/null 2>&1 || true
    oc get secrets -o name | grep '^secret/okteto-' | xargs -r oc delete >/dev/null 2>&1 || true  
    oc get pvc -o name | grep -- '-okteto$' | xargs -r oc delete >/dev/null 2>&1 || true
    
    log "All development containers cleaned up"
    
    # Clean up temporary okteto.yaml if we created it
    if [[ "$created_temp_yaml" == "true" ]]; then
        log "Cleaning up temporary okteto.yaml"
        rm -f okteto/okteto.yaml
    fi
    
    # Re-enable ClowdApp reconciliation after stopping development
    local clowdapp_disabled=$(check_clowdapp_status)
    if [[ "$clowdapp_disabled" == "true" ]]; then
        enable_clowdapp
    else
        log "ClowdApp reconciliation already enabled"
    fi
}

okteto_exec() {
    [[ -z "$1" ]] && { error "Service name required"; exit 1; }
    local service="$1"; shift
    
    if ! oc get deployment "${service}-okteto" >/dev/null 2>&1; then
        error "Service '$service' not in development mode"
        error "Run: $0 up $service"
        exit 1
    fi
    
    # Use existing okteto.yaml if available, otherwise create temporary one
    local created_temp_yaml=false
    if [[ ! -f "okteto/okteto.yaml" ]]; then
        cp okteto/okteto.template.yaml okteto/okteto.yaml
        # Use dummy values - actual values don't matter for exec operations
        sed -i.tmp "s/\${OKTETO_USER_ID}/1000000000/g; s/\${OKTETO_GROUP_ID}/1000000000/g; s/\${OKTETO_FS_GROUP_ID}/1000000000/g; s|\${OKTETO_IMAGE}|quay.io/cloudservices/insights-inventory|g; s/\${OKTETO_TAG}/latest/g" okteto/okteto.yaml
        rm -f okteto/okteto.yaml.tmp
        created_temp_yaml=true
    fi
    
    okteto exec --file okteto/okteto.yaml --namespace "$(oc project -q)" "$service" -- "$@"
    
    # Clean up temporary okteto.yaml if we created it
    if [[ "$created_temp_yaml" == "true" ]]; then
        rm -f okteto/okteto.yaml
    fi
}

show_help() {
    cat >&2 << EOF
Usage: okteto-dev.sh {up|down|check|exec} [service]

Configuration:
  INSIGHTS_HOST_INVENTORY_REPO_PATH (required) - Path to your local insights-host-inventory repository
  Current: ${INSIGHTS_HOST_INVENTORY_REPO_PATH:-"<NOT SET>"}
  
  CLOWDAPP_NAME (optional) - Override ClowdApp name
  Current: $CLOWDAPP_NAME

Commands:
  up [service]         - Start development for one service
                        No service: interactive selection
                        With service: start that specific service
                        Automatically disables ClowdApp reconciliation
  down                 - Stop all development containers  
                        Automatically re-enables ClowdApp reconciliation
  check [services...]  - Show development status including ClowdApp state
  exec <service> [cmd] - Execute command in development container

Available Services:
  ${DEFAULT_SERVICES[*]}

Examples:
  INSIGHTS_HOST_INVENTORY_REPO_PATH=/path/to/repo okteto-dev.sh up host-inventory-service-reads
  okteto-dev.sh up host-inventory-service-reads          # Start specific service
  okteto-dev.sh up                                       # Interactive service selection
  okteto-dev.sh check                                    # Show status
  okteto-dev.sh exec host-inventory-service-reads        # Connect to container
  okteto-dev.sh down                                     # Stop all development

ClowdApp Management:
  This script automatically manages ClowdApp reconciliation to ensure proper
  deployment scaling. ClowdApp is disabled during development and re-enabled
  when development stops.
EOF
}

# Main function
main() {
    # Basic checks
    if ! oc whoami >/dev/null 2>&1; then
        error "Not logged into OpenShift"
        exit 1
    fi
    
    if ! command -v okteto >/dev/null 2>&1; then
        error "Okteto CLI not found"
        exit 1
    fi
    
    # Validate that we successfully loaded services from template
    if [[ ${#DEFAULT_SERVICES[@]} -eq 0 ]]; then
        error "No services found in okteto.template.yaml"
        error "Please check that the template file contains a 'dev:' section with service definitions"
        exit 1
    fi
    
    # Debug: show loaded services
    log "Loaded ${#DEFAULT_SERVICES[@]} services from okteto.template.yaml: ${DEFAULT_SERVICES[*]}"
    
    # Clean up any existing backup files from previous runs
    rm -f okteto/okteto.yaml.bak okteto/okteto.yaml-e okteto/okteto.yaml.tmp
    
    # Verify repo path is set and exists
    if [[ -z "$INSIGHTS_HOST_INVENTORY_REPO_PATH" ]]; then
        warn "🔧 Almost ready! Just need to set up your local repository path first."
        warn ""
        warn "Please set INSIGHTS_HOST_INVENTORY_REPO_PATH to your local insights-host-inventory repository:"
        warn "  export INSIGHTS_HOST_INVENTORY_REPO_PATH=/path/to/your/insights-host-inventory"
        warn ""
        warn "Then you can run:"
        warn "  $0 up host-inventory-service-reads"
        warn ""
        warn "💡 Tip: Add the export to your ~/.bashrc or ~/.zshrc to make it permanent!"
        exit 1
    fi
    
    if [[ ! -d "$INSIGHTS_HOST_INVENTORY_REPO_PATH" ]]; then
        error "Insights repo path not found: $INSIGHTS_HOST_INVENTORY_REPO_PATH"
        error "Please verify the path exists and contains your insights-host-inventory repository"
        exit 1
    fi
    
    # Handle commands
    case "${1:-up}" in
        up)     shift; okteto_up "$1" ;;
        down)   okteto_down ;;
        check)  shift; show_status "$@" ;;
        exec)   shift; okteto_exec "$@" ;;
        -h|--help|help) show_help ;;
        *) error "Unknown command: $1"; show_help; exit 1 ;;
    esac
}

main "$@" 